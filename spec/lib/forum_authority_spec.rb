# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ForumAuthority do
  fab!(:actor, :admin)
  fab!(:category)
  fab!(:allowed_tag) { Fabricate(:tag, name: "bridge-alpha") }

  it "returns the forum-owned category and tags after Guardian authorization" do
    result = described_class.call(
      actor: actor,
      category_id: category.id,
      tags: "bridge-alpha|bridge-alpha",
    )

    expect(result.allowed?).to eq(true)
    expect(result.category_id).to eq(category.id)
    expect(result.tags).to eq(["bridge-alpha"])
  end

  it "rejects a missing category before topic creation" do
    result = described_class.call(actor: actor, category_id: -1, tags: [])

    expect(result.allowed?).to eq(false)
    expect(result.reason).to eq("category_unavailable")
  end

  it "rejects a requested tag that the forum has not defined" do
    result = described_class.call(actor: actor, category_id: category.id, tags: ["not-a-forum-tag"])

    expect(result.allowed?).to eq(false)
    expect(result.reason).to eq("tag_unavailable")
  end
end
