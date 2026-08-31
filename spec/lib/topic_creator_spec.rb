# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::TopicCreator do
  TopicPolicy = Data.define(:operating_actor_id, :effective_actor_id, :effective_category_id, :effective_tags)

  fab!(:actor, :admin)
  fab!(:author, :user)
  fab!(:category)
  let(:policy) do
    TopicPolicy.new(
      operating_actor_id: actor.id,
      effective_actor_id: author.id,
      effective_category_id: category.id,
      effective_tags: [],
    )
  end
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

    expect(creation.topic.user_id).to eq(author.id)
    expect(creation.topic.visible).to eq(false)
    expect(post.user_id).to eq(author.id)
    expect(post.raw).to eq(
      "<h2>Community guide</h2>\n\n<p>Source-owned article content.</p>\n\n" \
        "---\n\nOriginally published at " \
        "[https://example.com/articles/source](https://example.com/articles/source)",
    )
    expect(post.raw.index("Community guide")).to be < post.raw.index("Originally published at")
    expect(post.cooked).to include("Community guide", "Source-owned article content")
  end


  it "credits the primary source author and coauthors without granting forum authority" do
    authored_request = request.merge(
      source_authors: [
        {
          "id" => "astro:phil",
          "name" => "Phil & Team",
          "profile_url" => "https://example.com/authors/phil/",
        },
        { "id" => "astro:editor", "name" => "Editorial <Group>" },
      ],
      primary_source_author_id: "astro:phil",
    )
    creation = described_class.new.call(request: authored_request, policy: policy)
    post = creation.topic.first_post

    expect(post.user_id).to eq(author.id)
    expect(post.raw).to include(
      "Source authors",
      "Phil &amp; Team",
      "Editorial &lt;Group&gt;",
      "https://example.com/authors/phil/",
    )
    expect(post.raw.index("Source authors")).to be < post.raw.index("Originally published at")
  end

  it "adds the official DiscoTOC marker only when the connection requests it for structured content" do
    structured_request = request.merge(
      content_html: "<h2>First section</h2><p>One.</p><h2>Second section</h2><p>Two.</p>",
      generate_topic_toc: true,
    )
    post = described_class.new.call(request: structured_request, policy: policy).topic.first_post

    expect(post.raw).to start_with("<div data-theme-toc=\"true\"></div>\n\n")
    expect(post.cooked).to include('data-theme-toc="true"')

    short_post = described_class.new.call(
      request: request.merge(generate_topic_toc: true, source_url: "https://example.com/articles/short"),
      policy: policy,
    ).topic.first_post
    expect(short_post.raw).not_to include("data-theme-toc")

    disabled_post = described_class.new.call(
      request: structured_request.merge(generate_topic_toc: false, source_url: "https://example.com/articles/disabled"),
      policy: policy,
    ).topic.first_post
    expect(disabled_post.raw).not_to include("data-theme-toc")
  end

  it "converts portable Mermaid and math HTML into Discourse-native source" do
    rich_request = request.merge(
      content_html: <<~HTML,
        <h2>Portable structure</h2>
        <pre><code class="language-mermaid">flowchart LR
        A[Source] --&gt; B[Bridge]</code></pre>
        <p>Inline notation $E = mc^2$ remains text.</p>
        <p>$$
        \\sum_{n=1}^{10} n = 55
        $$</p>
      HTML
    )

    post = described_class.new.call(request: rich_request, policy: policy).topic.first_post

    expect(post.raw).to include(
      "```mermaid\nflowchart LR\nA[Source] --> B[Bridge]\n```",
      "Inline notation $E = mc^2$ remains text.",
      "$$\n\\sum_{n=1}^{10} n = 55\n$$",
    )
    expect(post.raw).not_to include("language-mermaid", "<p>$$")
    expect(post.cooked).to include('class="lang-mermaid"')
    expect(post.cooked).not_to include("```mermaid")
  end

  it "does not unwrap a Mermaid block that could terminate its own fence" do
    unsafe_request = request.merge(
      content_html: '<pre><code class="language-mermaid">flowchart LR\n```\nunsafe</code></pre>',
    )

    post = described_class.new.call(request: unsafe_request, policy: policy).topic.first_post

    expect(post.raw).to include('class="language-mermaid"')
    expect(post.raw).not_to include("\n```mermaid\n")
  end
end
