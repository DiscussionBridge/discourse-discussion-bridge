# frozen_string_literal: true

require "securerandom"
require "digest"

module DiscussionBridge
  # Native receiver authority mutation only. No source discovery, policy
  # selection translation, retry reset, CMS write or credential material audit.
  class CmsAuthorityLifecycle
    SCOPE_FIELDS = %w[enabled platform allowed_origins allowed_directions allowed_lanes].freeze
    CATALOG_CONFIGURATION_FIELDS = %w[profile destination_origin publication_lane].freeze
    ADMIN_FIELDS = %w[
      name
      platform
      author_user_id
      authorship_mode
      unmapped_author_policy
      generate_topic_toc
      default_category_id
      adapter_id
      adapter_version
      enabled
      allowed_origins
      allowed_directions
      allowed_lanes
    ].freeze
    # Root installs the exact catalog hook after its optional catalog loader.
    # The callable joins this clean connection's transaction; never after commit.
    class << self
      attr_accessor :catalog_invalidator
    end

    def self.admin_update!(connection_id:, attributes:, actor:, clock: -> { Time.current })
      administrator!(actor)
      unless attributes.is_a?(Hash) && (attributes.keys.map(&:to_s) - ADMIN_FIELDS).empty?
        raise ArgumentError, "Unknown native connection update attribute"
      end
      DiscussionBridgeContentConnection.transaction do
        connection =
          DiscussionBridgeContentConnection.lock.find(CmsSourceLifecycle.native_id!(connection_id))
        administrator!(actor) # Check actual actor again after the lock wait.
        connection.instance_variable_set(:@discussion_bridge_cms_scope_actor, actor)
        connection.instance_variable_set(:@discussion_bridge_cms_scope_clock, clock)
        begin
          connection.update!(attributes)
        ensure
          connection.remove_instance_variable(:@discussion_bridge_cms_scope_actor)
          connection.remove_instance_variable(:@discussion_bridge_cms_scope_clock)
        end
        connection
      end
    end

    # Called by the plugin-owned native connection before_update callback,
    # including while the plugin is off. Never lock!/reload the dirty caller.
    def self.before_scope_save!(record)
      fields = actual_write_fields(record) & SCOPE_FIELDS
      return nil if fields.empty?
      clean = record.class.lock.find(record.id)
      before = scope_facts(clean)
      after = before.deep_dup
      fields.each { |field| after[field] = record.public_send(field).deep_dup }
      changed = fields.select { |field| before[field] != after[field] }
      return nil if changed.empty?
      require_schema!

      if actual_write_fields(record).include?("cms_configuration") &&
           record.cms_configuration != clean.cms_configuration
        record.errors.add(
          :cms_configuration,
          "must be changed separately through native CMS configuration",
        )
        raise ActiveRecord::RecordInvalid, record
      end

      actor = record.instance_variable_get(:@discussion_bridge_cms_scope_actor)
      administrator!(actor) if actor
      clock =
        record.instance_variable_get(:@discussion_bridge_cms_scope_clock) || -> { Time.current }
      previous_revision, revision, revised = revised_configuration(clean.cms_configuration)
      # Scope changes retain the current stored selections, even when the
      # caller's untouched configuration is stale. Malformed trees stay exact.
      record.cms_configuration = revised unless revised == clean.cms_configuration
      state = scope_admits_selection?(after, revised) ? "superseded" : "cancelled"
      reason = after.fetch("enabled") ? "source_scope_changed" : "connection_disabled"
      invalidate!(clean, reason: reason, unfinished_state: state, clock: clock)
      scope_event!(
        clean,
        actor: actor,
        origin: actor ? "native_admin_scope_mutation" : "native_model_scope_mutation",
        reason: reason,
        fields: changed,
        before: before.slice(*changed),
        after: after.slice(*changed),
        previous_revision: previous_revision,
        revision: revision,
        clock: clock,
      )
      wake_after_commit(clean.id, clock: clock)
      nil
    end

    # Root calls this only once after its validated changed configure write,
    # inside the existing locked transaction. Existing configuration_events
    # remains the real admin audit; the exact no-op path never calls this method.
    def self.configuration_changed!(
      connection,
      previous_configuration:,
      actor:,
      clock: -> { Time.current },
      topic_selection_authorization: nil
    )
      if topic_selection_authorization
        topic_selection_authorization.authorize_configuration!(actor, connection,
          previous_configuration: previous_configuration, configuration: connection.cms_configuration)
      else
        administrator!(actor)
      end
      require_schema!
      connection.lock! # The just-saved configured native instance is CLEAN.
      configuration = connection.cms_configuration
      enabled = configuration.fetch("policy").fetch("enabled")
      invalidate!(
        connection,
        reason: "policy_changed",
        unfinished_state: enabled ? "superseded" : "cancelled",
        clock: clock,
        invalidate_catalog: catalog_configuration_changed?(previous_configuration, configuration),
      )
      wake_after_commit(connection.id, clock: clock)
      nil
    end

    def self.administrator!(actor)
      valid = actor.is_a?(User) && actor.persisted? && actor.id.positive?
      actor.reload if valid
      valid &&= actor.admin? && actor.active? && !actor.staged? && !actor.suspended?
      raise Discourse::InvalidAccess unless valid
      true
    rescue ActiveRecord::RecordNotFound
      raise Discourse::InvalidAccess
    end

    # Root may inspect this only for boot/migration orchestration. Ordinary
    # installed mutations require the complete private schema; no silent skip.
    def self.schema_ready?
      DiscussionBridgeCmsScopeEvent.table_exists? &&
        DiscussionBridgeCmsSourceCursor.column_names.include?("invalidated_at") &&
        DiscussionBridgeCmsReadSnapshot.column_names.include?("invalidated_at")
    end

    def self.require_schema!
      CmsProtocol.reject!("native_service_unavailable") unless schema_ready?
    end

    def self.actual_write_fields(record)
      record.class.partial_updates? ? record.changes_to_save.keys : record.attribute_names
    end

    def self.scope_facts(record)
      SCOPE_FIELDS.to_h { |field| [field, record.public_send(field).deep_dup] }
    end

    def self.revised_configuration(configuration)
      return nil, nil, configuration unless typed_stored_configuration?(configuration)
      previous = configuration.fetch("policy").fetch("policy_revision")
      revision = SecureRandom.uuid
      revised = configuration.deep_dup
      revised.fetch("policy")["policy_revision"] = revision
      [previous, revision, revised]
    end

    def self.typed_stored_configuration?(configuration)
      unless configuration.is_a?(Hash) && configuration.keys.sort == CmsConfiguration::FIELDS.sort
        return false
      end
      {
        "profile" => "CmsProfile",
        "destination_origin" => "Url",
        "publication_lane" => "Lane",
        "native_capabilities" => "NativeCapabilities",
        "policy" => "Policy",
      }.each { |field, type| CmsProtocol.validate!(type, configuration.fetch(field)) }
      true
    rescue CmsProtocol::Error, KeyError
      false
    end

    def self.scope_admits_selection?(scope, configuration)
      return false unless scope.fetch("enabled") && typed_stored_configuration?(configuration)
      unless configuration.fetch("policy").fetch("enabled") && CmsSourceLifecycle.globally_enabled?
        return false
      end
      profile = configuration.fetch("profile")
      platform = profile.start_with?("statamic_") ? "statamic" : profile
      scope.fetch("platform") == platform &&
        scope.fetch("allowed_directions").include?("from_discourse") &&
        scope.fetch("allowed_origins").include?(
          CmsProtocol.url_key(configuration.fetch("destination_origin")).delete_suffix("/"),
        ) && scope.fetch("allowed_lanes").include?(configuration.fetch("publication_lane"))
    end

    def self.catalog_configuration_changed?(previous, current)
      return true unless previous.is_a?(Hash)
      CATALOG_CONFIGURATION_FIELDS.any? { |field| previous[field] != current.fetch(field) }
    end

    def self.invalidate!(
      connection,
      reason:,
      unfinished_state: "cancelled",
      clock:,
      invalidate_catalog: true
    )
      CmsSourceLifecycle.invalidate_connection!(
        connection,
        reason: reason,
        unfinished_state: unfinished_state,
        clock: clock,
      )
      invalidate_read_authority!(connection, clock: clock)
      catalog_invalidator&.call(connection, clock: clock) if invalidate_catalog
    end

    def self.invalidate_read_authority!(connection, clock:)
      at = clock.call
      DiscussionBridgeCmsReadSnapshot.where(content_connection_id: connection.id).update_all(
        expires_at: at,
        invalidated_at: at,
      )
      DiscussionBridgeCmsSourceCursor
        .joins(:cms_source_stream)
        .where(discussion_bridge_cms_source_streams: { content_connection_id: connection.id })
        .update_all(expires_at: at, invalidated_at: at, updated_at: at)
    end

    def self.scope_event!(
      connection,
      actor:,
      origin:,
      reason:,
      fields:,
      before:,
      after:,
      previous_revision:,
      revision:,
      clock:
    )
      DiscussionBridgeCmsScopeEvent.create!(
        content_connection_id: connection.id,
        actor_user_id: actor&.id,
        event_origin: origin,
        reason: reason,
        changed_fields: fields,
        previous_values: before,
        values: after,
        previous_policy_revision: previous_revision,
        policy_revision: revision,
        created_at: clock.call,
      )
    end

    def self.wake_after_commit(connection_id, clock:)
      id = connection_id.to_s
      DB.after_commit { CmsSourceLifecycle.wake_connection(id, clock: clock) }
    end

    private_class_method :actual_write_fields,
                         :scope_facts,
                         :revised_configuration,
                         :typed_stored_configuration?,
                         :scope_admits_selection?,
                         :catalog_configuration_changed?,
                         :invalidate!,
                         :invalidate_read_authority!,
                         :scope_event!,
                         :wake_after_commit,
                         :require_schema!
  end
end
