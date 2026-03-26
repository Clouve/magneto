/* ═══════════════════════════════════════════════════════════════════════════
   AI Studio — Clouve
   Main application script

   Reads server-injected session state from window.__SESSION__ and renders
   either the login form or the authenticated app shell with embedded
   /chat (ttyd) and /browser (FileBrowser) iframes.
   ═══════════════════════════════════════════════════════════════════════════ */

(function () {
  "use strict";

  /* ── DOM references ───────────────────────────────────────────────────── */

  var loginView      = document.getElementById("login-view");
  var appView        = document.getElementById("app-view");
  var loginForm      = document.getElementById("login-form");
  var loginBtn       = document.getElementById("login-btn");
  var loginError     = document.getElementById("login-error");
  var usernameIn     = document.getElementById("username");
  var passwordIn     = document.getElementById("password");
  var userAvatar     = document.getElementById("user-avatar");
  var userDisplay    = document.getElementById("user-display");
  var logoutBtn      = document.getElementById("logout-btn");
  var tabChat        = document.getElementById("tab-chat");
  var tabBrowser     = document.getElementById("tab-browser");
  var contentArea    = document.querySelector(".content-area");
  var loadingChat    = document.getElementById("loading-chat");
  var loadingBrowser = document.getElementById("loading-browser");

  var chatFrame      = null;
  var browserFrame   = null;
  var activeTab      = "chat";

  /* ── Utilities ────────────────────────────────────────────────────────── */

  var yrEl = document.getElementById("yr");
  if (yrEl) yrEl.textContent = new Date().getFullYear();

  /* ── View management ──────────────────────────────────────────────────── */

  function showLogin() {
    loginView.style.display = "flex";
    appView.style.display = "none";
    document.body.style.overflow = "auto";
  }

  function showApp(username) {
    userAvatar.textContent = username.charAt(0);
    userDisplay.textContent = username;

    loginView.style.display = "none";
    appView.style.display = "flex";
    document.body.style.overflow = "hidden";

    loadFrames();
    switchTab(activeTab);
  }

  /* ── Authentication API ───────────────────────────────────────────────── */

  function doLogin(username, password) {
    loginBtn.disabled = true;
    loginBtn.textContent = "Signing in\u2026";
    hideError();

    fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: username, password: password }),
      credentials: "same-origin"
    })
      .then(function (res) {
        return res.json().then(function (d) {
          return { ok: res.ok, data: d };
        });
      })
      .then(function (result) {
        loginBtn.disabled = false;
        loginBtn.textContent = "Sign In";
        if (result.ok) {
          showApp(result.data.username);
        } else {
          showError(result.data.error || "Authentication failed");
        }
      })
      .catch(function () {
        loginBtn.disabled = false;
        loginBtn.textContent = "Sign In";
        showError("Unable to reach the server. Please try again.");
      });
  }

  function doLogout() {
    fetch("/api/logout", { method: "POST", credentials: "same-origin" })
      .finally(function () {
        destroyFrames();
        usernameIn.value = "";
        passwordIn.value = "";
        showLogin();
        usernameIn.focus();
      });
  }

  /* ── Error display ────────────────────────────────────────────────────── */

  function showError(msg) {
    loginError.textContent = msg;
    loginError.classList.add("visible");
  }

  function hideError() {
    loginError.classList.remove("visible");
  }

  /* ── Iframe lifecycle ─────────────────────────────────────────────────── */

  function loadFrames() {
    if (!chatFrame) {
      chatFrame = document.createElement("iframe");
      chatFrame.className = "service-frame";
      chatFrame.id = "frame-chat";
      chatFrame.src = "/chat";
      chatFrame.addEventListener("load", function () {
        loadingChat.classList.add("fade-out");
      });
      contentArea.appendChild(chatFrame);
    }

    if (!browserFrame) {
      browserFrame = document.createElement("iframe");
      browserFrame.className = "service-frame hidden";
      browserFrame.id = "frame-browser";
      browserFrame.addEventListener("load", function () {
        loadingBrowser.classList.add("fade-out");
      });
      contentArea.appendChild(browserFrame);
    }
  }

  function destroyFrames() {
    if (chatFrame)    { chatFrame.remove();    chatFrame = null; }
    if (browserFrame) { browserFrame.remove(); browserFrame = null; }
    loadingChat.classList.remove("fade-out");
    loadingBrowser.classList.remove("fade-out");
    loadingChat.classList.remove("hidden");
    loadingBrowser.classList.add("hidden");
  }

  /* ── Tab navigation ───────────────────────────────────────────────────── */

  function switchTab(tab) {
    activeTab = tab;

    tabChat.classList.toggle("active", tab === "chat");
    tabBrowser.classList.toggle("active", tab === "browser");

    if (chatFrame)    chatFrame.classList.toggle("hidden", tab !== "chat");
    if (browserFrame) browserFrame.classList.toggle("hidden", tab !== "browser");

    loadingChat.classList.toggle("hidden",
      tab !== "chat" || loadingChat.classList.contains("fade-out"));
    loadingBrowser.classList.toggle("hidden",
      tab !== "browser" || loadingBrowser.classList.contains("fade-out"));

    // Lazy-load Files iframe on first activation
    if (tab === "browser" && browserFrame && !browserFrame.src) {
      loadingBrowser.classList.remove("hidden");
      browserFrame.src = "/browser";
    }
  }

  /* ── Event binding ────────────────────────────────────────────────────── */

  loginForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var u = usernameIn.value.trim();
    var p = passwordIn.value;
    if (u && p) doLogin(u, p);
  });

  logoutBtn.addEventListener("click", doLogout);

  tabChat.addEventListener("click",    function () { switchTab("chat"); });
  tabBrowser.addEventListener("click", function () { switchTab("browser"); });

  // Handle session-expired notifications from embedded iframes.
  // When nginx auth_request returns 401, the @auth_required fallback page
  // posts a message to the parent frame so we can surface the login form.
  window.addEventListener("message", function (e) {
    if (e.data && e.data.type === "auth-expired") {
      destroyFrames();
      showLogin();
      showError("Your session has expired. Please sign in again.");
    }
  });

  /* ── Initialization ───────────────────────────────────────────────────── */
  //
  // Session state is injected server-side into window.__SESSION__ by the
  // Python auth server. If the user already has a valid session cookie, the
  // server sets it to {"username":"..."} so we skip straight to the app
  // view — no client-side /api/verify fetch needed.
  //
  // Query-string credentials (?username=X&password=Y) are handled entirely
  // server-side: the server validates, sets the cookie, and 302-redirects
  // to "/" (clean URL) so credentials never appear in browser history.

  var session = window.__SESSION__;

  if (session && session.username) {
    showApp(session.username);
  } else {
    showLogin();

    // If redirected after failed query-string authentication, show error
    var params = new URLSearchParams(window.location.search);
    if (params.get("error") === "invalid_credentials") {
      window.history.replaceState({}, "", "/");
      showError("Automatic sign-in failed. Please enter your credentials.");
    }
  }

})();
