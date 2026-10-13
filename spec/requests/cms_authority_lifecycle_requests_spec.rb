# frozen_string_literal: true

require "rails_helper"

describe "Native CMS scope authority provenance", type: :request do
  fab!(:admin)
  fab!(:other_admin) { Fabricate(:admin) }
  fab!(:user)

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(:wake_connection).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    @connection, =
      DiscussionBridgeContentConnection.issue!(
        name: "Native scope provenance HTTP fixture",
        platform: "ghost",
        allowed_origins: ["https://site.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"],
      )
  end

  it "uses the actual signed-in native admin and ignores a client actor claim" do
    sign_in(admin)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            allowed_lanes: %w[news other],
            actor_user_id: other_admin.id,
          },
        }
    expect(response.status).to eq(200)
    event = DiscussionBridgeCmsScopeEvent.where(content_connection_id: @connection.id).last
    expect(event.actor_user_id).to eq(admin.id)
    expect(event.event_origin).to eq("native_admin_scope_mutation")
    expect(event.changed_fields).to eq(["allowed_lanes"])
    expect(@connection.reload.allowed_lanes).to eq(%w[news other])
  end

  it "keeps a native nonadministrator outside the scope mutation and audit" do
    sign_in(user)
    put "/discussion-bridge/admin/content-connections/#{@connection.id}.json",
        params: {
          content_connection: {
            enabled: false,
          },
        }
    expect(response.status).to eq(403)
    expect(@connection.reload.enabled).to eq(true)
    expect(DiscussionBridgeCmsScopeEvent.where(content_connection_id: @connection.id)).to be_empty
  end
end
