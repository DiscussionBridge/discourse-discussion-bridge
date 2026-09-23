# frozen_string_literal: true

module DiscussionBridge
  class PublicationStatusAccess
    AUDIENCES = %w[admins staff groups].freeze

    def self.allowed?(user)
      return false unless user

      case SiteSetting.discussion_bridge_publication_status_audience
      when "admins"
        user.admin?
      when "groups"
        user.admin? || member_of_configured_group?(user)
      else
        user.staff?
      end
    end

    def self.member_of_configured_group?(user)
      group_ids = SiteSetting.discussion_bridge_publication_status_groups.to_s
        .split("|")
        .filter_map { |value| Integer(value, exception: false) }
        .uniq
      group_ids.any? && GroupUser.exists?(user_id: user.id, group_id: group_ids)
    end

    private_class_method :member_of_configured_group?
  end
end
