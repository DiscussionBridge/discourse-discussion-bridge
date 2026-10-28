# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ForumName do
  around do |example|
    original = ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME")
    example.run
  ensure
    original.nil? ?
      ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME") :
      ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = original
  end

  it "accepts the UTF8 byte boundary and preserves descriptive text" do
    label = "é" * 100
    expect(described_class.validate!(label)).to eq(label)
    expect(described_class.validate!("  A forum — café <name>  ")).to eq(
      "  A forum — café <name>  ",
    )
    binary = label.b
    expect(described_class.validate!(binary).encoding).to eq(Encoding::UTF_8)
  end

  it "rejects blank, invalid UTF8, oversized and control-containing raw labels" do
    invalid = [
      nil,
      12,
      "",
      " ",
      "\u00a0",
      "\u2003",
      "é" * 101,
      "\xff".b,
      "\nForum",
      "Forum\t",
      "Forum\u007f",
      "Forum\u0085",
      "\u0000",
    ]
    invalid.each do |label|
      expect { described_class.validate!(label) }.to raise_error(described_class::Invalid)
    end
  end

  it "fails closed for an explicit blank or invalid server override" do
    SiteSetting.title = "Native forum"
    ["", " ", "\u00a0", "\nForum", "Forum\u0085", "é" * 101].each do |label|
      ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = label
      expect { DiscussionBridge::CmsConfiguration.forum_name! }.to raise_error(
        DiscussionBridge::CmsProtocol::Error,
      ) { |error| expect(error.code).to eq("forum_configuration_invalid") }
    end
  end

  it "uses the native title or exact valid server override" do
    SiteSetting.title = "Native forum"
    expect(DiscussionBridge::CmsConfiguration.forum_name!).to eq("Native forum")
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "  Server forum — café  "
    expect(DiscussionBridge::CmsConfiguration.forum_name!).to eq("  Server forum — café  ")
    ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME")
    expect(DiscussionBridge::CmsConfiguration.forum_name!).to eq("Native forum")
  end

  it "fails closed when the selected native title is invalid" do
    allow(SiteSetting).to receive(:title).and_return("Forum\u0085")
    expect { DiscussionBridge::CmsConfiguration.forum_name! }.to raise_error(
      DiscussionBridge::CmsProtocol::Error,
    ) { |error| expect(error.code).to eq("forum_configuration_invalid") }
  end

end

