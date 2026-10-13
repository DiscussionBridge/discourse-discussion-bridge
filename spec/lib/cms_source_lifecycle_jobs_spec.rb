# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscussionBridgeCmsSourceBatch do
  it "dispatches only the stored connection identity to bounded receiver work" do
    expect(DiscussionBridge::CmsSourceLifecycle).to receive(:run_batch).with(
      "42"
    )
    described_class.new.execute(connection_id: "42")
  end

  it "reloads the current connection before dispatching one native topic identity" do
    connection = instance_double(DiscussionBridgeContentConnection)
    expect(DiscussionBridgeContentConnection).to receive(:find_by).with(
      id: 42
    ).and_return(connection)
    expect(DiscussionBridge::CmsSourceLifecycle).to receive(:refresh).with(
      connection,
      "9223372036854775807"
    )
    described_class.new.execute(
      connection_id: "42",
      topic_id: "9223372036854775807"
    )
  end

  it "does not dispatch a disappeared connection or unrepresentable identifier" do
    allow(DiscussionBridgeContentConnection).to receive(:find_by).with(
      id: 42
    ).and_return(nil)
    expect(DiscussionBridge::CmsSourceLifecycle).not_to receive(:refresh)
    described_class.new.execute(connection_id: "42", topic_id: "1")
    expect {
      described_class.new.execute(connection_id: 42.5, topic_id: "1")
    }.to raise_error(ArgumentError)
    expect {
      described_class.new.execute(connection_id: "042", topic_id: "1")
    }.to raise_error(ArgumentError)
  end

  it "uses durable maintenance rather than an unlimited sidekiq exception retry" do
    expect(described_class.get_sidekiq_options.fetch("retry")).to eq(false)
  end
end

describe Jobs::DiscussionBridgeCmsLifecycleMaintenance do
  it "delegates to current receiver scope checks without creating source through a read" do
    expect(DiscussionBridge::CmsSourceLifecycle).to receive(:maintenance)
    described_class.new.execute({})
    expect(described_class.get_sidekiq_options.fetch("retry")).to eq(false)
  end
end
