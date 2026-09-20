# frozen_string_literal: true

module DiscussionBridge
  class AdapterPlatformCatalogController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_json_request
    before_action :ensure_enabled
    before_action :authenticate_connection

    def update
      result = PlatformCatalog.call(params.require(:catalog), platform: @content_connection.platform)
      adapter_id, adapter_version = ContentConnectionAuthenticator.adapter_identity(request)
      raise ArgumentError, "adapter identity is required" unless adapter_id
      @content_connection.with_lock do
        @content_connection.reload
        expected_revision = params[:expected_catalog_revision].to_s.presence
        if @content_connection.platform_catalog_revision.present? &&
            expected_revision != @content_connection.platform_catalog_revision
          raise ArgumentError, "platform catalog changed; refresh before replacement"
        end
        if @content_connection.platform_catalog_revision.blank? && expected_revision.present?
          raise ArgumentError, "platform catalog replacement base is invalid"
        end
        if @content_connection.adapter_id.present? && @content_connection.adapter_id != adapter_id
          raise ArgumentError, "connection belongs to a different adapter"
        end
        prior_mapping_revision = @content_connection.destination_mapping_revision
        rebuilt_mapping = if @content_connection.destination_mapping.present?
          DestinationMapping.valid_against_catalog?(
            @content_connection.destination_mapping,
            connection: @content_connection,
            catalog: result.catalog,
            catalog_revision: result.revision,
          )
        end
        @content_connection.update!(
          platform_catalog: result.catalog,
          platform_catalog_revision: result.revision,
          platform_catalog_display_revision: result.display_revision,
          platform_catalog_adapter_id: adapter_id,
          platform_catalog_adapter_version: adapter_version,
          adapter_id: adapter_id,
          adapter_version: adapter_version,
          platform_catalog_observed_at: Time.zone.now,
          platform_catalog_refresh_requested_at: nil,
          destination_mapping: rebuilt_mapping&.mapping || @content_connection.destination_mapping,
          destination_mapping_revision: rebuilt_mapping&.revision,
        )
        if prior_mapping_revision != @content_connection.destination_mapping_revision
          @content_connection.mark_from_discourse_publications_pending!
        end
      end
      render json: {
        outcome: "accepted",
        catalog_revision: result.revision,
        catalog_display_revision: result.display_revision,
        destination_mapping_state: @content_connection.destination_mapping_current? ? "current" : "attention",
      }
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, ArgumentError => error
      render json: {
        outcome: "rejected", reason: reason_for(error), errors: [error.message],
      }, status: :unprocessable_entity
    end

    def show
      render json: {
        connection_id: @content_connection.public_id,
        catalog_revision: @content_connection.platform_catalog_revision,
        catalog_display_revision: @content_connection.platform_catalog_display_revision,
        catalog_adapter_id: @content_connection.platform_catalog_adapter_id,
        catalog_adapter_version: @content_connection.platform_catalog_adapter_version,
        connection_adapter_id: @content_connection.adapter_id,
        connection_adapter_version: @content_connection.adapter_version,
        refresh_requested_at: @content_connection.platform_catalog_refresh_requested_at&.iso8601(6),
        destination_mapping: @content_connection.destination_mapping,
        destination_mapping_revision: @content_connection.destination_mapping_revision,
        destination_mapping_state: @content_connection.destination_mapping_current? ? "current" : "attention",
      }
    end

    private

    def ensure_json_request
      raise Discourse::InvalidParameters.new(:format) unless request.format.json?
    end

    def ensure_enabled
      return if SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
      render json: { outcome: "rejected", reason: "endpoint_disabled" }, status: :service_unavailable
    end

    def authenticate_connection
      @content_connection = ContentConnectionAuthenticator.call(request, identity: :credential_only)
      render json: { outcome: "rejected", reason: "unauthorized" }, status: :unauthorized unless @content_connection
    end

    def reason_for(error)
      {
        "platform catalog changed; refresh before replacement" => "platform_catalog_changed",
        "platform catalog replacement base is invalid" => "platform_catalog_base_invalid",
        "connection belongs to a different adapter" => "adapter_identity_conflict",
        "adapter identity is required" => "adapter_identity_required",
      }.fetch(error.message, "invalid_platform_catalog")
    end
  end
end
