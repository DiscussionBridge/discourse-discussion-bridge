# frozen_string_literal: true

require "json"

contract_path = ARGV.fetch(0) do
  abort "usage: ruby script/verify_adapter_contract.rb PATH_TO_CONTRACT_JSON"
end

contract = JSON.parse(File.read(contract_path, encoding: "UTF-8"))
require_relative "../lib/discussion_bridge/adapter_request_boundary"

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

puts "Adapter Protocol request boundary matches #{authentication.fetch("contract_header_value")}: #{released_statuses.length} error codes"
