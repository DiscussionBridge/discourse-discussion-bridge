# frozen_string_literal: true

require "json"

contract_path = ARGV.fetch(0) do
  abort "usage: ruby script/verify_adapter_contract.rb PATH_TO_CONTRACT_JSON PATH_TO_OPERATOR_CONTRACT_JSON"
end
operator_contract_path = ARGV.fetch(1) do
  abort "usage: ruby script/verify_adapter_contract.rb PATH_TO_CONTRACT_JSON PATH_TO_OPERATOR_CONTRACT_JSON"
end

contract = JSON.parse(File.read(contract_path, encoding: "UTF-8"))
operator_contract = JSON.parse(File.read(operator_contract_path, encoding: "UTF-8"))
require_relative "../lib/discussion_bridge/adapter_request_boundary"
require_relative "../lib/discussion_bridge/bridge_record_request"
require_relative "../lib/discussion_bridge/connection_capability"
require_relative "../lib/discussion_bridge/adapter_protocol_records"
require_relative "../lib/discussion_bridge/source_publication_protocol"
require_relative "../lib/discussion_bridge/platform_catalog_protocol"
require_relative "../lib/discussion_bridge/publication_work_protocol"
require_relative "../lib/discussion_bridge/operator_provider_registry"
require_relative "../lib/discussion_bridge/operator_service_contract"
require_relative "../lib/discussion_bridge/operator_entitlement_verifier"

boundary = DiscussionBridge::AdapterRequestBoundary
authentication = contract.fetch("authentication")
common = contract.fetch("common")
errors = contract.fetch("error_responses")

expected = {
  boundary::CONNECTION_HEADER => authentication.fetch("connection_header"),
  boundary::SECRET_HEADER => authentication.fetch("secret_header"),
  boundary::CONTRACT_HEADER => authentication.fetch("contract_header"),
  boundary::CONTRACT_VERSION => authentication.fetch("contract_header_value"),
  boundary::CORRELATION_HEADER => common.fetch("correlation_header"),
  boundary::MAX_CORRELATION_BYTES => common.fetch("correlation_id_maximum_bytes"),
  boundary::MAX_ERROR_JSON_BYTES => errors.fetch("maximum_json_bytes"),
}

expected.each do |actual, released|
  abort "released Adapter Protocol mismatch: #{actual.inspect} != #{released.inspect}" unless actual == released
end

released_connection_pattern = Regexp.new("\\A#{authentication.fetch("connection_id_pattern")}\\z")
%w[dbc_111111111111111111111111 dbc_abcdef0123456789abcdef01].each do |value|
  abort "released connection pattern mismatch for #{value}" unless
    boundary::CONNECTION_ID_PATTERN.match?(value) == released_connection_pattern.match?(value)
end
%w[dbc_gggggggggggggggggggggggg dbc_ABCDEF0123456789ABCDEF01 dbc_11111111111111111111111].each do |value|
  abort "released connection pattern mismatch for #{value}" unless
    boundary::CONNECTION_ID_PATTERN.match?(value) == released_connection_pattern.match?(value)
end

status_symbols = {
  400 => :bad_request,
  401 => :unauthorized,
  403 => :forbidden,
  404 => :not_found,
  409 => :conflict,
  410 => :gone,
  413 => :payload_too_large,
  415 => :unsupported_media_type,
  422 => :unprocessable_entity,
  429 => :too_many_requests,
  500 => :internal_server_error,
  503 => :service_unavailable,
}
released_statuses = errors.fetch("statuses").each_with_object({}) do |(status, codes), result|
  codes.each { |code| result[code] = status_symbols.fetch(Integer(status, 10)) }
end

abort "released Adapter Protocol error registry mismatch" unless boundary::ERROR_STATUSES == released_statuses
abort "missing bounded static message" unless boundary::ERROR_MESSAGES.keys.sort == released_statuses.keys.sort

resolve = contract.fetch("resolve")
request = DiscussionBridge::BridgeRecordRequest
abort "released resolve required fields mismatch" unless request::REQUIRED_KEYS == resolve.fetch("required_fields")
abort "released resolve optional fields mismatch" unless
  (request::ALLOWED_KEYS - request::REQUIRED_KEYS) == resolve.fetch("optional_fields")
