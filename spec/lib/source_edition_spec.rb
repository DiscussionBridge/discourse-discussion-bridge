# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::SourceEdition do
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: admin, post_number: 1) }

  around do |example|
    original = ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME")
    example.run
  ensure
    original.nil? ?
      ENV.delete("DISCUSSIONBRIDGE_FORUM_NAME") :
      ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = original
  end

  it "returns coherent native content, exact dates and a stable edition while retaining the legacy revision" do
    value = described_class.for_topic(topic.id)
    expect(value.title).to eq(topic.title)
    expect(value.content_html).to eq(first_post.cooked)
    expect(value.topic_url).to eq(topic.url)
    expect(value.source).to include(
      revision: "post:#{first_post.id}:version:#{first_post.version}",
      created_at: first_post.created_at.utc.iso8601(6),
      updated_at: first_post.updated_at.utc.iso8601(6),
      forum_name: SiteSetting.title,
    )
    expect(value.source.fetch(:edition)).to match(/\A[0-9a-f]{64}\z/)
    expect(described_class.for_topic(topic.id).source.fetch(:edition)).to eq(
      value.source.fetch(:edition),
    )
  end

  it "matches the candidate contract's independent Unicode and microsecond golden source edition" do
    input =
      JSON.parse(File.read(File.expand_path("../fixtures/source-edition-input.json", __dir__)))
    row = [
      input.fetch("topic_id"),
      input.fetch("title"),
      "coherent-source",
      Time.iso8601(input.fetch("topic_created_at")),
      input.fetch("post_id"),
      input.fetch("post_number"),
      input.fetch("post_version"),
      Time.iso8601(input.fetch("post_created_at")),
      Time.iso8601(input.fetch("post_updated_at")),
      input.fetch("raw"),
      input.fetch("cooked"),
      input.fetch("author_username"),
      input.fetch("author_username_lower"),
      input.fetch("effective_author_name"),
    ]
    allow(Discourse).to receive(:base_url).and_return(input.fetch("origin"))
    allow(described_class).to receive(:forum_name).and_return(input.fetch("forum_name"))
    # Substitute only this exact query result; no fixture IDs are written into
    # the seeded native database. The real source builder serializes the row.
    allow_any_instance_of(ActiveRecord::Relation).to receive(:pluck).with(
      *described_class::SOURCE_COLUMNS,
    ).and_return([row])
    # Permission checks use native fixture records; the golden row itself is
    # never inserted into the native database.
    native_posts = Post.where(id: first_post.id)
    allow(Post).to receive(:where).with(id: [input.fetch("post_id")]).and_return(native_posts)
    allow(native_posts).to receive(:includes).with(topic: :category).and_return(native_posts)
    allow(native_posts).to receive(:index_by).and_return(input.fetch("post_id") => first_post)

    value = described_class.for_topic(input.fetch("topic_id"))
    expect(value.topic_url).to eq(input.fetch("topic_url"))
    expect(value.content_html).to eq(input.fetch("cooked"))
    expect(value.source.fetch(:edition)).to eq(
      "a93a2f632dfcab5dbcd0613db969c8295ae25cae61fa91aa382eca432b010d30",
    )
    expect(value.source.fetch(:updated_at)).to eq(input.fetch("post_updated_at"))
  end

  it "does not combine cached topic data with a later first-post edit" do
    cached = Topic.find(topic.id)
    cached.first_post
    Topic.find(topic.id).update!(title: "Current source title after cached association")
    Post.find(first_post.id).update!(raw: "Current source raw")
    value = described_class.for_topic(cached.id)
    expect(value.title).to eq("Current source title after cached association")
    expect(value.content_html).to eq(Post.find(first_post.id).cooked)
    expect(value.content_html).to include("Current source raw")
  end

  it "uses the server override then the selected forum name then the native title" do
    SiteSetting.title = "Native forum title"
    initial = described_class.for_topic(topic.id)
    SiteSetting.discussion_bridge_forum_name = "Selected publication forum"
    selected = described_class.for_topic(topic.id)
    expect(selected.source.fetch(:forum_name)).to eq("Selected publication forum")
    expect(selected.source.fetch(:edition)).not_to eq(initial.source.fetch(:edition))
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = "Server publication forum"
    expect(described_class.for_topic(topic.id).source.fetch(:forum_name)).to eq(
      "Server publication forum",
    )
    ENV["DISCUSSIONBRIDGE_FORUM_NAME"] = " "
    SiteSetting.discussion_bridge_forum_name = ""
    expect(described_class.for_topic(topic.id).source.fetch(:forum_name)).to eq(
      "Native forum title",
    )
  end

  it "changes edition for native author metadata without inventing a new post version" do
    initial = described_class.for_topic(topic.id)
    admin.update!(name: "Updated native author name")
    updated = described_class.for_topic(topic.id)
    expect(updated.source.fetch(:author).fetch(:name)).to eq("Updated native author name")
    expect(updated.source.fetch(:revision)).to eq(initial.source.fetch(:revision))
    expect(updated.source.fetch(:edition)).not_to eq(initial.source.fetch(:edition))
  end

  it "returns no source content after the native first post is deleted" do
    first_post.update!(deleted_at: Time.zone.now)
    expect(described_class.for_topic(topic.id)).to be_nil
  end

  it "does not publish a shared draft even when its native category is publicly readable" do
    SharedDraft.create!(topic_id: topic.id, category_id: topic.category_id)
    expect(described_class.publicly_available?(topic)).to eq(false)
    expect(described_class.for_topic(topic.id)).to be_nil
  end

  it "does not export a first post denied by native anonymous moderation permissions" do
    SiteSetting.hidden_post_visible_groups = Group::AUTO_GROUPS[:staff].to_s
    first_post.hide!(PostActionType.types[:spam])
    topic.reload
    first_post.reload
    expect(Guardian.new(nil).can_see?(topic)).to eq(true)
    expect(Guardian.new(nil).can_see?(first_post)).to eq(false)
    expect(described_class.publicly_available?(topic)).to eq(false)
    expect(described_class.for_topic(topic.id)).to be_nil
  end

  it "does not republish a native Core imported first post, including retained embed ancestry" do
    embed =
      TopicEmbed.create!(
        topic: topic,
        post: first_post,
        embed_url: "https://source.example/article/",
      )
    expect(described_class.publicly_available?(topic)).to eq(false)
    expect(described_class.for_topic(topic.id)).to be_nil
    embed.update!(deleted_at: Time.zone.now)
    expect(described_class.publicly_available?(topic)).to eq(false)
    expect(described_class.for_topic(topic.id)).to be_nil
  end

  it "does not treat ordinary citations or quotes as imported-content ancestry" do
    first_post.update!(
      raw: "A forum-owned discussion cites https://source.example/article/ and quotes a passage.",
    )
    expect(described_class.publicly_available?(topic)).to eq(true)
    expect(described_class.for_topic(topic.id).content_html).to include("forum-owned discussion")
  end

  it "does not move source modification time or edition for an ordinary reply or topic bump" do
    original = described_class.for_topic(topic.id)
    freeze_time(1.hour.from_now) do
      PostCreator.new(
        admin,
        topic_id: topic.id,
        reply_to_post_number: 1,
        raw: "An ordinary reply that leaves the published first post unchanged",
        skip_jobs: true,
      ).create!
      expect(topic.reload.updated_at).to be > first_post.reload.updated_at
      after_reply = described_class.for_topic(topic.id)
      expect(after_reply.source.fetch(:updated_at)).to eq(original.source.fetch(:updated_at))
      expect(after_reply.source.fetch(:edition)).to eq(original.source.fetch(:edition))

      topic.update!(bumped_at: Time.zone.now)
      after_bump = described_class.for_topic(topic.id)
      expect(after_bump.source.fetch(:updated_at)).to eq(original.source.fetch(:updated_at))
      expect(after_bump.source.fetch(:edition)).to eq(original.source.fetch(:edition))
    end
  end

  it "advances authoritative source modification time for a native title-only edit" do
    original = described_class.for_topic(topic.id)
    freeze_time(1.hour.from_now) do
      expect(
        first_post.revise(admin, title: "A title-only edit with its native first-post revision"),
      ).to eq(true)
      edited = described_class.for_topic(topic.id)
      expect(edited.source.fetch(:updated_at)).to eq(first_post.reload.updated_at.utc.iso8601(6))
      expect(edited.source.fetch(:updated_at)).not_to eq(original.source.fetch(:updated_at))
      expect(edited.source.fetch(:edition)).not_to eq(original.source.fetch(:edition))
      expect(edited.content_html).to eq(original.content_html)
    end
  end
end
