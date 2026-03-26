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
import secrets
import signal
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

# Path to the SPA HTML file (read once at startup, session data injected per-request)
HTML_PATH = "/clouve/ai-studio/installer/web/index.html"
AUTH_REQUIRED_PATH = "/clouve/ai-studio/installer/web/auth-required.html"

# Marker in the HTML that gets replaced with session JSON on each request.
# The raw HTML contains:  window.__SESSION__ = /*__SESSION_DATA__*/null;
# For authenticated users it becomes e.g.:  window.__SESSION__ = {"username":"admin"};
SESSION_MARKER = "/*__SESSION_DATA__*/null"

# In-memory session store: token -> {"username": str, "created": float}
sessions = {}

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


class AuthHandler(BaseHTTPRequestHandler):
    """Handles page serving, login, logout, and session verification."""

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            self._handle_page(parsed.query)
        elif path == "/api/verify":
            self._handle_verify()
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

        page = html_template.replace(SESSION_MARKER, session_json)

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

    def _handle_auth_required(self):
        self.send_response(401)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(auth_required_template.encode("utf-8"))

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