abort "released resolve JSON bound mismatch" unless request::MAX_JSON_BYTES == resolve.fetch("maximum_json_bytes")
abort "released resolve content bound mismatch" unless
  request::MAX_CONTENT_HTML_BYTES == resolve.dig("field_rules", "content_html_maximum_bytes")
abort "released source content bound mismatch" unless
  request::MAX_SOURCE_CONTENT_BYTES == resolve.fetch("source_content_maximum_bytes")
abort "released presentation modes mismatch" unless
  request::PRESENTATION_MODES == resolve.dig("field_rules", "presentation_mode")
abort "released content dispositions mismatch" unless
  request::CONTENT_DISPOSITIONS == resolve.dig("field_rules", "content_disposition")

capability = contract.fetch("connection_capability")
capability_impl = DiscussionBridge::ConnectionCapability
abort "released profiles mismatch" unless capability_impl::PROFILES == contract.fetch("profiles")
abort "released capability presentation modes mismatch" unless
  capability_impl::PRESENTATION_MODES == contract.dig("configuration", "presentation_modes")
abort "released supported operations mismatch" unless
  capability_impl::SUPPORTED_OPERATIONS == capability.fetch("supported_operations")
abort "released capability fields mismatch" unless
  capability_impl::REQUIRED_FIELDS == capability.fetch("required_fields")
abort "released destination policy fields mismatch" unless
  capability_impl::POLICY_KEYS == capability.fetch("destination_policy_required_fields")
policy_rules = capability.fetch("destination_policy_field_rules")
abort "released container mapping fields mismatch" unless
  capability_impl::CONTAINER_MAPPING_KEYS == policy_rules.fetch("container_mapping_required_fields")
abort "released taxonomy mapping fields mismatch" unless
  capability_impl::TAXONOMY_MAPPING_REQUIRED_KEYS == policy_rules.fetch("taxonomy_mapping_required_fields") &&
    capability_impl::TAXONOMY_MAPPING_OPTIONAL_KEYS == policy_rules.fetch("taxonomy_mapping_optional_fields")
abort "released author mapping fields mismatch" unless
  capability_impl::AUTHOR_MAPPING_REQUIRED_KEYS == policy_rules.fetch("author_mapping_required_fields") &&
    capability_impl::AUTHOR_MAPPING_OPTIONAL_KEYS == policy_rules.fetch("author_mapping_optional_fields")
abort "released mapping modes mismatch" unless capability_impl::MAPPING_MODES == policy_rules.fetch("mapping_modes")
abort "released native-limit policy fields mismatch" unless
  capability_impl::NATIVE_LIMIT_POLICY_KEYS == policy_rules.fetch("native_limit_policy_required_fields")
abort "released overflow behaviors mismatch" unless
  capability_impl::OVERFLOW_BEHAVIORS == policy_rules.fetch("overflow_behaviors")
released_bounds = {
  resolve_json_bytes: resolve.fetch("maximum_json_bytes"),
  source_content_bytes: contract.dig("common", "source_content_maximum_bytes"),
  claim_maximum_items: contract.dig("publication_work", "claim", "maximum_items"),
  lease_maximum_seconds: contract.dig("publication_work", "claim", "maximum_total_lease_seconds"),
  catalog_segment_items: contract.dig("platform_catalog", "maximum_items_per_segment"),
}
abort "released capability bounds mismatch" unless capability_impl::BOUNDS == released_bounds

records = contract.fetch("records")
record_impl = DiscussionBridge::AdapterProtocolRecords
abort "released resolve success fields mismatch" unless
  record_impl::RESOLVE_SUCCESS_FIELDS == resolve.fetch("success_response_required_fields")
abort "released resolve reconciliation fields mismatch" unless
  record_impl::RESOLVE_RECONCILIATION_FIELDS == resolve.fetch("reconciliation_response_required_fields")
abort "released record index fields mismatch" unless
  record_impl::INDEX_RESPONSE_FIELDS == records.fetch("index_required_response_fields")
