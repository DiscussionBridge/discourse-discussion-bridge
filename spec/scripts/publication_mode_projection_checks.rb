# frozen_string_literal: true

# Executes the actual controller, current-configuration validation and Mapping
# projection without Rails. Native persistence and the unrelated delivery-state
# projection are explicit fixture boundaries; this is not PostgreSQL acceptance.
require "json"
require "securerandom"
require "digest"
require "active_support/core_ext/object/blank"

root = File.expand_path("../..", __dir__)
require File.join(root, "lib/discussion_bridge/cms_protocol")
require File.join(root, "lib/discussion_bridge/cms_configuration")
require File.join(root, "lib/discussion_bridge/cms_mapping_projection")

class ApplicationController
  def self.requires_plugin(*) = nil
  def self.before_action(*) = nil
  def self.rescue_from(*) = nil
end

module DiscussionBridge
  PLUGIN_NAME = "discourse-discussion-bridge"

  module CmsDeliveryProjection
    def self.call(mapping) = mapping.fixture_delivery
  end
end

require File.join(root, "app/controllers/discussion_bridge/publisher_controller")

class DiscussionBridgeCmsMapping
  class << self
    attr_accessor :fixture_mapping

    def find_by(content_binding_id:)
      mapping = fixture_mapping
      raise "Unexpected persistence lookup" unless mapping.content_binding.id == content_binding_id
      mapping
    end
  end
end

class DiscussionBridgeCmsUrlHistoryEntry
  def self.where(cms_mapping_id:)
    raise "Unexpected history lookup" unless cms_mapping_id == 41
    []
  end
end

ConnectionFixture = Struct.new(:cms_configuration, :enabled, keyword_init: true) do
  def id = 7
  def public_id = "dbc_111111111111111111111111"
  def name = "Mode regression"
  def platform = "ghost"
  def allowed_origins = ["https://site.example"]
  def allows_direction?(value) = value == "from_discourse"
  def allows_lane?(value) = value == "news"
  def reload = self
end

RecordFixture = Struct.new(:binding, keyword_init: true) do
  def resource_id = "22222222-2222-4222-8222-222222222222"
  def state = "healthy"
  def topic_id = 23
  def topic = Struct.new(:id, :title, :url).new(23, "Article", "https://forum.example/t/article/23")
  def title = "Article"
  def lane = "news"
  def active_binding(role)
    raise "Unexpected role" unless role == "presentation"
    binding
  end
end

BindingFixture = Struct.new(:content_connection, :presentation_mode, :bridge_record, keyword_init: true) do
  def id = 31
  def content_connection_id = content_connection.id
  def external_id = "article"
  def canonical_url = "https://site.example/article/"
end

MappingFixture = Struct.new(:content_binding, :fixture_delivery, keyword_init: true) do
  def id = 41
  def mapping_id = "33333333-3333-4333-8333-333333333333"
  def content_connection = content_binding.content_connection
  def source_id = "topic:23"
  def mapping_revision = "mapping:1"
  def destination_native_id = nil
  def mapping_state = "pending"
  def desired_source_revision = "source:1"
  def synchronized_source_revision = nil
  def publicly_verified_source_revision = nil
  def destination_native_revision = nil
  def source_created_at = Time.utc(2026, 10, 1)
  def source_updated_at = Time.utc(2026, 10, 2)
  def synchronized_at = nil
  def publicly_verified_at = nil
  def presentation_move_intent = nil
end

def fixture(mode: "simple", initial: "simple", delivery: "pending", work_policy: "policy:1")
  configuration = {
    "profile" => "ghost", "destination_origin" => "https://site.example", "publication_lane" => "news",
    "native_capabilities" => { "native_revision" => "native:mode-fixture", "supported_presentations" => %w[simple full interactive],
      "publication_kind" => "dynamic", "complete_content_supported" => true },
    "policy" => { "policy_revision" => "policy:2", "enabled" => true, "selection" => "all_public",
      "category_ids" => [], "include_topic_ids" => [], "exclude_topic_ids" => [], "include_unlisted" => false,
      "publication_kind" => "dynamic", "presentation_mode" => mode, "author_ids" => [], "taxonomy_ids" => [] },
  }
  connection = ConnectionFixture.new(cms_configuration: configuration, enabled: true)
  record = RecordFixture.new
  binding = BindingFixture.new(content_connection: connection, presentation_mode: initial, bridge_record: record)
  record.binding = binding
  mapping = MappingFixture.new(content_binding: binding, fixture_delivery: {
    "publication_status" => delivery, "scope_available" => true, "scope_issue" => nil,
    "work" => { "policy_revision" => work_policy },
  })
  DiscussionBridgeCmsMapping.fixture_mapping = mapping
  [record, binding, mapping, connection]
end

def assert(condition, message)
  raise message unless condition
end

controller = DiscussionBridge::PublisherController.allocate
checks = []
failures = []
run = lambda do |name, &block|
  block.call
  checks << name
rescue StandardError => error
  failures << { check: name, error: error.message, type: error.class.name }
end

