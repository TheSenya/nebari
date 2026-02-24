Nebari Local Deployment Script & Documentation
Create a comprehensive Bash deployment script and documentation to deploy Nebari locally using Terraform (not OpenTofu), running all 10 stages sequentially with proper variable passing between stages.

User Review Required
IMPORTANT

This is a complex deployment. The stages have many interconnected variables and module dependencies. The script will provide sensible defaults, but some values (e.g., container image tags, storage sizes) may need adjusting for your machine's resources. The script is designed for development/testing purposes only — not production.

WARNING

Stages 03–08 require submodules in stages/*/modules/ directories. These modules must already exist in your repo (they appear to be present). If any modules are missing, the corresponding terraform init will fail and the script will report which module is missing.

CAUTION

Stage 02 creates a Kind cluster on Docker. This will consume significant resources. Ensure Docker is running and has ≥ 8GB memory and ≥ 4 CPU cores allocated. The script will create a cluster named test-cluster and a Docker network named kind.

Proposed Changes
Deployment Script
[NEW] 
deploy-nebari-local.sh
A Bash script that orchestrates running all Nebari stages using Terraform. Key features:

Prerequisites check: Validates terraform, docker, kind, kubectl, and helm are installed
Per-stage execution: Runs terraform init, terraform plan, and terraform apply for each of the 10 stages in order
State management: Uses local Terraform state with separate state files per stage in a terraform-state/ directory
Variable passing: Captures outputs from earlier stages (e.g., kubeconfig, Keycloak credentials, load balancer IP) and passes them as -var flags to later stages
Error handling: Stops on first failure with clear error messages
Destroy support: --destroy flag to tear down in reverse order
Dry-run/plan-only mode: --plan-only flag to just run terraform plan without applying
The stages executed in order:

Stage 01 – Terraform state (no-op for local)
Stage 02 – Kind cluster + MetalLB load balancer
Stage 03 – Kubernetes namespace init + Traefik CRDs
Stage 04 – Traefik ingress controller
Stage 05 – Keycloak deployment via Helm
Stage 06 – Keycloak realm/group/auth configuration
Stage 07 – Core services (JupyterHub, conda-store, Dask Gateway, NFS, monitoring, Argo, forward-auth)
Stage 08 – Terraform/Helm extensions + nebari-config secret
Stage 10 – Kuberhealthy CRDs and operator
Stage 11 – Kuberhealthy health checks for all services
Per-Stage Variable Files
[NEW] 
terraform-vars/stage-02.tfvars
Variables for Kind cluster creation (kubeconfig path, kube context).

[NEW] 
terraform-vars/stage-03.tfvars
Variables for Kubernetes init (name, namespace, cloud provider, GPU settings, container registry).

[NEW] 
terraform-vars/stage-04.tfvars
Variables for Traefik ingress (node groups, certificate service, Traefik image).

[NEW] 
terraform-vars/stage-05.tfvars
Variables for Keycloak deployment (endpoint, initial root password, node group, themes).

[NEW] 
terraform-vars/stage-06.tfvars
Variables for Keycloak configuration (realm, groups, authentication).

[NEW] 
terraform-vars/stage-07.auto.tfvars.json
Complex JSON variables for all Stage 07 services (JupyterHub, conda-store, Dask Gateway, monitoring, Argo, etc.).

[NEW] 
terraform-vars/stage-08.auto.tfvars.json
Variables for extensions (tf_extensions, helm_extensions, nebari_config_yaml).

Documentation
[NEW] 
DEPLOYMENT_GUIDE.md
Comprehensive documentation covering:

Overview – What Nebari is and what local deployment means
Prerequisites – All required tools with version requirements and install instructions
Architecture Diagram – Mermaid diagram of stage dependencies and what each deploys
Per-Stage Deep Dive – For each of the 10 stages:
Purpose and what it deploys
Terraform providers used
Key variables and their meanings
Outputs passed to subsequent stages
Troubleshooting tips
Running the Deployment – Step-by-step instructions
Accessing Services – URLs and credentials for JupyterHub, Keycloak, conda-store, Dask Gateway, Monitoring
Destroying the Deployment – Tear-down instructions
Troubleshooting – Common issues and solutions
Verification Plan
Automated Tests
Script syntax check: bash -n deploy-nebari-local.sh to verify no syntax errors
ShellCheck: shellcheck deploy-nebari-local.sh to lint for common Bash issues (if installed)
HCL syntax validation: Run terraform validate on each stage directory to confirm the tfvars are structurally valid
Manual Verification
The user should review the generated .tfvars files and adjust values (image tags, storage sizes, etc.) for their environment
The user should run ./deploy-nebari-local.sh --plan-only first to see what Terraform would create without applying changes
Full deployment test: ./deploy-nebari-local.sh (requires Docker running, ~10-20 min)