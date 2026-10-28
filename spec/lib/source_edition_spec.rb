# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::SourceEdition do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  it "requires a readable live native first post" do
    expect(described_class.publicly_available?(topic)).to eq(true)
    first_post.update!(deleted_at: Time.current)
    expect(described_class.publicly_available?(topic.reload)).to eq(false)
  end
  it "does not publish a shared draft even when its native category is publicly readable" do
    SharedDraft.create!(topic_id: topic.id, category_id: topic.category_id)
    expect(described_class.publicly_available?(topic)).to eq(false)
  end

  it "does not export a first post denied by native anonymous moderation permissions" do
    SiteSetting.hidden_post_visible_groups = Group::AUTO_GROUPS[:staff].to_s
    first_post.hide!(PostActionType.types[:spam])
    topic.reload
    first_post.reload
    expect(Guardian.new(nil).can_see?(topic)).to eq(true)
    expect(Guardian.new(nil).can_see?(first_post)).to eq(false)
    expect(described_class.publicly_available?(topic)).to eq(false)
  end

  it "does not republish a native Core imported first post, including retained embed ancestry" do
    embed =
      TopicEmbed.create!(
        topic: topic,
        post: first_post,
        embed_url: "https://source.example/article/",
      )
    expect(described_class.publicly_available?(topic)).to eq(false)
    embed.update!(deleted_at: Time.zone.now)
    expect(described_class.publicly_available?(topic)).to eq(false)
  end

  it "does not treat ordinary citations or quotes as imported-content ancestry" do
    first_post.update!(
      raw: "A forum-owned discussion cites https://source.example/article/ and quotes a passage.",
    )
    expect(described_class.publicly_available?(topic)).to eq(true)
  end
end
