# frozen_string_literal: true

describe "DiscussionBridge comments-only fullInteractive" do
  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic, raw: "Companion source post") }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_any_origin = true
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/article",
      source_identity_digest: Digest::SHA256.hexdigest("astro\nhttps://example.com/article"),
      state: "complete",
      topic_id: topic.id,
      effective_actor_id: topic.user_id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  it "removes companion post 1 from embed layout but preserves the native empty state" do
    first_post.update!(raw: ("Long companion content. " * 500))
    first_post.rebake!
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    expect(page).to have_css("#post_1", visible: :hidden)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).to eq("none")
    expect(page).to have_css(".embed-topic-footer__first-reply")
    expect(
      page.evaluate_script(
        "document.documentElement.classList.contains('discussion-bridge-comments-only')",
      ),
    ).to eq(true)

    initial_height = page.evaluate_script("document.querySelector('#main').scrollHeight")

    much_longer_topic = Fabricate(:topic)
    Fabricate(:post, topic: much_longer_topic, raw: ("Much longer companion content. " * 900))
    DiscussionBridgeConnection.create!(
      connection_id: "astro-much-longer",
      canonical_source_url: "https://example.com/much-longer-article",
      source_identity_digest:
        Digest::SHA256.hexdigest("astro-much-longer\nhttps://example.com/much-longer-article"),
      state: "complete",
      topic_id: much_longer_topic.id,
      effective_actor_id: much_longer_topic.user_id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
    visit("/embed/comments?topic_id=#{much_longer_topic.id}&full_app=true")

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    expect(page).to have_css("#post_1", visible: :hidden)
    longer_source_height = page.evaluate_script("document.querySelector('#main').scrollHeight")

    expect(longer_source_height).to be_within(2).of(initial_height)
  end

  it "keeps replies and their native actions visible" do
    reply = Fabricate(:post, topic: topic, raw: "A visible community reply")
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("#post_#{reply.post_number}", text: "A visible community reply")
    expect(page).to have_css("#post_#{reply.post_number} nav.post-controls")
    expect(page).to have_no_css(".embed-topic-footer__first-reply")
  end

  it "does not change the ordinary topic presentation even for a long companion post" do
    first_post.update!(raw: ("Long companion content. " * 500))
    first_post.rebake!

    visit("/t/#{topic.slug}/#{topic.id}")

    expect(page).to have_no_css("html.discussion-bridge-comments-only")
    expect(page).to have_css("#post_1", text: "Long companion content.")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).not_to eq("none")
  end

  it "strips a caller-supplied reserved marker when the operator option is disabled" do
    SiteSetting.discussion_bridge_comments_only_full_interactive = false

    visit(
      "/embed/comments?topic_id=#{topic.id}&full_app=true&#{
        { class_name: "discussion-bridge-comments-only <bad" }.to_query
      }",
    )

    expect(page).to have_no_css("html.discussion-bridge-comments-only")
    expect(page).to have_css("#post_1", text: "Companion source post")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).not_to eq("none")
  end
end