%w[simple full interactive].each do |mode|
  run.call("current #{mode} selection agrees with Mapping while initial mode stays historical") do
    record, binding, mapping, = fixture(mode: mode)
    before = Marshal.dump([record, mapping])
    payload = controller.send(:publication_payload, record)
    projection = DiscussionBridge::CmsMappingProjection.call(mapping)
    assert(payload.fetch(:presentation_mode) == mode, "publication status must expose current #{mode}, not initial #{binding.presentation_mode}")
    assert(payload.fetch(:presentation_mode) == projection.fetch("presentation_mode"), "status/Mapping current mode mismatch")
    assert(payload.fetch(:initial_presentation_mode) == "simple", "initial mode must remain explicitly historical")
    assert(Marshal.dump([record, mapping]) == before, "read projection mutated persisted fixture state")
  end
end

%w[pending publication_verified].each do |delivery|
  run.call("#{delivery} delivery does not turn desired Full into an applied-mode claim") do
    record, binding, mapping, = fixture(mode: "full", delivery: delivery)
    payload = controller.send(:publication_payload, record)
    assert(payload.fetch(:presentation_mode) == "full", "desired selection must stay Full independent of delivery")
    assert(payload.fetch(:initial_presentation_mode) == "simple", "original binding is not the new applied mode")
    assert(payload.fetch(:publication_status) == delivery, "delivery status changed")
    assert(payload.fetch(:delivery).equal?(mapping.fixture_delivery), "retained delivery evidence changed")
    assert(payload.fetch(:delivery).fetch("work").fetch("policy_revision") == "policy:1", "old delivery policy was relabeled")
    assert(!payload.key?(:applied_presentation_mode), "no applied-mode evidence exists in this projection")
    assert(binding.presentation_mode == "simple", "binding mode was synchronized without delivery")
  end
end

run.call("a current-policy completed delivery still preserves the initial mode without inventing applied proof") do
  record, binding, _, = fixture(mode: "full", delivery: "publication_verified", work_policy: "policy:2")
  payload = controller.send(:publication_payload, record)
  assert(payload.fetch(:presentation_mode) == "full", "current selection lost after completed delivery")
  assert(payload.fetch(:initial_presentation_mode) == "simple", "creation-time mode must not be rewritten by reads")
  assert(payload.fetch(:delivery).fetch("work").fetch("policy_revision") == "policy:2", "current delivery facts changed")
  assert(!payload.key?(:applied_presentation_mode) && binding.presentation_mode == "simple", "completion was used as invented applied-mode evidence")
end

run.call("disabled connection exposes no invented current selection and keeps retained diagnostics") do
  record, binding, mapping, connection = fixture(mode: "full")
  connection.enabled = false
  mapping.fixture_delivery.merge!("scope_available" => false, "scope_issue" => "connection_disabled")
  payload = controller.send(:publication_payload, record)
  assert(payload.fetch(:presentation_mode).nil?, "disabled current policy must not fall back to initial mode")
  assert(payload.fetch(:initial_presentation_mode) == binding.presentation_mode, "historical mode lost")
  assert(payload.fetch(:delivery).fetch("scope_issue") == "connection_disabled", "scope diagnostic lost")
end

run.call("a previously loaded connection refreshes the desired selection before status projection") do
  record, _, _, connection = fixture(mode: "simple")
  persisted_configuration = Marshal.load(Marshal.dump(connection.cms_configuration))
  persisted_configuration.fetch("policy")["presentation_mode"] = "full"
  connection.define_singleton_method(:reload) do
    self.cms_configuration = persisted_configuration
    self
  end
  payload = controller.send(:publication_payload, record)
  assert(payload.fetch(:presentation_mode) == "full", "cached connection selection differed from current Mapping policy")
  assert(payload.fetch(:initial_presentation_mode) == "simple", "refresh rewrote historical initial mode")
end

run.call("invalid current policy has no historical-mode fallback") do
  record, _, _, = fixture(mode: "fullInteractive")
  payload = controller.send(:publication_payload, record)
  assert(payload.fetch(:presentation_mode).nil?, "invalid mode must not become historical Simple")
  assert(payload.fetch(:initial_presentation_mode) == "simple", "historical initial mode mislabeled")
end

run.call("a record without an active presentation has no selected or initial mode") do
  record, = fixture
  record.binding = nil
  payload = controller.send(:publication_payload, record)
  assert(payload.fetch(:presentation_mode).nil? && payload.fetch(:initial_presentation_mode).nil?, "untracked record invented mode state")
  assert(payload.fetch(:publication_status) == "untracked", "untracked delivery changed")
end

run.call("unexpected configuration failures remain errors") do
  record, _, _, connection = fixture
  def connection.cms_configuration = raise("unexpected persistence failure")
  begin
    controller.send(:publication_payload, record)
    raise "Unexpected persistence error was swallowed"
  rescue RuntimeError => error
    assert(error.message == "unexpected persistence failure", error.message)
  end
end

puts JSON.pretty_generate({ checks: checks.size, failures: failures, runtime: RUBY_DESCRIPTION,
  boundary: "actual PublisherController/CmsConfiguration/CmsProtocol/CmsMappingProjection; in-memory persistence and delivery projection fixtures; no Rails/PostgreSQL/provider execution" })
exit(failures.empty? ? 0 : 1)
