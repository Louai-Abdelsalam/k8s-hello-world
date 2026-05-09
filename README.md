# Kubernetes Guestbook — Design and Planning Spec

---

# Part 1: Design

## Project Overview

A simple guestbook web application deployed on a local Kubernetes cluster. Visitors can view and submit messages, which are stored in a persistent database. The application itself is intentionally minimal — the purpose of this project is to gain hands-on experience with a broad set of commonly used Kubernetes native resource types, including stateful workloads.

## Constraints and Assumptions

- **Cluster environment:** Local Minikube cluster (single node)
- **No cloud provider integrations** — everything runs locally
- **No TLS/HTTPS** — plain HTTP only
- **Single-replica database** — high availability is out of scope
- **Application complexity is minimal** — the focus is on Kubernetes manifests, not application code
- **Breadth over depth** — the goal is hands-on exposure to many resource types rather than deep mastery of a few
- **Plaintext secrets:** The Secret resource in this project contains credentials in plain form. This is intentional — the project runs locally with no real security risk, and the values are needed in the spec so that manifests can be reproduced exactly. In a real environment, secrets would be managed via a secrets manager or sealed secrets.

## Architecture

The system consists of four workload components:

1. **Frontend app** — A single container that serves a web page and exposes a REST API for reading and writing guestbook entries. Deployed as a Deployment with multiple replicas.

2. **MariaDB database** — A single-replica database that stores guestbook entries. Deployed as a StatefulSet with persistent storage, ensuring data survives pod restarts and rescheduling.

3. **Database seed Job** — A one-shot Job that runs a migration to create the application database user, create the required table, and seed initial data.

4. **Cleanup CronJob** — A scheduled CronJob that runs every 1 minute and removes guestbook entries older than 1 minute.

### How They Connect

