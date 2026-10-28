# frozen_string_literal: true

# Standalone author checks: execute the actual support control modules against
# explicit native-framework seams. No database, Core session or account mutation.
require "json"

class Object
  def deep_dup
    Marshal.load(Marshal.dump(self))
  end
end

module Discourse
  class InvalidAccess < StandardError; end
end

module ActiveRecord
  class RecordNotFound < StandardError; end
end

class User
  attr_accessor :id, :persisted, :active, :staged, :suspended, :silenced, :on_reload, :guardian
  attr_reader :reloads, :admin, :moderator

  def initialize(id: 41)
    @id, @persisted, @active, @staged, @suspended, @silenced = id, true, true, false, false, false
    @reloads, @admin, @moderator = 0, false, false
    @guardian = GuardianSeam.new
  end

  def persisted? = persisted
  def active? = active
  def staged? = staged
  def suspended? = suspended
  def silenced? = silenced
  def staff? = admin || moderator

  def reload
    @reloads += 1
    on_reload&.call(self)
    self
  end

  def admin=(_value)
    raise "Support must never promote a native user"
  end
  def moderator=(_value)
    raise "Support must never promote a native user"
  end
end

class GuardianSeam
  attr_accessor :visible
  attr_reader :seen
  def initialize = (@visible, @seen = true, [])
  def ensure_can_see!(topic)
    @seen << topic.id
    raise Discourse::InvalidAccess unless visible
    true
  end
end

module SiteSetting
  class << self
    attr_accessor :discussion_bridge_enabled
  end
end

class SupportStateSeam
  attr_accessor :enabled, :on_reload
  attr_reader :reloads
  def initialize = (@enabled, @reloads = true, 0)
  def reload
    @reloads += 1
    on_reload&.call(self)
    self
  end
end

class DiscussionBridgeSupportState
  class << self
    attr_accessor :row, :events
    def transaction
      events << :transaction
      yield
    end
    def lock
      events << :lock
      self
    end
    def find(id)
      events << [:find, id]
      raise ActiveRecord::RecordNotFound unless id == 1 && row
      row
    end
  end
end

class DiscussionBridgeSupportGrant
  class << self
    attr_accessor :rows, :queries
    def active = self
    def exists?(user_id:)
      queries << user_id
      rows.any? { |row| row.fetch(:user_id) == user_id && row[:revoked_at].nil? }
    end
  end
end

class ConnectionSeam
  attr_accessor :id, :enabled, :current, :on_reload, :configuration
  attr_reader :reloads
  def initialize(id: 8)
    @id, @enabled, @current, @reloads = id, true, true, 0
  end
  def reload
    @reloads += 1
    on_reload&.call(self)
    self
  end
end

class TopicSeam
  attr_accessor :id, :publicly_available, :on_reload, :visible, :category_id
  attr_reader :reloads
  def initialize(id: 7, category_id: 11, visible: true)
    @id, @publicly_available, @reloads = id, true, 0
    @category_id, @visible = category_id, visible
  end
  def reload
    @reloads += 1
    on_reload&.call(self)
    self
  end
end

module DiscussionBridge
  module CmsConfiguration
    class << self
      attr_accessor :calls
      def current!(connection, require_enabled:)
        calls << [connection.id, require_enabled]
        raise Discourse::InvalidAccess unless connection.current && (!require_enabled || connection.enabled)
        connection.configuration
      end
    end
  end
  module SourceEdition
    def self.publicly_available?(topic) = topic.publicly_available
  end
end

require_relative "../../lib/discussion_bridge/support_topic_selection"
require_relative "../../lib/discussion_bridge/support_access"

CHECKS = []
FAILURES = []

def assert(value, message)
  raise message unless value
end

def denies(error = Discourse::InvalidAccess)
  begin
    yield
  rescue error => failure
    return failure
  end
  raise "Expected #{error}"
end

def run(name)
  yield
  CHECKS << name
rescue StandardError => error
  FAILURES << { check: name, error: "#{error.class}: #{error.message}" }
end

def configuration_fixture
  {
    "name" => "Current connection", "platform" => "wordpress", "base_url" => "https://source.example",
    "policy" => {
      "include_topic_ids" => %w[3 7], "exclude_topic_ids" => %w[4], "policy_revision" => "r1",
      "selection" => "categories", "category_ids" => %w[11], "include_unlisted" => false,
    },
  }
