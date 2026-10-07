# frozen_string_literal: true

module DiscussionBridge
  class SourceRevocations
    WINDOW_RETENTION_SECONDS = 2_592_000
    MAX_RESPONSE_BYTES = 65_536
    CURSOR_PURPOSE = "discussion-bridge-source-revocations"
    MAX_TOKEN_BYTES = 4096

    def initialize(connection:, query:, correlation_id:)
      @connection, @query, @correlation_id = connection, query, correlation_id
    end

    def page
      limit = parse_limit
      policy = SourceConnectionScope.revision(@connection)
      cursor = decode_cursor(policy)
      window = find_window(cursor, policy)
      window.with_lock do
        fail_with("snapshot_expired") if window.last_read_at < Time.now.utc - WINDOW_RETENTION_SECONDS
        fail_with("cursor_snapshot_mismatch") unless window.policy_revision == policy
        position = cursor ? cursor.fetch("position") : 0
        starting_position = position
        fail_with("cursor_snapshot_mismatch") unless position.between?(0, window.revocation_cut)
        items = []
        notices.where("id > ? AND id <= ?", position, window.revocation_cut).order(:id).limit(limit).each do |notice|
          item = item_for(notice)
          if (items + [item]).to_json.bytesize > MAX_RESPONSE_BYTES - 8192
            fail_with("content_unsupported") if position == starting_position
            break
          end
          items << item
          position = notice.id
        end
        remaining = notices.where("id > ? AND id <= ?", position, window.revocation_cut).exists?
        value = { high_water: window.public_id, policy_revision: window.policy_revision, items: items,
          next_cursor: remaining ? issue_cursor(window, position) : nil, complete: !remaining,
          correlation_id: @correlation_id }
        fail_with("content_unsupported") if value.to_json.bytesize > MAX_RESPONSE_BYTES
        window.update!(last_read_at: Time.now.utc)
        value
      end
    end

    def detail(resource_id:)
      unless resource_id.is_a?(String) && /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.match?(resource_id)
        fail_with("validation_failed")
      end
      notice = notices.where(resource_id: resource_id).order(id: :desc).first
      fail_with("not_found") unless notice
      item_for(notice).merge(affected_binding_ids: [notice.binding_public_id],
        policy_revision: SourceConnectionScope.revision(@connection), correlation_id: @correlation_id)
    end

    private

    def notices
      DiscussionBridgeSourceRevocation.where(content_connection_id: @connection.id)
    end

    def item_for(notice)
      SourceRevocationProducer.verify!(notice)
      { revocation_id: notice.public_id, resource_id: notice.resource_id,
        source_revision: notice.source_revision, source_revision_sequence: notice.source_revision_sequence,
        reason: notice.reason, effective_at: notice.effective_at_raw, restorable: notice.restorable }
    end

    def parse_limit
      return 25 unless @query.key?("limit")
      raw = @query["limit"]
      fail_with("validation_failed") unless raw.is_a?(String) && /\A[1-9]\d{0,2}\z/.match?(raw)
      limit = Integer(raw)
      fail_with("validation_failed") unless limit.between?(1, 100)
      limit
    end

    def decode_cursor(policy)
      return nil unless @query.key?("cursor")
      raw = @query["cursor"]
      fail_with("validation_failed") unless raw.is_a?(String) && raw.bytesize.between?(1, MAX_TOKEN_BYTES)
      value = verifier.verified(raw, purpose: CURSOR_PURPOSE)
      fields = %w[connection_id high_water policy_revision position]
      fail_with("validation_failed") unless value.is_a?(Hash) && value.keys.sort == fields.sort && value["position"].is_a?(Integer)
      fail_with("cursor_snapshot_mismatch") unless value["connection_id"] == @connection.public_id &&
        value["policy_revision"] == policy && value["high_water"] == @query["high_water"]
      value
    end

    def find_window(cursor, policy)
      unless @query.key?("high_water")
        fail_with("cursor_snapshot_mismatch") if cursor
        now = Time.now.utc
        return DiscussionBridgeSourceRevocationWindow.create!(content_connection: @connection,
          public_id: "dbw_#{SecureRandom.hex(16)}", policy_revision: policy,
          revocation_cut: notices.order(id: :desc).limit(1).pick(:id) || 0, established_at: now, last_read_at: now)
      end
      raw = @query["high_water"]
      fail_with("validation_failed") unless raw.is_a?(String) && /\Adbw_[a-f0-9]{32}\z/.match?(raw)
      window = DiscussionBridgeSourceRevocationWindow.find_by(content_connection_id: @connection.id, public_id: raw)
      fail_with("snapshot_expired") unless window
      window
    end

    def issue_cursor(window, position)
      verifier.generate({ "connection_id" => @connection.public_id, "high_water" => window.public_id,
        "policy_revision" => window.policy_revision, "position" => position }, purpose: CURSOR_PURPOSE)
    end

    def verifier
      Rails.application.message_verifier(:discussion_bridge_source_revocations)
    end

    def fail_with(code)
      raise AdapterRequestBoundary::Error.new(code)
    end
  end
end
