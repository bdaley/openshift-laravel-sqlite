# OpenShift Laravel SQLite — S2I Deployment Guide

This repository is prepared for Source-to-Image (S2I) builds and deployments on OpenShift using SQLite as the database.

Key facts:

- **Builder image app directory**: `/opt/app-root/src`
- **Persistent storage**: single PVC mounted at both `/opt/app-root/src/database` and `/opt/app-root/src/storage`
- **SQLite database**: `/opt/app-root/src/database/database.sqlite`
- **Migrations**: run via a separate Job, not at app startup
- **Replicas**: always 1 — SQLite uses file locking and will error under concurrent writes from multiple pods

## OpenShift Manifests

| File                                            | Purpose                                        |
| ----------------------------------------------- | ---------------------------------------------- |
| `openshift/buildconfig-s2i.yaml`                | ImageStream + BuildConfig (S2I build pipeline) |
| `openshift/runtime-s2i-sqlite-persistence.yaml` | PVC + Service + DeploymentConfig (runtime)     |
| `openshift/migrate-job-sqlite.yaml`             | One-off migration Job                          |

## S2I Scripts

| File                      | Phase               | Purpose                                                      |
| ------------------------- | ------------------- | ------------------------------------------------------------ |
| `.s2i/bin/assemble`       | Build               | Installs PHP/Node deps, builds Vite assets, sets permissions |
| `.s2i/bin/run`            | Runtime             | Starts the application via the builder image's run script    |
| `.s2i/bin/save-artifacts` | Build (incremental) | Caches `vendor/` and `node_modules/` between builds          |
| `.s2i/environment`        | Build               | Sets `APP_DIR`, `DOCUMENTROOT`, and build-time defaults      |

## Prerequisites

- [`oc` CLI](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) installed and on `PATH`
- Logged in to your cluster:

  ```bash
  oc login <cluster-url>
  ```
- Target namespace exists (create if needed):

  ```bash
  oc new-project laravel-staging
  ```
- Git repository reachable from the cluster (public, or with a source secret configured)

---

## First Deployment

### Step 1 — Apply the BuildConfig

Creates an ImageStream and BuildConfig. The `ConfigChange` trigger fires a build automatically on first apply.

```bash
oc process -f openshift/buildconfig-s2i.yaml \
  -p APP_NAME=laravel-web \
  -p NAMESPACE=laravel-staging \
  -p GIT_URI=https://github.com/bdaley/openshift-laravel-sqlite.git \
  -p GIT_REF=main \
  -p BUILDER_IMAGE=quay.io/fedora/php-84 \
  -p OUTPUT_IMAGESTREAM_TAG=laravel-web:latest \
  | oc apply -f -
```

Confirm the build strategy is `Source` (not `Docker`):

```bash
oc -n laravel-staging get bc/laravel-web -o jsonpath='{.spec.strategy.type}{"\n"}'
# Expected: Source
```

Builder override examples:

```bash
# Use an ImageStreamTag from the cluster's openshift namespace
oc process -f openshift/buildconfig-s2i.yaml \
  -p BUILDER_KIND=ImageStreamTag \
  -p BUILDER_IMAGE=quay.io/fedora/php-84 \
  -p BUILDER_NAMESPACE=openshift \
  | oc apply -f -

# Patch the builder image on an already-existing BuildConfig
oc -n laravel-staging patch bc/laravel-web --type=merge \
  -p '{"spec":{"strategy":{"sourceStrategy":{"from":{"kind":"DockerImage","name":"quay.io/fedora/php-84"}}}}}' 
```

### Step 2 — Generate APP_KEY

Generate the application encryption key locally:

```bash
php artisan key:generate --show
# Outputs: base64:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=
```

Save this value — you will inject it in Step 4.

### Step 3 — Watch the Build

```bash
oc -n laravel-staging logs -f bc/laravel-web
```

Or start a build manually if the automatic trigger did not fire:

```bash
oc -n laravel-staging start-build laravel-web --follow
```

Wait until you see `Push successful` before proceeding.

### Step 4 — Apply the Runtime Template

Creates the PVC, Service, and DeploymentConfig. Replace `APP_URL` with your actual route hostname.

```bash
oc process -f openshift/runtime-s2i-sqlite-persistence.yaml \
  -p APP_NAME=laravel-web \
  -p NAMESPACE=laravel-staging \
  -p APP_URL=https://laravel-web-laravel-staging.apps.example.com \
  -p PVC_SIZE=5Gi \
  | oc apply -f -
```

Inject the required env vars that are not in the template:

```bash
oc -n laravel-staging set env dc/laravel-web \
  APP_KEY='base64:YOUR_GENERATED_KEY_HERE' \
  LOG_CHANNEL=stderr
```

`LOG_CHANNEL=stderr` routes Laravel logs to `oc logs` output, which is strongly recommended for containers.

### Step 5 — Run the Migration Job

Wait until the build from Step 3 has completed and the ImageStream tag is updated before running migrations.

Each Job run must use a unique `JOB_NAME` because Kubernetes Jobs are immutable once created. Use a version number or timestamp suffix.

```bash
oc process -f openshift/migrate-job-sqlite.yaml \
  -p APP_NAME=laravel-web \
  -p NAMESPACE=laravel-staging \
  -p JOB_NAME=laravel-web-migrate-v1 \
  | oc apply -f -
```

Watch the migration output:

```bash
oc -n laravel-staging logs -f job/laravel-web-migrate-v1
```

Confirm completion:

```bash
oc -n laravel-staging get job laravel-web-migrate-v1
# COMPLETIONS column should show 1/1
```

