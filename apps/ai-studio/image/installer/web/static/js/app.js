/* ═══════════════════════════════════════════════════════════════════════════
   AI Studio — Clouve
   Main application script

   Reads server-injected session state from window.__SESSION__ and renders
   either the login form or the authenticated app shell with embedded
   /_clv/chat (ttyd) and /_clv/browser (FileBrowser) iframes in a resizable split view.
   ═══════════════════════════════════════════════════════════════════════════ */

(function () {
  "use strict";

  /* ── DOM references ───────────────────────────────────────────────────── */

  var loginView      = document.getElementById("login-view");
  var appView        = document.getElementById("app-view");
  var loginForm      = document.getElementById("login-form");
  var loginBtn       = document.getElementById("login-btn");
  var loginError     = document.getElementById("login-error");
  var loginSuccess   = document.getElementById("login-success");
  var usernameIn     = document.getElementById("username");
  var passwordIn     = document.getElementById("password");
  var resetForm      = document.getElementById("reset-form");
  var resetBtn       = document.getElementById("reset-btn");
  var resetUsername   = document.getElementById("reset-username");
  var recoveryPassIn = document.getElementById("recovery-password");
  var newPassIn      = document.getElementById("new-password");
  var confirmPassIn  = document.getElementById("confirm-password");
  var resetLink     = document.getElementById("reset-password-link");
  var backToLogin    = document.getElementById("back-to-login-link");
  var loginHeading   = document.querySelector(".login-heading");
  var loginSub       = document.querySelector(".login-sub");
  var userAvatar     = document.getElementById("user-avatar");
  var userDisplay    = document.getElementById("user-display");
  var logoutBtn      = document.getElementById("logout-btn");
  var panelBrowser   = document.getElementById("panel-browser");
  var panelChat      = document.getElementById("panel-chat");
  var divider        = document.getElementById("split-divider");
  var splitContainer = document.querySelector(".split-container");
  var layoutBtns     = document.querySelectorAll(".layout-btn");
  var loadingChat    = document.getElementById("loading-chat");
  var loadingBrowser = document.getElementById("loading-browser");

  var settingsBtn    = document.getElementById("settings-btn");
  var panelChatTitle = document.getElementById("panel-chat-title");
  var statusDot      = document.getElementById("terminal-status-dot");

  var chatFrame      = null;
  var browserFrame   = null;
  var currentLayout  = "split";
  var savedSplitFlex = "";  // remembers divider position when leaving split mode
  var prefsVisible   = false;  // whether the preferences panel is shown

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

    // Initialize preferences panel
    if (window.AIPrefs) {
      window.AIPrefs.init();
      window.AIPrefs.onSave = function () {
        hidePreferences();
        reloadTerminal();
      };
      window.AIPrefs.onCancel = function () {
        hidePreferences();
      };

      // Load preferences to check if this is a first-login (no config yet)
      window.AIPrefs.load(function () {
        if (window.AIPrefs.isConfigured()) {
          // Returning user with saved preferences — load everything
          loadFrames();
        } else {
          // First login or incomplete config — load file browser only,
          // defer the terminal until preferences are saved. Starting
          // the terminal now would trigger .bash_profile which attempts
          // client installation before the user has configured anything.
          loadBrowserFrame();
          showPreferences();
        }
      });
    } else {
      loadFrames();
    }
  }

  /* ── Preferences panel toggle ──────────────────────────────────────────── */

  function showPreferences() {
    prefsVisible = true;
    if (window.AIPrefs) window.AIPrefs.show();
    if (chatFrame) chatFrame.style.display = "none";
    loadingChat.style.display = "none";
    settingsBtn.classList.add("active");
    panelChatTitle.textContent = "Preferences";
    statusDot.style.display = "none";
  }

  function hidePreferences() {
    prefsVisible = false;
    if (window.AIPrefs) window.AIPrefs.hide();
    if (chatFrame) chatFrame.style.display = "";
    loadingChat.style.display = "";
    settingsBtn.classList.remove("active");
    panelChatTitle.textContent = "Terminal";
    statusDot.style.display = "";
  }

  function togglePreferences() {
    if (prefsVisible) {
      hidePreferences();
    } else {
      // Reload preferences state when opening
      if (window.AIPrefs) {
        window.AIPrefs.load(function () {
          showPreferences();
        });
      } else {
        showPreferences();
      }
    }
  }

  function reloadTerminal() {
    // Destroy the old iframe and create a fresh one instead of reassigning
    // src. Reassigning src triggers the beforeunload handler inside ttyd's
    // WebSocket connection, which causes the browser's "Leave site?" prompt.
    var chatContent = panelChat.querySelector(".panel-content");
    if (chatFrame) {
      chatFrame.remove();
      chatFrame = null;
    }
    loadingChat.classList.remove("fade-out");

    chatFrame = document.createElement("iframe");
    chatFrame.className = "service-frame";
    chatFrame.id = "frame-chat";
    chatFrame.src = "/_clv/chat";
    chatFrame.addEventListener("load", function () {
      loadingChat.classList.add("fade-out");
    });
    chatContent.appendChild(chatFrame);
  }

  /* ── Authentication API ───────────────────────────────────────────────── */

  function doLogin(username, password) {
    loginBtn.disabled = true;
    loginBtn.textContent = "Signing in\u2026";
    hideMessages();

    fetch("/_clv/api/login", {
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
    fetch("/_clv/api/logout", { method: "POST", credentials: "same-origin" })
      .finally(function () {
        destroyFrames();
        usernameIn.value = "";
        passwordIn.value = "";
        showLogin();
        usernameIn.focus();
      });
  }

  /* ── Error / success display ──────────────────────────────────────────── */

  function showError(msg) {
    loginError.textContent = msg;
    loginError.classList.add("visible");
    loginSuccess.classList.remove("visible");
  }

  function showSuccess(msg) {
    loginSuccess.textContent = msg;
    loginSuccess.classList.add("visible");
    loginError.classList.remove("visible");
  }

  function hideMessages() {
    loginError.classList.remove("visible");
    loginSuccess.classList.remove("visible");
  }

  /* ── Password reset view toggle ────────────────────────────────────── */

  function showResetView() {
    hideMessages();
    loginForm.style.display = "none";
    resetForm.style.display = "";
    loginHeading.textContent = "Reset your password";
    loginSub.textContent = "Enter the recovery password to set a new one for your account.";
    // Carry username across if already entered
    if (usernameIn.value.trim()) {
      resetUsername.value = usernameIn.value.trim();
    }
    recoveryPassIn.focus();
  }

  function showLoginView() {
    hideMessages();
    resetForm.style.display = "none";
    loginForm.style.display = "";
    loginHeading.textContent = "Sign in to your workspace";
    loginSub.textContent = "Enter your credentials to access the terminal and file browser.";
    usernameIn.focus();
  }

  resetLink.addEventListener("click", function (e) { e.preventDefault(); showResetView(); });
  backToLogin.addEventListener("click", function (e) { e.preventDefault(); showLoginView(); });

  /* ── Password reset API ────────────────────────────────────────────── */

  function doResetPassword(username, recoveryPassword, newPassword) {
    resetBtn.disabled = true;
    resetBtn.textContent = "Resetting\u2026";
    hideMessages();

    fetch("/_clv/api/reset-password", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: username,
        recoveryPassword: recoveryPassword,
        newPassword: newPassword
      }),
      credentials: "same-origin"
    })
      .then(function (res) {
        return res.json().then(function (d) {
          return { ok: res.ok, data: d };
        });
      })
      .then(function (result) {
        resetBtn.disabled = false;
        resetBtn.textContent = "Reset Password";
        if (result.ok) {
          // Clear the reset form
          recoveryPassIn.value = "";
          newPassIn.value = "";
          confirmPassIn.value = "";
          // Switch to login view with success message
          showLoginView();
          usernameIn.value = username;
          passwordIn.focus();
          showSuccess("Password reset successfully. Sign in with your new password.");
        } else {
          showError(result.data.error || "Password reset failed");
        }
      })
      .catch(function () {
        resetBtn.disabled = false;
        resetBtn.textContent = "Reset Password";
        showError("Unable to reach the server. Please try again.");
      });
  }

  resetForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var u = resetUsername.value.trim();
    var rp = recoveryPassIn.value;
    var np = newPassIn.value;
    var cp = confirmPassIn.value;

    if (!u || !rp || !np || !cp) return;
    if (np !== cp) {
      showError("Passwords do not match.");
      return;
    }
    if (np.length < 6) {
      showError("New password must be at least 6 characters.");
      return;
    }
    doResetPassword(u, rp, np);
  });

  /* ── Iframe lifecycle ─────────────────────────────────────────────────── */

  function loadBrowserFrame() {
    var browserContent = panelBrowser.querySelector(".panel-content");
    if (!browserFrame) {
      browserFrame = document.createElement("iframe");
      browserFrame.className = "service-frame";
      browserFrame.id = "frame-browser";
      browserFrame.src = "/_clv/browser";
      browserFrame.addEventListener("load", function () {
        loadingBrowser.classList.add("fade-out");
      });
      browserContent.appendChild(browserFrame);
    }
  }

  function loadChatFrame() {
    var chatContent = panelChat.querySelector(".panel-content");
    if (!chatFrame) {
      chatFrame = document.createElement("iframe");
      chatFrame.className = "service-frame";
      chatFrame.id = "frame-chat";
      chatFrame.src = "/_clv/chat";
      chatFrame.addEventListener("load", function () {
        loadingChat.classList.add("fade-out");
      });
      chatContent.appendChild(chatFrame);
    }
  }

  function loadFrames() {
    loadBrowserFrame();
    loadChatFrame();
  }

  function destroyFrames() {
    if (chatFrame)    { chatFrame.remove();    chatFrame = null; }
    if (browserFrame) { browserFrame.remove(); browserFrame = null; }
    loadingChat.classList.remove("fade-out");
    loadingBrowser.classList.remove("fade-out");
    // Reset preferences panel state
    prefsVisible = false;
    if (window.AIPrefs) window.AIPrefs.hide();
    settingsBtn.classList.remove("active");
    panelChatTitle.textContent = "Terminal";
    statusDot.style.display = "";
  }

  /* ── Resizable split divider ──────────────────────────────────────────── */

  var MIN_PANEL_PX = 180;
  var dragging = false;
  var rafId = 0;
  var pendingPct = 0;

  function isVertical() {
    return window.matchMedia("(max-width: 768px)").matches;
  }

  function onDragStart(e) {
    e.preventDefault();
    dragging = true;
    divider.classList.add("active");
    splitContainer.classList.add("is-dragging");

    // Hint the browser to optimise repaints on the resizing panel
    panelBrowser.style.willChange = "flex-basis";

    // Prevent iframes from capturing pointer events during drag
    if (chatFrame)    chatFrame.style.pointerEvents = "none";
    if (browserFrame) browserFrame.style.pointerEvents = "none";

    document.addEventListener("mousemove", onDragMove);
    document.addEventListener("mouseup", onDragEnd);
    document.addEventListener("touchmove", onDragMove, { passive: false });
    document.addEventListener("touchend", onDragEnd);
  }

  function applyDragPosition() {
    rafId = 0;
    panelBrowser.style.flex = "0 0 " + pendingPct + "%";
  }

  function onDragMove(e) {
    if (!dragging) return;
    if (e.cancelable) e.preventDefault();

    var container = panelBrowser.parentElement;
    var rect = container.getBoundingClientRect();
    var clientPos, totalSize;

    if (isVertical()) {
      clientPos = (e.touches ? e.touches[0].clientY : e.clientY) - rect.top;
      totalSize = rect.height;
    } else {
      clientPos = (e.touches ? e.touches[0].clientX : e.clientX) - rect.left;
      totalSize = rect.width;
    }

    var dividerSize = 5;
    var available = totalSize - dividerSize;
    var browserSize = Math.max(MIN_PANEL_PX, Math.min(clientPos, available - MIN_PANEL_PX));
    pendingPct = (browserSize / totalSize) * 100;

    // Coalesce rapid events — only apply once per animation frame
    if (!rafId) {
      rafId = requestAnimationFrame(applyDragPosition);
    }
  }

  function onDragEnd() {
    dragging = false;
    divider.classList.remove("active");

    // Flush any pending frame so the final position is applied
    if (rafId) {
      cancelAnimationFrame(rafId);
      rafId = 0;
      applyDragPosition();
    }

    panelBrowser.style.willChange = "";
    splitContainer.classList.remove("is-dragging");

    if (chatFrame)    chatFrame.style.pointerEvents = "";
    if (browserFrame) browserFrame.style.pointerEvents = "";

    document.removeEventListener("mousemove", onDragMove);
    document.removeEventListener("mouseup", onDragEnd);
    document.removeEventListener("touchmove", onDragMove);
    document.removeEventListener("touchend", onDragEnd);
  }

  // Keyboard support: arrow keys to resize
  divider.addEventListener("keydown", function (e) {
    var step = e.shiftKey ? 5 : 1;
    var container = panelBrowser.parentElement;
    var rect = container.getBoundingClientRect();
    var vertical = isVertical();
    var totalSize = vertical ? rect.height : rect.width;
    var currentPct = (panelBrowser.getBoundingClientRect()[vertical ? "height" : "width"] / totalSize) * 100;

    if ((vertical && e.key === "ArrowDown") || (!vertical && e.key === "ArrowRight")) {
      e.preventDefault();
      var newPct = Math.min(currentPct + step, ((totalSize - 5 - MIN_PANEL_PX) / totalSize) * 100);
      panelBrowser.style.flex = "0 0 " + newPct + "%";
    } else if ((vertical && e.key === "ArrowUp") || (!vertical && e.key === "ArrowLeft")) {
      e.preventDefault();
      var minPct = (MIN_PANEL_PX / totalSize) * 100;
      var newPct2 = Math.max(currentPct - step, minPct);
      panelBrowser.style.flex = "0 0 " + newPct2 + "%";
    }
  });

  divider.addEventListener("mousedown", onDragStart);
  divider.addEventListener("touchstart", onDragStart, { passive: false });

  /* ── Layout mode switcher ─────────────────────────────────────────────── */

  function switchLayout(mode) {
    if (mode === currentLayout) return;

    // Save divider position when leaving split mode
    if (currentLayout === "split") {
      savedSplitFlex = panelBrowser.style.flex || "";
    }

    currentLayout = mode;

    // Clear inline flex so CSS layout-mode rules take full effect
    panelBrowser.style.flex = "";

    splitContainer.setAttribute("data-layout", mode);

    // Update button states
    for (var i = 0; i < layoutBtns.length; i++) {
      var btn = layoutBtns[i];
      var isActive = btn.getAttribute("data-mode") === mode;
      btn.classList.toggle("active", isActive);
      btn.setAttribute("aria-checked", isActive ? "true" : "false");
    }

    // Restore divider position when returning to split mode
    if (mode === "split") {
      panelBrowser.style.flex = savedSplitFlex;
    }
  }

  for (var i = 0; i < layoutBtns.length; i++) {
    layoutBtns[i].addEventListener("click", function () {
      switchLayout(this.getAttribute("data-mode"));
    });
  }

  /* ── Settings button ──────────────────────────────────────────────────── */

  settingsBtn.addEventListener("click", togglePreferences);

  /* ── Event binding ────────────────────────────────────────────────────── */

  loginForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var u = usernameIn.value.trim();
    var p = passwordIn.value;
    if (u && p) doLogin(u, p);
  });

  logoutBtn.addEventListener("click", doLogout);

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
  // view — no client-side /_clv/api/verify fetch needed.
  //
  // Query-string credentials (?username=X&password=Y or ?u=X&p=Y) are
  // handled entirely server-side: the server validates, sets the cookie,
  // and 302-redirects to "/" (clean URL) so credentials never appear in
  // browser history.

  /* ── Forced-client badge update ────────────────────────────────────────── */
  // Title is already set inline in <head>; update badge elements now that
  // the DOM is parsed (this script is deferred).
  var forcedClient = window.__FORCED_CLIENT__;
  if (forcedClient) {
    var loginBadge  = document.getElementById("login-badge");
    var headerBadge = document.getElementById("header-badge");
    var badgeText   = "AI Studio (" + forcedClient + ")";
    if (loginBadge)  loginBadge.textContent  = badgeText;
    if (headerBadge) headerBadge.textContent = badgeText;
  }

  /* ── Initialization ───────────────────────────────────────────────────── */

  var session = window.__SESSION__;

  if (session && session.username) {
    showApp(session.username);
  } else {
    showLogin();

    // If redirected after failed query-string authentication, show error
    var params = new URLSearchParams(window.location.search);
    if (params.get("error") === "invalid_credentials") {
      window.history.replaceState({}, "", "/_clv/");
      showError("Automatic sign-in failed. Please enter your credentials.");
    }
  }

})();
