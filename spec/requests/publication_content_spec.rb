# frozen_string_literal: true

require "rails_helper"
require "base64"

describe DiscussionBridge::AdapterBridgeRecordsController do
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, user: admin, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    @connection, @secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Bounded publication reader",
        platform: "astro",
        allowed_origins: ["https://astro.example.com"],
        allowed_directions: ["from_discourse"],
      )
    @record =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: topic.id,
        external_id: "bounded-source",
        canonical_url: "https://astro.example.com/bounded-source/",
        native_materialization: true,
      ).record
    @body = "<p>#{"é" * 40_000}</p>"
    first_post.update!(cooked: @body)
  end

  def headers(connection = @connection, secret = @secret)
    {
      "X-DiscussionBridge-Connection" => connection.public_id,
      "X-DiscussionBridge-Secret" => secret,
    }
  end

  def detail(negotiated: true)
    get "/discussion-bridge/v1/bridge-records/#{@record.resource_id}.json",
        headers: headers,
        params: negotiated ? { publication_contract: "0.3.0-alpha.1" } : {}
  end

  def chunk(edition, offset)
    get "/discussion-bridge/v1/bridge-records/#{@record.resource_id}/content.json",
        headers: headers,
        params: {
          edition: edition,
          offset: offset,
        }
  end

  it "retains legacy inline content and negotiates bounded complete-content metadata" do
    detail(negotiated: false)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "content_html")).to eq(@body)
    detail
    expect(response).to have_http_status(:ok)
    record = response.parsed_body.fetch("bridge_record")
    expect(record.fetch("content_html")).to be_nil
    expect(record.fetch("source")).to include("status" => "active")
    expect(record.dig("source", "content")).to eq(
      "bytes" => @body.bytesize,
      "sha256" => Digest::SHA256.hexdigest(@body),
      "path" => "/discussion-bridge/v1/bridge-records/#{@record.resource_id}/content.json",
      "chunk_bytes" => 32_768,
    )
    expect(response.body.bytesize).to be < 4_096
  end

  it "returns exact bounded bytes across UTF8 character boundaries without a publication-size cap" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    offset = 0
    complete = +"".b
    loop do
      chunk(edition, offset)
      expect(response).to have_http_status(:ok)
      data = response.parsed_body
      bytes = Base64.strict_decode64(data.fetch("chunk_base64"))
      expect(bytes.bytesize).to eq([32_768, @body.bytesize - offset].min)
      expect(response.body.bytesize).to be <= 65_536
      expect(data).to include(
        "resource_id" => @record.resource_id,
        "edition" => edition,
        "offset" => offset,
        "total_bytes" => @body.bytesize,
        "content_sha256" => Digest::SHA256.hexdigest(@body),
      )
      complete << bytes
      break if data.fetch("next_offset").nil?
      expect(data.fetch("next_offset")).to eq(offset + bytes.bytesize)
      offset = data.fetch("next_offset")
    end
    expect(complete.bytesize).to eq(@body.bytesize)
    expect(complete.force_encoding(Encoding::UTF_8)).to eq(@body)
    expect(complete.valid_encoding?).to eq(true)
  end

  it "refuses a stale edition and permits fresh single-record detail recovery" do
    detail
    original = response.parsed_body.dig("bridge_record", "source", "edition")
    first_post.update!(cooked: "<p>Current edited source</p>")
    chunk(original, 0)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to include("reason" => "source_edition_changed")
    expect(response.parsed_body).not_to have_key("chunk_base64")
    detail
    current = response.parsed_body.dig("bridge_record", "source", "edition")
    expect(current).not_to eq(original)
    chunk(current, 0)
    expect(response).to have_http_status(:ok)
  end

  it "refuses a page when its native source changes during payload construction" do
    changed = false
    allow(DiscussionBridge::SourceEdition).to receive(
      :for_topic,
    ).and_wrap_original do |method, *arguments|
      result = method.call(*arguments)
      unless changed
        first_post.update!(cooked: "<p>A source edition changed while the page was mapped</p>")
        changed = true
      end
      result
    end
    get "/discussion-bridge/v1/bridge-records.json",
        headers: headers,
        params: {
          publication_contract: "0.3.0-alpha.1",
        }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).not_to have_key("bridge_records")
  end

  it "refuses a page when its native source changes during JSON serialization" do
    changed = false
    allow(ActiveSupport::JSON).to receive(:encode).and_wrap_original do |method, value, *arguments|
      json = method.call(value, *arguments)
      if !changed && value.is_a?(Hash) && value.key?(:bridge_records)
        first_post.update!(cooked: "<p>A source edition changed while the page was serialized</p>")
        changed = true
      end
      json
    end
    get "/discussion-bridge/v1/bridge-records.json",
        headers: headers,
        params: {
          publication_contract: "0.3.0-alpha.1",
        }
    expect(changed).to eq(true)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).not_to have_key("bridge_records")
  end

  it "rejects malformed negotiation, edition and byte offsets" do
    get "/discussion-bridge/v1/bridge-records/#{@record.resource_id}.json",
        headers: headers,
        params: {
          publication_contract: "unapproved",
        }
    expect(response).to have_http_status(:bad_request)
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    ["-1", "01", "1.5", @body.bytesize.to_s, "9007199254740992"].each do |offset|
      chunk(edition, offset)
      expect(response).to have_http_status(:bad_request)
    end
    chunk("BAD", 0)
    expect(response).to have_http_status(:bad_request)
  end

  it "keeps chunks within the authenticated connection scope" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    other, secret =
      DiscussionBridgeContentConnection.issue!(
        name: "Another reader",
        platform: "astro",
        allowed_origins: ["https://astro.example.com"],
        allowed_directions: ["from_discourse"],
      )
    get "/discussion-bridge/v1/bridge-records/#{@record.resource_id}/content.json",
        headers: headers(other, secret),
        params: {
          edition: edition,
          offset: 0,
        }
    expect(response).to have_http_status(:not_found)
    get "/discussion-bridge/v1/bridge-records/#{@record.resource_id}/content.json",
        headers: headers(@connection, "incorrect"),
        params: {
          edition: edition,
          offset: 0,
        }
    expect(response).to have_http_status(:unauthorized)
  end

  it "withdraws a now-private scoped source without disclosing private fields and restores its identity" do
    detail
    original_edition = response.parsed_body.dig("bridge_record", "source", "edition")
    private_category = Fabricate(:category, read_restricted: true)
    topic.update!(category_id: private_category.id, title: "Private source title must stay private")
    first_post.update!(cooked: "<p>Private source body must stay private</p>")
    detail
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("bridge_record")
    expect(data).to include(
      "resource_id" => @record.resource_id,
      "topic_id" => topic.id,
      "title" => "Source publication withdrawn",
      "content_html" => nil,
    )
    expect(data.fetch("source")).to include(
      "status" => "withdrawn",
      "reason" => "source_unavailable",
    )
    expect(data.fetch("source").keys).to contain_exactly("status", "reason", "edition")
    expect(data.fetch("topic_url")).to eq(Topic.url(topic.id, nil))
    expect(response.body).not_to include(
      "Private source title",
      "Private source body",
      admin.username,
    )
    get "/discussion-bridge/v1/bridge-records.json",
        headers: headers,
        params: {
          publication_contract: "0.3.0-alpha.1",
        }
    expect(
      response.parsed_body.fetch("bridge_records").map { |record| record.fetch("resource_id") },
    ).to include(@record.resource_id)
    chunk(original_edition, 0)
    expect(response).to have_http_status(:conflict)
    detail(negotiated: false)
    expect(response).to have_http_status(:conflict)
    expect(response.body).not_to include("Private source title", "Private source body")
    topic.update!(category_id: category.id)
    detail
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("active")
    expect(response.parsed_body.dig("bridge_record", "resource_id")).to eq(@record.resource_id)
  end

  it "withdraws deleted sources and login-required forum sources without returning chunks" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    first_post.update!(deleted_at: Time.zone.now)
    detail
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
    chunk(edition, 0)
    expect(response).to have_http_status(:conflict)
    first_post.update!(deleted_at: nil)
    SiteSetting.login_required = true
    detail
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
  end

  it "withdraws a hidden first post using native post permissions without leaking its content" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    SiteSetting.hidden_post_visible_groups = Group::AUTO_GROUPS[:staff].to_s
    first_post.hide!(PostActionType.types[:spam])
    topic.reload
    first_post.reload
    expect(Guardian.new(nil).can_see?(topic)).to eq(true)
    expect(Guardian.new(nil).can_see?(first_post)).to eq(false)

    detail
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
    expect(response.body).not_to include(@body, admin.username)
    chunk(edition, 0)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).not_to have_key("chunk_base64")
    detail(negotiated: false)
    expect(response).to have_http_status(:conflict)
    expect(response.body).not_to include(@body, admin.username)

    first_post.update!(hidden: false)
    detail
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("active")
    expect(response.parsed_body.dig("bridge_record", "resource_id")).to eq(@record.resource_id)
  end

  it "withdraws private messages and known imported external sources rather than republishing them" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    topic.update!(archetype: Archetype.private_message, category_id: nil)
    detail
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
    expect(response.body).not_to include(first_post.cooked, admin.username)
    chunk(edition, 0)
    expect(response).to have_http_status(:conflict)

    topic.update!(archetype: Archetype.default, category_id: category.id)
    DiscussionBridgeBridgeRecord.create!(
      resource_id: SecureRandom.uuid,
      direction: "to_discourse",
      state: "healthy",
      topic_id: topic.id,
      title: "Known external source",
      effective_actor_id: admin.id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
    )
    detail
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
    expect(response.body).not_to include(first_post.cooked, admin.username)
    chunk(edition, 0)
    expect(response).to have_http_status(:conflict)
  end

  it "withdraws a scoped source when native Core establishes imported article ancestry" do
    detail
    edition = response.parsed_body.dig("bridge_record", "source", "edition")
    TopicEmbed.create!(topic: topic, post: first_post, embed_url: "https://source.example/article/")
    detail
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("bridge_record", "source", "status")).to eq("withdrawn")
    expect(response.parsed_body.dig("bridge_record", "resource_id")).to eq(@record.resource_id)
    expect(response.body).not_to include(@body, admin.username, "source.example/article/")
    chunk(edition, 0)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).not_to have_key("chunk_base64")
  end
end
