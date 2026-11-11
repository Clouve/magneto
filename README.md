# Marketplace Application Packaging Guide

This guide explains how to prepare containerized applications for deployment in a Kubernetes-based marketplace system. Whether you're packaging a single application or a multi-application bundle, this document covers the directory structure, configuration patterns, and best practices you need to follow.

## Table of Contents

1. [Overview](#overview)
2. [Directory Structure](#directory-structure)
3. [Single Applications](#single-applications)
4. [Application Bundles](#application-bundles)
5. [Dockerfile Best Practices](#dockerfile-best-practices)
6. [Docker Compose Configuration](#docker-compose-configuration)
7. [Marketplace Manifest Configuration](#marketplace-manifest-configuration)
8. [Environment Variables and Secrets](#environment-variables-and-secrets)
9. [Health Checks and Readiness](#health-checks-and-readiness)
10. [Initialization and Entrypoint Scripts](#initialization-and-entrypoint-scripts)
11. [Volume Management](#volume-management)
12. [Multi-Container Applications](#multi-container-applications)
13. [Build Configuration](#build-configuration)
14. [Testing Your Application](#testing-your-application)

---

## Overview

The marketplace packaging system enables you to:

- **Package single applications** with their dependencies (databases, caches, etc.)
- **Create application bundles** that combine multiple applications with shared integrations
- **Define deployment configurations** that work across development and production environments
- **Provide metadata** for marketplace discovery and user configuration

### Key Concepts

| Concept | Description |
|---------|-------------|
| **Application** | A single deployable unit (e.g., WordPress, Moodle) with its dependencies |
| **Bundle** | Multiple applications packaged together with integrations (e.g., Education Kit) |
| **Development Compose** | `docker-compose.yml` for local testing and development |
| **Marketplace Manifest** | `clv-docker-compose.yml` with metadata for marketplace deployment |
| **Image Directory** | Contains Dockerfiles and build configuration for custom images |

---

## Directory Structure

### Single Application Structure

```
apps/
└── my-application/
    ├── README.md                    # Application documentation
    ├── logo.png                     # Application logo (recommended: 256x256)
    ├── docker-compose.yml           # Development/testing configuration
    ├── clv-docker-compose.yml       # Marketplace manifest with metadata
    └── image/                       # Custom Docker image build files
        ├── Dockerfile               # Main application Dockerfile
        ├── build.config             # Build configuration variables
        ├── installer/               # Initialization scripts
        │   ├── entrypoint.sh        # Custom entrypoint wrapper
        │   ├── install.sh           # Installation logic (optional)
        │   └── ...                  # Additional helper scripts
        └── <database>/              # Database container (mariadb/, mysql/, postgres/)
            └── Dockerfile           # Database Dockerfile
```

### Application Bundle Structure

```
bundles/
└── my-bundle/
    ├── README.md                    # Bundle documentation
    ├── description.txt              # Short bundle description
    ├── logo.png                     # Bundle logo
    ├── app1.png                     # Logo for included app 1
    ├── app2.png                     # Logo for included app 2
    ├── docker-compose.yml           # Development configuration
    └── clv-docker-compose.yml       # Marketplace manifest
```

> **Note:** Bundles typically reuse existing application images and do not include their own `image/` directory.

---

## Single Applications

A single application package includes one primary application container and any required supporting services.

### Container Naming Conventions

- **Main container:** Use the application name (e.g., `wordpress`, `moodle`)
- **Supporting containers:** Prefix with main app name (e.g., `wordpress-mariadb`, `moodle-mysql`)
- This convention is critical for service discovery and orchestration

---

## Application Bundles

Bundles combine multiple applications that work together with shared integrations.

### Bundle Characteristics

- **Reuse existing images:** Bundles reference pre-built application images
- **Shared networks:** All containers communicate on a common network
- **Integration configuration:** Environment variables configure inter-app communication
- **Multiple public endpoints:** Each main application gets its own port/ingress

---

## Dockerfile Best Practices

### Extending Official Images

When extending official Docker images:

1. **Preserve original entrypoints** - Don't rename or modify them
2. **Place custom scripts in separate paths** (e.g., `/clouve/app/installer/`)
3. **Call original entrypoint from your wrapper**

```dockerfile
# Example: Extending an official image
FROM wordpress

# Install additional dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Create directory for custom scripts
RUN mkdir -p /clouve/myapp/installer

# Copy custom entrypoint wrapper
COPY installer/entrypoint.sh /clouve/myapp/installer/entrypoint.sh
RUN chmod +x /clouve/myapp/installer/entrypoint.sh

# Set custom entrypoint (calls original at /usr/local/bin/docker-entrypoint.sh)
ENTRYPOINT ["/clouve/myapp/installer/entrypoint.sh"]
CMD []
```

### Building from Scratch

For applications built from base images (e.g., `php:8.3-apache`):

```dockerfile
FROM php:8.3-apache

# Version configuration
ENV APP_VERSION=1.0.0
ENV APP_PATH=myapp/myapp-${APP_VERSION}

# Install system dependencies
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y \
    gettext-base locales git default-mysql-client \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen

# Install PHP extensions
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo_mysql gd opcache zip intl

# Clean up
RUN apt-get clean autoclean && apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

# Apache configuration
RUN a2enmod rewrite headers

# Security hardening
RUN sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/g" /etc/apache2/apache2.conf
RUN echo "ServerTokens Prod\nServerSignature Off" >> /etc/apache2/apache2.conf

# PHP configuration
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN printf "upload_max_filesize=100M\npost_max_size=100M\nmemory_limit=512M" >> "$PHP_INI_DIR/php.ini"

# Working directory for custom scripts
WORKDIR /clouve
COPY installer ./myapp/installer
RUN chmod +x ./myapp/installer/*.sh

# Download and extract application
ADD https://example.com/myapp-${APP_VERSION}.tar.gz ./myapp/installer/
RUN tar -xzf ./myapp/installer/myapp-${APP_VERSION}.tar.gz -C ./myapp/

ENTRYPOINT ["/clouve/myapp/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
```

### Database Images

For database containers, you can often use a simple re-packaging Dockerfile:

```dockerfile
# mariadb/Dockerfile
FROM mariadb

LABEL maintainer="Your Team"
LABEL description="MariaDB database for MyApp"
```

This approach is useful when you want to:
- Avoid Docker Hub rate limits in production
- Push to your own private registry
- Maintain consistent image sources

### The clouve-ops SSH channel

An image the AI Assistant works in runs an sshd for the `clouve-ops` account,
which its entrypoint starts in the background (`start-clouve-ops-sshd.sh`).
Three rules come with it:

- **No SSH host keys in the image.** Installing openssh-server makes host keys.
  Delete them in the same `RUN` (`rm -f /etc/ssh/ssh_host_*`): kept, they ship
  to every deployment, and every tenant has the same host key. Each container
  then makes its own when its sshd starts (`ssh-keygen -A`), so the keys change
  at every container start. The Odoo, Nextcloud and Moodle images do this
  (`tests/ssh-host-keys.test.sh` checks Odoo's, `tests/moodle-ssh-host-keys.test.sh`
  Moodle's). The WordPress, Gibbon and AI Studio images, and WordPress's database
  image, still ship keys; add the `rm -f` when you next rebuild them.
- **Push a rebuilt image only where the AI Assistant keeps no host keys.** An
  AI Assistant older than magneto-agent 4.5.3 saves each sibling's host key,
  and refuses the sibling once that key changes. A rebuilt image's key does
  change: at every start when the image ships none, and at the rebuild itself
  when it still ships one. So push a rebuilt image with openssh-server to an
  environment only after that environment's AI Assistant image is
  magneto-agent 4.5.3 or later, which saves no sibling keys, and its running
  AI Assistants have restarted onto it. Until then, the app's skill has to
  pass `-o UserKnownHostsFile=/dev/null` itself, as the Nextcloud and AI Studio
  skills do. Where such an image runs, the AI Assistant image stays at 4.5.3
  or later: to roll it back below that, put the earlier app images back first.
- **A PID 1 that reaps.** An SSH session can leave processes whose parent has
  gone, and PID 1 inherits them. Make tini PID 1 when the image's own server
  doesn't reap them (Odoo, MySQL and MariaDB don't), or when it takes such a
  process for one of its own (PostgreSQL does: when one ends with an error or
  a signal, PostgreSQL ends every connection and restarts). Install the `tini`
  package and set `ENTRYPOINT ["/usr/bin/tini", "--", "<your entrypoint>"]`.
  tini passes signals on to its child, so `docker stop` and a `kill -HUP 1`
  restart still reach the server. In a database image, also start the sshd
  detached, `( start-clouve-ops-sshd.sh & )`: the subshell exits at once, so
  sshd's parent is tini, not the database server that the entrypoint's `exec`
  turns the shell into. Both Odoo images do this (`tests/odoo-init.test.sh`).
  `tests/db-image-zombies.test.sh` shows which database images still need it;
  add a new database image to its lists.

---

## Docker Compose Configuration

### Development Configuration (`docker-compose.yml`)

The development compose file is used for local testing. Key features:

```yaml
services:
  myapp:
    image: registry.example.com/myapp
    container_name: myapp
    restart: unless-stopped
    ports:
      # Support environment variable substitution for flexible testing
      - "${TEST_PORT:-8080}:80"
    environment:
      DB_HOST: myapp-mysql
      DB_NAME: myapp
      DB_USER: myapp
      DB_PASSWORD: myapp_password
      # URL with environment variable substitution
      APP_URL: http://${TEST_DOMAIN:-localhost}:${TEST_PORT:-8080}
    volumes:
      - app_data:/var/www/html
    networks:
      - app_network
    # Dependencies with health check conditions
    depends_on:
      myapp-mysql:
        condition: service_healthy

  myapp-mysql:
    image: registry.example.com/myapp-mysql
    container_name: myapp_db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp
      MYSQL_PASSWORD: myapp_password
      MYSQL_ROOT_PASSWORD: root_password
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - app_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  app_data:
    driver: local
  db_data:
    driver: local

networks:
  app_network:
    driver: bridge
```

### Environment Variable Substitution

Use environment variable substitution for testing flexibility:

```yaml
environment:
  # Default: http://localhost:8080
  # Override with: TEST_DOMAIN and TEST_PORT environment variables
  APP_URL: http://${TEST_DOMAIN:-localhost}:${TEST_PORT:-8080}
```

This allows testing URL change detection without modifying files:

```bash
TEST_DOMAIN=newdomain.test TEST_PORT=9090 docker-compose up -d
```

---

## Marketplace Manifest Configuration

The marketplace manifest (`clv-docker-compose.yml`) extends standard Docker Compose with metadata extensions.

### One manifest per app

Each app has one marketplace manifest. The AI-disabled twin
(`clv-docker-compose-basic.yml`) was retired on 2026-10-18, and no app has one.
An agent-capable app publishes a single listing: its manifest carries an
`x-clouve-agent: enabled: true` block, and the customer chooses the AI Assistant
at install. Its `appTitle` is the app's own name, such as "Moodle", never
"Moodle with AI Assistant", because the deployment page shows the title whether
or not the customer added the AI Assistant. The images also run without it,
because the `clouve-ops` sshd in them starts only when the platform injects
`CLOUVE_OPS_PASSWORD`.

### AI Assistant (`x-clouve-agent`)

An agent-capable manifest adds a top-level `x-clouve-agent` block. The
platform reads it at upload and adds the `magneto-agent` container to the
deployment itself, so the manifest never declares that service.

```yaml
x-clouve-agent:
  enabled: true
  skills:
    url: https://github.com/Clouve/magneto-skills.git?plugins=moodle
    git:
      token: ''
      username: ''
  advanced:
    sidecarPullTimeout: 600
```

| Field | Meaning |
| --- | --- |
| `enabled` | `true` offers the AI Assistant on this listing. A manifest without the block has no AI Assistant. |
| `skills.url` | Optional. The skills marketplace repo, with a non-empty `?plugins=` filter and an optional `#branch`. Left out, the agent starts with its base context and no skills plugins. |
| `skills.git.token` / `skills.git.username` | Optional credentials for a private skills repo. |
| `advanced.sidecarPullTimeout` | Optional, in seconds (at most 1800). How long the agent waits at init to pull each sibling's persona and env over `clouve-ops` SSH. Raise it for siblings with a slow first install, as Moodle, Gibbon, Odoo and Nextcloud do here. |
| `advanced.passthroughEnv` | Optional map of extra env vars for the agent container. It is an escape hatch; `apps/ai-studio` uses it. |

On a paid plan, the AI Assistant's monthly price is Clouve's platform fee for
the tier plus the publisher's own AI Assistant fee ($0 to $500 a month), which
the publisher sets on the publish wizard's pricing step and earns. Clouve sets
the monthly usage allowance that comes with it and sells extra usage at cost.
Customers see one price on the listing and at checkout, never the allowance in
dollars or the split, and they can buy more usage for the current month when it
runs out. A free trial, or an organization with free services, gets the AI
Assistant at no charge, with no AI usage and no Buy more: the customer uses it
with their own Claude subscription. A listing's text has to be true for both,
which `tests/listing-ai-copy.test.sh` checks. The AI Assistant is optional at
install, and the customer can turn it on or off later.

`quota` is retired: Clouve sets the allowance now, so an upload ignores a
leftover `quota` field instead of rejecting it.

The AI Assistant has one built-in client, so there is no `advanced.client`
field. An upload ignores a leftover `client: null` or `client: claude-code` and
rejects any other value. Manifests carry no API key and no model settings:
Clouve manages model access, with one key per paid deployment.

For local runs, an app's `docker-compose.yml` passes model access through from
the developer's shell (`MAGNETO_AGENT_LLM_BASE_URL` + `MAGNETO_AGENT_LLM_KEY`, or
`ANTHROPIC_API_KEY`). The full schema and the upload/download round trip are in
thermo's `docs/OPTIONAL_MAGNETO_AGENT.md`.

### Container Metadata (`x-clouve-metadata`)

```yaml
x-clouve-metadata:
  containerName: myapp           # Unique container identifier
  purpose: Frontend              # Frontend, Backend, Database, Cache, etc.
  protocol: TCP                  # TCP or UDP
  isPublic: true                 # Whether to expose via ingress
  memoryBase: 1                  # Base memory units (GB)
  cpuBase: 1                     # Base CPU units (cores)
```

### Application Metadata (`x-clouve-bundle-metadata`)

```yaml
x-clouve-bundle-metadata:
  appVersion: "1.0.0"            # Application version
  appTitle: "My Application"     # The app's own name, shown with its version (the listing has a name of its own)
  appDescription: |              # Detailed description
    My Application is a powerful platform that enables...
  appIcon: /thermo/assets/Company/acme/attachments/myapp-icon.png  # Optional: an icon your organization uploaded
  adminPath: /admin              # Optional: the admin page; the app's admin link is its URL plus this path
```

An app's icon is a PNG you upload in the publish wizard, so leave `appIcon`
out of a manifest you write. A manifest you download from the wizard holds the
path the upload wrote, `/thermo/assets/Company/<your organization's folder>/attachments/<file>`.
Clouve accepts no other path (release 4.5.3). A path that points anywhere else,
such as another organization's upload, is refused when the listing is saved or
published: "Container 1: upload the icon again. A listing can only use images
your organization uploaded."

### Host aliases (`x-clouve-host-aliases`)

Each public container gets one host. The first public container gets the deployment's own host, such as
`acme-12.clouve.app`. Every other public container gets `<container>-acme-12.clouve.app`, and the AI Assistant gets
`ai-acme-12.clouve.app`.

A public container can also answer on up to three more hosts, its host aliases. An alias named `studio` on that
deployment answers at `studio-acme-12.clouve.app`. The alias host sits beside the deployment's other hosts, under the
same certificate, and never below them: there is no `studio.acme-12.clouve.app`. The ingress sends it to the same
container and port, so the app gets the requests for all of its hosts on one port and tells them apart by the `Host`
header. Open edX needs this: one container runs its learner site and its Studio, each on a host of its own. An alias
adds no container, so it doesn't change the price.

The customer sees each alias as an app of its own on the deployment page, with its title, icon, URL, admin link and
status, and the sign-in of the container it runs in. Each alias also has its own custom-domain field, so a customer
can use `studio.learn.school.org` beside `learn.school.org`. When the customer saves a domain for an alias, Clouve
writes it into the owning container's environment in place of the alias's host, as it does for a container's own
domain.

```yaml
services:
  openedx:
    environment:
      OPENEDX_URL: http://localhost:8080
      OPENEDX_STUDIO_URL: studio
    x-clouve-environment-types:
      OPENEDX_URL: applicationUrl              # https://acme-12.clouve.app
      OPENEDX_STUDIO_URL: applicationAliasUrl  # https://studio-acme-12.clouve.app
    x-clouve-metadata:
      containerName: openedx
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: "Learning Site"
    x-clouve-host-aliases:
      - name: studio
        appTitle: Course Studio
        appDescription: Build and edit your courses.
        adminPath: /home
```

Each entry has a name and the text fields of `x-clouve-bundle-metadata`:

| Field | Meaning |
| --- | --- |
| `name` | Required. The first part of the alias's host: 2 to 15 lower-case letters and digits, starting with a letter, with no hyphen. |
| `appTitle` | The alias's name on the deployment page and in the marketplace, 2 to 100 characters, with no `{{` or `}}`. The publish wizard asks for it on every alias, and for the owning container's own `appTitle`, even when that container is the listing's only public one. A listing saved without it shows the alias's name with a capital first letter. |
| `appDescription` | Optional. 10 to 1000 characters, with no `{{` or `}}`. Left empty, it is the alias's title followed by "application", such as "Course Studio application". |
| `appVersion` | Optional, in the format of a container's `appVersion` (`"1.0.0"`, `"2.1"`, `"3.0.0-beta"`). Left empty, it is the owning container's version. |
| `adminPath` | Optional, with the rules of a container's `adminPath`: it starts with `/`, uses only letters, digits, `-`, `_`, `.`, `~`, `%` and `/`, has no `//`, and is at most 256 characters long. The alias's admin link is its URL plus this path. The owning container's own `adminPath` has to keep these rules too. |

The container that has the aliases can't have `{{` or `}}` in its own `appTitle`, `appDescription` or `appVersion`
either: Clouve writes these texts into templates that read those marks as their own.

The manifest has no icon field for an alias. Upload each alias's icon, a PNG, in the publish wizard next to its other
fields; the wizard asks for one, and for the owning container's icon. A manifest you download from the wizard leaves
the alias icons out as well, so after you upload it again, upload each alias's icon again.

Two environment types give a container the addresses of its own aliases: `applicationAliasUrl` and
`applicationAliasHost`. The variable's value is the alias's name, and it has to be an alias of the same container.
They work like `applicationUrl` and `applicationHost`: in the example, `OPENEDX_STUDIO_URL` becomes
`https://studio-acme-12.clouve.app`, and changes to the alias's custom domain when the customer sets one.

Clouve checks these rules, and the limits in the table, when you upload the manifest, whenever the listing is saved
and again when it is published:

- A container has at most 3 aliases.
- Only a public container whose `purpose` is `Frontend` or `Backend` takes aliases. The AI Assistant takes none.
- No alias is named `default`, `ai`, `icon`, `gcp`, `aws`, `azure`, `clv`, `magneto-agent` or `oauth2-proxy`. Clouve
  already uses these names: for the deployment's own host, the listing's icon, the AI Assistant, the deployment's
  single sign-on proxy (`oauth2-proxy`) and its clusters' hosts.
- No alias has the name of a container in the listing (in any case, public or not), and no two aliases share a name,
  even on different containers. The same goes the other way round: a container can't be named like an alias.

A listing's first published version also fixes its aliases. From then on, Clouve refuses to save a version that
doesn't declare the same alias names on the same containers; their titles, descriptions, versions, icons and admin
paths can change. To add, remove or move an alias, publish a new listing.

One more limit applies when a deployment is installed or copied: each of its hosts has to fit in 63 characters, and
Clouve refuses the install or the copy when one would be longer. A long alias name leaves less room for the
organization's part of the host.

In this repo, `./check-manifests.sh` checks every manifest against all of this section's rules except the two only
Clouve can check: the aliases a published version fixes, and the 63 characters at install. It also needs a container
with aliases to state `isPublic` and `purpose` in its `x-clouve-metadata`, which an upload would otherwise guess.

### Values Clouve refuses

Clouve writes much of a listing into the templates it deploys from, and those templates read `{{` and `}}` as
expressions of their own. So Clouve checks every listing against the rules below (release 4.5.3) when you upload a
manifest, whenever the listing is saved, when a reviewer downloads its manifests and when it is published. A listing
that breaks one can't be saved or published until you fix it, and deployments that already run don't change. A refusal
names the container and the field by position, counted from 1 as the publish wizard lists them, and the rule, never the
text it found. Refusals about a container's settings start with "Check the container settings: ".

- No `{{` or `}}` in these fields: a variable's name or value, whatever its type; `image`; the `path` of
  `x-clouve-healthcheck`; a volume's name and mount path; a Helm chart's name, version and repository; a global
  secret's name; and the AI Assistant's `skills.url` and `skills.git.username`. A backslash in front doesn't help, and
  no placeholder is allowed: the only expressions in a deployment's templates are the ones Clouve writes after this
  check, such as `tkt-{{ticket.id}}-<name>` for a container reference. Single braces are fine, so the template
  variables below, such as `{user.userEmail}`, keep working.
- A variable's name uses only letters, digits, `.`, `-` and `_`, doesn't start with a digit, isn't `.` and doesn't
  start with `..`: Kubernetes' rule for environment variable names. A global secret's name keeps the same rule. In a
  manifest with `x-clouve-environment-types`, that name is the value of a `secret` or `applicationPassword` variable,
  such as `myapp-mysql-password`.
- No line breaks or other control characters in `image`, the health check's `path`, a volume's name and mount path, a
  Helm chart's name, version and repository, or the AI Assistant's `skills.url` and `skills.git.username`. Clouve
  writes each of them into the deployment's manifests on a line of its own. A variable's value may hold line feeds and
  tabs, but no carriage return or other control character.
- A `userConfigurable` or `applicationUsername` variable's value can't contain a double quote or a backslash, and a
  mount path can't contain a quote of either kind or a backslash: Clouve writes these inside quoted strings.
- A container's Kubernetes labels and annotations, host prefix, service type, headless setting and extra ports are
  Clouve's own, so a listing can't set them. An upload doesn't read a manifest's compose `labels`.
- Every container's `adminPath`, with host aliases or without, keeps the rule in the host alias table above: it starts
  with `/`, uses only letters, digits, `-`, `_`, `.`, `~`, `%` and `/`, has no `//`, and is at most 256 characters
  long.
- Icons come only from your organization's uploads: a container's `appIcon`, each host alias's icon and the listing's
  logo (see [Application Metadata](#application-metadata-x-clouve-bundle-metadata)).

Of these rules, `./check-manifests.sh` checks only the admin path of a container that has host aliases.

### Environment Variable Types (`x-clouve-environment-types`)

Define how each environment variable should be handled:

```yaml
environment:
  DB_HOST: myapp-mysql
  DB_PASSWORD: myapp-mysql-password
  APP_URL: http://localhost
  ADMIN_EMAIL: '{user.userEmail}'
  ADMIN_PASSWORD: app-password

x-clouve-environment-types:
  DB_HOST: containerReference      # Reference to another container
  DB_PASSWORD: secret              # Auto-generated secret
  APP_URL: applicationUrl          # Replaced with actual deployment URL
  ADMIN_EMAIL: applicationUsername # User-provided value
  ADMIN_PASSWORD: applicationPassword  # User-configurable password
```

**Environment Type Reference:**

| Type | Description |
|------|-------------|
| `static` | Fixed value, not modified during deployment |
| `secret` | Auto-generated secure password/token |
| `containerReference` | Reference to another container name |
| `applicationUrl` | Replaced with the container's own URL, such as `https://acme-12.clouve.app` |
| `applicationHost` | Replaced with the container's own host, such as `acme-12.clouve.app` |
| `applicationAliasUrl` | Replaced with the URL of one of the container's host aliases; the value is the alias's name (see "Host aliases") |
| `applicationAliasHost` | Replaced with the host of one of the container's host aliases; the value is the alias's name |
| `applicationUsername` | Primary user identifier |
| `applicationPassword` | Primary user password |
| `userConfigurable` | User can modify during deployment |

### Template Variables

Use template variables for user context:

```yaml
environment:
  ADMIN_EMAIL: '{user.userEmail}'
  ADMIN_USER: '{user.firstName}_{user.lastName}'
  ORG_NAME: '{org.name}'
```

**Available Template Variables:**

| Variable | Description |
|----------|-------------|
| `{user.userEmail}` | User's email address |
| `{user.firstName}` | User's first name |
| `{user.lastName}` | User's last name |
| `{org.name}` | Organization name |

---

## Health Checks and Readiness

Health checks ensure containers are ready to receive traffic before being added to load balancers.

### Docker Compose Health Checks

```yaml
healthcheck:
  test:
    - CMD
    - wget
    - '--spider'
    - '-q'
    - http://localhost:80/
  interval: 15s        # Time between checks
  timeout: 10s         # Maximum time for check to complete
  retries: 5           # Number of retries before marking unhealthy
  start_period: 30s    # Grace period for container startup
```

### Marketplace Health Check Extension (`x-clouve-healthcheck`)

```yaml
x-clouve-healthcheck:
  enabled: true              # Enable/disable health checking
  type: HTTP                 # HTTP, TCP, or Command
  path: /                    # HTTP endpoint path
  port: 80                   # Port to check
  initialDelay: 30           # Seconds to wait before first check
  interval: 15               # Seconds between checks
  timeout: 10                # Seconds to wait for response
  failureThreshold: 5        # Failures before marking unhealthy
  successThreshold: 1        # Successes before marking healthy
```

### Health Check Types

**HTTP Health Check:**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: HTTP
  path: /health
  port: 8080
```

**TCP Health Check (for databases):**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: TCP
  port: 3306
```

**Command Health Check:**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: Command
  path: mysqladmin ping -h localhost
  port: 3306
```

> **Note:** Set `enabled: false` for supporting containers (databases) that don't need external health checking.

---

## Initialization and Entrypoint Scripts

Custom entrypoint scripts handle initialization, configuration, and startup.

### Entrypoint Script Pattern

```bash
#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Path to the original entrypoint (from base image)
ORIGINAL_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

# Application paths
APP_DIR="/var/www/html"
INSTALLED_MARKER="/var/www/html/.app_initialized"

# ============================================================================
# STEP 1: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."
max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if mysqladmin ping -h"$DB_HOST" --silent 2>/dev/null; then
        echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} Database not ready... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} Database failed to become ready"
    exit 1
fi

# Wait for database to stabilize
sleep 3

# ============================================================================
# STEP 2: Check if application is already installed
# ============================================================================

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} Application already initialized"

    # Check if URL has changed and update if needed
    # (Application-specific URL update logic here)
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization..."

    # Run installation logic
    # ...

    # Create marker file
    echo "$(date)" > "$INSTALLED_MARKER"
fi

# ============================================================================
# STEP 3: Execute original entrypoint or start service
# ============================================================================

if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    exec "$ORIGINAL_ENTRYPOINT" "$@"
else
    exec "$@"
fi
```

### Key Initialization Patterns

1. **Database readiness polling:** Use `mysqladmin ping` or similar with timeout
2. **Initialization markers:** Track state with marker files in persistent volumes
3. **URL change detection:** Check and update application URLs on restart
4. **File bundling:** Copy application files from bundled location to volume mount
5. **Original entrypoint preservation:** Always call original entrypoint if it exists

### File Bundling for Kubernetes Volumes

When Kubernetes mounts an empty PVC, it overwrites container files. Bundle files during build:

```dockerfile
# Bundle application files during build
RUN cp -a /var/www/html/. /clouve/myapp/package/

# In entrypoint.sh, copy files if missing
if [ ! -f "/var/www/html/index.php" ]; then
    cp -prf /clouve/myapp/package/* /var/www/html/
    chown -R www-data:www-data /var/www/html/
fi
```

---

## Volume Management

### Volume Configuration

```yaml
volumes:
  - app_data:/var/www/html          # Application files
  - upload_data:/var/www/html/upload # User uploads
  - db_data:/var/lib/mysql          # Database files

x-clouve-volumes:
  - name: app-data
    size: 10                        # Size in GB
    description: "Volume for application files"
  - name: upload-data
    size: 20
    description: "Volume for user uploads"
  - name: db-data
    size: 10
    description: "Volume for database files"
```

### Volume Best Practices

1. **Separate volumes by purpose:** Application files, uploads, database data
2. **Size appropriately:** Consider growth patterns
3. **Use descriptive names:** Helps with management and debugging
4. **Handle empty volume mounts:** On a cluster a new volume starts empty and owned by root (see the next section)

### Volumes on a cluster

On a cluster, every volume of a new install is a new disk. Tropo writes a plain PersistentVolumeClaim for each volume,
with the cluster's default storage class (on GKE a pd-balanced persistent disk, formatted ext4), no init container and
no `securityContext`. So when a container starts for the first time, each of its volumes is an empty filesystem:

- the top folder belongs to root, with mode 755;
- `lost+found` (root's, mode 700) is in it;
- none of the files the image keeps at that path are there.

Docker works differently. The first time a container mounts a new named volume, Docker copies the image's folder at
that path into it, owner and mode included. An image that has only ever run under Docker can therefore depend on that
copy without anyone noticing. Nextcloud's first install on GKE did, and crash-looped on 2026-10-26: www-data could not
write to its volume's root-owned top folder.

`./start.sh` and `./test.sh` make every new volume in the cluster's shape before Compose creates the containers
(`lib/new-disk-volumes.sh`), so a local start shows what a cluster does. Volumes that already exist stay as they are.
`--docker-volumes` gives Docker's copy back, for comparing the two while debugging; a cluster never does that. A plain
`docker-compose up` still gets Docker's copy.

An image follows these rules:

1. The entrypoint starts as root, and before anything runs as the app's user it makes each volume's top folder usable
   for that user. It acts when the folder is root's, which a working install never leaves it, and it doesn't change
   ownership through a whole volume at every start. Nextcloud's `nc_claim_new_volume`
   (`apps/nextcloud/image/installer/lib.sh`) is an example.
2. Files the app needs at a volume path aren't shipped at that path. They live elsewhere in the image (for example
   `/usr/src/<app>`) and the entrypoint copies them in when they're missing, as WordPress and Nextcloud do. Or the
   entrypoint seeds the volume from a snapshot in the image and writes a sentinel file, as the Magneto Agent and AI
   Studio do.
3. `lost+found` counts as empty. A first-start check ignores it, and an engine that refuses a data folder that isn't
   empty keeps its data in a subfolder (PostgreSQL's `PGDATA=/var/lib/postgresql/data`).
4. When the upstream image runs as a user other than root, the image starts as root and switches to that user once the
   ownership is right. It never relies on the owner the image gives the folder.
5. A nested volume, like LimeSurvey's `/var/www/html/upload` inside `/var/www/html`, is a disk of its own and follows
   the same rules.
6. A fix for an app that already has installs changes only what a working install never has, and proves it with
   `tests/new-disk-start.test.sh <app> --upgrade-from <previous build>` (see "Testing on new cluster disks").
7. `tests/new-disk-start.test.sh <app>` passes before every push to UAT or prod. `build-uat.sh` and `build-prod.sh`
   check for that pass and refuse to push an app whose current source doesn't have one.

---

## Multi-Container Applications

### Service Dependencies

Use `depends_on` with health check conditions:

```yaml
services:
  myapp:
    depends_on:
      myapp-mysql:
        condition: service_healthy
      myapp-redis:
        condition: service_started
```

### Shared Networks

All containers in an application should share a network:

```yaml
networks:
  app_network:
    driver: bridge

services:
  myapp:
    networks:
      - app_network
  myapp-mysql:
    networks:
      - app_network
```

### Inter-Container Communication

Use container service names for internal communication:

```yaml
environment:
  DB_HOST: myapp-mysql        # Service name, not container_name
  REDIS_HOST: myapp-redis
  CACHE_URL: redis://myapp-redis:6379
```

---

## Build Configuration

### Build Configuration File (`build.config`)

```bash
# build.config
APP_IMAGE="myapp"
MARIADB_IMAGE="myapp-mariadb"
MARIADB_NAME="MariaDB"
```

### Multi-Platform Builds

Build for multiple architectures using Docker Buildx:

```bash
# Build for local architecture only
docker buildx build --platform linux/amd64 -t myapp .

# Build for multiple architectures and push
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t registry.example.com/myapp \
  --push .
```

### Build Script Pattern

```bash
#!/bin/bash

# Load configuration
source ./image/build.config

# Build main application image
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "${REGISTRY}/${APP_IMAGE}" \
  --push \
  ./image

# Build database image (if custom)
if [ -d "./image/mariadb" ]; then
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t "${REGISTRY}/${MARIADB_IMAGE}" \
    --push \
    ./image/mariadb
fi
```

---

## Testing Your Application

### Testing on new cluster disks

Every app and bundle has to start the way a cluster starts a new install. The new-disk test does that locally:

```bash
# Builds the app (host platform), starts it with every volume as a new disk, and judges each container
# by its own probe from clv-docker-compose.yml. A pass is recorded for this exact source.
bash tests/new-disk-start.test.sh wordpress
bash tests/new-disk-start.test.sh education-kit      # a bundle runs the images of its apps as they are
bash tests/new-disk-start.test.sh --all

# After a fix to an app that already has installs: the previous build installs first, then the fix
# starts on the same volumes, and each volume's top folder must keep its owner and mode.
bash tests/new-disk-start.test.sh wordpress --upgrade-from 2026.10.22

# The test's own checks: the volume helper, start.sh, the runner and the push gate, on fake apps
bash tests/new-disk-volumes.test.sh
```

Each run uses its own Compose project with no published ports and no fixed container names, so it never collides
with a local stack, and it gives each container the CPU and memory of the smallest plan (`cpuBase`, `memoryBase`), with
no swap beyond that. A container passes when its `x-clouve-healthcheck` probe passes, run as Kubernetes runs it, within
`initialDelay + failureThreshold × interval` seconds (at most 600, the time the platform's launch job waits). An HTTP
probe asks the container's IP, follows redirects to the same host and judges the last answer, as the kubelet does.
Then, for a 90-second settle period, nothing may exit or restart, and no probe may fail for longer than the platform
allows. The Magneto Agent's service is left out unless `--with-agent` is given.

`build-uat.sh` and `build-prod.sh` push an app only when this test passed on its current source, on the machine that
pushes: a record of each pass is kept in `~/.cache/magneto/new-disk-passes/` there, and any change to the app's files
makes it stale. A pass counts only from a full run, built by the test itself and with the full 90-second settle. In an
emergency, `--skip-new-disk-check` pushes anyway and says so.

### Local Testing Workflow

```bash
# 1. Build images locally
docker-compose build

# 2. Start containers
docker-compose up -d

# 3. Check container status
docker-compose ps

# 4. View logs
docker-compose logs -f myapp

# 5. Test application
curl http://localhost:8080

# 6. Stop containers
docker-compose down
```

### Testing URL Changes

Test that your application handles URL changes correctly:

```bash
# Start with default URL
docker-compose up -d

# Verify application works
curl http://localhost:8080

# Stop and restart with new URL
docker-compose down
TEST_DOMAIN=newdomain.test TEST_PORT=9090 docker-compose up -d

# Verify URL was updated
curl http://newdomain.test:9090
```

### Testing Database Persistence

```bash
# Start containers
docker-compose up -d

# Create some data in the application
# ...

# Stop containers (preserves volumes)
docker-compose down

# Restart containers
docker-compose up -d

# Verify data persists
# ...

# Clean up (removes volumes)
docker-compose down -v
```

### Validation Checklist

Before submitting your application to the marketplace:

- [ ] **Container starts successfully** with `docker-compose up -d`
- [ ] **Health checks pass** - verify with `docker-compose ps`
- [ ] **Application is accessible** at configured URL
- [ ] **Database connection works** - application can read/write data
- [ ] **Data persists** across container restarts
- [ ] **URL changes are handled** - application updates internal URLs
- [ ] **Logs are clean** - no errors in `docker-compose logs`
- [ ] **Marketplace manifest is valid** - all required metadata present
- [ ] **Environment types are correct** - secrets, URLs, references properly typed
- [ ] **Health check configuration** - appropriate for your application

---

## Complete Marketplace Manifest Example

Here's a complete example of a marketplace manifest (`clv-docker-compose.yml`):

```yaml
services:
  myapp:
    image: registry.example.com/myapp
    container_name: myapp
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      # Database Configuration
      DB_HOST: myapp-mysql
      DB_PORT: 3306
      DB_NAME: myapp
      DB_USER: myapp
      DB_PASSWORD: myapp-db-password
      # Application Configuration
      APP_URL: http://localhost:8080
      ADMIN_USER: '{user.firstName}'
      ADMIN_EMAIL: '{user.userEmail}'
      ADMIN_PASSWORD: myapp-admin-password
      # Feature Flags
      DEBUG_MODE: "false"
    x-clouve-environment-types:
      DB_HOST: containerReference
      DB_PORT: static
      DB_NAME: static
      DB_USER: static
      DB_PASSWORD: secret
      APP_URL: applicationUrl
      ADMIN_USER: applicationUsername
      ADMIN_EMAIL: static
      ADMIN_PASSWORD: applicationPassword
      DEBUG_MODE: userConfigurable
    x-clouve-metadata:
      containerName: myapp
      purpose: Frontend
      protocol: TCP
      isPublic: true
      memoryBase: 1
      cpuBase: 1
    x-clouve-healthcheck:
      enabled: true
      type: HTTP
      path: /
      port: 80
      initialDelay: 30
      interval: 15
      timeout: 10
      failureThreshold: 5
      successThreshold: 1
    x-clouve-bundle-metadata:
      appVersion: "1.0.0"
      appTitle: "My Application"
      appDescription: |
        My Application is a powerful platform that enables teams to collaborate
        effectively. Features include real-time editing, file sharing, and
        integrated communication tools.
    volumes:
      - app_data:/var/www/html
      - upload_data:/var/www/html/upload
    x-clouve-volumes:
      - name: app-data
        size: 10
        description: "Volume for application files"
      - name: upload-data
        size: 20
        description: "Volume for user uploads"
    networks:
      - app_network
    depends_on:
      myapp-mysql:
        condition: service_healthy

  myapp-mysql:
    image: registry.example.com/myapp-mysql
    container_name: myapp_db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp
      MYSQL_PASSWORD: myapp-db-password
      MYSQL_ROOT_PASSWORD: myapp-root-password
    x-clouve-environment-types:
      MYSQL_DATABASE: static
      MYSQL_USER: static
      MYSQL_PASSWORD: secret
      MYSQL_ROOT_PASSWORD: secret
    x-clouve-metadata:
      containerName: myapp-mysql
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 1
    x-clouve-healthcheck:
      enabled: false
      type: Command
      path: mysqladmin ping -h localhost
      port: 3306
    volumes:
      - db_data:/var/lib/mysql
    x-clouve-volumes:
      - name: db-data
        size: 10
        description: "Volume for database files"
    networks:
      - app_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  app_data:
    driver: local
  upload_data:
    driver: local
  db_data:
    driver: local

networks:
  app_network:
    driver: bridge
```

---

## Additional Resources

- **DEVELOPER_GUIDE.md** - Management scripts and operational documentation
- **Individual app READMEs** - Application-specific documentation in `apps/<app>/README.md`
- **Bundle READMEs** - Bundle-specific documentation in `bundles/<bundle>/README.md`

