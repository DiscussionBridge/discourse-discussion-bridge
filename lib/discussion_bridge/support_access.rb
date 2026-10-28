# frozen_string_literal: true

module DiscussionBridge
  # This local grant never alters native User staff/admin/group permissions.
  # Every action and revocation serializes on the same singleton row.
  module SupportAccess
    ACTIONS = %w[status check retry select_topic synchronize].freeze

    def self.native_user!(actor)
      valid = actor.is_a?(User) && actor.persisted? && actor.id.positive?
      actor.reload if valid
      valid &&= actor.active? && !actor.staged? && !actor.suspended? && !actor.silenced?
      raise Discourse::InvalidAccess unless valid
      actor
    rescue ActiveRecord::RecordNotFound
      raise Discourse::InvalidAccess
    end

    def self.locked
      DiscussionBridgeSupportState.transaction do
        state = DiscussionBridgeSupportState.lock.find(1)
        yield state
      end
    end

    def self.operator!(actor, state:, action:, connection: nil)
      raise Discourse::InvalidAccess unless ACTIONS.include?(action)
      native_user!(actor)
      unless SiteSetting.discussion_bridge_enabled && state.reload.enabled &&
               DiscussionBridgeSupportGrant.active.exists?(user_id: actor.id)
        raise Discourse::InvalidAccess
      end
      if connection
        connection.reload
        CmsConfiguration.current!(connection, require_enabled: action != "status")
      end
      true
    end

    def self.audit!(actor, action, details = {})
      # Native UserHistory stores the actual actor for both admin and operator.
      # Do not put contact details, request text, connection credentials or raw
      # diagnostic payloads in the staff action log.
      StaffActionLogger.new(actor).log_custom(
        "discussion_bridge_support",
        details.merge(action: action),
      )
    end

    class Authorization
      def initialize(actor:, state:, connection:, action:, topic: nil)
        @actor, @state, @connection, @action, @topic = actor, state, connection, action, topic
      end

      def call(actor, connection)
        raise Discourse::InvalidAccess unless actor.id == @actor.id && connection.id == @connection.id
        SupportAccess.operator!(actor, state: @state, connection: connection, action: @action)
        if @topic
          @topic.reload
          actor.guardian.ensure_can_see!(@topic)
          policy = CmsConfiguration.current!(connection, require_enabled: true).fetch("policy")
          unless SourceEdition.publicly_available?(@topic) && SupportTopicSelection.source_in_scope?(@topic, policy)
            raise Discourse::InvalidAccess
          end
        end
        true
      end

      def authorize_topic!(actor, topic)
        call(actor, @connection)
        actor.guardian.ensure_can_see!(topic)
        policy = CmsConfiguration.current!(@connection, require_enabled: true).fetch("policy")
        unless SourceEdition.publicly_available?(topic) && SupportTopicSelection.source_in_scope?(topic, policy)
          raise Discourse::InvalidAccess
        end
      end

      def authorize_configuration!(actor, connection, previous_configuration:, configuration:)
        raise Discourse::InvalidAccess unless @action == "select_topic" && @topic
        call(actor, connection)
        SupportTopicSelection.validate_change!(previous_configuration, configuration, @topic.id.to_s)
      end
    end
  end
end
