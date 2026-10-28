# frozen_string_literal: true

# Local producer regressions execute the actual CmsSourceStore and CmsProtocol.
# The explicit in-memory relation/model doubles below supply query results and
# persistence only. They do NOT qualify PostgreSQL ordering/collation, unique
# indexes, transactional rollback, row-lock serialization or crash durability.
# Native coverage belongs to spec/lib/cms_source_ordering_spec.rb.
require "json"
require "digest"

class Object
  def blank? = respond_to?(:empty?) ? empty? : !self
  def present? = !blank?
  def presence = present? ? self : nil
end
class String
  def blank? = match?(/\A\p{Space}*\z/)
end

root = File.expand_path("../..", __dir__)
require File.join(root, "lib/discussion_bridge/cms_protocol")
require File.join(root, "lib/discussion_bridge/cms_source_store")

module ProducerDoubles
  class << self
    attr_accessor :streams, :cursors, :snapshots, :events, :queries, :trace, :next_id
    def reset
      self.streams = []
      self.cursors = []
      self.snapshots = []
      self.events = []
      self.queries = []
      self.trace = []
      self.next_id = 0
    end
    def id
      self.next_id += 1
    end
  end

  class Record
    def initialize(**fields) = @fields = fields
    def update!(fields)
      @fields.merge!(fields)
      self
    end
    def method_missing(name, *arguments)
      return @fields[name] if arguments.empty? && @fields.key?(name)
      super
    end
    def respond_to_missing?(name, private_access = false) = @fields.key?(name) || super
  end

  class Relation
    def initialize(rows, &builder)
      @rows = rows
      @builder = builder
    end
    def where(condition, *arguments)
      ProducerDoubles.queries << [:where, condition, arguments]
      rows =
        if condition.is_a?(Hash)
          @rows.select { |row| condition.all? { |key, value| row.public_send(key) == value } }
        elsif condition == "event_sequence > ? AND event_sequence <= ?"
          low, high = arguments
          @rows.select { |row| row.event_sequence > low && row.event_sequence <= high }
        elsif condition == "ordinal >= ?"
          @rows.select { |row| row.ordinal >= arguments.fetch(0) }
        else
          raise "Unsupported model-double query: #{condition.inspect}"
        end
      self.class.new(rows, &@builder)
    end
    def order(key)
      ProducerDoubles.queries << [:order, key]
      rows =
        if key == 'source_id COLLATE "C"'
          @rows.sort_by { |row| row.source_id.b }
        else
          @rows.sort_by { |row| row.public_send(key) }
        end
      self.class.new(rows, &@builder)
    end
    def limit(count) = self.class.new(@rows.first(count), &@builder)
    def offset(count) = self.class.new(@rows.drop(count), &@builder)
    def includes(*) = self
    def lock
      ProducerDoubles.trace << "stream.lock"
      self
    end
    def first = @rows.first
    def exists? = !@rows.empty?
    def to_a = @rows.dup
    def pluck(key) = @rows.map { |row| row.public_send(key) }
    def find_by(**fields) = where(fields).first
    def create!(fields)
      raise "No model-double builder" unless @builder
      @builder.call(fields)
    end
  end

  class Stream < Record
    def initialize(connection, lane)
      super(id: ProducerDoubles.id, content_connection_id: connection.id, publication_lane: lane,
        event_sequence: 0, source_scope_revision: 0, scan_state: "complete", scan_scope_signature: nil)
      @events = []
      @intents = []
    end
    def source_events
      Relation.new(@events) do |fields|
        event = Record.new(**fields, id: ProducerDoubles.id)
        @events << event
        ProducerDoubles.events << event
        event
      end
    end
    def source_intents = Relation.new(@intents)
    def add_intent(fields)
      intent = Record.new(**fields, id: ProducerDoubles.id)
      @intents << intent
      intent
    end
    def source_cursors
      Relation.new(ProducerDoubles.cursors.select { |cursor| cursor.cms_source_stream_id == id }) do |fields|
        cursor = Cursor.new(**fields, id: ProducerDoubles.id, cms_source_stream: self,
          cms_source_stream_id: id, page_body: nil, invalidated_at: nil)
        ProducerDoubles.cursors << cursor
        cursor
      end
    end
  end

  class Cursor < Record
    def snapshot_items = Relation.new(ProducerDoubles.snapshots.select { |item| item.snapshot_root_id == id })
  end

  class Connection < Record
    def lock!
      ProducerDoubles.trace << "connection.lock"
      self
    end
  end

  def self.fixture
    reset
    config = { "publication_lane" => "news", "policy" => { "policy_revision" => "policy:1" } }
    connection = Connection.new(id: 1, public_id: "dbc_0123456789abcdef01234567", platform: "ghost",
      allowed_origins: ["https://site.example"], allowed_directions: ["from_discourse"],
      allowed_lanes: ["news"], config: config)
    stream = Stream.new(connection, "news")
    streams << stream
    store = DiscussionBridge::CmsSourceStore.new(connection, clock: -> { Time.utc(2026, 10, 24) })
    stream.update!(scan_scope_signature: store.scope_fingerprint(config))
    intent = stream.add_intent(topic_id: 42, source_id: "source:one", state: "revoked",
      publication_event_id: nil, current_source_revision: nil)
    [store, stream, intent, config]
  end
