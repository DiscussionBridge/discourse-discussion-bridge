# frozen_string_literal: true
abort "Run this standalone source harness directly, outside Rails." if defined?(Rails::Application)

require "json"
require "active_support"
require "active_support/core_ext/object/blank"
module Discourse
  class InvalidAccess < StandardError; end
end
module Jobs
  class Base; end
end
module SiteSetting
  class << self
    attr_accessor :discussion_bridge_enabled
  end
end
class Time
  def self.current = utc(2026, 10, 28, 18)
end
module JobProbe
  class << self
    attr_accessor :events, :row, :state, :transaction_count, :before_transaction, :mailer_outcome, :audit_failure
  end
end
ActorProbe = Struct.new(:allowed)
StateProbe = Struct.new(:enabled)
class RequestProbe
  attr_reader :values
  def initialize(destination)
    @values = { id: 7, actor: ActorProbe.new(true), status: "pending", request_destination: destination, request_id: "synthetic-request" }
  end
  def method_missing(name, *) = values.fetch(name)
  def respond_to_missing?(name, *) = values.key?(name)
  def update!(**changes)
    values.merge!(changes)
    JobProbe.events << [:update, changes.dup]
    true
  end
  def reload = self
end
class DiscussionBridgeSupportState
  def self.transaction
    JobProbe.transaction_count += 1
    JobProbe.before_transaction&.call(JobProbe.transaction_count)
    before = JobProbe.row&.values&.dup
    completion = :running
    result = yield
    completion = :committed
    JobProbe.events << [:normal_commit, JobProbe.row&.status]
    result
  rescue StandardError
    JobProbe.row.values.replace(before) if before && JobProbe.row
    completion = :rolled_back
    JobProbe.events << [:rollback, JobProbe.row&.status]
    raise
  ensure
    JobProbe.events << [:nonlocal_exit, JobProbe.row&.status] if completion == :running
  end
  def self.lock = self
  def self.find(id)
    raise "Wrong singleton" unless id == 1
    JobProbe.state
  end
end
class DiscussionBridgeSupportRequest
  def self.lock = self
  def self.find_by(id:) = (JobProbe.row if JobProbe.row&.id == id)
  def self.where(**filter)
    Struct.new(:filter).new(filter).tap do |relation|
      def relation.update_all(**changes)
        row = JobProbe.row
        row.update!(**changes) if row && filter.all? { |key, value| row.public_send(key) == value }
      end
    end
  end
end
module DiscussionBridge
  module CmsAuthorityLifecycle
    def self.administrator!(actor)
      raise Discourse::InvalidAccess unless actor&.allowed
      actor
    end
  end
  module SupportMailer
    def self.request_assistance(row)
      JobProbe.events << [:message_prepared, row.id]
      :synthetic_message
    end
  end
end
require_relative "../../lib/discussion_bridge/support_workflow"
require_relative "../../lib/discussion_bridge/support_access"
module DiscussionBridge::SupportAccess
  def self.audit!(_actor, action, details = {})
    JobProbe.events << [:audit, action, details]
    raise "synthetic private audit sentinel" if JobProbe.audit_failure
  end
end
class EmailLog
  def persisted? = true
  def id = 99
end
module Email
  class Sender
    def initialize(message, kind)
      raise "Wrong synthetic message" unless message == :synthetic_message && kind == "discussion_bridge_support"
      JobProbe.events << [:sender_constructed]
    end
    def send
      raise "Admission not committed before transport" unless JobProbe.events.any? { |item| item == [:normal_commit, "sending"] }
      JobProbe.events << [:synthetic_send]
      raise "synthetic private transport sentinel" if JobProbe.mailer_outcome == :raise
      JobProbe.mailer_outcome == :accepted ? EmailLog.new : Object.new
    end
  end
end
require_relative "../../jobs/regular/discussion_bridge_support_request"
CHECKS = []
FAILURES = []
def assert(condition, message)
  raise message unless condition
end
def fixture
  JobProbe.events = []
  JobProbe.state = StateProbe.new(true)
  JobProbe.row = RequestProbe.new(DiscussionBridge::SupportWorkflow::REQUEST_DESTINATION)
  JobProbe.transaction_count = 0
  JobProbe.before_transaction = nil
  JobProbe.mailer_outcome = :accepted
  JobProbe.audit_failure = false
  SiteSetting.discussion_bridge_enabled = true
end
def execute = Jobs::DiscussionBridgeSupportRequest.new.execute(request_record_id: 7)
def no_mail_work
  forbidden = %i[message_prepared sender_constructed synthetic_send]
  assert(JobProbe.events.none? { |item| forbidden.include?(item.first) }, "Mail prepared, constructed or sent before admission")
end
def normal_blocks = assert(JobProbe.events.none? { |item| item.first == :nonlocal_exit }, "Job left the transaction block nonlocally")
def check(name)
  fixture
  yield
  CHECKS << name
rescue StandardError => error
  FAILURES << { name: name, failure: error.message }
