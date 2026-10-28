# frozen_string_literal: true

module DiscussionBridge
  class SupportOperations
    PAGE_SIZE = 25
    def initialize(actor)
      @actor = actor
    end

    def workspace(after: 0)
      after = CmsSourceLifecycle.native_id!(after) unless after.to_s == "0"
      SupportAccess.locked do |state|
        SupportAccess.operator!(@actor, state: state, action: "status")
        connections = DiscussionBridgeContentConnection.where(enabled: true).order(:id).filter_map do |connection|
          begin
            config = CmsConfiguration.current!(connection)
            [connection.id, { id: connection.id, name: connection.name, platform: connection.platform, configuration: config }]
          rescue CmsProtocol::Error
            nil
          end
        end.to_h
        rows = DiscussionBridgeBridgeRecord.where(direction: "from_discourse")
          .where("id > ?", after).includes(:topic, :content_bindings).order(:id).limit(PAGE_SIZE).to_a
        records = rows.filter_map do |record|
          topic = record.topic
          next unless topic && @actor.guardian.can_see?(topic) && SourceEdition.publicly_available?(topic)
          binding = record.content_bindings.find { |item| item.state == "active" && item.role == "presentation" && connections.key?(item.content_connection_id) }
          next unless binding
          connection = DiscussionBridgeContentConnection.find(binding.content_connection_id)
          configuration = connections.fetch(connection.id).fetch(:configuration)
          mapping = DiscussionBridgeCmsMapping.find_by(content_binding_id: binding.id, content_connection_id: connection.id)
          work = mapping&.work_items&.order(created_at: :desc, id: :desc)&.first
          projection = mapping && CmsAttentionRecovery.new(connection).projection(mapping, work)
          selected = CmsConfiguration.eligible?(topic, configuration.fetch("policy"))
          actionable = publication_enabled?(connection)
          { resource_id: record.resource_id, topic_id: topic.id, title: topic.title, topic_url: topic.url,
            connection_id: connection.id, publication_status: work&.state || record.state,
            mapping_id: mapping&.mapping_id, mapping_revision: mapping&.mapping_revision,
            work_id: work&.work_id, inspection: projection && projection["inspection"],
            can_check: actionable && projection && projection["can_check"] == true,
            can_retry: actionable && projection && projection.dig("inspection", "status") == "ready" && !projection["settlement_required"],
            can_reconcile_restored_baseline: !!(actionable && projection && projection.dig("inspection", "status") == "ready" && projection["settlement_required"] == true),
            can_select_topic: actionable && SupportTopicSelection.source_in_scope?(topic, configuration.fetch("policy")), can_synchronize: actionable && selected, selected: selected }
        end
        blockers = []
        blockers << "endpoint_disabled" unless SiteSetting.discussion_bridge_endpoint_enabled
        blockers << "publisher_disabled" unless SiteSetting.discussion_bridge_publisher_enabled
        SupportAccess.operator!(@actor, state: state, action: "status")
        { provider: "DiscussionBridge", health: { health: blockers.empty? ? "available" : "attention", blockers: blockers },
          connections: connections.values.map { |item| item.except(:configuration) }, records: records,
          next_after_id: rows.length == PAGE_SIZE ? rows.last.id : nil }
      end
    end

    def attention(connection_id, action, input)
      with_connection(connection_id, action) do |state, connection|
        authorization = SupportAccess::Authorization.new(actor: @actor, state: state, connection: connection, action: action)
        store = CmsAttentionRecovery.new(connection, native_authorizer: authorization)
        result = action == "check" ? store.check(actor: @actor, input: input) : store.retry_selected(actor: @actor, input: input)
        SupportAccess.audit!(@actor, action, content_connection_id: connection.id, mutation_id: input.fetch("mutation_id"))
        result.body
      end
    end

    def select_topic(connection_id, input)
      exact_fields!(input, %w[topic_id selected])
      unless input["selected"] == true || input["selected"] == false
        raise SupportWorkflow::Error, "Selection must be true or false."
      end
      with_connection(connection_id, "select_topic") do |state, connection|
        topic = visible_topic!(input.fetch("topic_id"))
        authorization = SupportAccess::Authorization.new(actor: @actor, state: state,
          connection: connection, action: "select_topic", topic: topic)
        result = CmsAuthorityStore.new(connection).select_support_topic!(actor: @actor,
          topic: topic, selected: input.fetch("selected"), authorization: authorization)
        SupportAccess.audit!(@actor, "select_topic", content_connection_id: connection.id, topic_id: topic.id, selected: input.fetch("selected"))
        result.body
      end
    end

    def synchronize(connection_id, input)
      exact_fields!(input, %w[topic_id])
      with_connection(connection_id, "synchronize") do |state, connection|
        topic = visible_topic!(input.fetch("topic_id"))
        configuration = CmsConfiguration.current!(connection, require_enabled: true)
        raise Discourse::InvalidAccess unless CmsConfiguration.eligible?(topic, configuration.fetch("policy"))
        # Existing lifecycle preserves attention holds and derives the actual
        # current intent; this operation does not reset attempts or verify work.
        result = CmsSourceLifecycle.refresh(connection, topic.id)
        SupportAccess.operator!(@actor, state: state, action: "synchronize", connection: connection)
        SupportAccess.audit!(@actor, "synchronize", content_connection_id: connection.id, topic_id: topic.id, state: result.state)
        { state: result.state, processed_count: result.processed_count, error_code: result.error_code }
      end
    end

    private

    def publication_enabled?(connection)
      CmsConfiguration.current!(connection, require_enabled: true)
      true
    rescue CmsProtocol::Error
      false
    end

    def with_connection(id, action)
      SupportAccess.locked do |state|
        connection = DiscussionBridgeContentConnection.find(CmsSourceLifecycle.native_id!(id))
        connection.with_lock do
          SupportAccess.operator!(@actor, state: state, connection: connection, action: action)
          result = yield(state, connection)
          SupportAccess.operator!(@actor, state: state, connection: connection, action: action)
          result
        end
      end
    end

    def visible_topic!(id)
      topic = Topic.lock.find(CmsSourceLifecycle.native_id!(id))
      @actor.guardian.ensure_can_see!(topic)
      raise Discourse::InvalidAccess unless SourceEdition.publicly_available?(topic)
      topic
    end

    def exact_fields!(input, fields)
      unless input.is_a?(Hash) && input.keys.sort == fields.sort
        raise SupportWorkflow::Error, "Only the named topic action fields are accepted."
      end
    end
  end
end
