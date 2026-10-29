# frozen_string_literal: true

module DiscussionBridge
  # Catalog facts never substitute identity, create work, or prove native absence.
  class CmsCatalogAvailabilityLifecycle
    Issue = Data.define(:code, :availability)
    Effect =
      Data.define(
        :catalog_revision,
        :issue,
        :waiting_count,
        :live_failed_count,
        :attention_retained_count,
        :mapping_issue_count,
      )
    BATCH_SIZE = 100
    PERMANENT_CODES = %w[catalog_entry_unavailable metadata_unavailable].freeze
    WAITING_STATES = %w[pending retry_wait].freeze

    # Caller owns current validated configuration/resource authority and its lock.
    # This deliberately avoids current! so guards cannot recurse or gate cleanup.
    def self.selection_issue(connection, configuration:)
      availability = CmsCatalogStore.selected_availability(connection, configuration: configuration)
      # Match the stored Policy's declared author_ids then taxonomy_ids order
      # when more than one selected field has an issue at the same stage.
      kind =
        %w[authors taxonomy].find do |candidate|
          availability.catalog_errors.key?(candidate) ||
            availability.missing_ids.fetch(candidate).any? ||
            availability.unavailable_ids.fetch(candidate).any?
        end
      code =
        if kind && availability.catalog_errors.key?(kind)
          "metadata_unavailable"
        elsif kind
          "catalog_entry_unavailable"
        elsif !availability.available
          "metadata_unavailable" # An inconsistent private fact shape is unsafe.
        end
      Issue.new(code: code, availability: availability)
    end

    def self.publication_eligible?(connection, configuration:, action:)
      validate_action!(action)
      return true if action == "withdraw"
      selection_issue(connection, configuration: configuration).code.nil?
    end

    def self.assert_publication_available!(connection, configuration:, action:)
      validate_action!(action)
      return nil if action == "withdraw"
      issue = selection_issue(connection, configuration: configuration)
      CmsProtocol.reject!(issue.code) if issue.code
      issue.availability
    end

    def self.validate_action!(action)
      CmsProtocol.reject!("invalid_field") if %w[publish_revision withdraw].exclude?(action)
    end
    private_class_method :validate_action!

    def initialize(
      connection,
      clock: -> { Time.current },
      authenticated_secret_digest: nil,
      permanent_failure: nil
    )
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
      # Use the shared frozen transition classifier for current LIVE work.
      @permanent_failure =
        permanent_failure ||
          lambda do |work, code|
            CmsWorkCoordinator.new(@connection, clock: @clock).fail_catalog_metadata!(
              work,
              code: code,
            )
          end
    end

    # Call only after first accepted CatalogStore.finalize within the same outer
    # ContentConnection transaction. Rendering happens after that outer commit.
    def apply_change!(change)
      return nil unless change
      unless DiscussionBridgeContentConnection.connection.transaction_open?
        raise ArgumentError, "Catalog availability effect requires the accepting transaction"
      end
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        authenticate_current_secret!
        configuration = CmsConfiguration.current!(@connection, required_direction: nil)
        reject_readonly!
        validate_current_change!(change, configuration)
        issue = self.class.selection_issue(@connection, configuration: configuration)
        unless CmsProtocol.semantic_identity(issue.availability.to_h) ==
                 CmsProtocol.semantic_identity(change.selected_availability.to_h)
          CmsProtocol.reject!("revision_conflict")
        end
        counts = { waiting: 0, live_failed: 0, attention_retained: 0, mapping_issue: 0 }
        if issue.code && publishing_scope?(configuration)
          scoped_publication_work(configuration).find_each(batch_size: BATCH_SIZE) do |work|
            mapping = work.cms_mapping
            mapping.lock!
            work.lock!
            next unless within_current_scope?(work, mapping, configuration)
            if WAITING_STATES.include?(work.state)
              counts[:waiting] += 1
              # Mapping issue bookkeeping is not actual work attention. All work
              # fields, including due schedule and previous failure, stay intact.
              counts[:mapping_issue] += 1 if mark_mapping_issue!(mapping)
            elsif DiscussionBridgeCmsWork::LIVE_STATES.include?(work.state)
              mapping_state_before = mapping.mapping_state
              @permanent_failure.call(work, issue.code)
              unless work.reload.state == "attention" && work.last_failure_code == issue.code
                raise ArgumentError, "Catalog failure delegate did not settle live authority"
              end
              counts[:live_failed] += 1
              counts[:mapping_issue] += 1 if mapping_state_before != "attention" &&
                mapping.reload.mapping_state == "attention"
            elsif work.state == "attention"
              counts[:attention_retained] += 1
              # Never clear/relabel an actual failure or its manual barrier.
            end
          end
        end
        # Restoration is descriptive: no retry, source job, state reset, mapping
        # active claim, attempt consumption, native write, or new work occurs.
        Effect.new(
          catalog_revision: change.catalog_revision,
          issue: issue,
          waiting_count: counts.fetch(:waiting),
          live_failed_count: counts.fetch(:live_failed),
          attention_retained_count: counts.fetch(:attention_retained),
          mapping_issue_count: counts.fetch(:mapping_issue),
        )
      end
    end

    private

    def authenticate_current_secret!
      return unless @authenticated_secret_digest
      unless ActiveSupport::SecurityUtils.secure_compare(
               @authenticated_secret_digest,
               @connection.secret_digest,
             )
        CmsProtocol.reject!("authentication_failed")
      end
    end

    def reject_readonly!
      CmsProtocol.reject!("native_service_unavailable") if Discourse.readonly_mode?
    end

    def validate_current_change!(change, configuration)
      unless change.is_a?(CmsCatalogStore::CatalogChange) &&
               change.connection_id == @connection.public_id &&
               change.publication_lane == configuration.fetch("publication_lane") &&
               %w[authors taxonomy].include?(change.kind)
        CmsProtocol.reject!("identity_conflict")
      end
      snapshot =
        DiscussionBridgeCmsCatalogSnapshot.find_by(
          content_connection_id: @connection.id,
          kind: change.kind,
          publication_lane: configuration.fetch("publication_lane"),
          active: true,
        )
      unless snapshot && snapshot.catalog_revision == change.catalog_revision &&
               snapshot.native_revision == change.native_revision &&
               snapshot.total_items == change.total_items &&
               snapshot.profile == configuration.fetch("profile") &&
               snapshot.destination_origin == configuration.fetch("destination_origin")
        CmsProtocol.reject!("revision_conflict")
      end
      unless CmsCatalogStore.snapshot_binding_valid?(snapshot) &&
               snapshot.entries.count == snapshot.total_items
        CmsProtocol.reject!("metadata_unavailable")
      end
    end

    def publishing_scope?(configuration)
      @connection.allows_direction?("from_discourse") &&
        configuration.fetch("policy").fetch("enabled") && CmsSourceLifecycle.globally_enabled?
    end

    def scoped_publication_work(configuration)
      DiscussionBridgeCmsWork.joins(:cms_mapping).where(
        discussion_bridge_cms_mappings: {
          content_connection_id: @connection.id,
        },
        action: "publish_revision",
        policy_revision: configuration.fetch("policy").fetch("policy_revision"),
        state: DiscussionBridgeCmsWork::UNCOMPLETED_STATES,
      )
    end

    def within_current_scope?(work, mapping, configuration)
      unless work.action == "publish_revision" &&
               work.policy_revision == configuration.fetch("policy").fetch("policy_revision")
        return false
      end
      binding = mapping.content_binding
      record = binding.bridge_record
      unless mapping.content_connection_id == @connection.id &&
               binding.content_connection_id == @connection.id && binding.role == "presentation" &&
               binding.state == "active" && record.direction == "from_discourse" &&
               record.lane.to_s == configuration.fetch("publication_lane") &&
               mapping.source_id == "topic:#{record.topic_id}"
        return false
      end
      CmsConfiguration.destination_url!(@connection, configuration, binding.canonical_url)
      true
    rescue CmsProtocol::Error => error
      raise unless error.code == "scope_denied"
      # Existing revoked/stale scope is handled by authority/source lifecycle;
      # accepted descriptive metadata cannot grant or repair that authority.
      false
    end

    def mark_mapping_issue!(mapping)
      return false if %w[attention withdrawn].include?(mapping.mapping_state)
      mapping.update!(mapping_state: "attention")
      true
    end
  end
end
