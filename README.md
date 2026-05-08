# Kubernetes Guestbook — Design Spec

## Project Overview

A simple guestbook web application deployed on a local Kubernetes cluster. Visitors can view and submit messages, which are stored in a persistent database. The application itself is intentionally minimal — the purpose of this project is to gain hands-on experience with a broad set of commonly used Kubernetes native resource types, including stateful workloads.

## Constraints and Assumptions

- **Cluster environment:** Local Minikube cluster (single node)
- **No cloud provider integrations** — everything runs locally
- **No TLS/HTTPS** — plain HTTP only
- **Single-replica database** — high availability is out of scope
- **Application complexity is minimal** — the focus is on Kubernetes manifests, not application code
- **Breadth over depth** — the goal is hands-on exposure to many resource types rather than deep mastery of a few

## Architecture

The system consists of three workload components:

1. **Frontend app** — A single container that serves a web page and exposes a REST API for reading and writing guestbook entries. Deployed as a Deployment with multiple replicas.

2. **MariaDB database** — A single-replica database that stores guestbook entries. Deployed as a StatefulSet with persistent storage, ensuring data survives pod restarts and rescheduling.

3. **Database seed Job** — A one-shot Job that runs a migration to create the required table and optionally seeds initial data.

4. **Cleanup CronJob** — A scheduled CronJob that periodically removes guestbook entries older than a set threshold (e.g. 7 days).

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

The project includes 13 resources across 11 distinct Kubernetes resource types:

| Resource Type         | Name (conceptual)            | Purpose                                                                 |
|-----------------------|------------------------------|-------------------------------------------------------------------------|
| Namespace             | Guestbook namespace          | Isolates all project resources from the default namespace               |
| PersistentVolume      | MariaDB PV                   | Manually provisioned storage for the database (learning exercise)       |
| PersistentVolumeClaim | MariaDB PVC                  | Requests and binds to the PV; mounted by the MariaDB StatefulSet        |
| StatefulSet           | MariaDB                      | Runs the database with stable pod identity and persistent storage       |
| Service (ClusterIP)   | MariaDB Service              | Provides stable internal DNS name for the database                      |
| Deployment            | Frontend app                 | Runs the web app and API with multiple replicas                         |
| Service (ClusterIP)   | Frontend Service             | Load balances across frontend replicas; target for the Ingress          |
| Ingress               | Frontend Ingress             | Routes external HTTP traffic to the frontend Service                    |
| ConfigMap             | App configuration            | Stores non-sensitive config consumed by the frontend, Job, and CronJob  |
| Secret                | Database credentials         | Stores sensitive credentials consumed by all workloads (root password by the StatefulSet; app credentials by the frontend, Job, and CronJob) |
| Job                   | Database migration/seed      | Runs once to create the table schema and insert initial data            |
| CronJob               | Entry cleanup                | Runs on a schedule to delete guestbook entries older than a set threshold |
| NetworkPolicy         | MariaDB access restriction   | Restricts database access to only the frontend, Job, and CronJob       |

## Configuration and Secrets

### Non-sensitive (ConfigMap)

- Database hostname (the MariaDB Service name)
- Database port
- Database name (e.g. "guestbook")

### Sensitive (Secret)

- MariaDB root password
- Application database username
- Application database password

The MariaDB root password is consumed by the MariaDB StatefulSet for initial database setup and by the seed Job if it needs to create the application-level database user. The frontend, cleanup CronJob, and (for its regular operations) the seed Job all use the application-level credentials — they never have access to the root password.

All four workloads (frontend Deployment, MariaDB StatefulSet, seed Job, cleanup CronJob) consume the ConfigMap. The StatefulSet uses it for its own port and database name configuration; the other three use it to discover and connect to MariaDB.

## Storage

- **PersistentVolume:** 1Gi, manually created as a learning exercise (in production, dynamic provisioning via a StorageClass would handle this automatically)
- **PersistentVolumeClaim:** Requests 1Gi with ReadWriteOnce access mode (mountable by one node at a time)
- **Mount target:** MariaDB's data directory, ensuring data persists across pod restarts and rescheduling

## Networking

### Internal Traffic

- **MariaDB ClusterIP Service** — Gives the database a stable DNS name inside the cluster. The frontend, Job, and CronJob all use this name to connect to MariaDB without needing to know which pod is running or where it's scheduled.
- **Frontend ClusterIP Service** — Sits in front of the frontend Deployment, load balancing across replicas. Also serves as the target that the Ingress routes traffic to.

### External Traffic

- **Ingress** — Accepts HTTP traffic from outside the cluster and routes it to the frontend ClusterIP Service based on routing rules. The Ingress Controller (nginx, installed via Minikube's built-in addon) reads the Ingress resource and handles the actual traffic routing.

### Access Restrictions

- **NetworkPolicy on MariaDB** — Only allows incoming connections from the frontend Deployment, the seed Job, and the cleanup CronJob. All other pods in the cluster are denied access to the database. This enforces the principle of least privilege at the network level.

### Traffic Flow Summary

```
External:  Browser → Ingress → Frontend Service → Frontend Pods
Internal:  Frontend Pods → MariaDB Service → MariaDB Pod
Internal:  Job/CronJob Pods → MariaDB Service → MariaDB Pod
Denied:    Any other pod → MariaDB Service (blocked by NetworkPolicy)
```
