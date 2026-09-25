# frozen_string_literal: true

module DiscussionBridge
  class OperatorProviderRegistry
    DEFAULT_PROVIDER_ID = "discussionbridge"

    PROVIDERS = {
      DEFAULT_PROVIDER_ID => {
        id: DEFAULT_PROVIDER_ID,
        display_name: "DiscussionBridge Operator Service",
        organization_name: "DiscussionBridge / WebSynergetics",
        availability: "available",
        service_request_email: "servicerequest@discussionbridge.dev",
        operator_email_domains: ["discussionbridge.dev"].freeze,
        description: "First-party operational support for DiscussionBridge publishing and publication recovery.",
      }.freeze,
    }.freeze

    PARTNER_PROGRAM = {
      display_name: "Approved Operator Partners",
      availability: "planned",
      description: "Additional vetted providers may offer paid or unpaid Operator service after the partner " \
        "approval, identity, entitlement, and audit requirements are published.",
    }.freeze

    def self.fetch(provider_id)
      PROVIDERS.fetch(provider_id.to_s) do
        raise ArgumentError, "operator service provider is invalid"
      end
    end

    def self.fetch_available(provider_id)
      provider = fetch(provider_id)
      raise ArgumentError, "operator service provider is unavailable" unless provider[:availability] == "available"

      provider
    end

    def self.provider_ids
      PROVIDERS.keys
    end

    def self.public_catalog(selected_provider_id:)
      PROVIDERS.values.map do |provider|
        provider.slice(:id, :display_name, :organization_name, :availability, :description).merge(
          available: provider[:availability] == "available",
          selected: provider[:id] == selected_provider_id,
        )
      end
    end

    def self.operator_email_allowed?(provider_id:, email:)
      provider = fetch_available(provider_id)
      address = email.to_s.strip.downcase
      domain = address.split("@", 2).last
      address.match?(/\A[^\s@]+@[^\s@]+\z/) && provider[:operator_email_domains].include?(domain)
    end
  end
end
