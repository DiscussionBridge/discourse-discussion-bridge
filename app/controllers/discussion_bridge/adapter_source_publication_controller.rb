# frozen_string_literal: true

require "base64"
require "digest"

module DiscussionBridge
  class AdapterSourcePublicationController < AdapterController
    before_action :require_source_capability

    def index
      page = SourceSnapshotManager.page(
        connection: @content_connection,
        snapshot_id: params[:snapshot],
        cursor: params[:cursor],
        limit: requested_limit,
      )
      render_protocol_json({
        snapshot: page.snapshot.snapshot_id,
        policy_revision: page.snapshot.policy_revision,
        items: page.items.map { |item| inventory_item(item.source_revision) },
        next_cursor: page.next_cursor,
        complete: page.complete,
      })
    end

    def show
      revision = requested_revision
      render_protocol_json(detail_payload(revision))
    end

    def content
      revision = requested_revision
      raise AdapterRequestBoundary::Error, "not_found" if
        revision.byte_length <= SourcePublicationProtocol::INLINE_MAXIMUM_BYTES

      chunk_number = positive_integer(params[:chunk])
      chunk_count = (revision.byte_length.to_f / SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES).ceil
      raise AdapterRequestBoundary::Error, "not_found" if chunk_number > chunk_count

      offset = (chunk_number - 1) * SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES
      bytes = revision.content_html.b.byteslice(offset, SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES)
      render_protocol_json({
        source_revision: revision.source_revision,
        chunk: chunk_number,
        chunk_count: chunk_count,
        decoded_bytes: bytes.bytesize,
        chunk_sha256: Digest::SHA256.hexdigest(bytes),
        content_base64: Base64.strict_encode64(bytes),
      })
    end

    def revocations
      page = SourceRevocationFeed.page(
        connection: @content_connection,
        high_water: params[:high_water],
        cursor: params[:cursor],
        limit: requested_limit,
      )
      render_protocol_json({
        high_water: page.high_water,
        policy_revision: @content_connection.policy_revision,
        items: page.items.map { |revocation| revocation_item(revocation) },
        next_cursor: page.next_cursor,
        complete: page.complete,
      })
    end

    def revocation
      SourceRevocationRegistry.reconcile!(connection: @content_connection)
      value = SourceRevocationRegistry.scope(connection: @content_connection)
        .joins(:bridge_record)
        .where(discussion_bridge_bridge_records: { resource_id: params[:resource_id] })
        .order(id: :desc).first!
      render_protocol_json(
        revocation_item(value).merge(
          affected_binding_ids: value.affected_binding_ids,
          policy_revision: value.policy_revision,
        ),
      )
    end

    private

    def require_source_capability
      raise AdapterRequestBoundary::Error, "direction_denied" unless
        @content_connection.enabled && @content_connection.allows_direction?("from_discourse")
      raise AdapterRequestBoundary::Error, "temporarily_unavailable" unless
        ConnectionCapability.configured?(@content_connection)
    end

    def requested_limit
      return SourcePublicationProtocol::DEFAULT_LIMIT if params[:limit].blank?

      value = positive_integer(params[:limit])
      raise AdapterRequestBoundary::Error, "malformed_value" if
        value > SourcePublicationProtocol::MAXIMUM_LIMIT

      value
    end

    def positive_integer(value)
      parsed = Integer(value, exception: false)
      raise AdapterRequestBoundary::Error, "malformed_value" unless parsed&.positive?

      parsed
    end

    def requested_revision
      source_revision = params[:source_revision]
      raise AdapterRequestBoundary::Error, "malformed_value" unless
        source_revision.is_a?(String) && source_revision.present? && source_revision.bytesize <= 255

      record = source_record
      revision = record.source_revisions.find_by(source_revision: source_revision)
      raise AdapterRequestBoundary::Error, "revision_not_found" unless revision

      revision
    end

    def source_record
      topic_id = positive_integer(params[:topic_id])
      record = DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse", topic_id: topic_id)
        .where(
          discussion_bridge_content_bindings: {
            content_connection_id: @content_connection.id,
            role: "presentation",
            state: "active",
          },
        ).distinct.first
      raise ActiveRecord::RecordNotFound unless record

      binding = record.content_bindings.find do |candidate|
        candidate.content_connection_id == @content_connection.id &&
          candidate.role == "presentation" && candidate.state == "active"
      end
      raise AdapterRequestBoundary::Error, "scope_denied" unless
        binding && @content_connection.allows_lane?(record.lane) &&
          @content_connection.allows_origin?(binding.canonical_url)

      record
    end

    def inventory_item(revision)
      {
        resource_id: revision.bridge_record.resource_id,
        topic_id: revision.bridge_record.topic_id,
        topic_url: revision.topic_url,
        title: revision.title,
        source_revision: revision.source_revision,
        source_revision_sequence: revision.source_revision_sequence,
        source_created_at: revision.source_created_at.iso8601(6),
        source_updated_at: revision.source_updated_at.iso8601(6),
      }
    end

    def detail_payload(revision)
      transport = if revision.byte_length <= SourcePublicationProtocol::INLINE_MAXIMUM_BYTES
        {
          mode: "inline",
          media_type: SourcePublicationProtocol::MEDIA_TYPE,
          byte_length: revision.byte_length,
          sha256: revision.content_sha256,
          content_html: revision.content_html,
        }
      else
        {
          mode: "chunked",
          media_type: SourcePublicationProtocol::MEDIA_TYPE,
          byte_length: revision.byte_length,
          sha256: revision.content_sha256,
          chunk_count: (revision.byte_length.to_f / SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES).ceil,
          decoded_chunk_maximum_bytes: SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
        }
      end
      inventory_item(revision).merge(
        source_authors: revision.source_authors,
        categories: revision.categories,
        tags: revision.tags,
        presentation_mode: revision.presentation_mode,
        content_transport: transport,
        content_disposition: "complete",
        network_provenance: revision.network_provenance,
      )
    end

    def revocation_item(value)
      {
        revocation_id: value.revocation_id,
        resource_id: value.bridge_record.resource_id,
        source_revision: value.source_revision,
        source_revision_sequence: value.source_revision_sequence,
        reason: value.reason,
        effective_at: value.effective_at.iso8601(6),
        restorable: value.restorable,
      }
    end

    def allowed_query_fields
      case action_name
      when "index"
        SourcePublicationProtocol::INVENTORY_QUERY_FIELDS
      when "show"
        SourcePublicationProtocol::DETAIL_QUERY_FIELDS
      when "content"
        SourcePublicationProtocol::CONTENT_QUERY_FIELDS
      when "revocations"
        SourcePublicationProtocol::REVOCATION_QUERY_FIELDS
      else
        []
      end
    end
  end
end
