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

    def acknowledge
      with_current_connection do
        render json: JSON.generate(PublicationAcknowledgement.accept!(@content_connection, params[:work_id], @work_request))
      end
    end

    def failure
      with_current_connection do
        PublicationFailure.accept!(@content_connection, params[:work_id], @work_request,
          secret: request.headers["X-DiscussionBridge-Secret"])
        # CENTRAL's common rule requires correlation in every response body;
        # no failure-specific success fields are declared.
        render json: JSON.generate("correlation_id" => @correlation_id)
      end
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
