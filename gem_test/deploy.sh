    1 #!/bin/bash
    2 set -e # Exit immediately if a command exits with a non-zero status.
    3
    4 # --- Configuration ---
    5 # We define the absolute path for the kubeconfig so all stages know where to look.
    6 export KUBECONFIG=$(pwd)/nebari-kubeconfig
    7 PROJECT_ROOT=$(pwd)
    8
    9 echo "Starting Nebari Manual Deployment..."
   10
   11 # --- Stage 01: Terraform State ---
   12 # WHY: This initializes the configuration object. Other stages read this
   13 # to know the project name, namespace, and provider type.
   14 echo "Applying Stage 01: Terraform State..."
   15 cd $PROJECT_ROOT/stages/01-terraform-state/local
   16 terraform init
   17 terraform apply -auto-approve
   18
   19 # --- Stage 02: Infrastructure ---
   20 # WHY: This creates the Kind cluster (locally) or Cloud resources.
   21 # We pass the kubeconfig path as a variable so Terraform can write the
   22 # connection details to a file we can use.
   23 echo "Applying Stage 02: Infrastructure..."
   24 cd $PROJECT_ROOT/stages/02-infrastructure/local
   25 terraform init
   26 terraform apply -auto-approve -var="kubeconfig_filename=$KUBECONFIG"
   27
   28 # --- Stage 03: Kubernetes Initialize ---
   29 # WHY: Now that the cluster exists, we need to create the 'dev' namespace
   30 # and install CRDs (like Traefik) that later stages rely on.
   31 echo "Applying Stage 03: Kubernetes Initialize..."
   32 cd $PROJECT_ROOT/stages/03-kubernetes-initialize
   33 terraform init
   34 terraform apply -auto-approve
   35
   36 # --- Stage 04: Kubernetes Ingress ---
   37 # WHY: Deploys Traefik. We need the Ingress Controller running so that
   38 # when we deploy Keycloak next, it has a way to receive traffic.
   39 echo "Applying Stage 04: Kubernetes Ingress..."
   40 cd $PROJECT_ROOT/stages/04-kubernetes-ingress
   41 terraform init
   42 terraform apply -auto-approve
   43
   44 # --- Stage 05: Kubernetes Keycloak ---
   45 # WHY: Installs the Keycloak software. This must happen before
   46 # Stage 06, which configures the software.
   47 echo "Applying Stage 05: Kubernetes Keycloak..."
   48 cd $PROJECT_ROOT/stages/05-kubernetes-keycloak
   49 terraform init
   50 terraform apply -auto-approve
   51
   52 # --- Stage 06: Keycloak Configuration ---
   53 # WHY: Configures realms and users. This stage provides the OIDC
   54 # Client IDs and Secrets that JupyterHub and Grafana need to function.
   55 echo "Applying Stage 06: Keycloak Configuration..."
   56 cd $PROJECT_ROOT/stages/06-kubernetes-keycloak-configuration
   57 terraform init
   58 terraform apply -auto-approve
   59
   60 # --- Stage 07: Kubernetes Services ---
   61 # WHY: The "Heavy Lifter". This installs JupyterHub, Dask, and Monitoring.
   62 # It depends on everything above being healthy.
   63 echo "Applying Stage 07: Kubernetes Services..."
   64 cd $PROJECT_ROOT/stages/07-kubernetes-services
   65 terraform init
   66 terraform apply -auto-approve
   67
   68 # --- Stage 08: Nebari TF Extensions ---
   69 # WHY: This is the catch-all for any custom user-defined Terraform.
   70 echo "Applying Stage 08: Nebari TF Extensions..."
   71 cd $PROJECT_ROOT/stages/08-nebari-tf-extensions
   72 terraform init
   73 terraform apply -auto-approve
   74
   75 # --- Stage 10 & 11: Kuberhealthy ---
   76 # WHY: These stages use raw Kubernetes manifests rather than Terraform modules.
   77 # We apply them at the end to verify the health of the completed deployment.
   78 echo "Applying Stage 10 & 11: Health Checks..."
   79 kubectl apply -f $PROJECT_ROOT/stages/10-kubernetes-kuberhealthy/crds/
   80 kubectl apply -f $PROJECT_ROOT/stages/10-kubernetes-kuberhealthy/manifests/
   81 kubectl apply -f $PROJECT_ROOT/stages/11-kubernetes-kuberhealthy-healthchecks/manifests/
   82
   83 echo "Deployment Complete!"