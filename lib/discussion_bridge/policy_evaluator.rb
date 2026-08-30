# frozen_string_literal: true

require "uri"

module DiscussionBridge
  class PolicyEvaluator
    Settings = Data.define(
      :enabled,
      :endpoint_enabled,
      :connection_id,
      :trusted_origins,
      :service_username,
    )
    Result = Data.define(
      :allowed,
      :reason,
      :requested_visibility,
      :effective_visibility,
      :operating_actor_id,
      :effective_actor_id,
      :effective_category_id,
      :effective_tags,
      :compatibility_mode,
    )

    def self.call(request:, settings:, actor:, author: actor, authority: nil, lane_resolution: nil)
      return denied("plugin_disabled", request) unless settings.enabled
      return denied("endpoint_disabled", request) unless settings.endpoint_enabled
      return denied("connection_mismatch", request) unless request.fetch(:connection_id) == settings.connection_id
      return denied("origin_denied", request) unless trusted_origin?(request.fetch(:source_url), settings.trusted_origins)
      return denied("invalid_actor", request) unless valid_actor?(actor, settings.service_username)
      return denied("invalid_author", request) unless valid_author?(author)
      return denied(lane_resolution.reason, request) if lane_resolution && !lane_resolution.allowed
      return denied("authorization_incomplete", request) unless authority
      return denied(authority.reason, request) unless authority.allowed?

      requested = request.fetch(:visibility, "unlisted").to_s
      Result.new(
        allowed: true,
        reason: "forum_policy_applied",
        requested_visibility: requested,
        effective_visibility: "unlisted",
        operating_actor_id: actor.id,
        effective_actor_id: author.id,
        effective_category_id: authority.category_id,
        effective_tags: authority.tags,
        compatibility_mode: false,
      )
    end

    def self.denied(reason, request)
      Result.new(
        allowed: false,
        reason: reason,
        requested_visibility: request[:visibility]&.to_s,
        effective_visibility: nil,
        operating_actor_id: nil,
        effective_actor_id: nil,
        effective_category_id: nil,
        effective_tags: [],
        compatibility_mode: false,
      )
    end
    private_class_method :denied

    def self.valid_actor?(actor, configured_username)
      actor && actor.active? && !actor.staged? && !actor.suspended? && !actor.silenced? &&
        actor.id != Discourse::SYSTEM_USER_ID && actor.username.casecmp?(configured_username.to_s)
    end
    private_class_method :valid_actor?

    def self.valid_author?(author)
      author && author.active? && !author.staged? && !author.suspended? && !author.silenced? &&
        author.id != Discourse::SYSTEM_USER_ID
    end
    private_class_method :valid_author?

    def self.trusted_origin?(source_url, trusted_origins)
      source = CanonicalSource.call(connection_id: "origin-validation", source_url: source_url)
      uri = URI.parse(source.source_url)
      origin = "#{uri.scheme}://#{uri.host}"
      origin += ":#{uri.port}" unless uri.port == uri.default_port
      origin_candidates(trusted_origins).include?(origin)
    rescue ArgumentError, URI::InvalidURIError
      false
    end
    private_class_method :trusted_origin?

    def self.origin_candidates(value)
      raw = value.is_a?(String) ? value.split("|") : Array(value)
      raw.filter_map do |candidate|
        CanonicalSource.origin(candidate.to_s.strip)
      rescue ArgumentError
        nil
      end.uniq
    end
    private_class_method :origin_candidates

  end
end