end

def access_fixture
  actor, state, connection, topic = User.new, SupportStateSeam.new, ConnectionSeam.new, TopicSeam.new
  connection.configuration = configuration_fixture
  SiteSetting.discussion_bridge_enabled = true
  DiscussionBridgeSupportGrant.rows = [{ user_id: actor.id, revoked_at: nil }]
  DiscussionBridgeSupportGrant.queries = []
  DiscussionBridgeSupportState.row = state
  DiscussionBridgeSupportState.events = []
  DiscussionBridge::CmsConfiguration.calls = []
  [actor, state, connection, topic]
end

def authorize(actor, state, connection = nil, action: "check")
  DiscussionBridge::SupportAccess.operator!(actor, state: state, action: action, connection: connection)
end

run("selection moves only the named topic and preserves both caller inputs") do
  before = configuration_fixture
  original = before.deep_dup
  after = DiscussionBridge::SupportTopicSelection.configuration(before, "7", selected: false)
  assert(before == original, "Selection mutated the caller configuration")
  assert(after.fetch("policy").fetch("include_topic_ids") == %w[3], "Named topic remained included")
  assert(after.fetch("policy").fetch("exclude_topic_ids") == %w[4 7], "Named topic not excluded")
  after.fetch("policy")["policy_revision"] = "r2"
  after_snapshot = after.deep_dup
  assert(DiscussionBridge::SupportTopicSelection.validate_change!(before, after, "7"), "Legitimate selection rejected")
  assert(before == original && after == after_snapshot, "Validation mutated either input")
  after.fetch("policy").fetch("category_ids") << "99"
  assert(before == original, "Returned configuration shares nested policy with its input")
end

run("selection can include an excluded topic without altering other selections") do
  before = configuration_fixture
  after = DiscussionBridge::SupportTopicSelection.configuration(before, "4", selected: true)
  assert(after.fetch("policy").fetch("include_topic_ids") == %w[3 7 4], "Topic not included")
  assert(after.fetch("policy").fetch("exclude_topic_ids").empty?, "Topic remained excluded")
  DiscussionBridge::SupportTopicSelection.validate_change!(before, after, "4")
  [nil, "true", 1].each do |invalid|
    denies { DiscussionBridge::SupportTopicSelection.configuration(before, "4", selected: invalid) }
  end
end

run("selection rejects changes to global policy and connection fields") do
  before = configuration_fixture
  [
    ->(after) { after["name"] = "Changed connection" },
    ->(after) { after["base_url"] = "https://other.example" },
    ->(after) { after.fetch("policy")["selection"] = "all_public" },
    ->(after) { after.fetch("policy")["include_unlisted"] = true },
    ->(after) { after.fetch("policy").fetch("category_ids") << "99" },
  ].each do |change|
    after = DiscussionBridge::SupportTopicSelection.configuration(before, "7", selected: false)
    change.call(after)
    denies { DiscussionBridge::SupportTopicSelection.validate_change!(before, after, "7") }
  end
end

run("selection rejects additions removal or movement of any other topic") do
  before = configuration_fixture
  [
    ->(policy) { policy.fetch("include_topic_ids") << "99" },
    ->(policy) { policy.fetch("include_topic_ids").delete("3") },
    ->(policy) { policy.fetch("exclude_topic_ids").delete("4"); policy.fetch("include_topic_ids") << "4" },
  ].each do |change|
    after = DiscussionBridge::SupportTopicSelection.configuration(before, "7", selected: false)
    change.call(after.fetch("policy"))
    denies { DiscussionBridge::SupportTopicSelection.validate_change!(before, after, "7") }
  end
end

run("visible topic outside configured categories and explicit lists is denied") do
  actor, state, connection = access_fixture
  topic = TopicSeam.new(id: 99, category_id: 22)
  policy = connection.configuration.fetch("policy")
  snapshot = policy.deep_dup
  assert(!DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "Visibility alone expanded source scope")
  guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "select_topic", topic: topic)
  denies { guard.call(actor, connection) }
  assert(policy == snapshot, "Scope checking changed configured policy")
end

