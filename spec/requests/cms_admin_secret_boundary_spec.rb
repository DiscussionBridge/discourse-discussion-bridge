# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::AdminContentConnectionsController do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.force_https = false
    @connection, @secret = DiscussionBridgeContentConnection.issue!(
      name: "Existing credential boundary fixture",
      platform: "ghost",
      allowed_origins: ["https://site.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: ["news"]
    )
  end

  def create_connection
    post "/discussion-bridge/admin/content-connections.json",
         params: {
           content_connection: {
             name: "Credential issuance boundary fixture",
             platform: "ghost",
             allowed_origins: ["https://site.example"],
             allowed_directions: ["from_discourse"],
             allowed_lanes: ["news"]
           }
         },
         as: :json
  end

  def rotate_connection
    post "/discussion-bridge/admin/content-connections/#{@connection.id}/rotate-secret.json",
         as: :json
  end

  def check_denied_issuance
    before_count = DiscussionBridgeContentConnection.count
    before_digest = @connection.reload.secret_digest
    create_connection
    expect(response).to have_http_status(:forbidden)
    expect(response.body.include?(@secret)).to eq(false)
    expect(DiscussionBridgeContentConnection.count).to eq(before_count)
    rotate_connection
    expect(response).to have_http_status(:forbidden)
    expect(response.body.include?(@secret)).to eq(false)
    expect(@connection.reload.secret_digest == before_digest).to eq(true)
  end

  it "denies anonymous creation and rotation without issuing or changing a secret" do
    check_denied_issuance
  end

  it "denies non-administrator creation and rotation without a privilege substitute" do
    sign_in(user)
    check_denied_issuance
  end

  it "reports actual native category restriction metadata without treating it as publication proof" do
    public_category = Fabricate(:category)
    restricted_category = Fabricate(:category, read_restricted: true)
    sign_in(admin)
    get "/discussion-bridge/admin/content-connections.json"
    expect(response).to have_http_status(:ok)
    categories = response.parsed_body.fetch("categories").index_by { |entry| entry.fetch("id_string") }
    expect(categories.fetch(public_category.id.to_s).fetch("read_restricted")).to eq(false)
    expect(categories.fetch(restricted_category.id.to_s).fetch("read_restricted")).to eq(true)
    expect(DiscussionBridgeCmsSourceIntent.count).to eq(0)
    expect(DiscussionBridgeCmsWork.count).to eq(0)
  end

  it "rejects missing native CSRF proof even with an administrator session" do
    sign_in(admin)
    previous = ApplicationController.allow_forgery_protection
    begin
      ApplicationController.allow_forgery_protection = true
      before_count = DiscussionBridgeContentConnection.count
      before_digest = @connection.reload.secret_digest
      create_connection
      expect(response).to have_http_status(:forbidden)
      expect(DiscussionBridgeContentConnection.count).to eq(before_count)
      expect(response.body.include?(@secret)).to eq(false)
      rotate_connection
      expect(response).to have_http_status(:forbidden)
      expect(@connection.reload.secret_digest == before_digest).to eq(true)
    ensure
      ApplicationController.allow_forgery_protection = previous
    end
  end

  it "returns a no-store secret only from direct administrator issuance and rotation" do
    sign_in(admin)
    create_connection
    expect(response).to have_http_status(:created)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Pragma"]).to eq("no-cache")
    issued = response.parsed_body.fetch("secret")
    issued_connection = DiscussionBridgeContentConnection.find(response.parsed_body.dig("content_connection", "id"))
    expect(issued_connection.authenticate_secret?(issued)).to eq(true)
    expect(issued_connection.secret_digest == Digest::SHA256.hexdigest(issued)).to eq(true)

    get "/discussion-bridge/admin/content-connections.json"
    expect(response).to have_http_status(:ok)
    expect(response.body.include?(issued)).to eq(false)
    expect(response.body.include?(@secret)).to eq(false)

    rotate_connection
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Pragma"]).to eq("no-cache")
    rotated = response.parsed_body.fetch("secret")
    expect(@connection.reload.authenticate_secret?(rotated)).to eq(true)
    expect(@connection.authenticate_secret?(@secret)).to eq(false)
    get "/discussion-bridge/admin/content-connections.json"
    expect(response.body.include?(rotated)).to eq(false)
  end
end
