# frozen_string_literal: true

module DiscussionBridge
  class NetworkReplayRegistry
    Result = Data.define(:replay, :record)

    def self.reserve!(peer:, provenance:, immutable_operation:, correlation_id:)
      digest = DiscourseNetworkProtocol.digest(immutable_operation)
      record = nil
      replay = false
      DiscussionBridgeNetworkReplay.transaction do
        record = DiscussionBridgeNetworkReplay.lock.find_by(
          origin_forum_id: provenance.fetch("origin_forum_id"),
          operation_id: provenance.fetch("operation_id"),
        )
        if record
          raise AdapterRequestBoundary::Error, "operation_replay_mismatch" unless
            record.network_peer_id == peer.id && record.immutable_sha256 == digest &&
              record.immutable_operation == immutable_operation

          replay = true
        else
          record = DiscussionBridgeNetworkReplay.create!(
            network_peer: peer,
            origin_forum_id: provenance.fetch("origin_forum_id"),
            operation_id: provenance.fetch("operation_id"),
            immutable_sha256: digest,
            immutable_operation: immutable_operation,
            retained_result: {},
            correlation_id: correlation_id,
            expires_at: Time.zone.now + DiscourseNetworkProtocol::REPLAY_RETENTION,
          )
        end
      end
      Result.new(replay: replay, record: record)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def self.retain!(record:, result:)
      record.with_lock do
        if record.retained_result.present? && record.retained_result != result
          raise AdapterRequestBoundary::Error, "operation_replay_mismatch"
        end

        record.update!(retained_result: result)
      end
      result
    end
  end
end
