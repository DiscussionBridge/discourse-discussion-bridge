# frozen_string_literal: true

module DiscussionBridge
  class NetworkWorker
    MUTATING_ACTIONS = %w[publish update restore].freeze
    PASSIVE_ACTIONS = %w[hold unpublish].freeze

    def self.call(peer, client: NetworkPeerClient.new(peer))
      new(peer, client: client).call
    end

    def initialize(peer, client:)
      @peer = peer
      @client = client
    end

    def call
      return { outcome: "disabled" } unless @peer.operational?

      claim_correlation = correlation_id("claim")
      work = @client.claim(correlation_id: claim_correlation).first
      return { outcome: "idle" } unless work

      remote_record = @client.bridge_record(
        work.fetch("resource_id"),
        correlation_id: correlation_id("record"),
      )
      validate_remote_record!(work, remote_record)
      result = process(work, remote_record)
      record = local_record(work.fetch("resource_id"))
      @client.acknowledge(
        work: work,
        destination_binding: destination_binding(record, remote_record, work),
        correlation_id: correlation_id("ack"),
      )
      { outcome: "acknowledged", work_id: work.fetch("work_id"), result: result }
    rescue NetworkPeerClient::Error => error
      report_failure(work, failure_code(error.error_code)) if work
      { outcome: "failed", error_code: error.error_code }
    rescue AdapterRequestBoundary::Error => error
      report_failure(work, failure_code(error.error_code)) if work
      { outcome: "failed", error_code: error.error_code }
    rescue StandardError
      report_failure(work, "internal_error") if work
      { outcome: "failed", error_code: "internal_error" }
    end

    private

    def process(work, remote_record)
      action = work.fetch("action")
      return synchronize(work, remote_record) if MUTATING_ACTIONS.include?(action)
      return retain_existing(work) if PASSIVE_ACTIONS.include?(action)

      raise AdapterRequestBoundary::Error, "content_unsupported"
    end

    def synchronize(work, remote_record)
      detail, content = @client.source_detail(
        topic_id: remote_record.fetch("topic_id"),
        source_revision: work.fetch("source_revision"),
        correlation_id: correlation_id("source"),
      )
      unless detail["resource_id"] == work.fetch("resource_id") &&
          detail["topic_id"] == remote_record.fetch("topic_id") &&
          detail["source_revision"] == work.fetch("source_revision") &&
          detail["source_revision_sequence"] == work.fetch("source_revision_sequence")
        raise AdapterRequestBoundary::Error, "revision_conflict"
      end
      NetworkReceiver.call(
        peer: @peer,
        source_detail: detail,
        policy_revision: work.fetch("policy_revision"),
        content_html: content,
      )
    end

    def retain_existing(work)
      record = local_record(work.fetch("resource_id"))
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless record

      {
        "outcome" => work.fetch("action"),
        "resource_id" => record.resource_id,
        "topic_id" => record.topic_id,
        "mutated" => false,
        "route_forum_ids" => record.network_provenance.fetch("route_forum_ids"),
      }
    end

    def local_record(remote_resource_id)
      external_id = "network:#{@peer.remote_forum_id}:#{remote_resource_id}"
      DiscussionBridgeBridgeRecord.joins(:content_bindings).find_by(
        discussion_bridge_content_bindings: {
          content_connection_id: @peer.content_connection_id,
          external_id: external_id,
          role: "source",
          state: "active",
        },
      )
    end

    def destination_binding(record, remote_record, work)
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless
        record&.state == "healthy" && record.topic&.first_post

      local_binding = record.content_bindings.find_by!(
        content_connection_id: @peer.content_connection_id,
        role: "source",
        state: "active",
      )
      remote_bindings = Array(remote_record.fetch("bindings"))
      authoritative = remote_bindings.select do |candidate|
        candidate["connection_id"] == work.fetch("connection_id") &&
          candidate["role"] == "presentation" && candidate["state"] == "active"
      end
      raise AdapterRequestBoundary::Error, "reconciliation_required" unless authoritative.one?

      {
        binding_id: authoritative.first.fetch("binding_id"),
        external_id: authoritative.first.fetch("external_id"),
        canonical_url: authoritative.first.fetch("canonical_url"),
        publication_revision: "post:#{record.topic.first_post.id}:version:#{record.topic.first_post.version}",
        content_disposition: local_binding.content_disposition || record.content_disposition,
      }
    end

    def validate_remote_record!(work, record)
      unless record["resource_id"] == work.fetch("resource_id") &&
          record["source_revision"] == work.fetch("source_revision") &&
          record["source_revision_sequence"] == work.fetch("source_revision_sequence")
        raise AdapterRequestBoundary::Error, "revision_conflict"
      end
    end

    def report_failure(work, error_code)
      @client.fail(
        work: work,
        error_code: error_code,
        correlation_id: correlation_id("failure"),
      )
    rescue StandardError
      nil
    end

    def failure_code(error_code)
      return error_code if PublicationWorkProtocol::FAILURE_CODES.include?(error_code)
      return "reconciliation_required" if %w[operation_replay_mismatch revision_conflict].include?(error_code)
      return "authentication_failed" if error_code == "authentication_failed"
      return "scope_denied" if %w[scope_denied direction_denied policy_denied].include?(error_code)
      return "content_unsupported" if %w[content_unsupported integrity_failed].include?(error_code)
      return "validation_failed" if %w[validation_failed malformed_value unknown_field].include?(error_code)

      "destination_unavailable"
    end

    def correlation_id(stage)
      "network-#{stage}-#{SecureRandom.hex(8)}"
    end
  end
end
