# EKS + Cilium + Istio + Route53 + HTTPS

A proof-of-concept deployment of a retail banking microservices application on Amazon EKS with Cilium CNI, Istio service mesh, Route53 custom domain, and HTTPS via self-signed TLS certificate.

## Architecture

```
Internet User
     ↓
Route53 DNS (retail-banking.cloud9.ceo)
     ↓
AWS ELB (Internet-facing)
     ↓
Istio Ingress Gateway (Port 80 / Port 443)
     ↓
Istio VirtualService (routing rules)
     ↓
retail-banking-team namespace (Istio sidecar injection enabled)
     ├── customer-profile-svc  :8081  →  account-svc
     ├── account-svc           :8082  →  statement-svc
     └── statement-svc         :8083
```

**Networking layer:** Cilium eBPF dataplane handles all pod networking and security. Istio Envoy sidecars (2/2 containers per pod) manage service-to-service traffic, observability, and mTLS inside the mesh. HTTPS terminates at the Istio Ingress Gateway using a Kubernetes TLS secret.

## Environment

| Component          | Value                          |
|--------------------|--------------------------------|
| Platform           | Amazon EKS                     |
| Region             | eu-west-2                      |
| Kubernetes Version | 1.35                           |
| CNI                | Cilium 1.19.2                  |
| Service Mesh       | Istio 1.29.0 (demo profile)    |
| Node Group         | 3 × t3.medium (private subnet) |
| Domain             | retail-banking.cloud9.ceo      |
| TLS                | OpenSSL self-signed certificate |

## Repository Structure

```
pov-cap-2026/
├── apps/
│   └── Retail-Banking-App/        # Core EKS + Cilium + Istio deployment manifests
│       ├── controlplane.yaml      # eksctl ClusterConfig (control plane only)
│       ├── nodegroup.yaml         # eksctl managed node group (3 × t3.medium)
│       ├── customer-profile.yaml  # customer-profile-svc Deployment + Service
│       ├── account.yaml           # account-svc Deployment + Service
│       ├── statement.yaml         # statement-svc Deployment + Service
│       ├── istio-gateway.yaml     # Istio Gateway (HTTP :80 + HTTPS :443)
│       └── virtual-services.yaml  # Istio VirtualService routing rules
├── cilium-helm-chart-v1.19.2/    # Vendored Cilium Helm chart
├── kindconfig/                    # Kind cluster configs (multi-region local dev)
├── kindsetup/                     # Kind cluster setup/teardown scripts
├── terraform-eks/                 # Terraform alternative for EKS provisioning
└── pov-kubernetes/                # Git-tracked mirror of manifests
    ├── eks-cilium-istio-retail-banking/
    └── retail-banking-app-istio/
```

## Prerequisites

- `eksctl` installed and configured
- `kubectl` installed
- `helm` installed
- `istioctl` installed
- AWS CLI configured with a profile named `master-console-admin`
- Route53 hosted zone for your domain

## Deployment Steps

### 1. Create EKS Control Plane

```bash
eksctl create cluster -f apps/Retail-Banking-App/controlplane.yaml \
  --profile master-console-admin
```

Verify — no worker nodes expected yet:
```bash
kubectl get nodes
# No resources found
```

### 2. Install Cilium CNI

Default addons are disabled in the control plane config so Cilium can own the dataplane.

```bash
helm install cilium cilium-helm-chart-v1.19.2/cilium \
  --namespace kube-system \
  --set eni.enabled=true \
  --set ipam.mode=eni \
  --set egressMasqueradeInterfaces=eth+ \
  --set routingMode=native \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<YOUR_EKS_API_ENDPOINT> \
  --set k8sServicePort=443
```

### 3. Create Worker Nodes

```bash
eksctl create nodegroup -f apps/Retail-Banking-App/nodegroup.yaml \
  --profile master-console-admin
```

Verify — 3 Ready nodes and Cilium DaemonSet:
```bash
kubectl get nodes
kubectl get ds -A
cilium status
```

### 4. Install Istio

```bash
istioctl install --set profile=demo
```

Verify:
```bash
kubectl get pods -n istio-system
# istiod, istio-ingressgateway, istio-egressgateway — all Running 1/1
```

