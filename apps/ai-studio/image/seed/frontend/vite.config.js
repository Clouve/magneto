import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// This dev server is reached two ways, and both must keep working:
//   - through clv-proxy at https://5173-<workspace-id>.<base>/  (deployed)
//   - directly on :5173                                         (local dev)
export default defineConfig({
  plugins: [react()],
  server: {
    // clv-proxy lives in a different pod — a loopback-only dev server is
    // unreachable through it.
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    // The proxied Host is <port>-<workspace-id>.<base> and varies per
    // deployment, so it can't be allowlisted statically. Auth is enforced
    // by clv-proxy before any request reaches this server.
    allowedHosts: true,
    // Same-origin /api: the app fetches relative URLs and Vite forwards them
    // to the Express backend, so the browser stays on one origin in both
    // access modes and the backend needs no CORS config.
    proxy: {
      '/api': { target: 'http://127.0.0.1:4000' },
    },
    // HMR: deliberately NO host/port/protocol override. The Vite client
    // derives the websocket endpoint from the URL the page was loaded over,
    // which is correct in both modes: ws://localhost:5173 directly, and
    // wss://5173-<workspace-id>.<base>:443 through the proxy (clv-proxy
    // passes WebSocket upgrades through).
  },
});
