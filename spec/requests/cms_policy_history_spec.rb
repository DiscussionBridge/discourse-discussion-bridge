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

  def repeat_revision!(position, earlier)
    event =
      DiscussionBridgeCmsConfigurationEvent.find_by!(
        policy_revision: @revisions[position]
      )
    following =
      DiscussionBridgeCmsConfigurationEvent.find_by!(
        previous_policy_revision: event.policy_revision
      )
    configuration = event.configuration.deep_dup
    configuration["policy"]["policy_revision"] = @revisions[earlier]
    event.update!(
      policy_revision: @revisions[earlier],
      configuration: configuration
    )
    following.update!(
      previous_policy_revision: @revisions[earlier],
      previous_configuration: configuration
    )
    expect(following.reload.previous_configuration).to eq(
      event.reload.configuration
    )
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

  it "bounds encoded bytes without truncating a policy change or its continuation" do
    13.times do |index|
      ids = 150.times.map { |number| "#{index}-#{number}".rjust(255, "a") }
      @revisions << configure(authors: ids)
    end
    after_revision = @revisions.first
    observed = []
    13.times do
      history(after_revision)
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to be <= 262_144
      body = response.parsed_body
      expect(body.fetch("items").size).to be_between(1, 20)
      observed.concat(
        body.fetch("items").map { |item| item.fetch("policy_revision") }
      )
      break unless body.fetch("next_policy_revision")
      expect(body.fetch("next_policy_revision")).not_to eq(after_revision)
      after_revision = body.fetch("next_policy_revision")
    end
    expect(observed).to eq(@revisions.drop(1))
  end

  it "refuses a repeated intermediate revision across count-based pages, including on continuation" do
    25.times { |index| @revisions << configure(authors: ["author-#{index}"]) }
    history
    expect(response).to have_http_status(:ok)
    continuation = response.parsed_body.fetch("next_policy_revision")
    expect(continuation).to eq(@revisions[20])
    repeat_revision!(21, 1)
    history(continuation)
    expect(response.parsed_body.fetch("code")).to eq("metadata_unavailable")
    history
    expect(response.parsed_body.fetch("code")).to eq("metadata_unavailable")
  end

  it "refuses the same ambiguity across byte-based pages without rewriting retained history" do
    13.times do |index|
      @revisions << configure(
        authors: 150.times.map { |n| "#{index}-#{n}".rjust(255, "a") }
      )
    end
    history
    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first.fetch("items").length).to be < 10
    continuation = first.fetch("next_policy_revision")
    repeat_revision!(10, 1)
    retained =
      DiscussionBridgeCmsConfigurationEvent.order(:id).pluck(:configuration)
    13.times do
      history(continuation)
      break if response.parsed_body["code"]
      continuation = response.parsed_body.fetch("next_policy_revision")
    end
    expect(response.parsed_body.fetch("code")).to eq("metadata_unavailable")
    expect(
      DiscussionBridgeCmsConfigurationEvent.order(:id).pluck(:configuration)
    ).to eq(retained)
  end

  it "returns typed unavailability for malformed anchor and intermediate JSON shapes" do
    @revisions << configure(authors: ["selected"])
    @revisions << configure
    [0, 1].each do |position|
      event =
        DiscussionBridgeCmsConfigurationEvent.find_by!(
          policy_revision: @revisions[position]
        )
      original = event.configuration.deep_dup
      [
        123,
        nil,
        [],
        {},
        { "policy" => nil },
        { "policy" => [] },
        {
          "policy" => {
            "policy_revision" => @revisions[position],
            "author_ids" => 123,
            "taxonomy_ids" => []
          }
        }
      ].each do |malformed|
        event
          .class
          .where(id: event.id)
          .update_all(
            "configuration = #{event.class.connection.quote(JSON.generate(malformed))}::jsonb"
          )
        history
        expect(response.parsed_body.fetch("code")).to eq("metadata_unavailable")
        event.update_columns(configuration: original)
      end
    end
    history
    expect(response).to have_http_status(:ok)
  end

  it "rejects malformed UTF-8 without replacing or decoding an identity twice" do
    original = @revisions.first
    event =
      DiscussionBridgeCmsConfigurationEvent.find_by!(policy_revision: original)
    unicode = "policy:雪+%FF"
    configuration = event.configuration.deep_dup
    configuration["policy"]["policy_revision"] = unicode
    event.update!(policy_revision: unicode, configuration: configuration)
    @connection.update!(cms_configuration: configuration)
    @revisions = [unicode]
    history
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("after_policy_revision")).to eq(unicode)
    %w[%FF %C0%AF %ED%A0%80 %E2%82 % %0G].each do |bad|
      # Preserve the raw query at Rack's boundary: the integration driver's URI
      # builder itself refuses malformed percent escapes before dispatch.
      get "/discussion-bridge/v4/policy-history.json",
          headers: @headers,
          env: {
            "QUERY_STRING" =>
              "after_policy_revision=#{bad}&through_policy_revision=r2"
          }
      expect(response.parsed_body.fetch("code")).to eq("invalid_field")
    end
    get "/discussion-bridge/v4/policy-history.json?%61fter_policy_revision=a&after_policy_revision=b&through_policy_revision=c",
        headers: @headers
    expect(response.parsed_body.fetch("code")).to eq("invalid_field")
    get "/discussion-bridge/v4/work/not-a-work.json?x=%FF", headers: @headers
    expect(response.parsed_body.fetch("code")).to eq("invalid_field")
    expect(
      DiscussionBridgeCmsConfigurationEvent.find(event.id).configuration
    ).to eq(configuration)
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
