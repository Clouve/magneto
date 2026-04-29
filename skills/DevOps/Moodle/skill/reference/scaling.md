# Scaling

Moodle scales horizontally cleanly **only if** every "shared state" surface is actually shared. The list of preconditions is short and load-bearing — getting one wrong causes broken images, lost sessions, or duplicate cron runs.

## Preconditions for horizontal scaling

| Surface | Single-node | Multi-node requirement |
|---|---|---|
| `<dataroot>` | local disk fine | RWX (ReadWriteMany) shared volume — NFS, EFS, Longhorn-RWX, CephFS, GlusterFS |
| `<cachedir>` | local fine | Subdirectory of `<dataroot>` is the natural choice. Or switch MUC application cache to Redis. |
| `<localcachedir>` | local | **per-node**; do NOT share |
| Sessions | DB or file (per node) | Redis (cluster), or DB session handler |
| MUC application cache | file (in `<cachedir>`) | Redis recommended; file works if `<cachedir>` is shared |
| Cron runner | one cron on the single node | one CronJob in K8s (`concurrencyPolicy: Forbid`), OR multiple cron runners with a cluster-safe lock factory |
| Database | single instance | the DB itself is your scaling tier — see [performance.md](performance.md) for read replicas |
| File lock factory | `\core\lock\file_lock_factory` (default) on local disk | DB-backed (`db_record_lock_factory`, `mysql_lock_factory`, `postgres_lock_factory`), OR file factory on a shared mount |

If you set up Moodle with N web pods and any of the above isn't shared, the symptom is not "down" — it's **inconsistent**. User uploads a file, refreshes, gets a 404 sometimes. Logs in, navigates, gets logged out half the time. The intermittent nature is what makes the bug expensive — operators chase it for hours before realizing it's a sharing problem.

## Reference cluster topology

For a Kubernetes deployment with N web pods:

```
                  ┌─────────────────────────────┐
                  │     Ingress / LB            │
                  │     (TLS termination)       │
                  └──────────────┬──────────────┘
                                 │  HTTP   sslproxy=true, reverseproxy=true
              ┌──────────────────┼──────────────────┐
              │                  │                  │
        ┌─────▼─────┐     ┌──────▼─────┐     ┌──────▼─────┐
        │  web-0    │     │  web-1     │ ... │  web-N     │
        │ Apache+   │     │ Apache+    │     │ Apache+    │
        │ mod_php   │     │ mod_php    │     │ mod_php    │
        └─────┬─────┘     └──────┬─────┘     └──────┬─────┘
              │                  │                  │
              ├──────────────────┼──────────────────┤
              │                  │                  │
        ┌─────▼──────┐    ┌──────▼─────────┐    ┌───▼────────┐
        │ moodledata │    │  Redis         │    │  Postgres  │
        │ RWX PVC    │    │  (sessions +   │    │  (primary  │
        │ (filedir/, │    │   MUC app      │    │  + read    │
        │  cache/,   │    │   cache)       │    │  replicas) │
        │  lock/)    │    └────────────────┘    └────────────┘
        └────────────┘

        ┌─────────────────────┐
        │  cron-runner        │  ← K8s CronJob, schedule: "* * * * *"
        │  (admin/cli/cron.   │     concurrencyPolicy: Forbid
        │   php)              │
        └─────────────────────┘
```

Notes:

- `sslproxy = true` and `reverseproxy = true` on every web pod (see [security.md](security.md)).
- `<dataroot>` mounted at `/var/moodledata` on every web pod, RWX. The cron runner pod also mounts it.
- Redis is a single deployment; for HA, use Redis Sentinel or Redis Cluster. Moodle's `cachestore_redis` and `\core\session\redis` both support cluster connection strings.
- Postgres / MariaDB is ONE instance from Moodle's perspective. Read replicas are configured via `dboptions['readonly']` if the workload warrants — see [performance.md](performance.md).
- The cron CronJob is **separate from the web pods**. Reasons: (1) you want exactly one cron runner, not N (where N is the web replica count); (2) you don't want long-running cron tasks to consume web request slots; (3) `concurrencyPolicy: Forbid` ensures a slow run doesn't double up.

