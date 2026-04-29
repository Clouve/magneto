# File Storage (`moodledata` and the File API)

Moodle stores user-uploaded files in a **content-addressable** layout: every file is keyed by its SHA-1 hash and stored at `<dataroot>/filedir/<first-2-hex>/<second-2-hex>/<full-hash>`. The DB tracks metadata (name, mime, owner, context) in `mdl_files`; the bytes live on disk under that hash.

This means:

- Two identical uploads share one bytes-on-disk entry. Storage is naturally deduplicated.
- A backup that includes only the DB but not `<dataroot>/filedir/` is **broken** — every file reference resolves to a missing path.
- A backup that includes `<dataroot>/filedir/` but not the DB is unreadable — the on-disk bytes are not addressable without the DB metadata.

## `<dataroot>` layout

```
<dataroot>/                      ← $CFG->dataroot — outside the webroot
├── filedir/                     ← user-uploaded files, hashed
│   ├── ab/
│   │   └── cd/
│   │       └── abcd1234...      ← actual file bytes
│   └── ...
├── temp/                        ← $CFG->tempdir; safe to wipe between runs
├── cache/                       ← $CFG->cachedir; MUC file store backing
├── localcache/                  ← $CFG->localcachedir; per-node local cache
├── lock/                        ← $CFG->file_lock_root if using file lock factory
├── sessions/                    ← only when session_handler_class = file
├── trashdir/                    ← deleted-but-recoverable holding pen
├── muc/                         ← MUC config + per-store data
├── models/                      ← analytics ML models, if any
└── upgradelogs/                 ← record of past upgrade runs
```

## File API (the right way to manipulate files)

PHP code reaches files through `\core\file_storage`, instantiated as `get_file_storage()`. Every file is identified by a **6-tuple**:

| Field | What it means |
|---|---|
| `contextid` | The Moodle context that owns the file (a course, a course module, a user, the system) |
| `component` | The frankenstyle of the plugin storing the file (`mod_assign`, `user`, `tool_filedirmig`) |
| `filearea` | The plugin's named bucket for these files (`'submission_files'`, `'icon'`, `'private'`) |
| `itemid` | A foreign key into the plugin's own data (e.g. assignment submission id) |
| `filepath` | A virtual path inside the bucket, ending with `/`. Default `'/'`. |
| `filename` | The user-visible filename. `'.'` denotes the directory entry. |

```php
$fs = get_file_storage();
$file = $fs->get_file($contextid, 'mod_assign', 'submission_files', $itemid, '/', 'essay.pdf');
$content = $file->get_content();          // returns bytes
$file->copy_content_to('/tmp/essay.pdf'); // writes to disk
$fs->delete_area_files($contextid, 'mod_assign', 'submission_files', $itemid);
```

The base classes live in [public/lib/filestorage/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/filestorage). The autoloaded counterpart `\core_files\file_system` is the storage backend swap point — see below.

## Pluggable file system

`$CFG->alternative_file_system_class` (line ~1198 of [config-dist.php](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php)) lets the operator swap the local-filesystem backend for one of:

