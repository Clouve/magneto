# ownCloud Application Bundle

This directory contains the production-ready ownCloud application bundle for the Clouve platform.

## Overview

ownCloud is a powerful, open-source file sync and share platform that enables businesses to securely store, access, and collaborate on files from anywhere. This bundle includes:

- **ownCloud Server**: The main application container based on the official `owncloud/server` image
- **MariaDB**: Database container for persistent data storage
- **Redis**: Caching layer for improved performance

## Architecture

The bundle follows the established Clouve patterns:

- Custom Dockerfile extending the official ownCloud image
- Non-invasive entrypoint wrapper at `/clouve/app/installer/entrypoint.sh`
- Automatic initialization on first run
- Production-ready configuration with health checks
- Persistent volumes for data and database

## Container Structure

### Main Application Container (`owncloud`)
- **Base Image**: `owncloud/server:10.16.6`
- **Port**: 8080 (HTTP)
- **Purpose**: Frontend application server
- **Data Volume**: `/mnt/data` - stores all ownCloud files and configuration

### Database Container (`owncloud-mariadb`)
- **Base Image**: `mariadb:12.3`, with gosu rebuilt from source as in the other database images
- **Port**: 3306
- **Purpose**: Database server
- **Data Volume**: `/var/lib/mysql` - stores database files

### Cache Container (`owncloud-redis`)
- **Base Image**: `redis:6`
- **Port**: 6379
- **Purpose**: Caching layer
- **Data Volume**: `/data` - stores Redis cache data

## Environment Variables

### ownCloud Application
- `OWNCLOUD_DOMAIN`: The domain where ownCloud is accessible (e.g., `http://localhost:8080`)
- `OWNCLOUD_TRUSTED_DOMAINS`: Comma-separated list of trusted domains
- `OWNCLOUD_ADMIN_USERNAME`: Admin username for initial setup
- `OWNCLOUD_ADMIN_PASSWORD`: Admin password for initial setup
- `OWNCLOUD_DB_TYPE`: Database type (mysql)
- `OWNCLOUD_DB_HOST`: Database host (container reference)
- `OWNCLOUD_DB_NAME`: Database name
- `OWNCLOUD_DB_USERNAME`: Database username
- `OWNCLOUD_DB_PASSWORD`: Database password
- `OWNCLOUD_MYSQL_UTF8MB4`: Enable UTF8MB4 support (true)
- `OWNCLOUD_REDIS_ENABLED`: Enable Redis caching (true)
- `OWNCLOUD_REDIS_HOST`: Redis host (container reference)

### MariaDB Database
- `MYSQL_DATABASE`: Database name
- `MYSQL_USER`: Database user
- `MYSQL_PASSWORD`: Database password
- `MYSQL_ROOT_PASSWORD`: Root password
- `MARIADB_AUTO_UPGRADE`: Enable automatic upgrades (1)

## Files

```
owncloud/
├── README.md                          # This file
├── logo.png                           # ownCloud logo
├── docker-compose.yml                 # Local development/testing compose file
├── clv-docker-compose.yml            # Production compose file with Clouve metadata
└── image/
    ├── Dockerfile                     # Main application Dockerfile
    ├── build.config                   # Build configuration
    ├── db/
    │   └── Dockerfile                 # MariaDB Dockerfile
    └── installer/
        ├── 20-config.sh               # Clouve's copy of ownCloud's config step (writes overwrite.config.php safely)
        ├── 25-chown.sh                # Clouve's copy of ownCloud's chown step (never follows a link)
        ├── 45-php.sh                  # Clouve's copy of ownCloud's PHP step (writes objectstore.config.php safely)
        ├── entrypoint.sh              # Custom entrypoint wrapper
        ├── root-paths.sh              # Checks for root's reads and writes on the data volume
        └── www-data.sh                # Ends what occ, run as www-data, left running (the Gibbon and Moodle images' functions)
```

## Building Images

To build the Docker images:

```bash
cd magneto
./build.sh owncloud
```

This will build both the application and database images.

## Running Locally

For local development and testing:

```bash
cd magneto/apps/owncloud
docker compose up -d
```

Access ownCloud at: http://localhost:8080

Default credentials:
- Username: `admin`
- Password: `Admin@123`

## Deployment

The `clv-docker-compose.yml` file contains the production configuration with all Clouve-specific metadata including:

- Health check configurations
- Volume specifications
- Environment variable types
- Resource allocations
- Public/private access flags

## Features

- **Automatic Installation**: First-time setup is handled automatically
- **Database Persistence**: All data persists across container restarts
- **Health Checks**: Built-in health monitoring for all containers
- **Redis Caching**: Improved performance with Redis integration
- **UTF8MB4 Support**: Full Unicode support for international characters
- **Secure Configuration**: Production-ready security settings

## Initialization Flow

1. Container starts and runs custom entrypoint wrapper
2. Wrapper waits for database to be ready
3. Checks if ownCloud is already installed
4. Calls original ownCloud entrypoint for setup
5. ownCloud automatically installs if needed
6. Server starts and is ready for use

## The domain marker

