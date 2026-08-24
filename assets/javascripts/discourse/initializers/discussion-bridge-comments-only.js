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
const OWNED_ATTRIBUTES = ["aria-label", "title", SUBMIT_LABEL_ATTRIBUTE];
const initializedDocuments = new WeakSet();
const ownedElements = new Set();
const ownedState = new WeakMap();

function commentsOnlyRequested(url = new URL(window.location.href)) {
  const params = url.searchParams;
  const classes = params.get("class_name")?.split(/\s+/) ?? [];

  return params.get("embed_mode") === "true" && classes.includes(CSS_CLASS);
}

function attributeState(element, name) {
  return {
    present: element.hasAttribute(name),
    value: element.getAttribute(name),
  };
}

function applyAttributeState(element, name, state) {
  if (state.present) {
    element.setAttribute(name, state.value ?? "");
  } else {
    element.removeAttribute(name);
  }
}

function restoreSubmitControl(button) {
  const state = ownedState.get(button);
  if (!state) {
    return;
  }

  OWNED_ATTRIBUTES.forEach((name) =>
    applyAttributeState(button, name, state.original[name]),
  );
  ownedElements.delete(button);
  ownedState.delete(button);
}

function restoreSubmitControls() {
  [...ownedElements].forEach(restoreSubmitControl);
}

function restoreRemovedSubmitControls(node) {
  if (!(node instanceof Element)) {
    return;
  }

  [...ownedElements].forEach((button) => {
    if (node === button || node.contains(button)) {
      restoreSubmitControl(button);
    }
  });
}

function captureExternalAttributeChange(button, attributeName) {
  const state = ownedState.get(button);
  if (!state || !OWNED_ATTRIBUTES.includes(attributeName)) {
    return;
  }

  const current = attributeState(button, attributeName);
  const expected = state.expected[attributeName];
  if (
    current.present === expected.present &&
    current.value === expected.value
  ) {
    return;
  }

  state.original[attributeName] = current;
}

function labelSubmitControls() {
  const eligible = new Set(
    document.querySelectorAll(
      ".embed-mode-composer .docked-composer__submit-btn",
    ),
  );
  [...ownedElements].forEach((button) => {
    if (!eligible.has(button)) {
      restoreSubmitControl(button);
    }
  });

  eligible.forEach((button) => {
      let state = ownedState.get(button);
      if (!state) {
        state = {
          original: Object.fromEntries(
            OWNED_ATTRIBUTES.map((name) => [
              name,
              attributeState(button, name),
            ]),
          ),
          expected: {},
        };
        ownedState.set(button, state);
        ownedElements.add(button);
      }

      const editing = button
        .closest(".embed-mode-composer")
        ?.querySelector(".embed-mode-composer__editing");
      const label = i18n(
        editing
          ? "discussion_bridge.composer_save_edit"
          : "discussion_bridge.composer_submit",
      );
      OWNED_ATTRIBUTES.forEach((name) => {
        state.expected[name] = { present: true, value: label };
        if (button.getAttribute(name) !== label) {
          button.setAttribute(name, label);
        }
      });
  });
}

function currentEmbedRoute() {
  return `${window.location.pathname}${window.location.search}${window.location.hash}`;
}

function discourseBasePath() {
  const base = document
    .querySelector("meta[name='discourse-base-uri']")
    ?.getAttribute("content");
  if (!base) {
    return "";
  }

  const pathname = new URL(base, window.location.origin).pathname;
  return pathname === "/" ? "" : pathname.replace(/\/$/, "");
}

function topicIdFromPath(pathname = window.location.pathname) {
  const basePath = discourseBasePath();
  if (/%(?:2f|5c)/i.test(pathname) || pathname.includes("\\")) {
    return null;
  }
  if (basePath && !pathname.startsWith(`${basePath}/`)) {
    return null;
  }

  const relativePath = basePath ? pathname.slice(basePath.length) : pathname;
  if (!relativePath.startsWith("/")) {
    return null;
  }

  const segments = relativePath.split("/");
  segments.shift();
  if (segments.at(-1) === "") {
    segments.pop();
  }
  if (segments.some((segment) => segment === "")) {
    return null;
  }
  if (segments[0] !== "t" || segments.length < 2 || segments.length > 4) {
    return null;
  }

  const numeric = (value) => /^[1-9]\d*$/.test(value ?? "");
  if (numeric(segments[1])) {
    return segments.length <= 3 &&
      (segments.length === 2 || numeric(segments[2]))
      ? segments[1]
      : null;
  }

  return segments.length >= 3 &&
    numeric(segments[2]) &&
    (segments.length === 3 || numeric(segments[3]))
    ? segments[2]
    : null;
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
    if (initializedDocuments.has(document)) {
      return;
    }

    const topicId = serverAttestedCompletedMapping();
    const token = new URL(window.location.href).searchParams.get(
      "discussion_bridge_embed_token",
    );
    if (!commentsOnlyRequested() || !topicId || !token) {
      return;
    }

    initializedDocuments.add(document);

    withPluginApi((api) => {
      const qualification = { topicId, token };
      let animationFrame = null;
      let observing = false;
      let listening = false;
      const clickHandler = (event) =>
        interceptLogoutRefresh(event, qualification);
      let observer;

      const startObservation = () => {
        if (observing) {
          return;
        }
        observer.observe(document.body, {
          attributes: true,
          attributeFilter: [...OWNED_ATTRIBUTES, "class"],
          childList: true,
          subtree: true,
        });
        observing = true;
      };

      const setListening = (active) => {
        if (active === listening) {
          return;
        }
        document[active ? "addEventListener" : "removeEventListener"](
          "click",
          clickHandler,
          true,
        );
        listening = active;
      };

      const syncPresentation = () => {
        if (animationFrame !== null) {
          return;
        }
        animationFrame = window.requestAnimationFrame(() => {
          animationFrame = null;
          const qualified =
            document.body.classList.contains("embed-mode") &&
            matchesQualifiedMapping(qualification);
          document.documentElement.toggleAttribute(
            ATTESTED_ATTRIBUTE,
            qualified,
          );
          if (qualified) {
            labelSubmitControls();
            startObservation();
          } else {
            restoreSubmitControls();
            observer.disconnect();
            observing = false;
          }
          setListening(qualified);
        });
      };

      observer = new MutationObserver((mutations) => {
        mutations
          .filter((mutation) => mutation.type === "attributes")
          .forEach((mutation) =>
            captureExternalAttributeChange(
              mutation.target,
              mutation.attributeName,
            ),
          );
        mutations.forEach((mutation) => {
          mutation.removedNodes.forEach(restoreRemovedSubmitControls);
        });
        syncPresentation();
      });
      api.onPageChange(() => {
        startObservation();
        syncPresentation();
      });
      startObservation();
      syncPresentation();
    });
  },
};
