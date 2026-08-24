import { withPluginApi } from "discourse/lib/plugin-api";
import logout from "discourse/lib/logout";
import { i18n } from "discourse-i18n";

const CSS_CLASS = "discussion-bridge-comments-only";
const ATTESTED_ATTRIBUTE = "data-discussion-bridge-comments-only-attested";
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

function labelSubmitControls(qualified) {
  document
    .querySelectorAll(".embed-mode-composer .docked-composer__submit-btn")
    .forEach((button) => {
      if (!qualified) {
        const pluginLabel = button.getAttribute(SUBMIT_LABEL_ATTRIBUTE);
        if (pluginLabel && button.getAttribute("aria-label") === pluginLabel) {
          button.removeAttribute("aria-label");
        }
        if (pluginLabel && button.getAttribute("title") === pluginLabel) {
          button.removeAttribute("title");
        }
        button.removeAttribute(SUBMIT_LABEL_ATTRIBUTE);
        return;
      }

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

function topicIdFromPath(pathname = window.location.pathname) {
  return pathname.match(
    /^\/t\/(?:[^/]+\/)?([1-9]\d*)(?:\/[1-9]\d*)?\/?$/,
  )?.[1];
}

function serverAttestedCompletedMapping() {
  const topicId = topicIdFromPath();
  const attestedTopicId = document.querySelector(
    COMPLETED_MAPPING_META,
  )?.content;

  return topicId && attestedTopicId === topicId ? topicId : null;
}

function matchesQualifiedMapping(qualification) {
  const url = new URL(window.location.href);

  return (
    serverAttestedCompletedMapping() === qualification.topicId &&
    url.searchParams.get("discussion_bridge_embed_token") ===
      qualification.token &&
    commentsOnlyRequested(url)
  );
}

function interceptLogoutRefresh(event, qualification) {
  if (!(event.target instanceof Element)) {
    return;
  }

  const button = event.target.closest(LOGOUT_REFRESH_SELECTOR);
  if (
    !button ||
    window.self === window.top ||
    !matchesQualifiedMapping(qualification) ||
    !document.documentElement.hasAttribute(ATTESTED_ATTRIBUTE) ||
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
    const topicId = serverAttestedCompletedMapping();
    const token = new URL(window.location.href).searchParams.get(
      "discussion_bridge_embed_token",
    );
    if (!commentsOnlyRequested() || !topicId || !token) {
      return;
    }

    withPluginApi((api) => {
      const qualification = { topicId, token };
      const syncPresentation = () => {
        window.requestAnimationFrame(() => {
          const qualified =
            document.body.classList.contains("embed-mode") &&
            matchesQualifiedMapping(qualification);
          document.documentElement.toggleAttribute(
            ATTESTED_ATTRIBUTE,
            qualified,
          );
          labelSubmitControls(qualified);
        });
      };

      const observer = new MutationObserver(syncPresentation);
      observer.observe(document.body, { childList: true, subtree: true });
      document.addEventListener(
        "click",
        (event) => interceptLogoutRefresh(event, qualification),
        true,
      );
      api.onPageChange(syncPresentation);
      syncPresentation();
    });
  },
};
