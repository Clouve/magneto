/* ═══════════════════════════════════════════════════════════════════════════
   AI Studio — Preferences Panel
   Manages AI client selection, execution mode, and API key configuration.
   Exposes window.AIPrefs for integration with app.js.
   ═══════════════════════════════════════════════════════════════════════════ */

(function () {
  "use strict";

  /* ── Client metadata (icon labels and key-acquisition URLs) ────────────── */

  var CLIENT_META = {
    "claude-code": { icon: "C", label: "Anthropic API key (sk-ant-...)", url: "https://console.anthropic.com/settings/keys" },
    "gemini-cli":  { icon: "G", label: "Google Gemini API key (AIza...)", url: "https://aistudio.google.com/apikey" },
    "codex-cli":   { icon: "O", label: "OpenAI API key (sk-...)",        url: "https://platform.openai.com/api-keys" },
  };

  /* ── State ──────────────────────────────────────────────────────────────── */

  var state = {
    clients: [],          // [{id, name}] from server
    selectedClient: null, // client id string
    autoAccept: false,
    apiKeySet: false,
    apiKeyMasked: null,
    forcedClient: null,   // non-null when AI_STUDIO_CLIENT env var is set
    loaded: false,
  };

  /* ── DOM refs (resolved lazily since the script loads with defer) ──────── */

  var panel, cardsContainer, modeGroup, apiKeyInput, keyToggleBtn;
  var eyeShow, eyeHide, keyStatus, keyLink, keyDesc;
  var saveBtn, cancelBtn, messageEl;

  function resolveDOM() {
    panel          = document.getElementById("preferences-panel");
    cardsContainer = document.getElementById("prefs-client-cards");
    modeGroup      = document.getElementById("prefs-mode-group");
    apiKeyInput    = document.getElementById("prefs-api-key");
    keyToggleBtn   = document.getElementById("prefs-key-toggle");
    eyeShow        = document.getElementById("prefs-eye-show");
    eyeHide        = document.getElementById("prefs-eye-hide");
    keyStatus      = document.getElementById("prefs-key-status");
    keyLink        = document.getElementById("prefs-key-link");
    keyDesc        = document.getElementById("prefs-key-desc");
    saveBtn        = document.getElementById("prefs-save-btn");
    cancelBtn      = document.getElementById("prefs-cancel-btn");
    messageEl      = document.getElementById("prefs-message");
  }

  /* ── API helpers ────────────────────────────────────────────────────────── */

  function apiGet(path) {
    return fetch("/_clv" + path, { credentials: "same-origin" })
      .then(function (r) { return r.json(); });
  }

  function apiPut(path, body) {
    return fetch("/_clv" + path, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
    }).then(function (r) { return r.json(); });
  }

  function apiPost(path, body) {
    return fetch("/_clv" + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
    }).then(function (r) { return r.json(); });
  }

  /* ── Render client cards ────────────────────────────────────────────────── */

  function renderClientCards() {
    var section = cardsContainer.parentElement;
    var clientDesc = document.getElementById("prefs-client-desc");
    cardsContainer.innerHTML = "";

    // Remove any previous forced-client info block
    var existingInfo = section.querySelector(".prefs-forced-info");
    if (existingInfo) existingInfo.remove();

    // When AI_STUDIO_CLIENT is set, replace the card selector entirely
    // with a read-only info block showing the assigned client.
    if (state.forcedClient) {
      clientDesc.textContent = "Your workspace is configured to use the following AI coding assistant.";
      var forced = null;
      for (var i = 0; i < state.clients.length; i++) {
        if (state.clients[i].id === state.forcedClient) { forced = state.clients[i]; break; }
      }
      var meta = CLIENT_META[state.forcedClient] || { icon: "?", label: "", url: "" };
      var name = forced ? forced.name : state.forcedClient;

      // Hide the interactive cards container
      cardsContainer.style.display = "none";

      var info = document.createElement("div");
      info.className = "prefs-forced-info";
      info.innerHTML =
        '<div class="prefs-forced-client">' +
          '<div class="prefs-client-icon" data-client="' + state.forcedClient + '">' + meta.icon + '</div>' +
          '<div class="prefs-client-info">' +
            '<div class="prefs-client-name">' + name + '</div>' +
            '<div class="prefs-client-id">' + state.forcedClient + '</div>' +
          '</div>' +
        '</div>' +
        '';
      section.appendChild(info);
      return;
    }

    // Normal mode — render interactive selection cards
    clientDesc.textContent = "Choose which AI coding assistant to use in your terminal session.";
    cardsContainer.style.display = "";

    state.clients.forEach(function (client) {
      var meta = CLIENT_META[client.id] || { icon: "?", label: "", url: "" };
      var card = document.createElement("div");
      card.className = "prefs-client-card" + (state.selectedClient === client.id ? " selected" : "");
      card.setAttribute("data-client", client.id);
      card.setAttribute("role", "radio");
      card.setAttribute("aria-checked", state.selectedClient === client.id ? "true" : "false");
      card.setAttribute("tabindex", "0");

      card.innerHTML =
        '<div class="prefs-client-radio"></div>' +
        '<div class="prefs-client-icon" data-client="' + client.id + '">' + meta.icon + '</div>' +
        '<div class="prefs-client-info">' +
          '<div class="prefs-client-name">' + client.name + '</div>' +
          '<div class="prefs-client-id">' + client.id + '</div>' +
        '</div>';

      card.addEventListener("click", function () {
        selectClient(client.id);
      });
      card.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          selectClient(client.id);
        }
      });

      cardsContainer.appendChild(card);
    });
  }

  function selectClient(clientId) {
    if (state.selectedClient === clientId) return;
    var previousClient = state.selectedClient;
    state.selectedClient = clientId;

    // If switching clients, clear key status since the stored key is for the old client
    if (previousClient && previousClient !== clientId) {
      state.apiKeySet = false;
      state.apiKeyMasked = null;
      apiKeyInput.value = "";
    }

    renderClientCards();
    updateKeySection();
    clearMessage();

    // Fetch current key status for the newly selected client
    if (previousClient !== clientId) {
      checkExistingKey(clientId);
    }
  }

  function checkExistingKey(clientId) {
    // Temporarily save current client, fetch prefs, then check if server has a key for this client
    apiPut("/api/preferences", { client: clientId }).then(function (data) {
      if (data.ok) {
        state.apiKeySet = data.apiKeySet;
        state.apiKeyMasked = data.apiKeyMasked;
        updateKeySection();
      }
    }).catch(function () { /* ignore */ });
  }

  /* ── Update key section based on selected client ────────────────────────── */

  function updateKeySection() {
    var clientId = state.selectedClient;
    var meta = CLIENT_META[clientId] || { label: "API key", url: "" };

    keyDesc.textContent = "Enter your " + meta.label.split(" (")[0] + " for the selected client.";

    if (state.apiKeySet && state.apiKeyMasked && !apiKeyInput.value) {
      keyStatus.textContent = "Key saved: " + state.apiKeyMasked;
      keyStatus.className = "prefs-key-status status-set";
      apiKeyInput.placeholder = state.apiKeyMasked;
    } else if (!state.apiKeySet && !apiKeyInput.value) {
      keyStatus.textContent = "No API key configured for this client.";
      keyStatus.className = "prefs-key-status status-missing";
      apiKeyInput.placeholder = "Paste your API key here";
    } else {
      keyStatus.textContent = "";
      keyStatus.className = "prefs-key-status";
    }

    if (meta.url) {
      keyLink.innerHTML = 'Get a key at <a href="' + meta.url + '" target="_blank" rel="noopener">' + meta.url.replace("https://", "") + '</a>';
    } else {
      keyLink.innerHTML = "";
    }
  }

  /* ── Key visibility toggle ──────────────────────────────────────────────── */

  function bindKeyToggle() {
    keyToggleBtn.addEventListener("click", function () {
      var isPassword = apiKeyInput.type === "password";
      apiKeyInput.type = isPassword ? "text" : "password";
      eyeShow.style.display = isPassword ? "none" : "";
      eyeHide.style.display = isPassword ? "" : "none";
    });
  }

  /* ── Execution mode ─────────────────────────────────────────────────────── */

  function setModeFromState() {
    var radios = modeGroup.querySelectorAll('input[name="exec-mode"]');
    for (var i = 0; i < radios.length; i++) {
      radios[i].checked = (radios[i].value === "auto-accept") === state.autoAccept;
    }
  }

  function getSelectedMode() {
    var radios = modeGroup.querySelectorAll('input[name="exec-mode"]');
    for (var i = 0; i < radios.length; i++) {
      if (radios[i].checked) return radios[i].value === "auto-accept";
    }
    return false;
  }

  /* ── Messages ───────────────────────────────────────────────────────────── */

  function showMessage(type, text) {
    messageEl.textContent = text;
    messageEl.className = "prefs-message msg-" + type;
  }

  function clearMessage() {
    messageEl.textContent = "";
    messageEl.className = "prefs-message";
  }

  /* ── Save ────────────────────────────────────────────────────────────────── */

  function handleSave() {
    if (!state.selectedClient) {
      showMessage("error", "Please select an AI client.");
      return;
    }

    var newKey = apiKeyInput.value.trim();
    if (!state.apiKeySet && !newKey) {
      showMessage("error", "Please enter an API key before saving.");
      return;
    }

    saveBtn.disabled = true;
    saveBtn.textContent = "Saving\u2026";
    clearMessage();

    // If a new key was entered, validate it first
    var saveChain;
    if (newKey) {
      saveChain = apiPost("/api/preferences/validate-key", {
        client: state.selectedClient,
        apiKey: newKey,
      }).then(function (result) {
        if (!result.valid) {
          throw new Error(result.error || "API key validation failed.");
        }
        return apiPut("/api/preferences", {
          client: state.selectedClient,
          autoAccept: getSelectedMode(),
          apiKey: newKey,
        });
      });
    } else {
      saveChain = apiPut("/api/preferences", {
        client: state.selectedClient,
        autoAccept: getSelectedMode(),
      });
    }

    saveChain
      .then(function (data) {
        saveBtn.disabled = false;
        saveBtn.textContent = "Save & Launch Terminal";

        if (data.ok) {
          state.apiKeySet = data.apiKeySet;
          state.apiKeyMasked = data.apiKeyMasked;
          state.autoAccept = data.autoAccept;
          apiKeyInput.value = "";
          updateKeySection();
          showMessage("success", "Preferences saved. Launching terminal\u2026");

          // Notify app.js to switch to terminal view and reload
          setTimeout(function () {
            if (window.AIPrefs && window.AIPrefs.onSave) {
              window.AIPrefs.onSave();
            }
          }, 800);
        } else {
          showMessage("error", data.error || "Failed to save preferences.");
        }
      })
      .catch(function (err) {
        saveBtn.disabled = false;
        saveBtn.textContent = "Save & Launch Terminal";
        showMessage("error", err.message || "An error occurred.");
      });
  }

  /* ── Load preferences from server ───────────────────────────────────────── */

  function loadPreferences(callback) {
    apiGet("/api/preferences")
      .then(function (data) {
        state.clients = data.clients || [];
        state.selectedClient = data.client || null;
        state.autoAccept = data.autoAccept || false;
        state.apiKeySet = data.apiKeySet || false;
        state.apiKeyMasked = data.apiKeyMasked || null;
        state.forcedClient = data.forcedClient || null;
        state.loaded = true;

        renderClientCards();
        setModeFromState();
        updateKeySection();

        if (callback) callback(state);
      })
      .catch(function () {
        // Fallback: use hardcoded client list
        state.clients = [
          { id: "claude-code", name: "Claude Code" },
          { id: "gemini-cli", name: "Gemini CLI" },
          { id: "codex-cli", name: "OpenAI Codex CLI" },
        ];
        state.loaded = true;
        renderClientCards();
        if (callback) callback(state);
      });
  }

  /* ── Initialization ─────────────────────────────────────────────────────── */

  function init() {
    resolveDOM();
    bindKeyToggle();
    saveBtn.addEventListener("click", handleSave);
    cancelBtn.addEventListener("click", function () {
      if (window.AIPrefs && window.AIPrefs.onCancel) {
        window.AIPrefs.onCancel();
      }
    });

    // Clear key status text when user starts typing a new key
    apiKeyInput.addEventListener("input", function () {
      if (apiKeyInput.value) {
        keyStatus.textContent = "";
        keyStatus.className = "prefs-key-status";
      } else {
        updateKeySection();
      }
      clearMessage();
    });
  }

  /* ── Public API (consumed by app.js) ────────────────────────────────────── */

  window.AIPrefs = {
    /** Initialize DOM bindings. Call once after DOMContentLoaded. */
    init: init,

    /** Load preferences from server. Callback receives the state object.
     *  Returns whether this is a first-login (no client configured). */
    load: loadPreferences,

    /** Show the preferences panel. */
    show: function () {
      if (panel) panel.style.display = "";
      clearMessage();
    },

    /** Hide the preferences panel. */
    hide: function () {
      if (panel) panel.style.display = "none";
    },

    /** Whether preferences are configured (client + key). */
    isConfigured: function () {
      return state.loaded && state.selectedClient && state.apiKeySet;
    },

    /** Callbacks set by app.js */
    onSave: null,
    onCancel: null,
  };

})();
