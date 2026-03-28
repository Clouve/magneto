#!/usr/bin/env python3
"""
AI Studio Authentication Server

Single entry point for authentication and page delivery:
  GET  /               — Serves the SPA with server-side session injection.
                          If ?username=X&password=Y (or ?u=X&p=Y) query params
                          are present, validates credentials and 302-redirects
                          with a session cookie (credentials never reach the
                          browser). Long form takes precedence over shorthand.
  POST /api/login      — JSON credential validation, sets session cookie.
  POST /api/logout     — Clears session cookie.
  GET  /api/verify     — Returns 200 + X-Auth-User if session valid, else 401.
                          Used by nginx auth_request to gate /_clv/chat and /_clv/browser.
  GET  /auth-required  — Returns 401 with a page that redirects to login or
                          notifies the parent frame via postMessage (for iframes).

Note: nginx rewrites strip the /_clv prefix before forwarding to this server,
so all paths here remain unprefixed.

Validates OS credentials against /etc/shadow using crypt (Python 3.12 stdlib).
No external dependencies.
"""

import crypt
import json
import os
import pwd
import secrets
import signal
import subprocess
import sys
import time
import warnings
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

# Suppress crypt deprecation warning (removed in 3.13, fine on 3.12)
warnings.filterwarnings("ignore", category=DeprecationWarning, module="crypt")

LISTEN_ADDR = "127.0.0.1"
LISTEN_PORT = 7892
SESSION_TTL = 86400  # 24 hours

# Runtime file where the auto-detected external hostname is cached.
# Written on the first external request so shell sessions can read it
# as a fallback when AI_STUDIO_HOST is not set via environment variable.
DETECTED_HOST_FILE = "/run/clouve/detected_host"

# Path to the SPA HTML file (read once at startup, session data injected per-request)
HTML_PATH = "/clouve/ai-studio/installer/web/index.html"
AUTH_REQUIRED_PATH = "/clouve/ai-studio/installer/web/auth-required.html"

# Marker in the HTML that gets replaced with session JSON on each request.
# The raw HTML contains:  window.__SESSION__ = /*__SESSION_DATA__*/null;
# For authenticated users it becomes e.g.:  window.__SESSION__ = {"username":"admin"};
SESSION_MARKER = "/*__SESSION_DATA__*/null"
FORCED_CLIENT_MARKER = "/*__FORCED_CLIENT_DATA__*/null"

# In-memory session store: token -> {"username": str, "created": float}
sessions = {}

# Tracks the last detected host to avoid redundant file writes.
_cached_detected_host = None

# HTML templates loaded at startup
html_template = ""
auth_required_template = ""


def validate_credentials(username, password):
    """Validate credentials against /etc/shadow using crypt."""
    try:
        with open("/etc/shadow", "r") as f:
            for line in f:
                parts = line.strip().split(":")
                if parts[0] == username:
                    stored_hash = parts[1]
                    if stored_hash in ("*", "!", "!!", ""):
                        return False
                    return crypt.crypt(password, stored_hash) == stored_hash
    except (IOError, PermissionError):
        return False
    return False


def get_session_token(cookie_header):
    """Extract clv_session token from Cookie header."""
    if not cookie_header:
        return None
    for part in cookie_header.split(";"):
        part = part.strip()
        if part.startswith("clv_session="):
            return part[len("clv_session="):]
    return None


def get_session(cookie_header):
    """Return the session dict if valid, else None."""
    token = get_session_token(cookie_header)
    if token and token in sessions:
        session = sessions[token]
        if time.time() - session["created"] < SESSION_TTL:
            return session
        else:
            del sessions[token]
    return None


def create_session(username):
    """Create a new session and return the token."""
    if len(sessions) > 100:
        # Lazy cleanup
        now = time.time()
        expired = [t for t, s in sessions.items() if now - s["created"] > SESSION_TTL]
        for t in expired:
            del sessions[t]

    token = secrets.token_urlsafe(32)
    sessions[token] = {"username": username, "created": time.time()}
    return token


