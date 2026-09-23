# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class PublicationAttentionNotifier
    MINIMUM_INTERVAL = 1.hour

    def self.call(connection)
      connection.with_lock do
        attention = connection.publication_work_items
          .where(state: DiscussionBridgePublicationWorkItem::ATTENTION_STATES)
          .order(:id)
          .pluck(:id, :topic_id, :state, :reason, :publication_revision)
        if attention.empty?
          if connection.publication_attention_fingerprint.present?
            users_for_notification.find_each do |user|
              Notification.create!(
                notification_type: Notification.types[:custom],
                user_id: user.id,
                data: {
                  display_username: "DiscussionBridge",
                  message: "success",
                  title: "discussion_bridge.notification.resolved_title",
                  topic_title: "#{connection.name}: publication attention is resolved",
                  discussion_bridge_connection_id: connection.public_id,
                }.to_json,
              )
            end
            connection.update_columns(
              publication_attention_fingerprint: nil,
              publication_attention_notified_at: nil,
              updated_at: Time.zone.now,
            )
          end
          return
        end

        fingerprint = Digest::SHA256.hexdigest(attention.to_json)
        return if connection.publication_attention_fingerprint == fingerprint
        return if connection.publication_attention_notified_at &&
          connection.publication_attention_notified_at > MINIMUM_INTERVAL.ago

        users_for_notification.find_each do |user|
          count = attention.length
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: user.id,
            topic_id: attention.first[1],
            data: {
              display_username: "DiscussionBridge",
              message: "warning",
              title: "discussion_bridge.notification.attention_title",
              topic_title: "#{connection.name}: #{count} publication #{
                count == 1 ? 'item needs' : 'items need'
              } attention",
              discussion_bridge_connection_id: connection.public_id,
            }.to_json,
          )
        end
        connection.update_columns(
          publication_attention_fingerprint: fingerprint,
          publication_attention_notified_at: Time.zone.now,
          updated_at: Time.zone.now,
        )
      end
    end

    def self.users_for_notification
      group_ids = SiteSetting.discussion_bridge_attention_groups.to_s.split("|")
        .filter_map { |value| Integer(value, exception: false) }
        .uniq
      user_ids = GroupUser.where(group_id: group_ids).distinct.select(:user_id)
      User.where(id: user_ids, active: true, staged: false)
        .where("suspended_till IS NULL OR suspended_till < ?", Time.zone.now)
        .where.not(id: Discourse::SYSTEM_USER_ID)
    end

    private_class_method :users_for_notification
  end
end
