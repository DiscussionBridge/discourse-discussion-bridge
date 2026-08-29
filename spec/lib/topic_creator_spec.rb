# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::TopicCreator do
  TopicPolicy = Data.define(:effective_actor_id, :effective_category_id, :effective_tags)

  fab!(:actor, :admin)
  fab!(:category)
  let(:policy) { TopicPolicy.new(effective_actor_id: actor.id, effective_category_id: category.id, effective_tags: []) }
  let(:request) do
    {
      connection_id: "astro",
      source_url: "https://example.com/articles/source",
      title: "A controlled DiscussionBridge companion topic",
      content_html: "<h2>Community guide</h2><p>Source-owned article content.</p>",
    }
  end

  it "creates an unlisted topic with source content and canonical attribution" do
    creation = described_class.new.call(request: request, policy: policy)
    post = creation.topic.first_post

    expect(creation.topic.user_id).to eq(actor.id)
    expect(creation.topic.visible).to eq(false)
    expect(post.user_id).to eq(actor.id)
    expect(post.raw).to eq(
      "Originally published at " \
        "[https://example.com/articles/source](https://example.com/articles/source)\n\n" \
        "---\n\n<h2>Community guide</h2><p>Source-owned article content.</p>",
    )
    expect(post.cooked).to include("Community guide", "Source-owned article content")
  end
end
