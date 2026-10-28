import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

// Run with DISCUSSIONBRIDGE_PINNED_CORE_SOURCES to exercise the actual cached
// Core Base/Custom renderer classes. Without it, only the local API seam runs.
// Neither mode loads Ember/DOM or establishes installed/browser qualification.
const snapshots = process.env.DISCUSSIONBRIDGE_PINNED_CORE_SOURCES;
const source = readFileSync(new URL("../../assets/javascripts/discourse/initializers/discussion-bridge-attention-notifications.js", import.meta.url), "utf8");
const stripImports = (text) => text.replace(/^import .*?;\r?\n/gm, "");
const i18n = (key) => `translated:${key}`;
let Custom;
let Base;
if (snapshots) {
  const base = readFileSync(path.join(snapshots, "CORE_PINNED_NOTIFICATION_BASE.js"), "utf8");
  Base = new Function("trustHTML", "emojiUnescape", "userPath", "formatUsername", "postUrl", "i18n",
    stripImports(base).replace("export default class NotificationTypeBase", "return class NotificationTypeBase"))(
    (value) => value, (value) => value, (value) => `/u/${value}`, (value) => value,
    (slug, id, post) => `/t/${slug}/${id}/${post}`, i18n,
  );
  const custom = readFileSync(path.join(snapshots, "CORE_PINNED_NOTIFICATION_CUSTOM.js"), "utf8");
  Custom = new Function("NotificationTypeBase", "i18n",
    stripImports(custom).replace("export default class", "return class"))(Base, i18n);
} else {
  Base = class {
    constructor({ notification }) { this.notification = notification; }
    get linkHref() { return this.notification.topic_id ? `/t/topic/${this.notification.topic_id}` : undefined; }
    get label() { return this.notification.data.display_username; }
    get description() { return this.notification.data.topic_title; }
  };
  Custom = class extends Base {
    get linkTitle() { return this.notification.data.title ? i18n(this.notification.data.title) : undefined; }
    get icon() { return `notification.${this.notification.data.message}`; }
  };
}
console.log(`Core renderer context: ${snapshots ? "actual cached Base/Custom sources; dependency seams" : "standalone API seam"}`);
const MESSAGE = "discussion_bridge.attention_notice";
const PANEL = "/admin/plugins/discourse-discussion-bridge/connections";
function setup(basePath = "") {
  const registrations = [];
  const withPluginApi = (callback) => callback({
    registerNotificationTypeRenderer(type, factory) { registrations.push({ type, factory }); },
  });
  const getURL = (url) => `${basePath}${url}`;
  const initializer = new Function("withPluginApi", "CustomNotification", "i18n", "getURL",
    stripImports(source).replace("export default", "return"))(withPluginApi, Custom, i18n, getURL);
  initializer.initialize();
  assert.equal(registrations.length, 1);
  assert.equal(registrations[0].type, "custom");
  return registrations[0].factory(Base);
}
function notification(data, extra = {}) {
  return { notification_type: 14, data, read: false, ...extra };
}
function render(Klass, value) {
  return new Klass({ notification: value, currentUser: { id: 1 },
    siteSettings: { prioritize_full_name_in_ux: false }, site: { notificationLookup: { 14: "custom" } } });
}

test("attention notice uses the protected panel and meaningful translated text", () => {
  const value = notification({ message: MESSAGE, title: MESSAGE });
  const before = structuredClone(value);
  const renderer = render(setup(), value);
  assert.equal(renderer.linkHref, PANEL);
  assert.equal(renderer.label, i18n(MESSAGE));
  assert.equal(renderer.linkTitle, i18n(MESSAGE));
  assert.equal(renderer.description, null);
  assert.equal(renderer.icon, "triangle-exclamation");
  assert.deepEqual(value, before);
});
test("attention panel link preserves a Discourse subfolder", () => {
  assert.equal(render(setup("/community"), notification({ message: MESSAGE, title: MESSAGE })).linkHref, `/community${PANEL}`);
});
test("payload cannot redirect attention notice or render a private title", () => {
  const renderer = render(setup(), notification({ message: MESSAGE, title: MESSAGE,
    link: "https://attacker.example/", topic_title: "private title", display_username: "private author" }, { topic_id: 999 }));
  assert.equal(renderer.linkHref, PANEL);
  assert.equal(renderer.label, i18n(MESSAGE));
  assert.equal(renderer.description, null);
});
for (const [name, extra] of [["topic", { topic_id: 42, slug: "existing", post_number: 3 }],
  ["generic", {}], ["read", { read: true }]]) {
  test(`unrelated custom ${name} notification retains Core behavior`, () => {
    const value = notification({ message: "another_plugin.notice", title: "another_plugin.title",
      topic_title: "existing description", display_username: "existing-user" }, extra);
    const actual = render(setup(), value), expected = render(Custom, value);
    for (const key of ["linkHref", "linkTitle", "label", "description", "icon"]) assert.equal(actual[key], expected[key], key);
  });
}
test("a similar message name cannot take over the attention renderer", () => {
  const value = notification({ message: `${MESSAGE}.suffix`, title: "another.title" }, { topic_id: 42, slug: "ordinary", post_number: 1 });
  assert.equal(render(setup(), value).linkHref, render(Custom, value).linkHref);
});
test("reading the notice changes no publishing authority or data", () => {
  const value = notification({ message: MESSAGE, title: MESSAGE });
  const renderer = render(setup(), value);
  value.read = true;
  assert.equal(renderer.linkHref, PANEL);
  assert.deepEqual(value.data, { message: MESSAGE, title: MESSAGE });
});
