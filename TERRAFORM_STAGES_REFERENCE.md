# Nebari Terraform Stages: Complete Reference

> A deep-dive technical reference for every Terraform stage in a Nebari local deployment. This document explains **what** each stage does, **why** it's needed, **every input variable** and its purpose, **every output**, and **how the stages connect** to form the full platform.

---

## How Nebari Stages Work

Nebari deploys a complete data science platform by executing **10 Terraform stages in sequence**. Each stage is an independent Terraform root module with its own state, providers, and variables. Stages are linked by **outputs** — the outputs of one stage become the inputs to the next.

```
Stage 01 → Stage 02 → Stage 03 → Stage 04 → Stage 05 → Stage 06 → Stage 07 → Stage 08 → Stage 10 → Stage 11
 (state)   (cluster)  (namespace) (ingress)  (keycloak)  (kc config)  (services)  (extensions) (health op) (health checks)
```

**Why separate stages?** Each stage has a different lifecycle and failure domain. If Keycloak configuration fails, you don't need to recreate the entire cluster. You just re-run Stage 06. This also allows different providers per stage (e.g., the Docker/Kind providers in Stage 02 aren't needed in Stage 07).

---

## Stage 01: Terraform State Backend

**Directory:** `stages/01-terraform-state/local/`

### Why This Stage Exists

Every Terraform deployment needs a **state backend** — the place where Terraform stores its record of what resources it has created. In cloud deployments, this would be an S3 bucket (AWS), GCS bucket (GCP), or Azure Blob Storage — something durable and shared across team members.

For **local deployments**, this stage is a **no-op**. Terraform's default backend stores state as a file (`terraform.tfstate`) in the working directory. There are no resources to create.

### What It Does

Nothing. The `main.tf` file is empty. It exists as a placeholder so the deployment script can uniformly iterate over all stages.

### Inputs

None.

### Outputs

None.

### Why It's Still Present

Nebari's architecture is provider-agnostic. The same stage numbering works across AWS, GCP, Azure, and local. On AWS, Stage 01 would create an S3 bucket and DynamoDB table for remote state locking. Having the stage exist (even as a no-op) keeps the deployment pipeline consistent.

---

## Stage 02: Infrastructure — Kind Cluster + MetalLB

**Directory:** `stages/02-infrastructure/local/`

### Why This Stage Exists

Before you can deploy any Kubernetes services, you need a **Kubernetes cluster**. In cloud deployments, this would provision an EKS, GKE, or AKS cluster with worker nodes. For local deployment, we use **Kind (Kubernetes in Docker)** — it creates a fully functional Kubernetes cluster using Docker containers as nodes.

Additionally, Nebari's services (JupyterHub, Keycloak, etc.) need to be accessible via a **LoadBalancer IP**. Cloud providers give this natively, but Docker networks don't. So we also deploy **MetalLB** — a bare-metal load balancer that assigns real IPs from the Docker network range.

### What It Does (Step by Step)

1. **Creates a Kind cluster** named `test-cluster` with a single node running Kubernetes v1.32.5
2. **Creates the `metallb-system` namespace** where MetalLB components will live
3. **Deploys MetalLB manifests** — the controller (assigns IPs), speaker (advertises IPs via ARP/NDP), and all RBAC permissions
4. **Configures MetalLB's IP range** — calculates an IP range from the Docker `kind` network's CIDR (addresses 356-406 in the subnet), creating a ConfigMap that tells MetalLB which IPs it can hand out
5. **Writes a kubeconfig file** to disk so subsequent stages can connect to the cluster

### Terraform Providers

| Provider | Source | Version | Purpose |
|----------|--------|---------|---------|
| **kind** | `tehcyx/kind` | 0.4.0 | Creates and manages Kind clusters |
| **docker** | `kreuzwerker/docker` | 3.0.2 | Reads Docker network config (for MetalLB IP range) |
| **kubernetes** | `hashicorp/kubernetes` | (inherited) | Creates the MetalLB namespace |
| **kubectl** | `gavinbunney/kubectl` | ≥1.7.0 | Applies raw YAML manifests (MetalLB) |

### Inputs

| Variable | Type | Example Value | Description |
|----------|------|---------------|-------------|
| `kubeconfig_filename` | `string` | `"./terraform-state/kubeconfig"` | **Absolute path where the kubeconfig file will be written.** This file contains the cluster's API endpoint, CA certificate, and client credentials. Every subsequent stage uses this file to connect to the cluster. |
| `kube_context` | `string` | `""` | **Optional Kubernetes context name.** If you have multiple clusters in your kubeconfig, this selects which one to use. For a fresh Kind deployment, leave empty — it defaults to the newly created cluster. |

### Key Resources Created

| Resource | Type | Purpose |
|----------|------|---------|
| `kind_cluster.default` | Kind Cluster | The actual Kubernetes cluster running inside Docker containers |
| `kubernetes_namespace_v1.metallb` | Namespace | `metallb-system` namespace for MetalLB components |
| `kubectl_manifest.metallb` | Multiple | MetalLB controller, speaker, RBAC, ServiceAccounts (from `metallb.yaml`) |
| `kubectl_manifest.load-balancer` | ConfigMap | MetalLB address pool configuration |
| `local_file.default` | File | Writes kubeconfig to the specified path |

