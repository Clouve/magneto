# AI Studio — expose user-built apps via an in-pod reverse proxy

## Goal

Today `apps/ai-studio/` is a blank Ubuntu workspace reachable only on port 22
(internal SSH for the Magneto Agent). Anything the agent stands up inside the
pod — a Node server, a Python service, a Postgres, a custom daemon — has no
public endpoint. The user can be told it's running, but can't open a browser
or a client and actually use it.

Turn AI Studio into a multi-app application server: any service the agent
brings up inside the pod becomes reachable from outside the pod under a
stable, predictable URL or port, with no per-app marketplace changes.

## Requirements

1. **HTTP front door (nginx).** Multiple web apps coexist behind one nginx
   process. Each registered app maps a hostname or path prefix to an upstream
   `127.0.0.1:<port>`. Language/framework is irrelevant — nginx accepts the
   inbound connection from the Clouve ingress and forwards over loopback.

2. **Non-HTTP apps.** Apps that aren't HTTP (a TCP daemon, a binary protocol)
   must still be reachable. Use nginx's `stream {}` module for L4 forwarding
   from a *pre-declared* range of external ports to loopback ports. The
   external range is baked into `clv-docker-compose.yml` so the Clouve
   synthesizer publishes it on the Service/Ingress.

3. **Persistence across restarts.** `/etc/nginx` lives on the image rootfs
   (NOT in the four persistent volumes `/home /usr /opt /var`). Canonical
   config tree must live under `/opt/clouve/nginx/{http.d,stream.d,sites}/`
   and be symlinked into `/etc/nginx/conf.d/` and `/etc/nginx/stream.d/` by
   `installer/entrypoint.sh` on every container start. Symlink + reload is
   idempotent.

4. **Agent-driven registration.** The ai-studio skill drives this — the agent
   should never hand-edit nginx.conf. Ship a single CLI baked into the image:

       clv-app register <slug> --port <loopback-port> \
                               [--host <subdomain> | --path <prefix>]
       clv-app unregister <slug>
       clv-app list

   Drops a server-block fragment under `/opt/clouve/nginx/sites/<slug>.conf`,
   `nginx -t`, `nginx -s reload`. Exit non-zero on validation failure so the
   agent gets clean feedback. Update the ai-studio skill in
   `magneto-skills/plugins/ai-studio/` to teach the agent to call this and
   nothing else (per the cross-cutting change rule in
   [../../CLAUDE.md](../../CLAUDE.md): image change + skill change ship together).

5. **TLS stays at the ingress.** The Clouve ingress already terminates TLS
   (cert-manager + ZeroSSL / Let's Encrypt — see the "Untrusted TLS
   certificates break WebSocket" note in [../../CLAUDE.md](../../CLAUDE.md)).
   nginx inside the pod must NOT re-terminate. Listen on plain HTTP on the
   public port, forward plain HTTP to loopback. WebSocket upgrades (Upgrade /
   Connection headers) must pass through untouched — this is the single most
   common AI-Studio user case (Node dev servers, ttyd, notebooks).

## Manifest changes

[clv-docker-compose.yml](clv-docker-compose.yml) currently has
`x-clouve-metadata.isPublic: false` and no published HTTP port. Required edits:

- `isPublic: true` (or add a second container metadata block if SSH should
  stay internal while only HTTP/L4 ports go public — design decision below).
- `applicationUrl` env var so the synthesizer wires the deployment hostname
  through, the same pattern WordPress / Moodle use.
- A declared L4 port range (proposal: `30000-30010`, 10 ports) for non-HTTP
  apps, surfaced as a service-level annotation the synthesizer reads.
- Healthcheck stays TCP/22 (sshd is still PID 1); nginx liveness is its own
  thing and shouldn't gate sshd.

`docker-compose.yml` mirrors the same published ports for local dev so
`./start.sh ai-studio` produces the same shape on a developer laptop as in
production.

## Open design questions (brainstorm before coding)

- **HTTP routing scheme.** Subdomain (`<slug>.<deployment-host>`) or path
  (`<deployment-host>/<slug>/`)?
  - Subdomain → cleanest URLs and root-relative apps work unchanged, but
    needs wildcard DNS + wildcard cert per tenant (cert-issuer strategy
    impact — recheck `dev` vs `selfsigned` for kind).
  - Path → trivial DNS/cert story, but most frameworks assume root-relative
    paths and break under `/slug/`.
  - Recommendation: subdomain, with path as a documented fallback for the
    "I have a static blob to serve" case.

- **Port allocation for HTTP apps.** Does the agent pick the loopback port, or
  does `clv-app register` auto-allocate from a pool? Auto is friendlier (no
  state in the agent's head) but a deterministic explicit port is easier to
  debug when the agent reports "I started it on 3001."
  Recommendation: agent picks, `clv-app register --port` is required; the
  CLI rejects collisions.

- **Default landing page.** Unmapped hostname → 404, or → a status page
  listing what `clv-app list` would print? The status page is friendly but
  leaks app slugs publicly. 404 is safer.

- **L4 port range size.** 10 is enough for the foreseeable AI-Studio workload
  (DBs, MQs, dev daemons). Growing it later means a marketplace re-deploy of
  the affected tenant — acceptable.

- **Cleanup on `unregister`.** Drop the server-block fragment only, or also
  stop the upstream systemd unit? Keep it nginx-only — the agent owns
  process lifecycle separately (the MERN skill already does this via
  `systemd --user`).

## Suggested first PR (in `magneto`)

1. Add `nginx` + `libnginx-mod-stream` to [image/Dockerfile](image/Dockerfile).
2. Create `/opt/clouve/nginx/` skeleton in the image; wire the
   symlink-into-/etc step into [image/installer/entrypoint.sh](image/installer/entrypoint.sh).
3. Ship `/usr/local/bin/clv-app` (POSIX sh; ~80 lines) for `register /
   unregister / list / reload`.
4. Update [clv-docker-compose.yml](clv-docker-compose.yml) and
   [docker-compose.yml](docker-compose.yml) with the public HTTP port and the
   L4 range; flip `isPublic`.
5. Smoke test on docker-compose: `./start.sh ai-studio`, ssh in as
   `clouve-ops`, run a `python3 -m http.server 3001`, `clv-app register demo
   --port 3001 --host demo`, curl through the published port. Verify
   WebSocket upgrade end-to-end (the cert footgun above).

## Companion PR (in `magneto-skills`)

Update `plugins/ai-studio/SKILL.md`:
- Add a "Publishing an app" section: `clv-app register` is the only sanctioned
  path; never edit nginx.conf.
- Document the subdomain scheme and how to communicate URLs back to the user.
- Note the L4 range cap so the agent doesn't promise more ports than exist.