abort "released record show fields mismatch" unless
  record_impl::SHOW_RESPONSE_FIELDS == records.fetch("show_required_response_fields")
abort "released record fields mismatch" unless
  record_impl::REQUIRED_RECORD_FIELDS == records.fetch("required_record_fields")
abort "released optional record fields mismatch" unless
  record_impl::OPTIONAL_RECORD_FIELDS == records.fetch("optional_record_fields")
abort "released binding fields mismatch" unless
  record_impl::BINDING_FIELDS == records.fetch("destination_binding_fields")
abort "released binding states mismatch" unless record_impl::BINDING_STATES == records.fetch("binding_states")
abort "released binding roles mismatch" unless record_impl::BINDING_ROLES == records.fetch("binding_roles")
released_binding_pattern = Regexp.new("\\A#{records.fetch("binding_id_pattern")}\\z")
%w[dbb_11111111111111111111111111111111 dbb_abcdef0123456789abcdef0123456789].each do |value|
  abort "released binding ID pattern mismatch for #{value}" unless
    record_impl::BINDING_ID_PATTERN.match?(value) == released_binding_pattern.match?(value)
end
abort "released deployment states mismatch" unless
  record_impl::DEPLOYMENT_STATES == records.fetch("deployment_states")
abort "released verification states mismatch" unless
  record_impl::VERIFICATION_STATES == records.fetch("verification_states")
abort "released record page bound mismatch" unless record_impl::MAXIMUM_PAGE == records.fetch("maximum_page")
abort "released record page size mismatch" unless record_impl::PER_PAGE == records.fetch("records_per_page")

source = contract.fetch("source_publication")
source_impl = DiscussionBridge::SourcePublicationProtocol
inventory = source.fetch("inventory")
detail = source.fetch("detail")
transport = source.fetch("content_transport")
revocations = source.fetch("revocations")
abort "released source inventory query mismatch" unless
  source_impl::INVENTORY_QUERY_FIELDS == inventory.fetch("query")
abort "released source inventory response mismatch" unless
  source_impl::INVENTORY_RESPONSE_FIELDS == inventory.fetch("required_response_fields")
abort "released source inventory item mismatch" unless
  source_impl::INVENTORY_ITEM_FIELDS == inventory.fetch("required_item_fields")
abort "released source detail query mismatch" unless
  source_impl::DETAIL_QUERY_FIELDS == detail.fetch("query")
abort "released source detail fields mismatch" unless
  source_impl::DETAIL_FIELDS == detail.fetch("required_fields")
abort "released inline transport mismatch" unless
  source_impl::INLINE_TRANSPORT_FIELDS == transport.dig("inline", "required_fields")
abort "released chunk descriptor mismatch" unless
  source_impl::CHUNK_DESCRIPTOR_FIELDS == transport.dig("chunked", "required_descriptor_fields")
abort "released content query mismatch" unless
  source_impl::CONTENT_QUERY_FIELDS == transport.dig("chunked", "query")
abort "released content fields mismatch" unless
  source_impl::CONTENT_FIELDS == transport.dig("chunked", "required_chunk_fields")
abort "released revocation query mismatch" unless
  source_impl::REVOCATION_QUERY_FIELDS == revocations.fetch("query")
abort "released revocation index mismatch" unless
  source_impl::REVOCATION_INDEX_FIELDS == revocations.fetch("index_required_fields")
abort "released revocation item mismatch" unless
  source_impl::REVOCATION_ITEM_FIELDS == revocations.fetch("item_required_fields")
abort "released revocation detail mismatch" unless
  source_impl::REVOCATION_DETAIL_FIELDS == revocations.fetch("detail_required_fields")
abort "released source inventory default mismatch" unless
  source_impl::DEFAULT_LIMIT == inventory.fetch("default_limit")
abort "released source inventory bound mismatch" unless
  source_impl::MAXIMUM_LIMIT == inventory.fetch("maximum_limit")
abort "released source retention mismatch" unless
  source_impl::SNAPSHOT_RETENTION_SECONDS == inventory.fetch("minimum_snapshot_retention_seconds")
