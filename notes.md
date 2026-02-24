━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Starting Nebari Local Deployment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO]  Project: nebari-test
[INFO]  Namespace: dev
[INFO]  Nebari Version: 2025.10.1
[INFO]  Plan Only: false


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Checking Prerequisites
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[OK]    terraform found: 1.14.4
[OK]    docker found: 29.2.1
[OK]    kind found: kind v0.31.0 go1.25.5 linux/amd64
[ERROR] kubectl is NOT installed
[OK]    jq found: jq-1.8.1
[WARN]  helm not found (optional, but recommended)
[OK]    Docker daemon is running
[ERROR] Missing prerequisites: kubectl
[INFO]  Install missing tools before continuing.

-------------------
# NOTE:
update this in stage 2 main.terraform
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2" 
    }
  }
}

-------------------

For ui for all the kubernetes stuff get `k9s`

-----------------
change this or else everyhting will hang and not progress 

``
module.kubernetes-ingress.kubernetes_service.main: Still creating... [09m30s elapsed]
module.kubernetes-ingress.kubernetes_service.main: Still creating... [09m40s elapsed]
module.kubernetes-ingress.kubernetes_service.main: Still creating... [09m50s elapsed]
``
```
resource "kubernetes_service" "main" {
  -  wait_for_load_balancer = true
  +  wait_for_load_balancer = false
}
```

-----------
if you get this error 
```
[INFO]  Applying Stage 04 - Kubernetes Ingress...
module.kubernetes-ingress.kubernetes_service.main: Creating...
╷
│ Error: services "nebari-traefik-ingress" already exists
│
│   with module.kubernetes-ingress.kubernetes_service.main,
│   on modules/kubernetes/ingress/main.tf line 114, in resource "kubernetes_service" "main":
│  114: resource "kubernetes_service" "main" {
│
╵
```

kubectl delete service nebari-traefik-ingress -n dev

----------

if you get issues with loadbalancer do this 
```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
[OK]    Stage 04 - Kubernetes Ingress applied successfully
[INFO]  Waiting for Traefik load balancer IP...
[WARN]  Could not detect load balancer IP automatically.
[WARN]  Trying to determine from MetalLB IP range...
[ERROR] Failed to get load balancer IP. Check MetalLB configuration.
[INFO]  You can set the endpoint manually and re-run from stage 05.
```

```
user0@senyas-MacBook-Pro nebari-gh % kubectl get pods -n metallb-system 2>/de
v/null; echo "---"; kubectl get svc -n dev nebari-traefik-ingress 2>/dev/null
; echo "---"; kubectl get configmap -n metallb-system 2>/dev/null
NAME                          READY   STATUS    RESTARTS   AGE
controller-6ddbf5b746-bkkwz   1/1     Running   0          41m
speaker-7vr25                 1/1     Running   0          41m
---
NAME                     TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                                                                                  AGE
nebari-traefik-ingress   LoadBalancer   10.96.170.32   <pending>     80:31916/TCP,443:32757/TCP,8022:31724/TCP,8023:31871/TCP,9080:31615/TCP,8786:31852/TCP   11m
---
NAME               DATA   AGE
config             1      41m
kube-root-ca.crt   1      41m
```

```
kubectl get configmap config -n metallb-system -o yaml 2>/dev/null
```
```
kubectl get ipaddresspools -n metallb-system -o yaml 2>/dev/null; echo "---SEPARATOR---"; kubectl get l2advertisement
```
```
kubectl logs -n metallb-system -l app=metallb --tail=30 2>/dev/null
```
```
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null
```
```
Root Cause: IPv6-Only MetalLB Address Pool
The MetalLB ConfigMap has an IPv6-only address pool:


addresses: "fc00:f853:ccd:e793::164-fc00:f853:ccd:e793::196"
But your Docker kind network has two subnets:


fc00:f853:ccd:e793::/64 (IPv6)

172.18.0.0/16 (IPv4)

The problem is in 

stages/02-infrastructure/local/main.tf
 line 93:


bash
SUBNET=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')
It grabs index .IPAM.Config 0 — the first subnet — which on your machine is the IPv6 one. The IPv4 subnet is at index 1. MetalLB then calculates the address pool from the IPv6 CIDR, and on macOS, Docker desktop doesn't route IPv6 traffic from containers to the host properly, so MetalLB can't use those addresses and reports "no available IPs".


The Fix
You need the Terraform to use the IPv4 subnet (172.18.0.0/16) instead. The simplest fix is to update the bash script in 

main.tf
 to find the IPv4 subnet specifically:


for Option B
After patching, MetalLB should immediately assign an IP from 172.18.1.100-172.18.1.150 to the nebari-traefik-ingress service. You can verify with:

bash
kubectl get svc -n dev nebari-traefik-ingress
Once the EXTERNAL-IP changes from <pending> to something like 172.18.1.100, re-run from Stage 05 onward:

bash
./deploy-nebari-local.sh --from-stage 05

```

----

