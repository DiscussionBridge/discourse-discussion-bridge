# frozen_string_literal: true

describe "DiscussionBridge comments-only fullInteractive" do
  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic, raw: "Companion source post") }
  fab!(:interactive_user) do
    Fabricate(:user, trust_level: TrustLevel[1], refresh_auto_groups: true)
  end
  fab!(:interaction_author) { Fabricate(:user, refresh_auto_groups: true) }

  before do
    SiteSetting.discussion_bridge_enabled = true
    SiteSetting.discussion_bridge_comments_only_full_interactive = true
    SiteSetting.embed_full_app = true
    SiteSetting.embed_full_app_signin_flow = true
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

  it "completes an authenticated reply inside the full-app embed" do
    sign_in(interactive_user)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("body.embed-mode")
    expect(page).to have_css(".embed-topic-footer__first-reply")
    find(".embed-topic-footer__first-reply button").click
    expect(page).to have_css(".embed-mode-composer .d-editor-input")
    expect(page).to have_css(
      ".embed-mode-composer .docked-composer__submit-btn[data-discussion-bridge-submit-label='Post reply'][aria-label='Post reply'][title='Post reply']",
    )
    expect(
      page.evaluate_script(
        "getComputedStyle(document.querySelector('.docked-composer__submit-btn'), '::after').content",
      ),
    ).to eq('"Post reply"')

    find(".embed-mode-composer .d-editor-input").set("A native in-frame reply")
    find(".embed-mode-composer .docked-composer__submit-btn").click

    expect(page).to have_css(".topic-post", text: "A native in-frame reply")
    expect(Post.exists?(topic_id: topic.id, user_id: interactive_user.id, raw: "A native in-frame reply")).to eq(true)
    expect(page.current_url).to include("embed_mode=true")
  end

  it "labels and completes an authorized edit inside the full-app embed" do
    editable_post =
      Fabricate(
        :post,
        topic: topic,
        user: interactive_user,
        raw: "An editable in-frame reply",
      )
    sign_in(interactive_user)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    within("#post_#{editable_post.post_number}") { find("button.edit").click }
    expect(page).to have_css(".embed-mode-composer__editing")
    expect(page).to have_css(
      ".embed-mode-composer .docked-composer__submit-btn[data-discussion-bridge-submit-label='Save edit'][aria-label='Save edit'][title='Save edit']",
    )
    expect(
      page.evaluate_script(
        "getComputedStyle(document.querySelector('.docked-composer__submit-btn'), '::after').content",
      ),
    ).to eq('"Save edit"')

    find(".embed-mode-composer .d-editor-input").set("The edited in-frame reply")
    find(".embed-mode-composer .docked-composer__submit-btn").click

    expect(page).to have_css("#post_#{editable_post.post_number}", text: "The edited in-frame reply")
    expect(editable_post.reload.raw).to eq("The edited in-frame reply")
    expect(page.current_url).to include("embed_mode=true")
  end

  it "completes native reply and like actions without leaving embed mode" do
    reply =
      Fabricate(
        :post,
        topic: topic,
        user: interaction_author,
        raw: "A reply ready for interaction",
      )
    sign_in(interactive_user)
    expect(Guardian.new(interactive_user).post_can_act?(reply, :like)).to eq(true)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    within("#post_#{reply.post_number}") do
      find(".discourse-reactions-reaction-button[title='Like this post']").click
      expect(page).to have_css(".discourse-reactions-reaction-button[title='Remove this like']")
      find("button.reply").click
    end
    expect(
      PostAction.exists?(
        post_id: reply.id,
        user_id: interactive_user.id,
        post_action_type_id: PostActionType.types[:like],
      ),
    ).to eq(true)
    expect(page).to have_css(".embed-mode-composer .d-editor-input")
    find(".embed-mode-composer .d-editor-input").set("Replying inside the embedded page")
    find(".embed-mode-composer .docked-composer__submit-btn").click
    expect(page).to have_css(".topic-post", text: "Replying inside the embedded page")
    expect(page.current_url).to include("embed_mode=true")
  end

  it "completes a native quote reply without leaving embed mode" do
    quoted_post =
      Fabricate(
        :post,
        topic: topic,
        user: interaction_author,
        raw: "Words selected for an embedded quote",
      )
    sign_in(interactive_user)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    select_text_range("#post_#{quoted_post.post_number} .cooked p", 0, 14)
    find(".quote-button .insert-quote").click

    expect(page).to have_css(".embed-mode-composer .d-editor-input")
    expect(page).to have_field(class: "d-editor-input", with: /Words selected/)
    find(".embed-mode-composer .docked-composer__submit-btn").click

    expect(page).to have_css(".topic-post blockquote", text: "Words selected")
    expect(
      Post.where(topic_id: topic.id, user_id: interactive_user.id).where.not(id: quoted_post.id).exists?,
    ).to eq(true)
    expect(page.current_url).to include("embed_mode=true")
  end

  it "does not invent a logout control that qualified Core does not render in embed mode" do
    sign_in(interactive_user)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    expect(page).to have_no_css("li.logout button")
    expect(page).to have_no_css("[data-discussion-bridge-logout]")
    expect(page.current_url).to include("embed_mode=true")
  end

  it "keeps mapped and ordinary iframe browsing contexts isolated" do
    second_topic = Fabricate(:topic)
    Fabricate(:post, topic: second_topic, raw: "Second companion source post")
    DiscussionBridgeConnection.create!(
      connection_id: "astro-second",
      canonical_source_url: "https://example.com/second-article",
      source_identity_digest: Digest::SHA256.hexdigest("astro-second\nhttps://example.com/second-article"),
      state: "complete",
      topic_id: second_topic.id,
      effective_actor_id: second_topic.user_id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
    ordinary_topic = Fabricate(:topic)
    Fabricate(:post, topic: ordinary_topic, raw: "Ordinary Core topic")

    visit("/")
    page.execute_script(<<~JS)
      [
        ["mapped-frame-one", "/embed/comments?topic_id=#{topic.id}&full_app=true"],
        ["mapped-frame-two", "/embed/comments?topic_id=#{second_topic.id}&full_app=true"],
        ["ordinary-core-frame", "/embed/comments?topic_id=#{ordinary_topic.id}&full_app=true"],
      ].forEach(([id, src]) => {
        const frame = document.createElement("iframe");
        frame.id = id;
        frame.src = src;
        document.body.appendChild(frame);
      });
    JS

    within_frame("mapped-frame-one") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      expect(page.evaluate_script("window.location.href")).to match(%r{/t/[^/]+/#{topic.id}\?})
    end
    within_frame("mapped-frame-two") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      expect(page.evaluate_script("window.location.href")).to match(
        %r{/t/[^/]+/#{second_topic.id}\?},
      )
    end
    within_frame("ordinary-core-frame") do
      expect(page).to have_no_css("html.discussion-bridge-comments-only")
    end
    ordinary_url = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const frame = document.getElementById("ordinary-core-frame");
      frame.addEventListener("load", () => done(frame.contentWindow.location.href), { once: true });
      frame.contentWindow.location.assign("/?ordinary_navigation=1");
    JS
    expect(URI.parse(ordinary_url).request_uri).to eq("/?ordinary_navigation=1")
    deliberate_url = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const frame = document.getElementById("mapped-frame-one");
      frame.addEventListener("load", () => done(frame.contentWindow.location.href), { once: true });
      frame.contentWindow.location.assign("/latest");
    JS
    expect(URI.parse(deliberate_url).path).to eq("/latest")
    within_frame("mapped-frame-two") do
      expect(page.evaluate_script("window.location.href")).to match(
        %r{/t/[^/]+/#{second_topic.id}\?},
      )
    end
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