### Step 6 — Create a Route

```bash
oc -n laravel-staging expose svc/laravel-web \
  --hostname=laravel-web-laravel-staging.apps.example.com
```

For TLS edge termination with HTTP→HTTPS redirect:

```bash
oc -n laravel-staging create route edge laravel-web \
  --service=laravel-web \
  --hostname=laravel-web-laravel-staging.apps.example.com \
  --insecure-policy=Redirect
```

### Step 7 — Verify

```bash
# Pod should be Running
oc -n laravel-staging get pods -l app=laravel-web

# Get the route URL
oc -n laravel-staging get route laravel-web

# Hit the health endpoint
curl -I https://laravel-web-laravel-staging.apps.example.com/up
# Expected: HTTP/2 200
```

---

## Redeployment

After pushing new code, the `ImageChange` trigger on the DeploymentConfig rolls out the new image automatically once the build completes.

```bash
# 1. Trigger a new build (or push to Git to trigger automatically)
oc -n laravel-staging start-build laravel-web --follow

# 2. Run migrations if the release includes schema changes.
#    Increment JOB_NAME each time.
oc process -f openshift/migrate-job-sqlite.yaml \
  -p NAMESPACE=laravel-staging \
  -p JOB_NAME=laravel-web-migrate-v2 \
  | oc apply -f -

oc -n laravel-staging logs -f job/laravel-web-migrate-v2

# 3. Watch the rollout (triggered automatically by ImageChange)
oc -n laravel-staging rollout status dc/laravel-web

# Force a manual rollout if needed
oc -n laravel-staging rollout latest dc/laravel-web
```

---

## Required Environment Variables

Variables marked *template* are set automatically when you apply the runtime template. All others must be injected via `oc set env`.

| Variable        | Value                                                 | Source                   |
| --------------- | ----------------------------------------------------- | ------------------------ |
| `APP_ENV`       | `production`                                          | template                 |
| `APP_DEBUG`     | `false`                                               | template                 |
| `APP_URL`       | `https://<your-route>`                                | template parameter       |
| `DB_CONNECTION` | `sqlite`                                              | template                 |
| `DB_DATABASE`   | `/opt/app-root/src/database/database.sqlite`          | template                 |
| `APP_KEY`       | `base64:...` — from `php artisan key:generate --show` | **manual**               |
| `LOG_CHANNEL`   | `stderr`                                              | **manual** (recommended) |

View currently set env vars:

```bash
oc -n laravel-staging set env dc/laravel-web --list
```

---

## Persistent Volume

A single PVC (`laravel-web-data` by default, `5Gi`) is mounted at two `subPath` entries on the same claim:

| Mount path                   | SubPath    | Contents                                        |
| ---------------------------- | ---------- | ----------------------------------------------- |
| `/opt/app-root/src/database` | `database` | SQLite file + WAL/SHM journal files             |
| `/opt/app-root/src/storage`  | `storage`  | Logs, framework cache, sessions, uploaded files |

Data in these paths survives pod restarts and new deployments. If either path is missing or unwritable the application will fail to start correctly.

> **SQLite and replicas:** Keep replicas at 1. SQLite uses file locking; concurrent writes from multiple pods produce `database is locked` errors.

---

## Useful Commands

```bash
# Stream live application logs
oc -n laravel-staging logs -f dc/laravel-web

# Open an interactive shell in the running pod
oc -n laravel-staging rsh dc/laravel-web

# Run an Artisan command inside the running pod
oc -n laravel-staging rsh dc/laravel-web php artisan tinker

# Check PVC mount paths exist and are writable
oc -n laravel-staging rsh dc/laravel-web \
  ls -la /opt/app-root/src/database /opt/app-root/src/storage

# Confirm the SQLite file is present
oc -n laravel-staging rsh dc/laravel-web \
  ls -lh /opt/app-root/src/database/database.sqlite

# List all env vars on the DeploymentConfig
oc -n laravel-staging set env dc/laravel-web --list

# Force a pod restart without triggering a new build
oc -n laravel-staging rollout latest dc/laravel-web

# Scale down to 0 and back (hard restart)
oc -n laravel-staging scale dc/laravel-web --replicas=0
oc -n laravel-staging scale dc/laravel-web --replicas=1

# List all resources for this app
oc -n laravel-staging get all,pvc -l app=laravel-web
```

---

## Local Development

Local development uses Laravel Sail via `compose.yaml` and does not use the OpenShift builder image.

```bash
# Start the local environment
./vendor/bin/sail up

# Run tests
php artisan test --compact
```

---

## Troubleshooting

- **Permission denied on `storage` or `database`**: The PVC must be writable by the arbitrary UID the container runs as. The `fsGroup: 0` in the pod spec covers the default case. Diagnose with:

  ```bash
  oc -n laravel-staging rsh dc/laravel-web ls -la /opt/app-root/src/database
  ```
- **Missing Vite manifest (`Unable to locate file in Vite manifest`)**: `npm run build` did not complete during S2I assemble. Re-trigger the build and check assemble logs with `oc -n laravel-staging logs -f bc/laravel-web`.
- **App starts but `/up` returns non-200**: Verify `APP_KEY`, `APP_URL`, and `DB_DATABASE` are set:

  ```bash
  oc -n laravel-staging set env dc/laravel-web --list
  ```
- **Migration Job fails**: Confirm the PVC is bound (`oc -n laravel-staging get pvc`) and the image tag used by the Job matches the pushed ImageStream tag.
- **`database is locked` errors**: More than one replica is running. Scale back to 1:

  ```bash
  oc -n laravel-staging scale dc/laravel-web --replicas=1
  ```