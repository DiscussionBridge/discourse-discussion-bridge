# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::NetworkPeerClient do
  class NetworkClientResponse
    attr_reader :code

    def initialize(code:, payload:, content_type: "application/json")
      @code = code.to_s
      @body = payload.is_a?(String) ? payload : JSON.generate(payload)
      @content_type = content_type
    end

    def [](name)
      @content_type if name.downcase == "content-type"
    end

    def read_body
      yield @body
    end
  end

  class NetworkClientHTTP
    attr_reader :requests
    attr_accessor :read_timeout, :write_timeout

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      yield @responses.shift
    end
  end

  fab!(:admin)
  fab!(:category)

  before do
    @original_forum_name = ENV["DISCUSSIONBRIDGE_FORUM_NAME"]
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Regional Chapter"
    DiscussionBridgeForumIdentity.enable!(actor: admin)
    @connection, = DiscussionBridgeContentConnection.issue!(
      name: "National network source",
      platform: "discourse",
      allowed_origins: ["https://national.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
      default_category_id: category.id,
      destination_policies: [destination_policy],
      policy_revision: "policy:2026-09-27:1",
      network_enabled: true,
      network_peer_forum_id: "dbf_11111111111111111111111111111111",
      network_relationship: "hub_to_spoke",
    )
    @peer = DiscussionBridgeNetworkPeer.create!(
      content_connection: @connection,
      name: "National Organization",
      remote_forum_id: "dbf_11111111111111111111111111111111",
      remote_forum_name: "National Organization",
      remote_origin: "https://national.example",
      remote_connection_id: "dbc_#{"1" * 24}",
      remote_secret: "s" * 32,
      relationship: "hub_to_spoke",
      enabled: true,
      authorized_by: admin,
      authorized_at: Time.zone.now,
    )
  end

  after { ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = @original_forum_name }

  def destination_policy
    DiscussionBridge::DiscourseNetworkProtocol.destination_policy(
      peer_forum_id: "dbf_11111111111111111111111111111111",
      relationship: "hub_to_spoke",
    )
  end

  def fixture_detail
    JSON.parse(
      File.read(
        File.expand_path(
          "../../../adapter-contract-successor/fixtures/network-source-detail.json",
          __dir__,
        ),
      ),
    )
  end

  def use_http(*responses)
    http = NetworkClientHTTP.new(responses)
    FinalDestination::HTTP.stubs(:start).yields(http)
    http
  end

  it "sends exact authenticated claim headers and a bounded one-item request" do
    http = use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: { "publication_work" => [], "claimed_at" => Time.zone.now.iso8601(6) },
      ),
    )

    expect(described_class.new(@peer).claim(correlation_id: "network-claim-1234")).to eq([])
    request = http.requests.sole
    expect(request.path).to eq("/discussion-bridge/v1/publication-work/claim.json")
    expect(request[DiscussionBridge::AdapterRequestBoundary::CONNECTION_HEADER]).to eq(
      @peer.remote_connection_id,
    )
    expect(request[DiscussionBridge::AdapterRequestBoundary::SECRET_HEADER]).to eq("s" * 32)
    expect(request[DiscussionBridge::AdapterRequestBoundary::CONTRACT_HEADER]).to eq(
      DiscussionBridge::CONTRACT_VERSION,
    )
    expect(JSON.parse(request.body)).to include(
      "maximum_items" => 1,
      "correlation_id" => "network-claim-1234",
    )
  end

  it "reassembles and verifies exact bounded chunk responses" do
    detail = fixture_detail
    content = "<p>#{"network publication " * 4_000}</p>"
    chunks = content.bytes.each_slice(DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES)
      .map { |bytes| bytes.pack("C*") }
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content),
      "chunk_count" => chunks.length,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    responses = [NetworkClientResponse.new(code: 200, payload: detail)]
    chunks.each_with_index do |chunk, index|
      responses << NetworkClientResponse.new(
        code: 200,
        payload: {
          "source_revision" => detail.fetch("source_revision"),
          "chunk" => index + 1,
          "chunk_count" => chunks.length,
          "decoded_bytes" => chunk.bytesize,
          "chunk_sha256" => Digest::SHA256.hexdigest(chunk),
          "content_base64" => Base64.strict_encode64(chunk),
          "correlation_id" => "network-source-1234",
        },
      )
    end
    http = use_http(*responses)

    payload, materialized = described_class.new(@peer).source_detail(
      topic_id: detail.fetch("topic_id"),
      source_revision: detail.fetch("source_revision"),
      correlation_id: "network-source-1234",
    )

    expect(payload.fetch("content_transport").fetch("mode")).to eq("chunked")
    expect(materialized).to eq(content)
    expect(http.requests.length).to eq(chunks.length + 1)
  end

  it "fails closed on an oversized or non-JSON peer response" do
    oversized = use_http(
      NetworkClientResponse.new(code: 200, payload: "{" + ("x" * 65_536)),
    )
    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-oversized")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("request_too_large") }
    expect(oversized.requests.length).to eq(1)

    use_http(NetworkClientResponse.new(code: 200, payload: "ok", content_type: "text/plain"))
    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-not-json")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("destination_unavailable") }
  end
end
