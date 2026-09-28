# frozen_string_literal: true

module DiscussionBridge
  class OperatorProviderRegistry
    DISCUSSIONBRIDGE_PROVIDER_ID = "dbp_00000000000000000000000000000001"

    PROVIDERS = {
      DISCUSSIONBRIDGE_PROVIDER_ID => {
        id: DISCUSSIONBRIDGE_PROVIDER_ID,
        key: "discussionbridge",
        name: "DiscussionBridge",
        availability: "available",
        description: "First-party operational support for DiscussionBridge installations.",
      }.freeze,
    }.freeze

    PARTNER_PROGRAM = {
      name: "Approved Operator Service providers",
      availability: "planned",
      description: "Future providers use the same customer-approved entitlement, scope, and audit boundary.",
    }.freeze

    def self.fetch(provider_id)
      PROVIDERS.fetch(provider_id.to_s) { raise ArgumentError, "operator provider is invalid" }
    end

    def self.catalog(selected_provider_id:)
      PROVIDERS.values.map do |provider|
        provider.merge(selected: provider[:id] == selected_provider_id)
      end
    end
  end
end