- The **frontend** discovers the database via a **ClusterIP Service** that provides a stable internal DNS name for the MariaDB pod.
- The **outside world** reaches the frontend via an **Ingress** resource, which routes HTTP traffic to a **ClusterIP Service** sitting in front of the frontend Deployment. The Ingress Controller (installed via Minikube's built-in addon) does the actual traffic handling.
- The **seed Job** and **cleanup CronJob** both connect to the database the same way the frontend does — through the MariaDB ClusterIP Service.
- A **NetworkPolicy** restricts access to MariaDB, allowing connections only from the frontend, the Job, and the CronJob. All other traffic to the database is denied.

### Request Flow

```
Browser → Ingress → Frontend ClusterIP Service → Frontend Pod → MariaDB ClusterIP Service → MariaDB Pod
```

## Resource Inventory

The project includes 15 resources across 12 distinct Kubernetes resource types:

| Resource Type         | Name (conceptual)            | Purpose                                                                 |
|-----------------------|------------------------------|-------------------------------------------------------------------------|
| Namespace             | Guestbook namespace          | Isolates all project resources from the default namespace               |
| StorageClass          | Guestbook StorageClass       | Defines how storage is provisioned; used to bind the PV and PVC         |
| PersistentVolume      | MariaDB PV                   | Manually provisioned storage for the database (learning exercise)       |
| PersistentVolumeClaim | MariaDB PVC                  | Requests and binds to the PV via StorageClass; mounted by the StatefulSet |
| StatefulSet           | MariaDB                      | Runs the database with stable pod identity and persistent storage       |
| Service (ClusterIP)   | MariaDB Service              | Provides stable internal DNS name for the database                      |
| Deployment            | Frontend app                 | Runs the web app and API with multiple replicas                         |
| Service (ClusterIP)   | Frontend Service             | Load balances across frontend replicas; target for the Ingress          |
| Ingress               | Frontend Ingress             | Routes external HTTP traffic to the frontend Service                    |
| ConfigMap             | App configuration            | Stores non-sensitive config consumed by all workloads                   |
| ConfigMap             | Seed SQL script              | Contains the SQL script mounted as a file into the seed Job             |
| Secret                | Database credentials         | Stores sensitive credentials (root password for StatefulSet and Job; app credentials for frontend, Job, and CronJob) |
| Job                   | Database migration/seed      | Runs once to create the app user, table schema, and seed data           |
| CronJob               | Entry cleanup                | Runs every 1 minute to delete entries older than 1 minute               |
| NetworkPolicy         | MariaDB access restriction   | Restricts database access to only the frontend, Job, and CronJob       |

## Configuration and Secrets

### Non-sensitive (ConfigMap)

- Database hostname (the MariaDB Service name)
- Database port
- Database name

### Sensitive (Secret)

- MariaDB root password
- Application database username
- Application database password

The MariaDB root password is consumed by the MariaDB StatefulSet for initial database setup and by the seed Job to create the application-level database user. The frontend, cleanup CronJob, and (for its regular operations) the seed Job all use the application-level credentials — they never have access to the root password.

All four workloads (frontend Deployment, MariaDB StatefulSet, seed Job, cleanup CronJob) consume the ConfigMap. The StatefulSet uses it for its own port and database name configuration; the other three use it to discover and connect to MariaDB.

## Storage

- **StorageClass:** Defines the provisioner (`k8s.io/minikube-hostpath`) and reclaim policy. Both the PV and PVC reference this StorageClass, and Kubernetes binds them based on matching StorageClass, capacity, and access mode.
- **PersistentVolume:** 1Gi, manually created as a learning exercise (in production, dynamic provisioning via the StorageClass would create PVs automatically)
- **PersistentVolumeClaim:** Requests 1Gi with ReadWriteOnce access mode (mountable by one node at a time)
- **Mount target:** MariaDB's data directory (`/var/lib/mysql`), ensuring data persists across pod restarts and rescheduling

## Networking

### Internal Traffic

- **MariaDB ClusterIP Service** — Gives the database a stable DNS name inside the cluster. The frontend, Job, and CronJob all use this name to connect to MariaDB without needing to know which pod is running or where it's scheduled.
- **Frontend ClusterIP Service** — Sits in front of the frontend Deployment, load balancing across replicas. Also serves as the target that the Ingress routes traffic to.

### External Traffic

- **Ingress** — Accepts HTTP traffic from outside the cluster and routes it to the frontend ClusterIP Service based on routing rules. The Ingress Controller (nginx, installed via Minikube's built-in addon) reads the Ingress resource and handles the actual traffic routing. No hostname is set on the Ingress (matches any hostname); access the application via the IP returned by `minikube ip`.

### Access Restrictions

- **NetworkPolicy on MariaDB** — Only allows incoming connections on port 3306 from the frontend Deployment, the seed Job, and the cleanup CronJob. All other pods in the cluster are denied access to the database. This enforces the principle of least privilege at the network level.

### Traffic Flow Summary

```
External:  Browser → Ingress → Frontend Service → Frontend Pods
Internal:  Frontend Pods → MariaDB Service → MariaDB Pod
Internal:  Job/CronJob Pods → MariaDB Service → MariaDB Pod
Denied:    Any other pod → MariaDB Service (blocked by NetworkPolicy)
```

---

# Part 2: Planning

## Technical Decisions

| Decision              | Value                                                                 |
|-----------------------|-----------------------------------------------------------------------|
| Cluster tool          | Minikube                                                              |
| Namespace             | `guestbook`                                                           |
| MariaDB image         | `mariadb:11.8`                                                        |
| Frontend image        | `guestbook-frontend:1.0` (custom, built locally from `alpine`)        |
| Job/CronJob image     | `mariadb:11.8` (reuses database image for its mysql CLI)              |
| MariaDB port          | 3306                                                                  |
| Frontend port         | 5000 (Flask default)                                                  |
| Frontend Service port | 80 (forwards to container port 5000)                                  |
| Ingress               | Routes `/` (pathType: Prefix) to `guestbook-frontend` Service on port 80; no hostname; ingressClassName: nginx |
| Naming convention     | `guestbook-<component>` for all resources                             |
| Labels                | `app: <component>` and `project: guestbook` on all resources          |
| StorageClass provisioner | `k8s.io/minikube-hostpath`                                         |

## Frontend Application Description

The frontend is a minimal Python Flask application with the following behavior:

- **GET `/`** — Serves a minimal HTML page that displays existing guestbook entries and provides a form to submit a new entry. The page calls the API endpoints using JavaScript.
- **GET `/messages`** — Returns all entries from the `entries` table as JSON.
- **POST `/messages`** — Accepts a JSON body with a `message` field, inserts it into the `entries` table, and returns the created entry as JSON.

The application depends on Flask and PyMySQL. It reads database connection details from environment variables populated by the ConfigMap and Secret.

The container image is based on `alpine`, with `python3`, `py3-flask`, and `py3-pymysql` installed via apk. No pip or requirements.txt — all dependencies are managed by Alpine's package manager. The application code is copied into `/app` and run with `python3`.

## Detailed Resource Inventory

### Namespace

- **Kind:** Namespace
- **Name:** `guestbook`

### StorageClass

- **Kind:** StorageClass
- **Name:** `guestbook-storage`
- **Provisioner:** `k8s.io/minikube-hostpath`
- **Reclaim policy:** Retain

### PersistentVolume

- **Kind:** PersistentVolume
- **Name:** `guestbook-mariadb-pv`
- **Capacity:** 1Gi
- **Access mode:** ReadWriteOnce
- **StorageClass:** `guestbook-storage`
- **Host path:** `/data/guestbook-mariadb` (directory on the minikube node, created automatically if absent)

### PersistentVolumeClaim

- **Kind:** PersistentVolumeClaim
- **Name:** `guestbook-mariadb-pvc`
- **Namespace:** `guestbook`
- **Requests:** 1Gi
- **Access mode:** ReadWriteOnce
- **StorageClass:** `guestbook-storage`
- **Binds to:** `guestbook-mariadb-pv` (matched via StorageClass, capacity, and access mode)
- **Referenced by:** MariaDB StatefulSet

### StatefulSet (MariaDB)

- **Kind:** StatefulSet
- **Name:** `guestbook-mariadb`
- **Namespace:** `guestbook`
- **Replicas:** 1
- **Image:** `mariadb:11.8`
- **Container port:** 3306
- **Labels:** `app: mariadb`, `project: guestbook`
- **Volume mount:** `guestbook-mariadb-pvc` mounted at `/var/lib/mysql`
- **Env from ConfigMap (`guestbook-config`):** `DB_NAME`; `DB_PORT` mapped to `MARIADB_TCP_PORT` (overrides MariaDB's default port, even if with the same port value — this keeps the port consistent via a single source of truth)
- **Env from Secret (`guestbook-secret`):** `MARIADB_ROOT_PASSWORD`
- **Resources:** requests 250m CPU / 256Mi memory; limits 500m CPU / 512Mi memory
- **Readiness probe:** exec `sh -c "mysqladmin ping -uroot -p$MARIADB_ROOT_PASSWORD"`
- **Liveness probe:** same command as readiness probe
- **Note:** Does not use `volumeClaimTemplates`; references the existing PVC directly

### Service (MariaDB)

- **Kind:** Service
- **Name:** `guestbook-mariadb`
- **Namespace:** `guestbook`
- **Type:** ClusterIP
- **Port:** 3306 → target port 3306
- **Selector:** `app: mariadb`
- **Note:** This name (`guestbook-mariadb`) becomes the database hostname used by other workloads via DNS

### Deployment (Frontend)

- **Kind:** Deployment
- **Name:** `guestbook-frontend`
- **Namespace:** `guestbook`
- **Replicas:** 2
- **Image:** `guestbook-frontend:1.0`
- **Container port:** 5000
- **Labels:** `app: frontend`, `project: guestbook`
- **Env from ConfigMap (`guestbook-config`):** `DB_HOST`, `DB_PORT`, `DB_NAME`
- **Env from Secret (`guestbook-secret`):** `DB_USERNAME`, `DB_PASSWORD`
- **Resources:** requests 100m CPU / 128Mi memory; limits 300m CPU / 256Mi memory (per replica)
- **Readiness probe:** HTTP GET `/messages` on port 5000 — pod only receives traffic once it can successfully query the database
- **Liveness probe:** HTTP GET `/` on port 5000

### Service (Frontend)

- **Kind:** Service
- **Name:** `guestbook-frontend`
- **Namespace:** `guestbook`
- **Type:** ClusterIP
- **Port:** 80 → target port 5000
- **Selector:** `app: frontend`

### Ingress

- **Kind:** Ingress
- **Name:** `guestbook-ingress`
- **Namespace:** `guestbook`
- **Ingress class:** `nginx` (`ingressClassName: nginx`) — required so the nginx controller installed by Minikube's ingress addon knows to process this resource
- **Rules:** HTTP path `/` with `pathType: Prefix` routes to Service `guestbook-frontend` on port 80. `Prefix` matches all URLs (since every path starts with `/`), which is correct for a single-service ingress.
- **Hostname:** None (matches any hostname)
- **Requires:** Minikube ingress addon enabled (`minikube addons enable ingress`)
- **Access via:** IP returned by `minikube ip`

### ConfigMap (App Configuration)

- **Kind:** ConfigMap
- **Name:** `guestbook-config`
- **Namespace:** `guestbook`
- **Data:**
  - `DB_HOST`: `guestbook-mariadb`
  - `DB_PORT`: `3306`
  - `DB_NAME`: `guestbook`
- **Consumed by:** StatefulSet, Deployment, Job, CronJob

### ConfigMap (Seed SQL Script)

- **Kind:** ConfigMap
- **Name:** `guestbook-seed-sql`
- **Namespace:** `guestbook`
- **Data key:** `seed.sql`
- **Data value:** See [Seed SQL Script](#seed-sql-script) below
- **Consumed by:** Job (mounted as a file at `/scripts/seed.sql`)

### Secret

- **Kind:** Secret
- **Name:** `guestbook-secret`
- **Namespace:** `guestbook`
- **Type:** Opaque
- **Data:**
  - `MARIADB_ROOT_PASSWORD`: `rootpass123`
  - `DB_USERNAME`: `guestbook_user`
  - `DB_PASSWORD`: `guestbook_pass`
- **Consumed by:** StatefulSet (only `MARIADB_ROOT_PASSWORD`), Job (all three keys), Deployment (only `DB_USERNAME`, `DB_PASSWORD`), CronJob (only `DB_USERNAME`, `DB_PASSWORD`)
- **Note:** Values are in plain text intentionally. See the disclaimer in Constraints and Assumptions.

### Job (Database Seed)

- **Kind:** Job
- **Name:** `guestbook-seed`
- **Namespace:** `guestbook`
- **Image:** `mariadb:11.8`
- **Labels:** `app: seed`, `project: guestbook`
- **Command:** `["sh", "-c", "mariadb -h $DB_HOST -P $DB_PORT -u root -p$MARIADB_ROOT_PASSWORD < /scripts/seed.sql"]` — `sh -c` ensures the command is interpreted by a shell rather than exec'd directly as the container's main process
- **Restart policy:** Never
- **Resources:** requests 100m CPU / 128Mi memory; limits 200m CPU / 256Mi memory
- **Volume mount:** `guestbook-seed-sql` ConfigMap mounted at `/scripts/seed.sql` (subPath: `seed.sql`)
- **Env from ConfigMap (`guestbook-config`):** `DB_HOST`, `DB_PORT`, `DB_NAME`
- **Env from Secret (`guestbook-secret`):** `MARIADB_ROOT_PASSWORD`, `DB_USERNAME`, `DB_PASSWORD`

### CronJob (Cleanup)

- **Kind:** CronJob
- **Name:** `guestbook-cleanup`
- **Namespace:** `guestbook`
- **Image:** `mariadb:11.8`
- **Schedule:** `*/1 * * * *` (every 1 minute)
- **Labels:** `app: cleanup`, `project: guestbook`
- **Command:** `["sh", "-c", "mariadb -h $DB_HOST -P $DB_PORT -u $DB_USERNAME -p$DB_PASSWORD $DB_NAME -e \"DELETE FROM entries WHERE created_at < NOW() - INTERVAL 1 MINUTE;\""]` — `sh -c` ensures the command is interpreted by a shell rather than exec'd directly as the container's main process
- **Restart policy:** Never
- **Resources:** requests 50m CPU / 64Mi memory; limits 100m CPU / 128Mi memory
- **Env from ConfigMap (`guestbook-config`):** `DB_HOST`, `DB_PORT`, `DB_NAME`
- **Env from Secret (`guestbook-secret`):** `DB_USERNAME`, `DB_PASSWORD`

### NetworkPolicy

- **Kind:** NetworkPolicy
- **Name:** `guestbook-network-policy`
- **Namespace:** `guestbook`
- **Applied to:** Pods matching `app: mariadb`
- **Ingress rules:** Allow TCP port 3306 from pods matching `app: frontend`, `app: seed`, or `app: cleanup`
- **Effect:** All other ingress to MariaDB pods is denied

## Seed SQL Script

The following SQL is stored in the `guestbook-seed-sql` ConfigMap under the key `seed.sql`. The seed Job executes this script against MariaDB as root.

```sql
CREATE DATABASE IF NOT EXISTS guestbook;

CREATE USER IF NOT EXISTS 'guestbook_user'@'%' IDENTIFIED BY 'guestbook_pass';
GRANT ALL PRIVILEGES ON guestbook.* TO 'guestbook_user'@'%';
FLUSH PRIVILEGES;

USE guestbook;

CREATE TABLE IF NOT EXISTS entries (
    id INT AUTO_INCREMENT PRIMARY KEY,
    message VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO entries (message) VALUES ('Welcome to the guestbook!');
INSERT INTO entries (message) VALUES ('This is a sample entry.');
INSERT INTO entries (message) VALUES ('Kubernetes is fun!');
```

## Cleanup SQL Command

The CronJob runs the following inline command. It connects to MariaDB as the application user and deletes entries older than 1 minute.

```sql
DELETE FROM guestbook.entries WHERE created_at < NOW() - INTERVAL 1 MINUTE;
```

## Build Sequence

### Phase 1 — Cluster and Namespace

- Start Minikube: `minikube start`
- Enable the ingress addon: `minikube addons enable ingress`
- Apply the Namespace manifest
- **Verify:** `kubectl get namespace guestbook` returns the namespace with status Active

### Phase 2 — StorageClass

- Apply the StorageClass manifest
- **Verify:** `kubectl get storageclass guestbook-storage` returns the StorageClass

### Phase 3 — Storage

- Apply the PV and PVC manifests
- **Verify:** `kubectl get pv guestbook-mariadb-pv` shows status Bound; `kubectl get pvc guestbook-mariadb-pvc -n guestbook` shows status Bound

### Phase 4 — Configuration

- Apply the ConfigMap (`guestbook-config`), the seed SQL ConfigMap (`guestbook-seed-sql`), and the Secret (`guestbook-secret`)
- **Verify:** `kubectl describe configmap guestbook-config -n guestbook` shows keys `DB_HOST`, `DB_PORT`, `DB_NAME`; `kubectl describe configmap guestbook-seed-sql -n guestbook` shows key `seed.sql`; `kubectl describe secret guestbook-secret -n guestbook` shows keys `MARIADB_ROOT_PASSWORD`, `DB_USERNAME`, `DB_PASSWORD`

### Phase 5 — Database

- Apply the MariaDB StatefulSet and MariaDB ClusterIP Service manifests
- **Verify:** `kubectl get pods -n guestbook -l app=mariadb` shows the pod in Running status; exec into the pod and run `mariadb -u root -prootpass123 -e "SELECT 1"` to confirm MariaDB is responding

### Phase 6 — Seed Job

- Apply the Job manifest
- **Verify:** `kubectl get jobs -n guestbook` shows `guestbook-seed` with status Completed; then verify:
  - Table exists: `kubectl exec <mariadb-pod-name> -n guestbook -- mariadb -u root -prootpass123 guestbook -e "DESCRIBE entries"`
  - Seed data present: `kubectl exec <mariadb-pod-name> -n guestbook -- mariadb -u root -prootpass123 guestbook -e "SELECT * FROM entries"`
  - App user works: `kubectl exec <mariadb-pod-name> -n guestbook -- mariadb -u guestbook_user -pguestbook_pass guestbook -e "SELECT 1"`

### Phase 7 — Frontend

- Build the frontend image: `docker build --tag guestbook-frontend:1.0 --network=host .` (from the directory containing the Flask app and Dockerfile)
- Load the image into Minikube: `minikube image load guestbook-frontend:1.0`
- Apply the frontend Deployment and frontend ClusterIP Service manifests
- **Verify:** `kubectl get pods -n guestbook -l app=frontend` shows 2 pods in Running status; port-forward to one pod (`kubectl port-forward <pod> 5000:5000 -n guestbook`) and test:
  - Read: `curl http://localhost:5000/messages` returns seed entries as JSON
  - Write: `curl -X POST http://localhost:5000/messages -H "Content-Type: application/json" -d '{"message":"Test entry"}'` returns the created entry; subsequent GET confirms it appears

### Phase 8 — NetworkPolicy

- Apply the NetworkPolicy manifest
- **Verify allowed traffic:** The frontend pods can still reach MariaDB (repeat the curl test from Phase 7 to confirm reads and writes still work)
- **Verify denied traffic:** Run a temporary pod with a non-matching label and attempt to connect: `kubectl run test-pod --rm -it --image=mariadb:11.8 -n guestbook -- mariadb -h guestbook-mariadb -u guestbook_user -pguestbook_pass guestbook -e "SELECT 1"` — this should time out or be refused

### Phase 9 — CronJob

- Apply the CronJob manifest
- **Verify:** Wait approximately 1 minute; `kubectl get cronjobs -n guestbook` shows `guestbook-cleanup` with a recent last schedule time; `kubectl get jobs -n guestbook -l app=cleanup` shows a completed job; inspect its logs (`kubectl logs job/<job-name> -n guestbook`) to confirm the DELETE statement ran without errors

### Phase 10 — Ingress

- Apply the Ingress manifest
- **Verify:** Run `minikube ip` to get the cluster IP; access `http://<minikube-ip>/` in a browser and confirm the guestbook page loads, displays entries, and allows submitting new entries
