# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  # Private accepted native edition facts. No earlier wire grammar or storage
  # strategy is retained by this helper.
  module ManagedNativePublication
    KEYS = %w[revision previous_revision created_at updated_at content_sha256 content_bytes excerpted].freeze

    def self.managed_native_sha256(topic, first_post, raw: first_post.raw)
      Digest::SHA256.hexdigest(JSON.generate([topic.id, topic.title, first_post.id, raw, first_post.user_id]))
    end

    def self.matches?(expected_sha256, topic, first_post)
      raw = first_post.raw
      return true if expected_sha256 == managed_native_sha256(topic, first_post, raw: raw)

      uploads = first_post.post_hotlinked_media.downloaded.includes(:upload).index_by(&:url)
      return false if uploads.empty?

      # Work back to the accepted edition using Core's recorded image substitutions.
      first_post.version.downto(2) do |number|
        revision = first_post.post_revisions.find_by(number: number)
        return false unless revision&.user_id == Discourse::SYSTEM_USER_ID

        changes = revision.modifications
        return false if (changes.keys - %w[raw cooked edit_reason]).any?

        previous, current = changes["raw"]
        return false unless previous.is_a?(String) && current == raw && previous != current

        localized = InlineUploads.replace_hotlinked_image_urls(raw: previous) do |src|
          uploads[PostHotlinkedMedia.normalize_src(src)]&.upload
        end
        return false unless localized == current
        return true if expected_sha256 == managed_native_sha256(topic, first_post, raw: previous)

        raw = previous
      end
      false
    end

    def self.receipt(incoming, topic, first_post)
      incoming.merge("managed_native_sha256" => managed_native_sha256(topic, first_post))
    end
  end
end
