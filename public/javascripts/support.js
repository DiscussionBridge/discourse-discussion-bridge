(function () {
  "use strict";

  const page = document.body.dataset.supportPage;
  if (page !== "admin" && page !== "workspace") {
    return;
  }

  const announcement = document.getElementById("support-announcement");
  const errorNotice = document.getElementById("support-error");
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  const noticeKey = "discussion-bridge-support-notice";
  const messages = {
    settings:
      "Support setting saved. Sending a request and granting access remain separate actions.",
    request:
      "Request accepted by this forum. Read its native status below; this does not confirm delivery, payment, access or publication.",
    grant: "Scoped support access granted to the named native account.",
    revoke: "Local support access revoked.",
    check:
      "Check requested. Read the current native status below; this does not verify publication.",
    retry:
      "Retry requested. Read the current native status below; this does not verify publication.",
    reconcile:
      "Reconciliation and retry requested. Read the current native status below; this does not verify publication.",
    selection: "Topic selection updated for this connection.",
    synchronize:
      "Synchronization requested. Read the current native status below; this does not verify publication.",
  };
  let busy = false;
  let permissionDenied = false;
  let previewSnapshot = null;
  const requestFields = [
    "contact_email",
    "forum_url",
    "plugin_version",
    "request_id",
    "problem",
  ];
  const requestForm = document.getElementById("support-request-form");
  const preview = document.getElementById("support-request-preview");
  const reviewed = document.getElementById("support-request-reviewed");
  const sendRequest = document.getElementById("support-send-request");

  function announce(message) {
    if (announcement) {
      announcement.textContent = message;
      announcement.hidden = false;
    }
  }

  function showError(message) {
    if (errorNotice) {
      errorNotice.textContent = message;
      errorNotice.hidden = false;
      errorNotice.tabIndex = -1;
      errorNotice.focus();
    }
  }

  function clearError() {
    if (errorNotice) {
      errorNotice.textContent = "";
      errorNotice.hidden = true;
    }
  }

  function refreshAfter(notice) {
    // Retain only a fixed notice key across reloads, never request fields or credentials.
    try {
      window.sessionStorage.setItem(noticeKey, notice);
    } catch {
      // Reload remains available when browser storage is unavailable.
    }
    window.location.reload();
  }

  function fieldValues() {
    return Object.fromEntries(
      requestFields.map((name) => [
        name,
        requestForm.elements.namedItem(name).value.trim(),
      ])
    );
  }

  function invalidatePreview() {
    const hadPreview = previewSnapshot !== null;
    previewSnapshot = null;
    if (preview) {
      preview.hidden = true;
    }
    if (reviewed) {
      reviewed.checked = false;
    }
    if (sendRequest) {
      sendRequest.disabled = true;
    }
    if (hadPreview) {
      announce("Request changed. Review it again before sending.");
    }
  }

  function controlsAvailable() {
    document.querySelectorAll("[data-js-enable]").forEach((control) => {
      const refresh = control.dataset.supportAction === "refresh";
      const available =
        refresh ||
        (!permissionDenied &&
          control.dataset.capabilityUnavailable !== "true" &&
          Boolean(csrfToken));
      control.disabled = busy || !available;
    });
    if (requestForm) {
      const available = requestForm.dataset.requestAvailable === "true";
      const previewButton = requestForm.querySelector(
        '[data-support-action="preview-request"]'
      );
      if (previewButton) {
        previewButton.disabled =
          busy || permissionDenied || !csrfToken || !available;
      }
      sendRequest.disabled =
        busy ||
        permissionDenied ||
        !csrfToken ||
        !available ||
        previewSnapshot === null ||
        !reviewed.checked;
    }
    const grantForm = document.getElementById("support-grant-form");
    if (grantForm) {
      grantForm.querySelector('button[type="submit"]').disabled =
        busy ||
        permissionDenied ||
        !csrfToken ||
        grantForm.dataset.grantAvailable !== "true";
    }
  }

  async function api(path, method, payload) {
    if (!csrfToken) {
      throw new Error(
        "The forum security token is unavailable. Refresh this page before trying again."
      );
    }
    const response = await window.fetch(path, {
      method,
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "X-Requested-With": "XMLHttpRequest",
      },
      body: payload === undefined ? undefined : JSON.stringify(payload),
    });
    let result = null;
    try {
      result = await response.json();
    } catch {
      // Native HTML errors must not be inserted into the page.
    }
    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        permissionDenied = true;
        throw new Error(
          "The forum denied this action. Your session, support setting or access may have changed. Refresh to load the current native permission state."
        );
      }
      const nativeErrors =
        result && Array.isArray(result.errors)
          ? result.errors.filter((item) => typeof item === "string")
          : [];
      throw new Error(
        nativeErrors.length
          ? nativeErrors.join(" ")
          : `The forum could not complete this action (HTTP ${response.status}). Refresh before retrying.`
      );
    }
    return result;
  }

  async function mutate(path, method, payload, notice) {
    if (busy || permissionDenied) {
      return;
    }
    busy = true;
    clearError();
    controlsAvailable();
    try {
      await api(path, method, payload);
      announce(messages[notice]);
      refreshAfter(notice);
    } catch (error) {
      showError(
        error instanceof Error
          ? error.message
          : "The forum could not complete this action. Refresh before retrying."
      );
      busy = false;
      controlsAvailable();
    }
  }

  function requiredData(button, keys) {
    const valid = keys.every(
      (key) =>
        typeof button.dataset[key] === "string" &&
        button.dataset[key].trim() !== ""
    );
    if (!valid) {
      showError(
        "This action is unavailable because current server metadata is missing. Refresh the workspace."
      );
    }
    return valid;
  }

  function connectionPath(button, action) {
    return `/discussion-bridge/support/connections/${encodeURIComponent(button.dataset.connectionId)}/${action}.json`;
  }

  if (requestForm) {
    requestFields.forEach((name) => {
      requestForm.elements
        .namedItem(name)
        .addEventListener("input", invalidatePreview);
      requestForm.elements
        .namedItem(name)
        .addEventListener("change", invalidatePreview);
    });
    reviewed.addEventListener("change", controlsAvailable);
    requestForm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (
        busy ||
        requestForm.dataset.requestAvailable !== "true" ||
        !requestForm.reportValidity()
      ) {
        return;
      }
      const fields = fieldValues();
      if (!reviewed.checked || previewSnapshot !== JSON.stringify(fields)) {
        invalidatePreview();
        showError(
          "Review the current request fields and confirm them before sending."
        );
        return;
      }
      mutate(
        "/discussion-bridge/admin/support/requests.json",
        "POST",
        { support_request: { ...fields, reviewed: true } },
        "request"
      );
    });
  }

  const settingsForm = document.getElementById("support-settings-form");
  if (settingsForm) {
    settingsForm.addEventListener("submit", (event) => {
      event.preventDefault();
      mutate(
        "/discussion-bridge/admin/support.json",
        "PUT",
        {
          support: {
            enabled: document.getElementById("support-enabled").checked,
          },
        },
        "settings"
      );
    });
  }

  const grantForm = document.getElementById("support-grant-form");
  if (grantForm) {
    grantForm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (
        grantForm.dataset.grantAvailable !== "true" ||
        !grantForm.reportValidity()
      ) {
        return;
      }
      mutate(
        "/discussion-bridge/admin/support/grants.json",
        "POST",
        {
          support_grant: {
            username: grantForm.elements.namedItem("username").value.trim(),
          },
        },
        "grant"
      );
    });
  }

  const topicSelectionForm = document.getElementById(
    "support-topic-selection-form"
  );
  if (topicSelectionForm) {
    topicSelectionForm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (busy || permissionDenied || !topicSelectionForm.reportValidity()) {
        return;
      }
      const connectionId =
        topicSelectionForm.elements.namedItem("connection_id").value;
      const topicId = topicSelectionForm.elements
        .namedItem("topic_id")
        .value.trim();
      if (!connectionId || !/^[1-9][0-9]*$/.test(topicId)) {
        return;
      }
      mutate(
        `/discussion-bridge/support/connections/${encodeURIComponent(connectionId)}/select-topic.json`,
        "POST",
        {
          topic_id: topicId,
          selected: topicSelectionForm.elements.namedItem("selected").checked,
        },
        "selection"
      );
    });
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-support-action]");
    if (!button || button.disabled || busy) {
      return;
    }
    const action = button.dataset.supportAction;
    if (action === "refresh") {
      window.location.reload();
      return;
    }
    if (action === "preview-request") {
      if (
        !requestForm ||
        requestForm.dataset.requestAvailable !== "true" ||
        !requestForm.reportValidity()
      ) {
        return;
      }
      clearError();
      const fields = fieldValues();
      preview.querySelectorAll("[data-preview-field]").forEach((item) => {
        item.textContent = fields[item.dataset.previewField];
      });
      reviewed.checked = false;
      previewSnapshot = JSON.stringify(fields);
      preview.hidden = false;
      controlsAvailable();
      document.getElementById("support-preview-heading").focus();
      announce(
        "Request preview ready. Confirm the five fields, then choose Send request."
      );
      return;
    }
    if (action === "revoke-grant") {
      if (requiredData(button, ["grantId"])) {
        mutate(
          `/discussion-bridge/admin/support/grants/${encodeURIComponent(button.dataset.grantId)}.json`,
          "DELETE",
          undefined,
          "revoke"
        );
      }
      return;
    }
    if (!requiredData(button, ["connectionId"])) {
      return;
    }
    if (action === "check") {
      if (!requiredData(button, ["workId", "mappingRevision"])) {
        return;
      }
      if (typeof window.crypto?.randomUUID !== "function") {
        showError(
          "This browser cannot create the required mutation ID. Use a secure forum connection and refresh before trying again."
        );
        return;
      }
      mutate(
        connectionPath(button, "check"),
        "POST",
        {
          mutation_id: window.crypto.randomUUID(),
          selected: [
            {
              work_id: button.dataset.workId,
              mapping_revision: button.dataset.mappingRevision,
            },
          ],
        },
        "check"
      );
    } else if (action === "retry" || action === "reconcile-restored-baseline") {
      if (!requiredData(button, ["inspectionId", "contextSha256"])) {
        return;
      }
      if (typeof window.crypto?.randomUUID !== "function") {
        showError(
          "This browser cannot create the required mutation ID. Use a secure forum connection and refresh before trying again."
        );
        return;
      }
      const settleRestoredBaseline = action === "reconcile-restored-baseline";
      mutate(
        connectionPath(button, "retry"),
        "POST",
        {
          mutation_id: window.crypto.randomUUID(),
          selected: [
            {
              inspection_id: button.dataset.inspectionId,
              context_sha256: button.dataset.contextSha256,
              settle_restored_baseline: settleRestoredBaseline,
            },
          ],
        },
        settleRestoredBaseline ? "reconcile" : "retry"
      );
    } else if (action === "select-topic") {
      if (!requiredData(button, ["topicId", "selected"])) {
        return;
      }
      if (
        button.dataset.selected !== "true" &&
        button.dataset.selected !== "false"
      ) {
        return;
      }
      mutate(
        connectionPath(button, "select-topic"),
        "POST",
        {
          topic_id: button.dataset.topicId,
          selected: button.dataset.selected === "true",
        },
        "selection"
      );
    } else if (action === "synchronize") {
      if (!requiredData(button, ["topicId"])) {
        return;
      }
      mutate(
        connectionPath(button, "synchronize"),
        "POST",
        { topic_id: button.dataset.topicId },
        "synchronize"
      );
    }
  });

  try {
    const notice = window.sessionStorage.getItem(noticeKey);
    window.sessionStorage.removeItem(noticeKey);
    if (Object.prototype.hasOwnProperty.call(messages, notice)) {
      announce(messages[notice]);
    }
  } catch {
    // The pages work without browser storage.
  }
  controlsAvailable();
  if (!csrfToken) {
    showError(
      "The forum security token is unavailable. Refresh this page before making changes."
    );
  }
})();
