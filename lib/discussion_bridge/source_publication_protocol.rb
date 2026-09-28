# frozen_string_literal: true

module DiscussionBridge
  module SourcePublicationProtocol
    INVENTORY_QUERY_FIELDS = %w[cursor limit snapshot].freeze
    INVENTORY_RESPONSE_FIELDS = %w[
      snapshot
      policy_revision
      items
      next_cursor
      complete
      correlation_id
    ].freeze
    INVENTORY_ITEM_FIELDS = %w[
      resource_id
      topic_id
      topic_url
      title
      source_revision
      source_revision_sequence
      source_created_at
      source_updated_at
    ].freeze
    DETAIL_QUERY_FIELDS = %w[source_revision].freeze
    DETAIL_FIELDS = %w[
      resource_id
      topic_id
      topic_url
      title
      source_revision
      source_revision_sequence
      source_created_at
      source_updated_at
      source_authors
      categories
      tags
      presentation_mode
      content_transport
      content_disposition
      network_provenance
      correlation_id
    ].freeze
    INLINE_TRANSPORT_FIELDS = %w[mode media_type byte_length sha256 content_html].freeze
    CHUNK_DESCRIPTOR_FIELDS = %w[
      mode
      media_type
      byte_length
      sha256
      chunk_count
      decoded_chunk_maximum_bytes
    ].freeze
    CONTENT_QUERY_FIELDS = %w[source_revision chunk].freeze
    CONTENT_FIELDS = %w[
      source_revision
      chunk
      chunk_count
      decoded_bytes
      chunk_sha256
      content_base64
      correlation_id
    ].freeze
    REVOCATION_QUERY_FIELDS = %w[cursor limit high_water].freeze
    REVOCATION_INDEX_FIELDS = %w[
      high_water
      policy_revision
      items
      next_cursor
      complete
      correlation_id
    ].freeze
    REVOCATION_ITEM_FIELDS = %w[
      revocation_id
      resource_id
      source_revision
      source_revision_sequence
      reason
      effective_at
      restorable
    ].freeze
    REVOCATION_DETAIL_FIELDS = %w[
      revocation_id
      resource_id
      source_revision
      source_revision_sequence
      reason
      effective_at
      restorable
      affected_binding_ids
      policy_revision
      correlation_id
    ].freeze
    REVOCATION_REASONS = %w[
      source_unpublished
      source_deleted
      scope_removed
      policy_removed
      operator_hold
    ].freeze

    DEFAULT_LIMIT = 25
    MAXIMUM_LIMIT = 100
    SNAPSHOT_RETENTION_SECONDS = 2_592_000
    INLINE_MAXIMUM_BYTES = 49_152
    CHUNK_MAXIMUM_BYTES = 32_768
    MAXIMUM_SOURCE_CONTENT_BYTES = 16_777_216
    MAXIMUM_CURSOR_BYTES = 8_192
    SHA256_PATTERN = /\A[a-f0-9]{64}\z/
    SNAPSHOT_ID_PATTERN = /\Adbs_[a-f0-9]{32}\z/
    REVOCATION_ID_PATTERN = /\Adbr_[a-f0-9]{32}\z/
    MEDIA_TYPE = "text/html; charset=utf-8"
  end
end
