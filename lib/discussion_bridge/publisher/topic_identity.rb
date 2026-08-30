# frozen_string_literal: true

require "digest"

module ::DiscussionBridge
  module Publisher
    module TopicIdentity
      module_function

      def external_id(topic)
        origin_hash = Digest::SHA256.hexdigest(Discourse.base_url)
        "discourse-topic:#{origin_hash}:#{topic.id}"
      end

      def canonical_url(topic)
        "#{Discourse.base_url}#{topic.relative_url}"
      end
    end
  end
end