| Backend | Plugin |
|---|---|
| Local filesystem | (default — class `\core_files\file_system_filedir`) |
| Amazon S3 / S3-compatible | community plugin `tool_objectfs` (https://github.com/catalyst/moodle-tool_objectfs) — production-grade, supports S3, Azure Blob, Swift, GCS |
| Filesystem with offload to a tier | Same plugin in "presigned" / "offloaded" modes |

`tool_objectfs` is the de-facto choice when `<dataroot>/filedir/` outgrows a single PVC. It can be configured to:

- **Pull-through cache:** new uploads land on local disk, with a separate scheduled task moving cold files to S3.
- **Offload only:** uploads go straight to S3.
- **Presigned redirects:** Moodle redirects users directly to a presigned S3 URL for downloads, bypassing PHP entirely. Massive bandwidth saver.

Operator implications:

- The plugin requires its own scheduled task to move files between tiers.
- Permissions, encryption-at-rest, and lifecycle rules live on the bucket — Moodle assumes write access works.
- The presigned-URL mode uses `wwwroot`-relative URLs; if the bucket is in a different region the latency tradeoff changes.

## Why `moodledata` MUST be on a shared volume in a cluster

Every PHP request might need to read or write `<dataroot>`:

- Render a course image → read from `filedir/<hash>/...`
- A user uploads a file → write to `filedir/`, then DB row in `mdl_files`
- MUC application cache (file store) → read/write `<cachedir>/`
- Session handler (file mode) → read/write `<sessions>/`
- File lock factory → read/write `<lock>/`

If two Moodle web pods don't share `<dataroot>`, file uploads on pod A become 404s on pod B. The whole site appears broken half the time.

For Kubernetes: a `ReadWriteMany` PVC (NFS, EFS, Longhorn RWX, etc.) for `<dataroot>`. The Magneto-shipped Moodle is single-pod today; if the user asks about scaling, this is the load-bearing constraint to surface — see [scaling.md](scaling.md).

## Permissions

```
<dataroot>/                       0770 www-data:www-data
<dataroot>/filedir/<2hex>/<2hex>/ 0770 www-data:www-data
<dataroot>/filedir/<2hex>/<2hex>/<hash>  0660 www-data:www-data
```

`$CFG->directorypermissions = 02777` and `$CFG->filepermissions = 0666` are the defaults that Moodle uses when **creating** new directories/files (not what it expects on existing files). The setgid bit `02xxx` is intentional — keeps new files inheriting the group ownership.

If you find files in `<dataroot>` owned by a different user (e.g. `root`), it's usually because cron ran via root once: `sudo -u www-data` was forgotten. Fix: `chown -R www-data:www-data <dataroot>`.

## Garbage collection

Files in `mdl_files` whose `filearea` no longer references them (e.g. a deleted assignment submission) get cleaned up by the `\core\task\file_temp_cleanup_task` and the file-storage retention logic. There is **no** filesystem-level cleanup — orphan bytes-on-disk that no DB row references can accumulate over years if `mdl_files` is mutated by hand.

Diagnostic:

```sql
-- Files that exist in mdl_files (the DB sees them):
SELECT COUNT(*), SUM(filesize) FROM mdl_files WHERE filename != '.';
```

Compared to `du -sb <dataroot>/filedir/` on disk. Big divergence = orphans (or vice-versa, missing files).

## `tempdir`, `cachedir`, `localcachedir` — when to override

`<dataroot>` is the default location for all three. Override only if you have a reason:

- **`$CFG->tempdir`**: e.g. mount a faster scratch filesystem (NVMe) for backup/restore performance.
- **`$CFG->cachedir`**: e.g. point at a shared NFS mount on a cluster while keeping `<dataroot>` per-node — but this is rare; usually `<dataroot>` IS the shared mount.
- **`$CFG->localcachedir`**: e.g. point at `/var/local/cache` on each node so the local accelerator survives `<dataroot>` mounts being slow. **Per-node, NOT shared.**

If you override these, **the old paths are not garbage-collected automatically.** Move the contents over (or accept that they'll be re-warmed) and remove the old path.

## What "the file system is broken" looks like

| Symptom | Likely cause |
|---|---|
| 500 on every page after a deploy | `<dataroot>` not writable by web user |
| Some images load, others 404 with no obvious pattern | Cluster pods don't share `<dataroot>` |
| File uploads "succeed" but downloads return 0 bytes | Wrong `directorypermissions` / `filepermissions` and PHP can't read what it just wrote |
| `Cannot create directory $CFG->dataroot/filedir/...` in error log | Out of disk; `<dataroot>` filesystem is full |
| Course backup / restore fails with "Cannot write to backup_temp" | `<backuptempdir>` not writable, or out of disk |
