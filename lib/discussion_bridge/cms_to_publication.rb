# frozen_string_literal: true

module DiscussionBridge
  # Current native publication receipt and immutable source edition identity.
  module CmsToPublication
    DIAGNOSTIC_FIELDS = %w[adapter_id adapter_version correlation_id expected_source_revision].freeze

    def self.identity(input)
      value = input.except(*DIAGNOSTIC_FIELDS)
      value["visibility"] ||= "unlisted"
      value["lane"] = value["lane"].to_s
      value["source_authors"] ||= []
      Digest::SHA256.hexdigest(CmsProtocol.semantic_identity(value))
    end

    def self.read(record)
      record.cms_source_publication
    end

    def self.same_edition?(stored, incoming, request)
      (ManagedNativePublication::KEYS - ["previous_revision"]).all? { |key| stored[key] == incoming[key] } &&
        stored["request_sha256"] == identity(request.fetch(:cms_input))
    end

    def self.attributes(incoming, request, topic, first_post)
      receipt = ManagedNativePublication.receipt(incoming, topic, first_post)
      receipt["request_sha256"] = identity(request.fetch(:cms_input))
      receipt["input"] = request.fetch(:cms_input)
      receipt["synchronized_at"] = request.fetch(:cms_synchronized_at)
      receipt["state"] = "active"
      if CmsGeneratedExcerpt.generated?(request.fetch(:cms_input))
        receipt["generated_native_segment"] = CmsGeneratedExcerpt.capture_native(request.fetch(:cms_input), first_post.raw)
      end
      { cms_source_publication: receipt }
    end
  end
end

