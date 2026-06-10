# Operational notes — @SLUG@

One line per non-obvious decision, newest last (convention: ISO date prefix).

- 2026-06-10 Project seeded at image build time from `apps/ai-studio/image/seed/` (Clouve/magneto); `node_modules` baked into the /home snapshot, so first boot needs no npm install.
- 2026-06-10 Ports: frontend 5173, API 4000, mongo-express 8081 (all 0.0.0.0 — required for clv-proxy reachability); mongod 27017 loopback-only.
- 2026-06-10 Supervision: supervisord programs `frontend`, `backend`, `mongo-express`, `mongod` in /opt/clouve/supervisord.d/ (persistent); no systemd in this container.
- 2026-06-10 Frontend→API origin: Vite `server.proxy` forwards `/api` to 127.0.0.1:4000 so the browser stays same-origin in both access modes; backend therefore has no CORS config. If you point the frontend at the API's own `https://4000-…` origin instead, add a CORS allowlist to the backend.
- 2026-06-10 Vite `server.hmr` left unset on purpose: the client infers ws endpoint from the page URL, which works both direct (:5173) and through clv-proxy (wss/443). `allowedHosts: true` because the proxied Host varies per deployment; auth lives at clv-proxy.
- 2026-06-10 MongoDB auth OFF; the 127.0.0.1 bind is the security boundary. Enable `security.authorization` before binding any non-loopback interface (mern skill rule).
- 2026-06-10 mongo-express basic auth OFF on purpose — every clv-proxy port already sits behind the workspace login.
- 2026-06-10 Backend dev runner is `node --env-file=.env --watch src/server.js` (no nodemon); restart `backend` after editing `.env`.
