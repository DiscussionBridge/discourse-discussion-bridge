# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class PublicationUrlMigrator
    Result = Data.define(:record, :outcome, :redirect_status)

    def self.call(user:, resource_id:, old_url:, new_url:, verifier: PublicationRedirectVerifier)
      new(user: user, resource_id: resource_id, old_url: old_url, new_url: new_url, verifier: verifier).call
    end

    def initialize(user:, resource_id:, old_url:, new_url:, verifier:)
      @user = user
      @resource_id = resource_id
      @old_url = old_url
      @new_url = new_url
      @verifier = verifier
    end

    def call
      raise Discourse::InvalidAccess unless @user&.staff?
      record = DiscussionBridgeBridgeRecord.find_by!(resource_id: @resource_id, direction: "from_discourse")
      binding = record.content_bindings.find_by!(role: "presentation", state: "active")
      connection = binding.content_connection
      old_canonical = canonical(connection, @old_url)
      new_canonical = canonical(connection, @new_url)
      raise ArgumentError, "publication URLs must differ" if old_canonical == new_canonical
      ensure_eligible!(record, binding, connection, old_canonical, new_canonical)

      # Network verification is outside the database transaction. Every binding
      # and collision condition is checked again under locks before committing.
      redirect_status = @verifier.call(old_url: old_canonical, new_url: new_canonical)
      raise ArgumentError, "publication redirect must be permanent" if [301, 308].exclude?(redirect_status)

      outcome = nil
      DiscussionBridgeBridgeRecord.transaction do
        # Creators and presentation corrections take the same connection lock
        # before checking either binding or retired-URL reservations.
        connection.lock!
        record.lock!
        binding.lock!
        ensure_eligible!(record, binding, connection, old_canonical, new_canonical)
        history = exact_history(binding, old_canonical, new_canonical)
        if binding.canonical_url == new_canonical && history
          outcome = "already_current"
        else
          raise ArgumentError, "old publication URL no longer matches the active binding" unless
            binding.canonical_url == old_canonical
          old_digest = binding.canonical_url_digest
          new_digest = digest(connection.public_id, new_canonical)
          raise ArgumentError, "destination URL is already bound or reserved" if
            DiscussionBridgeContentBinding.where(canonical_url_digest: new_digest).where.not(id: binding.id).exists? ||
              DiscussionBridgePresentationUrlHistory.where(old_canonical_url_digest: new_digest)
                .where.not(content_binding_id: binding.id).exists?

          DiscussionBridgePresentationUrlHistory.create!(
            bridge_record: record,
            content_binding: binding,
            verified_by: @user,
            old_canonical_url: old_canonical,
            new_canonical_url: new_canonical,
            old_canonical_url_digest: old_digest,
            redirect_status: redirect_status,
            verified_at: Time.zone.now,
          )
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
      raise ArgumentError, "publication URL is outside connection scope" unless connection.allows_origin?(source)
      source
    end

    def digest(connection_id, url)
      Digest::SHA256.hexdigest("#{connection_id}\n#{url}")
    end

    def exact_history(binding, old_url, new_url)
      DiscussionBridgePresentationUrlHistory.order(id: :desc).find_by(
        content_binding_id: binding.id,
        old_canonical_url_digest: digest(binding.content_connection.public_id, old_url),
        old_canonical_url: old_url,
        new_canonical_url: new_url,
      )
    end

    def ensure_eligible!(record, binding, connection, old_url, new_url)
      raise ArgumentError, "publication is not healthy" unless record.state == "healthy"
      raise ArgumentError, "native publication authority is required" unless binding.native_materialization
      raise ArgumentError, "connection is unavailable" unless
        connection.enabled && connection.allows_direction?("from_discourse") &&
          connection.allows_lane?(record.lane)
      raise ArgumentError, "publication binding changed during migration" unless
        binding.bridge_record_id == record.id && binding.state == "active" &&
          binding.role == "presentation"

      return if binding.canonical_url == old_url
      return if binding.canonical_url == new_url && exact_history(binding, old_url, new_url)

      raise ArgumentError, "old publication URL does not match the active binding"
    end
  end
end