def _detect_and_cache_host(host_header):
    """Persist the external hostname from the HTTP Host header for shell sessions.

    Only acts when AI_STUDIO_HOST was not explicitly provided as an
    environment variable.  Writes the detected value to DETECTED_HOST_FILE
    and updates /etc/profile.d/clouve-env.sh so new login shells inherit it.
    """
    global _cached_detected_host

    # Explicit env var takes precedence — never override it.
    if os.environ.get("AI_STUDIO_HOST"):
        return

    if not host_header:
        return

    # Ignore direct container-internal requests (e.g. curl from inside the
    # container to 127.0.0.1:7892).  "localhost" is kept because it is a
    # valid external hostname in local Docker development.
    host_name = host_header.split(":")[0]
    if host_name in ("127.0.0.1", ""):
        return

    # Skip redundant writes when the value hasn't changed.
    if host_header == _cached_detected_host:
        return
    _cached_detected_host = host_header

    try:
        os.makedirs(os.path.dirname(DETECTED_HOST_FILE), exist_ok=True)
        with open(DETECTED_HOST_FILE, "w") as f:
            f.write(host_header)
        # Also update profile.d so new terminal sessions export it.
        _update_profile_env("AI_STUDIO_HOST", host_header)
    except OSError:
        pass  # best-effort — don't break the request


# ── Client registry (mirrors CLV_IDS / CLV_KEY_VARS / CLV_KEY_FILES in .bash_profile) ──
CLIENT_REGISTRY = [
    {
        "id": "claude-code",
        "name": "Claude Code",
        "keyVar": "ANTHROPIC_API_KEY",
        "keyFile": ".claude_api_key",
        "validateUrl": "https://api.anthropic.com/v1/models",
        "validateHeaders": lambda key: {
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        },
        "validateParams": None,
    },
    {
        "id": "gemini-cli",
        "name": "Gemini CLI",
        "keyVar": "GEMINI_API_KEY",
        "keyFile": ".gemini_api_key",
        "validateUrl": "https://generativelanguage.googleapis.com/v1beta/models",
        "validateHeaders": None,
        "validateParams": lambda key: f"key={key}",
    },
    {
        "id": "codex-cli",
        "name": "OpenAI Codex CLI",
        "keyVar": "OPENAI_API_KEY",
        "keyFile": ".openai_api_key",
        "validateUrl": "https://api.openai.com/v1/models",
        "validateHeaders": lambda key: {"Authorization": f"Bearer {key}"},
        "validateParams": None,
    },
]

CLIENT_BY_ID = {c["id"]: c for c in CLIENT_REGISTRY}

PREFERENCES_FILE = "preferences.json"
PREFERENCES_DIR = ".ai-studio"


def _get_user_home(username):
    """Return the home directory for the given OS user."""
    try:
        return pwd.getpwnam(username).pw_dir
    except KeyError:
        return f"/home/{username}"


def _prefs_path(username):
    """Return the full path to the user's preferences.json."""
    home = _get_user_home(username)
    return os.path.join(home, PREFERENCES_DIR, PREFERENCES_FILE)


