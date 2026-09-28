# frozen_string_literal: true

module DiscussionBridge
  module OperatorServiceContract
    MAXIMUM_ACTIVE_PROVIDERS_PER_FORUM = 1
    STATES = %w[pending_enrollment active grace_read_only expired revoked replaced].freeze
    AUDIT_FIELDS = %w[
      event_id occurred_at forum_id provider_id entitlement_id actor scope action target_type
      target_id operation_sha256 customer_approval_id outcome
    ].freeze
    AUDIT_OUTCOMES = %w[prepared approved applied rejected failed revoked].freeze
  end
end
