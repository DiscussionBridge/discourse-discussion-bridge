# frozen_string_literal: true
return if defined?(Rails::Application)
# Actual coordinator/recovery/configuration/authority/controller methods with
# explicit process-local persistence, source-capture and framework seams.
# No Rails boot, PostgreSQL, network, services or filesystem writes.
require "json"
require "digest"
require "securerandom"
require "stringio"
require "active_support"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/except"
require "active_support/security_utils"
ROOT = File.expand_path("../..", __dir__)
FIXTURES = JSON.parse(File.read(File.join(ROOT, "spec/fixtures/attention-recovery.json")))
class Time
  def self.current = utc(2026, 10, 25, 22)
end
module SiteSetting
  def self.method_missing(*) = true
  def self.login_required = false
end
module Discourse
  class InvalidAccess < StandardError; end
end
module ActiveRecord
  class RecordNotFound < StandardError; end
  class Base
    def self.sanitize_sql_like(value) = value.gsub("%", "\\%").gsub("_", "\\_")
  end
end
class Relation
  include Enumerable
  attr_reader :rows, :model
  def initialize(model, rows = model.records) = (@model, @rows = model, rows)
  def each(&block) = rows.each(&block)
  def joins(*) = self
  def lock = self
  def not(filter) = self.class.new(model, rows.reject { |row| matches(row, filter) })
  def where(filter = nil, *arguments, **kw)
    filter ||= kw
    return self if filter.empty?
    if filter.is_a?(String)
      key = filter.split.first.split(".").last
      value = arguments.first
      return self.class.new(model, rows.select { |row| row.public_send(key) && row.public_send(key) > value }) if filter.include?(" > ")
      return self.class.new(model, rows.select { |row| row.public_send(key) && row.public_send(key) <= value }) if filter.include?(" <= ")
      return self if filter.include?(" LIKE ") # SQL scope is a declared native-DB gate.
      raise "Unhandled fixture SQL: #{filter}"
    end
    self.class.new(model, rows.select { |row| matches(row, filter) })
  end
  def matches(row, filter)
    filter.all? do |key, expected|
      target = case key.to_s
      when "discussion_bridge_cms_mappings" then row.cms_mapping
      when "discussion_bridge_content_bindings" then row.cms_mapping.content_binding
      when "discussion_bridge_bridge_records" then row.cms_mapping.content_binding.bridge_record
      else row
      end
      expected.is_a?(Hash) ? matches(target, expected) :
        (expected.is_a?(Array) ? expected.include?(target.public_send(key)) : target.public_send(key) == expected)
    end
  end
  def order(*keys, **kw)
    if kw.any?
      order_key, direction = kw.first
      sorted = rows.sort_by { |row| row.public_send(order_key) }
      sorted.reverse! if direction == :desc
    else
      names = keys.map { |field| field.to_s.split(".").last.to_sym }
      sorted = rows.sort_by { |row| names.map { |field| row.public_send(field) } }
    end
    self.class.new(model, sorted)
  end
  def limit(value) = self.class.new(model, rows.first(value))
  def first = rows.first
  def count = rows.size
  def exists? = !rows.empty?
  def to_a = rows
  def pluck(*keys) = rows.map { |row| keys.map { |key| row.public_send(key) } }
  def find_each(**, &block) = rows.each(&block)
  def find(id) = rows.find { |row| row.id == id } || raise(ActiveRecord::RecordNotFound)
  def find_by(**filter) = where(filter).first
  def create!(**attrs) = model.create!(**(rows.first && model == DiscussionBridgeCmsWork ? {cms_mapping_id: rows.first.cms_mapping_id} : {}).merge(attrs))
  def update_all(**attrs) = rows.each { |row| row.update!(**attrs) }
