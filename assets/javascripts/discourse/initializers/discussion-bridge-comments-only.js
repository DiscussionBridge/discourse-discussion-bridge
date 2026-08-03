import { withPluginApi } from "discourse/lib/plugin-api";

const CSS_CLASS = "discussion-bridge-comments-only";

function commentsOnlyRequested() {
  const params = new URLSearchParams(window.location.search);
  const classes = params.get("class_name")?.split(/\s+/) ?? [];

  return params.get("embed_mode") === "true" && classes.includes(CSS_CLASS);
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
        });
      };

      api.onPageChange(syncClass);
      syncClass();
    });
  },
};
