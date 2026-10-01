# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::NetworkPeerClient do
  class NetworkMonotonicClock
    attr_reader :now

    def initialize(now = 0.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class NetworkClientResponse
    PAYLOAD_CORRELATION = Object.new

    attr_reader :code

    def initialize(
      code:,
      payload:,
      content_type: "application/json",
      correlation_header: PAYLOAD_CORRELATION,
      content_length: nil,
      chunks: nil,
      before_chunk: nil
    )
      @code = code.to_s
      @body = payload.is_a?(String) ? payload : JSON.generate(payload)
      @content_type = content_type
      @chunks = chunks || [@body]
      @before_chunk = before_chunk
      @content_length = content_length
      @correlation_header = if correlation_header.equal?(PAYLOAD_CORRELATION)
        payload["correlation_id"] if payload.is_a?(Hash)
      else
        correlation_header
      end
    end

    def [](name)
      case name.downcase
      when "content-type"
        @content_type
      when DiscussionBridge::AdapterRequestBoundary::CORRELATION_HEADER.downcase
        @correlation_header
      when "content-length"
        @content_length
      end
    end

    def read_body
      @chunks.each do |chunk|
        @before_chunk&.call
        yield chunk
      end
    end
  end

  class NetworkClientHTTP
    attr_reader :read_timeouts, :requests, :write_timeouts

    def initialize(responses)
      @responses = responses
      @requests = []
      @read_timeouts = []
      @write_timeouts = []
    end

    def read_timeout=(value)
      @read_timeouts << value
    end

    def write_timeout=(value)
      @write_timeouts << value
    end

    def request(request)
      @requests << request
      yield @responses.shift
    end
  end

  class HeaderProgressHTTP
    attr_reader :iterations, :request_finished
    attr_accessor :read_timeout, :write_timeout

    def initialize
      @iterations = 0
    end

    def request(_request)
      loop do
        @iterations += 1
        raise "header wait test watchdog exhausted" if @iterations > 1_000

        sleep(0.001)
      end
    ensure
      @request_finished = true
    end
  end

  class BlockingStartHTTP
    class << self
      attr_reader :iterations

      def reset!
        @iterations = 0
      end

      def start(...)
        loop do
          @iterations += 1
          raise "connection test watchdog exhausted" if @iterations > 1_000

          sleep(0.001)
        end
      end
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
        File.expand_path("../fixtures/network-source-detail.json", __dir__),
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
        payload: {
          "publication_work" => [],
          "claimed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => "network-claim-1234",
        },
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

  it "bounds a progressing response by total exchange time rather than inactivity" do
    clock = NetworkMonotonicClock.new
    correlation = "network-progressing-response"
    payload = JSON.generate(
      "publication_work" => [],
      "claimed_at" => Time.zone.now.iso8601(6),
      "correlation_id" => correlation,
    )
    chunks = payload.bytes.each_slice((payload.bytesize / 3.0).ceil).map { |bytes| bytes.pack("C*") }
    http = use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: payload,
        correlation_header: correlation,
        chunks: chunks,
        before_chunk: -> { clock.advance(11) },
      ),
    )

    expect do
      described_class.new(@peer, monotonic_clock: clock).claim(correlation_id: correlation)
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
    expect(http.read_timeouts.first).to eq(described_class::RESPONSE_TIMEOUT_SECONDS)
    expect(http.read_timeouts).to include(8.0)
  end

  it "interrupts a progressing header wait that never yields a response body" do
    http = HeaderProgressHTTP.new
    elapsed = nil
    stub_const(described_class, :HTTP_EXCHANGE_TIMEOUT_SECONDS, 0.02) do
      FinalDestination::HTTP.stubs(:start).yields(http)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        described_class.new(@peer).claim(correlation_id: "network-header-timeout")
      end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    end

    expect(elapsed).to be < 1
    expect(http.iterations).to be_positive
    expect(http.request_finished).to eq(true)
  end

  it "interrupts connection setup before the HTTP session yields" do
    BlockingStartHTTP.reset!
    elapsed = nil
    stub_const(described_class, :HTTP_EXCHANGE_TIMEOUT_SECONDS, 0.02) do
      stub_const(FinalDestination, :HTTP, BlockingStartHTTP) do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect do
          described_class.new(@peer).claim(correlation_id: "network-connect-timeout")
        end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      end
    end

    expect(elapsed).to be < 1
    expect(BlockingStartHTTP.iterations).to be_positive
  end

  it "does not open an exchange when the shared work-cycle allowance is exhausted" do
    clock = NetworkMonotonicClock.new
    client = described_class.new(@peer, monotonic_clock: clock)
    client.start_work_cycle!
    clock.advance(described_class::WORK_CYCLE_TIMEOUT_SECONDS)
    FinalDestination::HTTP.expects(:start).never

    expect do
      client.claim(correlation_id: "network-zero-remaining")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
  ensure
    client&.finish_work_cycle!
  end

  it "accepts a complete exchange immediately before its total deadline" do
    clock = NetworkMonotonicClock.new
    correlation = "network-before-deadline"
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: {
          "publication_work" => [],
          "claimed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => correlation,
        },
        before_chunk: -> { clock.advance(described_class::HTTP_EXCHANGE_TIMEOUT_SECONDS - 0.001) },
      ),
    )

    expect(
      described_class.new(@peer, monotonic_clock: clock).claim(correlation_id: correlation),
    ).to eq([])
  end

  it "reassembles and verifies exact bounded chunk responses" do
    detail = fixture_detail
    detail["correlation_id"] = "network-source-1234"
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

  it "bounds individually timely chunk exchanges by one cumulative transfer deadline" do
    clock = NetworkMonotonicClock.new
    detail = fixture_detail
    correlation = "network-cumulative-chunks"
    detail["correlation_id"] = correlation
    chunks = Array.new(24) { |index| (index.to_s * DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES).byteslice(0, DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES) }
    content = chunks.join
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content),
      "chunk_count" => chunks.length,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    responses = [
      NetworkClientResponse.new(
        code: 200,
        payload: detail,
        before_chunk: -> { clock.advance(10) },
      ),
    ]
    chunks.each_with_index do |chunk, index|
      responses << NetworkClientResponse.new(
        code: 200,
        before_chunk: -> { clock.advance(10) },
        payload: {
          "source_revision" => detail.fetch("source_revision"),
          "chunk" => index + 1,
          "chunk_count" => chunks.length,
          "decoded_bytes" => chunk.bytesize,
          "chunk_sha256" => Digest::SHA256.hexdigest(chunk),
          "content_base64" => Base64.strict_encode64(chunk),
          "correlation_id" => correlation,
        },
      )
    end
    http = use_http(*responses)

    expect do
      described_class.new(@peer, monotonic_clock: clock).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
    expect(http.requests.length).to eq(24)
    expect(http.requests.last.path).to end_with("chunk=23")
  end

  it "rejects a successful peer response whose matching header and body identify another request" do
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: {
          "publication_work" => [],
          "claimed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => "different-request",
        },
      ),
    )

    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-1234")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
  end

  it "requires a valid response correlation header matching the request and body" do
    [nil, "", "different-request", "invalid\ncorrelation", "x" * 201].each do |response_correlation|
      use_http(
        NetworkClientResponse.new(
          code: 200,
          correlation_header: response_correlation,
          payload: {
            "publication_work" => [],
            "claimed_at" => Time.zone.now.iso8601(6),
            "correlation_id" => "network-claim-1234",
          },
        ),
      )

      expect do
        described_class.new(@peer).claim(correlation_id: "network-claim-1234")
      end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
    end
  end

  it "rejects a wrong body correlation even when the response header matches the request" do
    use_http(
      NetworkClientResponse.new(
        code: 200,
        correlation_header: "network-claim-1234",
        payload: {
          "publication_work" => [],
          "claimed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => "different-request",
        },
      ),
    )

    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-1234")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
  end

  it "accepts the maximum valid correlation identity without value normalization" do
    correlation = "A" * DiscussionBridge::AdapterRequestBoundary::MAX_CORRELATION_BYTES
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: {
          "publication_work" => [],
          "claimed_at" => Time.zone.now.iso8601(6),
          "correlation_id" => correlation,
        },
      ),
    )

    expect(described_class.new(@peer).claim(correlation_id: correlation)).to eq([])
  end

  it "validates the response correlation header before accepting a peer error" do
    payload = {
      "error_code" => "revision_conflict",
      "message" => "The request conflicts with the authoritative source revision.",
      "correlation_id" => "network-error-1234",
    }
    use_http(NetworkClientResponse.new(code: 409, payload: payload))
    expect do
      described_class.new(@peer).claim(correlation_id: "network-error-1234")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("revision_conflict") }

    [nil, "", "different-request", "invalid\ncorrelation", "x" * 201].each do |response_correlation|
      use_http(
        NetworkClientResponse.new(
          code: 409,
          payload: payload,
          correlation_header: response_correlation,
        ),
      )
      expect do
        described_class.new(@peer).claim(correlation_id: "network-error-1234")
      end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
    end

    use_http(
      NetworkClientResponse.new(
        code: 409,
        payload: payload.merge("correlation_id" => "different-request"),
        correlation_header: "network-error-1234",
      ),
    )
    expect do
      described_class.new(@peer).claim(correlation_id: "network-error-1234")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
  end

  it "rejects a mismatched correlation header on a failure-report response" do
    correlation = "network-failure-1234"
    use_http(
      NetworkClientResponse.new(
        code: 200,
        correlation_header: "different-request",
        payload: {
          "resulting_state" => "operator_attention",
          "terminal" => true,
          "correlation_id" => correlation,
        },
      ),
    )

    expect do
      described_class.new(@peer).fail(
        work: {
          "work_id" => "dbw_#{"1" * 32}",
          "lease_token" => "2" * 64,
        },
        error_code: "validation_failed",
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
  end

  it "gives failure reporting one fresh bounded deadline after the ordinary cycle expires" do
    correlation = "network-failure-deadline"
    work = {
      "work_id" => "dbw_#{"1" * 32}",
      "lease_token" => "2" * 64,
    }
    payload = {
      "resulting_state" => "retry_wait",
      "terminal" => false,
      "correlation_id" => correlation,
    }

    before_deadline_clock = NetworkMonotonicClock.new
    before_deadline_client = described_class.new(@peer, monotonic_clock: before_deadline_clock)
    before_deadline_client.start_work_cycle!
    before_deadline_clock.advance(described_class::WORK_CYCLE_TIMEOUT_SECONDS)
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: payload,
        before_chunk: -> { before_deadline_clock.advance(described_class::FAILURE_REPORT_TIMEOUT_SECONDS - 0.001) },
      ),
    )
    expect(
      before_deadline_client.fail(
        work: work,
        error_code: "transport_timeout",
        correlation_id: correlation,
      ),
    ).to eq(payload)

    expired_clock = NetworkMonotonicClock.new
    expired_client = described_class.new(@peer, monotonic_clock: expired_clock)
    expired_client.start_work_cycle!
    expired_clock.advance(described_class::WORK_CYCLE_TIMEOUT_SECONDS)
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: payload,
        before_chunk: -> { expired_clock.advance(described_class::FAILURE_REPORT_TIMEOUT_SECONDS) },
      ),
    )
    expect do
      expired_client.fail(
        work: work,
        error_code: "transport_timeout",
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("transport_timeout") }
  ensure
    before_deadline_client&.finish_work_cycle!
    expired_client&.finish_work_cycle!
  end

  it "fails closed on an oversized or non-JSON peer response" do
    oversized = use_http(
      NetworkClientResponse.new(code: 200, payload: "{" + ("x" * 65_536)),
    )
    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-oversized")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("request_too_large") }
    expect(oversized.requests.length).to eq(1)

    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: "ok",
        content_type: "text/plain",
      ),
    )
    expect do
      described_class.new(@peer).claim(correlation_id: "network-claim-not-json")
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("destination_unavailable") }
  end

  it "applies the exact error-envelope byte limit before parsing streamed peer detail" do
    correlation = "network-source-error-limit"
    detail = fixture_detail
    error_body = lambda do |maximum_bytes|
      payload = {
        "error_code" => "temporarily_unavailable",
        "message" => "PRIVATE_PEER_DETAIL",
        "correlation_id" => correlation,
      }
      padding = maximum_bytes - JSON.generate(payload).bytesize
      raise "error-envelope fixture exceeds requested size" if padding.negative?

      payload["message"] += "€"
      payload["message"] += "x" * (padding - "€".bytesize)
      JSON.generate(payload).tap do |body|
        raise "incorrect error-envelope fixture size" unless body.bytesize == maximum_bytes
      end
    end

    accepted_error = error_body.call(DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES)
    use_http(
      NetworkClientResponse.new(
        code: 503,
        payload: accepted_error,
        correlation_header: correlation,
        chunks: [accepted_error.byteslice(0, 2_047), accepted_error.byteslice(2_047..)],
      ),
    )
    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) do |error|
      expect(error.error_code).to eq("temporarily_unavailable")
      expect(error.message).not_to include("PRIVATE_PEER_DETAIL")
    end

    rejected_error = error_body.call(DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES + 1)
    observed_chunks = 0
    use_http(
      NetworkClientResponse.new(
        code: 503,
        payload: rejected_error,
        correlation_header: correlation,
        content_length: "1",
        chunks: [
          rejected_error.byteslice(0, DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES),
          rejected_error.byteslice(DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES, 1),
          "unread-sentinel",
        ],
        before_chunk: -> { observed_chunks += 1 },
      ),
    )
    @peer.stubs(:remote_secret).returns("s" * 32)
    JSON.expects(:parse).with(rejected_error).never
    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) do |error|
      expect(error.error_code).to eq("request_too_large")
      expect(error.message).not_to include("PRIVATE_PEER_DETAIL")
    end
    expect(observed_chunks).to eq(2)
  end

  it "preserves the exact source-detail success-response limit" do
    correlation = "network-source-success-limit"
    detail = fixture_detail
    detail["correlation_id"] = correlation
    success_body = JSON.generate(detail).ljust(
      described_class::SOURCE_DETAIL_MAXIMUM_BYTES,
      " ",
    )
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: success_body,
        correlation_header: correlation,
        chunks: [
          success_body.byteslice(0, DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES),
          success_body.byteslice(DiscussionBridge::AdapterRequestBoundary::MAX_ERROR_JSON_BYTES..),
        ],
      ),
    )
    payload, content = described_class.new(@peer).source_detail(
      topic_id: detail.fetch("topic_id"),
      source_revision: detail.fetch("source_revision"),
      correlation_id: correlation,
    )
    expect(payload).to eq(detail)
    expect(content).to be_nil

    oversized_success = success_body + " "
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: oversized_success,
        correlation_header: correlation,
        chunks: [success_body, " "],
      ),
    )
    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) do |error|
      expect(error.error_code).to eq("request_too_large")
    end
  end

  it "preserves the exact default success-response limit" do
    correlation = "network-claim-success-limit"
    payload = {
      "publication_work" => [],
      "claimed_at" => Time.zone.now.iso8601(6),
      "correlation_id" => correlation,
    }
    success_body = JSON.generate(payload).ljust(described_class::JSON_MAXIMUM_BYTES, " ")
    expect(success_body.bytesize).to eq(described_class::JSON_MAXIMUM_BYTES)
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: success_body,
        correlation_header: correlation,
      ),
    )
    expect(described_class.new(@peer).claim(correlation_id: correlation)).to eq([])

    oversized_success = success_body + " "
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: oversized_success,
        correlation_header: correlation,
        chunks: [success_body, " "],
      ),
    )
    expect do
      described_class.new(@peer).claim(correlation_id: correlation)
    end.to raise_error(described_class::Error) do |error|
      expect(error.error_code).to eq("request_too_large")
    end
  end

  it "preserves the exact chunk success-response limit and rejects before decoding overflow" do
    correlation = "network-chunk-success-limit"
    detail = fixture_detail
    detail["correlation_id"] = correlation
    content = "a" * (DiscussionBridge::SourcePublicationProtocol::INLINE_MAXIMUM_BYTES + 1)
    content_chunks = content.bytes.each_slice(DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES)
      .map { |bytes| bytes.pack("C*") }
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content),
      "chunk_count" => content_chunks.length,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    chunk_payloads = content_chunks.each_with_index.map do |chunk, index|
      {
        "source_revision" => detail.fetch("source_revision"),
        "chunk" => index + 1,
        "chunk_count" => content_chunks.length,
        "decoded_bytes" => chunk.bytesize,
        "chunk_sha256" => Digest::SHA256.hexdigest(chunk),
        "content_base64" => Base64.strict_encode64(chunk),
        "correlation_id" => correlation,
      }
    end
    exact_chunk_body = JSON.generate(chunk_payloads.first).ljust(
      described_class::CONTENT_CHUNK_MAXIMUM_BYTES,
      " ",
    )
    expect(exact_chunk_body.bytesize).to eq(described_class::CONTENT_CHUNK_MAXIMUM_BYTES)
    http = use_http(
      NetworkClientResponse.new(code: 200, payload: detail),
      NetworkClientResponse.new(
        code: 200,
        payload: exact_chunk_body,
        correlation_header: correlation,
      ),
      NetworkClientResponse.new(code: 200, payload: chunk_payloads.second),
    )
    _, materialized = described_class.new(@peer).source_detail(
      topic_id: detail.fetch("topic_id"),
      source_revision: detail.fetch("source_revision"),
      correlation_id: correlation,
    )
    expect(materialized).to eq(content)
    expect(http.requests.length).to eq(3)

    oversized_chunk_body = exact_chunk_body + " "
    http = use_http(
      NetworkClientResponse.new(code: 200, payload: detail),
      NetworkClientResponse.new(
        code: 200,
        payload: oversized_chunk_body,
        correlation_header: correlation,
        chunks: [exact_chunk_body, " "],
      ),
      NetworkClientResponse.new(code: 200, payload: chunk_payloads.second),
    )
    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) do |error|
      expect(error.error_code).to eq("request_too_large")
    end
    expect(http.requests.length).to eq(2)
  end

  it "rejects a malformed chunk relationship before requesting content" do
    detail = fixture_detail
    detail["correlation_id"] = "network-source-malformed"
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => (DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES * 2) + 1,
      "sha256" => "a" * 64,
      "chunk_count" => 2,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    http = use_http(NetworkClientResponse.new(code: 200, payload: detail))

    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: "network-source-malformed",
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
    expect(http.requests.length).to eq(1)
  end

  it "rejects a chunk whose response correlation header does not match" do
    detail = fixture_detail
    correlation = "network-source-header"
    detail["correlation_id"] = correlation
    content = "n" * (DiscussionBridge::SourcePublicationProtocol::INLINE_MAXIMUM_BYTES + 1)
    first_chunk = content.byteslice(0, DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES)
    detail["content_transport"] = {
      "mode" => "chunked",
      "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
      "byte_length" => content.bytesize,
      "sha256" => Digest::SHA256.hexdigest(content),
      "chunk_count" => 2,
      "decoded_chunk_maximum_bytes" => DiscussionBridge::SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES,
    }
    http = use_http(
      NetworkClientResponse.new(code: 200, payload: detail),
      NetworkClientResponse.new(
        code: 200,
        correlation_header: "different-request",
        payload: {
          "source_revision" => detail.fetch("source_revision"),
          "chunk" => 1,
          "chunk_count" => 2,
          "decoded_bytes" => first_chunk.bytesize,
          "chunk_sha256" => Digest::SHA256.hexdigest(first_chunk),
          "content_base64" => Base64.strict_encode64(first_chunk),
          "correlation_id" => correlation,
        },
      ),
    )

    expect do
      described_class.new(@peer).source_detail(
        topic_id: detail.fetch("topic_id"),
        source_revision: detail.fetch("source_revision"),
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
    expect(http.requests.length).to eq(2)
  end

  it "accepts only the exact terminal acknowledgement relationship" do
    work = {
      "work_id" => "dbw_#{"1" * 32}",
      "resource_id" => "dbr_#{"2" * 32}",
      "source_revision" => "remote:revision:1",
      "source_revision_sequence" => 1,
      "policy_revision" => "policy:network:1",
      "destination_policy_id" => "destination:network:1",
      "action" => "publish",
      "lease_token" => "3" * 64,
      "stage_token" => "4" * 64,
    }
    binding = {
      binding_id: "dbb_#{"5" * 32}",
      external_id: "remote-page",
      canonical_url: "https://national.example/remote-page",
      publication_revision: "post:1:version:1",
      content_disposition: "complete",
    }
    correlation = "network-ack-exact"
    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: {
          "work_id" => work.fetch("work_id"),
          "accepted_stage" => "synchronized",
          "resulting_state" => "acknowledged",
          "terminal" => true,
          "correlation_id" => correlation,
        },
      ),
    )
    expect(
      described_class.new(@peer).acknowledge(
        work: work,
        destination_binding: binding,
        correlation_id: correlation,
      ),
    ).to include("terminal" => true)

    use_http(
      NetworkClientResponse.new(
        code: 200,
        payload: {
          "work_id" => "dbw_#{"9" * 32}",
          "accepted_stage" => "synchronized",
          "resulting_state" => "acknowledged",
          "terminal" => true,
          "correlation_id" => correlation,
        },
      ),
    )
    expect do
      described_class.new(@peer).acknowledge(
        work: work,
        destination_binding: binding,
        correlation_id: correlation,
      )
    end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("validation_failed") }
  end

  it "rejects invalid UTF-8 and decoded chunks above the advertised maximum" do
    [
      {
        content: (("a" * 65_536).b + "\xFF".b).force_encoding(Encoding::UTF_8),
        lengths: [32_768, 32_768, 1],
      },
      { content: ("a" * 65_537).b, lengths: [32_769, 32_767, 1] },
    ].each do |test_case|
      detail = fixture_detail
      correlation = "network-invalid-chunk-#{test_case.fetch(:lengths).first}"
      detail["correlation_id"] = correlation
      offset = 0
      chunks = test_case.fetch(:lengths).map do |length|
        value = test_case.fetch(:content).byteslice(offset, length)
        offset += length
        value
      end
      detail["content_transport"] = {
        "mode" => "chunked",
        "media_type" => DiscussionBridge::SourcePublicationProtocol::MEDIA_TYPE,
        "byte_length" => test_case.fetch(:content).bytesize,
        "sha256" => Digest::SHA256.hexdigest(test_case.fetch(:content)),
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
            "correlation_id" => correlation,
          },
        )
      end
      use_http(*responses)
      expect do
        described_class.new(@peer).source_detail(
          topic_id: detail.fetch("topic_id"),
          source_revision: detail.fetch("source_revision"),
          correlation_id: correlation,
        )
      end.to raise_error(described_class::Error) { |error| expect(error.error_code).to eq("integrity_failed") }
    end
  end

  it "accepts valid UTF-8 whose multibyte sequence crosses a chunk boundary" do
    content = (("a" * 32_767).b + "€".b + ("b" * 20_000).b).force_encoding(Encoding::UTF_8)
    chunks = [
      content.byteslice(0, 32_768),
      content.byteslice(32_768, content.bytesize - 32_768),
    ]
    detail = fixture_detail
    correlation = "network-valid-split-utf8"
    detail["correlation_id"] = correlation
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
          "correlation_id" => correlation,
        },
      )
    end
    use_http(*responses)

    _, received = described_class.new(@peer).source_detail(
      topic_id: detail.fetch("topic_id"),
      source_revision: detail.fetch("source_revision"),
      correlation_id: correlation,
    )
    expect(received).to eq(content)
    expect(received).to be_valid_encoding
  end
end
