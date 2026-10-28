# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  class CmsSourceMoveStore < CmsRecordStore
    def prepare(resource_id, input)
      CmsProtocol.validate!("SourceUrlMovePrepare", input)
      mutation("source_url_move_prepare", resource_id, input) do
        binding, receipt, native = current_source!(resource_id, input.fetch("expected_source_revision"))
        source_move_baseline!(receipt, native)
        unless binding.external_id == input.fetch("external_id") && binding.canonical_url == input.fetch("old_url")
          CmsProtocol.reject!("identity_conflict")
        end
        CmsUrlMoveProof.urls!(input.fetch("old_url"), input.fetch("new_url"))
        CmsProtocol.reject!("scope_denied") unless @connection.allows_origin?(input.fetch("new_url"))
        canonical = CanonicalSource.call(connection_id: @connection.public_id, source_url: input.fetch("new_url")).source_url
        CmsProtocol.reject!("invalid_field") unless canonical == input.fetch("new_url")
        CmsUrlReservation.with_locks([input.fetch("old_url"), input.fetch("new_url")]) do
          open = moves(binding).where(state: %w[prepared attention]).first
          if open
            unless open.state == "prepared" && open.old_url == input.fetch("old_url") && open.new_url == input.fetch("new_url")
              CmsProtocol.reject!("mapping_conflict")
            end
            # Reprepare after a concurrent accepted source edition: same owned
            # native binding/old URL/reservations, new revision and challenge.
            if open.expected_revision != receipt.fetch("revision")
              open.update!(expected_revision: receipt.fetch("revision"), proof_nonce: SecureRandom.urlsafe_base64(32),
                prepared_at: now, old_ownership: ownership_facts(binding, receipt))
            end
            next move_projection(open, 200)
          end
          CmsMoveReservation.reserve!(binding, binding.canonical_url, state: "active")
          CmsMoveReservation.reserve!(binding, input.fetch("new_url"), state: "prepared")
          move = DiscussionBridgeCmsUrlMove.create!(move_id: SecureRandom.uuid, content_connection: @connection,
            content_binding: binding, kind: "source", state: "prepared", expected_revision: receipt.fetch("revision"),
            old_url: binding.canonical_url, new_url: input.fetch("new_url"), proof_nonce: SecureRandom.urlsafe_base64(32),
            prepared_at: now, old_ownership: ownership_facts(binding, receipt))
          move_projection(move, 201)
        end
      end
    end

    def finalize(resource_id, move_id, input)
      preservation_context = nil
      CmsProtocol.validate!("SourceUrlMoveFinalize", input)
      matching_path!(move_id, input)
      mutation("source_url_move_finalize", resource_id, input) do
        binding, receipt, native = current_source!(resource_id, input.fetch("expected_source_revision"))
        generated = source_move_baseline!(receipt, native)
        move = move!(binding, move_id)
        current_move!(binding, receipt, move)
        CmsProtocol.reject!("native_ownership_conflict") unless input.fetch("proof_nonce") == move.proof_nonce
        proof = input.fetch("verification")
        unless proof.fetch("url") == move.new_url && proof.fetch("external_id") == binding.external_id
          CmsProtocol.reject!("identity_conflict")
        end
        unless proof.fetch("source_content_sha256") == receipt.fetch("content_sha256")
          CmsProtocol.reject!("content_hash_mismatch")
        end
        CmsUrlMoveProof.checked_at!(proof, move.prepared_at, now)
        record = binding.bridge_record
        if DiscussionBridgeCmsToSourceRevision.exists?(bridge_record_id: record.id, source_revision: input.fetch("new_source_revision"))
          CmsProtocol.reject!("revision_conflict")
        end
        updated_at = input.fetch("source_updated_at")
        if updated_at && receipt["created_at"] && Time.iso8601(updated_at) < Time.iso8601(receipt.fetch("created_at"))
          CmsProtocol.reject!("invalid_field")
        end
        new_input = if CmsGeneratedExcerpt.generated?(receipt.fetch("input"))
          CmsGeneratedExcerpt.project_move(receipt.fetch("input"), move.new_url, input.fetch("new_source_revision"), updated_at)
        else
          receipt.fetch("input").merge("canonical_url" => move.new_url,
            "source_revision" => input.fetch("new_source_revision"), "expected_source_revision" => receipt.fetch("revision"),
            "source_updated_at" => updated_at)
        end
        # Both representations must remain a valid, deliverable current record
        # before any native/link/binding/history/receipt mutation.
        CmsGeneratedExcerpt.validate_envelope!(new_input)
        CmsUrlReservation.with_locks([move.old_url, move.new_url]) do
          if generated
            raw = CmsGeneratedExcerpt.replace_native(receipt.fetch("generated_native_segment"), native.raw, move.new_url)
            preservation_context = { external_id: binding.external_id, resource_id: resource_id,
              source_revision: new_input.fetch("source_revision"), mutation_id: input.fetch("mutation_id") }
            edit_generated_native!(binding.bridge_record, native, raw, source_input: new_input,
              source_article_url: receipt.fetch("input").fetch("canonical_url"))
          end
          CmsMoveReservation.commit!(binding, move)
          metadata = receipt.merge("revision" => input.fetch("new_source_revision"), "previous_revision" => receipt.fetch("revision"),
            "updated_at" => updated_at, "input" => new_input, "request_sha256" => CmsToPublication.identity(new_input),
            "synchronized_at" => CmsProtocol.instant(now),
            "native_ownership_receipt_sha256" => proof.fetch("native_ownership_receipt_sha256"))
          if generated
            metadata["managed_native_sha256"] = ManagedNativePublication.managed_native_sha256(record.topic, native)
            metadata["generated_native_segment"] = CmsGeneratedExcerpt.capture_native(new_input, native.raw)
          end
          record.update!(cms_source_publication: metadata)
          DiscussionBridgeCmsToSourceRevision.create!(bridge_record_id: record.id, source_revision: input.fetch("new_source_revision"),
            identity_sha256: CmsToPublication.identity(new_input), accepted_at: now)
          move.update!(state: "committed", native_proof: proof)
          response("Record", projection(binding))
        end
      end
    rescue PortableContent::PreparationUnavailable => error
      # Finalize declares no correlation field: do not manufacture one or reuse
      # an old Resolve correlation as if it belonged to this request.
      log_content_loss!(error, **preservation_context) if preservation_context
      CmsProtocol.reject!("content_preservation_unavailable")
    end

    def abort(resource_id, move_id, input)
      CmsProtocol.validate!("SourceUrlMoveAbort", input)
      matching_path!(move_id, input)
      mutation("source_url_move_abort", resource_id, input) do
        binding, receipt = current_source!(resource_id, input.fetch("expected_source_revision"))
        move = move!(binding, move_id)
        if input.fetch("native_change_applied")
          unless %w[prepared attention].include?(move.state) && move.old_url == binding.canonical_url
            CmsProtocol.reject!("revision_conflict")
          end
        else
          current_move!(binding, receipt, move)
        end
        CmsUrlReservation.with_locks([move.old_url, move.new_url]) do
          known = move.old_ownership["native_ownership_receipt_sha256"]
          proven_unapplied = input.fetch("native_change_applied") == false && input.fetch("old_url") == move.old_url &&
            (known.nil? || known == input.fetch("native_ownership_receipt_sha256"))
          if proven_unapplied
            # The current authenticated native owner reports actual inspection.
            # Receiver binding checks and stored hash are not independent proof.
            CmsMoveReservation.release!(binding, move)
            move.update!(state: "aborted", native_proof: input.except("mutation_id"))
          else
            move.update!(state: "attention", native_proof: input.except("mutation_id"))
            binding.bridge_record.update!(cms_source_publication: receipt.merge("state" => "attention"))
          end
          move_projection(move)
        end
      end
    end

    private

    def now
      Time.at((@clock.call.to_r * 1000).floor / 1000r).utc
    end

    def current_source!(resource_id, expected)
      binding = owned_binding!(resource_id)
      record = binding.bridge_record
      record.lock!
      receipt = record.cms_source_publication
      unless record.direction == "to_discourse" && receipt && receipt["state"] == "active" && receipt["revision"] == expected
        CmsProtocol.reject!("revision_conflict")
      end
      native = Post.unscoped.where(topic_id: record.topic_id, post_number: 1, deleted_at: nil).lock.first
      record.topic.reload(lock: true)
      unless native && receipt.fetch("managed_native_sha256") == ManagedNativePublication.managed_native_sha256(record.topic, native)
        CmsProtocol.reject!("native_ownership_conflict")
      end
      [binding, receipt, native]
    end

    def ownership_facts(binding, receipt)
      facts = { "external_id" => binding.external_id, "canonical_url" => binding.canonical_url,
        "source_revision" => receipt.fetch("revision"), "managed_native_sha256" => receipt.fetch("managed_native_sha256"),
        "native_ownership_receipt_sha256" => receipt["native_ownership_receipt_sha256"] }
      facts
    end

    def source_move_baseline!(receipt, native)
      source = receipt.fetch("input")
      return false if source.fetch("representation").fetch("kind") == "full"
      # The one current excerpt owns its explicit retained native segment.
      CmsProtocol.reject!("native_ownership_conflict") unless CmsGeneratedExcerpt.generated?(source)
      unless receipt["generated_native_segment"] == CmsGeneratedExcerpt.capture_native(source, native.raw)
        CmsProtocol.reject!("native_ownership_conflict")
      end
      CmsProtocol.validate!("ToRecord", source)
      true
    end

    def edit_generated_native!(record, native, raw, source_input:, source_article_url:)
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.downcase)
      unless actor && actor.id.positive? && actor.active? && !actor.staged? && !actor.suspended? && actor.guardian.can_edit?(native)
        CmsProtocol.reject!("scope_denied")
      end
      identity = [record.topic.title, native.id, native.topic_id, native.user_id, native.wiki]
      CmsProtocol.reject!("native_ownership_conflict") unless native.revise(actor, { raw: raw }, force_new_version: true)
      native.reload
      record.topic.reload
      unless native.raw == raw && [record.topic.title, native.id, native.topic_id, native.user_id, native.wiki] == identity
        CmsProtocol.reject!("native_ownership_conflict")
      end
      NativeContentPreservation.verify!(source_html: source_input.fetch("content_html"),
        cooked_html: native.cooked, source_url: source_article_url, native_url: record.topic.url,
        owned_generated_link: true)
    end

    def moves(binding)
      DiscussionBridgeCmsUrlMove.lock.where(content_connection_id: @connection.id, content_binding_id: binding.id, kind: "source")
    end

    def move!(binding, move_id)
      moves(binding).find_by(move_id: move_id) || CmsProtocol.reject!("resource_not_found")
    end

    def current_move!(binding, receipt, move)
      unless move.state == "prepared" && move.expected_revision == receipt.fetch("revision") &&
          move.old_url == binding.canonical_url && move.old_ownership == ownership_facts(binding, receipt)
        CmsProtocol.reject!("revision_conflict")
      end
    end

    def matching_path!(move_id, input)
      CmsProtocol.validate!("UUID", move_id)
      CmsProtocol.reject!("identity_conflict") unless input.fetch("move_id") == move_id
    end

    def move_projection(move, status = 200)
      response("SourceUrlMove", { "move_id" => move.move_id, "resource_id" => move.content_binding.bridge_record.resource_id,
        "expected_source_revision" => move.expected_revision, "old_url" => move.old_url, "new_url" => move.new_url,
        "proof_nonce" => move.proof_nonce, "state" => move.state, "prepared_at" => CmsProtocol.instant(move.prepared_at) }, status)
    end
  end
end
