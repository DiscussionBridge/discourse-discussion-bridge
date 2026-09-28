# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class AdminNetworkController < ::Admin::AdminController
    requires_plugin DiscussionBridge::PLUGIN_NAME

    def show
      render json: state_payload
    end

    def enable
      identity = DiscussionBridgeForumIdentity.enable!(actor: current_user)
      audit!(identity.forum_id, "enabled", "network_identity_enabled")
      render json: state_payload
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def disable
      identity = DiscussionBridgeForumIdentity.current
      raise Discourse::NotFound unless identity

      identity.disable!(actor: current_user)
      audit!(identity.forum_id, "disabled", "network_identity_disabled")
      render json: state_payload
    end

    def rotate
      identity = DiscussionBridgeForumIdentity.current
      raise Discourse::NotFound unless identity
      confirmation = params.require(:confirmation_forum_id).to_s
      raise ArgumentError, "forum identity confirmation does not match" unless
        ActiveSupport::SecurityUtils.secure_compare(identity.forum_id, confirmation)

      old_id = identity.forum_id
      identity.rotate!(actor: current_user)
      audit!(old_id, "rotated", "network_identity_rotated")
      render json: state_payload
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def create_peer
      identity = DiscussionBridgeForumIdentity.current
      raise ArgumentError, "network identity is not enabled" unless identity&.ready?

      attributes = peer_params
      secret = attributes.delete(:remote_secret)
      peer = DiscussionBridgeNetworkPeer.new(
        attributes.merge(
          authorized_by: current_user,
          authorized_at: Time.zone.now,
        ),
      )
      peer.remote_secret = secret
      peer.save!
      audit!(peer.remote_forum_id, "created", "network_peer_authorized")
      render json: { network_peer: serialize_peer(peer) }, status: :created
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def update_peer
      peer = DiscussionBridgeNetworkPeer.find(params[:id])
      attributes = peer_params
      secret = attributes.delete(:remote_secret)
      peer.assign_attributes(attributes)
      peer.remote_secret = secret if secret.present?
      peer.authorized_by = current_user
      peer.authorized_at = Time.zone.now
      peer.disabled_at = peer.enabled ? nil : Time.zone.now
      peer.save!
      audit!(peer.remote_forum_id, "updated", "network_peer_updated")
      render json: { network_peer: serialize_peer(peer) }
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      render json: { errors: errors_for(error) }, status: :unprocessable_entity
    end

    def disable_peer
      peer = DiscussionBridgeNetworkPeer.find(params[:id])
      peer.update!(enabled: false, disabled_at: Time.zone.now, authorized_by: current_user)
      audit!(peer.remote_forum_id, "disabled", "network_peer_disabled")
      render json: { network_peer: serialize_peer(peer) }
    end

    private

    def peer_params
      raw = params.require(:network_peer).permit(
        :content_connection_id,
        :name,
        :remote_forum_id,
        :remote_forum_name,
        :remote_origin,
        :remote_connection_id,
        :remote_secret,
        :relationship,
        :enabled,
      ).to_h.symbolize_keys
      raw[:content_connection_id] = Integer(raw[:content_connection_id].to_s, 10) if
        raw.key?(:content_connection_id)
      raw[:remote_origin] = CanonicalSource.origin(raw[:remote_origin]) if raw.key?(:remote_origin)
      raw
    end

    def state_payload
      identity = DiscussionBridgeForumIdentity.current
      {
        network_identity: identity && {
          forum_id: identity.forum_id,
          site_origin: identity.site_origin,
          enabled: identity.enabled,
          ready: identity.ready?,
          retired_forum_ids: identity.retired_forum_ids,
          enabled_at: identity.enabled_at,
          disabled_at: identity.disabled_at,
          rotated_at: identity.rotated_at,
        },
        network_peers: DiscussionBridgeNetworkPeer.order(:name, :id).map do |peer|
          serialize_peer(peer)
        end,
      }
    end

    def serialize_peer(peer)
      {
        id: peer.id,
        content_connection_id: peer.content_connection_id,
        name: peer.name,
        remote_forum_id: peer.remote_forum_id,
        remote_forum_name: peer.remote_forum_name,
        remote_origin: peer.remote_origin,
        remote_connection_id: peer.remote_connection_id,
        relationship: peer.relationship,
        enabled: peer.enabled,
        operational: peer.operational?,
        authorized_at: peer.authorized_at,
        disabled_at: peer.disabled_at,
      }
    end

    def audit!(identity, outcome, reason)
      DiscussionBridgeAuditEvent.create!(
        correlation_id: "network-admin-#{SecureRandom.hex(8)}",
        connection_id: "discourse-network",
        source_identity_digest: Digest::SHA256.hexdigest(identity),
        effective_actor_id: current_user.id,
        outcome: outcome,
        reason: reason,
        requested_state: {},
        effective_state: {},
      )
    end

    def errors_for(error)
      error.respond_to?(:record) ? error.record.errors.full_messages : [error.message]
    end
  end
end
