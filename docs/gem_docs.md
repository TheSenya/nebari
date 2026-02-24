  Prerequisites for Manual Deployment
   1. Terraform/OpenTofu: Ensure you have the binary installed.
   2. Configuration: Nebari generates _nebari.tf.json files in each stage directory. These contain the configuration derived from your nebari-config.yaml.
   3. Order: You must deploy these stages in numerical order (01 through 11).

  ---


  Stage 01: Terraform State
   * Purpose: This stage initializes the global configuration state. It stores the input nebari-config.yaml as a Terraform resource so other stages can reference the desired cluster state.
   * Manual Steps:
   1     cd stages/01-terraform-state/local
   2     terraform init
   3     terraform apply


  Stage 02: Infrastructure
   * Purpose: Provisions the actual compute environment.
       * Local: Creates a kind (Kubernetes-in-Docker) cluster and sets up MetalLB for local LoadBalancer support.
       * Cloud (AWS/GCP/Azure): Would provision VPCs, EKS/GKE/AKS clusters, and Node Groups.
   * Manual Steps:
   1     cd stages/02-infrastructure/local
   2     terraform init
   3     terraform apply -var="kubeconfig_filename=$(pwd)/nebari-kubeconfig"


  Stage 03: Kubernetes Initialize
   * Purpose: Prepares the cluster for Nebari services.
       * Creates the primary namespace (usually dev).
       * Installs Traefik CRDs (Custom Resource Definitions).
       * Sets up Cluster Autoscaler and GPU drivers (if applicable).
       * Initializes External Container Registry credentials.
   * Manual Steps:


   1     cd stages/03-kubernetes-initialize
   2     terraform init
   3     terraform apply


  Stage 04: Kubernetes Ingress
   * Purpose: Deploys the Traefik Ingress controller to handle external traffic. It sets up the LoadBalancer service and manages TLS certificates (via Let's Encrypt or self-signed).
   * Manual Steps:
   1     cd stages/04-kubernetes-ingress
   2     terraform init
   3     terraform apply


  Stage 05: Kubernetes Keycloak
   * Purpose: Installs the Keycloak identity provider using Helm. This provides the backbone for all authentication across JupyterHub, Grafana, and Argo.
   * Manual Steps:
   1     cd stages/05-kubernetes-keycloak
   2     terraform init
   3     terraform apply


  Stage 06: Keycloak Configuration
   * Purpose: Configures the Keycloak "master" and "nebari" realms.
       * Sets up identity providers (GitHub, Auth0, etc.).
       * Creates default groups (admin, developer, analyst) and permissions.
   * Manual Steps:


   1     cd stages/06-kubernetes-keycloak-configuration
   2     terraform init
   3     terraform apply


  Stage 07: Kubernetes Services
   * Purpose: The core stage that deploys the user-facing applications:
       * JupyterHub: The multi-user notebook environment.
       * Conda-Store: Manages shared environments and build artifacts.
       * Dask Gateway: Orchestrates scalable compute clusters.
       * Argo Workflows: Handles pipelined automation.
       * Monitoring: Prometheus, Grafana, and Loki for logs/metrics.
   * Manual Steps:
   1     cd stages/07-kubernetes-services
   2     terraform init
   3     terraform apply


  Stage 08: Nebari TF Extensions
   * Purpose: A hooks stage allowing users to inject custom Terraform modules or Helm charts into the deployment without modifying the core Nebari code.
   * Manual Steps:
   1     cd stages/08-nebari-tf-extensions
   2     terraform init
   3     terraform apply


  Stage 10: Kuberhealthy
   * Purpose: Installs the Kuberhealthy operator, which runs synthetic tests within the cluster to ensure the Kubernetes control plane and networking are functional.
   * Manual Steps:
       * This stage often involves applying raw manifests found in stages/10-kubernetes-kuberhealthy/manifests.


   1     kubectl apply -f stages/10-kubernetes-kuberhealthy/crds/
   2     kubectl apply -f stages/10-kubernetes-kuberhealthy/manifests/


  Stage 11: Kuberhealthy Healthchecks
   * Purpose: Deploys specific health checks for the Nebari services (e.g., "Can I reach the JupyterHub API?", "Is Keycloak responding?").
   * Manual Steps:
   1     kubectl apply -f stages/11-kubernetes-kuberhealthy-healthchecks/manifests/

  ---


  Important Note on Variables
  When running manually, you will notice that many stages require variables (like endpoint, realm_id, or node_groups). In a standard deployment, Nebari's internal engine passes these as outputs from one stage to the next. For a truly manual run, you must collect the
  outputs from the previous stage and pass them as -var="key=value" or via a .tfvars file.