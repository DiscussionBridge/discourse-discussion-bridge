# frozen_string_literal: true

module DiscussionBridge
  # Native session administration only; no adapter credentials, publication
  # enablement, source discovery or native CMS calls are granted by inspection.
  class CmsAdminInspectionStore
    Result = Data.define(:status, :body)
    TEXT_BYTES = 4096
    RESPONSE_BYTES = 262_144

    class CatalogReader < CmsCatalogStore
      def initialize(connection, actor:, **options)
        super(connection, **options)
        @actor = actor
      end

      private

      def transaction
        DiscussionBridgeContentConnection.transaction do
          @connection.lock!
          configuration = CmsAuthorityStore.new(@connection).administrative_configuration(actor: @actor).body.fetch("cms_configuration")
          CmsProtocol.reject!("scope_denied") unless configuration
          CmsConfiguration.validate!(@connection, configuration)
          yield configuration
        end
      end
    end

    def initialize(connection, actor:, guardian:, clock: -> { Time.current })
      @connection, @actor, @guardian, @clock = connection, actor, guardian, clock
    end

    def preview(topic_id)
      CmsProtocol.validate!("CoreId", topic_id)
      transaction do |configuration|
        unless @connection.allows_direction?("from_discourse")
          CmsProtocol.reject!("scope_denied")
        end
        topic = Topic.find_by(id: topic_id)
        unless topic && @guardian.can_see?(topic) && SourceEdition.publicly_available?(topic)
          CmsProtocol.reject!("source_ineligible")
        end
        topic.lock!
        first = Post.unscoped.where(topic_id: topic.id, post_number: 1, deleted_at: nil).lock.first
        unless first && @guardian.can_see?(first) && SourceEdition.publicly_available?(topic)
          CmsProtocol.reject!("source_ineligible")
        end
        policy = configuration.fetch("policy")
        selected = CmsConfiguration.eligible?(topic, policy)
        availability = CmsCatalogStore.selected_availability(@connection, configuration: configuration)
        enabled = @connection.enabled && SiteSetting.discussion_bridge_enabled &&
          SiteSetting.discussion_bridge_endpoint_enabled && SiteSetting.discussion_bridge_publisher_enabled && policy.fetch("enabled")
        snapshot = CmsSourceStore.new(@connection, clock: @clock).send(:capture_snapshot_locked, topic, policy) if selected
        if snapshot && (snapshot.body.bytesize != snapshot.metadata.fetch("content_bytes") ||
            Digest::SHA256.hexdigest(snapshot.body.b) != snapshot.metadata.fetch("content_sha256"))
          CmsProtocol.reject!("content_hash_mismatch")
        end
        text = snapshot && Nokogiri::HTML5.fragment(snapshot.body).text
        response({ "preview_kind" => "native_source_and_saved_plan", "cms_output_verified" => false,
          "topic_id" => topic.id.to_s, "title" => topic.title, "native_source_url" => topic.url,
          "native_first_post_id" => first.id.to_s, "native_version" => first.version, "wiki" => first.wiki,
          "source" => snapshot&.metadata, "source_text" => text && self.class.excerpt(text),
          "source_text_truncated" => text ? text.bytesize > TEXT_BYTES : false,
          "selection_eligible" => selected, "publication_enabled" => enabled,
          "publication_eligible" => enabled && selected && availability.available,
          "policy_revision" => policy.fetch("policy_revision"), "presentation_mode" => policy.fetch("presentation_mode"),
          "native_capabilities" => configuration.fetch("native_capabilities"),
          "author_ids" => policy.fetch("author_ids"), "taxonomy_ids" => policy.fetch("taxonomy_ids"),
          "selection_availability" => availability_body(availability) })
      end
    rescue SourceEdition::Unavailable
      CmsProtocol.reject!("source_ineligible")
    end

    def catalog(query)
      CmsProtocol.validate!("CatalogReadQuery", query)
      transaction do |configuration|
        reader = CatalogReader.new(@connection, actor: @actor, clock: @clock)
        current = reader.send(:active_snapshot, configuration, query.fetch("kind"))
        reader.send(:scoped_snapshot!, current, configuration) if current
        page = current || query["cursor"] ? reader.read(query).body : nil
        availability = CmsCatalogStore.selected_availability(@connection, configuration: configuration)
        response({ "catalog" => page, "current_catalog_revision" => current&.catalog_revision,
          "policy_revision" => configuration.fetch("policy").fetch("policy_revision"),
          "selected_ids" => configuration.fetch("policy").fetch(query.fetch("kind") == "authors" ? "author_ids" : "taxonomy_ids"),
          "selection_availability" => availability_body(availability) })
      end
    end

    def self.excerpt(text)
      text.byteslice(0, TEXT_BYTES).force_encoding(Encoding::UTF_8).scrub("")
    end

    private

    def transaction
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        configuration = CmsAuthorityStore.new(@connection).administrative_configuration(actor: @actor).body.fetch("cms_configuration")
        CmsProtocol.reject!("scope_denied") unless configuration
        CmsConfiguration.validate!(@connection, configuration)
        yield configuration
      end
    end

    def availability_body(value)
      { "available" => value.available, "missing_ids" => value.missing_ids,
        "unavailable_ids" => value.unavailable_ids, "catalog_revisions" => value.catalog_revisions,
        "catalog_errors" => value.catalog_errors }
    end

    def response(body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > RESPONSE_BYTES
      Result.new(status: 200, body: body)
    end
  end
end