end
class Row
  MODELS = []
  def self.inherited(child) = (MODELS << child; child.records = [])
  class << self
    attr_accessor :records
    def create!(**attrs)
      row = new(**{ id: (records.map(&:id).max || 0) + 1 }.merge(attrs))
      records << row
      row
    end
    def where(*args, **kw) = Relation.new(self).where(*args, **kw)
    def joins(*) = Relation.new(self)
    def lock = Relation.new(self)
    def find_by(filter = nil, **kw) = where(filter || kw).first
    def table_name = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase + "s"
    def transaction(**)
      yield
    end
  end
  def initialize(**attrs) = @attrs = attrs
  def method_missing(name, *values)
    key = name.to_s
    return @attrs[key.delete_suffix("=").to_sym] = values.first if key.end_with?("=")
    return !!@attrs[key.delete_suffix("?").to_sym] if key.end_with?("?")
    @attrs[name]
  end
  def respond_to_missing?(*) = true
  def update!(**attrs) = (@attrs.merge!(attrs); self)
  def lock! = self
  def reload = self
  def persisted? = true
  def attributes = @attrs.reject { |_key, value| value.is_a?(Row) || value.is_a?(Relation) }.transform_keys(&:to_s)
  def cms_mapping = DiscussionBridgeCmsMapping.find_by(id: @attrs[:cms_mapping_id])
  def cms_work = DiscussionBridgeCmsWork.find_by(id: @attrs[:cms_work_id])
  def successor_work = DiscussionBridgeCmsWork.find_by(id: @attrs[:successor_work_id])
  def work_items = DiscussionBridgeCmsWork.where(cms_mapping_id: id)
end
class DiscussionBridgeContentConnection < Row
  def authenticate_secret?(value) = value == "synthetic-cms-secret"
  def allows_direction?(value) = allowed_directions.include?(value)
  def allows_lane?(value) = allowed_lanes.include?(value)
end
class DiscussionBridgeCmsMapping < Row; end
class DiscussionBridgeCmsWork < Row
  LIVE_STATES = %w[leased synchronized deployed].freeze
  UNCOMPLETED_STATES = %w[pending leased synchronized deployed retry_wait attention].freeze
end
class DiscussionBridgeCmsMutationReceipt < Row; end
class DiscussionBridgeCmsAttentionInspection < Row; end
class DiscussionBridgeCmsAttentionRecovery < Row; end
class DiscussionBridgeCmsUrlMove < Row; end
class DiscussionBridgeCmsSourceStream < Row; end
class DiscussionBridgeCmsUrlHistoryEntry < Row; end
class User < Row
  def guardian = GuardianFixture.new
end
class GuardianFixture
  def ensure_can_see!(topic)
    raise Discourse::InvalidAccess unless topic.visible
  end
end
module DiscussionBridge
  PLUGIN_NAME = "discourse-discussion-bridge"
  class SourceEdition
    class Unavailable < StandardError; end
    class InvalidForumName < StandardError; end
    def self.publicly_available?(topic) = topic.visible
  end
  module CmsReceiptCipher
    # Encryption is a declared test seam; actual semantics are preserved trees.
    def self.encrypt(value) = Marshal.load(Marshal.dump(value))
    def self.decrypt(value) = Marshal.load(Marshal.dump(value))
  end
  module CmsCatalogStore
    Availability = Data.define(:available, :missing_ids, :unavailable_ids, :catalog_errors)
    class << self
      attr_accessor :missing
      def selected_availability(*)
        Availability.new(available: !missing, missing_ids: {"authors" => missing ? ["missing"] : [], "taxonomy" => []},
          unavailable_ids: {"authors" => [], "taxonomy" => []}, catalog_errors: {})
      end
    end
  end
end
%w[cms_protocol cms_configuration cms_mapping_projection cms_authority_lifecycle cms_source_store
   cms_catalog_availability_lifecycle cms_attention_evidence cms_work_coordinator cms_attention_recovery].each do |name|
  require File.join(ROOT, "lib/discussion_bridge", name)
end
module DiscussionBridge
  class CmsSourceStore
    class << self
      attr_accessor :source, :unavailable
    end
    def capture_snapshot(topic)
      raise SourceEdition::Unavailable if self.class.unavailable
      Snapshot.new(metadata: self.class.source.key?("source_id") ? self.class.source : self.class.source.fetch(topic.id), body: "synthetic")
    end
  end
end
class ApplicationController
  def self.requires_plugin(*) = nil
  def self.before_action(*) = nil
  def self.skip_before_action(*) = nil
  def self.rescue_from(*) = nil
end
require File.join(ROOT, "app/controllers/discussion_bridge/cms_work_controller")
require File.join(ROOT, "app/controllers/discussion_bridge/cms_attention_controller")
require File.join(ROOT, "lib/discussion_bridge/cms_json_transport_guard")
module Admin
  class AdminController
    def self.requires_plugin(*) = nil
    def self.before_action(*) = nil
    def self.rescue_from(*) = nil
  end
