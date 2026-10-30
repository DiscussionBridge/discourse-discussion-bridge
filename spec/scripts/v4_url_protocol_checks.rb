# frozen_string_literal: true

# Actual receiver codec, without Rails/DB. Native origin/ownership/locks are
# covered separately by cms_url_policy_spec and the native request suite.
require "json"
require_relative "support/standalone_enumerable_helpers"
require_relative "../../lib/discussion_bridge/cms_protocol"

codec = DiscussionBridge::CmsProtocol
fixtures = File.expand_path("../fixtures/v4", __dir__)
positive =
  JSON.parse(File.binread(File.join(fixtures, "positive-examples.json"))).fetch(
    "fixtures"
  )
connection =
  positive.find { |item| item.fetch("type") == "Connection" }.fetch("value")
prepare =
  positive.find { |item| item.fetch("type") == "MappingPrepare" }.fetch("value")
vectors = JSON.parse(File.binread(File.join(fixtures, "url-contextj.json")))
checks = 0
vectors
  .fetch("cases")
  .each do |item|
    ["#{item.fetch("label")}.example", item.fetch("asciiHost")].each do |host|
      url = "https://#{host}/"
      inputs = [
        ["Url", url],
        [
          "Connection",
          connection.merge("destination_origin" => url.delete_suffix("/"))
        ],
        ["MappingPrepare", prepare.merge("canonical_url" => url)]
      ]
      inputs.each do |type, input|
        before = JSON.generate(input)
        begin
          codec.validate!(type, input)
          unless item.fetch("accepted")
            raise "Accepted #{item.fetch("id")} #{type}"
          end
        rescue DiscussionBridge::CmsProtocol::Error => error
          if item.fetch("accepted") || error.code != "invalid_field"
            raise "Rejected #{item.fetch("id")} #{type}"
          end
        end
        unless JSON.generate(input) == before
          raise "Mutated #{item.fetch("id")} #{type}"
        end
        checks += 1
      end
      input = connection.merge("destination_origin" => url.delete_suffix("/"))
      bytes = JSON.generate(input)
      begin
        value = codec.parse_json(bytes, type: "Connection")
        raise "Accepted JSON #{item.fetch("id")}" unless item.fetch("accepted")
        raise "Changed JSON #{item.fetch("id")}" unless value == input
      rescue DiscussionBridge::CmsProtocol::Error => error
        if item.fetch("accepted") || error.code != "invalid_field"
          raise "Rejected JSON #{item.fetch("id")}"
        end
      end
      checks += 1
    end
  end
puts JSON.generate(
       checks: checks,
       context_labels: vectors.fetch("cases").length,
       limitations:
         "Actual receiver codec only; native PostgreSQL/authorization/receipt qualification is separate"
     )
