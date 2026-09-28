# frozen_string_literal: true

module DiscussionBridge
  class AdapterPublicationWorkController < AdapterController
    def claim
      require_from_discourse!
      claimed_at = Time.zone.now
      work = PublicationWorkRegistry.claim(
        connection: @content_connection,
        worker_id: params.require(:worker_id),
        maximum_items: params[:maximum_items],
        requested_lease_seconds: params[:requested_lease_seconds],
        correlation_id: @correlation_id,
      )
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json({ publication_work: work, claimed_at: claimed_at.iso8601(6) })
    end

    def renew
      require_from_discourse!
      result = PublicationWorkRegistry.renew(
        connection: @content_connection,
        work_id: params.require(:work_id),
        lease_token: params.require(:lease_token),
        requested_lease_seconds: params.require(:requested_lease_seconds),
      )
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json(result)
    end

    def acknowledge
      require_from_discourse!
      result = PublicationWorkRegistry.acknowledge(
        connection: @content_connection,
        work_id: params.require(:work_id),
        payload: request.request_parameters,
      )
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json(result)
    end

    def failure
      require_from_discourse!
      result = PublicationWorkRegistry.fail(
        connection: @content_connection,
        work_id: params.require(:work_id),
        payload: request.request_parameters,
      )
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json(result)
    end

    private

    def require_from_discourse!
      raise AdapterRequestBoundary::Error, "direction_denied" unless
        @content_connection.allows_direction?("from_discourse")
    end

    def maximum_json_bytes
      65_536
    end

    def allowed_body_fields
      case action_name
      when "claim"
        PublicationWorkProtocol::CLAIM_REQUIRED_FIELDS + PublicationWorkProtocol::CLAIM_OPTIONAL_FIELDS
      when "renew"
        PublicationWorkProtocol::RENEW_FIELDS
      when "acknowledge"
        PublicationWorkProtocol::ACK_REQUIRED_FIELDS + PublicationWorkProtocol::ACK_OPTIONAL_FIELDS
      when "failure"
        PublicationWorkProtocol::FAILURE_FIELDS
      else
        []
      end
    end

    def require_known_nested_body_fields
      return unless action_name == "acknowledge"

      binding = request.request_parameters["destination_binding"]
      return unless binding.is_a?(Hash)
      raise AdapterRequestBoundary::Error, "unknown_field" if
        (binding.keys.map(&:to_s) - PublicationWorkProtocol::DESTINATION_BINDING_FIELDS).any?
    end
  end
end
