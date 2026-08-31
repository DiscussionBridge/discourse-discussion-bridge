# frozen_string_literal: true

describe DiscussionBridgeContentConnection do
  it "supports every settled platform type and multiple installations of one type" do
    created = described_class::PLATFORMS.each_with_index.map do |platform, index|
      connection, secret = described_class.issue!(
        name: "#{platform} #{index + 1}",
        platform: platform,
        allowed_origins: ["https://#{platform}.example"],
        allowed_directions: described_class::DIRECTIONS,
        allowed_lanes: [],
      )
      expect(secret.bytesize).to be_between(32, 256)
      expect(connection.generate_topic_toc).to eq(false)
      connection
    end
    second_wordpress, = described_class.issue!(
      name: "wordpress 2",
      platform: "wordpress",
      allowed_origins: ["https://second-wordpress.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: [],
    )

    expect(created.map(&:platform)).to contain_exactly(*described_class::PLATFORMS)
    expect(second_wordpress.platform).to eq("wordpress")
    second_wordpress.update!(generate_topic_toc: true)
    expect(second_wordpress.reload.generate_topic_toc).to eq(true)
  end

  it "keeps credentials independent and rejects malformed scope" do
    first, first_secret = described_class.issue!(
      name: "First",
      platform: "ghost",
      allowed_origins: ["https://first.example"],
      allowed_directions: ["to_discourse"],
      allowed_lanes: ["news"],
    )
    second, second_secret = described_class.issue!(
      name: "Second",
      platform: "ghost",
      allowed_origins: ["https://second.example"],
      allowed_directions: ["from_discourse"],
      allowed_lanes: [],
    )

    expect(first.authenticate_secret?(first_secret)).to eq(true)
    expect(first.authenticate_secret?(second_secret)).to eq(false)
    expect(second.authenticate_secret?(first_secret)).to eq(false)
    expect(first).to allow_value(["https://first.example"]).for(:allowed_origins)
    expect(first).not_to allow_value(["https://first.example/path/"]).for(:allowed_origins)
    expect(first).not_to allow_value([]).for(:allowed_origins)
    expect(first).not_to allow_value(
      (1..(described_class::MAX_ORIGINS + 1)).map { |index| "https://origin-#{index}.example" },
    ).for(:allowed_origins)
    expect(first).not_to allow_value(%w[to_discourse unknown]).for(:allowed_directions)
  end
end