end

# These are test-only substitutes for ActiveRecord, framework settings and
# eligibility. Actual production CmsSourceStore methods are not replaced.
class DiscussionBridgeContentConnection
  def self.transaction
    ProducerDoubles.trace << "transaction.begin"
    result = yield
    ProducerDoubles.trace << "transaction.return"
    result
  end
end
class DiscussionBridgeCmsSourceStream
  def self.where(**fields) = ProducerDoubles::Relation.new(ProducerDoubles.streams).where(fields)
end
class DiscussionBridgeCmsSourceCursor
  def self.find_by(**fields) = ProducerDoubles::Relation.new(ProducerDoubles.cursors).find_by(**fields)
end
class DiscussionBridgeCmsSourceSnapshotItem
  def self.insert_all!(rows)
    rows.each do |fields|
      event = ProducerDoubles.events.find { |row| row.id == fields.fetch(:cms_source_event_id) }
      ProducerDoubles.snapshots << ProducerDoubles::Record.new(**fields, cms_source_event: event)
    end
  end
end
module Arel
  def self.sql(value) = value
end
module SiteSetting
  def self.discussion_bridge_enabled = true
  def self.discussion_bridge_endpoint_enabled = true
  def self.discussion_bridge_publisher_enabled = true
  def self.login_required = false
end
module DiscussionBridge::CmsConfiguration
  def self.current!(connection, require_enabled:) = connection.config
  def self.eligible?(_topic, _policy) = true
end
class Topic
  def self.unscoped = self
  def self.find_by(id:) = ProducerDoubles::Record.new(id: id)
end

def expect_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end
def expect_error(code)
  begin
    yield
  rescue DiscussionBridge::CmsProtocol::Error => error
    expect_equal(code, error.code)
    return
  end
  raise "Expected protocol error #{code}"
end
def revocation(intent)
  { "event_type" => "revocation", "source_id" => intent.source_id,
    "last_source_revision" => nil, "reason" => "source_ineligible" }
end
def allocate(store, intent)
  store.send(:transaction) do |config|
    stream = store.send(:stream!, config)
    store.send(:event!, stream, intent, revocation(intent))
  end
end
def insert_event(stream, intent, sequence, fields = revocation(intent))
  payload = fields.merge("event_id" => SecureRandom.uuid, "event_sequence" => sequence.to_s)
  DiscussionBridge::CmsProtocol.validate!("SourceEvent", payload)
  stream.source_events.create!(cms_source_intent: intent, event_id: payload.fetch("event_id"),
    event_sequence: sequence, payload: payload)
end
def cursor(store, stream, config, position:, high_water:, kind: "changes")
  store.send(:new_cursor!, stream, config, kind: kind, position: position, high_water: high_water).last
end
def retained_cursor(token)
  DiscussionBridgeCmsSourceCursor.find_by(token_digest: Digest::SHA256.hexdigest(token))
end
def poll(store, token) = store.feed("stream" => "changes", "cursor" => token).body
def sequences(page) = page.fetch("items").map { |event| event.fetch("event_sequence") }

checks = 0
failures = []
run = lambda do |name, &block|
  block.call
  checks += 1
  puts "ok #{checks} - #{name}"
rescue StandardError => error
  failures << { name: name, error: error.class.name, message: error.message, location: error.backtrace.first }
  puts "not ok - #{name}: #{error.class}: #{error.message}"
end

run.call("actual allocator increments exactly above 2^53 and invokes transaction/connection/stream locks") do
  store, stream, intent = ProducerDoubles.fixture
  stream.update!(event_sequence: 9_007_199_254_740_991)
  expect_equal(%w[9007199254740992 9007199254740993],
    [allocate(store, intent).payload.fetch("event_sequence"), allocate(store, intent).payload.fetch("event_sequence")])
  expect_equal(9_007_199_254_740_993, stream.event_sequence)
  expect_equal(["transaction.begin", "connection.lock", "stream.lock", "transaction.return"] * 2, ProducerDoubles.trace)
end

run.call("actual allocator reaches signed-64 maximum and refuses overflow without another insertion") do
  store, stream, intent = ProducerDoubles.fixture
  stream.update!(event_sequence: DiscussionBridge::CmsSourceStore::MAX_SEQUENCE - 2)
  expect_equal(%w[9223372036854775806 9223372036854775807],
    [allocate(store, intent).payload.fetch("event_sequence"), allocate(store, intent).payload.fetch("event_sequence")])
  expect_error("storage_exhausted") { allocate(store, intent) }
  expect_equal(2, stream.source_events.to_a.size)
  expect_equal(DiscussionBridge::CmsSourceStore::MAX_SEQUENCE, stream.event_sequence)
end

