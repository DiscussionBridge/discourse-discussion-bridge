# frozen_string_literal: true

module DiscussionBridge
  module CmsAttentionNotifications
    MESSAGE = "discussion_bridge.attention_notice"
    BATCH_SIZE = 100

    def self.record!(work)
      return unless work.state == "attention"
      notice = DiscussionBridgeCmsAttentionNotice.find_or_create_by!(cms_work_id: work.id,
          attempt_cycle: work.attempt_cycle) do |row|
        row.content_connection_id = work.cms_mapping.content_connection_id
        row.attention_snapshot = CmsReceiptCipher.encrypt(work.attributes.except("lease_verifier"))
        row.created_at = Time.current
      end
      User.where(admin: true, active: true, staged: false).find_each(batch_size: BATCH_SIZE) do |user|
        next unless eligible?(user)
        DiscussionBridgeCmsAttentionDelivery.find_or_create_by!(notice_id: notice.id, user_id: user.id)
      end
      # A failed notification enqueue cannot lose the durable recipient rows;
      # existing lifecycle maintenance also drains the bounded pending outbox.
      DB.after_commit do
        begin
          Jobs.enqueue(:discussion_bridge_cms_attention_notifications)
        rescue StandardError
          # The durable outbox is retried by receiver maintenance. Never expose
          # provider/queue exception text in a publication or admin response.
          Rails.logger.warn("[DiscussionBridge] attention notification enqueue deferred")
        end
      end
      notice
    end

    def self.dispatch
      DiscussionBridgeCmsAttentionDelivery.where(delivered_at: nil, skipped_at: nil)
        .order(:id).limit(BATCH_SIZE).each do |candidate|
          DiscussionBridgeCmsAttentionDelivery.transaction do
            row = DiscussionBridgeCmsAttentionDelivery.lock.find(candidate.id)
            next if row.delivered_at || row.skipped_at
            user = User.find_by(id: row.user_id)
            unless eligible?(user)
              row.update!(skipped_at: Time.current)
              next
            end
            notification = Notification.new(user_id: user.id,
              notification_type: Notification.types.fetch(:custom),
              data: JSON.generate(message: MESSAGE, title: MESSAGE))
            # Actual pinned Core supports this attr_accessor and checks it in
            # its after-commit mail callback. This feature adds no email/SMS.
            notification.skip_send_email = true
            notification.save!
            row.update!(notification_id: notification.id, delivered_at: Time.current)
          end
        rescue StandardError
          # This row remains pending after its transaction rolls back. A bell
          # delivery outage must not stop unrelated publication maintenance.
          Rails.logger.warn("[DiscussionBridge] attention notification delivery deferred")
        end
    end

    def self.eligible?(user)
      return false unless user
      CmsAuthorityLifecycle.administrator!(user)
      true
    rescue Discourse::InvalidAccess
      false
    end
    private_class_method :eligible?
  end
end
