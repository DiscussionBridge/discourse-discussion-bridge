# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CmsPolicyHistoryController do
  fab!(:admin)

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.force_https = true
    @connection, secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Selection history fixture",
        platform: "ghost",
        allowed_origins: ["https://history.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    @headers = {
      "X-DiscussionBridge-Connection" => @connection.public_id,
      "X-DiscussionBridge-Secret" => secret
    }
    @store = DiscussionBridge::CmsAuthorityStore.new(@connection)
    @configuration = {
      "profile" => "ghost",
      "destination_origin" => "https://history.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:history",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true
      },
      "policy" => {
        "enabled" => false,
        "selection" => "all_public",
        "category_ids" => [],
        "include_topic_ids" => [],
        "exclude_topic_ids" => [],
        "include_unlisted" => false,
        "publication_kind" => "dynamic",
        "presentation_mode" => "simple",
        "author_ids" => [],
        "taxonomy_ids" => []
      }
    }
    @revisions = [configure]
  end

  def configure(authors: [], tags: [])
    @configuration["policy"]["author_ids"] = authors
    @configuration["policy"]["taxonomy_ids"] = tags
    @store.configure!(
      actor: admin,
      input: {
        "expected_policy_revision" =>
          @connection.reload.cms_configuration&.dig(
            "policy",
            "policy_revision"
          ),
        "configuration" => @configuration.deep_dup
      }
    )
    @connection.reload.cms_configuration.dig("policy", "policy_revision")
  end

  def history(
    after_revision = @revisions.first,
    through_revision = @revisions.last,
    headers: @headers
  )
    get "/discussion-bridge/v4/policy-history.json",
        params: {
          after_policy_revision: after_revision,
          through_policy_revision: through_revision
        },
        headers: headers
  end

  it "returns the complete clear and reselect chain, not actor/configuration details, without writes" do
    author_id = "a" * 24
    @revisions << configure(authors: [author_id], tags: ["b" * 24])
    @revisions << configure
    @revisions << configure(authors: [author_id])
    counts = [
      DiscussionBridgeCmsConfigurationEvent.count,
      DiscussionBridgeCmsMutationReceipt.count,
      DiscussionBridgeCmsReadSnapshot.count,
      DiscussionBridgeCmsWork.count
    ]
    history
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys.sort).to eq(
      %w[
        after_policy_revision
        connection_id
        items
        next_policy_revision
        through_policy_revision
      ]
    )
    expect(body["items"].map { |item| item["policy_revision"] }).to eq(
      @revisions.drop(1)
    )
    expect(body["items"].map { |item| item["previous_policy_revision"] }).to eq(
      @revisions[0...-1]
    )
    expect(body["items"][1]["author_ids"]).to eq([])
    expect(body["items"][1]["taxonomy_ids"]).to eq([])
    expect(
      body["items"].all? do |item|
        item.keys.sort ==
          %w[author_ids policy_revision previous_policy_revision taxonomy_ids]
      end
    ).to eq(true)
    expect(body["next_policy_revision"]).to eq(nil)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(
      [
        DiscussionBridgeCmsConfigurationEvent.count,
        DiscussionBridgeCmsMutationReceipt.count,
        DiscussionBridgeCmsReadSnapshot.count,
        DiscussionBridgeCmsWork.count
      ]
    ).to eq(counts)
    history(@revisions.last)
    expect(response.parsed_body["items"]).to eq([])
  end

  it "pages exact revision-keyed intervals and refuses a concurrent policy change" do
    23.times { |index| @revisions << configure(authors: ["author-#{index}"]) }
    history
    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first["items"].size).to eq(20)
    expect(first["next_policy_revision"]).to eq(@revisions[20])
    history(first["next_policy_revision"])
    expect(
      response.parsed_body["items"].map { |item| item["policy_revision"] }
    ).to eq(@revisions.last(3))
    expect(response.parsed_body["next_policy_revision"]).to eq(nil)
    configure(authors: ["changed-again"])
    history(first["next_policy_revision"])
    expect(response.parsed_body["code"]).to eq("revision_conflict")
  end

  it "refuses missing, discontinuous, future and foreign anchors instead of guessing an interval" do
    @revisions << configure(authors: ["selected"])
    @revisions << configure
    history("unknown")
    expect(response.parsed_body["code"]).to eq("metadata_unavailable")
    event =
      DiscussionBridgeCmsConfigurationEvent.find_by!(
        policy_revision: @revisions[1]
      )
    event.update!(previous_policy_revision: "different")
    history
    expect(response.parsed_body["code"]).to eq("metadata_unavailable")
    event.destroy!
    history
    expect(response.parsed_body["code"]).to eq("metadata_unavailable")
    other, other_secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Other selection history",
        platform: "ghost",
        allowed_origins: ["https://history.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    DiscussionBridge::CmsAuthorityStore.new(other).configure!(
      actor: admin,
      input: {
        "expected_policy_revision" => nil,
        "configuration" => @configuration.deep_dup
      }
    )
    history(
      @revisions.first,
      other.reload.cms_configuration.dig("policy", "policy_revision"),
      headers: {
        "X-DiscussionBridge-Connection" => other.public_id,
        "X-DiscussionBridge-Secret" => other_secret
      }
    )
    expect(response.parsed_body["code"]).to eq("metadata_unavailable")
  end

  it "requires live scoped credentials and rejects duplicate, unknown, missing and oversized query fields" do
    get "/discussion-bridge/v4/policy-history.json", headers: @headers
    expect(response.parsed_body["code"]).to eq("invalid_field")
    %W[
      after_policy_revision=a&after_policy_revision=b&through_policy_revision=c
      after_policy_revision=a&through_policy_revision=b&actor=1
      #{"x" * 4097}
    ].each do |query|
      get "/discussion-bridge/v4/policy-history.json?#{query}",
          headers: @headers
      expect(response.status).to be_between(400, 499)
    end
    history(headers: @headers.merge("X-DiscussionBridge-Secret" => "wrong"))
    expect(response.parsed_body["code"]).to eq("authentication_failed")
    @connection.update!(allowed_directions: ["to_discourse"])
    history
    expect(response.parsed_body["code"]).to eq("scope_denied")
    @connection.update!(enabled: false)
    history
    expect(response.parsed_body["code"]).to eq("connection_disabled")
  end
end
