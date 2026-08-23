import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

const CSS_CLASS = "discussion-bridge-comments-only";
const SUBMIT_LABEL_ATTRIBUTE = "data-discussion-bridge-submit-label";

function commentsOnlyRequested(url = new URL(window.location.href)) {
  const params = url.searchParams;
  const classes = params.get("class_name")?.split(/\s+/) ?? [];

  return params.get("embed_mode") === "true" && classes.includes(CSS_CLASS);
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
    if (!commentsOnlyRequested()) {
      return;
    }

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