def _read_prefs(username):
    """Read the user's preferences. Returns dict or empty dict."""
    path = _prefs_path(username)
    if os.path.isfile(path):
        try:
            with open(path, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def _write_prefs(username, prefs):
    """Write the user's preferences to disk."""
    path = _prefs_path(username)
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    with open(path, "w") as f:
        json.dump(prefs, f, indent=2)
    # Ensure the user owns the directory and file
    home = _get_user_home(username)
    prefs_dir = os.path.join(home, PREFERENCES_DIR)
    try:
        pw = pwd.getpwnam(username)
        os.chown(prefs_dir, pw.pw_uid, pw.pw_gid)
        os.chown(path, pw.pw_uid, pw.pw_gid)
    except (KeyError, OSError):
        pass


def _read_api_key(username, client_id):
    """Read the stored API key for a client. Returns the key string or None."""
    client = CLIENT_BY_ID.get(client_id)
    if not client:
        return None
    home = _get_user_home(username)
    key_path = os.path.join(home, client["keyFile"])
    if os.path.isfile(key_path):
        try:
            with open(key_path, "r") as f:
                return f.read().strip()
        except IOError:
            pass
    return None


def _write_api_key(username, client_id, api_key):
    """Write the API key to the client's key file and update /etc/profile.d/."""
    client = CLIENT_BY_ID.get(client_id)
    if not client:
        return
    home = _get_user_home(username)
    key_path = os.path.join(home, client["keyFile"])
    with open(key_path, "w") as f:
        f.write(api_key)
    os.chmod(key_path, 0o600)
    try:
        pw = pwd.getpwnam(username)
        os.chown(key_path, pw.pw_uid, pw.pw_gid)
    except (KeyError, OSError):
        pass

    # Update /etc/profile.d/clouve-env.sh so the terminal session picks it up
    _update_profile_env(client["keyVar"], api_key)


def _update_profile_env(var_name, value):
    """Add or update an environment variable in /etc/profile.d/clouve-env.sh."""
    env_file = "/etc/profile.d/clouve-env.sh"
    lines = []
    found = False
    if os.path.isfile(env_file):
        with open(env_file, "r") as f:
            for line in f:
                if line.startswith(f"export {var_name}="):
                    lines.append(f"export {var_name}={value}\n")
                    found = True
                else:
                    lines.append(line)
    if not found:
        lines.append(f"export {var_name}={value}\n")
    with open(env_file, "w") as f:
        f.writelines(lines)


def _mask_key(key):
    """Mask an API key, showing only last 6 characters."""
    if not key or len(key) <= 6:
        return key
    return "\u2022" * 8 + key[-6:]


def _validate_api_key(client_id, api_key):
    """Validate an API key against the provider's API.

    Returns: {"valid": True/False, "error": str or None}
    """
    client = CLIENT_BY_ID.get(client_id)
    if not client:
        return {"valid": False, "error": "Unknown client"}

    url = client["validateUrl"]
    if client["validateParams"]:
        url += "?" + client["validateParams"](api_key)

    cmd = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        url, "--max-time", "10", "--connect-timeout", "5",
    ]
    if client["validateHeaders"]:
        for k, v in client["validateHeaders"](api_key).items():
            cmd.extend(["-H", f"{k}: {v}"])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        status = result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError):
        return {"valid": False, "error": "Network error — could not reach provider API"}

    if status == "200":
        return {"valid": True, "error": None}
    elif status == "000":
        return {"valid": False, "error": "Network error — could not reach provider API"}
    else:
        return {"valid": False, "error": f"Key rejected by provider (HTTP {status})"}


