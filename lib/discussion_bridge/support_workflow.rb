# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  module SupportWorkflow
    # Phil's explicit preset choice, recorded 2026-10-27. No user-editable
    # destination, guessed fallback, partner or commercial provider routing.
    REQUEST_DESTINATION = "supportrequest@discussionbridge.dev"
    REQUEST_FIELDS = %w[contact_email forum_url plugin_version request_id problem].freeze
    class Error < StandardError
      attr_reader :status
      def initialize(message, status: 422)
        @status = status
        super(message)
      end
    end

    def self.admin_data(actor)
      CmsAuthorityLifecycle.administrator!(actor)
      SupportAccess.locked do |state|
        CmsAuthorityLifecycle.administrator!(actor)
        {
          enabled: state.enabled, provider: "DiscussionBridge", future_providers_planned: true,
          request_destination_configured: REQUEST_DESTINATION.present?,
          request_destination: REQUEST_DESTINATION,
          request_defaults: { forum_url: Discourse.base_url, plugin_version: VERSION, request_id: SecureRandom.uuid },
          requests: DiscussionBridgeSupportRequest.order(id: :desc).limit(25).map { |row| request_summary(row) },
          grants: DiscussionBridgeSupportGrant.includes(:user).order(id: :desc).limit(100).map do |row|
            { id: row.id, user_id: row.user_id, username: row.user&.username || "[deleted account]",
              granted_at: row.granted_at, revoked_at: row.revoked_at }
          end,
        }
      end
    end

    def self.enable!(actor, enabled)
      raise Error, "Enable must be true or false." unless enabled == true || enabled == false
      CmsAuthorityLifecycle.administrator!(actor)
      SupportAccess.locked do |state|
        CmsAuthorityLifecycle.administrator!(actor)
        state.update!(enabled: enabled)
        unless enabled
          DiscussionBridgeSupportGrant.active.update_all(revoked_at: Time.current, revoked_by_user_id: actor.id, updated_at: Time.current)
        end
        SupportAccess.audit!(actor, enabled ? "enabled" : "disabled", all_local_grants_revoked: !enabled)
      end
      { enabled: enabled }
    end

    def self.grant!(actor, username)
      unless username.is_a?(String) && username.present? && username.bytesize <= 255
        raise Error, "An existing native account username is required."
      end
      CmsAuthorityLifecycle.administrator!(actor)
      SupportAccess.locked do |state|
        CmsAuthorityLifecycle.administrator!(actor)
        raise Error, "Enable support before granting access." unless state.enabled
        user = User.find_by(username_lower: username.downcase)
        raise Error, "The named active native account does not exist." unless user
        SupportAccess.native_user!(user)
        grant = DiscussionBridgeSupportGrant.active.find_by(user_id: user.id)
        unless grant
          grant = DiscussionBridgeSupportGrant.create!(user_id: user.id, granted_by_user_id: actor.id, granted_at: Time.current)
          SupportAccess.audit!(actor, "grant", target_user_id: user.id, grant_id: grant.id)
        end
        { grant_id: grant.id, user_id: user.id }
      end
    end

    def self.revoke!(actor, id)
      CmsAuthorityLifecycle.administrator!(actor)
      SupportAccess.locked do |_state|
        CmsAuthorityLifecycle.administrator!(actor)
        grant = DiscussionBridgeSupportGrant.find(CmsSourceLifecycle.native_id!(id))
        unless grant.revoked_at
          grant.update!(revoked_at: Time.current, revoked_by_user_id: actor.id)
          SupportAccess.audit!(actor, "revoke", target_user_id: grant.user_id, grant_id: grant.id)
        end
        { grant_id: grant.id, revoked: true }
      end
    end

    def self.request!(actor, input)
      CmsAuthorityLifecycle.administrator!(actor)
      validate_request!(input)
      row = nil
      SupportAccess.locked do |state|
        CmsAuthorityLifecycle.administrator!(actor)
        raise Error, "Enable support before requesting assistance." unless state.enabled
        raise Error, "The support request email destination has not been configured." if REQUEST_DESTINATION.blank?
        payload = input.slice(*REQUEST_FIELDS)
        digest = Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h))
        row = DiscussionBridgeSupportRequest.find_by(request_id: input.fetch("request_id"))
        if row
          unless row.actor_user_id == actor.id && row.payload_sha256 == digest
            raise Error.new("The request ID was already used for different fields or a different administrator.", status: 409)
          end
        else
          row = DiscussionBridgeSupportRequest.create!(**payload.symbolize_keys,
            actor_user_id: actor.id, payload_sha256: digest, request_destination: REQUEST_DESTINATION, status: "pending")
          SupportAccess.audit!(actor, "request_reviewed", request_id: row.request_id)
          DB.after_commit { enqueue_request(row.id) }
        end
      end
      request_summary(row.reload)
    end

    def self.validate_request!(input)
      unless input.is_a?(Hash) && input.keys.sort == (REQUEST_FIELDS + ["reviewed"]).sort && input["reviewed"] == true
        raise Error, "Explicit review of the five request fields is required."
      end
      unless REQUEST_FIELDS.all? { |key| input[key].is_a?(String) && input[key].present? }
        raise Error, "All five request fields are required."
      end
      CmsProtocol.validate!("UUID", input.fetch("request_id"))
      email = input.fetch("contact_email")
      unless email.bytesize <= 320 && email.match?(/\A[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+\z/)
        raise Error, "Enter a valid contact email address."
      end
      unless input.fetch("forum_url") == Discourse.base_url && input.fetch("plugin_version") == VERSION
        raise Error, "The forum URL or plugin version changed. Refresh and review the request again."
      end
      raise Error, "Problem text must be at most 8,000 bytes." if input.fetch("problem").bytesize > 8_000
    end

    def self.enqueue_request(id)
      Jobs.enqueue(:discussion_bridge_support_request, request_record_id: id)
      DiscussionBridgeSupportRequest.where(id: id, status: "pending").update_all(status: "queued", updated_at: Time.current)
    rescue StandardError
      # An enqueue exception may occur after queue acceptance. Preserve that
      # ambiguity and never automatically submit the same request again.
      DiscussionBridgeSupportRequest.where(id: id, status: "pending").update_all(status: "queue_unconfirmed", failure_code: "queue_unconfirmed", updated_at: Time.current)
    end

    def self.request_summary(row)
      { request_id: row.request_id, status: row.status, created_at: row.created_at,
        failure_code: row.failure_code }
    end
  end
end
