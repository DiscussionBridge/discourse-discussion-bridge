# frozen_string_literal: true

module DiscussionBridge
  class CmsSourceLifecycle
    Result = Data.define(:state, :processed_count, :continuation, :error_code, :source_intent)
    DISPATCH_SECONDS = 60
    FULL_SCAN_COOLDOWN = 300
    BATCH_SIZE = CmsSourceStore::BATCH_SIZE
    INVALIDATION_REASONS = %w[
      policy_changed
      connection_disabled
      scope_denied
      authentication_failed
      secret_rotated
      plugin_disabled
      endpoint_disabled
      publisher_disabled
      login_required
      source_scope_changed
      forum_configuration_invalid
      catalog_entry_unavailable
      storage_exhausted
    ].freeze
    ATTENTION_CODES = %w[
      metadata_unavailable
      forum_configuration_invalid
      catalog_entry_unavailable
      storage_exhausted
      native_service_unavailable
      revision_conflict
      native_ownership_conflict
    ].freeze

    def self.refresh(connection, topic_id, **options)
      new(connection, **options).refresh(topic_id)
    end

    def self.run_batch(connection_id, **options)
      connection = DiscussionBridgeContentConnection.find_by(id: native_id!(connection_id))
      return inactive_result unless connection
      new(connection, **options).run_batch
    end

    def self.wake_connection(connection_id, topic_id: nil, **options)
      connection = DiscussionBridgeContentConnection.find_by(id: native_id!(connection_id))
      return false unless connection
      new(connection, **options).wake(topic_id: topic_id)
    end

    # Root calls this inside its connection-locked native mutation. Nested
    # transactions join that same commit; invalidation must not follow it later.
    # Root owns policy-revision minting and the native actor/configuration audit.
    def self.invalidate_connection!(
      connection,
      reason:,
      unfinished_state: "cancelled",
      invalidate_scope: true,
      clock: -> { Time.current }
    )
      reason = reason.to_s
      unless INVALIDATION_REASONS.include?(reason) &&
               %w[cancelled superseded].include?(unfinished_state)
        raise ArgumentError, "Invalid receiver CMS invalidation"
      end
      DiscussionBridgeContentConnection.transaction do
        connection.lock!
        at = clock.call
        cancellation = {
          state: unfinished_state,
          lease_verifier: nil,
          lease_expires_at: nil,
          retry_at: nil,
          updated_at: at,
        }
        if %w[plugin_disabled endpoint_disabled publisher_disabled].include?(reason)
          cancellation[:same_intent_hold] = true
        end
        DiscussionBridgeCmsWork
          .joins(:cms_mapping)
          .where(
            discussion_bridge_cms_mappings: {
              content_connection_id: connection.id,
            },
            state: DiscussionBridgeCmsWork::UNCOMPLETED_STATES,
          )
          .update_all(cancellation)
        DiscussionBridgeCmsMapping
          .where(content_connection_id: connection.id)
          .where.not(mapping_state: "withdrawn")
          .update_all(mapping_state: "attention", updated_at: at)
        if invalidate_scope
          DiscussionBridgeCmsReadSnapshot.where(content_connection_id: connection.id).update_all(
            expires_at: at,
            invalidated_at: at,
          )
        end
        DiscussionBridgeCmsSourceStream
          .where(content_connection_id: connection.id)
          .find_each do |stream|
            stream.lock!
            code = reason
            if invalidate_scope
              if stream.source_scope_revision >= CmsProtocol::MAX_COUNTER
                code = "storage_exhausted"
              else
                stream.source_scope_revision += 1
              end
              # Explicit expiry also preserves invalidity when a counter cannot
              # advance. Restoration cannot resurrect these retained tokens.
              stream.source_cursors.update_all(expires_at: at, invalidated_at: at, updated_at: at)
            end
            stream.update!(
              scan_state: "uninitialized",
              scan_phase: "topics",
              scan_scope_signature: nil,
              scan_high_topic_id: nil,
              scan_last_topic_id: 0,
              scan_high_intent_id: nil,
              scan_last_intent_id: 0,
              scan_completed_at: nil,
              lifecycle_error_code: code,
              lifecycle_failed_at: at,
            )
          end
      end
      true
    end

    def self.invalidate_global!(reason:, **options)
      count = 0
      DiscussionBridgeContentConnection
        .where.not(cms_configuration: nil)
        .find_each(batch_size: BATCH_SIZE) do |connection|
          invalidate_connection!(connection, reason: reason, **options)
          count += 1
        end
      count
    end

    def self.maintenance(clock: -> { Time.current }, enqueuer: nil)
      return 0 if Discourse.readonly_mode?
      return 0 unless globally_enabled?
      count = 0
      DiscussionBridgeContentConnection
        .where(enabled: true)
        .where.not(cms_configuration: nil)
        .find_each(batch_size: BATCH_SIZE) do |connection|
          lifecycle = new(connection, clock: clock, enqueuer: enqueuer)
          count += 1 if lifecycle.wake_if_due
        end
      count
    end

    def self.globally_enabled?
      SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
        SiteSetting.discussion_bridge_publisher_enabled
    end

    def self.native_id!(value)
      text = value.to_s if value.is_a?(Integer) || value.is_a?(String)
      unless text && text.match?(/\A[1-9][0-9]*\z/) && text.length <= 19 &&
               text.to_i <= 9_223_372_036_854_775_807
        raise ArgumentError, "Invalid native CMS identity"
      end
      text.to_i
    end

    def self.inactive_result
      Result.new(
        state: "inactive",
        processed_count: 0,
        continuation: false,
        error_code: nil,
        source_intent: nil,
      )
    end

    def initialize(connection, clock: -> { Time.current }, enqueuer: nil, on_intent: nil)
      @connection = connection
      @clock = clock
      @enqueuer = enqueuer || ->(args) { Jobs.enqueue(:discussion_bridge_cms_source_batch, args) }
      @on_intent = on_intent || method(:reconcile_intent!)
      @store = CmsSourceStore.new(connection, clock: clock)
    end

    def refresh(topic_id)
      return self.class.inactive_result if Discourse.readonly_mode?
      id = self.class.native_id!(topic_id)
      with_configuration do |_config|
        intent = @store.refresh_topic!(id, on_intent: @on_intent)
        code = update_stream_error!
        result(
          state: code ? "attention" : "refreshed",
          processed_count: 1,
          error_code: code,
          source_intent: intent,
        )
      end
    rescue CmsProtocol::Error => error
      handle_error(error)
    end

    def run_batch
      return self.class.inactive_result if Discourse.readonly_mode?
      value =
        with_configuration do |_config|
          batch = @store.refresh_batch!(on_intent: @on_intent)
          code = update_stream_error!
          result(
            state: code ? "attention" : batch.complete ? "complete" : "scanning",
            processed_count: batch.processed_count,
            continuation: !batch.complete && code != "storage_exhausted",
            error_code: code,
          )
        end
      wake if value.continuation
      value
    rescue CmsProtocol::Error => error
      handle_error(error)
    end

    def wake(topic_id: nil)
      return false if Discourse.readonly_mode?
      id = self.class.native_id!(topic_id) unless topic_id.nil?
      with_configuration do |config|
        stream = stream_for(config)
        if stream &&
             (
               stream.lifecycle_error_code == "storage_exhausted" ||
                 stream.source_scope_revision >= CmsProtocol::MAX_COUNTER
             )
          return false
        end
        args = { connection_id: @connection.id.to_s }
        args[:topic_id] = id.to_s if id
        DB.after_commit { @enqueuer.call(args) }
        true
      end
    rescue CmsProtocol::Error => error
      handle_error(error)
      false
    end

    def wake_if_due
      return false if Discourse.readonly_mode?
      with_configuration do |config|
        stream = stream_for(config)
        if stream &&
             (
               stream.lifecycle_error_code == "storage_exhausted" ||
                 stream.source_scope_revision >= CmsProtocol::MAX_COUNTER
             )
          return false
        end
        due =
          !stream || stream.scan_state != "complete" ||
            stream.scan_scope_signature != @store.scope_fingerprint(config) ||
            !stream.scan_completed_at || stream.scan_completed_at <= now - FULL_SCAN_COOLDOWN
        return false unless due
        DB.after_commit { @enqueuer.call({ connection_id: @connection.id.to_s }) }
        true
      end
    rescue CmsProtocol::Error => error
      handle_error(error)
      false
    end

    private

    def now
      @clock.call
    end

    def result(state:, processed_count: 0, continuation: false, error_code: nil, source_intent: nil)
      Result.new(
        state: state,
        processed_count: processed_count,
        continuation: continuation,
        error_code: error_code,
        source_intent: source_intent,
      )
    end

    def with_configuration
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        config = CmsConfiguration.current!(@connection, require_enabled: true)
        yield config
      end
    end

    def stream_for(config)
      DiscussionBridgeCmsSourceStream.find_by(
        content_connection_id: @connection.id,
        publication_lane: config.fetch("publication_lane"),
      )
    end

    def update_stream_error!
      config = CmsConfiguration.current!(@connection, require_enabled: true)
      stream = stream_for(config)
      code = stream.source_intents.where(state: "attention").order(:id).pick(:attention_code)
      code ||=
        CmsCatalogAvailabilityLifecycle.selection_issue(@connection, configuration: config).code
      stream.update!(lifecycle_error_code: code, lifecycle_failed_at: code ? now : nil)
      code
    end

    def reconcile_intent!(intent, config)
      mapping =
        DiscussionBridgeCmsMapping.find_by(
          content_connection_id: @connection.id,
          source_id: intent.source_id,
        )
      return unless mapping
      mapping.lock!
      if intent.state == "active"
        issue = CmsCatalogAvailabilityLifecycle.selection_issue(@connection, configuration: config)
        if issue.code
          attention_mapping!(mapping, issue.code)
          return
        end
        revision = intent.source_revisions.find_by!(source_revision: intent.current_source_revision)
        CmsWorkCoordinator.new(@connection, clock: @clock).enqueue!(
          mapping,
          source_snapshot: revision.source_metadata,
        )
      elsif intent.state == "revoked"
        cancel_publish!(mapping, "cancelled")
        unless mapping.destination_native_id
          mapping.update!(mapping_state: "attention") unless mapping.mapping_state == "withdrawn"
          return
        end
        CmsWorkCoordinator.new(@connection, clock: @clock).enqueue!(
          mapping,
          source_snapshot: nil,
          action: "withdraw",
        )
      else
        attention_mapping!(mapping, intent.attention_code || "metadata_unavailable")
      end
    rescue CmsProtocol::Error => error
      attention_mapping!(mapping, error.code) if mapping
    end

    def cancel_publish!(mapping, state)
      mapping
        .work_items
        .where(action: "publish_revision", state: DiscussionBridgeCmsWork::UNCOMPLETED_STATES)
        .update_all(
          state: state,
          lease_verifier: nil,
          lease_expires_at: nil,
          retry_at: nil,
          updated_at: now,
        )
    end

    def attention_mapping!(mapping, code)
      safe = ATTENTION_CODES.include?(code) ? code : "native_ownership_conflict"
      config = CmsConfiguration.current!(@connection)
      binding = mapping.content_binding
      record = binding.bridge_record
      unless binding.content_connection_id == @connection.id && binding.role == "presentation" &&
               binding.state == "active" && record.direction == "from_discourse" &&
               record.lane.to_s == config.fetch("publication_lane")
        return
      end
      CmsConfiguration.destination_url!(@connection, config, binding.canonical_url)
      mapping
        .work_items
        .where(
          action: "publish_revision",
          state: DiscussionBridgeCmsWork::LIVE_STATES,
          policy_revision: config.fetch("policy").fetch("policy_revision"),
        )
        .find_each do |work|
          CmsWorkCoordinator.new(@connection, clock: @clock).fail_receiver_publication!(
            work,
            code: safe,
          )
        end
      mapping.update!(mapping_state: "attention") unless mapping.mapping_state == "withdrawn"
    end

    def handle_error(error)
      code = error.code
      if ATTENTION_CODES.include?(code)
        DiscussionBridgeContentConnection.transaction do
          @connection.lock!
          config = CmsConfiguration.current!(@connection)
          if config.fetch("policy").fetch("enabled") && self.class.globally_enabled?
            stream =
              stream_for(config) ||
                DiscussionBridgeCmsSourceStream.create!(
                  content_connection_id: @connection.id,
                  publication_lane: config.fetch("publication_lane"),
                )
            stream.update!(lifecycle_error_code: code, lifecycle_failed_at: now)
            DiscussionBridgeCmsMapping
              .where(content_connection_id: @connection.id)
              .find_each { |mapping| attention_mapping!(mapping, code) }
          end
        end
        result(state: "attention", error_code: code)
      else
        result(state: "inactive", error_code: code)
      end
    rescue CmsProtocol::Error
      result(state: "inactive", error_code: code)
    end
  end
end
