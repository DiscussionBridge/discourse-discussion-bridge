# frozen_string_literal: true

module DiscussionBridge
  # Called only inside CmsAuthorityStore's authenticated connection lock.
  # Revisions describe historical selection, never native write authority.
  class CmsPolicyHistory
    PAGE_ITEMS = 20
    MAXIMUM_BYTES = 262_144

    def initialize(connection, configuration)
      @connection, @configuration = connection, configuration
    end

    def page(query)
      CmsProtocol.validate!("PolicyHistoryQuery", query)
      unless @connection.allows_direction?("from_discourse")
        CmsProtocol.reject!("scope_denied")
      end
      after_revision = query.fetch("after_policy_revision")
      through_revision = query.fetch("through_policy_revision")
      unless through_revision == @configuration.dig("policy", "policy_revision")
        CmsProtocol.reject!("revision_conflict")
      end
      first, last = anchor!(after_revision), anchor!(through_revision)
      CmsProtocol.reject!("metadata_unavailable") if first.id > last.id
      unless last.configuration == @configuration
        CmsProtocol.reject!("metadata_unavailable")
      end
      rows =
        events
          .where("id > ? AND id <= ?", first.id, last.id)
          .order(:id)
          .limit(PAGE_ITEMS)
          .to_a
      items = []
      previous = after_revision
      previous_configuration = first.configuration
      rows.each do |row|
        unless row.previous_policy_revision == previous &&
                 row.previous_configuration == previous_configuration
          CmsProtocol.reject!("metadata_unavailable")
        end
        policy = row.configuration.fetch("policy")
        unless policy.fetch("policy_revision") == row.policy_revision
          CmsProtocol.reject!("metadata_unavailable")
        end
        item =
          policy.slice("policy_revision", "author_ids", "taxonomy_ids").merge(
            "previous_policy_revision" => row.previous_policy_revision
          )
        validate_history!("PolicyHistoryEvent", item)
        continuation = row.id == last.id ? nil : row.policy_revision
        candidate = envelope(query, items + [item], continuation)
        if JSON.generate(candidate).bytesize > MAXIMUM_BYTES
          CmsProtocol.reject!("metadata_unavailable") if items.empty?
          break
        end
        items << item
        previous = row.policy_revision
        previous_configuration = row.configuration
      end
      # Detect a missing final event or a deleted gap even on a short page.
      if items.empty? && after_revision != through_revision
        CmsProtocol.reject!("metadata_unavailable")
      end
      if items.size == rows.size && rows.size < PAGE_ITEMS &&
           previous != through_revision
        CmsProtocol.reject!("metadata_unavailable")
      end
      body =
        envelope(query, items, previous == through_revision ? nil : previous)
      validate_history!("PolicyHistoryPage", body)
      body
    rescue KeyError, TypeError
      CmsProtocol.reject!("metadata_unavailable")
    end

    private

    def validate_history!(type, value)
      CmsProtocol.validate!(type, value)
    rescue CmsProtocol::Error
      CmsProtocol.reject!("metadata_unavailable")
    end

    def events
      DiscussionBridgeCmsConfigurationEvent.where(
        content_connection_id: @connection.id
      )
    end

    def anchor!(revision)
      found = events.where(policy_revision: revision).limit(2).to_a
      CmsProtocol.reject!("metadata_unavailable") unless found.size == 1
      row = found.first
      unless row.configuration.dig("policy", "policy_revision") == revision
        CmsProtocol.reject!("metadata_unavailable")
      end
      row
    end

    def envelope(query, items, continuation)
      query.merge(
        "connection_id" => @connection.public_id,
        "items" => items,
        "next_policy_revision" => continuation
      )
    end
  end
end
