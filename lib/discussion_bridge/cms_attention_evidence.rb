# frozen_string_literal: true

module DiscussionBridge
  # Read-only classification of factual native observations. This never grants
  # a lease, repairs an object, clears preparation or creates publication work.
  module CmsAttentionEvidence
    PROFILES = {
      "astro" => "astro-static-1", "ghost" => "ghost-dynamic-1",
      "hugo" => "hugo-static-1", "statamic_flat" => "statamic-flat-1",
      "statamic_db" => "statamic-db-1", "statamic_ssg" => "statamic-ssg-1",
      "wordpress" => "wordpress-dynamic-1",
    }.freeze

    def self.evaluate(inspection, observation, profile:, publication_kind:)
      return outcome("unsupported", "unsupported_profile") unless observation["profile"] == PROFILES[profile]
      state = observation.fetch("native_state")
      return outcome("unsupported", "unsupported_profile") if state == "unsupported"
      issue = observation.fetch("issue")
      return outcome("not_ready", issue) unless issue == "none"
      return outcome("not_ready", "active_command") if observation["native_command"] == "active"
      return outcome("not_ready", "uncertain_command") if observation["native_command"] == "uncertain"
      return outcome("not_ready", "uncertain_mutation") if observation["pending_mutation"] == "uncertain"
      return outcome("not_ready", "collector_unavailable") if %w[unknown unavailable].include?(state)
      return outcome("not_ready", "native_conflict") if state == "conflict"
      return outcome("not_ready", "baseline_missing") unless observation["journal_sha256"]
      prepared = inspection["prepared_transaction"]
      if prepared && state != "restored_baseline"
        return outcome("not_ready", "baseline_missing")
      end
      case state
      when "never_applied"
        initial_absence?(inspection, observation) ? outcome("ready", "none") : outcome("not_ready", "native_conflict")
      when "baseline"
        baseline = inspection["native_result"] || inspection["verified_native_result"]
        revision = inspection.fetch("mapping")["synchronized_source_revision"]
        revision ||= inspection.fetch("mapping")["publicly_verified_source_revision"]
        qualified = if baseline&.fetch("kind") == "withdraw"
          withdrawn_baseline?(inspection, observation, baseline, profile: profile, publication_kind: publication_kind)
        else
          baseline && same_result?(baseline, observation["native_result"]) &&
            owned_object?(inspection, observation, revision: revision) &&
            equal_hash?(observation, "current_sha256", "baseline_sha256") &&
            public_result?(inspection, observation, baseline, revision, required: publication_kind == "static")
        end
        if qualified
          outcome("ready", "none")
        else
          outcome("not_ready", "native_conflict")
        end
      when "candidate_applied"
        if publication_kind == "dynamic" && !prepared &&
             candidate?(inspection, observation)
          outcome("ready", "none")
        else
          outcome("not_ready", "native_conflict")
        end
      when "restored_baseline"
        baseline = inspection["verified_native_result"]
        revision = inspection.fetch("mapping")["publicly_verified_source_revision"]
        if publication_kind == "static" && prepared && baseline &&
             observation["prepared_transaction_id"] == prepared.fetch("transaction_id") &&
             equal_hash?(observation, "current_sha256", "baseline_sha256") &&
             (baseline.fetch("kind") == "withdraw" ?
               withdrawn_baseline?(inspection, observation, baseline, profile: profile, publication_kind: publication_kind) :
               same_result?(baseline, observation["native_result"]) &&
                 owned_object?(inspection, observation, revision: revision) &&
                 public_result?(inspection, observation, baseline, revision))
          outcome("ready", "none")
        else
          outcome("not_ready", "baseline_missing")
        end
      else
        outcome("not_ready", "collector_unavailable")
      end
    end

    def self.initial_absence?(inspection, observation)
      mapping = inspection.fetch("mapping")
      inspection.fetch("work").fetch("action") == "publish_revision" &&
        mapping["destination_native_id"].nil? && inspection["native_result"].nil? &&
        inspection["prepared_transaction"].nil? && observation["object_exists"] == false &&
        observation["native_id"].nil? && observation["ownership"].nil? &&
        observation["native_result"].nil? &&
        observation["restoration_operation_id"].nil?
    end

    def self.candidate?(inspection, observation)
      work = inspection.fetch("work")
      result = observation["native_result"]
      return false unless result && result["kind"] == work.fetch("action") &&
        equal_hash?(observation, "current_sha256", "candidate_sha256") &&
        observation["source_revision"] == work["source_revision"] &&
        (owned_object?(inspection, observation, revision: nil, allow_prior_revision: true) ||
          candidate_after_withdrawal?(inspection, observation))
      if work.fetch("action") == "publish_revision"
        source = inspection["source"]
        return false unless source && result.dig("representation", "source_content_sha256") == source["content_sha256"]
      end
      public_result?(inspection, observation, result, work["source_revision"], required: false)
    end

    def self.owned_object?(inspection, observation, revision:, allow_prior_revision: false)
      mapping = inspection.fetch("mapping")
      ownership = observation["ownership"]
      result = observation["native_result"]
      return false unless observation["object_exists"] == true && ownership && result &&
        observation["managed_content_sha256"] && observation["native_id"] &&
        observation["native_revision"] == result["native_revision"] &&
        observation["native_id"] == result["native_id"] &&
        (mapping["destination_native_id"].nil? || mapping["destination_native_id"] == result["native_id"]) &&
        ownership["native_id"] == result["native_id"] &&
        ownership["resource_id"] == mapping["resource_id"] &&
        ownership["external_id"] == mapping["external_id"] &&
        ownership["canonical_url"] == mapping["canonical_url"] &&
        result["external_id"] == mapping["external_id"] && result["canonical_url"] == mapping["canonical_url"] &&
        ownership["ownership_receipt_sha256"] == result["ownership_receipt_sha256"]
      if allow_prior_revision
        [inspection.fetch("work")["source_revision"], mapping["synchronized_source_revision"],
         mapping["publicly_verified_source_revision"]].include?(ownership["source_revision"])
      else
        ownership["source_revision"] == revision && observation["source_revision"] == revision
      end
    end

    # A known current dynamic candidate may have committed before its local
    # private receipt advanced. Its exact prior verified withdrawal can bind
    # that retained receipt; this does not call it a baseline or adopt static
    # candidates. All current source/content/candidate checks remain in candidate?.
    def self.candidate_after_withdrawal?(inspection, observation)
      mapping = inspection.fetch("mapping")
      previous = inspection["verified_native_result"]
      current = observation["native_result"]
      ownership = observation["ownership"]
      return false unless previous && previous["kind"] == "withdraw" && current && ownership &&
        observation["object_exists"] == true && observation["managed_content_sha256"] &&
        mapping["destination_native_id"] && mapping["destination_native_id"] == previous["native_id"] &&
        observation["native_id"] == previous["native_id"] && current["native_id"] == previous["native_id"] &&
        observation["native_revision"] == current["native_revision"] &&
        current["external_id"] == mapping["external_id"] && current["canonical_url"] == mapping["canonical_url"] &&
        previous["external_id"] == mapping["external_id"] && previous["canonical_url"] == mapping["canonical_url"] &&
        ownership["resource_id"] == mapping["resource_id"] && ownership["external_id"] == mapping["external_id"] &&
        ownership["native_id"] == previous["native_id"] && ownership["canonical_url"] == mapping["canonical_url"] &&
        ownership["ownership_receipt_sha256"] == previous["ownership_receipt_sha256"] &&
        current["ownership_receipt_sha256"] == previous["ownership_receipt_sha256"]
      public_result?(inspection, { "verification" => inspection["verification"] }, previous, nil)
    end

    # Qualified withdrawal is a known VERIFIED baseline, not a new-object 404.
    # Actual native owners reread their entire owned manifest under their writer
    # lock, and make a fresh anonymous exact-URL absence read per inspection.
    # Cross-host audit timestamps do not invent a TTL or a clock-synchronization
    # requirement. Receiving these fields alone is not native qualification.
    def self.withdrawn_baseline?(inspection, observation, baseline, profile:, publication_kind:)
      mapping = inspection.fetch("mapping")
      ownership = observation["ownership"]
      return false unless PROFILES.key?(profile) && %w[static dynamic].include?(publication_kind)
      return false unless baseline.fetch("kind") == "withdraw" &&
        same_result?(baseline, inspection["verified_native_result"]) &&
        same_result?(baseline, observation["native_result"]) &&
        mapping["destination_native_id"] && mapping["destination_native_id"] == baseline["native_id"] &&
        equal_hash?(observation, "current_sha256", "baseline_sha256") &&
        observation["journal_sha256"] && ownership &&
        observation["native_id"] == baseline["native_id"] &&
        ownership["native_id"] == baseline["native_id"] &&
        ownership["resource_id"] == mapping["resource_id"] &&
        ownership["external_id"] == mapping["external_id"] &&
        ownership["canonical_url"] == mapping["canonical_url"] &&
        baseline["external_id"] == mapping["external_id"] &&
        baseline["canonical_url"] == mapping["canonical_url"] &&
        ownership["ownership_receipt_sha256"] == baseline["ownership_receipt_sha256"]
      if observation["object_exists"] == true
        # Astro/Statamic retain a real owned unpublished native object. A copied
        # receipt without current native and managed-content readback is unsafe.
        return false unless observation["native_revision"] &&
          observation["native_revision"] == baseline["native_revision"] &&
          observation["managed_content_sha256"]
      elsif observation["object_exists"] == false
        # Only the Hugo profile currently supplies a qualified complete owned
        # all-absent manifest. Deleting Astro's known draft is a conflict.
        return false unless profile == "hugo" && publication_kind == "static" &&
          (observation["native_revision"].nil? || observation["native_revision"] == baseline["native_revision"])
      else
        return false
      end
      # A withdrawal's exact retained receipt may still bind the prior published
      # source revision. The verified result binds that receipt hash; never
      # rewrite its actual source revision to the receiver's current null value.
      required_public = publication_kind == "static"
      public_result?(inspection, { "verification" => inspection["verification"] }, baseline, nil, required: required_public) &&
        public_result?(inspection, observation, baseline, nil, required: required_public)
    end

    def self.public_result?(inspection, observation, result, revision, required: true)
      proof = observation["verification"]
      return !required if proof.nil?
      return false unless proof && proof["url"] == inspection.fetch("mapping")["canonical_url"] &&
        proof["native_id"] == result["native_id"]
      if result["kind"] == "withdraw"
        proof["kind"] == "absent" && [404, 410].include?(proof["http_status"])
      else
        proof["kind"] == "published" && proof["source_revision"] == revision &&
          proof["representation"] == result["representation"] &&
          proof["source_content_sha256"] == result.dig("representation", "source_content_sha256")
      end
    end

    def self.same_result?(left, right)
      right && CmsProtocol.semantic_identity(left) == CmsProtocol.semantic_identity(right)
    end

    def self.equal_hash?(observation, left, right)
      observation[left] && observation[left] == observation[right]
    end

    def self.outcome(status, issue) = { "status" => status, "issue" => issue }
    private_class_method :initial_absence?, :candidate?, :owned_object?, :public_result?,
                         :same_result?, :equal_hash?, :outcome, :withdrawn_baseline?, :candidate_after_withdrawal?
  end
end
