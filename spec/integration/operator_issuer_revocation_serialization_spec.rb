# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "R3-F04 Operator issuer-key serialization" do
  self.use_transactional_tests = false

  before do
    @r3_f04_workers = []
    @r3_f04_users = []
    clean_operator_state
    SiteSetting.discussion_bridge_enabled = true
  end

  after do
    alive_workers = @r3_f04_workers.select(&:alive?)
    raise "R3-F04 worker survived example cleanup" if alive_workers.any?

    clean_operator_state
    @r3_f04_users.reverse_each { |user| user.destroy! if user.persisted? }
  end

  it "rolls back verified work when key revocation commits before activation" do
    admin = tracked_user(:admin)
    enrollment = enabled_enrollment
    signing_key, trusted_key = trusted_key!(admin: admin, suffix: "1", key_id: "revocation-wins")
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      trusted_key: trusted_key,
      entitlement_id: "dbe_#{"1" * 32}",
    )
    verified = Queue.new
    continue_activation = Queue.new
    result = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          DiscussionBridgeOperatorEntitlement.transaction do
            locked_enrollment = DiscussionBridgeOperatorEnrollment.find(enrollment.id)
            entitlement = DiscussionBridge::OperatorEntitlementVerifier.call(
              payload: payload,
              enrollment: locked_enrollment,
              actor: admin,
            )
            verified << true
            continue_activation.pop
            locked_enrollment.activate!(entitlement: entitlement, actor: admin)
          end
          result << :activated
        rescue StandardError => error
          result << error
        end
      end
    end
    @r3_f04_workers << worker

    wait_for(verified)
    Timeout.timeout(15) do
      enrollment.revoke_trusted_key!(trusted_key_id: trusted_key.id, actor: admin)
    end
    continue_activation << true
    wait_for(worker)

    error = result.pop
    expect(error).to be_a(DiscussionBridge::OperatorEntitlementVerifier::VerificationError)
    expect(error.code).to eq("entitlement_invalid_signature")
    expect(DiscussionBridgeOperatorEntitlement).not_to exist(entitlement_id: payload.fetch("entitlement_id"))
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: nil,
      state: "pending_enrollment",
    )
    expect(trusted_key.reload).to have_attributes(may_issue: false, revoked_at: be_present)
    expect(DiscussionBridgeOperatorAuditRecord.pluck(:action, :entitlement_id)).to eq(
      [["revoke_trusted_key", nil]],
    )
  ensure
    continue_activation << true if worker&.alive?
    worker&.join(5)
    if worker&.alive?
      worker.kill
      worker.join(5)
    end
    raise "activation worker did not terminate" if worker&.alive?
  end

  it "makes concurrent revocation wait for activation, then revokes authority atomically" do
    admin = tracked_user(:admin)
    operator_user = tracked_user(:user, active: true)
    enrollment = enabled_enrollment
    enrollment.update!(operator_user: operator_user)
    signing_key, trusted_key = trusted_key!(admin: admin, suffix: "2", key_id: "activation-wins")
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      trusted_key: trusted_key,
      entitlement_id: "dbe_#{"2" * 32}",
      scopes: %w[observe_health apply_customer_approved_upgrade],
    )
    activated = Queue.new
    commit_activation = Queue.new
    result = Queue.new

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          DiscussionBridgeOperatorEntitlement.transaction do
            locked_enrollment = DiscussionBridgeOperatorEnrollment.find(enrollment.id)
            entitlement = DiscussionBridge::OperatorEntitlementVerifier.call(
              payload: payload,
              enrollment: locked_enrollment,
              actor: admin,
            )
            locked_enrollment.activate!(entitlement: entitlement, actor: admin)
            activated << true
            commit_activation.pop
          end
          result << :activated
        rescue StandardError => error
          result << error
        end
      end
    end
    @r3_f04_workers << worker

    wait_for(activated)
    connection = ActiveRecord::Base.connection
    begin
      connection.execute("SET lock_timeout = '250ms'")
      expect do
        enrollment.reload.revoke_trusted_key!(trusted_key_id: trusted_key.id, actor: admin)
      end.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      connection.execute("RESET lock_timeout")
    end
    expect(trusted_key.reload).to be_may_issue
    expect(DiscussionBridgeOperatorAuditRecord.count).to eq(0)

    commit_activation << true
    wait_for(worker)
    expect(result.pop).to eq(:activated)
    entitlement = DiscussionBridgeOperatorEntitlement.find_by!(
      entitlement_id: payload.fetch("entitlement_id"),
    )
    approval = DiscussionBridgeOperatorApproval.create!(
      approval_id: "r3-f04-approval",
      forum_id: enrollment.forum_id,
      provider_id: enrollment.provider_id,
      entitlement_id: entitlement.entitlement_id,
      scope: "apply_customer_approved_upgrade",
      operation_sha256: Digest::SHA256.hexdigest("r3-f04 operation"),
      approved_by: admin,
      expires_at: 30.minutes.from_now,
    )

    enrollment.reload.revoke_trusted_key!(trusted_key_id: trusted_key.id, actor: admin)

    expect(entitlement.reload).to have_attributes(state: "revoked", revoked_at: be_present)
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: entitlement.entitlement_id,
      state: "revoked",
    )
    expect do
      DiscussionBridge::OperatorServiceAccess.authorize!(
        user: operator_user,
        scope: approval.scope,
        operation_sha256: approval.operation_sha256,
        customer_approval_id: approval.approval_id,
      )
    end.to raise_error(DiscussionBridge::OperatorEntitlementVerifier::VerificationError) { |error|
      expect(error.code).to eq("entitlement_revoked")
    }
    expect(approval.reload.consumed_at).to be_nil
    expect(DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id)).to eq(
      [
        ["enroll_entitlement", entitlement.entitlement_id],
        ["revoke_entitlement", entitlement.entitlement_id],
        ["revoke_trusted_key", nil],
      ],
    )
  ensure
    commit_activation << true if worker&.alive?
    worker&.join(5)
    if worker&.alive?
      worker.kill
      worker.join(5)
    end
    raise "activation worker did not terminate" if worker&.alive?
  end

  it "samples default authorization time after a blocking approval lock" do
    admin = tracked_user(:admin)
    operator_user = tracked_user(:user, active: true)
    enrollment = enabled_enrollment
    enrollment.update!(operator_user: operator_user)
    signing_key, trusted_key = trusted_key!(admin: admin, suffix: "6", key_id: "clock-key")
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      trusted_key: trusted_key,
      entitlement_id: "dbe_#{"6" * 32}",
      scopes: %w[observe_health apply_customer_approved_upgrade],
    )
    DiscussionBridgeOperatorEntitlement.transaction do
      entitlement = DiscussionBridge::OperatorEntitlementVerifier.call(
        payload: payload,
        enrollment: enrollment,
        actor: admin,
      )
      enrollment.activate!(entitlement: entitlement, actor: admin)
    end
    entitlement = DiscussionBridgeOperatorEntitlement.find_by!(
      entitlement_id: payload.fetch("entitlement_id"),
    )
    before_expiry = Time.zone.now.change(usec: 0)
    entitlement.update!(
      expires_at: before_expiry + 5.minutes,
      grace_until: before_expiry + 1.hour,
    )
    approval = DiscussionBridgeOperatorApproval.create!(
      approval_id: "r3-f04-clock-approval",
      forum_id: enrollment.forum_id,
      provider_id: enrollment.provider_id,
      entitlement_id: entitlement.entitlement_id,
      scope: "apply_customer_approved_upgrade",
      operation_sha256: Digest::SHA256.hexdigest("r3-f04 clock operation"),
      approved_by: admin,
      expires_at: before_expiry + 2.hours,
    )
    approval_locked = Queue.new
    release_approval = Queue.new
    authorization_ready = Queue.new
    authorization_result = Queue.new
    database_name = ActiveRecord::Base.connection_db_config.configuration_hash.fetch(:database)
    ActiveRecord::Base.connection_pool.release_connection

    approval_holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        DiscussionBridgeOperatorApproval.transaction do
          DiscussionBridgeOperatorApproval.lock.find(approval.id)
          approval_locked << true
          release_approval.pop
        end
      end
    end
    @r3_f04_workers << approval_holder
    wait_for(approval_locked)

    authorization_worker = nil
    freeze_time(before_expiry) do
      authorization_worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          authorization_ready << connection.raw_connection.backend_pid
          begin
            DiscussionBridge::OperatorServiceAccess.authorize!(
              user: operator_user,
              scope: approval.scope,
              operation_sha256: approval.operation_sha256,
              customer_approval_id: approval.approval_id,
            )
            authorization_result << :authorized
          rescue StandardError => error
            authorization_result << error
          end
        end
      end
      @r3_f04_workers << authorization_worker
      authorization_pid = wait_for(authorization_ready)
      wait_for_database_lock(authorization_pid, database_name: database_name)
    end

    freeze_time(entitlement.expires_at + 1.second) do
      release_approval << true
      wait_for(approval_holder)
      wait_for(authorization_worker)
    end

    error = authorization_result.pop
    expect(error).to be_a(DiscussionBridge::OperatorEntitlementVerifier::VerificationError)
    expect(error.code).to eq("scope_denied")
    expect(approval.reload.consumed_at).to be_nil
    expect(entitlement.reload.effective_state(at: entitlement.expires_at + 1.second)).to eq(
      "grace_read_only",
    )
  ensure
    release_approval << true if approval_holder&.alive?
    [approval_holder, authorization_worker].compact.each do |worker|
      worker.join(5)
      if worker.alive?
        worker.kill
        worker.join(5)
      end
      raise "R3-F04 worker did not terminate" if worker.alive?
    end
  end

  it "rolls back committed state and inserted entitlement audit when the final key audit fails" do
    admin = tracked_user(:admin)
    enrollment = enabled_enrollment
    signing_key, trusted_key = trusted_key!(admin: admin, suffix: "5", key_id: "rollback-key")
    payload = signed_payload(
      signing_key: signing_key,
      enrollment: enrollment,
      trusted_key: trusted_key,
      entitlement_id: "dbe_#{"5" * 32}",
    )
    DiscussionBridgeOperatorEntitlement.transaction do
      entitlement = DiscussionBridge::OperatorEntitlementVerifier.call(
        payload: payload,
        enrollment: enrollment,
        actor: admin,
      )
      enrollment.activate!(entitlement: entitlement, actor: admin)
    end
    entitlement = DiscussionBridgeOperatorEntitlement.find_by!(
      entitlement_id: payload.fetch("entitlement_id"),
    )
    baseline_audits = DiscussionBridgeOperatorAuditRecord.order(:id).pluck(
      :action,
      :entitlement_id,
      :outcome,
    )
    allow(DiscussionBridge::OperatorAudit).to receive(:record!).and_wrap_original do |method, **attributes|
      raise "key audit unavailable" if attributes.fetch(:action) == "revoke_trusted_key"

      method.call(**attributes)
    end

    expect do
      enrollment.reload.revoke_trusted_key!(trusted_key_id: trusted_key.id, actor: admin)
    end.to raise_error("key audit unavailable")

    expect(trusted_key.reload).to have_attributes(may_issue: true, revoked_at: nil)
    expect(entitlement.reload).to have_attributes(state: "active", revoked_at: nil)
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: entitlement.entitlement_id,
      state: "active",
    )
    expect(
      DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id, :outcome),
    ).to eq(baseline_audits)
  end

  it "reloads current selection after a same-issuer cross-key replacement commits" do
    admin = tracked_user(:admin)
    enrollment = enabled_enrollment
    original_signing_key, original_key = trusted_key!(
      admin: admin,
      suffix: "3",
      key_id: "original-key",
    )
    replacement_signing_key, replacement_key = trusted_key!(
      admin: admin,
      suffix: "3",
      key_id: "replacement-key",
    )
    original_payload = signed_payload(
      signing_key: original_signing_key,
      enrollment: enrollment,
      trusted_key: original_key,
      entitlement_id: "dbe_#{"3" * 32}",
    )
    replacement_payload = signed_payload(
      signing_key: replacement_signing_key,
      enrollment: enrollment,
      trusted_key: replacement_key,
      entitlement_id: "dbe_#{"4" * 32}",
    )
    DiscussionBridgeOperatorEntitlement.transaction do
      original = DiscussionBridge::OperatorEntitlementVerifier.call(
        payload: original_payload,
        enrollment: enrollment,
        actor: admin,
      )
      enrollment.activate!(entitlement: original, actor: admin)
    end

    replacement_activated = Queue.new
    commit_replacement = Queue.new
    replacement_result = Queue.new
    revoker_ready = Queue.new
    revocation_result = Queue.new
    database_name = ActiveRecord::Base.connection_db_config.configuration_hash.fetch(:database)
    ActiveRecord::Base.connection_pool.release_connection

    replacement_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          DiscussionBridgeOperatorEntitlement.transaction do
            locked_enrollment = DiscussionBridgeOperatorEnrollment.find(enrollment.id)
            replacement = DiscussionBridge::OperatorEntitlementVerifier.call(
              payload: replacement_payload,
              enrollment: locked_enrollment,
              actor: admin,
            )
            locked_enrollment.activate!(entitlement: replacement, actor: admin)
            replacement_activated << true
            commit_replacement.pop
          end
          replacement_result << :activated
        rescue StandardError => error
          replacement_result << error
        end
      end
    end
    @r3_f04_workers << replacement_worker

    wait_for(replacement_activated)
    revocation_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        begin
          stale_enrollment = DiscussionBridgeOperatorEnrollment.find(enrollment.id)
          revoker_ready << connection.raw_connection.backend_pid
          stale_enrollment.revoke_trusted_key!(trusted_key_id: original_key.id, actor: admin)
          revocation_result << :revoked
        rescue StandardError => error
          revocation_result << error
        end
      end
    end
    @r3_f04_workers << revocation_worker

    revoker_pid = wait_for(revoker_ready)
    wait_for_database_lock(revoker_pid, database_name: database_name)
    commit_replacement << true
    wait_for(replacement_worker)
    wait_for(revocation_worker)

    expect(replacement_result.pop).to eq(:activated)
    expect(revocation_result.pop).to eq(:revoked)
    original = DiscussionBridgeOperatorEntitlement.find_by!(
      entitlement_id: original_payload.fetch("entitlement_id"),
    )
    replacement = DiscussionBridgeOperatorEntitlement.find_by!(
      entitlement_id: replacement_payload.fetch("entitlement_id"),
    )
    expect(original).to have_attributes(state: "replaced", revoked_at: nil)
    expect(replacement).to have_attributes(state: "active", revoked_at: nil)
    expect(enrollment.reload).to have_attributes(
      current_entitlement_id: replacement.entitlement_id,
      state: "active",
    )
    expect(original_key.reload).to have_attributes(may_issue: false, revoked_at: be_present)
    expect(replacement_key.reload).to have_attributes(may_issue: true, revoked_at: nil)
    expect(DiscussionBridgeOperatorAuditRecord.order(:id).pluck(:action, :entitlement_id)).to eq(
      [
        ["enroll_entitlement", original.entitlement_id],
        ["enroll_entitlement", replacement.entitlement_id],
        ["revoke_trusted_key", nil],
      ],
    )
  ensure
    commit_replacement << true if replacement_worker&.alive?
    [replacement_worker, revocation_worker].compact.each do |worker|
      worker.join(5)
      if worker.alive?
        worker.kill
        worker.join(5)
      end
      raise "R3-F04 worker did not terminate" if worker.alive?
    end
  end

  def enabled_enrollment
    DiscussionBridgeOperatorEnrollment.instance.tap do |record|
      record.update!(enabled: true)
    end
  end

  def tracked_user(fabricator, **attributes)
    suffix = SecureRandom.hex(6)
    user = Fabricate(
      fabricator,
      username: "r3f04_#{suffix}",
      email: "r3f04-#{suffix}@example.com",
      **attributes,
    )
    @r3_f04_users << user
    user
  end

  def trusted_key!(admin:, suffix:, key_id:)
    signing_key = OpenSSL::PKey.generate_key("ED25519")
    raw = OpenSSL::ASN1.decode(signing_key.public_to_der).value.last.value
    trusted_key = DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: "dbi_#{suffix * 32}",
      key_id: key_id,
      public_key_base64url: Base64.urlsafe_encode64(raw, padding: false),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    [signing_key, trusted_key]
  end

  def signed_payload(signing_key:, enrollment:, trusted_key:, entitlement_id:,
                     scopes: ["observe_health"])
    now = Time.zone.now.change(usec: 0)
    claims = {
      "entitlement_version" => 1,
      "entitlement_id" => entitlement_id,
      "provider_id" => enrollment.provider_id,
      "provider_name" => enrollment.provider_name,
      "forum_id" => enrollment.forum_id,
      "issuer_id" => trusted_key.issuer_id,
      "issued_at" => (now - 1.minute).iso8601,
      "not_before" => (now - 1.minute).iso8601,
      "expires_at" => (now + 1.hour).iso8601,
      "grace_until" => (now + 2.hours).iso8601,
      "scopes" => scopes,
      "key_id" => trusted_key.key_id,
    }
    canonical = DiscussionBridge::OperatorCanonicalJson.generate(claims)
    signature = signing_key.sign(
      nil,
      DiscussionBridge::OperatorEntitlementVerifier::SIGNING_DOMAIN + canonical,
    )
    claims.merge("signature" => Base64.urlsafe_encode64(signature, padding: false))
  end

  def clean_operator_state
    DiscussionBridgeOperatorAuditRecord.delete_all
    DiscussionBridgeOperatorApproval.delete_all
    DiscussionBridgeOperatorEntitlement.delete_all
    DiscussionBridgeOperatorTrustedKey.delete_all
    DiscussionBridgeOperatorEnrollment.delete_all
  end

  def wait_for(target)
    Timeout.timeout(15) do
      target.is_a?(Thread) ? target.join : target.pop
    end
  end

  def wait_for_database_lock(backend_pid, database_name:)
    observer = PG.connect(dbname: database_name)
    Timeout.timeout(15) do
      loop do
        result = observer.exec_params(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [Integer(backend_pid)],
        )
        return if result.ntuples == 1 && result.getvalue(0, 0) == "Lock"

        sleep 0.01
      end
    end
  ensure
    observer&.close
  end
end
