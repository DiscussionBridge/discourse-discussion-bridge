# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  # Private accepted native edition facts. No earlier wire grammar or storage
  # strategy is retained by this helper.
  module ManagedNativePublication
    KEYS = %w[revision previous_revision created_at updated_at content_sha256 content_bytes excerpted].freeze

    def self.managed_native_sha256(topic, first_post)
      Digest::SHA256.hexdigest(JSON.generate([topic.id, topic.title, first_post.id, first_post.raw, first_post.user_id]))
    end

    def self.receipt(incoming, topic, first_post)
      incoming.merge("managed_native_sha256" => managed_native_sha256(topic, first_post))
    end
  end
end