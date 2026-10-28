# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  class CmsPresentationMoveStore
    Result = Data.define(:status, :body)

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
      @coordinator = CmsWorkCoordinator.new(connection, clock: clock)
    end

    def prepare(mapping_id, input)
      CmsProtocol.validate!("UrlMovePrepare", input)
      mutation("url_move_prepare", mapping_id, input) do |mapping, configuration|
        work = authority!(mapping, input.fetch("authority"), configuration)
        binding = mapping.content_binding
        unless input.fetch("expected_mapping_revision") == mapping.mapping_revision && input.fetch("old_url") == binding.canonical_url
          CmsProtocol.reject!("revision_conflict")
        end
        CmsUrlMoveProof.urls!(input.fetch("old_url"), input.fetch("new_url"))
        CmsConfiguration.destination_url!(@connection, configuration, input.fetch("new_url"))
        ownership!(mapping, input.fetch("ownership"))
        CmsUrlReservation.with_locks([input.fetch("old_url"), input.fetch("new_url")]) do
          open = moves(mapping).where(state: %w[prepared attention]).first
          if open
            unless open.state == "prepared" && open.expected_revision == mapping.mapping_revision &&
                open.old_url == input.fetch("old_url") && open.new_url == input.fetch("new_url") &&
                open.old_ownership.except("ownership_receipt_sha256") == input.fetch("ownership").except("ownership_receipt_sha256")
              CmsProtocol.reject!("mapping_conflict")
            end
            # A new current lease may rebind the exact unchanged prepared move.
            # The public nonce and reservations are retained, never replaced.
            open.update!(authority: authority_facts(work), old_ownership: input.fetch("ownership"))
            next projection(open, 200)
          end
          CmsMoveReservation.reserve!(binding, binding.canonical_url, state: "active", mapping: mapping)
          CmsMoveReservation.reserve!(binding, input.fetch("new_url"), state: "prepared", mapping: mapping)
          move = DiscussionBridgeCmsUrlMove.create!(
            move_id: SecureRandom.uuid, content_connection: @connection, content_binding: binding,
            cms_mapping: mapping, kind: "presentation", state: "prepared", expected_revision: mapping.mapping_revision,
            old_url: input.fetch("old_url"), new_url: input.fetch("new_url"),
            proof_nonce: SecureRandom.urlsafe_base64(32), prepared_at: now,
            authority: authority_facts(work), old_ownership: input.fetch("ownership"),
          )
          projection(move, 201)
        end
      end
    end

    def finalize(mapping_id, move_id, input)
      CmsProtocol.validate!("UrlMoveFinalize", input)
      matching_path!(move_id, input)
      mutation("url_move_finalize", mapping_id, input) do |mapping, configuration|
        work = authority!(mapping, input.fetch("authority"), configuration)
        move = move!(mapping, move_id)
        current_move!(mapping, move, work)
        CmsProtocol.reject!("native_ownership_conflict") unless input.fetch("proof_nonce") == move.proof_nonce
        CmsUrlMoveProof.presentation!(mapping, work, move, input, now)
        CmsUrlReservation.with_locks([move.old_url, move.new_url]) do
          CmsMoveReservation.commit!(mapping.content_binding, move, mapping: mapping)
          changes = { mapping_revision: SecureRandom.uuid }
          intent = mapping.presentation_move_intent
          if intent && intent["requested_url"] == move.new_url
            changes[:presentation_move_intent] = intent.merge("state" => "settled", "move_id" => move.move_id,
              "settled_at" => CmsProtocol.instant(now))
          end
          mapping.update!(changes)
          move.update!(state: "committed", native_proof: input.slice("ownership", "verification"))
          # SyncAck will report actual current native result at the new URL.
          # This route changes neither Work state nor an accepted SyncResult.
          Result.new(status: 200, body: CmsMappingProjection.call(mapping, configuration: configuration))
        end
      end
    end

    def abort(mapping_id, move_id, input)
      CmsProtocol.validate!("UrlMoveAbort", input)
      matching_path!(move_id, input)
      mutation("url_move_abort", mapping_id, input) do |mapping, configuration|
        work = authority!(mapping, input.fetch("authority"), configuration, publication: false)
        move = move!(mapping, move_id)
        if input.fetch("native_change_applied")
          # Current owner may report uncertainty after a replacement lease;
          # this authorizes attention only, never rebind/finalize/release.
          unless %w[prepared attention].include?(move.state) && move.expected_revision == mapping.mapping_revision &&
              move.old_url == mapping.content_binding.canonical_url
            CmsProtocol.reject!("revision_conflict")
          end
        else
          current_move!(mapping, move, work)
        end
        CmsUrlReservation.with_locks([move.old_url, move.new_url]) do
          if input.fetch("native_change_applied") == false && input.fetch("ownership") == move.old_ownership
            ownership!(mapping, input.fetch("ownership"))
            CmsMoveReservation.release!(mapping.content_binding, move, mapping: mapping)
            move.update!(state: "aborted", native_proof: input.slice("ownership", "native_change_applied"))
          else
            move.update!(state: "attention", native_proof: input.slice("ownership", "native_change_applied"))
            mapping.update!(mapping_state: "attention")
          end
          projection(move)
        end
      end
    end

    private

    def now
      Time.at((@clock.call.to_r * 1000).floor / 1000r).utc
    end

    def mutation(route, mapping_id, input)
      CmsProtocol.validate!("UUID", mapping_id)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest && !ActiveSupport::SecurityUtils.secure_compare(@connection.secret_digest, @authenticated_secret_digest)
          CmsProtocol.reject!("authentication_failed")
        end
        config = CmsConfiguration.current!(@connection)
        mapping = DiscussionBridgeCmsMapping.lock.find_by(content_connection_id: @connection.id, mapping_id: mapping_id)
        CmsProtocol.reject!("resource_not_found") unless mapping
        @coordinator.send(:scoped_mapping!, mapping)
        keys = { content_connection_id: @connection.id, route: route, path_resource: mapping_id, mutation_id: input.fetch("mutation_id") }
        if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
          CmsProtocol.reject!("mutation_conflict") unless CmsReceiptCipher.decrypt(receipt.request_tree) == input
          next Result.new(status: receipt.response_status, body: CmsReceiptCipher.decrypt(receipt.response_body))
        end
        response = yield(mapping, config)
        DiscussionBridgeCmsMutationReceipt.create!(**keys, request_tree: CmsReceiptCipher.encrypt(input),
          response_status: response.status, response_body: CmsReceiptCipher.encrypt(response.body))
        response
      end
    rescue ActiveRecord::RecordNotUnique
      CmsProtocol.reject!("url_collision")
    end

    def authority!(mapping, authority, configuration, publication: true)
      work = @coordinator.send(:owned_work!, authority.fetch("work_id"))
      work.lock!
      unless work.cms_mapping_id == mapping.id && work.state == "leased" && work.action == "publish_revision" && !mapping.prepared_transaction
        CmsProtocol.reject!("invalid_transition")
      end
      config = @coordinator.send(:scoped_mapping!, mapping, enabled: true)
      @coordinator.send(:current_work!, work, config)
      @coordinator.send(:authority!, work, authority)
      CmsProtocol.reject!("revision_conflict") unless work.source_revision == mapping.desired_source_revision
      if publication
        CmsCatalogAvailabilityLifecycle.assert_publication_available!(@connection, configuration: config, action: work.action)
      end
      CmsProtocol.reject!("native_ownership_conflict") unless mapping.destination_native_id
      work
    end

    def ownership!(mapping, ownership)
      binding = mapping.content_binding
      unless ownership.fetch("resource_id") == binding.bridge_record.resource_id &&
          ownership.fetch("external_id") == binding.external_id && ownership.fetch("native_id") == mapping.destination_native_id &&
          ownership.fetch("canonical_url") == binding.canonical_url
        CmsProtocol.reject!("native_ownership_conflict")
      end
      known = mapping.native_result
      # The native owner may refence an actually inspected unchanged old object
      # under this current generation. That changes the receipt hash; the prior
      # accepted receipt remains historical evidence, not the new lease proof.
      unless known &&
          ownership.fetch("source_revision") == mapping.synchronized_source_revision
        CmsProtocol.reject!("native_ownership_conflict")
      end
    end

    def moves(mapping)
      DiscussionBridgeCmsUrlMove.lock.where(content_connection_id: @connection.id, cms_mapping_id: mapping.id, kind: "presentation")
    end

    def move!(mapping, move_id)
      moves(mapping).find_by(move_id: move_id) || CmsProtocol.reject!("resource_not_found")
    end

    def authority_facts(work)
      { "work_id" => work.work_id, "lease_generation" => work.lease_generation,
        "source_revision" => work.source_revision, "policy_revision" => work.policy_revision }
    end

    def current_move!(mapping, move, work)
      unless move.state == "prepared" && move.expected_revision == mapping.mapping_revision &&
          move.old_url == mapping.content_binding.canonical_url && move.authority == authority_facts(work)
        CmsProtocol.reject!("revision_conflict")
      end
    end

    def matching_path!(move_id, input)
      CmsProtocol.validate!("UUID", move_id)
      CmsProtocol.reject!("identity_conflict") unless input.fetch("move_id") == move_id
    end

    def projection(move, status = 200)
      body = { "move_id" => move.move_id, "mapping_id" => move.cms_mapping.mapping_id,
        "expected_mapping_revision" => move.expected_revision, "old_url" => move.old_url, "new_url" => move.new_url,
        "proof_nonce" => move.proof_nonce, "state" => move.state, "prepared_at" => CmsProtocol.instant(move.prepared_at) }
      CmsProtocol.validate!("UrlMove", body)
      Result.new(status: status, body: body)
    end
  end
end