end
require File.join(ROOT, "app/controllers/discussion_bridge/cms_admin_attention_controller")

CHECKS = []
FAILURES = []
def assert(value, message) = (raise(message) unless value)
def run(name)
  yield
  CHECKS << name
rescue StandardError => error
  FAILURES << { check: name, type: error.class.name, error: error.message, location: error.backtrace&.first }
end
def expect_error(code = nil)
  begin
    yield
  rescue DiscussionBridge::CmsProtocol::Error => error
    assert(code.nil? || error.code == code, "expected #{code}, got #{error.code}")
    return
  end
  raise "expected protocol rejection #{code}"
end
def fixture(kind = "initial")
  Row::MODELS.each { |model| model.records = [] }
  input = Marshal.load(Marshal.dump(FIXTURES.fetch(kind)))
  i = input.fetch("inspection")
  m = i.fetch("mapping")
  w = i.fetch("work")
  config = { "profile" => "astro", "destination_origin" => "https://astro.example", "publication_lane" => "news",
    "native_capabilities" => {"native_revision" => "synthetic:1", "supported_presentations" => %w[simple full interactive],
      "publication_kind" => "static", "complete_content_supported" => true},
    "policy" => {"policy_revision" => w.fetch("policy_revision"), "enabled" => true, "selection" => "all_public",
      "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
      "publication_kind" => "static", "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => []} }
  conn = DiscussionBridgeContentConnection.create!(public_id: m.fetch("connection_id"), cms_configuration: config,
    enabled: true, platform: "astro", allowed_origins: ["https://astro.example"], allowed_directions: ["from_discourse"],
    allowed_lanes: ["news"], secret_digest: "s" * 64)
  topic = Row.new(id: 53, visible: true)
  record = Row.new(resource_id: m.fetch("resource_id"), direction: "from_discourse", lane: "news", topic: topic)
  binding = Row.new(content_connection_id: conn.id, role: "presentation", state: "active", bridge_record: record,
    canonical_url: m.fetch("canonical_url"), external_id: m.fetch("external_id"))
  mapping = DiscussionBridgeCmsMapping.create!(**m.transform_keys(&:to_sym), content_connection_id: conn.id,
    content_connection: conn, content_binding: binding, fence_generation: 9, prepared_transaction: i["prepared_transaction"],
    native_result: i["native_result"], verified_result: i["verified_native_result"] && {
      "native_result" => i["verified_native_result"], "verification" => i["verification"]})
  %i[source_created_at source_updated_at synchronized_at publicly_verified_at].each do |key|
    mapping.update!(key => mapping.public_send(key) && Time.iso8601(mapping.public_send(key)))
  end
  work = DiscussionBridgeCmsWork.create!(**w.transform_keys(&:to_sym).except(:mapping_id, :source_id), cms_mapping_id: mapping.id,
    source_snapshot: i["source"], failure_detail: {"code" => "synthetic_failure"}, created_at: Time.current,
    same_intent_hold: false)
  actor = User.create!(admin: true, active: true, staged: false, suspended: false)
  DiscussionBridge::CmsSourceStore.source = i["source"]
  DiscussionBridge::CmsSourceStore.unavailable = false
  DiscussionBridge::CmsCatalogStore.missing = false
  service = DiscussionBridge::CmsAttentionRecovery.new(conn, clock: -> { Time.current })
  [service, conn, mapping, work, actor, input.fetch("observation")]
end
def check(service, work, actor)
  service.check(actor: actor, input: {"mutation_id" => SecureRandom.uuid,
    "selected" => [{"work_id" => work.work_id, "mapping_revision" => work.cms_mapping.mapping_revision}]}).body.fetch("items").first
end
def report(service, item, observation)
  inspection = DiscussionBridgeCmsAttentionInspection.find_by(inspection_id: item.fetch("inspection_id"))
  body = {"mutation_id" => SecureRandom.uuid, "context_sha256" => inspection.context_sha256, "observation" => observation}
  [service.report(inspection.inspection_id, body), inspection, body]
end
def retry_input(inspection, settle: false)
  {"mutation_id" => SecureRandom.uuid, "selected" => [{"inspection_id" => inspection.inspection_id,
    "context_sha256" => inspection.context_sha256, "settle_restored_baseline" => settle}]}
end