### MetalLB IP Calculation (How It Works)

MetalLB needs a range of IPs it can assign. The stage calculates this dynamically:

```hcl
locals {
  metallb_ip_min = cidrhost(<kind_network_subnet>, 356)
  metallb_ip_max = cidrhost(<kind_network_subnet>, 406)
}
```

If the Kind Docker network has subnet `172.18.0.0/16`, then:
- `metallb_ip_min` = `172.18.1.100` (host 356 in the subnet)
- `metallb_ip_max` = `172.18.1.150` (host 406 in the subnet)

This gives 50 IPs for LoadBalancer services — more than enough for Nebari.

### Outputs

| Output | Type | Description | Used By |
|--------|------|-------------|---------|
| `kubernetes_credentials` | `object` (sensitive) | Contains `host`, `cluster_ca_certificate`, `client_key`, `client_certificate`, `config_path` — everything needed to connect to the cluster | Provider config for Stages 03-08 |
| `kubeconfig_filename` | `string` | Path to the written kubeconfig file | All stages via `KUBECONFIG` env var |

### Why MetalLB and Not NodePort?

Nebari's ingress controller (Traefik, in Stage 04) expects a `LoadBalancer` service. Without MetalLB, the service would stay in `Pending` state forever on a bare Docker network. MetalLB provides Layer 2 load balancing using ARP, making the Traefik service reachable on a real IP address.

---

## Stage 03: Kubernetes Initialize — Namespace + CRDs

**Directory:** `stages/03-kubernetes-initialize/`

### Why This Stage Exists

Before deploying any applications, Kubernetes needs **foundational resources**:
1. A **namespace** to isolate Nebari's resources from system components
2. **Custom Resource Definitions (CRDs)** for Traefik's routing model (IngressRoute, Middleware, etc.)
3. Optional platform components (GPU drivers, autoscaler) depending on the cloud provider

This stage creates the "landing zone" that all subsequent stages deploy into.

### What It Does

1. **Creates the application namespace** (default: `dev`) — all Nebari pods, services, secrets, and configmaps live here
2. **Installs Traefik CRDs** — registers Traefik's custom Kubernetes resource types so that IngressRoute and Middleware objects can be created in later stages
3. **Skips cluster autoscaler** — only relevant for AWS (checks `cloud_provider == "aws"`)
4. **Skips NVIDIA GPU drivers** — only relevant when `gpu_enabled = true`

### Terraform Providers

| Provider | Source | Version | Purpose |
|----------|--------|---------|---------|
| **kubernetes** | `hashicorp/kubernetes` | 2.35.1 | Create namespace, secrets |
| **helm** | `hashicorp/helm` | 2.1.2 | Install Traefik CRDs chart |

Both providers are configured via the kubeconfig from Stage 02.

### Inputs

| Variable | Type | Local Value | Why It Exists |
|----------|------|-------------|---------------|
| `name` | `string` | `"nebari-test"` | **Project name prefix.** Used to tag resources and construct the cluster name (`nebari-test-dev`). This prefix appears in Kubernetes labels, Helm release names, and cloud resource tags. It ensures multiple Nebari deployments on the same cluster don't conflict. |
| `environment` | `string` | `"dev"` | **Kubernetes namespace name.** This becomes the namespace where ALL Nebari resources are deployed. Typical values: `dev`, `staging`, `production`. Kubernetes namespaces provide resource isolation — pods in different namespaces can't see each other by default. |
| `cloud_provider` | `string` | `"local"` | **Cloud provider identifier.** Determines which conditional resources to create. Valid values: `"local"`, `"aws"`, `"gcp"`, `"azure"`, `"do"`, `"existing"`. For local, this disables cloud-specific features like the cluster autoscaler (AWS only) and affects how node groups are configured. |
| `aws_region` | `string` | `""` | **AWS region for cluster autoscaler.** Only used when `cloud_provider = "aws"`. The cluster autoscaler needs to know the AWS region to call the EC2 API for scaling node groups. For local deployments, this is ignored — set to empty string. |
| `external_container_reg` | `object` | `{enabled: false}` | **External container registry configuration.** When enabled, creates a Kubernetes secret with registry credentials so pods can pull images from private registries (like AWS ECR). The object contains: `enabled` (bool), `access_key_id`, `secret_access_key`, `extcr_account`, `extcr_region`. For local deployments, this is disabled — Kind has access to local Docker images. |
| `gpu_enabled` | `bool` | `false` | **Enable NVIDIA GPU support.** When true, deploys the NVIDIA device plugin as a DaemonSet on GPU nodes. This plugin exposes `nvidia.com/gpu` as a schedulable resource so JupyterLab pods can request GPUs. Requires actual NVIDIA GPU hardware and drivers on the host. |
| `gpu_node_group_names` | `list` | `[]` | **Names of node groups with GPUs.** Tells the NVIDIA installer which nodes to target. Only relevant when `gpu_enabled = true`. For cloud deployments, this would be something like `["gpu-workers"]`. |

