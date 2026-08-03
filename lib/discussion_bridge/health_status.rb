# frozen_string_literal: true

module DiscussionBridge
  class HealthStatus
    STATES = %w[reserved complete failed].freeze

    def self.call
      new.call
    end

    def call
      actor = configured_actor
      authority = configured_authority(actor)
      blockers = readiness_blockers(actor, authority)

      {
        features: feature_status,
        connection: connection_status,
        lane_policies: lane_policy_status,
        operating_identity: actor_status(actor),
        forum_authority: authority_status(authority),
        mappings: mapping_status,
        audits: audit_status,
        readiness: {
          controlled_creation_ready: blockers.empty?,
          blockers: blockers,
        },
      }
    end

    private

    def feature_status
      {
        plugin_enabled: SiteSetting.discussion_bridge_enabled,
        endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
        comments_only_full_interactive: SiteSetting.discussion_bridge_comments_only_full_interactive,
        core_zero_touch_compatibility: SiteSetting.discussion_bridge_core_zero_touch_compatibility,
      }
    end

    def connection_status
      {
        connection_id_configured: SiteSetting.discussion_bridge_connection_id.present?,
        credential_configured: SiteSetting.discussion_bridge_connection_secret.present?,
        trusted_origins: list_values(SiteSetting.discussion_bridge_trusted_origins),
      }
    end

    def configured_actor
      username = SiteSetting.discussion_bridge_service_username.to_s.strip
      User.find_by(username_lower: username.downcase) if username.present?
    end

    def lane_policy_status
      policies = LanePolicies.parse(SiteSetting.discussion_bridge_lane_policies)
      {
        configured: policies.any?,
        count: policies.length,
        lanes: policies.map { |policy| policy[:lane] },
        valid: true,
      }
    rescue LanePolicies::ParseError
      { configured: true, count: 0, lanes: [], valid: false }
    end

    def actor_status(actor)
      {
        configured_username: SiteSetting.discussion_bridge_service_username.presence,
        found: actor.present?,
        id: actor&.id,
        username: actor&.username,
        active: actor&.active? || false,
        staged: actor&.staged? || false,
        suspended: actor&.suspended? || false,
        silenced: actor&.silenced? || false,
        system: actor&.id == Discourse::SYSTEM_USER_ID,
        admin: actor&.admin? || false,
        moderator: actor&.moderator? || false,
      }
    end

    def configured_authority(actor)
      return unless actor

      ForumAuthority.call(
        actor: actor,
        category_id: SiteSetting.discussion_bridge_effective_category_id,
        tags: SiteSetting.discussion_bridge_effective_tags,
      )
    end

    def authority_status(authority)
      category = Category.find_by(id: SiteSetting.discussion_bridge_effective_category_id.to_i)
      configured_tags = list_values(SiteSetting.discussion_bridge_effective_tags)

      {
        allowed: authority&.allowed? || false,
        reason: authority&.reason || "invalid_actor",
        category_id: category&.id,
        category_name: category&.name,
        configured_tags: configured_tags,
        missing_tags: configured_tags - Tag.where(name: configured_tags).pluck(:name),
      }
    end

    def mapping_status
      grouped = DiscussionBridgeConnection.group(:state).count
      counts = STATES.to_h { |state| [state, grouped.fetch(state, 0)] }
      counts.merge(
        total: grouped.values.sum,
        system_authored: DiscussionBridgeConnection.where(effective_actor_id: Discourse::SYSTEM_USER_ID).count,
      )
    end

    def audit_status
      {
        total: DiscussionBridgeAuditEvent.count,
        outcomes: DiscussionBridgeAuditEvent.group(:outcome).count,
        reasons: DiscussionBridgeAuditEvent.group(:reason).count,
      }
    end

    def readiness_blockers(actor, authority)
      blockers = []
      blockers << "plugin_disabled" unless SiteSetting.discussion_bridge_enabled
      blockers << "endpoint_disabled" unless SiteSetting.discussion_bridge_endpoint_enabled
      blockers << "connection_id_missing" if SiteSetting.discussion_bridge_connection_id.blank?
      blockers << "credential_missing" if SiteSetting.discussion_bridge_connection_secret.blank?
      blockers << "trusted_origins_missing" if SiteSetting.discussion_bridge_trusted_origins.blank?
      blockers << "invalid_actor" unless valid_actor?(actor)
      blockers << "lane_policy_invalid" unless lane_policy_status[:valid]
      blockers << (authority&.reason || "authorization_incomplete") unless authority&.allowed?
      blockers.uniq
    end

    def valid_actor?(actor)
      actor && actor.active? && !actor.staged? && !actor.suspended? && !actor.silenced? &&
        actor.id != Discourse::SYSTEM_USER_ID
    end

    def list_values(value)
      values = value.is_a?(String) ? value.split("|") : Array(value)
      values.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end
  end
end
