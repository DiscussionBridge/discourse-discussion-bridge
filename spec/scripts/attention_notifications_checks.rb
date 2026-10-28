# frozen_string_literal: true
require_relative "../support/attention_recovery_fixture"
class Row
  class << self
    def find_or_create_by!(**attrs)
      find_by(**attrs) || begin
        row = new(**attrs)
        yield(row) if block_given?
        create!(**row.instance_variable_get(:@attrs))
      end
    end
  end
end
class DiscussionBridgeCmsAttentionNotice < Row; end
class DiscussionBridgeCmsAttentionDelivery < Row; end
class Notification < Row
  class << self
    attr_accessor :fail_delivery
    def types = {custom: 14}
  end
  def save!
    raise "private backend token must never be logged" if self.class.fail_delivery
    self.id = (self.class.records.map(&:id).max || 0) + 1
    self.class.records << self
  end
end
module DB
  def self.after_commit(&block) = block.call
end
module Jobs
  class << self
    attr_accessor :fail_enqueue, :enqueued
    def enqueue(name)
      raise "private queue token must never be logged" if fail_enqueue
      self.enqueued ||= []
      enqueued << name
    end
  end
end
module Rails
  class << self
    attr_accessor :warnings
    def logger = self
    def warn(message)
      self.warnings ||= []
      warnings << message
    end
  end
end
require File.join(ROOT, "lib/discussion_bridge/cms_attention_notifications")

def notification_fixture
  values = fixture
  Notification.fail_delivery = false
  Jobs.fail_enqueue = false
  Jobs.enqueued = []
  Rails.warnings = []
  values
end
run("attention notice/outbox is unique per Work/cycle/current administrator") do
  _, _, _, work, actor, = notification_fixture
  ordinary = User.create!(admin: false, active: true, staged: false, suspended: false)
  User.create!(admin: true, active: false, staged: false, suspended: false)
  User.create!(admin: true, active: true, staged: true, suspended: false)
  User.create!(admin: true, active: true, staged: false, suspended: true)
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  assert(DiscussionBridgeCmsAttentionNotice.records.size == 1, "duplicate Work/cycle notices")
  recipients = DiscussionBridgeCmsAttentionDelivery.records.map(&:user_id)
  assert(recipients == [actor.id] && !recipients.include?(ordinary.id), "wrong native recipients")
  notice = DiscussionBridgeCmsAttentionNotice.records.first
  assert(notice.attention_snapshot.fetch("state") == "attention" && !notice.attention_snapshot.key?("lease_verifier"), "private failure snapshot wrong")
end
run("pending/retry_wait/verified/superseded are never notified as actual attention") do
  _, _, _, work, _, = notification_fixture
  %w[pending retry_wait verified superseded].each do |state|
    work.state = state
    DiscussionBridge::CmsAttentionNotifications.record!(work)
  end
  assert(DiscussionBridgeCmsAttentionNotice.records.empty? && Jobs.enqueued.empty?, "nonattention notified")
end
run("bell delivery uses supported no-email flag and no private data or read override") do
  _, _, _, work, _, = notification_fixture
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  DiscussionBridge::CmsAttentionNotifications.dispatch
  notification = Notification.records.first
  assert(notification && notification.skip_send_email == true && notification.notification_type == 14, "native no-email bell absent")
  assert(JSON.parse(notification.data) == {"message" => "discussion_bridge.attention_notice", "title" => "discussion_bridge.attention_notice"}, "private data in bell")
  assert(notification.read.nil?, "native read/unread was overridden")
  DiscussionBridge::CmsAttentionNotifications.dispatch
  assert(Notification.records.size == 1, "duplicate bell after outbox replay")
end
run("recipient revoked after occurrence is skipped without delivering") do
  _, _, _, work, actor, = notification_fixture
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  actor.admin = false
  DiscussionBridge::CmsAttentionNotifications.dispatch
  row = DiscussionBridgeCmsAttentionDelivery.records.first
  assert(row.skipped_at && !row.delivered_at && Notification.records.empty?, "revoked recipient received bell")
end
run("queue outage retains durable occurrence and recipients without failing publication response") do
  _, _, _, work, _, = notification_fixture
  Jobs.fail_enqueue = true
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  assert(DiscussionBridgeCmsAttentionNotice.records.size == 1 && DiscussionBridgeCmsAttentionDelivery.records.size == 1, "queue outage lost outbox")
  assert(Rails.warnings.any? && Rails.warnings.none? { |message| message.include?("private") }, "unsafe/missing queue diagnostic")
end
run("delivery failure stays pending and does not prevent lifecycle recovery") do
  _, _, _, work, _, = notification_fixture
  DiscussionBridge::CmsAttentionNotifications.record!(work)
  Notification.fail_delivery = true
  DiscussionBridge::CmsAttentionNotifications.dispatch
  row = DiscussionBridgeCmsAttentionDelivery.records.first
  assert(!row.delivered_at && !row.skipped_at && work.state == "attention", "delivery error lost outbox or reset Work")
  assert(Rails.warnings.any? && Rails.warnings.none? { |message| message.include?("private") }, "unsafe/missing delivery diagnostic")
  Notification.fail_delivery = false
  DiscussionBridge::CmsAttentionNotifications.dispatch
  assert(row.delivered_at && Notification.records.size == 1, "deferred bell never retried")
end
puts JSON.pretty_generate(checks: CHECKS.length, passed: CHECKS, failures: FAILURES, runtime: RUBY_DESCRIPTION,
  boundary: "Actual CmsAttentionNotifications/CmsAuthorityLifecycle; explicit synthetic User/model/outbox/Notification/DB.after_commit/Jobs/Rails logger seams. No real Core notification callback, database atomicity, Sidekiq or email transport execution.")
exit(FAILURES.empty? ? 0 : 1)
