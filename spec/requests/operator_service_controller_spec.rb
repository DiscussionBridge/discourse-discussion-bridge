# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorServiceController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.discussion_bridge_enabled = true
    @enqueued_jobs = []
    allow(Jobs).to receive(:enqueue) do |job_name, **arguments|
      @enqueued_jobs << [job_name, arguments]
    end
  end

  def operator_notification_jobs
    @enqueued_jobs.select do |job_name, _arguments|
      job_name == :discussion_bridge_operator_service_notification
    end
  end

  it "keeps local enablement separate from the explicit enrollment request" do
    sign_in(user)
    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: true } },
        as: :json
    expect(response).to have_http_status(:forbidden)

    sign_in(admin)
    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: true } },
        as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "enabled" => true,
      "status" => "inactive",
      "service_request_email" => "servicerequest@discussionbridge.dev",
      "grace_period_days" => 14,
      "notification_state" => "not_sent",
      "request_available" => true,
      "request_submitted" => false,
    )
    expect(operator_notification_jobs).to be_empty

    post "/discussion-bridge/admin/operator-service/request.json", as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "enabled" => true,
      "status" => "pending",
      "notification_state" => "queued",
      "request_available" => false,
      "request_submitted" => true,
    )
    expect(@enqueued_jobs).to include(
      [
        :discussion_bridge_operator_service_notification,
        {
          service_id: DiscussionBridgeOperatorService.instance.id,
          event: "requested",
          requested_by_id: admin.id,
        },
      ],
    )

    post "/discussion-bridge/admin/operator-service/request.json", as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(operator_notification_jobs.length).to eq(1)

    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: false } },
        as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("enabled" => false, "status" => "inactive")
  end

  it "rejects enrollment requests until an administrator enables the local capability" do
    sign_in(user)
    post "/discussion-bridge/admin/operator-service/request.json", as: :json
    expect(response).to have_http_status(:forbidden)

    sign_in(admin)
    post "/discussion-bridge/admin/operator-service/request.json", as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(
      "operator service must be enabled before requesting enrollment",
    )
    expect(operator_notification_jobs).to be_empty
  end
end