run.call("actual changes method requests numeric ordering despite reverse insertion and preserves large values") do
  store, stream, intent, config = ProducerDoubles.fixture
  [9_007_199_254_740_993, 9_007_199_254_740_992, 9_007_199_254_740_991].each { |n| insert_event(stream, intent, n) }
  stream.update!(event_sequence: 9_007_199_254_740_993)
  page = poll(store, cursor(store, stream, config, position: 9_007_199_254_740_990, high_water: 9_007_199_254_740_993))
  expect_equal(%w[9007199254740991 9007199254740992 9007199254740993], sequences(page))
  expect_equal(9_007_199_254_740_993, retained_cursor(page.fetch("checkpoint_cursor")).position)
  raise "Actual ordered query not invoked" unless ProducerDoubles.queries.include?([:order, :event_sequence])
  raise "Actual lower/upper bounds not invoked" unless ProducerDoubles.queries.include?(
    [:where, "event_sequence > ? AND event_sequence <= ?", [9_007_199_254_740_990, 9_007_199_254_740_993]])
end

run.call("fixed high-water survives page boundaries, exact replay and event creation before continuation") do
  store, stream, intent, config = ProducerDoubles.fixture
  105.downto(1) { |n| insert_event(stream, intent, n) }
  stream.update!(event_sequence: 105)
  token = cursor(store, stream, config, position: 0, high_water: 105)
  first = poll(store, token)
  expect_equal((1..100).map(&:to_s), sequences(first))
  expect_equal(100, retained_cursor(first.fetch("checkpoint_cursor")).position)
  expect_equal(105, retained_cursor(first.fetch("next_cursor")).high_water)
  expect_equal(106, allocate(store, intent).event_sequence)
  expect_equal(first, poll(store, token))
  final = poll(store, first.fetch("next_cursor"))
  expect_equal((101..105).map(&:to_s), sequences(final))
  expect_equal(nil, final.fetch("next_cursor"))
  expect_equal(["106"], sequences(poll(store, final.fetch("checkpoint_cursor"))))
end

run.call("empty completed changes page advances checkpoint to pinned high-water") do
  store, stream, _intent, config = ProducerDoubles.fixture
  stream.update!(event_sequence: 27)
  page = poll(store, cursor(store, stream, config, position: 9, high_water: 27))
  expect_equal([], sequences(page))
  expect_equal(nil, page.fetch("next_cursor"))
  expect_equal(27, retained_cursor(page.fetch("checkpoint_cursor")).position)
end

run.call("initial snapshot uses source-ID ordering and permits decreasing publication sequence") do
  store, stream, _intent, = ProducerDoubles.fixture
  [["source:z", 10], ["source:a", 20]].each do |source_id, sequence|
    intent = stream.add_intent(topic_id: 42, source_id: source_id, state: "active",
      current_source_revision: "revision:1", publication_event_id: nil)
    source = { "source_id" => source_id, "source_revision" => "revision:1", "topic_id" => "42",
      "topic_url" => "https://forum.example/t/source/42", "title" => "Source", "content_bytes" => 0,
      "content_sha256" => Digest::SHA256.hexdigest(""), "source_created_at" => nil,
      "source_updated_at" => nil, "source_authors" => [] }
    event = insert_event(stream, intent, sequence, { "event_type" => "publication", "source" => source })
    intent.update!(publication_event_id: event.id)
  end
  stream.update!(event_sequence: 20)
  page = store.feed("stream" => "initial").body
  expect_equal(%w[source:a source:z], page.fetch("items").map { |event| event.fetch("source").fetch("source_id") })
  expect_equal(%w[20 10], sequences(page))
  expect_equal(20, retained_cursor(page.fetch("checkpoint_cursor")).position)
  raise "Actual C collation query not invoked" unless ProducerDoubles.queries.include?([:order, 'source_id COLLATE "C"'])
end

run.call("empty initial snapshot emits changes checkpoint at its horizon") do
  store, stream, = ProducerDoubles.fixture
  stream.update!(event_sequence: 33)
  page = store.feed("stream" => "initial").body
  expect_equal([], page.fetch("items"))
  expect_equal(nil, page.fetch("next_cursor"))
  expect_equal(33, retained_cursor(page.fetch("checkpoint_cursor")).position)
end

run.call("a changed policy rejects an existing cursor without creating an advanced cursor") do
  store, stream, intent, config = ProducerDoubles.fixture
  allocate(store, intent)
  token = cursor(store, stream, config, position: 0, high_water: 1)
  before = ProducerDoubles.cursors.size
  config.fetch("policy")["policy_revision"] = "policy:2"
  expect_error("cursor_scope_changed") { poll(store, token) }
  expect_equal(before, ProducerDoubles.cursors.size)
end

run.call("an unknown cursor fails visibly rather than silently starting again") do
  store, = ProducerDoubles.fixture
  expect_error("cursor_invalid") { poll(store, "unknown_cursor") }
  expect_equal(0, ProducerDoubles.cursors.size)
end

puts JSON.generate(passed: checks, failed: failures.size, failures: failures,
  implementation: "actual CmsSourceStore + CmsProtocol",
  doubles: "ActiveRecord relations/models, settings and source eligibility",
  limits: "No native Rails/PostgreSQL, lock serialization, unique-index, rollback or crash-durability qualification")
exit(failures.empty? ? 0 : 1)
