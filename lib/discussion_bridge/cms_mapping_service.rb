# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  class CmsMappingService
    Result = Data.define(:status, :body)

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    def prepare(input)
      CmsProtocol.validate!("MappingPrepare", input)
      mutation("mapping_prepare", input) do
        configuration = CmsConfiguration.current!(@connection, require_enabled: true)
        unless input.fetch("policy_revision") ==
                 configuration.fetch("policy").fetch("policy_revision")
          CmsProtocol.reject!("policy_changed")
        end
        CmsConfiguration.destination_url!(@connection, configuration, input.fetch("canonical_url"))
        intent, metadata, topic = current_source!(input.fetch("source_id"))
        unless input.fetch("source_revision") == metadata.fetch("source_revision")
          CmsProtocol.reject!("revision_conflict")
        end
        if mapping = owned_source_mapping(input.fetch("source_id"))
          scoped_mapping!(mapping, configuration)
          binding = mapping.content_binding
          unless binding.external_id == input.fetch("external_id") &&
                   binding.canonical_url == input.fetch("canonical_url")
            CmsProtocol.reject!("mapping_conflict")
          end
          CmsUrlReservation.new.reserve_active!(mapping)
          next result(mapping, configuration, status: 200)
        end

        # An existing baseline identity must use explicit adoption. Prepared or
        # historical identities are retained too; absence of active delivery is
        # never permission to recreate a resource, external ID or native object.
        CmsCatalogAvailabilityLifecycle.assert_publication_available!(
          @connection,
          configuration: configuration,
          action: "publish_revision",
        )
        reject_baseline_identity!(intent, input)
        record =
          DiscussionBridgeBridgeRecord.create!(
            resource_id: SecureRandom.uuid,
            direction: "from_discourse",
            lane: configuration.fetch("publication_lane"),
            state: "healthy",
            title: metadata.fetch("title"),
            topic_id: topic.id,
            effective_actor_id: topic.user_id,
            requested_visibility: topic.visible ? "listed" : "unlisted",
            effective_visibility: topic.visible ? "listed" : "unlisted",
          )
        binding =
          DiscussionBridgeContentBinding.create!(
            bridge_record: record,
            content_connection: @connection,
            role: "presentation",
            state: "active",
            external_id: input.fetch("external_id"),
            canonical_url: input.fetch("canonical_url"),
            identity_digest:
              Digest::SHA256.hexdigest("#{@connection.public_id}\n#{input.fetch("external_id")}"),
            canonical_url_digest:
              Digest::SHA256.hexdigest("#{@connection.public_id}\n#{input.fetch("canonical_url")}"),
            native_materialization: true,
            presentation_mode: configuration.fetch("policy").fetch("presentation_mode"),
            cms_protocol_version: 2,
            activated_at: now,
          )
        mapping = create_mapping!(binding, intent)
        CmsUrlReservation.new.reserve_active!(mapping)
        enqueue_current!(mapping, metadata)
        result(mapping, configuration, status: 201)
      end
    end

    def adopt(input)
      CmsProtocol.validate!("MappingAdopt", input)
      unless input.fetch("ownership").fetch("resource_id") == input.fetch("resource_id")
        CmsProtocol.reject!("identity_conflict")
      end
      mutation("mapping_adopt", input) do
        configuration = CmsConfiguration.current!(@connection, require_enabled: true)
        policy = configuration.fetch("policy")
        unless policy.fetch("existing_record_adoption") == "explicit_records_only" &&
                 policy.fetch("adoptable_resource_ids").include?(input.fetch("resource_id"))
          CmsProtocol.reject!("scope_denied")
        end
        intent, metadata, topic = current_source!(input.fetch("source_id"))
        unless input.fetch("expected_topic_id") == topic.id.to_s
          CmsProtocol.reject!("identity_conflict")
        end
        record, binding = adoption_binding!(input, configuration, intent)
        ownership = input.fetch("ownership")
        unless binding.external_id == ownership.fetch("external_id") &&
                 binding.canonical_url == ownership.fetch("canonical_url")
          CmsProtocol.reject!("native_ownership_conflict")
        end

        if mapping = owned_source_mapping(input.fetch("source_id"))
          scoped_mapping!(mapping, configuration)
          unless mapping.content_binding_id == binding.id &&
                   mapping.content_binding.bridge_record_id == record.id
            CmsProtocol.reject!("mapping_conflict")
          end
          match_known_ownership!(mapping, ownership)
          CmsUrlReservation.new.reserve_active!(mapping)
          next result(mapping, configuration, status: 200)
        end
        if DiscussionBridgeCmsMapping.exists?(content_binding_id: binding.id)
          CmsProtocol.reject!("mapping_conflict")
        end
        if DiscussionBridgeCmsMapping.where(
             content_connection_id: @connection.id,
             destination_native_id: ownership.fetch("native_id"),
           ).exists?
          CmsProtocol.reject!("native_ownership_conflict")
        end

        CmsCatalogAvailabilityLifecycle.assert_publication_available!(
          @connection,
          configuration: configuration,
          action: "publish_revision",
        )
        mapping =
          create_mapping!(
            binding,
            intent,
            destination_native_id: ownership.fetch("native_id"),
            adoption_ownership: ownership.deep_dup,
          )
        CmsUrlReservation.new.reserve_active!(mapping)
        # Nullable/older baseline revision and ownership hash are reported
        # provenance, not retained-v2 revision authority or native/public proof.
        # New desired work uses the current receiver-authorized source instead.
        enqueue_current!(mapping, metadata)
        result(mapping, configuration, status: 201)
      end
    end

    def show(mapping_id)
      CmsProtocol.validate!("UUID", mapping_id)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        authenticate_current_secret!
        configuration = CmsConfiguration.current!(@connection)
        mapping = owned_mapping!(mapping_id)
        scoped_mapping!(mapping, configuration)
        result(mapping, configuration, status: 200)
      end
    end

    private

    def now
      Time.at((@clock.call.to_r * 1000).floor / 1000r).utc
    end

    def mutation(route, input)
      DiscussionBridgeCmsMutationReceipt.transaction do
        @connection.lock!
        authenticate_current_secret!
        configuration = CmsConfiguration.current!(@connection)
        keys = {
          content_connection_id: @connection.id,
          route: route,
          path_resource: "",
          mutation_id: input.fetch("mutation_id"),
        }
        if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
          unless CmsReceiptCipher.decrypt(receipt.request_tree) == input
            CmsProtocol.reject!("mutation_conflict")
          end
          body = CmsReceiptCipher.decrypt(receipt.response_body)
          mapping = owned_mapping!(body.fetch("mapping_id"))
          scoped_mapping!(mapping, configuration)
          next Result.new(status: receipt.response_status, body: body)
        end
        response = yield
        DiscussionBridgeCmsMutationReceipt.create!(
          **keys,
          request_tree: CmsReceiptCipher.encrypt(input),
          response_status: response.status,
          response_body: CmsReceiptCipher.encrypt(response.body),
        )
        response
      end
    rescue ActiveRecord::RecordNotUnique
      # Identities/URL tombstones are never retried as a second native create.
      CmsProtocol.reject!("mapping_conflict")
    end

    def authenticate_current_secret!
      return unless @authenticated_secret_digest
      unless ActiveSupport::SecurityUtils.secure_compare(
               @connection.secret_digest,
               @authenticated_secret_digest,
             )
        CmsProtocol.reject!("authentication_failed")
      end
    end

    def current_source!(source_id)
      source_store = CmsSourceStore.new(@connection, clock: @clock)
      intent = source_store.intent(source_id, for_mutation: true)
      CmsProtocol.reject!("source_ineligible") unless intent
      intent.lock!
      CmsProtocol.reject!("source_ineligible") unless intent.state == "active"
      revision = intent.source_revisions.find_by(source_revision: intent.current_source_revision)
      CmsProtocol.reject!("revision_conflict") unless revision
      metadata = revision.source_metadata
      CmsProtocol.validate!("Source", metadata)
      unless metadata.fetch("source_id") == source_id &&
               metadata.fetch("topic_id") == intent.topic_id.to_s
        CmsProtocol.reject!("identity_conflict")
      end
      topic = Topic.unscoped.find_by(id: intent.topic_id)
      CmsProtocol.reject!("source_ineligible") unless topic
      snapshot = source_store.capture_snapshot(topic)
      CmsProtocol.reject!("revision_conflict") unless snapshot.metadata == metadata
      bytes = revision.content_bytes_blob.b
      unless bytes.bytesize == metadata.fetch("content_bytes") &&
               Digest::SHA256.hexdigest(bytes) == metadata.fetch("content_sha256")
        CmsProtocol.reject!("metadata_unavailable")
      end
      [intent, metadata, topic]
    rescue SourceEdition::Unavailable
      CmsProtocol.reject!("source_ineligible")
    end

    def owned_source_mapping(source_id)
      DiscussionBridgeCmsMapping.lock.find_by(
        content_connection_id: @connection.id,
        source_id: source_id,
      )
    end

    def owned_mapping!(mapping_id)
      mapping =
        DiscussionBridgeCmsMapping.find_by(
          content_connection_id: @connection.id,
          mapping_id: mapping_id,
        )
      CmsProtocol.reject!("resource_not_found") unless mapping
      mapping
    end

    def scoped_mapping!(mapping, configuration)
      binding = mapping.content_binding
      record = binding.bridge_record
      unless binding.content_connection_id == @connection.id && binding.role == "presentation" &&
               binding.state == "active" && record.direction == "from_discourse" &&
               record.lane.to_s == configuration.fetch("publication_lane") &&
               mapping.source_id == "topic:#{record.topic_id}"
        CmsProtocol.reject!("scope_denied")
      end
      CmsConfiguration.destination_url!(@connection, configuration, binding.canonical_url)
    end

    def reject_baseline_identity!(intent, input)
      bindings = DiscussionBridgeContentBinding.where(content_connection_id: @connection.id)
      if bindings.where(external_id: input.fetch("external_id")).exists? ||
           bindings.where(
             canonical_url_digest:
               Digest::SHA256.hexdigest(
                 "#{@connection.public_id}\n#{input.fetch("canonical_url")}",
               ),
           ).exists?
        CmsProtocol.reject!("mapping_conflict")
      end
      if bindings
           .joins(:bridge_record)
           .where(
             role: "presentation",
             discussion_bridge_bridge_records: {
               topic_id: intent.topic_id,
               direction: "from_discourse",
             },
           )
           .exists?
        CmsProtocol.reject!("mapping_conflict")
      end
    end

    def adoption_binding!(input, configuration, intent)
      record = DiscussionBridgeBridgeRecord.lock.find_by(resource_id: input.fetch("resource_id"))
      CmsProtocol.reject!("resource_not_found") unless record
      binding =
        DiscussionBridgeContentBinding.lock.find_by(
          bridge_record_id: record.id,
          content_connection_id: @connection.id,
          role: "presentation",
          state: "active",
        )
      CmsProtocol.reject!("resource_not_found") unless binding
      unless record.direction == "from_discourse" && record.topic_id == intent.topic_id &&
               record.topic_id.to_s == input.fetch("expected_topic_id") &&
               record.lane.to_s == configuration.fetch("publication_lane")
        CmsProtocol.reject!("identity_conflict")
      end
      CmsConfiguration.destination_url!(@connection, configuration, binding.canonical_url)
      [record, binding]
    end

    def create_mapping!(binding, intent, **attributes)
      DiscussionBridgeCmsMapping.create!(
        mapping_id: SecureRandom.uuid,
        mapping_revision: SecureRandom.uuid,
        mapping_state: "pending",
        content_connection: @connection,
        content_binding: binding,
        source_id: intent.source_id,
        **attributes,
      )
    end

    def match_known_ownership!(mapping, ownership)
      unless mapping.destination_native_id == ownership.fetch("native_id")
        CmsProtocol.reject!("native_ownership_conflict")
      end
      # Current synchronized receiver facts supersede older baseline reports.
      # Neither branch interprets an opaque reported revision as fresh content.
      known = mapping.native_result || mapping.adoption_ownership
      if known
        %w[resource_id external_id native_id canonical_url ownership_receipt_sha256].each do |field|
          if known.key?(field) && known.fetch(field) != ownership.fetch(field)
            CmsProtocol.reject!("native_ownership_conflict")
          end
        end
      end
      known_revision = mapping.synchronized_source_revision
      if known_revision && known_revision != ownership.fetch("source_revision")
        CmsProtocol.reject!("native_ownership_conflict")
      elsif !known_revision && mapping.adoption_ownership &&
            mapping.adoption_ownership.fetch("source_revision") !=
              ownership.fetch("source_revision")
        CmsProtocol.reject!("native_ownership_conflict")
      end
    end

    def enqueue_current!(mapping, metadata)
      CmsWorkCoordinator.new(@connection, clock: @clock).enqueue!(
        mapping,
        source_snapshot: metadata,
      )
    end

    def result(mapping, configuration, status:)
      Result.new(
        status: status,
        body: CmsMappingProjection.call(mapping, configuration: configuration),
      )
    end
  end
end
