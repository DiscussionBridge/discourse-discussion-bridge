# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridge::CmsProtocol do
  let(:vectors) do
    JSON.parse(
      File.binread(
        File.expand_path("../fixtures/v4/url-domain-policy.json", __dir__)
      )
    )
  end

  it "applies the fixed policy in the actual loaded receiver without replacing URL bytes" do
    vectors
      .fetch("cases")
      .each do |item|
        value = item.fetch("url").dup
        original = value.b.dup
        if item.fetch("accepted")
          expect(described_class.validate!("Url", value)).to equal(value)
          expect(described_class.url_authority(value).facts).to eq(
            item.fetch("facts")
          )
        else
          expect { described_class.validate!("Url", value) }.to raise_error(
            described_class::Error
          ) { |error| expect(error.code).to eq("invalid_field") }
        end
        expect(value.b).to eq(original)
      end
  end

  it "retains every prior ASCII key including escaped hosts, paths, queries and IP spellings" do
    vectors
      .fetch("legacyAsciiKeys")
      .each do |item|
        expect(described_class.url_key(item.fetch("url"))).to eq(
          item.fetch("expected")
        )
      end
    expect(
      described_class.url_key("https://site.example/A%2Fb?Q=%2F&Q=x")
    ).not_to eq(described_class.url_key("https://site.example/A%2fb?Q=%2F&Q=x"))
  end

  it "rejects oversize direct native helper inputs as well as typed values" do
    value = "https://site.example/" + "a" * 2048
    expect { described_class.url_authority(value) }.to raise_error(
      described_class::Error
    )
    expect { described_class.url_key(value) }.to raise_error(
      described_class::Error
    )
  end

  it "accepts slashless international connection origins but not paths or queries" do
    connection =
      JSON
        .parse(
          File.binread(
            File.expand_path("../fixtures/v4/positive-examples.json", __dir__)
          )
        )
        .fetch("fixtures")
        .find { |item| item.fetch("type") == "Connection" }
        .fetch("value")
    %w[https://é.example https://xn--9ca.example/].each do |url|
      expect(
        described_class.validate!(
          "Connection",
          connection.merge("destination_origin" => url)
        ).fetch("destination_origin")
      ).to eq(url)
    end
    %w[
      https://é.example/article
      https://é.example/?
      https://xn--ggboa426xba.example/
    ].each do |url|
      expect {
        described_class.validate!(
          "Connection",
          connection.merge("destination_origin" => url)
        )
      }.to raise_error(described_class::Error)
    end
  end

  it "leaves the narrower native source eligibility boundary unchanged" do
    %w[
      https://é.example/
      https://%65xample.test/
      https://127.1/
      https://source.example/?q=1
      https://source.example/A%2Fb
    ].each do |url|
      expect(described_class.validate!("Url", url)).to eq(url)
      expect {
        DiscussionBridge::CanonicalSource.call(
          connection_id: "native",
          source_url: url
        )
      }.to raise_error(ArgumentError)
    end
    value = "https://source.example/retained/"
    result =
      DiscussionBridge::CanonicalSource.call(
        connection_id: "native",
        source_url: value
      )
    expect(result.source_url).to eq(value)
    expect(result.identity_digest).to eq(
      Digest::SHA256.hexdigest("native\n#{value}")
    )
  end
end

RSpec.describe DiscussionBridge::CmsUrlReservation do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: admin, post_number: 1)
  end

  before do
    allow(DiscussionBridge::CmsSourceLifecycle).to receive(
      :wake_connection
    ).and_return(false)
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_endpoint_enabled = true
    SiteSetting.discussion_bridge_publisher_enabled = true
    SiteSetting.force_https = true
    @connection, =
      DiscussionBridgeContentConnection.issue!(
        name: "URL native policy",
        platform: "ghost",
        allowed_origins: ["https://xn--9ca.example"],
        allowed_directions: ["from_discourse"],
        allowed_lanes: ["news"]
      )
    @config = {
      "profile" => "ghost",
      "destination_origin" => "https://é.example",
      "publication_lane" => "news",
      "native_capabilities" => {
        "native_revision" => "native:url",
        "supported_presentations" => ["simple"],
        "publication_kind" => "dynamic",
        "complete_content_supported" => true
      },
      "policy" => {
        "policy_revision" => SecureRandom.uuid,
        "enabled" => true,
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
    @connection.update!(cms_configuration: @config)
  end

  def publish(url, external_id: "article", source_topic: topic)
    result =
      DiscussionBridge::FromDiscourseRecordCreator.call(
        user: admin,
        connection_id: @connection.id,
        topic_id: source_topic.id,
        external_id: external_id,
        canonical_url: url
      )
    DiscussionBridgeCmsMapping.find_by!(
      content_binding_id: result.record.active_binding("presentation").id
    )
  end

  it "requires explicit current scope even when a domain is valid or equivalent" do
    config_before = @config.deep_dup
    expect(
      DiscussionBridge::CmsConfiguration.validate!(@connection, @config)
    ).to eq(config_before)
    %w[
      https://é.example/A%2Fb?Q=%2F
      https://xn--9ca.example/article
      https://%C3%A9.example/article
    ].each do |url|
      expect(
        DiscussionBridge::CmsConfiguration.destination_url!(
          @connection,
          @config,
          url
        )
      ).to eq(url)
    end
    %w[
      https://other.example/article
      https://é.example:444/article
    ].each do |url|
      expect {
        DiscussionBridge::CmsConfiguration.destination_url!(
          @connection,
          @config,
          url
        )
      }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
        expect(error.code).to eq("scope_denied")
      }
    end
    @connection.update!(allowed_origins: ["https://other.example"])
    expect {
      DiscussionBridge::CmsConfiguration.validate!(@connection, @config)
    }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq("scope_denied")
    }
    expect(@config).to eq(config_before)
  end

  it "retains one native mapping, original URL, digest and topic across exact retries and reloads" do
    url = "https://%C3%A9.example/Original%2F?Q=%2F&Q=x"
    mapping = publish(url)
    binding = mapping.content_binding
    reservation =
      DiscussionBridgeCmsUrlReservation.find_by!(cms_mapping_id: mapping.id)
    before = [
      mapping.mapping_id,
      binding.attributes,
      reservation.attributes,
      topic.id,
      first_post.id,
      DiscussionBridgeCmsMutationReceipt.order(:id).pluck(
        :id,
        :request_tree,
        :response_body
      )
    ]
    expect(reservation.collision_key_sha256).to eq(
      Digest::SHA256.hexdigest("https://%c3%a9.example/Original%2F?Q=%2F&Q=x")
    )
    expect(publish(url).id).to eq(mapping.id)
    expect(
      [
        mapping.reload.mapping_id,
        binding.reload.attributes,
        reservation.reload.attributes,
        topic.id,
        first_post.id,
        DiscussionBridgeCmsMutationReceipt
          .order(:id)
          .limit(before.last.length)
          .pluck(:id, :request_tree, :response_body)
      ]
    ).to eq(before)
    expect(DiscussionBridgeBridgeRecord.count).to eq(1)
    expect(DiscussionBridgeCmsMapping.count).to eq(1)
  end

  it "rejects an equivalent spelling reserved by another native publication without creating new rows" do
    mapping = publish("https://é.example/article/")
    other = Fabricate(:topic, user: admin)
    Fabricate(:post, topic: other, user: admin, post_number: 1)
    before = [
      DiscussionBridgeBridgeRecord.count,
      DiscussionBridgeContentBinding.count,
      DiscussionBridgeCmsMapping.count,
      DiscussionBridgeCmsUrlReservation.count
    ]
    expect {
      publish(
        "https://xn--9ca.example/article/",
        external_id: "other",
        source_topic: other
      )
    }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
      expect(error.code).to eq("url_collision")
    }
    expect(
      [
        DiscussionBridgeBridgeRecord.count,
        DiscussionBridgeContentBinding.count,
        DiscussionBridgeCmsMapping.count,
        DiscussionBridgeCmsUrlReservation.count
      ]
    ).to eq(before)
    expect(mapping.reload.content_binding.canonical_url).to eq(
      "https://é.example/article/"
    )
  end

  it "protects prepared and retired alias reservations that are not the current binding URL" do
    mapping = publish("https://xn--9ca.example/current/")
    %w[prepared retired].each do |state|
      url = "https://%C3%A9.example/#{state}/"
      row =
        DiscussionBridgeCmsUrlReservation.create!(
          cms_mapping: mapping,
          canonical_url: url,
          collision_key_sha256: described_class.collision_digest(url),
          state: state
        )
      before = row.attributes
      expect {
        described_class.with_locks(["https://é.example/#{state}/"]) do
          described_class.new.send(
            :reject_binding_collision!,
            described_class.collision_key("https://é.example/#{state}/"),
            allowed_binding_id: nil
          )
        end
      }.to raise_error(DiscussionBridge::CmsProtocol::Error) { |error|
        expect(error.code).to eq("url_collision")
      }
      expect(row.reload.attributes).to eq(before)
    end
  end

  it "takes the existing lock and a shared alias lock without changing the old key" do
    url = "https://%C3%A9.example/article/"
    old = described_class.collision_key(url)
    comparison = DiscussionBridge::CmsProtocol.url_authority(url).comparison_key
    locks = []
    allow(DB).to receive(:exec).and_wrap_original do |original, sql, **args|
      locks << args.fetch(:key) if sql.include?("pg_advisory_xact_lock")
      original.call(sql, **args)
    end
    described_class.with_locks([url]) do
      expect(DiscussionBridgeCmsUrlReservation.count).to eq(0)
      key =
        Digest::SHA256.hexdigest("discussionbridge-cms-url-1\n#{comparison}")[
          0,
          16
        ].to_i(16)
      key -= 1 << 64 if key >= 1 << 63
      # Core's transactional-fixture pool shares its connection across threads.
      # Use a separate libpq connection instead of deadlocking that pool.
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      database =
        PG.connect(
          {
            dbname: config.fetch(:database),
            host: config[:host],
            port: config[:port],
            user: config[:username],
            password: config[:password],
            connect_timeout: 3
          }.compact
        )
      begin
        database.exec("SET statement_timeout = 3000")
        expect(
          database.exec_params(
            "SELECT pg_try_advisory_xact_lock($1::bigint)",
            [key]
          ).getvalue(0, 0)
        ).to eq("f")
      ensure
        database.close
      end
    end
    expected =
      [old, comparison].uniq.sort.map do |key|
        unsigned =
          Digest::SHA256.hexdigest("discussionbridge-cms-url-1\n#{key}")[
            0,
            16
          ].to_i(16)
        unsigned >= (1 << 63) ? unsigned - (1 << 64) : unsigned
      end
    expect(locks).to eq(expected)
    expect(described_class.collision_key(url)).to eq(old)
    expect(comparison).to eq(
      DiscussionBridge::CmsProtocol.url_authority(
        "https://é.example/article/"
      ).comparison_key
    )
  end
end
