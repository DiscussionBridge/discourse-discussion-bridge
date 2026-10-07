# frozen_string_literal: true

module DiscussionBridge
  class AdapterPublicationWorkController < AdapterController
    prepend_before_action :prevent_work_caching

    def claim
      with_current_connection { render json: JSON.generate(PublicationWork.claim!(@content_connection, @work_request)) }
    end

    def renew
      with_current_connection { render json: JSON.generate(PublicationWork.renew!(@content_connection, params[:work_id], @work_request)) }
    end

    private

    def parse_request_body(value)
      DestinationPolicy.fail_with unless value.is_a?(Hash) && value["correlation_id"] == @correlation_id
      @work_request = value
    end

    def prevent_work_caching
      response.headers["Cache-Control"] = "private, no-store"
    end
  end
end
