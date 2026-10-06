# frozen_string_literal: true

module DiscussionBridge
  class AdapterSourceTopicsController < AdapterController
    requires_plugin PLUGIN_NAME
    prepend_before_action :prevent_source_caching

    def show
      render_source { |transport| transport.detail(correlation_id: @correlation_id) }
    end

    def content
      value = request.query_parameters["chunk"]
      number = value.is_a?(String) && /\A[1-9]\d{0,15}\z/.match?(value) ? Integer(value) : nil
      raise AdapterRequestBoundary::Error.new("validation_failed") unless number&.between?(1, SourceRevisionTransport::MAX_INTEGER)
      render_source { |transport| transport.chunk(number: number, correlation_id: @correlation_id) }
    end

    private

    def prevent_source_caching
      response.headers["Cache-Control"] = "private, no-store"
    end

    def permitted_query_fields
      action_name == "content" ? %w[source_revision chunk] : %w[source_revision]
    end

    def render_source
      topic_value = params[:topic_id]
      topic_id = topic_value.is_a?(String) && /\A[1-9]\d{0,15}\z/.match?(topic_value) ? Integer(topic_value) : nil
      unless topic_id&.between?(1, SourceRevisionTransport::MAX_INTEGER)
        raise AdapterRequestBoundary::Error.new("validation_failed")
      end
      revision = request.query_parameters["source_revision"]
      unless revision.is_a?(String) && revision.valid_encoding? && revision.strip.present? &&
          revision.bytesize <= 255 && !AdapterRequestBoundary::CONTROL_PATTERN.match?(revision)
        raise AdapterRequestBoundary::Error.new("validation_failed")
      end
      @content_connection.with_lock do
        unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
            @content_connection.enabled && @content_connection.authenticate_secret?(request.headers["X-DiscussionBridge-Secret"])
          raise AdapterRequestBoundary::Error.new("authentication_failed")
        end
        unless @content_connection.allows_direction?("from_discourse")
          raise AdapterRequestBoundary::Error.new("direction_denied")
        end
        topic = Topic.lock.find(topic_id)
        unless topic.deleted_at.nil? && !topic.private_message? && Guardian.new.can_see?(topic) &&
            topic.first_post && topic.first_post.deleted_at.nil?
          raise AdapterRequestBoundary::Error.new("policy_denied")
        end
        records = DiscussionBridgeBridgeRecord.joins(:content_bindings).where(
          direction: "from_discourse", topic_id: topic.id,
          discussion_bridge_content_bindings: { content_connection_id: @content_connection.id, role: "presentation", state: "active" },
        ).distinct.limit(2).to_a
        raise AdapterRequestBoundary::Error.new("not_found") if records.empty?
        raise AdapterRequestBoundary::Error.new("reconciliation_required") unless records.one?
        record = records.sole
        record.lock!
        bindings = record.content_bindings.where(content_connection_id: @content_connection.id, role: "presentation", state: "active").limit(2).to_a
        raise AdapterRequestBoundary::Error.new("reconciliation_required") unless bindings.one?
        binding = bindings.sole
        unless @content_connection.allows_lane?(record.lane) && @content_connection.allows_origin?(binding.canonical_url)
          raise AdapterRequestBoundary::Error.new("scope_denied")
        end
        value = yield SourceRevisionTransport.new(record: record, binding: binding, revision: revision)
        response.headers["Cache-Control"] = "private, no-store"
        render json: value
      end
    end
  end
end
