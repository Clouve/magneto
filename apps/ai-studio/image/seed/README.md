# @SLUG@ — MERN starter

A minimal full-stack app that ships pre-installed and already running on this
AI Studio workspace: a React (Vite) frontend, an Express API, and a MongoDB
collection, wired end-to-end. It exists so there is a live app to iterate on
from the first message — extend it, gut it, or replace it.

## What it does

A notes list. The React page fetches `/api/v1/notes`, Express reads/writes the
`notes` collection in the `@SLUG@` database, and the page round-trips adds and
deletes through the same route.

## Layout

```
backend/    Express 5 + Mongoose API — src/server.js, src/routes/, src/models/, .env
frontend/   React 19 + Vite — src/App.jsx, vite.config.js
README.md   this file
NOTES.md    operational decisions, one dated line each
```

## How it runs

Everything is supervised by `supervisord` (PID 1 of this container — there is
no systemd here). The stack comes up on every boot with no manual steps:

| Service | Port | Bind | supervisord program |
|---|---|---|---|
| Vite dev server (HMR) | 5173 | 0.0.0.0 | `frontend` |
| Express API (watch mode) | 4000 | 0.0.0.0 | `backend` |
| mongo-express (DB browser) | 8081 | 0.0.0.0 | `mongo-express` |
| MongoDB 7.0 | 27017 | 127.0.0.1 only | `mongod` |

```bash
sudo supervisorctl status                  # what's running
sudo supervisorctl restart backend         # bounce a service
sudo tail -f /var/log/supervisor/backend.log
```

Program definitions live in `/opt/clouve/supervisord.d/*.conf` (persistent —
edits survive pod restarts).

## Reaching it

Deployed, each HTTP port is served through clv-proxy at
`https://<port>-<workspace-id>.<base>/` behind the workspace login — frontend
on `5173`, API on `4000`, mongo-express on `8081`. The browser app stays on
one origin: Vite proxies `/api` to the backend (see `vite.config.js`).

MongoDB itself never leaves loopback. Browse data with mongo-express, or for
native clients (`mongosh`, Compass) tunnel: 

```bash
ssh -L 27017:localhost:27017 -p <NodePort> clouve-ops@nodes.<base>
```

## Dev loop

Source edits apply themselves: Vite hot-reloads the frontend, `node --watch`
restarts the backend. Backend config (port, Mongo URL) lives in
`backend/.env`; restart the backend after changing it.
