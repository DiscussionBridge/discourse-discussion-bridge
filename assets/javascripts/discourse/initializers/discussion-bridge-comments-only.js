import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

const CSS_CLASS = "discussion-bridge-comments-only";
const TOKEN_PARAM = "discussion_bridge_embed_token";
const AUTH_RETURN_PREFIX = "discussion-bridge-auth-return:";
const AUTH_RETURN_MAX_AGE_MS = 2 * 60 * 1000;
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

function attestedMappedRoute(url = new URL(window.location.href)) {
  if (!commentsOnlyRequested(url)) {
    return null;
  }

  const token = url.searchParams.get(TOKEN_PARAM);
  const tokenMatch = token?.match(/^([1-9]\d*)\.(.{20,4096})$/);
  const segments = url.pathname.split("/").filter(Boolean);
  const topicId = tokenMatch?.[1];
  const exactTopicPath =
    segments.length >= 3 &&
    segments.at(-3) === "t" &&
    segments.at(-2).length > 0 &&
    segments.at(-1) === topicId;

  return exactTopicPath ? { token, topicId } : null;
}

function consumeAuthReturnState() {
  if (!window.name.startsWith(AUTH_RETURN_PREFIX)) {
    return null;
  }

  let state;
  try {
    state = JSON.parse(window.name.slice(AUTH_RETURN_PREFIX.length));
  } catch {}

  const previousName =
    typeof state?.previousName === "string" ? state.previousName : "";
  window.name = previousName;

  const now = Date.now();
  if (
    state?.version !== 1 ||
    typeof state.token !== "string" ||
    !Number.isFinite(state.issuedAt) ||
    !Number.isFinite(state.expiresAt) ||
    state.issuedAt > now ||
    state.expiresAt <= now ||
    state.expiresAt <= state.issuedAt ||
    state.expiresAt > now + AUTH_RETURN_MAX_AGE_MS ||
    state.expiresAt - state.issuedAt > AUTH_RETURN_MAX_AGE_MS ||
    now - state.issuedAt > AUTH_RETURN_MAX_AGE_MS
  ) {
    return null;
  }

  return state;
}

function reviewedLogoutDestination(url = new URL(window.location.href)) {
  return (
    url.origin === window.location.origin &&
    [getURL("/"), getURL("/login")].includes(url.pathname)
  );
}

function armLogoutReturn(event) {
  if (!isEmbeddedFrame() || !event.target.closest("li.logout button")) {
    return;
  }

  const route = attestedMappedRoute();
  if (!route) {
    return;
  }

  const previousName = window.name.startsWith(AUTH_RETURN_PREFIX)
    ? ""
    : window.name.slice(0, 1024);
  const issuedAt = Date.now();
  window.name = `${AUTH_RETURN_PREFIX}${JSON.stringify({
    version: 1,
    token: route.token,
    issuedAt,
    expiresAt: issuedAt + AUTH_RETURN_MAX_AGE_MS,
    previousName,
  })}`;
}

function restoreReviewedAuthReturn() {
  if (!isEmbeddedFrame()) {
    return false;
  }

  const state = consumeAuthReturnState();
  if (!state || !reviewedLogoutDestination()) {
    return false;
  }

  const restoreUrl = new URL(
    getURL("/discussion-bridge/embed/restore"),
    window.location.origin
  );
  restoreUrl.searchParams.set("token", state.token);
  window.location.replace(restoreUrl.toString());
  return true;
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
    if (restoreReviewedAuthReturn()) {
      return;
    }

    if (!attestedMappedRoute()) {
      return;
    }

    document.addEventListener("click", armLogoutReturn, true);

    withPluginApi((api) => {
      const syncClass = () => {
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