class AuthHandler(BaseHTTPRequestHandler):
    """Handles page serving, login, logout, session verification, and preferences."""

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            self._handle_page(parsed.query)
        elif path == "/api/verify":
            self._handle_verify()
        elif path == "/api/preferences":
            self._handle_get_preferences()
        elif path == "/auth-required":
            self._handle_auth_required()
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            self._handle_login()
        elif path == "/api/logout":
            self._handle_logout()
        elif path == "/api/reset-password":
            self._handle_reset_password()
        elif path == "/api/preferences/validate-key":
            self._handle_validate_key()
        else:
            self.send_error(404)

    def do_PUT(self):
        path = urlparse(self.path).path
        if path == "/api/preferences":
            self._handle_put_preferences()
        else:
            self.send_error(404)

    def _handle_page(self, query_string):
        """Serve the SPA with session state injected server-side.

        If ?username=X&password=Y query params are present, validate
        credentials and 302-redirect to "/" with a session cookie set.
        Shorthand aliases ?u=X&p=Y are also accepted; the long form
        takes precedence if both are provided. This keeps credentials
        out of browser history entirely — the redirect happens before
        the page renders.

        Security note: passing credentials via query string is intended
        for controlled, internal, or automated use cases only. Credentials
        may appear in server access logs and HTTP Referer headers.
        """
        # Auto-detect the external hostname from the Host header so
        # shell sessions can reference it without a hardcoded env var.
        _detect_and_cache_host(self.headers.get("Host"))

        # Check for query-string credentials (auto-login)
        if query_string:
            params = parse_qs(query_string)
            # Long form takes precedence over shorthand (?u, ?p)
            qs_user = params.get("username", params.get("u", [None]))[0]
            qs_pass = params.get("password", params.get("p", [None]))[0]

            if qs_user and qs_pass:
                if validate_credentials(qs_user, qs_pass):
                    token = create_session(qs_user)
                    self.send_response(302)
                    self.send_header("Location", "/_clv/")
                    self.send_header(
                        "Set-Cookie",
                        f"clv_session={token}; Path=/; HttpOnly; SameSite=Strict",
                    )
                    self.end_headers()
                    return
                else:
                    # Invalid query-string credentials — serve page with error
                    # hint via a query param the JS can read (no sensitive data)
                    self.send_response(302)
                    self.send_header("Location", "/_clv/?error=invalid_credentials")
                    self.end_headers()
                    return

        # Resolve session and inject into HTML
        session = get_session(self.headers.get("Cookie"))
        if session:
            session_json = json.dumps({"username": session["username"]})
        else:
            session_json = "null"

        # Inject forced client display name so the page title and badges
        # are correct from first paint (even on the login screen).
        forced_id = os.environ.get("AI_STUDIO_CLIENT") or None
        forced_entry = CLIENT_BY_ID.get(forced_id) if forced_id else None
        forced_client_json = json.dumps(forced_entry["name"]) if forced_entry else "null"

        page = html_template.replace(SESSION_MARKER, session_json)
        page = page.replace(FORCED_CLIENT_MARKER, forced_client_json)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(page.encode("utf-8"))

    def _handle_login(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
            username = str(data.get("username", "")).strip()
            password = str(data.get("password", ""))
        except (json.JSONDecodeError, AttributeError):
            self._send_json(400, {"error": "Invalid request body"})
            return

        if not username or not password:
            self._send_json(400, {"error": "Username and password are required"})
            return

        if validate_credentials(username, password):
            token = create_session(username)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header(
                "Set-Cookie",
                f"clv_session={token}; Path=/; HttpOnly; SameSite=Strict",
            )
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "username": username}).encode())
        else:
            self._send_json(401, {"error": "Invalid username or password"})

    def _handle_verify(self):
        session = get_session(self.headers.get("Cookie"))
        if session:
            self.send_response(200)
            self.send_header("X-Auth-User", session["username"])
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Unauthorized")

    def _handle_logout(self):
        token = get_session_token(self.headers.get("Cookie"))
        if token:
            sessions.pop(token, None)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header(
            "Set-Cookie",
            "clv_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        )
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True}).encode())

    def _handle_reset_password(self):
        """Reset the OS password for a user.

        Requires the initial AI_STUDIO_PASSWORD (env var) as a recovery
        password. This value is set at container startup and persists even
        if the user later changes their password via `passwd` in the terminal.
        """
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
            username = str(data.get("username", "")).strip()
            recovery_password = str(data.get("recoveryPassword", ""))
            new_password = str(data.get("newPassword", ""))
        except (json.JSONDecodeError, AttributeError):
            self._send_json(400, {"error": "Invalid request body"})
            return

        if not username or not recovery_password or not new_password:
            self._send_json(400, {"error": "All fields are required"})
            return

        if len(new_password) < 6:
            self._send_json(400, {"error": "New password must be at least 6 characters"})
            return

        # Verify the recovery password matches the initial AI_STUDIO_PASSWORD
        expected = os.environ.get("AI_STUDIO_PASSWORD", "changeme")
        if recovery_password != expected:
            self._send_json(401, {"error": "Invalid recovery password"})
            return

        # Verify the username exists on the system
        try:
            pwd.getpwnam(username)
        except KeyError:
            self._send_json(401, {"error": "Invalid recovery password"})
            return

        # Change the OS password via chpasswd
        try:
            result = subprocess.run(
                ["chpasswd"],
                input=f"{username}:{new_password}",
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode != 0:
                self._send_json(500, {"error": "Failed to update password"})
                return
        except (subprocess.TimeoutExpired, OSError):
            self._send_json(500, {"error": "Failed to update password"})
            return

        # Invalidate all existing sessions for this user
        expired = [t for t, s in sessions.items() if s["username"] == username]
        for t in expired:
            del sessions[t]

        self._send_json(200, {"ok": True})

    def _handle_auth_required(self):
        self.send_response(401)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(auth_required_template.encode("utf-8"))

    # ── Preferences API ─────────────────────────────────────────────────────

    def _require_session(self):
        """Return session dict if authenticated, else send 401 and return None."""
        session = get_session(self.headers.get("Cookie"))
        if not session:
            self._send_json(401, {"error": "Authentication required"})
            return None
        return session

    def _handle_get_preferences(self):
        """Return the user's preferences and API key status."""
        session = self._require_session()
        if not session:
            return

        username = session["username"]
        prefs = _read_prefs(username)

        # When AI_STUDIO_CLIENT is set, it overrides the user's client choice
        forced_client = os.environ.get("AI_STUDIO_CLIENT") or None
        if forced_client and forced_client in CLIENT_BY_ID:
            client_id = forced_client
        else:
            forced_client = None  # unrecognised value — ignore
            client_id = prefs.get("client")

        api_key_set = False
        api_key_masked = None
        if client_id:
            key = _read_api_key(username, client_id)
            if key:
                api_key_set = True
                api_key_masked = _mask_key(key)

        self._send_json(200, {
            "client": client_id,
            "autoAccept": prefs.get("autoAccept", False),
            "apiKeySet": api_key_set,
            "apiKeyMasked": api_key_masked,
            "forcedClient": forced_client,
            "clients": [
                {"id": c["id"], "name": c["name"]} for c in CLIENT_REGISTRY
            ],
        })

    def _handle_put_preferences(self):
        """Update the user's preferences (client, autoAccept, apiKey)."""
        session = self._require_session()
        if not session:
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, AttributeError):
            self._send_json(400, {"error": "Invalid request body"})
            return

        username = session["username"]
        prefs = _read_prefs(username)

        # When AI_STUDIO_CLIENT is set, the client selection is locked
        forced_client = os.environ.get("AI_STUDIO_CLIENT") or None
        if forced_client and forced_client not in CLIENT_BY_ID:
            forced_client = None

        # Update client selection
        client_id = data.get("client")
        if client_id is not None:
            if client_id not in CLIENT_BY_ID:
                self._send_json(400, {"error": f"Unknown client: {client_id}"})
                return
            if forced_client and client_id != forced_client:
                self._send_json(400, {"error": f"Client is locked to {forced_client} by AI_STUDIO_CLIENT"})
                return
            prefs["client"] = client_id

        # Update auto-accept mode
        if "autoAccept" in data:
            prefs["autoAccept"] = bool(data["autoAccept"])

        # Update API key if provided
        api_key = data.get("apiKey")
        if api_key and prefs.get("client"):
            _write_api_key(username, prefs["client"], api_key)

        _write_prefs(username, prefs)

        # Return updated state
        current_client = prefs.get("client")
        key = _read_api_key(username, current_client) if current_client else None

        self._send_json(200, {
            "ok": True,
            "client": current_client,
            "autoAccept": prefs.get("autoAccept", False),
            "apiKeySet": bool(key),
            "apiKeyMasked": _mask_key(key) if key else None,
        })

    def _handle_validate_key(self):
        """Validate an API key against the provider without saving it."""
        session = self._require_session()
        if not session:
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, AttributeError):
            self._send_json(400, {"error": "Invalid request body"})
            return

        client_id = data.get("client")
        api_key = data.get("apiKey")

        if not client_id or not api_key:
            self._send_json(400, {"error": "client and apiKey are required"})
            return

        if client_id not in CLIENT_BY_ID:
            self._send_json(400, {"error": f"Unknown client: {client_id}"})
            return

        result = _validate_api_key(client_id, api_key)
        self._send_json(200, result)

    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        """Suppress per-request log noise."""
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in a separate thread for concurrent iframe loads."""
    daemon_threads = True


def main():
    global html_template, auth_required_template

    # Load HTML templates once at startup
    if not os.path.isfile(HTML_PATH):
        print(f"[ERROR] HTML file not found: {HTML_PATH}")
        sys.exit(1)

    with open(HTML_PATH, "r", encoding="utf-8") as f:
        html_template = f.read()

    if SESSION_MARKER not in html_template:
        print(f"[WARNING] Session marker not found in {HTML_PATH} — "
              "server-side session injection will not work.")

    if os.path.isfile(AUTH_REQUIRED_PATH):
        with open(AUTH_REQUIRED_PATH, "r", encoding="utf-8") as f:
            auth_required_template = f.read()
    else:
        print(f"[WARNING] Auth-required page not found: {AUTH_REQUIRED_PATH}")
        auth_required_template = "<html><body><p>Authentication required. <a href='/_clv/'>Sign in</a></p></body></html>"

    server = ThreadedHTTPServer((LISTEN_ADDR, LISTEN_PORT), AuthHandler)

    def shutdown_handler(signum, frame):
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print(f"[INFO] Auth server listening on {LISTEN_ADDR}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
