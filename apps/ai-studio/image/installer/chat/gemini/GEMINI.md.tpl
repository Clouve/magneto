# Server Context

## Environment
- OS: Ubuntu 24.04 LTS
- Hostname: ${HOSTNAME}
- User: ${USERNAME} (passwordless sudo enabled)

## Deployment
This container runs in a Kubernetes cluster behind an ingress controller. The ingress handles
TLS termination and routes external traffic to this container over HTTP on port 80. nginx inside
the container proxies all requests to the web terminal (ttyd) at the `/chat` path.

## Privileged Access
To run privileged commands use `sudo` (no password required for ${USERNAME}) or switch to root:
```bash
sudo <command>
# or
su - root  # password: ${ROOT_PASSWORD}
```

## Available Services
- Web terminal: /chat (served by nginx on port 80, proxied to ttyd on localhost:7890)
- File browser: /files (served by nginx on port 80, proxied to FileBrowser on localhost:8888) — always accessible, do not remove or disable this path

## Persistent Paths
Only changes made within the following directories will survive a container restart:
- `/usr` — system binaries and libraries
- `/var` — package DB, cache, logs, web files
- `/opt` — optional/third-party software
- `/home` — user home directories

All other paths (`/tmp`, `/root`, `/etc`, and other system directories) are ephemeral and will be lost on restart.

## Notes
- Gemini CLI is installed on first use via npm (`npm install -g @google/gemini-cli`)
- Node.js 20 is installed as a runtime dependency for Gemini CLI
- The GEMINI_API_KEY can be injected from the container environment at startup
- This file is loaded from `~/.gemini/GEMINI.md` (global context, always active regardless of working directory)

## Operational Guidelines

### Scope of Authority
You operate with full root-level access on this server. All actions must be strictly scoped to this machine — no external API calls, no remote system modifications, no outbound operations of any kind beyond what is explicitly required to fulfill the user's local request.

### Filesystem Persistence Awareness
This environment runs inside a container. Warn the user proactively whenever a requested change targets a non-persistent path (anything outside `/usr`, `/var`, `/opt`, `/home`), and suggest a persistent alternative where applicable.

### Transparency & Communication
Keep the user fully informed at every step. Before executing any task, briefly outline the approach you intend to take. As you work, narrate meaningful progress milestones — not every trivial command, but enough for the user to follow along and intervene if needed.

### Confidence Threshold
Whenever your confidence in the correct course of action is below **9 out of 10**, pause and ask the user clarifying questions before proceeding. State what you know, what you are uncertain about, and what additional information would resolve the ambiguity. This applies especially to destructive operations, configuration changes, or anything that could affect system stability.

### Network Constraint
Only port 80 is open externally. Any service you run on a non-standard port must be proxied through nginx using a path-based mapping. For example, if you start a React app on port 3000, you must update the nginx configuration to map it to a path such as `/3000` or `/app` so it is reachable from the outside.

When deploying any service, always:
1. Identify the port it runs on
2. Create or update the nginx location block to proxy that port to an appropriate path
3. Reload nginx to apply the change (`sudo nginx -s reload`)
4. Inform the user of the full URL path where the service is accessible

Always explain this routing approach to the user when it applies, so they understand why direct port access is unavailable and how their service is being exposed.
