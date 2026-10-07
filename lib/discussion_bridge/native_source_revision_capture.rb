# frozen_string_literal: true

require "digest"

module DiscussionBridge
  # Called by explicit staff publication or an already-authorized native update,
  # inside the caller's locked transaction.
  # Retain the whole cooked first post, not an excerpt or a later mutable read.
  class NativeSourceRevisionCapture
    def self.call(record:, topic:, restoration: nil)
      post = Post.unscoped.lock.find_by(topic_id: topic.id, post_number: 1, deleted_at: nil)
      unless post && Guardian.new.can_see?(topic) && !topic.private_message?
        raise Discourse::InvalidAccess
      end
      html = post.cooked
      raise ArgumentError, "native source is unavailable" unless html.is_a?(String) && html.valid_encoding?

      metadata = {
        "title" => topic.title, "post_id" => post.id, "post_version" => post.version,
        "wiki" => post.wiki, "source_created_at" => post.created_at.utc.iso8601(6),
        "source_updated_at" => post.updated_at.utc.iso8601(6),
        "source_content_bytes" => html.bytesize, "source_content_sha256" => Digest::SHA256.hexdigest(html),
        "author_user_id" => post.user_id, "category_id" => topic.category_id,
        "tag_ids" => topic.tags.order(:id).pluck(:id),
        "topic_url" => topic.url,
        "source_authors" => post.user ? [{
          "source_author_id" => "discourse:user:#{post.user_id}",
          "source_author_name" => post.user.username,
          "source_author_url" => "#{Discourse.base_url}/u/#{post.user.username}",
        }] : [],
        "categories" => topic.category ? [{
          "source_category_id" => "discourse:category:#{topic.category_id}",
          "source_category_name" => topic.category.name,
          "source_parent_category_id" => topic.category.parent_category_id ? "discourse:category:#{topic.category.parent_category_id}" : nil,
        }] : [],
        "tags" => topic.tags.order(:id).map { |tag| {
          "source_tag_id" => "discourse:tag:#{tag.id}", "source_tag_name" => tag.name,
        } },
      }
      created = BridgeRecordRequest.timestamp!(metadata.fetch("source_created_at"))
      updated = BridgeRecordRequest.timestamp!(metadata.fetch("source_updated_at"))
      raise ArgumentError, "native source clocks are invalid" if updated < created
      fingerprint = self.fingerprint(metadata)
      latest = record.native_source_revisions.order(sequence: :desc).first
      if latest
        unless record.known_source_context? && retained?(record) && record.source_revision == latest.revision &&
            record.source_revision_sequence == latest.sequence && record.source_request_fingerprint == latest.fingerprint
          raise ArgumentError, "source revision context requires reconciliation"
        end
        unless latest.metadata.fetch("post_id") == post.id &&
            latest.metadata.fetch("source_created_at") == metadata.fetch("source_created_at")
          raise ArgumentError, "native source identity requires reconciliation"
        end
        restore = false
        if restoration
          SourceRevocationProducer.verify!(restoration)
          unless restoration.bridge_record_id == record.id && restoration.restorable &&
              %w[source_deleted source_unpublished scope_removed].include?(restoration.reason) &&
              restoration.source_revision_sequence <= latest.sequence
            raise ArgumentError, "source restoration context requires reconciliation"
          end
          restore = restoration.source_revision_sequence == latest.sequence
        end
        return latest if !restore && latest.fingerprint == fingerprint && latest.content_html == html
        if updated < BridgeRecordRequest.timestamp!(latest.metadata.fetch("source_updated_at"))
          raise ArgumentError, "native source clock is stale"
        end
      elsif restoration || record.source_revision || record.source_revision_sequence || record.persisted? && !record.previously_new_record?
        raise ArgumentError, "source revision context requires reconciliation"
      end

      sequence = (latest&.sequence || 0) + 1
      revision = "post:#{post.id}:version:#{post.version}:capture:#{sequence}"
      capture = record.native_source_revisions.create!(sequence: sequence, revision: revision,
        fingerprint: fingerprint, metadata: metadata, content_html: html, captured_at: Time.now.utc)
      record.update!(title: metadata.fetch("title"), source_revision: revision, source_revision_sequence: sequence,
        source_created_at_raw: metadata.fetch("source_created_at"), source_updated_at_raw: metadata.fetch("source_updated_at"),
        source_content_bytes: metadata.fetch("source_content_bytes"), source_content_sha256: metadata.fetch("source_content_sha256"),
        content_disposition: "complete", source_context_state: "observed", source_request_fingerprint: fingerprint)
      capture
    end

    def self.retained?(record)
      capture = record.native_source_revisions.find_by(sequence: record.source_revision_sequence)
      return false unless capture && capture.revision == record.source_revision &&
        capture.fingerprint == record.source_request_fingerprint
      expected = capture.metadata.slice("title", "source_created_at", "source_updated_at", "source_content_bytes", "source_content_sha256")
      actual = { "title" => record.title, "source_created_at" => record.source_created_at_raw,
        "source_updated_at" => record.source_updated_at_raw, "source_content_bytes" => record.source_content_bytes,
        "source_content_sha256" => record.source_content_sha256 }
      expected == actual && record.content_disposition == "complete" &&
        capture.content_html.bytesize == record.source_content_bytes &&
        Digest::SHA256.hexdigest(capture.content_html) == record.source_content_sha256 &&
        fingerprint(capture.metadata) == capture.fingerprint
    end

    def self.fingerprint(metadata)
      Digest::SHA256.hexdigest(JSON.generate(canonical_metadata(metadata)))
    end

    def self.canonical_metadata(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical_metadata(value.fetch(key))] }
      when Array
        value.map { |item| canonical_metadata(item) }
      else
        value
      end
    end

    private_class_method :canonical_metadata
  end
end
