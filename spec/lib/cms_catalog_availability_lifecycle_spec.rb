# frozen_string_literal: true

# HELD, NOT RUN. Requires root shared guard/delegate integration; this does not
# qualify actual native CMS selected-ID/fence/public-verification behavior.
require "rails_helper"
require_relative "../support/cms_catalog_availability_fixture"

describe DiscussionBridge::CmsCatalogAvailabilityLifecycle do
  include_context "CMS catalog availability native author fixture"

  context "pure current accepted facts" do
    let(:cms_build_work) { false }

    it "permits exact accepted selections without granting replacement identities" do
      expect(cms_issue.code).to be_nil
      expect(cms_issue.availability.available).to eq(true)
      cms_accept([cms_entry("replacement")])
      expect(cms_issue.code).to eq("catalog_entry_unavailable")
      expect(cms_issue.availability.missing_ids).to eq("authors" => ["writer"], "taxonomy" => [])
      expect(@cms_connection.reload.cms_configuration.fetch("policy").fetch("author_ids")).to eq(
        ["writer"],
      )
    end

    it "distinguishes an explicit unavailable entry from a missing accepted ID" do
      cms_accept([cms_entry("writer", available: false)])
      expect(cms_issue.availability.missing_ids.values.flatten).to be_empty
      expect(cms_issue.availability.unavailable_ids).to eq(
        "authors" => ["writer"],
        "taxonomy" => [],
      )
      expect(cms_issue.code).to eq("catalog_entry_unavailable")
    end

    it "reports damaged accepted selected data without inventing native absence" do
      snapshot =
        DiscussionBridgeCmsCatalogSnapshot.find_by!(
          content_connection_id: @cms_connection.id,
          kind: "authors",
          active: true,
        )
      entry = snapshot.entries.first!
      entry.update_columns(payload: entry.payload.merge("available" => "invalid"))
      expect(cms_issue.code).to eq("metadata_unavailable")
      expect(cms_issue.availability.catalog_errors).to eq("authors" => "metadata_unavailable")
      expect(cms_issue.availability.missing_ids.values.flatten).to be_empty
      expect(cms_issue.availability.unavailable_ids.values.flatten).to be_empty
    end

    it "does not turn a failed incomplete upload into an accepted absence" do
      before = cms_issue.availability.to_h
      upload =
        @cms_store
          .begin_upload(
            "mutation_id" => SecureRandom.uuid,
            "kind" => "authors",
            "native_revision" => "incomplete-r1",
            "total_items" => 1,
          )
          .body
          .fetch("upload_id")
      cms_rejected("catalog_page_conflict") do
        @cms_store.finalize(
          upload,
          "mutation_id" => SecureRandom.uuid,
          "upload_id" => upload,
          "expected_total_items" => 1,
        )
      end
      expect(cms_issue.availability.to_h).to eq(before)
    end

    context "no accepted catalog" do
      let(:cms_seed_authors) { false }

      it "retains exact missing IDs with a null accepted catalog revision" do
        expect(cms_issue.code).to eq("catalog_entry_unavailable")
        expect(cms_issue.availability.missing_ids.fetch("authors")).to eq(["writer"])
        expect(cms_issue.availability.catalog_revisions.fetch("authors")).to be_nil
      end
    end

    context "empty selections" do
      let(:cms_author_ids) { [] }
      let(:cms_seed_authors) { false }

      it "needs no catalog and writes no manufactured defaults or state" do
        before = @cms_connection.reload.attributes
        expect(cms_issue.availability.available).to eq(true)
        expect(cms_issue.code).to be_nil
        expect(DiscussionBridgeCmsCatalogSnapshot.count).to eq(0)
        expect(@cms_connection.reload.attributes).to eq(before)
      end
    end
  end

  it "retains every pending work field through exact-ID loss and restoration" do
    before = @cms_work.reload.attributes.deep_dup
    counts = [DiscussionBridgeCmsWork.count, DiscussionBridgeCmsSourceIntent.count]
    mapping_proof = cms_preserved_mapping_facts
    loss = cms_accept([])
    expect(loss.change.selected_availability.missing_ids.fetch("authors")).to eq(["writer"])
    expect(@cms_work.reload.attributes).to eq(before)
    expect(cms_preserved_mapping_facts).to eq(mapping_proof)
    expect(@cms_mapping.mapping_state).to eq("attention")
    cms_accept([cms_entry("writer")])
    expect(@cms_work.reload.attributes).to eq(before)
    expect([DiscussionBridgeCmsWork.count, DiscussionBridgeCmsSourceIntent.count]).to eq(counts)
    cycle = @cms_work.attempt_cycle
    cms_claim!
    expect(@cms_work.reload.state).to eq("leased")
    expect(@cms_work.attempt_cycle).to eq(cycle)
    expect(@cms_work.attempt).to eq(1)
  end

  it "retains overdue retry schedule and cycle until the ordinary eligible due path" do
    cms_claim!
    cms_fail!("transport_timeout")
    before = @cms_work.reload.attributes.deep_dup
    retry_time = @cms_work.retry_at
    cms_accept([])
    @cms_now = retry_time + 10
    @cms_coordinator.maintain_due!
    empty =
      @cms_coordinator.claim(
        "mutation_id" => SecureRandom.uuid,
        "mapping_id" => @cms_mapping.mapping_id,
      )
    expect(empty.status).to eq(204)
    expect(@cms_work.reload.attributes).to eq(before)
    cms_accept([cms_entry("writer")])
    expect(@cms_work.reload.attributes).to eq(before)
    @cms_coordinator.maintain_due!
    expect(@cms_work.reload.state).to eq("pending")
    expect(@cms_work.attempt_cycle).to eq(before.fetch("attempt_cycle"))
    expect(@cms_work.attempt).to eq(1)
    cms_claim!
    expect(@cms_work.reload.attempt).to eq(2)
  end

  %w[leased synchronized deployed].each do |state|
    context "current #{state} publication" do
      let(:cms_publication_kind) { state == "deployed" ? "static" : "dynamic" }

      it "fails permanent metadata loss without discarding prior native/prepared facts" do
        cms_make_live!(state)
        @cms_work.reload
        retained =
          @cms_work.attributes.slice(
            "attempt_cycle",
            "attempt",
            "lease_generation",
            "source_snapshot",
            "failure_detail",
          )
        mapping_proof = cms_preserved_mapping_facts
        source_post = cms_first_post.reload.attributes
        cms_accept([cms_entry("writer", available: false)])
        expect(@cms_work.reload.state).to eq("attention")
        expect(@cms_work.last_failure_code).to eq("catalog_entry_unavailable")
        expect(@cms_work.attributes.slice(*retained.keys)).to eq(retained)
        expect(@cms_work.lease_verifier).to be_nil
        expect(@cms_work.lease_expires_at).to be_nil
        expect(@cms_work.retry_at).to be_nil
        expect(cms_preserved_mapping_facts).to eq(mapping_proof)
        expect(cms_first_post.reload.attributes).to eq(source_post)
        before_attention = @cms_work.attributes.deep_dup
        cms_accept([cms_entry("writer")])
        expect(@cms_work.reload.attributes).to eq(before_attention)
      end
    end
  end

  it "keeps an existing actual attention failure unchanged when metadata later returns" do
    cms_claim!
    cms_fail!("public_verification_failed")
    before = @cms_work.reload.attributes.deep_dup
    cms_accept([])
    cms_accept([cms_entry("writer")])
    DiscussionBridge::CmsSourceLifecycle.new(@cms_connection, clock: -> { @cms_now }).refresh(
      cms_topic.id,
    )
    expect(@cms_work.reload.attributes).to eq(before)
    expect(DiscussionBridgeCmsWork.count).to eq(1)
    expect(@cms_work.last_failure_code).to eq("public_verification_failed")
  end

  context "damaged selected taxonomy and an accepted author repair" do
    let(:cms_taxonomy_ids) { ["term"] }

    it "settles live authority with metadata_unavailable while accepting the different valid kind" do
      cms_claim!
      snapshot =
        DiscussionBridgeCmsCatalogSnapshot.find_by!(
          content_connection_id: @cms_connection.id,
          kind: "taxonomy",
          active: true,
        )
      entry = snapshot.entries.first!
      entry.update_columns(payload: entry.payload.merge("available" => "invalid"))
      result = cms_accept([cms_entry("writer")])
      expect(result.change.selected_availability.catalog_errors).to eq(
        "taxonomy" => "metadata_unavailable",
      )
      expect(@cms_work.reload.state).to eq("attention")
      expect(@cms_work.last_failure_code).to eq("metadata_unavailable")
      expect(cms_issue.availability.missing_ids.values.flatten).to be_empty
      expect(cms_issue.availability.unavailable_ids.values.flatten).to be_empty
    end
  end

  it "rolls catalog switch, upload receipt and live failure back together" do
    cms_claim!
    active =
      DiscussionBridgeCmsCatalogSnapshot.find_by!(
        content_connection_id: @cms_connection.id,
        kind: "authors",
        active: true,
      )
    work_before = @cms_work.reload.attributes.deep_dup
    upload, input = cms_begin([])
    receipts_before = DiscussionBridgeCmsMutationReceipt.count
    failing =
      cms_lifecycle(
        permanent_failure:
          lambda do |work, code|
            @cms_coordinator.fail_catalog_metadata!(work, code: code)
            DiscussionBridge::CmsProtocol.reject!("storage_exhausted")
          end,
      )
    cms_rejected("storage_exhausted") do
      DiscussionBridgeContentConnection.transaction(requires_new: true) do
        @cms_connection.lock!
        result = @cms_store.finalize(upload, input)
        failing.apply_change!(result.change)
      end
    end
    expect(active.reload.active).to eq(true)
    expect(DiscussionBridgeCmsCatalogUpload.find_by!(upload_id: upload).state).to eq("open")
    expect(DiscussionBridgeCmsMutationReceipt.count).to eq(receipts_before)
    expect(@cms_work.reload.attributes).to eq(work_before)
  end

  it "does not repeat a loss effect or reactivate an old snapshot on saved finalize replay" do
    cms_claim!
    upload, input = cms_begin([])
    first =
      DiscussionBridgeContentConnection.transaction do
        result = @cms_store.finalize(upload, input)
        cms_lifecycle.apply_change!(result.change)
        result
      end
    cms_accept([cms_entry("writer")])
    work_before = @cms_work.reload.attributes.deep_dup
    current_revision = cms_issue.availability.catalog_revisions.fetch("authors")
    replay = @cms_store.finalize(upload, input)
    expect(replay.body).to eq(first.body)
    expect(replay.change).to be_nil
    expect(cms_lifecycle.apply_change!(replay.change)).to be_nil
    expect(cms_issue.availability.catalog_revisions.fetch("authors")).to eq(current_revision)
    expect(@cms_work.reload.attributes).to eq(work_before)
  end

  it "rejects stale accepted change context without rewriting restored current state" do
    old = cms_accept([])
    cms_accept([cms_entry("writer")])
    before = @cms_work.reload.attributes.deep_dup
    cms_rejected("revision_conflict") do
      DiscussionBridgeContentConnection.transaction { cms_lifecycle.apply_change!(old.change) }
    end
    expect(@cms_work.reload.attributes).to eq(before)
    expect(cms_issue.code).to be_nil
  end

  it "permits owned withdrawal despite absent selected publication assignments" do
    cms_claim!
    @cms_coordinator.acknowledge(
      @cms_work.work_id,
      "mutation_id" => SecureRandom.uuid,
      "authority" => @cms_authority,
      "stage" => "synchronized",
      "native_result" => cms_native_result,
    )
    withdrawal = @cms_coordinator.enqueue!(@cms_mapping, source_snapshot: nil, action: "withdraw")
    cms_accept([])
    lease =
      @cms_coordinator.claim(
        "mutation_id" => SecureRandom.uuid,
        "mapping_id" => @cms_mapping.mapping_id,
      )
    expect(lease.status).to eq(200)
    expect(lease.body.fetch("work").fetch("work_id")).to eq(withdrawal.work_id)
    expect(lease.body.fetch("work").fetch("action")).to eq("withdraw")
  end

  it "rechecks current credential before saved receipt or availability effect" do
    upload, input = cms_begin([])
    @cms_connection.rotate_secret!
    work_before = @cms_work.reload.attributes.deep_dup
    cms_rejected("authentication_failed") { @cms_store.finalize(upload, input) }
    expect(@cms_work.reload.attributes).to eq(work_before)
  end

  it "prevents a stale publication authority from advancing after exact metadata restoration" do
    cms_claim!
    old_authority = @cms_authority.deep_dup
    cms_accept([])
    cms_accept([cms_entry("writer")])
    before = @cms_work.reload.attributes.deep_dup
    cms_rejected("lease_expired") do
      @cms_coordinator.acknowledge(
        @cms_work.work_id,
        "mutation_id" => SecureRandom.uuid,
        "authority" => old_authority,
        "stage" => "synchronized",
        "native_result" => cms_native_result,
      )
    end
    expect(@cms_work.reload.attributes).to eq(before)
  end

  context "saved claim and a newly selected permitted lane" do
    let(:cms_allowed_lanes) { %w[news alternate] }

    it "rechecks the saved resource scope before returning a historical lease receipt" do
      input = { "mutation_id" => SecureRandom.uuid, "mapping_id" => @cms_mapping.mapping_id }
      expect(@cms_coordinator.claim(input).status).to eq(200)
      previous = @cms_connection.reload.cms_configuration.deep_dup
      changed = previous.deep_dup
      changed["publication_lane"] = "alternate"
      changed.fetch("policy").delete("policy_revision")
      DiscussionBridge::CmsAuthorityStore.new(@cms_connection).configure!(
        actor: cms_admin,
        input: {
          "expected_policy_revision" => previous.fetch("policy").fetch("policy_revision"),
          "configuration" => changed,
        },
      )
      cms_rejected("scope_denied") { @cms_coordinator.claim(input) }
    end
  end

  %w[pending retry_wait].each do |state|
    it "keeps #{state} truthful through an actual native source configuration error" do
      if state == "retry_wait"
        cms_claim!
        cms_fail!("transport_timeout")
      end
      before = @cms_work.reload.attributes.deep_dup
      existed = ENV.key?("DISCUSSIONBRIDGE_FORUM_NAME")
      previous = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
      begin
        ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = " "
        result =
          DiscussionBridge::CmsSourceLifecycle.new(@cms_connection, clock: -> { @cms_now }).refresh(
            cms_topic.id,
          )
        expect(result.error_code).to eq("forum_configuration_invalid")
        expect(@cms_work.reload.attributes).to eq(before)
        expect(@cms_mapping.reload.mapping_state).to eq("attention")
      ensure
        if existed
          ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = previous
        else
          ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME")
        end
      end
    end
  end

  it "handles a later database batch without converting the earlier waiting estate" do
    waiting = [@cms_work] + 100.times.map { |index| cms_add_pending!(index) }
    final_work = cms_add_pending!(100)
    final_mapping = final_work.cms_mapping
    @cms_coordinator.claim(
      "mutation_id" => SecureRandom.uuid,
      "mapping_id" => final_mapping.mapping_id,
    )
    waiting_before = waiting.to_h { |work| [work.id, work.reload.attributes.deep_dup] }
    cms_accept([])
    waiting_before.each do |id, attributes|
      expect(DiscussionBridgeCmsWork.find(id).attributes).to eq(attributes)
    end
    expect(final_work.reload.state).to eq("attention")
    expect(final_work.last_failure_code).to eq("catalog_entry_unavailable")
    expect(DiscussionBridgeCmsWork.where(state: "attention").count).to eq(1)
    expect(DiscussionBridgeCmsWork.count).to eq(102)
  end
end