The wrapper keeps the last domain it saw in `/mnt/data/.owncloud_domain`. When `OWNCLOUD_DOMAIN` differs from it, the
start sets `overwrite.cli.url` and the trusted domains with `occ`, which runs as www-data. The wrapper runs as root,
and the data volume belongs to www-data, so it reads the marker only when it is a regular file, never through a link,
and at most 300 bytes. The old domain goes to the log only when it looks like a host name. A link, a folder or a pipe
at the marker, or text that isn't a host name, is named in the log and ignored, and the marker is written again into
a new file that replaces whatever was there without following it (`installer/root-paths.sh`, the same file as the
Gibbon image's; `tests/owncloud-domain-marker.test.sh`).

## Who owns the data volume

At every start, ownCloud's own `/etc/owncloud.d/25-chown.sh` gives the code tree and the data volume to
`www-data:root`. Upstream's version did it with `find | xargs chown` without `-h`, so a link that www-data put on the
volume gave its target, any file of root's in the container, to www-data. The image replaces that script with
`installer/25-chown.sh`, which does the same work with `find -P ... -execdir chown -h` and never follows a link. Real
files and folders end with the same owner, group and mode as before. The build checks upstream's script against a
checksum (`UPSTREAM_CHOWN_SHA256` in the Dockerfile) and stops when a new base image changes it: compare the new
script with `installer/25-chown.sh`, carry its changes over, then update the checksum. Upstream's file stays in the
image at `/clouve/app/upstream/25-chown.sh`, never run, and `tests/owncloud-domain-marker.test.sh` runs both on the
same made-up volume.

## The config files ownCloud's start writes

At every start, ownCloud's own `20-config.sh` and `45-php.sh` render `overwrite.config.php` and
`objectstore.config.php` into the volume's config folder (`/mnt/data/config`) as root. Upstream's versions did it with
`gomplate -o`, which writes through a link that www-data put at either name: a file of root's anywhere in the
container then held the rendered config. The image runs Clouve's copies (`installer/20-config.sh`,
`installer/45-php.sh`): gomplate renders to its output, and `safe_put` (`installer/root-paths.sh`) writes that into a
new file it makes in the config folder, from inside the folder once the kernel has shown it to be `/mnt/data/config`,
then renames it over the old name. A link, a dangling link or a pipe at either name is replaced and never followed; a
regular file keeps its owner, group and read and write bits, as the write in place kept them. Because ownCloud's own
`occ` steps read every file of the config folder (as www-data) before `45-php.sh` writes `objectstore.config.php`,
Clouve's `20-config.sh` also removes anything at that name that isn't a regular file, without following it: a pipe
there would hold the start. The same checksum gate
as for `25-chown.sh` (`UPSTREAM_CONFIG_SHA256` and `UPSTREAM_PHP_SHA256`) stops the build when a new base image
changes either script, and upstream's files stay at `/clouve/app/upstream/`, never run.

When the config folder itself is a link (or has one on the way), nothing is written and the start stops with
`✗ Error: can't write /mnt/data/config/overwrite.config.php: its folder is missing or there is a link on the way to
it`. The folder holds the site's `config.php`, so the start doesn't replace the link with an empty folder: the
site's settings would be gone. To repair, stop the container, put the real folder back at
`/mnt/data/config` (from a throwaway container on the same volume), and start it again.

A start cut off between making one of these files and renaming it leaves `.<name>.<16 hex digits>` in the config
folder (or beside the domain marker); the next start removes such regular files. When the domain changes, the
wrapper runs `occ` as www-data without `CLOUVE_OPS_PASSWORD`, and then ends every process of www-data's that is still
running (`installer/www-data.sh`), before ownCloud's own start. When it can't make sure that none is left, the start
stops with a `[clouve-www-data]` line that says so.

## Volumes

- `ownclouddata`: Stores all ownCloud files, uploads, and configuration
- `dbdata`: Stores MariaDB database files
- `redisdata`: Stores Redis cache data

## Health Checks

- **ownCloud**: HTTP check on `/status.php` endpoint
- **MariaDB**: MySQL ping check
- **Redis**: Redis CLI ping check

## Notes

- The custom entrypoint is non-invasive and calls the original ownCloud entrypoint
- All ownCloud-specific initialization is handled by the official image
- Database credentials should be changed for production use
- The bundle supports both HTTP and HTTPS (configure via `OWNCLOUD_DOMAIN`)

## Version

- ownCloud Server: 10.16.6 (`owncloud/server:10.16.6`)
- MariaDB: 12.3 (`mariadb:12.3`)
- Redis: 6

The image takes no `:latest`. A site moves to a new pin in place at its next start (`owncloud migrate`, and MariaDB's
`MARIADB_AUTO_UPGRADE`), but neither runs older code on data a newer version wrote. So before a new ownCloud listing
version goes to an environment, list every ownCloud and owncloud-mariadb image that environment's ownCloud
deployments run, paused ones included, with `bash tests/owncloud-images.sh <kube context>...` (read-only; it exits 1
and says why when a context or an image can't be read). Pull each one by digest, give `bash tests/owncloud-pin-check.sh`
every one as `<ref>@<digest>` (or the reference as printed when it already has `@sha256:`), never the tag alone, and
publish only when it prints both pins `ok`.
`tests/owncloud-image.test.sh` installs a 10.16.0 site on MariaDB 11.4 and moves it to the current images.

## Support

For issues or questions, refer to:
- [ownCloud Documentation](https://doc.owncloud.com/)
- [ownCloud Docker Hub](https://hub.docker.com/r/owncloud/server)