### Modules Used

| Module | Condition | Purpose |
|--------|-----------|---------|
| `kubernetes-initialization` | Always | Creates the namespace and any initial secrets |
| `traefik-crds` | Always | Installs Traefik's Custom Resource Definitions |
| `kubernetes-autoscaling` | `cloud_provider == "aws"` | Deploys cluster autoscaler (skipped for local) |
| `nvidia-driver-installer` | `gpu_enabled == true` | Deploys NVIDIA device plugin DaemonSet (skipped for local) |

### Outputs

None directly. The namespace creation is a prerequisite for all subsequent stages.

### Why a Separate Stage for Namespace?

CRDs must exist before any resources that reference them. If Traefik CRDs were installed in the same stage as Traefik itself (Stage 04), Terraform would fail because the IngressRoute resource type doesn't exist yet during planning. Separating CRD installation into its own stage guarantees they're registered before anyone tries to use them.

---

## Stage 04: Kubernetes Ingress — Traefik

**Directory:** `stages/04-kubernetes-ingress/`

### Why This Stage Exists

All Nebari services (JupyterHub, Keycloak, conda-store, etc.) run as individual pods inside the cluster. Users need a **single entry point** to reach all of them. This stage deploys **Traefik** as an ingress controller — a reverse proxy that sits in front of all services and routes requests based on URL path:

| URL Path | Routes To |
|----------|-----------|
| `/` | JupyterHub |
| `/auth/` | Keycloak |
| `/conda-store/` | conda-store |
| `/gateway/` | Dask Gateway |
| `/monitoring/` | Grafana |
| `/argo/` | Argo Workflows |

Traefik also handles **TLS termination** (HTTPS) using either self-signed certificates or Let's Encrypt.

### What It Does