run("configured category permits a visible topic and current policy is rechecked") do
  actor, state, connection = access_fixture
  topic = TopicSeam.new(id: 99, category_id: 11)
  policy = connection.configuration.fetch("policy")
  assert(DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "Configured category denied")
  guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "select_topic", topic: topic)
  assert(guard.call(actor, connection), "In-category topic authorization denied")
  policy["category_ids"] = %w[22]
  denies { guard.call(actor, connection) }
end

run("explicit include or exclude permits named topic outside configured categories") do
  actor, state, connection = access_fixture
  topic = TopicSeam.new(id: 99, category_id: 22)
  policy = connection.configuration.fetch("policy")
  %w[include_topic_ids exclude_topic_ids].each do |field|
    policy["include_topic_ids"] = []
    policy["exclude_topic_ids"] = []
    policy.fetch(field) << topic.id.to_s
    assert(DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "Existing explicit topic scope denied")
    guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "select_topic", topic: topic)
    assert(guard.call(actor, connection), "Explicit topic authorization denied")
  end
end

run("all_public permits visible outside-category topics without widening category policy") do
  _, _, connection = access_fixture
  topic = TopicSeam.new(id: 99, category_id: 22)
  policy = connection.configuration.fetch("policy")
  policy["selection"] = "all_public"
  assert(DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "all_public visible topic denied")
  assert(policy.fetch("category_ids") == %w[11], "Scope helper changed configured categories")
end

run("unlisted topics require include_unlisted across every permitted source boundary") do
  %i[category all_public include exclude].each do |boundary|
    _, _, connection = access_fixture
    topic = TopicSeam.new(id: 99, category_id: 22, visible: false)
    policy = connection.configuration.fetch("policy")
    case boundary
    when :category then topic.category_id = 11
    when :all_public then policy["selection"] = "all_public"
    when :include then policy.fetch("include_topic_ids") << topic.id.to_s
    when :exclude then policy.fetch("exclude_topic_ids") << topic.id.to_s
    end
    assert(!DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "Unlisted topic accepted without opt-in")
    policy["include_unlisted"] = true
    assert(DiscussionBridge::SupportTopicSelection.source_in_scope?(topic, policy), "Explicitly permitted unlisted topic denied")
  end
end

run("ordinary native grantee may use each approved action without promotion") do
  actor, state, connection = access_fixture
  %w[status check retry select_topic synchronize].each do |action|
    assert(authorize(actor, state, connection, action: action), "Approved action denied")
  end
  assert(!actor.staff? && !actor.admin && !actor.moderator, "Native role changed")
  assert(actor.reloads == 5 && state.reloads == 5 && connection.reloads == 5, "Current native rows not reloaded")
end

run("unapproved actions cannot use an otherwise valid grant") do
  actor, state, connection = access_fixture
  %w[grant revoke manage_connections secrets global_policy url_migration].each do |action|
    denies { authorize(actor, state, connection, action: action) }
  end
  assert(actor.reloads.zero? && DiscussionBridgeSupportGrant.queries.empty?, "Unapproved action reached grant evaluation")
end

run("only a persisted positive-id native User is eligible") do
  actor, state = access_fixture
  [nil, Object.new, User.new(id: 0), User.new(id: -1)].each do |invalid|
    denies { authorize(invalid, state) }
  end
  actor.persisted = false
  denies { authorize(actor, state) }
end

run("native status is rechecked on reload including deletion") do
  %i[active staged suspended silenced].each do |attribute|
    actor, state = access_fixture
    actor.on_reload = ->(user) { user.public_send("#{attribute}=", attribute != :active) }
    denies { authorize(actor, state) }
    assert(actor.reloads == 1, "Native user status not refreshed")
  end
  actor, state = access_fixture
  actor.on_reload = ->(_user) { raise ActiveRecord::RecordNotFound }
  denies { authorize(actor, state) }
end

run("plugin enablement and freshly reloaded support enablement both gate actions") do
  actor, state = access_fixture
  SiteSetting.discussion_bridge_enabled = false
  denies { authorize(actor, state) }
  actor, state = access_fixture
  state.on_reload = ->(current) { current.enabled = false }
  denies { authorize(actor, state) }
  assert(state.reloads == 1, "Support state was trusted without reload")
end

