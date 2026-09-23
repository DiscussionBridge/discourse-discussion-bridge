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

  it "lets only an administrator explicitly request or disable service" do
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
      "status" => "pending",
      "service_request_email" => "servicerequest@discussionbridge.dev",
      "grace_period_days" => 14,
      "notification_state" => "queued",
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

    put "/discussion-bridge/admin/operator-service.json",
        params: { operator_service: { enabled: false } },
        as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("enabled" => false, "status" => "inactive")
  end
end
