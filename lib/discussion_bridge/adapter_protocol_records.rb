# frozen_string_literal: true

module DiscussionBridge
  module AdapterProtocolRecords
    RESOLVE_SUCCESS_FIELDS = %w[
      outcome
      reason
      resource_id
      topic_id
      topic_url
      direction
      accepted_source_revision
      accepted_source_revision_sequence
      core_fallback
      correlation_id
    ].freeze
    RESOLVE_RECONCILIATION_FIELDS = %w[
      outcome
      reason
      resource_id
      topic_id
      topic_url
      direction
      conflict_fields
      core_fallback
      correlation_id
    ].freeze
    INDEX_RESPONSE_FIELDS = %w[records page total_pages correlation_id].freeze
    SHOW_RESPONSE_FIELDS = %w[bridge_record correlation_id].freeze
    REQUIRED_RECORD_FIELDS = %w[
      resource_id
      direction
      state
      title
      topic_id
      topic_url
      source_revision
      source_revision_sequence
      source_created_at
      source_updated_at
      bindings
    ].freeze
    OPTIONAL_RECORD_FIELDS = %w[content_disposition content_transport].freeze
    BINDING_FIELDS = %w[
      binding_id
      connection_id
      role
      state
      external_id
      canonical_url
      presentation_mode
      applied_source_revision
      publication_revision
      content_disposition
      synchronized_at
      deployment_state
      deployed_at
      verification_state
      publicly_verified_at
    ].freeze
    BINDING_STATES = %w[
      pending
      active
      held
      withdrawn
      reconciliation_required
      operator_attention
      retired
    ].freeze
    BINDING_ROLES = %w[source presentation].freeze
    DEPLOYMENT_STATES = %w[not_required pending deployed failed].freeze
    VERIFICATION_STATES = %w[not_required pending verified failed].freeze
    BINDING_ID_PATTERN = /\Adbb_[a-f0-9]{32}\z/
    PER_PAGE = 100
    MAXIMUM_PAGE = 10_000
  end
end
