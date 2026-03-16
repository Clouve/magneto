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

## Notes
- Home directory is persisted across container restarts via a Docker volume mounted at /home
- Claude Code is pre-installed globally via npm (Node.js 22)

## Responsibilities
You have full root access to this machine and are responsible for managing it entirely.

**Network constraint:** Only port 80 is open externally. Any service you run on a non-standard port must be proxied through nginx using a path-based mapping. For example, if you start a React app on port 3000, you must update the nginx configuration to map it to a path such as `/3000` or `/app` so it is reachable from the outside.

When deploying any service, always:
1. Identify the port it runs on
2. Create or update the nginx location block to proxy that port to an appropriate path
3. Reload nginx to apply the change (`sudo nginx -s reload`)
4. Inform the user of the full URL path where the service is accessible

Always explain this routing approach to the user when it applies, so they understand why direct port access is unavailable and how their service is being exposed.
