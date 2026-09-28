# frozen_string_literal: true

module DiscussionBridge
  class VerifiedUrlMigrator
    Result = Data.define(:record, :outcome, :redirect_status)

    CONFIGURATION = {
      "source" => {
        direction: "to_discourse",
        history: "DiscussionBridgeSourceUrlHistory",
      },
      "presentation" => {
        direction: "from_discourse",
        history: "DiscussionBridgePresentationUrlHistory",
      },
    }.freeze

    def self.call(user:, resource_id:, role:, old_url:, new_url:, external_id:,
                  native_identity_confirmed:, cross_origin_approved: false,
                  verifier: PublicationRedirectVerifier)
      new(
        user: user,
        resource_id: resource_id,
        role: role,
        old_url: old_url,
        new_url: new_url,
        external_id: external_id,
        native_identity_confirmed: native_identity_confirmed,
        cross_origin_approved: cross_origin_approved,
        verifier: verifier,
      ).call
    end

    def initialize(user:, resource_id:, role:, old_url:, new_url:, external_id:,
                   native_identity_confirmed:, cross_origin_approved:, verifier:)
      @user = user
      @resource_id = resource_id
      @role = role.to_s
      @old_url = old_url
      @new_url = new_url
      @external_id = external_id
      @native_identity_confirmed = native_identity_confirmed
      @cross_origin_approved = cross_origin_approved
      @verifier = verifier
    end

    def call
      raise Discourse::InvalidAccess unless @user&.staff?
      configuration = CONFIGURATION.fetch(@role) { raise ArgumentError, "invalid URL role" }
      record = DiscussionBridgeBridgeRecord.find_by!(
        resource_id: @resource_id,
        direction: configuration.fetch(:direction),
      )
      binding = record.content_bindings.find_by!(role: @role, state: "active")
      connection = binding.content_connection
      old_canonical = canonical(connection, @old_url)
      new_canonical = canonical(connection, @new_url)
      raise ArgumentError, "URL migration requires distinct URLs" if old_canonical == new_canonical

      ensure_eligible!(record, binding, connection, old_canonical, new_canonical)
      committed = committed_transition(
        configuration,
        record,
        binding,
        connection,
        old_canonical,
        new_canonical,
      )
      return committed if committed

      redirect_status = @verifier.call(
        old_url: old_canonical,
        new_url: new_canonical,
        allow_cross_origin: @cross_origin_approved,
      )
      raise ArgumentError, "URL migration requires a permanent redirect" if
        [301, 308].exclude?(redirect_status)

      outcome = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection.lock!
        record.lock!
        binding.lock!
        ensure_eligible!(record, binding, connection, old_canonical, new_canonical)
        history = exact_history(configuration, binding, old_canonical, new_canonical)
        if binding.canonical_url == new_canonical && history
          outcome = "already_current"
          redirect_status = history.redirect_status
        else
          raise ArgumentError, "retired URL no longer matches the active binding" unless
            binding.canonical_url == old_canonical

          new_digest = UrlReservation.ensure_available!(
            connection: connection,
            canonical_url: new_canonical,
            binding: binding,
            allow_owned_retired: true,
          )
          history_class(configuration).create!(
            bridge_record: record,
            content_binding: binding,
            verified_by: @user,
            old_canonical_url: old_canonical,
            new_canonical_url: new_canonical,
            old_canonical_url_digest: binding.canonical_url_digest,
            redirect_status: redirect_status,
            verified_at: Time.zone.now,
          )
          migrate_core_embed!(record, binding, old_canonical, new_canonical) if
            @role == "source"
          binding.update!(canonical_url: new_canonical, canonical_url_digest: new_digest)
          record.touch
          outcome = "migrated"
        end
      end
      Result.new(record: record.reload, outcome: outcome, redirect_status: redirect_status)
    end

    private

    def canonical(connection, value)
      result = CanonicalSource.call(connection_id: connection.public_id, source_url: value)
      raise ArgumentError, "URL is outside Content Connection scope" unless
        connection.allows_origin?(result.source_url)

      result.source_url
    end

    def ensure_eligible!(record, binding, connection, old_url, new_url)
      raise ArgumentError, "Bridge Record is not healthy" unless record.state == "healthy"
      raise ArgumentError, "Content Connection is unavailable" unless
        connection.enabled && connection.allows_direction?(record.direction) &&
          connection.allows_lane?(record.lane) && connection.allows_origin?(old_url) &&
          connection.allows_origin?(new_url)
      raise ArgumentError, "URL binding changed during migration" unless
        binding.bridge_record_id == record.id && binding.content_connection_id == connection.id &&
          binding.role == @role && binding.state == "active"
      unless @native_identity_confirmed == true && @external_id == binding.external_id
        raise ArgumentError, "confirm the unchanged native identity and external ID"
      end
      if different_origin?(old_url, new_url) && @cross_origin_approved != true
        raise ArgumentError, "cross-origin migration requires explicit operator approval"
      end

      return if binding.canonical_url == old_url
      configuration = CONFIGURATION.fetch(@role)
      return if binding.canonical_url == new_url &&
        exact_history(configuration, binding, old_url, new_url)

      raise ArgumentError, "retired URL does not match the active binding"
    end

    def different_origin?(old_url, new_url)
      old_uri = URI.parse(old_url)
      new_uri = URI.parse(new_url)
      [old_uri.scheme, old_uri.host, old_uri.port] !=
        [new_uri.scheme, new_uri.host, new_uri.port]
    end

    def exact_history(configuration, binding, old_url, new_url)
      history_class(configuration).order(id: :desc).find_by(
        content_binding_id: binding.id,
        old_canonical_url: old_url,
        new_canonical_url: new_url,
      )
    end

    def committed_transition(configuration, record, binding, connection, old_url, new_url)
      result = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection.lock!
        record.lock!
        binding.lock!
        ensure_eligible!(record, binding, connection, old_url, new_url)
        history = exact_history(configuration, binding, old_url, new_url)
        if binding.canonical_url == new_url && history
          result = Result.new(
            record: record.reload,
            outcome: "already_current",
            redirect_status: history.redirect_status,
          )
        end
      end
      result
    end

    def migrate_core_embed!(record, binding, old_url, new_url)
      embed = TopicEmbed.lock.find_by(topic_id: record.topic_id)
      return unless embed
      unless embed.embed_url == TopicEmbed.normalize_url(old_url)
        raise ArgumentError, "Discourse Core embed URL does not match the source binding"
      end
      collision = TopicEmbed.with_deleted.where(embed_url: TopicEmbed.normalize_url(new_url))
        .where.not(id: embed.id).exists?
      raise AdapterRequestBoundary::Error, "destination_collision" if collision

      embed.update!(embed_url: TopicEmbed.normalize_url(new_url))
    end

    def history_class(configuration)
      configuration.fetch(:history).constantize
    end
  end
end