## Sticky sessions: needed?

**No, with a shared session store.** When `\core\session\redis` (or `database`) is the session handler, any pod can serve any user's request. Sticky sessions (LB session affinity) are a fallback for the file session handler — and the file session handler doesn't work on a cluster anyway, so sticky sessions are a sign the topology is wrong.

There's one edge case: WebSocket-based features (some BBB integrations, some plugins). Those want sticky for the duration of the socket. The Magneto-shipped Moodle does not have WebSocket features by default.

## Cluster-safe locks

Cron picks a lock factory based on `$CFG->lock_factory`. Defaults to `\core\lock\file_lock_factory` writing to `<dataroot>/lock/`. The choice for a cluster:

| Factory | When |
|---|---|
| `\core\lock\file_lock_factory` | If `<dataroot>/lock/` is on a shared filesystem with working POSIX `flock`. NFS supports flock; EFS supports flock with caveats. |
| `\core\lock\db_record_lock_factory` | Always works. Slight DB overhead. The default-safe choice when in doubt. |
| `\core\lock\mysql_lock_factory` | MariaDB/MySQL `GET_LOCK()`. Fast. Connection-scoped — be careful with persistent connections. |
| `\core\lock\postgres_lock_factory` | Postgres advisory locks. Fast. |

```php
$CFG->lock_factory = '\core\lock\postgres_lock_factory';
```

Test by running cron concurrently from two nodes and watching `mdl_task_log` for double-runs of the same task. There should be none.

## File system: choosing the shared volume

| Option | Pros | Cons |
|---|---|---|
| NFS | Universal; cheap | Latency adds up on many small files; requires NFS server HA |
| AWS EFS | Managed; auto-scale | Latency; cost at scale |
| Longhorn (RWX) | K8s-native; works on-prem | Operational overhead |
| CephFS | Performant on real hardware | Complex |
| Object storage (`tool_objectfs`) for files only, separate volume for cache/lock | Cleanest scale | Plugin dependency, additional moving parts |

For mid-sized schools (up to ~10k DAU), NFS or EFS is the right answer. For very large deployments, `tool_objectfs` offloading `filedir/` to S3 with EFS for the rest is the standard pattern.

## When to scale

Don't scale by default — Moodle on a single beefy node handles a surprising amount of load. Scale when one of:

- **Sustained CPU > 70%** on the web tier during peak hours.
- **PHP-FPM `pm.max_children` saturated** — request queue building up.
- **PHP request rate > ~100/sec** with growing latency.
- **Resilience requirement** — single-pod outage is unacceptable for the institution.

## What changes when you scale

You inherit a longer list of operational concerns:

- **Deployment is no longer "stop the container, swap, start"** — rolling updates expose users to a code-and-DB version skew window.
- **`admin/cli/upgrade.php`** must run on **one** node, with all other web pods either drained or running compatible code.
- **Plugin installs** affect every pod (all read the same DB, but each pod's OPcache must be flushed).
- **Cache stampede** on cold deploy: every pod has empty caches; the first request to a popular URL fans out to N pods all rebuilding the same cache. Pre-warm by hitting the site from a cron-job after deploy.
- **Logs are spread across N pods.** Centralize with Loki / Cloudwatch / equivalent before scaling, not after.

If the user is asking "should I scale?" the right preface to the answer is "what failure mode are you trying to avoid?" — pure traffic load and resilience requirements call for different topologies.

## What does NOT scale by adding pods

- Database write throughput. Adding web pods just amplifies write demand on the single primary.
- The cron runner. There is exactly one (or you accept the lock-factory complexity above).
- Heavy synchronous tasks: course backup and restore, big imports, search index rebuild. These run inside cron / adhoc tasks; throughput is bounded by cron parallelism, not web pod count.
- Bandwidth out of `<dataroot>` for large file downloads. Use `tool_objectfs` with presigned URLs to bypass PHP entirely.