abort "released inline content bound mismatch" unless
  source_impl::INLINE_MAXIMUM_BYTES == transport.dig("inline", "maximum_content_html_bytes")
abort "released chunk content bound mismatch" unless
  source_impl::CHUNK_MAXIMUM_BYTES == transport.dig("chunked", "decoded_chunk_maximum_bytes")
abort "released total source bound mismatch" unless
  source_impl::MAXIMUM_SOURCE_CONTENT_BYTES == detail.fetch("maximum_source_content_bytes")
abort "released revocation default mismatch" unless
  source_impl::DEFAULT_LIMIT == revocations.fetch("default_limit")
abort "released revocation bound mismatch" unless
  source_impl::MAXIMUM_LIMIT == revocations.fetch("maximum_limit")
abort "released revocation reasons mismatch" unless
  source_impl::REVOCATION_REASONS == revocations.fetch("reasons")

catalog = contract.fetch("platform_catalog")
catalog_impl = DiscussionBridge::PlatformCatalogProtocol
abort "released catalog query mismatch" unless catalog_impl::QUERY_FIELDS == catalog.fetch("get_query")
abort "released catalog response mismatch" unless
  catalog_impl::RESPONSE_FIELDS == catalog.fetch("get_required_response_fields")
abort "released catalog update mismatch" unless
  catalog_impl::UPDATE_REQUIRED_FIELDS == catalog.fetch("put_required_request_fields")
abort "released catalog update response mismatch" unless
  catalog_impl::UPDATE_RESPONSE_FIELDS == catalog.fetch("put_required_response_fields")
abort "released catalog segment fields mismatch" unless
  catalog_impl::SEGMENT_FIELDS == catalog.fetch("segment_required_fields")
abort "released catalog segment types mismatch" unless
  catalog_impl::SEGMENT_TYPES == catalog.fetch("segment_types")
abort "released catalog item schemas mismatch" unless
  catalog_impl::ITEM_SCHEMAS == catalog.fetch("item_schemas")
abort "released catalog body bound mismatch" unless
  catalog_impl::MAXIMUM_JSON_BYTES == catalog.fetch("maximum_json_bytes")
abort "released catalog item bound mismatch" unless
  catalog_impl::MAXIMUM_ITEMS == catalog.fetch("maximum_items_per_segment")

work = contract.fetch("publication_work")
work_impl = DiscussionBridge::PublicationWorkProtocol
abort "released work claim required fields mismatch" unless
  work_impl::CLAIM_REQUIRED_FIELDS == work.dig("claim", "request_required_fields")
abort "released work claim optional fields mismatch" unless
  work_impl::CLAIM_OPTIONAL_FIELDS == work.dig("claim", "request_optional_fields")
abort "released work claim response mismatch" unless
  work_impl::CLAIM_RESPONSE_FIELDS == work.dig("claim", "response_required_fields")
abort "released work renewal fields mismatch" unless
  work_impl::RENEW_FIELDS == work.dig("renew", "required_fields")
abort "released work renewal response mismatch" unless
  work_impl::RENEW_RESPONSE_FIELDS == work.dig("renew", "response_required_fields")
abort "released work acknowledgement fields mismatch" unless
  work_impl::ACK_REQUIRED_FIELDS == work.dig("acknowledgement", "required_fields") &&
    work_impl::ACK_OPTIONAL_FIELDS == work.dig("acknowledgement", "conditional_fields")
abort "released work acknowledgement response mismatch" unless
  work_impl::ACK_RESPONSE_FIELDS == work.dig("acknowledgement", "response_required_fields") &&
    work_impl::ACK_RESPONSE_OPTIONAL_FIELDS == work.dig("acknowledgement", "response_conditional_fields")
abort "released work failure fields mismatch" unless
  work_impl::FAILURE_FIELDS == work.dig("failure", "required_fields")
