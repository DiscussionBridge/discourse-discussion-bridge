import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

const CSS_CLASS = "discussion-bridge-comments-only";
const EMBED_ROUTE_KEY = "discussion-bridge:comments-only:embed-route";
const SUBMIT_LABEL_ATTRIBUTE = "data-discussion-bridge-submit-label";

function commentsOnlyRequested(url = new URL(window.location.href)) {
  const params = url.searchParams;
  const classes = params.get("class_name")?.split(/\s+/) ?? [];

  return params.get("embed_mode") === "true" && classes.includes(CSS_CLASS);
}

function isEmbeddedFrame() {
  try {
    return window.self !== window.top;
  } catch {
    return true;
  }
}

function validStoredEmbedRoute(value) {
  if (!value) {
    return null;
  }

  try {
    const url = new URL(value);
    if (
      url.origin !== window.location.origin ||
      !url.pathname.split("/").includes("t") ||
      !commentsOnlyRequested(url)
    ) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}

function rememberOrRestoreEmbedRoute() {
  if (!isEmbeddedFrame()) {
    return commentsOnlyRequested();
  }

  const currentUrl = new URL(window.location.href);
  if (commentsOnlyRequested(currentUrl)) {
    try {
      window.sessionStorage.setItem(EMBED_ROUTE_KEY, currentUrl.toString());
    } catch {}
    return true;
  }

  let storedUrl;
  try {
    storedUrl = validStoredEmbedRoute(
      window.sessionStorage.getItem(EMBED_ROUTE_KEY)
    );
  } catch {}

  if (storedUrl) {
    window.location.replace(storedUrl.toString());
  }
  return false;
}

function labelSubmitControls() {
  document
    .querySelectorAll(
      ".embed-mode-composer .docked-composer__submit-btn"
    )
    .forEach((button) => {
      const editing = button
        .closest(".embed-mode-composer")
        ?.querySelector(".embed-mode-composer__editing");
      const label = i18n(
        editing
          ? "discussion_bridge.composer_save_edit"
          : "discussion_bridge.composer_submit"
      );
      button.setAttribute(SUBMIT_LABEL_ATTRIBUTE, label);
      button.setAttribute("aria-label", label);
      button.setAttribute("title", label);
    });
}

export default {
  name: "discussion-bridge-comments-only",

  initialize() {
    if (!rememberOrRestoreEmbedRoute()) {
      return;
    }

    withPluginApi((api) => {
      const syncClass = () => {
        if (!rememberOrRestoreEmbedRoute()) {
          return;
        }
        window.requestAnimationFrame(() => {
          document.documentElement.classList.toggle(
            CSS_CLASS,
            document.body.classList.contains("embed-mode")
          );
          labelSubmitControls();
        });
      };

      const observer = new MutationObserver(labelSubmitControls);
      observer.observe(document.body, { childList: true, subtree: true });
      api.onPageChange(syncClass);
      syncClass();
    });
  },
};
