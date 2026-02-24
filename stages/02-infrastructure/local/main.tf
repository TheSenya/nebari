terraform {
  required_providers {
    kind = {
      source  = "registry.terraform.io/tehcyx/kind"
      version = "0.4.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

provider "kind" {

}

provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
  client_key             = kind_cluster.default.client_key
  client_certificate     = kind_cluster.default.client_certificate
}

provider "kubectl" {
  load_config_file       = false
  host                   = kind_cluster.default.endpoint
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
  client_key             = kind_cluster.default.client_key
  client_certificate     = kind_cluster.default.client_certificate
}

resource "kind_cluster" "default" {
  name           = "test-cluster"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role  = "general"
      image = "kindest/node:v1.32.5"
    }
  }
}

resource "kubernetes_namespace_v1" "metallb" {
  metadata {
    name = "metallb-system"
  }
}

data "kubectl_path_documents" "metallb" {
  pattern = "${path.module}/metallb.yaml"
}

resource "kubectl_manifest" "metallb" {
  for_each   = toset(data.kubectl_path_documents.metallb.documents)
  yaml_body  = each.value
  wait       = true
  depends_on = [kubernetes_namespace_v1.metallb]
}

resource "kubectl_manifest" "load-balancer" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      namespace = kubernetes_namespace_v1.metallb.metadata.0.name
      name      = "config"
    }
    data = {
      config = yamlencode({
        address-pools = [{
          name     = "default"
          protocol = "layer2"
          addresses = [
            "${local.metallb_ip_min}-${local.metallb_ip_max}"
          ]
        }]
      })
    }
  })

  depends_on = [kubectl_manifest.metallb]
}

# Use the docker CLI (which negotiates API versions correctly) instead of the
# kreuzwerker/docker provider (which has API 1.41 hardcoded and fails on Docker 29.x+).
data "external" "docker_network" {
  program = ["bash", "-c", <<-EOF
    SUBNET=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)
    if [ -z "$SUBNET" ]; then
      echo '{"subnet": "172.18.0.0/16"}' 
    else
      echo "{\"subnet\": \"$SUBNET\"}"
    fi
  EOF
  ]

  depends_on = [kind_cluster.default]
}

locals {
  metallb_ip_min = cidrhost(data.external.docker_network.result.subnet, 356)
  metallb_ip_max = cidrhost(data.external.docker_network.result.subnet, 406)
}