run("every action queries an active grant for the exact native user") do
  actor, state = access_fixture
  assert(authorize(actor, state), "Initial active grant denied")
  DiscussionBridgeSupportGrant.rows.first[:revoked_at] = "revoked"
  denies { authorize(actor, state) }
  DiscussionBridgeSupportGrant.rows = [{ user_id: actor.id + 1, revoked_at: nil }]
  denies { authorize(actor, state) }
  assert(DiscussionBridgeSupportGrant.queries == [actor.id] * 3, "Grant lookup reused stale authorization or another user")
end

run("revocation during the current state reload is observed before access") do
  actor, state = access_fixture
  state.on_reload = ->(_current) { DiscussionBridgeSupportGrant.rows.first[:revoked_at] = "revoked" }
  denies { authorize(actor, state) }
end

run("connection current state is reloaded and revalidated for each action") do
  actor, state, connection = access_fixture
  connection.on_reload = ->(current) { current.enabled = false }
  denies { authorize(actor, state, connection) }
  assert(connection.reloads == 1, "Connection not refreshed")
  assert(authorize(actor, state, connection, action: "status"), "Read status unnecessarily requires enabled publication")
  connection.on_reload = ->(current) { current.current = false }
  denies { authorize(actor, state, connection, action: "status") }
  assert(DiscussionBridge::CmsConfiguration.calls == [[connection.id, true], [connection.id, false], [connection.id, false]], "Current configuration gate not applied with action scope")
end

run("locked actions yield the singleton native row inside transaction and row lock") do
  _, state = access_fixture
  yielded = nil
  DiscussionBridge::SupportAccess.locked { |current| yielded = current }
  assert(yielded.equal?(state), "Wrong support state yielded")
  assert(DiscussionBridgeSupportState.events == [:transaction, :lock, [:find, 1]], "Singleton lock seam not used")
end

run("reusable authorization binds the actor and connection and rechecks revocation") do
  actor, state, connection = access_fixture
  guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "retry")
  assert(guard.call(actor, connection), "Initial authorization denied")
  denies { guard.call(User.new(id: actor.id + 1), connection) }
  denies { guard.call(actor, ConnectionSeam.new(id: connection.id + 1)) }
  DiscussionBridgeSupportGrant.rows.first[:revoked_at] = "revoked"
  denies { guard.call(actor, connection) }
end

run("topic authorization refreshes native visibility and public eligibility") do
  actor, state, connection, topic = access_fixture
  guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "synchronize", topic: topic)
  assert(guard.call(actor, connection), "Visible eligible topic denied")
  actor.guardian.visible = false
  denies { guard.call(actor, connection) }
  actor.guardian.visible = true
  topic.on_reload = ->(current) { current.publicly_available = false }
  denies { guard.call(actor, connection) }
  assert(topic.reloads == 3, "Current topic eligibility not enforced")
  assert(actor.guardian.seen == [topic.id] * 3, "Native topic visibility not checked each time")
end

run("configuration authorization permits only selection after current native checks") do
  actor, state, connection, topic = access_fixture
  before = configuration_fixture
  after = DiscussionBridge::SupportTopicSelection.configuration(before, topic.id.to_s, selected: false)
  guard = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "select_topic", topic: topic)
  assert(guard.authorize_configuration!(actor, connection, previous_configuration: before, configuration: after), "Named selection denied")
  after["platform"] = "statamic"
  denies { guard.authorize_configuration!(actor, connection, previous_configuration: before, configuration: after) }
  wrong_action = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "check", topic: topic)
  denies { wrong_action.authorize_configuration!(actor, connection, previous_configuration: before, configuration: before) }
  missing_topic = DiscussionBridge::SupportAccess::Authorization.new(actor: actor, state: state, connection: connection, action: "select_topic")
  denies { missing_topic.authorize_configuration!(actor, connection, previous_configuration: before, configuration: before) }
  DiscussionBridgeSupportGrant.rows.first[:revoked_at] = "revoked"
  denies { guard.authorize_configuration!(actor, connection, previous_configuration: before, configuration: before) }
end

puts JSON.pretty_generate(
  checks: CHECKS.length, passed: CHECKS, failures: FAILURES, runtime: RUBY_DESCRIPTION,
  boundary: "Actual SupportTopicSelection and SupportAccess modules; synthetic User/Guardian/state/grant/connection/topic/CmsConfiguration/SourceEdition seams. No real Core permissions, ActiveRecord transactions/locks, database, mail, account, browser or hosted execution. Native user remains ordinary throughout."
)
exit(FAILURES.empty? ? 0 : 1)
