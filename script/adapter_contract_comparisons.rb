# frozen_string_literal: true

module DiscussionBridge
  module AdapterContractComparisons
    Mismatch = Class.new(StandardError)

    def self.verify_common_boundary!(boundary:, authentication:, common:, errors:)
      verify!(
        [
          [
            "CONNECTION_HEADER",
            boundary.const_get(:CONNECTION_HEADER),
            authentication.fetch("connection_header"),
          ],
          [
            "SECRET_HEADER",
            boundary.const_get(:SECRET_HEADER),
            authentication.fetch("secret_header"),
          ],
          [
            "CONTRACT_HEADER",
            boundary.const_get(:CONTRACT_HEADER),
            authentication.fetch("contract_header"),
          ],
          [
            "CONTRACT_VERSION",
            boundary.const_get(:CONTRACT_VERSION),
            authentication.fetch("contract_header_value"),
          ],
          [
            "CORRELATION_HEADER",
            boundary.const_get(:CORRELATION_HEADER),
            common.fetch("correlation_header"),
          ],
          [
            "MAX_CORRELATION_BYTES",
            boundary.const_get(:MAX_CORRELATION_BYTES),
            common.fetch("correlation_id_maximum_bytes"),
          ],
          [
            "MAX_ERROR_JSON_BYTES",
            boundary.const_get(:MAX_ERROR_JSON_BYTES),
            errors.fetch("maximum_json_bytes"),
          ],
        ],
      )
    end

    def self.verify!(comparisons)
      comparisons.each do |label, actual, released|
        next if actual == released

        raise Mismatch,
              "released Adapter Protocol mismatch for #{label}: #{actual.inspect} != #{released.inspect}"
      end

      true
    end
  end
end
