# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  # Private metadata snapshots for the approved CMS mapping/history reads.
  # No source discovery, publication work or native object mutation occurs here.
  class CmsMappingReadStore
    Result = Data.define(:status, :body)
    PAGE_ITEMS = 100
    PAGE_BYTES = 262_144
    SNAPSHOT_SECONDS = 86_400
    KINDS = {
      "mapping_inventory" => %w[Mapping MappingPage],
      "url_history" => %w[UrlHistoryEntry UrlHistoryPage],
      "record_inventory" => %w[Record RecordPage],
      "source_url_history" => %w[UrlHistoryEntry UrlHistoryPage],
    }.freeze

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    def inventory(query = {})
      page("mapping_inventory", "", query) do |snapshot, configuration|
        count = 0
        DiscussionBridgeCmsMapping
          .where(content_connection_id: @connection.id)
          .find_each(batch_size: PAGE_ITEMS) do |mapping|
            scoped_mapping!(mapping, configuration)
            append!(
              snapshot,
              count,
              CmsMappingProjection.call(mapping, configuration: configuration),
            )
            count += 1
          end
        count
      end
    end

    def url_history(mapping_id, query = {})
      CmsProtocol.validate!("UUID", mapping_id)
      page("url_history", mapping_id, query) do |snapshot|
        mapping = owned_mapping!(mapping_id)
        count = 0
        DiscussionBridgeCmsUrlHistoryEntry
          .where(cms_mapping_id: mapping.id)
          .find_each(batch_size: PAGE_ITEMS) do |entry|
            append!(
              snapshot,
              count,
              {
                "url" => entry.url,
                "retired_at" => entry.retired_at.utc.iso8601(3),
                "move_id" => entry.move_id,
              },
            )
            count += 1
          end
        count
      end
    end

    private

    def page(kind, resource, query)
      CmsProtocol.validate!("CursorQuery", query)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest && @authenticated_secret_digest != @connection.secret_digest
          CmsProtocol.reject!("authentication_failed")
        end
        configuration = current_configuration!
        # Even cursor continuations must refer to an owned resource. Never
        # trust possession of a token as connection or object authority.
        scoped_mapping!(owned_mapping!(resource), configuration) if kind == "url_history"
        cursor =
          if query["cursor"]
            continuation!(query.fetch("cursor"), kind, resource, configuration)
          else
            snapshot =
              DiscussionBridgeCmsReadSnapshot.create!(
                content_connection_id: @connection.id,
                kind: kind,
                path_resource: resource,
                publication_lane: configuration.fetch("publication_lane"),
                scope_signature: scope_signature(configuration),
                policy_revision: configuration.fetch("policy").fetch("policy_revision"),
                expires_at: @clock.call + SNAPSHOT_SECONDS,
                created_at: @clock.call,
              )
            snapshot.update!(item_count: yield(snapshot, configuration))
            new_cursor!(snapshot, 0).first
          end
        result = render_page!(cursor)
        verify_page_scope!(kind, resource, result, configuration)
        result
      end
    end

    def scope_signature(configuration)
      stream =
        DiscussionBridgeCmsSourceStream.find_by(
          content_connection_id: @connection.id,
          publication_lane: configuration.fetch("publication_lane"),
        )
      CmsSourceStore.new(@connection).scope_fingerprint(
        configuration,
        source_scope_revision: stream&.source_scope_revision || 0,
      )
    end

    def current_configuration!
      CmsConfiguration.current!(@connection)
    end

    def verify_page_scope!(kind, resource, result, configuration)
      if kind == "mapping_inventory"
        result.body.fetch("items").each do |item|
          scoped_mapping!(owned_mapping!(item.fetch("mapping_id")), configuration)
        end
      end
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

    def append!(snapshot, ordinal, payload)
      CmsProtocol.reject!("storage_exhausted") if ordinal >= CmsProtocol::MAX_COUNTER
      CmsProtocol.validate!(KINDS.fetch(snapshot.kind).first, payload)
      snapshot.items.create!(ordinal: ordinal, payload: payload)
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

    def continuation!(token, kind, resource, configuration)
      cursor = DiscussionBridgeCmsReadCursor.find_by(token_digest: Digest::SHA256.hexdigest(token))
      CmsProtocol.reject!("cursor_invalid") unless cursor
      snapshot = cursor.cms_read_snapshot
      CmsProtocol.reject!("cursor_expired") unless snapshot
      unless snapshot.content_connection_id == @connection.id && snapshot.kind == kind &&
               snapshot.path_resource == resource &&
               snapshot.publication_lane == configuration.fetch("publication_lane") &&
               snapshot.policy_revision == configuration.fetch("policy").fetch("policy_revision") &&
               snapshot.scope_signature == scope_signature(configuration)
        CmsProtocol.reject!("cursor_scope_changed")
      end
      if snapshot.invalidated_at || snapshot.expires_at <= @clock.call
        CmsProtocol.reject!("cursor_expired")
      end
      cursor
    end

    def new_cursor!(snapshot, position)
      token = SecureRandom.urlsafe_base64(32, false)
      cursor =
        DiscussionBridgeCmsReadCursor.create!(
          cms_read_snapshot_id: snapshot.id,
          token_digest: Digest::SHA256.hexdigest(token),
          position: position,
          created_at: @clock.call,
        )
      [cursor, token]
    end

    def render_page!(cursor)
      snapshot = cursor.cms_read_snapshot
      response_type = KINDS.fetch(snapshot.kind).last
      if cursor.page_body
        CmsProtocol.validate!(response_type, cursor.page_body)
        return Result.new(status: 200, body: cursor.page_body)
      end
      items = []
      CmsProtocol.reject!("cursor_expired") unless cursor.position.between?(0, snapshot.item_count)
      rows =
        snapshot.items.where("ordinal >= ?", cursor.position).order(:ordinal).limit(PAGE_ITEMS).to_a
      expected_count = [PAGE_ITEMS, snapshot.item_count - cursor.position].min
      unless rows.size == expected_count &&
               rows.each_with_index.all? { |item, index| item.ordinal == cursor.position + index }
        CmsProtocol.reject!("cursor_expired")
      end
      rows.each do |item|
        candidate = items + [item.payload]
        maximum_envelope = { "items" => candidate, "next_cursor" => "a" * 43 }
        if JSON.generate(maximum_envelope).bytesize > PAGE_BYTES
          CmsProtocol.reject!("metadata_unavailable") if items.empty?
          break
        end
        items = candidate
      end
      position = cursor.position + items.size
      if position < snapshot.item_count && items.empty?
        # A lost snapshot row cannot silently advance or omit its entry.
        CmsProtocol.reject!("cursor_expired")
      end
      next_token = position < snapshot.item_count ? new_cursor!(snapshot, position).last : nil
      body = { "items" => items, "next_cursor" => next_token }
      CmsProtocol.validate!(response_type, body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > PAGE_BYTES
      cursor.update!(page_body: body)
      Result.new(status: 200, body: body)
    end
  end
end
