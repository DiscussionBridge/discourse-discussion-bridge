# frozen_string_literal: true

require "securerandom"

module DiscussionBridge
  class CmsAuthorityStore
    Result = Data.define(:status, :body)
    WRITE_FIELDS = %w[expected_policy_revision configuration].freeze

    def initialize(connection, authenticated_secret_digest: nil, clock: -> { Time.current })
      @connection = connection
      @authenticated_secret_digest = authenticated_secret_digest
      @clock = clock
    end

    # Read descriptors even while publication is off. This grants neither From
    # scope to a To-only connection nor native capability qualification.
    def descriptor
      read_descriptor do |configuration|
        stream =
          DiscussionBridgeCmsSourceStream.find_by(
            content_connection_id: @connection.id,
            publication_lane: configuration.fetch("publication_lane"),
          )
        body = {
          "connection_id" => @connection.public_id,
          "profile" => configuration.fetch("profile"),
          "destination_origin" => configuration.fetch("destination_origin"),
          "scope_revision" =>
            CmsSourceStore.new(@connection).scope_fingerprint(
              configuration,
              source_scope_revision: stream&.source_scope_revision || 0,
            ),
          "forum_name" => CmsConfiguration.forum_name!,
          "directions" => @connection.allowed_directions,
          "policy" => configuration.fetch("policy"),
          "publication_lane" => configuration.fetch("publication_lane"),
          "native_capabilities" => configuration.fetch("native_capabilities"),
        }
        response("Connection", body)
      end
    end

    def publication_policy
      read_descriptor { |configuration| response("Policy", configuration.fetch("policy")) }
    end

    # Native administration may inspect an off/disabled or scope-stale stored
    # configuration for reconciliation; no adapter authorization is derived here.
    def administrative_configuration(actor:)
      administrator!(actor)
      @connection.reload
      configuration = @connection.cms_configuration
      validate_stored_shape!(configuration) if configuration
      administrative_response(configuration)
    end

    def configure!(actor:, input:)
      administrator!(actor)
      validate_write!(input)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        administrator!(actor)
        previous = @connection.cms_configuration&.deep_dup
        validate_stored_shape!(previous) if previous
        previous_revision = previous&.dig("policy", "policy_revision")
        unless input.fetch("expected_policy_revision") == previous_revision
          CmsProtocol.reject!("revision_conflict")
        end

        configuration = input.fetch("configuration").deep_dup
        policy = configuration.fetch("policy")
        policy["policy_revision"] = previous_revision || SecureRandom.uuid
        CmsConfiguration.validate!(@connection, configuration)
        if policy.fetch("enabled") && !@connection.allows_direction?("from_discourse")
          CmsProtocol.reject!("scope_denied")
        end

        # Exact unchanged native writes do not reset work, mint revisions or
        # generate misleading extra audit events. Caller never sets revision.
        same_configuration = previous && CmsProtocol.semantic_identity(previous) == CmsProtocol.semantic_identity(configuration)
        if same_configuration
          next administrative_response(previous)
        end
        policy["policy_revision"] = SecureRandom.uuid
        administrative_response(configuration) # Bound output before committing.
        @connection.update!(cms_configuration: configuration)
        CmsAuthorityLifecycle.configuration_changed!(
          @connection,
          previous_configuration: previous,
          actor: actor,
          clock: @clock,
        )
        audit!(actor, previous, configuration)
        administrative_response(configuration)
      end
    end

    # Separate narrow native operation; the general administrative writer above
    # continues to require an administrator. No arbitrary support configuration
    # body is accepted. Only the named topic's include/exclude entries change.
    def select_support_topic!(actor:, topic:, selected:, authorization:)
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        authorization.call(actor, @connection)
        previous = CmsConfiguration.current!(@connection, require_enabled: true).deep_dup
        configuration = SupportTopicSelection.configuration(previous, topic.id.to_s, selected: selected)
        authorization.authorize_configuration!(actor, @connection,
          previous_configuration: previous, configuration: configuration)
        next Result.new(status: 200, body: { selected: selected }) if configuration == previous
        configuration.fetch("policy")["policy_revision"] = SecureRandom.uuid
        CmsConfiguration.validate!(@connection, configuration)
        @connection.update!(cms_configuration: configuration)
        CmsAuthorityLifecycle.configuration_changed!(@connection,
          previous_configuration: previous, actor: actor, clock: @clock,
          topic_selection_authorization: authorization)
        audit!(actor, previous, configuration)
        Result.new(status: 200, body: { selected: selected })
      end
    end

    private

    def read_descriptor
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest &&
             !ActiveSupport::SecurityUtils.secure_compare(
               @connection.secret_digest,
               @authenticated_secret_digest,
             )
          CmsProtocol.reject!("authentication_failed")
        end
        configuration = CmsConfiguration.current!(@connection, required_direction: nil)
        yield configuration
      end
    end

    def administrator!(actor)
      valid = actor.is_a?(User) && actor.persisted? && actor.id.positive?
      actor.reload if valid
      valid &&= actor.admin? && actor.active? && !actor.staged? && !actor.suspended?
      raise Discourse::InvalidAccess unless valid
    rescue ActiveRecord::RecordNotFound
      raise Discourse::InvalidAccess
    end

    def validate_write!(input)
      CmsProtocol.reject!("invalid_field") unless input.is_a?(Hash)
      CmsProtocol.reject!("unknown_field") if (input.keys - WRITE_FIELDS).any?
      CmsProtocol.reject!("invalid_field") unless WRITE_FIELDS.all? { |field| input.key?(field) }
      expected = input.fetch("expected_policy_revision")
      CmsProtocol.validate!("Revision", expected) unless expected.nil?
      configuration = input.fetch("configuration")
      CmsProtocol.reject!("invalid_field") unless configuration.is_a?(Hash)
      CmsProtocol.reject!("unknown_field") if (configuration.keys - CmsConfiguration::FIELDS).any?
      unless CmsConfiguration::FIELDS.all? { |field| configuration.key?(field) }
        CmsProtocol.reject!("invalid_field")
      end
      policy = configuration.fetch("policy")
      CmsProtocol.reject!("invalid_field") unless policy.is_a?(Hash)
      CmsProtocol.reject!("unknown_field") if policy.key?("policy_revision")
    end

    def validate_stored_shape!(configuration)
      CmsProtocol.reject!("invalid_field") unless configuration.is_a?(Hash)
      CmsProtocol.reject!("unknown_field") if (configuration.keys - CmsConfiguration::FIELDS).any?
      unless CmsConfiguration::FIELDS.all? { |field| configuration.key?(field) }
        CmsProtocol.reject!("invalid_field")
      end
      {
        "profile" => "CmsProfile",
        "destination_origin" => "Url",
        "publication_lane" => "Lane",
        "native_capabilities" => "NativeCapabilities",
        "policy" => "Policy",
      }.each { |field, type| CmsProtocol.validate!(type, configuration.fetch(field)) }
    end

    def response(type, body)
      CmsProtocol.validate!(type, body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 262_144
      Result.new(status: 200, body: body.deep_dup)
    end

    def administrative_response(configuration)
      body = { "cms_configuration" => configuration&.deep_dup }
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 262_144
      Result.new(status: 200, body: body)
    end
    def audit!(actor, previous, configuration)
      DB.exec(
        <<~SQL,
        INSERT INTO discussion_bridge_cms_configuration_events
          (content_connection_id, actor_user_id, previous_policy_revision, policy_revision,
           previous_configuration, configuration, created_at)
        VALUES
          (:content_connection_id, :actor_user_id, :previous_policy_revision, :policy_revision,
            :previous_configuration::jsonb, :configuration::jsonb, :created_at)
      SQL
        content_connection_id: @connection.id,
        actor_user_id: actor.id,
        previous_policy_revision: previous&.dig("policy", "policy_revision"),
        policy_revision: configuration.fetch("policy").fetch("policy_revision"),
        previous_configuration: previous && JSON.generate(previous),
        configuration: JSON.generate(configuration),
        created_at: @clock.call,
      )
    end
  end
end
