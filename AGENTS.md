# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Deploying

```bash
./deploy.sh
```

This is the only deployment mechanism. It provisions everything in order across 10 phases. Use `minikube kubectl --` (not standalone `kubectl`) throughout — this is the convention used across the whole project.

To tear everything down:
```bash
minikube delete
```

To access the app after deployment:
```bash
minikube ip   # then visit http://<ip>/ in a browser
```

## Architecture

A guestbook web app on a local Minikube cluster. All resources live in the `guestbook` namespace.

**Traffic path:**
```
Browser → Ingress (nginx) → Frontend Service (ClusterIP :80) → Frontend Pods (:5000) → MariaDB Service (ClusterIP :3306) → MariaDB Pod
```

**Frontend** (`k8s/frontend/`) — Python Flask app (`app.py`) built from `alpine` using `apk`. The image is built locally with `docker build` and loaded into Minikube via `minikube image load` — it never comes from a registry. The Deployment has 2 replicas. The readiness probe hits `/messages` (verifying DB connectivity), liveness hits `/`.

**Database** (`k8s/database/`) — MariaDB 11.8 StatefulSet with 1 replica. Data is persisted via a manually provisioned PV/PVC (`k8s/storage/`) backed by a hostPath on the Minikube node. The NetworkPolicy is whitelist-only: only pods with `app: frontend`, `app: seed`, or `app: cleanup` labels can reach port 3306.

**Seed Job** (`k8s/jobs/seed-job.yaml`) — Runs once as root to create the database, application user, table schema, and seed data. The SQL script lives in a ConfigMap (`k8s/config/configmap-seed.yaml`) and is mounted as a file at `/scripts/seed.sql`.

**Cleanup CronJob** (`k8s/jobs/cleanup-cronjob.yaml`) — Runs every minute, deletes entries older than 1 minute. Uses application credentials (not root).

## Key Design Decisions

**Port values are hardcoded in the Service and StatefulSet** (`3306`) even though `DB_PORT` exists in the ConfigMap. Raw YAML has no mechanism to reference ConfigMap values in Service/StatefulSet specs — this would require Helm templating.

**MariaDB 11.x binary names** — use `mariadb` (not `mysql`) and `mariadb-admin` (not `mysqladmin`) in all exec commands and probes.

**`imagePullPolicy` is not set** on any manifest — the default `IfNotPresent` for tagged images is intentional. The frontend image is local-only; MariaDB and other images are pulled once and cached.

**`containerPort` is omitted** from the StatefulSet — it's documentation-only in Kubernetes and would duplicate `DB_PORT` from the ConfigMap with no enforcement mechanism.

**Secret uses `stringData`** (plain text) — intentional for a local learning project so credentials are readable directly from the manifest.

**`jobTemplate.metadata.labels`** is set on the CronJob so that Job objects (not just their pods) carry the `app: cleanup` label, making them queryable with `--selector=app=cleanup`.

## Configuration Reference

All workload configuration flows from two sources:

| Source | Keys | Consumed by |
|--------|------|-------------|
| ConfigMap `guestbook-config` | `DB_HOST`, `DB_PORT`, `DB_NAME` | All four workloads |
| Secret `guestbook-secret` | `MARIADB_ROOT_PASSWORD` | StatefulSet, seed Job |
| Secret `guestbook-secret` | `DB_USERNAME`, `DB_PASSWORD` | Frontend, seed Job, CronJob |

The seed Job is the only workload that uses all three secret keys — it needs root to create the app user.
