# frozen_string_literal: true

module DiscussionBridge
  class PublicationWorkQueue
    MAX_CONNECTION_TOPICS = 10_000

    def self.reconcile_topic!(topic_id:, connection: nil)
      connections = connection ? [connection] : publication_connections
      connections.each do |candidate|
        reconcile_for_connection!(candidate, topic_id.to_i)
        PublicationAttentionNotifier.call(candidate)
      end
    end

    def self.reconcile_connection!(connection)
      raise ArgumentError, "publication connection is unavailable" unless publication_connection?(connection)

      eligible_ids = PublicationTopicScope.relation(connection)
        .order(:id).limit(MAX_CONNECTION_TOPICS + 1).pluck(:id)
      raise ArgumentError, "publication scope exceeds bounded queue capacity" if
        eligible_ids.length > MAX_CONNECTION_TOPICS

      record_topic_ids = from_discourse_records(connection).where.not(topic_id: nil).distinct.pluck(:topic_id)
      (eligible_ids + record_topic_ids).uniq.sort.each do |topic_id|
        reconcile_for_connection!(connection, topic_id)
      end
      connection.publication_work_items.where.not(topic_id: eligible_ids + record_topic_ids).find_each do |item|
        item.with_lock do
          item.update!(
            action: "publish",
            state: "held",
            reason: "topic_unavailable",
            lease_token: nil,
            claimed_at: nil,
            lease_expires_at: nil,
            completed_at: Time.zone.now,
          )
        end
      end
      PublicationAttentionNotifier.call(connection)
    end

    def self.acknowledge!(connection:, record:, publication:, outcome:, error_code:, error_detail:)
      item = DiscussionBridgePublicationWorkItem.find_or_initialize_by(
        content_connection_id: connection.id,
        topic_id: record.topic_id,
      )
      persist_item(item) do
        state = case outcome
                when "failed" then "failed"
                when "held" then "held"
                when "unpublished" then "unpublished"
                else "current"
                end
        item.assign_attributes(
          bridge_record_id: record.id,
          action: publication.eligibility.fetch(:eligible) ? "publish" : "unpublish",
          state: state,
          reason: outcome == "failed" ? error_code.presence || "delivery_failed" :
            publication.eligibility.fetch(:reason),
          source_revision: publication.source_revision,
          publication_revision: publication.publication_revision,
          policy_revision: publication.policy_revision,
          lease_token: nil,
          claimed_at: nil,
          lease_expires_at: nil,
          available_at: nil,
          completed_at: outcome == "failed" ? nil : Time.zone.now,
          attempt_count: record.delivery_attempt_count,
          last_error_code: error_code,
          last_error_detail: error_detail,
        )
      end
      PublicationAttentionNotifier.call(connection)
      item
    end

    def self.publication_connections
      DiscussionBridgeContentConnection.where(enabled: true, forum_publication_enabled: true)
        .select { |connection| connection.allows_direction?("from_discourse") }
    end

    def self.publication_connection?(connection)
      connection.enabled && connection.forum_publication_enabled &&
        connection.allows_direction?("from_discourse")
    end

    def self.reconcile_for_connection!(connection, topic_id)
      return unless publication_connection?(connection)

      topic = Topic.with_deleted.includes(:category, :tags, first_post: :user).find_by(id: topic_id)
      record = from_discourse_records(connection).find_by(topic_id: topic_id)
      eligibility = topic ? PublicationTopicScope.eligibility(connection, topic) :
        { eligible: false, reason: "topic_missing" }
      return unless eligibility.fetch(:eligible) || record ||
        connection.publication_work_items.exists?(topic_id: topic_id)

      publication = if eligibility.fetch(:eligible)
        TopicPublicationState.for_topic(connection: connection, topic: topic)
      else
        record && TopicPublicationState.for_revocation(connection: connection, record: record)
      end
      unless publication
        item = connection.publication_work_items.find_by(topic_id: topic_id)
        if item
          item.with_lock do
            item.update!(
              action: "publish",
              state: "held",
              reason: eligibility.fetch(:reason),
              available_at: nil,
              lease_token: nil,
              claimed_at: nil,
              lease_expires_at: nil,
              completed_at: Time.zone.now,
            )
          end
        end
        return item
      end
      action = eligibility.fetch(:eligible) ? "publish" : "unpublish"
      desired = desired_state(record: record, publication: publication, action: action)
      item = DiscussionBridgePublicationWorkItem.find_or_initialize_by(
        content_connection_id: connection.id,
        topic_id: topic_id,
      )
      persist_item(item) do
        same_work = item.persisted? && item.action == action &&
          item.publication_revision == publication.publication_revision &&
          item.policy_revision == publication.policy_revision
        claimed = same_work && item.state == "claimed" && item.lease_expires_at&.future?
        next item if claimed

        item.assign_attributes(
          bridge_record_id: record&.id,
          action: action,
          state: desired.fetch(:state),
          reason: desired[:reason],
          source_revision: publication.source_revision,
          publication_revision: publication.publication_revision,
          policy_revision: publication.policy_revision,
          available_at: desired.fetch(:state).in?(%w[queued retrying]) ? Time.zone.now : nil,
          lease_token: nil,
          claimed_at: nil,
          lease_expires_at: nil,
          completed_at: desired.fetch(:state).in?(%w[current held unpublished]) ? Time.zone.now : nil,
          last_error_code: desired.fetch(:state) == "failed" ? record&.last_delivery_error_code : nil,
          last_error_detail: desired.fetch(:state) == "failed" ? record&.last_delivery_error_detail : nil,
          attempt_count: record&.delivery_attempt_count.to_i,
        )
      end
      item
    end

    def self.desired_state(record:, publication:, action:)
      if action == "publish"
        destination = publication.destination
        reasons = Array(destination["reasons"])
        return { state: "attention", reason: reasons.first || "destination_not_ready" } unless
          destination["state"] == "ready"
        return { state: "failed", reason: record.last_delivery_error_code || "delivery_failed" } if
          record&.destination_state == "failed" &&
            record.attempted_publication_revision == publication.publication_revision
        current = record&.destination_state == "healthy" &&
          record.acknowledged_publication_revision == publication.publication_revision &&
          record.acknowledged_mapping_revision.to_s == destination["mapping_revision"].to_s
        { state: current ? "current" : "queued", reason: current ? nil : publication_reason(record) }
      else
        unpublished = record&.destination_state == "held" &&
          %w[held unpublished].include?(record.last_delivery_outcome) &&
          record.acknowledged_publication_revision == publication.publication_revision
        {
          state: unpublished ? "unpublished" : "queued",
          reason: publication.eligibility.fetch(:reason),
        }
      end
    end

    def self.publication_reason(record)
      return "new_publication" unless record
      return "delivery_failed" if record.destination_state == "failed"
      return "mapping_changed" if record.pending_mapping_revision.present?

      "source_changed"
    end

    def self.from_discourse_records(connection)
      DiscussionBridgeBridgeRecord.joins(:content_bindings)
        .where(direction: "from_discourse")
        .where(discussion_bridge_content_bindings: {
          content_connection_id: connection.id,
          role: "presentation",
          state: "active",
        }).distinct
    end

    def self.persist_item(item)
      if item.persisted?
        item.with_lock do
          yield
          item.save!
        end
      else
        yield
        item.save!
      end
    rescue ActiveRecord::RecordNotUnique
      current = DiscussionBridgePublicationWorkItem.find_by!(
        content_connection_id: item.content_connection_id,
        topic_id: item.topic_id,
      )
      current.with_lock do
        item.attributes.except("id", "created_at", "updated_at").each do |key, value|
          current[key] = value
        end
        current.save!
      end
      current
    end

    private_class_method :reconcile_for_connection!, :desired_state,
                         :publication_reason, :from_discourse_records, :persist_item
  end
end
