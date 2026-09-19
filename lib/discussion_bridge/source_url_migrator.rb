# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class SourceUrlMigrator
    Result = Data.define(:record, :outcome, :redirect_status)

    def self.call(user:, resource_id:, old_url:, new_url:, external_id:, native_identity_confirmed:,
                  verifier: PublicationRedirectVerifier)
      new(user: user, resource_id: resource_id, old_url: old_url, new_url: new_url,
          external_id: external_id, native_identity_confirmed: native_identity_confirmed,
          verifier: verifier).call
    end

    def initialize(user:, resource_id:, old_url:, new_url:, external_id:, native_identity_confirmed:, verifier:)
      @user = user
      @resource_id = resource_id
      @old_url = old_url
      @new_url = new_url
      @external_id = external_id
      @native_identity_confirmed = native_identity_confirmed
      @verifier = verifier
    end

    def call
      raise Discourse::InvalidAccess unless @user&.staff?

      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: @resource_id, direction: "to_discourse")
      binding = record.content_bindings.find_by!(role: "source", state: "active")
      connection = binding.content_connection
      old_canonical = canonical(connection, @old_url)
      new_canonical = canonical(connection, @new_url)
      raise ArgumentError, "source URLs must differ" if old_canonical == new_canonical
      ensure_eligible!(record, binding, connection, old_canonical, new_canonical)

      committed = committed_transition(record, binding, connection, old_canonical, new_canonical)
      return committed if committed

      # The public route check is deliberately outside the transaction. The
      # connection, record, binding and URL ownership are rechecked under locks.
      redirect_status = @verifier.call(old_url: old_canonical, new_url: new_canonical)
      raise ArgumentError, "source redirect must be permanent" if [301, 308].exclude?(redirect_status)

      outcome = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection.lock!
        record.lock!
        binding.lock!
        ensure_eligible!(record, binding, connection, old_canonical, new_canonical)
        embed = active_core_embed!(record.topic_id, binding.canonical_url)
        history = exact_history(binding, old_canonical, new_canonical)
        if binding.canonical_url == new_canonical && history
          outcome = "already_current"
          redirect_status = history.redirect_status
        else
          raise ArgumentError, "old source URL no longer matches the active binding" unless
            binding.canonical_url == old_canonical
          new_digest = digest(connection.public_id, new_canonical)
          raise ArgumentError, "destination URL is already bound or reserved" if
            DiscussionBridgeContentBinding.where(canonical_url_digest: new_digest).where.not(id: binding.id).exists? ||
              DiscussionBridgePresentationUrlHistory.where(old_canonical_url_digest: new_digest).exists? ||
              DiscussionBridgeSourceUrlHistory.where(old_canonical_url_digest: new_digest)
                .where.not(content_binding_id: binding.id).exists?

          if embed && TopicEmbed.with_deleted.where(embed_url: TopicEmbed.normalize_url(new_canonical))
              .where.not(id: embed.id).exists?
            raise ArgumentError, "destination Core embed URL is already reserved"
          end

          DiscussionBridgeSourceUrlHistory.create!(
            bridge_record: record,
            content_binding: binding,
            verified_by: @user,
            old_canonical_url: old_canonical,
            new_canonical_url: new_canonical,
            old_canonical_url_digest: binding.canonical_url_digest,
            redirect_status: redirect_status,
            verified_at: Time.zone.now,
          )
          embed&.update!(embed_url: TopicEmbed.normalize_url(new_canonical))
          binding.update!(canonical_url: new_canonical, canonical_url_digest: new_digest)
          record.touch
          outcome = "migrated"
        end
      end
      Result.new(record: record.reload, outcome: outcome, redirect_status: redirect_status)
    end

    private

    def canonical(connection, value)
      source = CanonicalSource.call(connection_id: connection.public_id, source_url: value).source_url
      raise ArgumentError, "source URL is outside connection scope" unless connection.allows_origin?(source)

      source
    end

    def digest(connection_id, url)
      Digest::SHA256.hexdigest("#{connection_id}\n#{url}")
    end

    def exact_history(binding, old_url, new_url)
      DiscussionBridgeSourceUrlHistory.order(id: :desc).find_by(
        content_binding_id: binding.id,
        old_canonical_url_digest: digest(binding.content_connection.public_id, old_url),
        old_canonical_url: old_url,
        new_canonical_url: new_url,
      )
    end

    def committed_transition(record, binding, connection, old_url, new_url)
      result = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection.lock!
        record.lock!
        binding.lock!
        ensure_eligible!(record, binding, connection, old_url, new_url)
        active_core_embed!(record.topic_id, binding.canonical_url)
        history = exact_history(binding, old_url, new_url)
        if binding.canonical_url == new_url && history
          result = Result.new(record: record.reload, outcome: "already_current", redirect_status: history.redirect_status)
        end
      end
      result
    end

    def ensure_eligible!(record, binding, connection, old_url, new_url)
      raise ArgumentError, "source record is not healthy" unless record.state == "healthy"
      raise ArgumentError, "source connection is unavailable" unless
        connection.enabled && connection.allows_direction?("to_discourse") &&
          connection.allows_lane?(record.lane) && connection.allows_origin?(new_url)
      raise ArgumentError, "source binding changed during migration" unless
        binding.bridge_record_id == record.id && binding.content_connection_id == connection.id &&
          binding.state == "active" && binding.role == "source"
      raise ArgumentError, "confirm the same native platform item and external ID" unless
        @native_identity_confirmed == true && @external_id == binding.external_id

      topic = Topic.find_by(id: record.topic_id)
      raise ArgumentError, "source topic is unavailable" unless
        topic && topic.deleted_at.nil? &&
          Post.exists?(topic_id: topic.id, post_number: 1, deleted_at: nil)

      return if binding.canonical_url == old_url
      return if binding.canonical_url == new_url && exact_history(binding, old_url, new_url)

      raise ArgumentError, "old source URL does not match the active binding"
    end

    def active_core_embed!(topic_id, old_url)
      embed = TopicEmbed.lock.find_by(topic_id: topic_id)
      if embed && embed.embed_url != TopicEmbed.normalize_url(old_url)
        raise ArgumentError, "Core embed URL does not match the source binding"
      end
      embed
    end
  end
end
