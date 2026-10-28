# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module DiscussionBridge
  class CmsSourceStore
    Result = Data.define(:status, :body)
    Snapshot = Data.define(:metadata, :body)
    Batch = Data.define(:complete, :processed_count, :phase, :stream_id)
    BATCH_SIZE = 100
    PAGE_BYTES = 262_144
    CHUNK_BYTES = 32_768
    CURSOR_SECONDS = 86_400
    MAX_SEQUENCE = 9_223_372_036_854_775_807

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    # Receiver-owned native observer/admin/job entry points. GET never calls
    # either method and therefore cannot discover/create source publication.
    def refresh_topic!(topic_id, on_intent: nil)
      transaction do |config|
        stream = stream!(config, create: true)
        assert_scope_capacity!(stream)
        intent = refresh_topic_locked!(stream, config, topic_id)
        on_intent&.call(intent, config) if intent
        intent
      end
    end

    # One receiver job processes at most BATCH_SIZE native topic IDs or retained
    # missing-topic intents. Its callback and progress commit with source state.
    def refresh_batch!(on_intent: nil)
      transaction do |config|
        stream = stream!(config, create: true)
        assert_scope_capacity!(stream)
        base = scope_fingerprint(config)
        unless stream.scan_state == "scanning" && stream.scan_scope_signature == base
          stream.update!(
            scan_state: "scanning",
            scan_phase: "topics",
            scan_scope_signature: base,
            scan_high_topic_id: Topic.unscoped.maximum(:id) || 0,
            scan_last_topic_id: 0,
            scan_high_intent_id: nil,
            scan_last_intent_id: 0,
            scan_completed_at: nil,
          )
        end
        if stream.scan_phase == "topics"
          ids =
            Topic
              .unscoped
              .where("id > ? AND id <= ?", stream.scan_last_topic_id, stream.scan_high_topic_id)
              .order(:id)
              .limit(BATCH_SIZE)
              .pluck(:id)
          ids.each do |id|
            intent = refresh_topic_locked!(stream, config, id)
            on_intent&.call(intent, config) if intent
          end
          if ids.empty?
            stream.update!(
              scan_phase: "retirement",
              scan_high_intent_id: stream.source_intents.maximum(:id) || 0,
              scan_last_intent_id: 0,
            )
          else
            stream.update!(scan_last_topic_id: ids.last)
          end
          Batch.new(
            complete: false,
            processed_count: ids.size,
            phase: stream.scan_phase,
            stream_id: stream.id,
          )
        else
          intents =
            stream
              .source_intents
              .where("id > ? AND id <= ?", stream.scan_last_intent_id, stream.scan_high_intent_id)
              .where.not(topic_id: Topic.unscoped.select(:id))
              .order(:id)
              .limit(BATCH_SIZE)
              .to_a
          intents.each do |intent|
            revoke!(stream, intent, "source_deleted")
            on_intent&.call(intent, config)
          end
          if intents.empty?
            stream.update!(scan_state: "complete", scan_completed_at: now)
          else
            stream.update!(scan_last_intent_id: intents.last.id)
          end
          Batch.new(
            complete: intents.empty?,
            processed_count: intents.size,
            phase: "retirement",
            stream_id: stream.id,
          )
        end
      end
    end

    # Synchronous receiver wrapper retained for existing author fixtures; jobs
    # use refresh_batch! and persisted continuation rather than this loop.
    def refresh_all!(on_intent: nil)
      loop { break if refresh_batch!(on_intent: on_intent).complete }
      true
    end

    def intent(source_id, for_mutation: false)
      CmsProtocol.validate!("OpaqueId", source_id)
      transaction do |config|
        stream = stream!(config)
        stream.assert_mutation_capacity! if for_mutation
        stream.source_intents.find_by(source_id: source_id)
      end
    end

    def assert_mutation_capacity!
      transaction { |config| stream!(config).assert_mutation_capacity! }
    end

    def feed(query)
      CmsProtocol.validate!("SourceFeedQuery", query)
      transaction do |config|
        cursor = nil
        if query["cursor"]
          cursor =
            DiscussionBridgeCmsSourceCursor.find_by(
              token_digest: Digest::SHA256.hexdigest(query.fetch("cursor")),
            )
          CmsProtocol.reject!("cursor_invalid") unless cursor
          stream = cursor.cms_source_stream
          cursor = read_cursor!(query.fetch("cursor"), stream, config)
        else
          stream = stream!(config)
        end
        if cursor.nil? &&
             !(
               stream.scan_state == "complete" &&
                 stream.scan_scope_signature == scope_fingerprint(config)
             )
          CmsProtocol.reject!("native_service_unavailable")
        end
        attention = stream.source_intents.where(state: "attention").order(:id).first
        if attention
          code =
            (
              if %w[storage_exhausted revision_conflict forum_configuration_invalid].include?(
                   attention.attention_code,
                 )
                attention.attention_code
              else
                "metadata_unavailable"
              end
            )
          CmsProtocol.reject!(code)
        end
        if query.fetch("stream") == "initial"
          CmsProtocol.reject!("cursor_invalid") if cursor && cursor.kind != "initial"
          cursor ||= initial_snapshot!(stream, config)
          initial_page!(cursor, stream, config)
        else
          CmsProtocol.reject!("cursor_invalid") unless %w[changes checkpoint].include?(cursor.kind)
          cursor =
            new_cursor!(
              stream,
              config,
              kind: "changes",
              position: cursor.position,
              high_water: stream.event_sequence,
            ).first if cursor.kind == "checkpoint"
          changes_page!(cursor, stream, config)
        end
      end
    end

    def content(source_id, revision, query = {})
      CmsProtocol.validate!("OpaqueId", source_id)
      CmsProtocol.validate!("Revision", revision)
      query = CmsProtocol.apply_defaults("ContentQuery", query)
      transaction do |config|
        stream = stream!(config)
        intent = stream.source_intents.find_by(source_id: source_id)
        CmsProtocol.reject!("resource_not_found") unless intent
        assert_current_source!(intent, config, "source_ineligible")
        stored = intent.source_revisions.find_by(source_revision: revision)
        CmsProtocol.reject!("revision_unavailable") unless stored
        metadata = stored.source_metadata
        bytes = stored.content_bytes_blob.b
        unless bytes.bytesize == metadata.fetch("content_bytes") &&
                 Digest::SHA256.hexdigest(bytes) == metadata.fetch("content_sha256")
          CmsProtocol.reject!("content_hash_mismatch")
        end
        offset = query.fetch("offset").to_i
        CmsProtocol.reject!("invalid_field") if offset > bytes.bytesize
        slice = bytes.byteslice(offset, CHUNK_BYTES) || "".b
        ending = offset + slice.bytesize
        body = {
          "source_id" => source_id,
          "source_revision" => revision,
          "content_sha256" => metadata.fetch("content_sha256"),
          "content_bytes" => bytes.bytesize,
          "offset" => offset,
          "next_offset" => ending == bytes.bytesize ? nil : ending,
          "content_base64" => Base64.strict_encode64(slice),
        }
        CmsProtocol.validate!("ContentChunk", body)
        CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 65_536
        Result.new(status: 200, body: body)
      end
    end

    # Shared receiver source-scope binding for root's admin/descriptor path.
    # Secret rotation is checked separately, never placed in a cursor payload.
    def scope_fingerprint(config, source_scope_revision: nil)
      value = [
        @connection.public_id,
        @connection.platform,
        @connection.allowed_origins,
        @connection.allowed_directions,
        @connection.allowed_lanes,
        config,
        SiteSetting.discussion_bridge_enabled,
        SiteSetting.discussion_bridge_endpoint_enabled,
        SiteSetting.discussion_bridge_publisher_enabled,
        SiteSetting.login_required,
        source_scope_revision,
      ]
      Digest::SHA256.hexdigest(CmsProtocol.semantic_identity(value))
    end

    # The private source tuple includes stable actual native creator ID. Do
    # not mix a later User lookup with an accepted native edition.
    def capture_snapshot(topic)
      transaction do |config|
        stream =
          DiscussionBridgeCmsSourceStream.find_by(
            content_connection_id: @connection.id,
            publication_lane: config.fetch("publication_lane"),
          )
        stream&.assert_mutation_capacity!
        capture_snapshot_locked(topic, config.fetch("policy"))
      end
    end

    def capture_snapshot_locked(topic, policy)
      topic.lock!
      first = Post.unscoped.where(topic_id: topic.id, post_number: 1).lock.first
      raise SourceEdition::Unavailable unless first && CmsConfiguration.eligible?(topic, policy)
      row =
        Post
          .unscoped
          .joins(topic: :category)
          .left_joins(:user)
          .where(id: first.id, deleted_at: nil)
          .where(topics: { deleted_at: nil }, categories: { read_restricted: false })
          .where.not(topics: { archetype: Archetype.private_message })
          .where.not(
            topic_id:
              DiscussionBridgeBridgeRecord
                .where(direction: "to_discourse")
                .where.not(topic_id: nil)
                .select(:topic_id),
          )
          .where.not(topic_id: SharedDraft.select(:topic_id))
          .where.not(id: TopicEmbed.with_deleted.select(:post_id))
          .pluck(*(SourceEdition::SOURCE_COLUMNS + ["users.id"]))
          .first
      raise SourceEdition::Unavailable unless row
      topic_id,
      title,
      slug,
      topic_created_at,
      post_id,
      post_number,
      version,
      created_at,
      updated_at,
      raw,
      cooked,
      username,
      username_lower,
      name,
      user_id =
        row
      # Native eligibility is independent of formatting or content type. Missing
      # supported render output is a Bridge limitation, never source exclusion
      # or a selected definition of truly absent native content.
      CmsProtocol.reject!("metadata_unavailable") if user_id.nil? || username.blank? || !cooked.is_a?(String) || cooked.empty?
      label = CmsConfiguration.forum_name!
      author_name = name.presence || username
      topic_url = Topic.url(topic_id, slug)
      time = ->(value) { value&.utc&.iso8601(6) }
      bytes = cooked.b
      unless bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        CmsProtocol.reject!("metadata_unavailable")
      end
      body_hash = Digest::SHA256.hexdigest(bytes)
      authors = [{ "id" => user_id.to_s, "name" => author_name }]
      # Deterministic private source encoding; actual creator ID is part of the
      # revision. The retained source edition tuple is private native state.
      edition =
        Digest::SHA256.hexdigest(
          JSON.generate(
            [
              "discussionbridge-cms-source-1",
              Discourse.base_url,
              label,
              topic_id.to_s,
              topic_url,
              title,
              time.call(topic_created_at),
              post_id.to_s,
              post_number,
              version,
              time.call(created_at),
              time.call(updated_at),
              raw,
              body_hash,
              bytes.bytesize,
              authors.map { |author| [author.fetch("id"), author.fetch("name")] },
            ],
          ),
        )
      metadata = {
        "source_id" => "topic:#{topic_id}",
        "source_revision" => edition,
        "topic_id" => topic_id.to_s,
        "topic_url" => topic_url,
        "title" => title,
        "content_sha256" => body_hash,
        "content_bytes" => bytes.bytesize,
        "source_created_at" => CmsProtocol.instant(created_at),
        "source_updated_at" => CmsProtocol.instant(updated_at),
        "source_authors" => authors,
      }
      CmsProtocol.validate!("Source", metadata)
      Snapshot.new(metadata: metadata, body: bytes)
    end

    private

    private :capture_snapshot_locked

    def now
      @clock.call
    end

    def transaction
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest && @connection.secret_digest != @authenticated_secret_digest
          CmsProtocol.reject!("authentication_failed")
        end
        config = CmsConfiguration.current!(@connection, require_enabled: true)
        yield config
      end
    end

    def stream!(config, create: false)
      scope =
        DiscussionBridgeCmsSourceStream.where(
          content_connection_id: @connection.id,
          publication_lane: config.fetch("publication_lane"),
        )
      stream = scope.lock.first
      stream ||= scope.create! if create
      CmsProtocol.reject!("native_service_unavailable") unless stream
      stream
    end

    def assert_scope_capacity!(stream)
      if stream.source_scope_revision >= CmsProtocol::MAX_COUNTER
        CmsProtocol.reject!("storage_exhausted")
      end
    end

    def refresh_topic_locked!(stream, config, topic_id)
      topic = Topic.unscoped.find_by(id: topic_id)
      intent = stream.source_intents.find_by(source_id: "topic:#{topic_id}")
      unless CmsConfiguration.eligible?(topic, config.fetch("policy"))
        revoke!(stream, intent, revocation_reason(topic, config.fetch("policy"))) if intent
        return intent
      end
      snapshot = capture_snapshot_locked(topic, config.fetch("policy"))
      CmsProtocol.validate!("Source", snapshot.metadata)
      unless snapshot.body.bytesize == snapshot.metadata.fetch("content_bytes") &&
               Digest::SHA256.hexdigest(snapshot.body) == snapshot.metadata.fetch("content_sha256")
        CmsProtocol.reject!("metadata_unavailable")
      end
      intent ||=
        stream.source_intents.create!(
          topic_id: topic.id,
          source_id: snapshot.metadata.fetch("source_id"),
          state: "active",
        )
      prior = intent.state
      revision = snapshot.metadata.fetch("source_revision")
      stored = intent.source_revisions.find_by(source_revision: revision)
      if stored
        unless stored.source_metadata == snapshot.metadata &&
                 stored.content_bytes_blob.b == snapshot.body
          CmsProtocol.reject!("revision_conflict")
        end
      else
        intent.source_revisions.create!(
          source_revision: revision,
          source_metadata: snapshot.metadata,
          content_bytes_blob: snapshot.body,
        )
      end
      if prior == "active" && intent.current_source_revision == revision && intent.publication_event
        return intent
      end
      bump_source_scope!(stream) if prior != "active"
      event = event!(stream, intent, "event_type" => "publication", "source" => snapshot.metadata)
      intent.update!(
        state: "active",
        attention_code: nil,
        current_source_revision: revision,
        publication_event: event,
      )
      intent
    rescue SourceEdition::Unavailable
      revoke!(stream, intent, "source_ineligible") if intent
      intent
    rescue CmsProtocol::Error, SourceEdition::InvalidForumName => error
      intent ||=
        stream.source_intents.create!(
          topic_id: topic_id,
          source_id: "topic:#{topic_id}",
          state: "attention",
        )
      bump_source_scope!(stream) if intent.state == "active"
      preserve = %w[revision_conflict storage_exhausted forum_configuration_invalid]
      code =
        (
          if error.respond_to?(:code) && preserve.include?(error.code)
            error.code
          else
            "metadata_unavailable"
          end
        )
      intent.update!(state: "attention", attention_code: code)
      intent
    end

    def revocation_reason(topic, policy)
      return "source_deleted" unless topic && topic.deleted_at.nil?
      return "policy_excluded" if policy.fetch("exclude_topic_ids").include?(topic.id.to_s)
      return "source_unpublished" if SharedDraft.exists?(topic_id: topic.id)
      "source_ineligible"
    end

    def revoke!(stream, intent, reason)
      return if intent.state == "revoked"
      bump_source_scope!(stream)
      event!(
        stream,
        intent,
        "event_type" => "revocation",
        "source_id" => intent.source_id,
        "last_source_revision" => intent.current_source_revision,
        "reason" => reason,
      )
      intent.update!(state: "revoked", attention_code: nil)
    end

    def bump_source_scope!(stream)
      if stream.source_scope_revision >= CmsProtocol::MAX_COUNTER
        CmsProtocol.reject!("storage_exhausted")
      end
      stream.update!(source_scope_revision: stream.source_scope_revision + 1)
    end

    def event!(stream, intent, fields)
      CmsProtocol.reject!("storage_exhausted") if stream.event_sequence >= MAX_SEQUENCE
      sequence = stream.event_sequence + 1
      payload = fields.merge("event_id" => SecureRandom.uuid, "event_sequence" => sequence.to_s)
      CmsProtocol.validate!("SourceEvent", payload)
      event =
        stream.source_events.create!(
          cms_source_intent: intent,
          event_id: payload.fetch("event_id"),
          event_sequence: sequence,
          payload: payload,
        )
      stream.update!(event_sequence: sequence)
      event
    end

    def cursor_signature(stream, config)
      scope_fingerprint(config, source_scope_revision: stream.source_scope_revision)
    end

    def new_cursor!(stream, config, kind:, high_water:, position: 0, root: nil, count: 0)
      token = SecureRandom.urlsafe_base64(32, false)
      cursor =
        stream.source_cursors.create!(
          kind: kind,
          token_digest: Digest::SHA256.hexdigest(token),
          scope_signature: cursor_signature(stream, config),
          policy_revision: config.fetch("policy").fetch("policy_revision"),
          high_water: high_water,
          position: position,
          snapshot_root: root,
          snapshot_count: count,
          expires_at: root ? root.expires_at : now + CURSOR_SECONDS,
        )
      [cursor, token]
    end

    def read_cursor!(token, stream, config)
      CmsProtocol.validate!("Cursor", token)
      cursor =
        DiscussionBridgeCmsSourceCursor.find_by(token_digest: Digest::SHA256.hexdigest(token))
      CmsProtocol.reject!("cursor_invalid") unless cursor
      unless cursor.cms_source_stream_id == stream.id &&
               stream.content_connection_id == @connection.id &&
               stream.publication_lane == config.fetch("publication_lane") &&
               cursor.scope_signature == cursor_signature(stream, config) &&
               cursor.policy_revision == config.fetch("policy").fetch("policy_revision")
        CmsProtocol.reject!("cursor_scope_changed")
      end
      CmsProtocol.reject!("cursor_expired") if cursor.invalidated_at || cursor.expires_at <= now
      cursor
    end

    def initial_snapshot!(stream, config)
      root = new_cursor!(stream, config, kind: "initial", high_water: stream.event_sequence).first
      relation =
        stream.source_intents.where(state: "active").order(Arel.sql('source_id COLLATE "C"'))
      offset = 0
      loop do
        batch = relation.offset(offset).limit(BATCH_SIZE).pluck(:publication_event_id)
        break if batch.empty?
        CmsProtocol.reject!("metadata_unavailable") if batch.any?(&:nil?)
        DiscussionBridgeCmsSourceSnapshotItem.insert_all!(
          batch.each_with_index.map do |event_id, index|
            { snapshot_root_id: root.id, cms_source_event_id: event_id, ordinal: offset + index }
          end,
        )
        offset += batch.size
      end
      root.update!(snapshot_count: offset)
      root
    end

    def initial_page!(cursor, stream, config)
      return cached_page!(cursor, config) if cursor.page_body
      root = cursor.snapshot_root || cursor
      rows =
        root
          .snapshot_items
          .where("ordinal >= ?", cursor.position)
          .order(:ordinal)
          .limit(BATCH_SIZE)
          .includes(:cms_source_event)
          .to_a
      items = bounded_items!(rows.map(&:cms_source_event), config)
      position = cursor.position + items.size
      next_token = nil
      checkpoint = nil
      if position < root.snapshot_count
        next_token =
          new_cursor!(
            stream,
            config,
            kind: "initial",
            high_water: root.high_water,
            position: position,
            root: root,
            count: root.snapshot_count,
          ).last
      else
        checkpoint =
          new_cursor!(
            stream,
            config,
            kind: "checkpoint",
            high_water: root.high_water,
            position: root.high_water,
          ).last
      end
      result = feed_result("initial", items, next_token, checkpoint)
      cursor.update!(page_body: result.body)
      result
    end

    def changes_page!(cursor, stream, config)
      return cached_page!(cursor, config) if cursor.page_body
      events =
        stream
          .source_events
          .where("event_sequence > ? AND event_sequence <= ?", cursor.position, cursor.high_water)
          .order(:event_sequence)
          .limit(BATCH_SIZE)
          .to_a
      items = bounded_items!(events, config)
      position =
        (
          if items.empty?
            cursor.high_water
          else
            items.last.fetch("event_sequence").to_i
          end
        )
      more =
        stream
          .source_events
          .where("event_sequence > ? AND event_sequence <= ?", position, cursor.high_water)
          .exists?
      position = cursor.high_water unless more
      next_token =
        (
          if more
            new_cursor!(
              stream,
              config,
              kind: "changes",
              high_water: cursor.high_water,
              position: position,
            ).last
          else
            nil
          end
        )
      checkpoint =
        new_cursor!(
          stream,
          config,
          kind: "checkpoint",
          high_water: cursor.high_water,
          position: position,
        ).last
      result = feed_result("changes", items, next_token, checkpoint)
      cursor.update!(page_body: result.body)
      result
    end

    def bounded_items!(events, config)
      items = []
      events.each do |event|
        if event.payload.fetch("event_type") == "publication"
          assert_current_source!(event.cms_source_intent, config, "cursor_scope_changed")
        end
        candidate = items + [event.payload]
        # Reserve the exact maximum token sizes and fixed envelope overhead.
        probe = {
          "stream" => "initial",
          "items" => candidate,
          "next_cursor" => "a" * 43,
          "checkpoint_cursor" => "a" * 43,
        }
        if JSON.generate(probe).bytesize > PAGE_BYTES
          CmsProtocol.reject!("metadata_unavailable") if items.empty?
          break
        end
        items = candidate
      end
      items
    end

    def assert_current_source!(intent, config, code)
      topic = Topic.unscoped.find_by(id: intent.topic_id)
      unless intent.state == "active" && CmsConfiguration.eligible?(topic, config.fetch("policy"))
        CmsProtocol.reject!(code)
      end
    end

    def cached_page!(cursor, config)
      cursor
        .page_body
        .fetch("items")
        .each do |item|
          next unless item.fetch("event_type") == "publication"
          intent =
            cursor.cms_source_stream.source_intents.find_by(
              source_id: item.fetch("source").fetch("source_id"),
            )
          CmsProtocol.reject!("cursor_scope_changed") unless intent
          assert_current_source!(intent, config, "cursor_scope_changed")
        end
      CmsProtocol.validate!("SourceFeed", cursor.page_body)
      Result.new(status: 200, body: cursor.page_body)
    end

    def feed_result(stream, items, next_cursor, checkpoint)
      body = {
        "stream" => stream,
        "items" => items,
        "next_cursor" => next_cursor,
        "checkpoint_cursor" => checkpoint,
      }
      CmsProtocol.validate!("SourceFeed", body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > PAGE_BYTES
      Result.new(status: 200, body: body)
    end
  end
end