abort "released work fields mismatch" unless work_impl::WORK_FIELDS == work.fetch("work_required_fields")
abort "released work actions mismatch" unless work_impl::ACTIONS == work.fetch("actions")
abort "released work states mismatch" unless work_impl::STATES == work.fetch("lifecycle_states")
abort "released work stages mismatch" unless
  work_impl::STAGES == work.dig("acknowledgement", "stages")
abort "released retry registry mismatch" unless
  work_impl::RETRYABLE_FAILURES == contract.dig("failure_registry", "retryable") &&
    work_impl::TERMINAL_FAILURES == contract.dig("failure_registry", "terminal")
abort "released retry schedule mismatch" unless
  work_impl::RETRY_BACKOFF_SECONDS == work.fetch("retry_backoff_seconds")
abort "released work claim bounds mismatch" unless
  work_impl::DEFAULT_MAXIMUM_ITEMS == work.dig("claim", "default_maximum_items") &&
    work_impl::MAXIMUM_ITEMS == work.dig("claim", "maximum_items") &&
    work_impl::DEFAULT_LEASE_SECONDS == work.dig("claim", "default_lease_seconds") &&
    work_impl::MAXIMUM_REQUESTED_LEASE_SECONDS == work.dig("claim", "maximum_requested_lease_seconds") &&
    work_impl::MAXIMUM_TOTAL_LEASE_SECONDS == work.dig("claim", "maximum_total_lease_seconds") &&
    work_impl::MAXIMUM_TOTAL_ATTEMPTS == work.fetch("maximum_total_attempts")
abort "released worker bound mismatch" unless
  work_impl::WORKER_ID_MAXIMUM_BYTES == work.fetch("worker_id_maximum_bytes")
abort "released failure detail bound mismatch" unless
  work_impl::ERROR_DETAIL_MAXIMUM_BYTES == work.dig("failure", "error_detail_maximum_bytes")

operator = DiscussionBridge::OperatorEntitlementVerifier
released_entitlement = operator_contract.fetch("entitlement")
abort "released operator contract version mismatch" unless
  operator_contract.fetch("version") == boundary::CONTRACT_VERSION
abort "released operator provider count mismatch" unless
  operator_contract.dig("relationship", "maximum_active_providers_per_forum") ==
    DiscussionBridge::OperatorServiceContract::MAXIMUM_ACTIVE_PROVIDERS_PER_FORUM
abort "released current operator provider mismatch" unless
  DiscussionBridge::OperatorProviderRegistry::PROVIDERS.values.one? &&
    DiscussionBridge::OperatorProviderRegistry::PROVIDERS.values.first.fetch(:key) ==
      operator_contract.dig("relationship", "current_provider")
abort "released operator signing domain mismatch" unless
  operator::SIGNING_DOMAIN == released_entitlement.fetch("signing_domain")
abort "released operator entitlement fields mismatch" unless
  operator::REQUIRED_FIELDS == released_entitlement.fetch("required_fields")
abort "released operator entitlement version mismatch" unless
  operator::ENTITLEMENT_VERSION == released_entitlement.fetch("entitlement_version")
abort "released operator scopes mismatch" unless
  operator::ALLOWED_SCOPES == released_entitlement.fetch("allowed_scopes")
abort "released operator lifetime mismatch" unless
  operator::MAXIMUM_LIFETIME_SECONDS == released_entitlement.fetch("maximum_lifetime_seconds")
abort "released operator grace mismatch" unless
  operator::MAXIMUM_GRACE_SECONDS == released_entitlement.fetch("maximum_grace_seconds")
abort "released operator states mismatch" unless
  DiscussionBridge::OperatorServiceContract::STATES == operator_contract.fetch("states")
abort "released operator audit fields mismatch" unless
  DiscussionBridge::OperatorServiceContract::AUDIT_FIELDS == operator_contract.dig("audit", "required_fields")
abort "released operator audit outcomes mismatch" unless
  DiscussionBridge::OperatorServiceContract::AUDIT_OUTCOMES == operator_contract.dig("audit", "outcomes")

puts "Adapter Protocol request boundary, P2 records, P3 source publication, P4 catalog/work, and P6 Operator Service match #{authentication.fetch("contract_header_value")}: #{released_statuses.length} error codes"