end
check("admission commits before the sole synthetic transport; exact receipt recorded") do
  execute
  assert(JobProbe.row.status == "submitted_to_mailer" && JobProbe.row.email_log_id == 99, "Missing actual mailer acceptance")
  assert(JobProbe.events.count { |item| item.first == :synthetic_send } == 1, "Not exactly one synthetic send")
  committed = JobProbe.events.index([:normal_commit, "sending"])
  prepared = JobProbe.events.index { |item| item.first == :message_prepared }
  constructed = JobProbe.events.index { |item| item.first == :sender_constructed }
  transported = JobProbe.events.index { |item| item.first == :synthetic_send }
  assert(committed && prepared && constructed && transported && committed < prepared && prepared < constructed && constructed < transported, "Mailer construction preceded committed admission")
  normal_blocks
end
%w[sending submitted_to_mailer delivery_unconfirmed delivery_failed cancelled].each do |status|
  check("#{status} request cannot be sent by another job") do
    JobProbe.row.values[:status] = status
    execute
    no_mail_work
    assert(JobProbe.row.status == status, "Existing receipt state changed")
    normal_blocks
  end
end
check("missing request is a normal no-op") do
  JobProbe.row = nil
  execute
  no_mail_work
  normal_blocks
end
check("lost administrator authority cancels without transport or nonlocal transaction exit") do
  JobProbe.row.actor.allowed = false
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("disabled support cancels before admission") do
  JobProbe.state.enabled = false
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("wrong fixed request destination cannot be sent") do
  JobProbe.row.values[:request_destination] = "synthetic-wrong-destination.invalid"
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("administrator revocation between locks cancels after admitted sending state") do
  JobProbe.before_transaction = ->(number) { JobProbe.row.actor.allowed = false if number == 2 }
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("support revocation between locks cancels before synthetic transport") do
  JobProbe.before_transaction = ->(number) { JobProbe.state.enabled = false if number == 2 }
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("plugin disable between locks cancels before synthetic transport") do
  JobProbe.before_transaction = ->(number) { SiteSetting.discussion_bridge_enabled = false if number == 2 }
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Not cancelled")
  normal_blocks
end
check("ambiguous synthetic transport failure is retained and is never sent twice") do
  JobProbe.mailer_outcome = :raise
  execute
  assert(JobProbe.row.status == "delivery_unconfirmed" && JobProbe.row.failure_code == "native_mailer_exception", "Ambiguity not retained")
  execute
  assert(JobProbe.events.count { |item| item.first == :synthetic_send } == 1, "Duplicate send after ambiguous outcome")
  assert(!JSON.generate(JobProbe.row.values.reject { |key, _| key == :actor }).include?("synthetic private transport sentinel"), "Private raw exception retained")
end
check("non-EmailLog result is unconfirmed and cannot be automatically resent") do
  JobProbe.mailer_outcome = :unconfirmed
  execute
  assert(JobProbe.row.status == "delivery_unconfirmed", "False mailer success")
  execute
  assert(JobProbe.events.count { |item| item.first == :synthetic_send } == 1, "Repeated unconfirmed send")
end
%w[queued queue_unconfirmed].each do |status|
  check("#{status} admits one synthetic transport and never a second") do
    JobProbe.row.values[:status] = status
    execute
    execute
    assert(JobProbe.row.status == "submitted_to_mailer", "Admission failed")
    assert(JobProbe.events.count { |item| item.first == :synthetic_send } == 1, "Duplicate send")
    normal_blocks
  end
end
check("audit exception rolls back the receipt and retains an unconfirmed outcome without resend") do
  JobProbe.audit_failure = true
  execute
  assert(JobProbe.row.status == "delivery_unconfirmed" && JobProbe.row.failure_code == "native_mailer_exception", "Rolled-back acceptance falsely retained")
  assert(JobProbe.row.values[:email_log_id].nil? && JobProbe.row.values[:submitted_at].nil?, "Rolled-back receipt metadata survived")
  assert(JobProbe.events.any? { |item| item.first == :rollback }, "No transaction rollback observed")
  execute
  assert(JobProbe.events.count { |item| item.first == :synthetic_send } == 1, "Duplicate send after audit rollback")
end
check("deleted actor cancels without constructing mail") do
  JobProbe.row.values[:actor] = nil
  execute
  no_mail_work
  assert(JobProbe.row.status == "cancelled", "Deleted actor not cancelled")
  normal_blocks
end
check("transaction fixture rolls back native fields while external attempt evidence survives") do
  begin
    DiscussionBridge::SupportAccess.locked do
      JobProbe.row.update!(status: "sending", email_log_id: 99)
      JobProbe.events << [:external_attempt_marker]
      raise "synthetic fixture rollback"
    end
  rescue RuntimeError
    # Native rollback must not erase an external attempt trace.
  end
  assert(JobProbe.row.status == "pending" && JobProbe.row.values[:email_log_id].nil?, "Fixture failed to roll back row state")
  assert(JobProbe.events.any? { |item| item.first == :external_attempt_marker }, "External evidence erased by rollback")
end
puts JSON.pretty_generate(checks: CHECKS.size + FAILURES.size, passed: CHECKS, failures: FAILURES, runtime: RUBY_DESCRIPTION,
  boundary: "Actual job and SupportAccess.locked with synthetic native rows/exception rollback/transaction completion/authority/mailer. No actual email, account, server, database transaction or delivery executed. A normal-block completion check does not establish real Rails commit behavior.")
exit(FAILURES.empty? ? 0 : 1)