### 5. Create Application Namespace

```bash
kubectl create namespace retail-banking-team
kubectl label ns retail-banking-team istio-injection=enabled
```

### 6. Deploy Microservices

```bash
kubectl apply -f apps/Retail-Banking-App/customer-profile.yaml
kubectl apply -f apps/Retail-Banking-App/account.yaml
kubectl apply -f apps/Retail-Banking-App/statement.yaml
```

Verify — each pod shows 2/2 (app container + Envoy sidecar):
```bash
kubectl get pods -n retail-banking-team
```

### 7. Configure Istio Ingress (HTTP)

```bash
kubectl apply -f apps/Retail-Banking-App/istio-gateway.yaml
kubectl apply -f apps/Retail-Banking-App/virtual-services.yaml
```

Test via ELB hostname:
```bash
ELB=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -H "Host: retail-banking.cloud9.ceo" http://$ELB
```

### 8. Configure Route53

In the AWS Console (or CLI), create an **A record alias** in your hosted zone:

- **Name:** `retail-banking`
- **Type:** A (Alias)
- **Target:** Alias to Application and Classic Load Balancer → Europe (London) → select the Istio ELB
- **Routing policy:** Simple routing
- **Evaluate target health:** Yes

Test via domain:
```bash
curl http://retail-banking.cloud9.ceo
```

### 9. Generate Self-Signed TLS Certificate

```bash
openssl req -x509 -sha256 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout retail-banking.key \
  -out retail-banking.crt \
  -subj "/CN=retail-banking.cloud9.ceo/O=cloud9"

kubectl create secret tls retail-banking-credential \
  --key retail-banking.key \
  --cert retail-banking.crt \
  -n istio-system
```

### 10. Enable HTTPS

The `istio-gateway.yaml` already includes the HTTPS server block with `credentialName: retail-banking-credential`. Re-apply to activate it:

```bash
kubectl apply -f apps/Retail-Banking-App/istio-gateway.yaml
```

Test HTTPS:
```bash
curl -k https://retail-banking.cloud9.ceo

# Verify certificate
openssl s_client -connect retail-banking.cloud9.ceo:443
```

## Service Call Chain

Each request to `retail-banking.cloud9.ceo` triggers a synchronous upstream call chain:

```
customer-profile-svc (8081)
  → account-svc.retail-banking-team.svc.cluster.local:8082
      → statement-svc.retail-banking-team.svc.cluster.local:8083
```

All inter-service traffic is routed through Envoy sidecars and carries Istio telemetry headers (`X-Envoy-Decorator-Operation`, `X-Envoy-Upstream-Service-Time`).

## Validation Checklist

| Validation                  | Command                                              |
|-----------------------------|------------------------------------------------------|
| EKS cluster created         | `kubectl get nodes`                                  |
| Cilium healthy              | `cilium status`                                      |
| Istio installed             | `kubectl get pods -n istio-system`                   |
| Sidecar injection working   | `kubectl get pods -n retail-banking-team` (2/2 ready)|
| Microservices running       | `kubectl get pods -n retail-banking-team`            |
| Istio Gateway working       | `kubectl get svc -n istio-system`                    |
| Route53 domain working      | `curl http://retail-banking.cloud9.ceo`              |
| HTTPS working               | `curl -k https://retail-banking.cloud9.ceo`          |
| Self-signed cert verified   | `openssl s_client -connect retail-banking.cloud9.ceo:443` |

## Key Design Decisions

- **`disableDefaultAddons: true`** in the control plane config — prevents AWS VPC CNI from being installed so Cilium can own ENI networking from the start.
- **`kubeProxyReplacement=true`** — Cilium replaces kube-proxy entirely using eBPF, reducing latency and eliminating iptables rules.
- **Private node networking** — worker nodes sit in private subnets; only the Istio ELB is internet-facing.
- **TLS termination at the gateway** — HTTPS terminates at the Istio Ingress Gateway; traffic inside the mesh travels over HTTP (Envoy handles mTLS between sidecars separately).
- **Self-signed certificate** — suitable for PoC; for production use ACM or cert-manager with Let's Encrypt.