1. **Deploys Traefik via Helm** as a Kubernetes Deployment with a `LoadBalancer` service
2. MetalLB (from Stage 02) assigns the service an **external IP address**
3. Configures **TLS certificates** — for local, uses self-signed (for production, supports Let's Encrypt via ACME)
4. Creates Traefik middlewares and entrypoints for HTTP→HTTPS redirect

### Inputs

| Variable | Type | Default | Why It Exists |
|----------|------|---------|---------------|
| `name` | `string` | — | **Project name** prefix for Helm release names and Kubernetes labels. |
| `environment` | `string` | — | **Namespace** where Traefik will be deployed. Must match Stage 03's namespace. |
| `node_groups` | `map(object({key, value}))` | — | **Node selector labels** that control which cluster nodes Traefik pods are scheduled on. For local Kind, all nodes have `kubernetes.io/os: linux`. In cloud environments, this ensures Traefik runs on "general" purpose nodes (not GPU or user nodes). The map has keys: `general`, `user`, `worker`. |
| `traefik-image` | `object({image, tag})` | — | **Traefik container image and version.** Controls which version of Traefik is deployed. Example: `{image: "traefik", tag: "2.11"}`. Newer versions may have different features or configuration syntax. |
| `certificate-service` | `string` | `"self-signed"` | **TLS certificate provider.** Options: `"self-signed"` (generates a self-signed cert — browser shows warning), `"letsencrypt"` (gets a real cert from Let's Encrypt via ACME). For local deployments, always use `"self-signed"` since Let's Encrypt requires a public domain. |
| `acme-email` | `string` | `"nebari@example.com"` | **Email for Let's Encrypt registration.** Let's Encrypt requires an email for certificate expiry notifications. Only used when `certificate-service = "letsencrypt"`. |
| `acme-server` | `string` | staging URL | **ACME server URL.** Let's Encrypt has staging (for testing, issues fake certs) and production (issues real certs) servers. Only relevant for Let's Encrypt. |
| `acme-challenge-type` | `string` | `"tls"` | **ACME challenge type.** How Let's Encrypt verifies domain ownership: `"tls"` (TLS-ALPN-01, requires port 443 accessible from internet) or `"dns"` (DNS-01, requires DNS API access). |
| `cloudflare-dns-api-token` | `string` | `null` | **Cloudflare API token for DNS challenge.** Only needed when `acme-challenge-type = "dns"` and using Cloudflare as DNS provider. Allows Traefik to automatically create DNS TXT records for verification. |
| `certificate-secret-name` | `string` | `""` | **Name of a pre-existing TLS secret.** If you already have a TLS certificate stored as a Kubernetes secret, specify its name here and Traefik will use it instead of generating one. |
| `load-balancer-ip` | `string` | `null` | **Static IP for the LoadBalancer.** On cloud providers, you can pre-allocate a static IP (e.g., AWS Elastic IP) and tell MetalLB/cloud LB to use it. `null` means "let the LB assign one automatically." |
| `load-balancer-annotations` | `map(string)` | `null` | **Cloud-specific LoadBalancer annotations.** Different cloud providers use annotations to configure their load balancers (e.g., `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"` for AWS NLB). Not needed for local. |
| `additional-arguments` | `list(string)` | `[]` | **Extra Traefik CLI arguments.** Passed directly to the Traefik binary. Useful for enabling debug logging (`["--log.level=DEBUG"]`), adding custom entrypoints, or configuring specific Traefik features. |

### Outputs

| Output | Type | Description | Used By |
|--------|------|-------------|---------|
| `load_balancer_address` | `string` | The external IP assigned to Traefik's LoadBalancer service | Stages 05-08 as the `endpoint` (combined with `.nip.io` for DNS) |

### Why nip.io?

Services like Keycloak need a **hostname** (not just an IP) for OAuth redirects and cookie domains. [nip.io](https://nip.io) is a wildcard DNS service — `172.18.1.100.nip.io` resolves to `172.18.1.100`. This gives us a working hostname without any DNS configuration.

---

## Stage 05: Keycloak Deployment

**Directory:** `stages/05-kubernetes-keycloak/`

### Why This Stage Exists

Nebari needs **identity management** — user accounts, authentication, and authorization. **Keycloak** is an open-source identity provider that handles:
- User login with passwords, GitHub OAuth, or Auth0
- Single Sign-On (SSO) across all Nebari services
- Role-based access control (RBAC) via groups
- OAuth2/OIDC token issuance for service-to-service auth

This stage deploys the Keycloak server itself. Stage 06 then configures it.

### What It Does

1. **Generates a random 32-character password** for the `nebari-bot` service account (used by other services to call the Keycloak API)
2. **Deploys Keycloak via Helm** with a PostgreSQL database, configured to serve under the `/auth` path prefix
3. Sets the **initial admin password** (the `root` user)
4. Optionally applies **custom themes** (branding for the login page)

### Inputs

| Variable | Type | Example | Why It Exists |
|----------|------|---------|---------------|
| `name` | `string` | `"nebari-test"` | **Project name** for Helm release naming and Kubernetes labels. |
| `environment` | `string` | `"dev"` | **Namespace** where Keycloak pods and services are created. |
| `endpoint` | `string` | `"172.18.1.100.nip.io"` | **External URL hostname.** Keycloak needs to know its own public URL to generate correct OAuth redirect URIs, token issuer URLs, and login page links. If this doesn't match the actual URL users access, OAuth flows will fail with "invalid redirect" errors. |
| `initial_root_password` | `string` | (from config) | **Admin password for the `root` user.** This is the superadmin account for Keycloak itself (not the Nebari realm). Used to log into the Keycloak admin console at `https://<endpoint>/auth/admin/` and for the Terraform Keycloak provider to connect in Stage 06. |
| `overrides` | `list(string)` | `[]` | **Helm chart value overrides.** Each string is a YAML-encoded set of values that override the Keycloak Helm chart defaults. Used for things like increasing memory limits, changing the database config, or setting Java options. Applied in order — later overrides take precedence. |
| `node_group` | `object({key, value})` | `{key: "kubernetes.io/os", value: "linux"}` | **Node selector for Keycloak pods.** Ensures Keycloak runs on appropriate nodes. In cloud deployments, you'd target "general" nodes (not GPU or user-specific ones) since Keycloak is an infrastructure service. |
| `themes` | `object({enabled, repository, branch})` | `{enabled: false, ...}` | **Custom Keycloak login themes.** When `enabled: true`, Keycloak clones a Git repository containing custom themes (login page branding, colors, logos) at startup. `repository` is the Git URL and `branch` is the Git branch. For local testing, leave disabled. |

### Outputs

| Output | Type | Description | Used By |
|--------|------|-------------|---------|
| `keycloak_credentials` | `object` (sensitive) | Admin console URL, username, and password | Script uses this for Keycloak provider env vars |
| `keycloak_nebari_bot_password` | `string` (sensitive) | The randomly generated password for the `nebari-bot` service account | Stage 08 (for extensions that need Keycloak API access) |

### Why Separate Deploy (05) and Configure (06)?

Keycloak must be **fully running** before it can be configured. The Terraform Keycloak provider connects to Keycloak's HTTP API — if the server isn't ready, Stage 06 would fail. By separating deployment from configuration, we can wait for Keycloak to become healthy between stages.

---

## Stage 06: Keycloak Configuration — Realm, Groups, Auth

**Directory:** `stages/06-kubernetes-keycloak-configuration/`

### Why This Stage Exists

A freshly deployed Keycloak has only a `master` realm (its internal admin realm). Nebari needs its **own realm** with:
- User groups that map to platform permissions
- OAuth clients for each service (JupyterHub, conda-store, etc.)
- Authentication flows (password login, GitHub SSO, etc.)
- Auditing and event logging

### What It Does

1. **Creates a Keycloak realm** — a logical tenant within Keycloak. All Nebari users, groups, and OAuth clients exist within this realm
2. **Creates user groups:** `admin`, `developer`, `analyst`, `superadmin`
3. **Sets default groups** — new users are automatically added to `analyst`
4. **Assigns RBAC roles:**
   - `admin` group: can manage users (query-users, query-groups, manage-users)
   - `superadmin` group: full realm admin (realm-admin permission)
5. **Creates a read-only monitoring user** in the `master` realm with view-users permission — used by services that need to list users without modifying them
6. **Configures authentication flows** for social login (GitHub OAuth, Auth0 OIDC) if enabled
7. **Enables event logging** for security auditing (admin events + user events)

### Terraform Providers

| Provider | Source | Version | Purpose |
|----------|--------|---------|---------|
| **kubernetes** | `hashicorp/kubernetes` | 2.35.1 | (inherited, for potential future use) |
| **helm** | `hashicorp/helm` | 2.1.2 | (inherited) |
| **keycloak** | `mrparkers/keycloak` | 3.7.0 | Creates realms, groups, users, roles, auth flows |

The Keycloak provider connects via environment variables:
- `KEYCLOAK_URL` = `https://<endpoint>/auth`
- `KEYCLOAK_USER` = `root`
- `KEYCLOAK_PASSWORD` = the initial root password
- `KEYCLOAK_CLIENT_ID` = `admin-cli`
- `KEYCLOAK_REALM` = `master`

### Inputs

| Variable | Type | Example | Why It Exists |
|----------|------|---------|---------------|
| `realm` | `string` | `"nebari-test"` | **Realm name.** The unique identifier for Nebari's Keycloak realm. This appears in URLs (e.g., `https://<endpoint>/auth/realms/nebari-test`). Should match the project name for consistency. |
| `realm_display_name` | `string` | `"nebari-test"` | **Human-readable realm name.** Shown on the Keycloak login page. Can include spaces and special characters (e.g., `"My Data Science Platform"`). |
| `keycloak_groups` | `set(string)` | `["admin", "developer", "analyst", "superadmin"]` | **Permission groups to create.** These groups are the foundation of Nebari's access control. JupyterHub, conda-store, and other services check group membership to determine what a user can do. The four default groups represent: `analyst` (basic users), `developer` (can create environments), `admin` (manages users), `superadmin` (full control). |
| `default_groups` | `set(string)` | `["analyst"]` | **Groups assigned to new users automatically.** When a user logs in for the first time (or is created), they're added to these groups. Setting `["analyst"]` means everyone starts with basic access. Admins can then promote users to higher groups. |
| `authentication` | `any` | `{type: "password"}` | **Authentication method configuration.** Controls how users log in. `{type: "password"}` = username/password only. `{type: "GitHub", config: {client_id: "...", client_secret: "..."}}` = GitHub OAuth. `{type: "Auth0", config: {client_id: "...", client_secret: "...", auth0_subdomain: "..."}}` = Auth0 OIDC. The `any` type allows flexible schema per auth type. |

### Outputs

| Output | Type | Description | Used By |
|--------|------|-------------|---------|
| `realm_id` | `string` | Keycloak's internal ID for the realm (UUID) | Stages 07-08: used to create OAuth clients within this realm |
| `keycloak-read-only-user-credentials` | `object` (sensitive) | `{username, password, client_id, realm}` for the monitoring user | Stage 07: passed to Argo Workflows for user lookup |

### Group Permission Model Explained

```
superadmin  →  Full Keycloak realm admin (can do anything)
    ↑
  admin     →  Can manage users (create, delete, query)
    ↑
developer   →  Can create conda environments, run workflows
    ↑
 analyst    →  Basic access: notebooks, shared environments (DEFAULT)
```

---

## Stage 07: Kubernetes Services — The Core Platform

**Directory:** `stages/07-kubernetes-services/`

### Why This Stage Exists

This is the **heart of Nebari** — it deploys all the data science services that users interact with. Everything deployed here uses Keycloak for authentication (via OAuth2 clients) and Traefik for ingress routing.

### What It Does

This single stage deploys up to **10 interconnected services**:

#### 1. NFS Server (Shared Storage)
**Why:** JupyterHub users need persistent storage that survives pod restarts. The NFS server provides shared storage that all user notebook pods mount at `/home/shared`.

#### 2. JupyterHub
**Why:** The primary user interface. JupyterHub spawns individual JupyterLab servers (pods) for each user. It integrates with Keycloak for login, conda-store for environments, and Dask Gateway for distributed computing.

#### 3. conda-store
**Why:** Manages reproducible conda environments. Users define environments via YAML, and conda-store builds and serves them. All JupyterLab pods mount the conda-store PVC so environments are available everywhere.

#### 4. Dask Gateway
**Why:** Allows users to create Dask clusters for parallel computing from within JupyterLab. The gateway manages Dask scheduler and worker pods, scaling them based on workload.

#### 5. Forward Auth (Traefik Middleware)
**Why:** Protects services behind SSO. Forward auth is a Traefik middleware that intercepts requests, redirects unauthenticated users to Keycloak, and passes identity headers to backend services.

#### 6. Monitoring — Prometheus + Grafana (Optional)
**Why:** Provides dashboards for cluster health, pod metrics, and JupyterHub usage. Grafana is the visualization layer, Prometheus collects metrics.

#### 7. Grafana Loki (Optional, with monitoring)
**Why:** Centralized log aggregation. Loki collects logs from all pods and makes them searchable in Grafana.

#### 8. Argo Workflows (Optional)
**Why:** Enables scheduled and triggered workflows (e.g., run a notebook every day at midnight). Integrates with conda-store for environment selection.

#### 9. Rook-Ceph (Conditional)
**Why:** Alternative to NFS for shared storage. CephFS provides distributed storage with better performance but higher complexity. Only deployed when `shared_fs_type = "cephfs"`.

#### 10. JupyterHub-SSH
**Why:** Allows SSH access to JupyterHub sessions for users who prefer terminal access or need to connect from VS Code/remote editors.

### Inputs — Complete Reference

#### Core Identity

| Variable | Type | Description |
|----------|------|-------------|
| `name` | `string` | Project name prefix for all resource names |
| `environment` | `string` | Kubernetes namespace |
| `endpoint` | `string` | External hostname (e.g., `172.18.1.100.nip.io`). Used to generate OAuth redirect URLs, service URLs, and TLS certificate SANs |
| `realm_id` | `string` | Keycloak realm ID from Stage 06. Used when creating OAuth clients for JupyterHub, conda-store, Dask Gateway, monitoring, and Argo |
| `cloud-provider` | `string` | Cloud provider identifier (`"local"` for Kind). Affects storage class selection, node group handling, and cloud-specific features |

#### Node Scheduling

| Variable | Type | Description |
|----------|------|-------------|
| `node_groups` | `map(object({key, value}))` | Node selectors for scheduling. Keys: `general` (infrastructure pods), `user` (JupyterLab pods), `worker` (Dask workers). Each has a label `key` and `value` that pods use as a nodeSelector. For local, all point to `kubernetes.io/os: linux` |
| `node-taint-tolerations` | `list(object)` | Kubernetes tolerations for JupyterHub pods. If your nodes have taints (e.g., `dedicated=user:NoSchedule`), pods need tolerations to be scheduled there. Each object has `key`, `operator`, `value`, `effect` |
| `worker-taint-tolerations` | `list(object)` | Same as above but for Dask scheduler/worker pods |

#### JupyterHub Configuration

| Variable | Type | Description |
|----------|------|-------------|
| `jupyterhub-image` | `object({name, tag})` | JupyterHub server image. This is the Hub itself (not users' labs). Controls the version of JupyterHub, its authenticator, spawner, and extensions |
| `jupyterlab-image` | `object({name, tag})` | Default JupyterLab image for user pods. Users see this environment when they log in. Should contain JupyterLab, extensions, and base libraries |
| `jupyterhub-theme` | `map(any)` | Branding for JupyterHub: `hub_title`, `hub_subtitle`, `welcome` (HTML message on login page), `logo` (URL to logo image) |
| `jupyterhub-shared-storage` | `number` | Size in GB for the shared NFS volume. This is the `/home/shared` directory visible to all users |
| `jupyterhub-shared-endpoint` | `string` | External NFS server IP (if using an existing NFS server instead of the built-in one). Set to `null` to deploy the built-in NFS server |
| `jupyterlab-profiles` | `any` | List of JupyterLab server profiles offered to users on login. Each profile specifies CPU, memory, GPU requests, and which conda environment to use. Empty list = single default profile |
| `jupyterlab-preferred-dir` | `string` | Default directory opened in JupyterLab's file browser. Empty = user home directory |
| `initial-repositories` | `string` | JSON map of `{"/path": "https://github.com/..."}`. Git repositories auto-cloned into user home directories on first login |
| `jupyterlab-default-settings` | `map(any)` | JupyterLab settings written to `overrides.json`. Controls theme, font size, terminal options, etc. |
| `jupyterlab-gallery-settings` | `object` | Configuration for the jupyterlab-gallery extension. `exhibits` is a list of Git repositories shown in a gallery for users to clone |
| `jupyterhub-overrides` | `list(string)` | Raw Helm value overrides for the JupyterHub chart |
| `jupyterhub-hub-extraEnv` | `string` | JSON array of extra environment variables injected into the JupyterHub pod |
| `jupyterhub-logout-redirect-url` | `string` | URL to redirect to after Keycloak logout. Empty = Keycloak default |
| `idle-culler-settings` | `any` | JupyterHub idle culler configuration: auto-shutdown inactive notebooks. Keys: `kernel_cull_idle_timeout` (minutes), `server_shutdown_no_activity_timeout` (minutes), etc. |
| `shared_fs_type` | `string` | `"nfs"` or `"cephfs"`. Determines whether shared storage uses NFS (simpler, recommended for local) or CephFS (distributed, requires Rook-Ceph) |

#### conda-store Configuration

| Variable | Type | Description |
|----------|------|-------------|
| `conda-store-image` | `string` | conda-store server container image |
| `conda-store-image-tag` | `string` | Version tag for conda-store |
| `conda-store-environments` | `any` | Map of conda environment YAML files. Keys are filenames, values are conda env specs with `name`, `channels`, and `dependencies` |
| `conda-store-filesystem-storage` | `string` | Storage allocation for conda environments on disk (e.g., `"20Gi"`). This is where built environments are stored |
| `conda-store-object-storage` | `string` | Storage for conda-store's MinIO object store. Stores environment build artifacts, logs, and metadata |
| `conda-store-default-namespace` | `string` | Default conda-store namespace (e.g., `"nebari-git"`). Users see environments organized under namespaces |
| `conda-store-extra-settings` | `map(any)` | Advanced conda-store traitlets in `c.Class.key = value` form |
| `conda-store-extra-config` | `string` | Raw Python code appended to conda-store config. Used for custom authentication backends, storage configurations, etc. |
| `conda-store-service-token-scopes` | `map(any)` | Defines API tokens for services that talk to conda-store. Each key is a service name, value defines `primary_namespace` and `role_bindings` |
| `conda-store-worker` | `any` | Resource overrides for conda-store worker pods (CPU/memory limits) |

#### Dask Gateway Configuration

| Variable | Type | Description |
|----------|------|-------------|
| `dask-worker-image` | `object({name, tag})` | Container image for Dask workers. Must be compatible with the JupyterLab image (same Python version, same key libraries) |
| `dask-gateway-profiles` | `any` | Dask cluster profiles: defines available cluster sizes. Each profile specifies worker CPU, memory, number of workers, and conda environment |

#### Monitoring & Logging

| Variable | Type | Description |
|----------|------|-------------|
| `monitoring-enabled` | `bool` | Enable Prometheus + Grafana stack. Adds ~2 GB memory usage |
| `grafana-loki-overrides` | `list(string)` | Helm value overrides for Grafana Loki (log aggregation) |
| `grafana-promtail-overrides` | `list(string)` | Helm value overrides for Promtail (log shipper) |
| `grafana-loki-minio-overrides` | `list(string)` | Helm value overrides for Loki's MinIO storage backend |
| `minio-enabled` | `bool` | Deploy MinIO alongside Loki for object storage |

#### Argo Workflows

| Variable | Type | Description |
|----------|------|-------------|
| `argo-workflows-enabled` | `bool` | Enable Argo Workflows for scheduled/triggered notebook runs |
| `argo-workflows-overrides` | `list(string)` | Helm value overrides for the Argo Workflows chart |
| `nebari-workflow-controller` | `bool` | Enable Nebari's custom workflow controller (manages workflow submissions) |
| `keycloak-read-only-user-credentials` | `map(string)` | From Stage 06. Argo uses this to query Keycloak for user information |
| `workflow-controller-image-tag` | `string` | Version tag for the Nebari workflow controller image |

#### JupyterLab Telemetry

| Variable | Type | Description |
|----------|------|-------------|
| `jupyterlab-pioneer-enabled` | `bool` | Enable JupyterLab Pioneer telemetry extension |
| `jupyterlab-pioneer-log-format` | `string` | Log format for Pioneer telemetry data |

#### JupyterHub Apps

| Variable | Type | Description |
|----------|------|-------------|
| `jhub-apps-enabled` | `bool` | Enable JupyterHub Apps (deploy Streamlit, Dash, etc. apps from JupyterHub) |
| `jhub-apps-overrides` | `string` | JSON configuration overrides for JHub Apps |

#### Infrastructure

| Variable | Type | Description |
|----------|------|-------------|
| `forwardauth_middleware_name` | `string` | Name for the Traefik forward-auth middleware resource |
| `cert_secret_name` | `string` | Name of the Kubernetes secret containing the TLS certificate (from Stage 04) |
| `rook_ceph_storage_class_name` | `string` | Kubernetes StorageClass name for Rook-Ceph volumes |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| `service_urls` | `map` | URLs and health check endpoints for all services |
| `forward-auth-middleware` | `string` | Traefik middleware name for SSO protection |
| `forward-auth-service` | `string` | Forward auth service details |

---

## Stage 08: Nebari Terraform Extensions

**Directory:** `stages/08-nebari-tf-extensions/`

### Why This Stage Exists

Nebari is designed to be **extensible**. This stage provides two extension mechanisms:
1. **Terraform extensions** — deploy custom Docker-based services with automatic OAuth integration, URL routing, and Keycloak authentication
2. **Helm extensions** — install any Helm chart as part of the deployment

It also stores the `nebari-config.yaml` as a **Kubernetes secret** so services can read the full configuration at runtime.

### What It Does

1. **Stores nebari-config.yaml as a Kubernetes secret** — services like JupyterHub can read the full Nebari configuration to make runtime decisions
2. **Deploys Terraform extensions** — each extension is a Docker container deployed as a Kubernetes Deployment with a Service, Traefik IngressRoute, and optional Keycloak OAuth client
3. **Deploys Helm extensions** — installs additional Helm charts with custom overrides

### Inputs

| Variable | Type | Description |
|----------|------|-------------|
| `environment` | `string` | Kubernetes namespace |
| `endpoint` | `string` | External hostname for generating OAuth redirect URLs |
| `realm_id` | `string` | Keycloak realm ID for creating OAuth clients |
| `tf_extensions` | `list` | List of Terraform extensions. Each has: `name`, `image` (Docker image), `urlslug` (URL path), `private` (require auth), `oauth2client` (create Keycloak client), `keycloakadmin` (give Keycloak admin access), `jwt` (pass JWT tokens), `nebariconfigyaml` (mount config), `envs` (extra env vars) |
| `helm_extensions` | `list` | List of Helm charts to install. Each has: `name`, `repository` (Helm repo URL), `chart` (chart name), `version` (chart version), `overrides` (values map) |
| `nebari_config_yaml` | `any` | The full contents of nebari-config.yaml as a data structure. Stored as a Kubernetes secret |
| `keycloak_nebari_bot_password` | `string` | Password for the nebari-bot Keycloak account. Passed to extensions that need Keycloak API access |
| `forwardauth_middleware_name` | `string` | Traefik middleware name for SSO protection of extension routes |

### Outputs

None.

---

## Stage 10: Kuberhealthy Operator

**Directory:** `stages/10-kubernetes-kuberhealthy/`

### Why This Stage Exists

After deploying everything, you need to know if services are **actually healthy**. Kuberhealthy is a Kubernetes operator that runs periodic health checks and reports status via a unified API.

### What It Does (via kubectl apply, not Terraform)

1. **Installs CRDs:** `KHCheck`, `KHJob`, `KHState` — custom resource types for defining health checks
2. **Deploys the Kuberhealthy controller** — watches for KHCheck resources and executes them on schedule
3. **Creates built-in checks:** DaemonSet health, Deployment health, internal DNS resolution
4. **Sets up RBAC** — service accounts the controller needs to create checker pods and read/write KHState resources

### Key Manifests

| Manifest | Purpose |
|----------|---------|
| `apps_v1_deployment_kuberhealthy.yaml` | Main controller pod |
| `v1_service_kuberhealthy.yaml` | Service for health status API |
| `comcast.github.io_v1_kuberhealthycheck_daemonset.yaml` | Checks that DaemonSets are healthy |
| `comcast.github.io_v1_kuberhealthycheck_deployment.yaml` | Checks that Deployments are healthy |
| `comcast.github.io_v1_kuberhealthycheck_dns-status-internal.yaml` | Checks internal DNS resolution |

---

## Stage 11: Kuberhealthy Health Checks

**Directory:** `stages/11-kubernetes-kuberhealthy-healthchecks/`

### Why This Stage Exists

Stage 10 installed Kuberhealthy itself. This stage defines **application-specific health checks** for every Nebari service.

### What It Does (via kubectl apply)

Creates `KuberhealthyCheck` resources that periodically make HTTP requests to each service and report success/failure:

| Check | Endpoint | What It Validates |
|-------|----------|-------------------|
| `jupyterhub-http-check` | `https://<endpoint>/hub/api/` | JupyterHub API is responding |
| `keycloak-http-check` | `https://<endpoint>/auth/realms/master` | Keycloak realm is accessible |
| `conda-store-http-check` | `https://<endpoint>/conda-store/api/v1/` | conda-store API is up |
| `dask-gateway-http-check` | `https://<endpoint>/gateway/api/version` | Dask Gateway API is responding |
| `argo-http-check` | `https://<endpoint>/argo/` | Argo Workflows UI is serving (if enabled) |
| `grafana-http-check` | `https://<endpoint>/monitoring/api/health` | Grafana API is healthy (if enabled) |

### Why Separate from Stage 10?

Health checks reference specific service URLs that only exist after Stage 07 deploys the services. By separating the operator (Stage 10) from the check definitions (Stage 11), we can install the operator early and add checks after all services are deployed.

---

## Summary: Why Every Stage Is Needed

| Stage | If Removed, What Breaks |
|-------|------------------------|
| **01** | Nothing (no-op for local), but breaks cloud deploy consistency |
| **02** | No Kubernetes cluster exists. Nothing can be deployed |
| **03** | No namespace — all pods have nowhere to run. No Traefik CRDs — ingress routes can't be created |
| **04** | No ingress — services exist but are unreachable from outside the cluster |
| **05** | No authentication — users can't log in, services can't verify identity |
| **06** | No realm or groups — Keycloak exists but has no config. OAuth clients don't exist |
| **07** | No data science services — the platform has no functionality |
| **08** | No config secret, no extensions — services can't read nebari-config.yaml at runtime |
| **10** | No health monitoring — broken services go undetected |
| **11** | No service-specific health checks — Kuberhealthy runs but doesn't check Nebari services |
