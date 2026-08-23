import { withPluginApi } from "discourse/lib/plugin-api";
import logout from "discourse/lib/logout";
import { i18n } from "discourse-i18n";

const CSS_CLASS = "discussion-bridge-comments-only";
const SUBMIT_LABEL_ATTRIBUTE = "data-discussion-bridge-submit-label";
const LOGOUT_REFRESH_SELECTOR =
  ".dialog-container__logout-refresh .dialog-footer button.btn-primary";
const COMPLETED_MAPPING_META =
  "meta[name='discussion-bridge-completed-mapping']";

function commentsOnlyRequested(url = new URL(window.location.href)) {
  const params = url.searchParams;
  const classes = params.get("class_name")?.split(/\s+/) ?? [];

  return params.get("embed_mode") === "true" && classes.includes(CSS_CLASS);
}

function labelSubmitControls() {
  document
    .querySelectorAll(".embed-mode-composer .docked-composer__submit-btn")
    .forEach((button) => {
      const editing = button
        .closest(".embed-mode-composer")
        ?.querySelector(".embed-mode-composer__editing");
      const label = i18n(
        editing
          ? "discussion_bridge.composer_save_edit"
          : "discussion_bridge.composer_submit",
      );
      button.setAttribute(SUBMIT_LABEL_ATTRIBUTE, label);
      button.setAttribute("aria-label", label);
      button.setAttribute("title", label);
    });
}

function currentEmbedRoute() {
  return `${window.location.pathname}${window.location.search}${window.location.hash}`;
}

function serverAttestedCompletedMapping() {
  const topicMatch = window.location.pathname.match(
    /^\/t\/(?:[^/]+\/)?([1-9]\d*)(?:\/[1-9]\d*)?\/?$/,
  );
  const attestedTopicId = document.querySelector(
    COMPLETED_MAPPING_META,
  )?.content;

  return Boolean(topicMatch && attestedTopicId === topicMatch[1]);
}

function interceptLogoutRefresh(event, qualifiedEmbedRoute) {
  if (!(event.target instanceof Element)) {
    return;
  }

  const button = event.target.closest(LOGOUT_REFRESH_SELECTOR);
  if (
    !button ||
    window.self === window.top ||
    currentEmbedRoute() !== qualifiedEmbedRoute ||
    !serverAttestedCompletedMapping() ||
    !document.documentElement.classList.contains(CSS_CLASS) ||
    !document.body.classList.contains("embed-mode")
  ) {
    return;
  }

  event.preventDefault();
  event.stopImmediatePropagation();
  logout({ redirect: currentEmbedRoute() });
}

export default {
  name: "discussion-bridge-comments-only",

  initialize() {
    if (!commentsOnlyRequested() || !serverAttestedCompletedMapping()) {
      return;
    }

    withPluginApi((api) => {
      const qualifiedEmbedRoute = currentEmbedRoute();
      const syncClass = () => {
        window.requestAnimationFrame(() => {
          document.documentElement.classList.toggle(
            CSS_CLASS,
            document.body.classList.contains("embed-mode"),
          );
          labelSubmitControls();
        });
      };

      const observer = new MutationObserver(labelSubmitControls);
      observer.observe(document.body, { childList: true, subtree: true });
      document.addEventListener(
        "click",
        (event) => interceptLogoutRefresh(event, qualifiedEmbedRoute),
        true,
      );
      api.onPageChange(syncClass);
      syncClass();
    });
  },
};
