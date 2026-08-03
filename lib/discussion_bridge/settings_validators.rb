# frozen_string_literal: true

require "uri"
require_relative "lane_policies"

module DiscussionBridge
  class TrustedOriginsValidator
    def initialize(_opts = {})
    end

    def valid_value?(value)
      values(value).all? do |candidate|
        uri = URI.parse(candidate)
        !candidate.include?("*") && uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil? && (uri.path.empty? || uri.path == "/")
      rescue URI::InvalidURIError
        false
      end
    end

    def error_message
      I18n.t("site_settings.discussion_bridge_trusted_origins_error")
    end

    private

    def values(value)
      value.to_s.split("|").map(&:strip).reject(&:empty?)
    end
  end

  class ServiceUsernameValidator
    def initialize(_opts = {})
    end

    def valid_value?(value)
      return true if value.blank?

      user = User.find_by(username_lower: value.to_s.downcase)
      !!(
        user && user.active? && !user.staged? && !user.suspended? && !user.silenced? &&
          user.id != Discourse::SYSTEM_USER_ID
      )
    end

    def error_message
      I18n.t("site_settings.discussion_bridge_service_username_error")
    end
  end

  class CategoryValidator
    def initialize(_opts = {})
    end

    def valid_value?(value)
      value.to_i.zero? || Category.exists?(id: value.to_i)
    end

    def error_message
      I18n.t("site_settings.discussion_bridge_effective_category_id_error")
    end
  end

  class TagsValidator
    def initialize(_opts = {})
    end

    def valid_value?(value)
      names = value.to_s.split("|").map(&:strip).reject(&:empty?).uniq
      Tag.where(name: names).count == names.length
    end

    def error_message
      I18n.t("site_settings.discussion_bridge_effective_tags_error")
    end
  end

  class LanePoliciesValidator
    def initialize(_opts = {})
    end

    def valid_value?(value)
      policies = LanePolicies.parse(value)
      category_ids = policies.map { |policy| policy[:category_id] }
      tag_names = policies.flat_map { |policy| policy[:tags] }.uniq

      Category.where(id: category_ids).count == category_ids.uniq.length &&
        Tag.where(name: tag_names).count == tag_names.length
    rescue LanePolicies::ParseError
      false
    end

    def error_message
      I18n.t("site_settings.discussion_bridge_lane_policies_error")
    end
  end
end
