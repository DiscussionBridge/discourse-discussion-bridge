# frozen_string_literal: true

describe "DiscussionBridge comments-only fullInteractive" do
  fab!(:service_actor, :admin)
  fab!(:topic) { Fabricate(:topic, user: service_actor, visible: false) }
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
    SiteSetting.discussion_bridge_service_username = service_actor.username
    SiteSetting.discussion_bridge_effective_category_id = topic.category_id
    SiteSetting.discussion_bridge_effective_tags = ""
    SiteSetting.discussion_bridge_lane_policies = "[]"
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
    expect(page).to have_css("html[data-discussion-bridge-comments-only-attested] body.embed-mode")
    expect(page).to have_css("#post_1", visible: :hidden)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).to eq("none")
    expect(page).to have_css(".embed-topic-footer__first-reply")
    expect(
      page.evaluate_script(
        "document.documentElement.classList.contains('discussion-bridge-comments-only')",
      ),
    ).to eq(true)

    initial_height = page.evaluate_script("document.querySelector('#main').scrollHeight")

    much_longer_topic = Fabricate(:topic, user: service_actor, category: topic.category, visible: false)
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
    expect(page).to have_css("html[data-discussion-bridge-comments-only-attested] body.embed-mode")
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

  it "keeps Core's mapped-embed logout refresh on the mapped child-frame route" do
    sign_in(interactive_user)
    visit("/")
    page.execute_script(<<~JS)
      const frame = document.createElement("iframe");
      frame.id = "mapped-logout-frame";
      frame.src = "/embed/comments?topic_id=#{topic.id}&full_app=true";
      document.body.appendChild(frame);
    JS

    within_frame("mapped-logout-frame") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      mapped_route = URI.parse(page.evaluate_script("window.location.href")).request_uri
      page.execute_script(<<~JS)
        const dialog = document.createElement("div");
        dialog.className = "dialog-container__logout-refresh";
        dialog.innerHTML = `
          <div class="dialog-body"><p>You were logged out.</p></div>
          <div class="dialog-footer">
            <button class="btn btn-primary" type="button">
              <span class="d-button-label">Refresh</span>
            </button>
          </div>`;
        document.body.appendChild(dialog);
      JS

      find(".dialog-container__logout-refresh .dialog-footer button.btn-primary").click
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      expect(URI.parse(page.evaluate_script("window.location.href")).request_uri).to eq(mapped_route)

      page.execute_script(<<~JS)
        window.__discussionBridgeGenericRefreshReached = false;
        const button = document.createElement("button");
        button.className = "btn btn-primary";
        button.textContent = "Refresh";
        button.addEventListener("click", () => {
          window.__discussionBridgeGenericRefreshReached = true;
        });
        document.body.appendChild(button);
      JS
      all("body > button.btn-primary").last.click
      expect(page.evaluate_script("window.__discussionBridgeGenericRefreshReached")).to eq(true)
    end
  end

  it "keeps Core's logout refresh after same-topic post navigation" do
    Fabricate(:post, topic: topic, raw: "A reply that Core can navigate to")
    sign_in(interactive_user)
    visit("/")
    page.execute_script(<<~JS)
      const frame = document.createElement("iframe");
      frame.id = "mapped-post-logout-frame";
      frame.src = "/embed/comments?topic_id=#{topic.id}&full_app=true";
      document.body.appendChild(frame);
    JS

    within_frame("mapped-post-logout-frame") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      page.execute_script(<<~JS)
        const url = new URL(window.location.href);
        url.pathname = `/t/#{topic.id}/2`;
        window.history.pushState({}, "", `${url.pathname}${url.search}`);
        const dialog = document.createElement("div");
        dialog.className = "dialog-container__logout-refresh";
        dialog.innerHTML = `
          <div class="dialog-footer">
            <button class="btn btn-primary" type="button">Refresh</button>
          </div>`;
        document.body.appendChild(dialog);
      JS

      expect(page).to have_css("html[data-discussion-bridge-comments-only-attested]")
      navigated_route = URI.parse(page.evaluate_script("window.location.href")).request_uri
      find(".dialog-container__logout-refresh button.btn-primary").click
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      expect(URI.parse(page.evaluate_script("window.location.href")).request_uri).to eq(
        navigated_route,
      )
    end
  end

  it "removes attested presentation after in-document navigation to another topic" do
    another_topic = Fabricate(:topic)
    Fabricate(:post, topic: another_topic, raw: "Another topic source post")
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("html[data-discussion-bridge-comments-only-attested]")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).to eq(
      "none",
    )

    page.execute_script(<<~JS)
      const composer = document.createElement("div");
      composer.className = "embed-mode-composer";
      composer.innerHTML = `
        <button
          id="lifecycle-submit-control"
          class="docked-composer__submit-btn"
          aria-label="Core submit"
          title="Core title"
          data-discussion-bridge-submit-label="Core marker"
          data-discussion-bridge-original-aria-label="Caller-owned value"
        >Core action</button>`;
      document.body.appendChild(composer);
    JS
    expect(page).to have_css(
      "#lifecycle-submit-control[data-discussion-bridge-submit-label='Post reply'][aria-label='Post reply'][title='Post reply']",
    )

    page.execute_script(<<~JS)
      const button = document.getElementById("lifecycle-submit-control");
      button.setAttribute("aria-label", "Core newer submit");
      button.removeAttribute("title");
      button.setAttribute("data-discussion-bridge-submit-label", "Core newer marker");
      const url = new URL(window.location.href);
      url.pathname = "/t/#{another_topic.slug}/#{another_topic.id}";
      window.history.pushState({}, "", `${url.pathname}${url.search}`);
      button.closest(".embed-mode-composer").remove();
      button.className = "core-reparented-submit-control";
      document.body.appendChild(button);
    JS

    expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).not_to eq(
      "none",
    )
    expect(page).to have_css(
      "#lifecycle-submit-control.core-reparented-submit-control[data-discussion-bridge-submit-label='Core newer marker'][aria-label='Core newer submit']:not([title])[data-discussion-bridge-original-aria-label='Caller-owned value']",
      text: "Core action",
    )
  end


  it "releases an owned control that becomes ineligible on the same qualified route" do
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    page.execute_script(<<~JS)
      const composer = document.createElement("div");
      composer.className = "embed-mode-composer";
      composer.innerHTML = `
        <button id="same-route-submit" class="docked-composer__submit-btn"
          aria-label="Core submit" title="Core title"
          data-discussion-bridge-submit-label="Core marker">Core action</button>`;
      document.body.appendChild(composer);
    JS
    expect(page).to have_css("#same-route-submit[aria-label='Post reply']")

    page.execute_script(<<~JS)
      document.getElementById("same-route-submit").className = "core-other-control";
    JS

    expect(page).to have_css(
      "#same-route-submit.core-other-control[aria-label='Core submit'][title='Core title'][data-discussion-bridge-submit-label='Core marker']",
    )
    expect(page).to have_css("html[data-discussion-bridge-comments-only-attested]")
  end

  it "restores the latest detached Core state when removal and mutation share a delivery" do
    another_topic = Fabricate(:topic)
    Fabricate(:post, topic: another_topic, raw: "Another topic source post")
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    page.execute_script(<<~JS)
      const composer = document.createElement("div");
      composer.id = "remove-mutate-composer";
      composer.className = "embed-mode-composer";
      composer.innerHTML = `
        <button id="remove-mutate-submit" class="docked-composer__submit-btn"
          aria-label="Core original" title="Core original title">Core action</button>`;
      document.body.appendChild(composer);
    JS
    expect(page).to have_css("#remove-mutate-submit[aria-label='Post reply']")

    page.execute_script(<<~JS)
      const button = document.getElementById("remove-mutate-submit");
      window.__removeMutateButton = button;
      document.getElementById("remove-mutate-composer").remove();
      button.setAttribute("aria-label", "Core detached latest");
      button.removeAttribute("title");
      button.setAttribute("data-discussion-bridge-submit-label", "Core detached marker");
    JS
    expect(page.evaluate_script("window.__removeMutateButton.getAttribute('aria-label')")).to eq(
      "Core detached latest",
    )
    expect(page.evaluate_script("window.__removeMutateButton.hasAttribute('title')")).to eq(false)
    expect(
      page.evaluate_script(
        "window.__removeMutateButton.getAttribute('data-discussion-bridge-submit-label')",
      ),
    ).to eq("Core detached marker")

    page.execute_script(<<~JS)
      const url = new URL(window.location.href);
      url.pathname = "/t/#{another_topic.slug}/#{another_topic.id}";
      window.history.pushState({}, "", `${url.pathname}${url.search}`);
      document.body.appendChild(window.__removeMutateButton);
    JS
    expect(page).to have_css(
      "#remove-mutate-submit[aria-label='Core detached latest'][data-discussion-bridge-submit-label='Core detached marker']:not([title])",
    )
  end


  it "restores a detached owned control before later non-mapped reinsertion" do
    another_topic = Fabricate(:topic)
    Fabricate(:post, topic: another_topic, raw: "Another topic source post")
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    page.execute_script(<<~JS)
      const composer = document.createElement("div");
      composer.id = "detached-composer";
      composer.className = "embed-mode-composer";
      composer.innerHTML = `
        <button id="detached-submit" class="docked-composer__submit-btn"
          aria-label="Core detached" title="Core detached title">Core action</button>`;
      document.body.appendChild(composer);
    JS
    expect(page).to have_css("#detached-submit[data-discussion-bridge-submit-label='Post reply']")

    page.execute_script(<<~JS)
      window.__detachedBridgeButton = document.getElementById("detached-submit");
      document.getElementById("detached-composer").remove();
    JS
    expect(page.evaluate_script("window.__detachedBridgeButton.getAttribute('aria-label')")).to eq(
      "Core detached",
    )
    expect(
      page.evaluate_script("window.__detachedBridgeButton.hasAttribute('data-discussion-bridge-submit-label')"),
    ).to eq(false)

    page.execute_script(<<~JS)
      const url = new URL(window.location.href);
      url.pathname = "/t/#{another_topic.slug}/#{another_topic.id}";
      window.history.pushState({}, "", `${url.pathname}${url.search}`);
      document.body.appendChild(window.__detachedBridgeButton);
    JS

    expect(page).to have_css(
      "#detached-submit:not([data-discussion-bridge-submit-label])[aria-label='Core detached'][title='Core detached title']",
    )
  end

  it "qualifies slugless subfolder topic and post routes for the attested topic" do
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    page.execute_script(<<~JS)
      let base = document.querySelector("meta[name='discourse-base-uri']");
      if (!base) {
        base = document.createElement("meta");
        base.name = "discourse-base-uri";
        document.head.appendChild(base);
      }
      base.content = "/forum";
      const url = new URL(window.location.href);
      url.pathname = "/forum/t/#{topic.id}/2";
      window.history.pushState({}, "", `${url.pathname}${url.search}`);
      document.body.appendChild(document.createElement("span"));
    JS

    expect(page).to have_css("html[data-discussion-bridge-comments-only-attested]")
  end

  [
    ["root duplicate slash", "/t//%{id}", nil],
    ["subfolder duplicate slash", "/forum/t/%{id}//2", "/forum"],
    ["encoded separator", "/t/slug%2Fextra/%{id}", nil],
    ["malformed post ordinal", "/t/%{id}/not-a-post", nil],
    ["extra segment", "/t/slug/%{id}/2/extra", nil],
  ].each do |label, path_template, base_path|
    it "rejects #{label} during in-document qualification" do
      visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
      page.execute_script(<<~JS)
        const basePath = #{base_path.to_json};
        if (basePath) {
          let base = document.querySelector("meta[name='discourse-base-uri']");
          if (!base) {
            base = document.createElement("meta");
            base.name = "discourse-base-uri";
            document.head.appendChild(base);
          }
          base.content = basePath;
        }
        const url = new URL(window.location.href);
        url.pathname = #{path_template.gsub("%{id}", topic.id.to_s).to_json};
        window.history.pushState({}, "", `${url.pathname}${url.search}`);
        document.body.appendChild(document.createElement("span"));
      JS

      expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
    end
  end

  it "does not intercept Core's logout refresh on a top-level embed-mode page" do
    sign_in(interactive_user)
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    page.execute_script(<<~JS)
      window.__discussionBridgeTopLevelRefreshReached = false;
      const dialog = document.createElement("div");
      dialog.className = "dialog-container__logout-refresh";
      dialog.innerHTML = `
        <div class="dialog-footer">
          <button class="btn btn-primary" type="button">Refresh</button>
        </div>`;
      dialog.querySelector("button").addEventListener("click", () => {
        window.__discussionBridgeTopLevelRefreshReached = true;
      });
      document.body.appendChild(dialog);
    JS

    find(".dialog-container__logout-refresh button.btn-primary").click
    expect(page.evaluate_script("window.__discussionBridgeTopLevelRefreshReached")).to eq(true)
  end

  it "does not intercept Core's logout refresh after navigation leaves the mapped topic" do
    sign_in(interactive_user)
    visit("/")
    page.execute_script(<<~JS)
      const frame = document.createElement("iframe");
      frame.id = "navigated-logout-frame";
      frame.src = "/embed/comments?topic_id=#{topic.id}&full_app=true";
      document.body.appendChild(frame);
    JS

    within_frame("navigated-logout-frame") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      page.execute_script(<<~JS)
        window.history.pushState({}, "", "/?non_mapped_state=1");
        window.__discussionBridgeNavigatedRefreshReached = false;
        const dialog = document.createElement("div");
        dialog.className = "dialog-container__logout-refresh";
        dialog.innerHTML = `
          <div class="dialog-footer">
            <button class="btn btn-primary" type="button">Refresh</button>
          </div>`;
        dialog.querySelector("button").addEventListener("click", () => {
          window.__discussionBridgeNavigatedRefreshReached = true;
        });
        document.body.appendChild(dialog);
      JS

      find(".dialog-container__logout-refresh button.btn-primary").click
      expect(page.evaluate_script("window.__discussionBridgeNavigatedRefreshReached")).to eq(true)
      expect(URI.parse(page.evaluate_script("window.location.href")).request_uri).to eq(
        "/?non_mapped_state=1",
      )
    end
  end

  it "does not intercept Core's logout refresh after the mapping token changes" do
    sign_in(interactive_user)
    visit("/")
    page.execute_script(<<~JS)
      const frame = document.createElement("iframe");
      frame.id = "changed-token-logout-frame";
      frame.src = "/embed/comments?topic_id=#{topic.id}&full_app=true";
      document.body.appendChild(frame);
    JS

    within_frame("changed-token-logout-frame") do
      expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
      page.execute_script(<<~JS)
        const url = new URL(window.location.href);
        url.searchParams.set("discussion_bridge_embed_token", "changed-token");
        window.history.pushState({}, "", `${url.pathname}${url.search}`);
        window.__discussionBridgeChangedTokenRefreshReached = false;
        const dialog = document.createElement("div");
        dialog.className = "dialog-container__logout-refresh";
        dialog.innerHTML = `
          <div class="dialog-footer">
            <button class="btn btn-primary" type="button">Refresh</button>
          </div>`;
        dialog.querySelector("button").addEventListener("click", () => {
          window.__discussionBridgeChangedTokenRefreshReached = true;
        });
        document.body.appendChild(dialog);
      JS

      find(".dialog-container__logout-refresh button.btn-primary").click
      expect(page.evaluate_script("window.__discussionBridgeChangedTokenRefreshReached")).to eq(
        true,
      )
    end
  end

  it "keeps mapped and ordinary iframe browsing contexts isolated" do
    second_topic = Fabricate(:topic, user: service_actor, category: topic.category, visible: false)
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

  it "does not hide post 1 for a forged direct mapped-topic route" do
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    forged_url = URI.parse(page.current_url)
    query = Rack::Utils.parse_nested_query(forged_url.query)
    query["discussion_bridge_embed_token"] = "forged"
    query["class_name"] =
      "discussion-bridge-comments-only discussion-bridge-comments-only-attested"
    forged_url.query = query.to_query

    visit(forged_url.to_s)

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
    expect(page).to have_css("#post_1", text: "Companion source post")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).not_to eq(
      "none",
    )
  end

  it "does not hide post 1 for an ordinary topic carrying another mapping's token" do
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    mapped_url = URI.parse(page.current_url)
    ordinary_topic = Fabricate(:topic)
    Fabricate(:post, topic: ordinary_topic, raw: "Ordinary topic first post")
    mapped_url.path = URI.parse(ordinary_topic.url).path

    visit(mapped_url.to_s)

    expect(page).to have_css("html.discussion-bridge-comments-only body.embed-mode")
    expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
    expect(page).to have_css("#post_1", text: "Ordinary topic first post")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('#post_1')).display")).not_to eq(
      "none",
    )
  end

  it "fails explicitly after an authentic attested mapping is invalidated" do
    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
    mapped_url = page.current_url
    DiscussionBridgeConnection.update_all(state: "failed")

    visit(mapped_url)

    expect(page).to have_content("DiscussionBridge fullInteractive is unavailable")
    expect(page).to have_no_css("#post_1")
    expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
  end

  it "fails explicitly when the mapped capability is disabled" do
    SiteSetting.discussion_bridge_comments_only_full_interactive = false

    visit("/embed/comments?topic_id=#{topic.id}&full_app=true")

    expect(page).to have_content("DiscussionBridge fullInteractive is unavailable")
    expect(page).to have_no_css("#post_1")
    expect(page).to have_no_css("html[data-discussion-bridge-comments-only-attested]")
  end
end
