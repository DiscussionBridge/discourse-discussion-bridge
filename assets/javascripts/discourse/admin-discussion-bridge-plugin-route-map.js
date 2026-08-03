export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("discussion-bridge-health", { path: "health" });
    this.route("discussion-bridge-operations", { path: "operations" });
    this.route("discussion-bridge-reconciliation", { path: "reconciliation" });
  },
};
