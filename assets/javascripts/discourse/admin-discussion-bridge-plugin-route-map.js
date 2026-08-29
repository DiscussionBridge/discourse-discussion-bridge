export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("discussion-bridge-health", { path: "overview" });
    this.route("discussion-bridge-connections", { path: "connections" });
    this.route("discussion-bridge-operations", { path: "bridge-records" });
    this.route("discussion-bridge-reconciliation", { path: "reconciliation" });
  },
};
