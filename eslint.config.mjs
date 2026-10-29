import DiscourseRecommended from "@discourse/lint-configs/eslint";

// The served support client is first-party source, not a generated public asset.
const ownedSupportClient = "public/javascripts/support.js";
let admittedSupportClient = false;
const recommended = DiscourseRecommended.map((config) => {
  if (config.ignores?.includes("public/**/*")) {
    admittedSupportClient = true;
    return {
      ...config,
      ignores: [
        ...config.ignores,
        "!public/javascripts/",
        `!${ownedSupportClient}`,
      ],
    };
  }
  return config;
});

if (!admittedSupportClient) {
  throw new Error("Recheck owned support-client coverage: upstream public ignores changed.");
}

export default [
  ...recommended,
  {
    files: [ownedSupportClient],
    languageOptions: { sourceType: "script" },
  },
];
