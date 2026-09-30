# frozen_string_literal: true

require "cgi"

module DiscussionBridge
  class NetworkReceiver
    def self.call(peer:, source_detail:, policy_revision:, content_html: nil, action: "publish")
      new(
        peer: peer,
        source_detail: source_detail,
        policy_revision: policy_revision,
        content_html: content_html,
        action: action,
      ).call
    end

    def initialize(peer:, source_detail:, policy_revision:, content_html:, action: "publish")
      @peer = peer
      @source_detail = source_detail
      @policy_revision = policy_revision
      @content_html = content_html
      @action = action
    end

    def call
      raise AdapterRequestBoundary::Error, "scope_denied" unless @peer.operational?

      identity = DiscussionBridgeForumIdentity.current
      detail = NetworkSourceDetail.call(payload: @source_detail, content_html: @content_html)
      provenance = DiscourseNetworkProtocol.validate_provenance!(
        detail.fetch("network_provenance"),
        peer: @peer,
        local_identity: identity,
      )
      raise AdapterRequestBoundary::Error, "integrity_failed" unless
        provenance.fetch("origin_topic_url") == detail.fetch("topic_url")
      require_current_authority!(detail, provenance)
      immutable = DiscourseNetworkProtocol.immutable_operation(
        source_detail: detail,
        provenance: provenance,
        policy_revision: @policy_revision,
      )
      result = nil
      DiscussionBridgeNetworkReplay.transaction do
        replay = NetworkReplayRegistry.reserve!(
          peer: @peer,
          provenance: provenance,
          immutable_operation: immutable,
          correlation_id: detail.fetch("correlation_id"),
        )
        if replay.replay
          if @action == "restore"
            result = restore_replayed_source!(detail, provenance)
            next
          end
          raise AdapterRequestBoundary::Error, "operation_replay_mismatch" if
            replay.record.retained_result.blank?

          result = replay.record.retained_result.merge("mutated" => false)
          next
        end

        prior_revision = existing_record(detail)&.source_revision
        resolved = resolve!(detail, provenance)
        appended = DiscourseNetworkProtocol.append_local_route!(provenance, local_identity: identity)
        record = DiscussionBridgeBridgeRecord.find_by!(resource_id: resolved.resource_id)
        if @action == "restore"
          record.topic.update!(closed: false, visible: true)
          record.update!(state: "healthy")
        end
        record.update!(network_provenance: appended)
        result = {
          "outcome" => resolved.outcome,
          "resource_id" => resolved.resource_id,
          "topic_id" => resolved.topic_id,
          "mutated" => resolved.outcome == "created" || prior_revision != detail.fetch("source_revision"),
          "route_forum_ids" => appended.fetch("route_forum_ids"),
        }
        NetworkReplayRegistry.retain!(record: replay.record, result: result)
      end
      result
    end

    private

    def restore_replayed_source!(detail, provenance)
      record = existing_record(detail)
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless record
      raise AdapterRequestBoundary::Error, "policy_denied" unless
        @policy_revision == @peer.content_connection.policy_revision

      topic = record.topic
      stored = record.network_provenance || {}
      exact_source = record.source_revision == detail.fetch("source_revision") &&
        record.source_revision_sequence == detail.fetch("source_revision_sequence") &&
        record.source_content_sha256 == detail.dig("content_transport", "sha256") &&
        stored["origin_forum_id"] == provenance.fetch("origin_forum_id") &&
        stored["content_authority_forum_id"] == provenance.fetch("content_authority_forum_id")
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless exact_source && topic&.first_post

      mutated = false
      if expected_passive_state?(record, topic, detail)
        appended = DiscourseNetworkProtocol.append_local_route!(
          provenance,
          local_identity: DiscussionBridgeForumIdentity.current,
        )
        topic.update!(closed: false, visible: true)
        record.update!(state: "healthy", network_provenance: appended)
        mutated = true
      elsif record.state != "healthy" || topic.closed || !topic.visible
        raise AdapterRequestBoundary::Error, "reconciliation_required"
      end

      {
        "outcome" => "resolved",
        "resource_id" => record.resource_id,
        "topic_id" => record.topic_id,
        "mutated" => mutated,
        "route_forum_ids" => Array(record.reload.network_provenance["route_forum_ids"]),
      }
    end

    def expected_passive_state?(record, topic, detail)
      stored = record.network_provenance || {}
      record.state == "attention" && topic.closed && !topic.visible &&
        %w[hold unpublish].include?(stored["local_passive_action"]) &&
        stored["local_passive_policy_revision"] == @policy_revision &&
        stored["local_passive_predecessor_revision"] == record.source_revision &&
        stored["local_passive_predecessor_revision_sequence"] == record.source_revision_sequence &&
        stored["local_passive_source_revision_sequence"].is_a?(Integer) &&
        detail.fetch("source_revision_sequence") > stored["local_passive_source_revision_sequence"]
    end

    def require_current_authority!(detail, provenance)
      connection = @peer.content_connection
      raise AdapterRequestBoundary::Error, "policy_denied" unless
        @policy_revision == connection.policy_revision
      request = {
        connection_id: connection.public_id,
        source_url: provenance.fetch("origin_topic_url"),
        visibility: "unlisted",
        lane: resolved_lane(connection),
      }
      unless connection.enabled && connection.allows_direction?("to_discourse") &&
          connection.allows_lane?(request[:lane]) && connection.allows_origin?(request[:source_url])
        raise AdapterRequestBoundary::Error, "scope_denied"
      end

      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase)
      lane_resolution = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: request[:lane])
      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane_resolution.category_id || connection.default_category_id ||
          SiteSetting.discussion_bridge_effective_category_id,
        tags: lane_resolution.tags || SiteSetting.discussion_bridge_effective_tags,
      ) if actor
      policy = PolicyEvaluator.call(
        request: request,
        settings: PolicyEvaluator::Settings.new(
          enabled: SiteSetting.discussion_bridge_enabled,
          endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
          connection_id: connection.public_id,
          trusted_origins: connection.allowed_origins,
          service_username: SiteSetting.discussion_bridge_service_username,
        ),
        actor: actor,
        author: connection.effective_author,
        authority: authority,
        lane_resolution: lane_resolution,
      )
      raise AdapterRequestBoundary::Error, "scope_denied" unless policy.allowed

      true
    end

    def existing_record(detail)
      external_id = "network:#{@peer.remote_forum_id}:#{detail.fetch("resource_id")}"
      DiscussionBridgeBridgeRecord.joins(:content_bindings).find_by(
        discussion_bridge_content_bindings: {
          content_connection_id: @peer.content_connection_id,
          external_id: external_id,
          role: "source",
          state: "active",
        },
      )
    end

    def resolve!(detail, provenance)
      connection = @peer.content_connection
      request = destination_request(detail, provenance, connection)
      author = connection.effective_author
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase)
      lane = request[:lane]
      lane_resolution = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: lane)
      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane_resolution.category_id || connection.default_category_id ||
          SiteSetting.discussion_bridge_effective_category_id,
        tags: lane_resolution.tags || SiteSetting.discussion_bridge_effective_tags,
      ) if actor
      policy = PolicyEvaluator.call(
        request: {
          connection_id: connection.public_id,
          source_url: request.fetch(:canonical_url),
          visibility: request.fetch(:visibility),
        },
        settings: PolicyEvaluator::Settings.new(
          enabled: SiteSetting.discussion_bridge_enabled,
          endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
          connection_id: connection.public_id,
          trusted_origins: connection.allowed_origins,
          service_username: SiteSetting.discussion_bridge_service_username,
        ),
        actor: actor,
        author: author,
        authority: authority,
        lane_resolution: lane_resolution,
      )
      result = BridgeRecordResolver.call(connection: connection, request: request, policy: policy)
      raise AdapterRequestBoundary::Error, "scope_denied" if result.outcome == "rejected"
      raise AdapterRequestBoundary::Error, "reconciliation_required" if
        result.outcome == "reconciliation_required"

      result
    end

    def destination_request(detail, provenance, connection)
      content = content_for_destination(detail, provenance, connection)
      {
        direction: "to_discourse",
        external_id: "network:#{provenance.fetch("origin_forum_id")}:#{detail.fetch("resource_id")}",
        canonical_url: provenance.fetch("origin_topic_url"),
        title: detail.fetch("title"),
        content_html: content.fetch(:content_html),
        published: true,
        presentation_mode: detail.fetch("presentation_mode"),
        source_revision: detail.fetch("source_revision"),
        source_revision_sequence: detail.fetch("source_revision_sequence"),
        source_created_at: detail.fetch("source_created_at"),
        source_updated_at: detail.fetch("source_updated_at"),
        source_created_at_wire: detail.fetch("source_created_at"),
        source_updated_at_wire: detail.fetch("source_updated_at"),
        content_disposition: content.fetch(:content_disposition),
        source_content_bytes: detail.fetch("content_transport").fetch("byte_length"),
        source_content_sha256: detail.fetch("content_transport").fetch("sha256"),
        read_more_url: content[:read_more_url],
        lane: resolved_lane(connection),
        correlation_id: detail.fetch("correlation_id"),
        visibility: "unlisted",
        source_authors: [],
        network_restore: @action == "restore",
      }.compact
    end

    def content_for_destination(detail, provenance, connection)
      body = detail.fetch("content_html")
      boundary = provenance_boundary(provenance)
      maximum = destination_policy(connection).dig("native_limit_policy", "maximum_bytes")
      effective_maximum = [maximum, BridgeRecordRequest::MAX_CONTENT_HTML_BYTES].min
      complete_content = body + boundary
      read_more = provenance.fetch("origin_topic_url")
      if content_within_limits?(complete_content, read_more, connection, effective_maximum)
        return { content_html: complete_content, content_disposition: "complete" }
      end

      overflow = destination_policy(connection).dig("native_limit_policy", "overflow_behavior")
      raise AdapterRequestBoundary::Error, "content_unsupported" unless overflow == "excerpt_with_read_more"

      text = ActionController::Base.helpers.strip_tags(body).squish
      excerpt_body = bounded_excerpt_body(
        text,
        read_more: read_more,
        boundary: boundary,
        maximum_bytes: effective_maximum,
      )
      {
        content_html: excerpt_body,
        content_disposition: "excerpt",
        read_more_url: read_more,
      }
    end

    def bounded_excerpt_body(text, read_more:, boundary:, maximum_bytes:)
      characters = text.each_char.to_a
      low = 0
      high = characters.length
      accepted = nil

      while low <= high
        midpoint = (low + high) / 2
        candidate = excerpt_body(characters.first(midpoint).join, read_more, boundary)
        if content_within_limits?(candidate, read_more, @peer.content_connection, maximum_bytes)
          accepted = candidate
          low = midpoint + 1
        else
          high = midpoint - 1
        end
      end
      raise AdapterRequestBoundary::Error, "content_unsupported" unless accepted

      accepted
    end

    def content_within_limits?(content_html, source_url, connection, maximum_bytes)
      raw = companion_raw(
        content_html,
        source_url,
        connection: connection,
      )
      content_html.bytesize <= BridgeRecordRequest::MAX_CONTENT_HTML_BYTES &&
        raw.bytesize <= maximum_bytes && raw.length <= SiteSetting.max_post_length
    end

    def companion_raw_length(content_html, source_url, connection: @peer.content_connection)
      companion_raw(content_html, source_url, connection: connection).length
    end

    def companion_raw(content_html, source_url, connection:)
      TopicCreator.companion_post(
        source_url: source_url,
        content_html: content_html,
        source_authors: [],
        generate_topic_toc: connection.generate_topic_toc,
      )
    end

    def excerpt_body(text, read_more, boundary)
      escaped = CGI.escapeHTML(text)
      escaped_url = CGI.escapeHTML(read_more)
      %(<p><strong>This is an excerpt.</strong></p><p>#{escaped}…</p>) +
        %(<p><a href="#{escaped_url}">Read More</a></p>#{boundary})
    end

    def provenance_boundary(provenance)
      current_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
      relationship = provenance.fetch("relationship") == "hub_to_spoke" ? "Hub to spoke" : "Spoke to hub"
      origin_name = CGI.escapeHTML(provenance.fetch("origin_forum_name"))
      origin_url = CGI.escapeHTML(provenance.fetch("origin_topic_url"))
      current = CGI.escapeHTML(current_name.to_s)
      <<~HTML
        <aside class="discussion-bridge-network-provenance">
          <p><strong>DiscussionBridge network publication</strong></p>
          <p>Origin: <a href="#{origin_url}">#{origin_name}</a> · Relationship: #{relationship} · Current forum: #{current}</p>
          <p>The first post is synchronized from the origin. Replies and moderation remain local to this forum.</p>
        </aside>
      HTML
    end

    def destination_policy(connection)
      policies = Array(connection.destination_policies).select do |policy|
        policy.stringify_keys["profile"] == "discourse_as_publisher"
      end
      raise AdapterRequestBoundary::Error, "policy_denied" unless policies.one?

      policies.first.stringify_keys
    end

    def resolved_lane(connection)
      lanes = Array(connection.allowed_lanes)
      raise AdapterRequestBoundary::Error, "scope_denied" if lanes.length > 1

      lanes.first
    end
  end
end
