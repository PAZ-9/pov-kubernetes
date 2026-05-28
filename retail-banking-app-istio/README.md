# Retail Banking App — Istio on Kind

A three-service demo application deployed on a Kind cluster with Istio service mesh. Traffic enters through the Istio ingress gateway and is routed through the service chain via Envoy sidecar proxies.

## Architecture
<img width="1643" height="534" alt="image" src="https://github.com/user-attachments/assets/11ad79cc-b649-420c-9c14-77d2cabfa3a3" />


```
curl (Host: retail-banking.example.com)
        │
        ▼
Istio IngressGateway (MetalLB IP: 172.18.255.170)
        │  Gateway: retail-banking-istio-igw
        │  VirtualService: customer-profile
        ▼
customer-profile-svc :8081
        │  upstream → account-svc
        ▼
account-svc :8082
        │  upstream → statement-svc
        ▼
statement-svc :8083
```

All services run in the `retail-banking-team` namespace with Istio sidecar injection enabled. Inter-service calls go through Envoy proxies automatically.

## Prerequisites

- Kind cluster running (see `kind-setup/`)
- `istioctl` installed
- `kubectl` configured to the correct cluster context

## Deploy

### 1. Install Istio

```bash
istioctl install --set profile=demo -y
```

### 2. Create and label the namespace

```bash
kubectl create ns retail-banking-team
kubectl label ns retail-banking-team istio-injection=enabled
```

### 3. Apply the manifests

```bash
kubectl apply -f ./retail-banking-app-istio/
```

This creates:

| Resource | Kind | Description |
|----------|------|-------------|
| `customer-profile-svc` | Deployment + Service + ServiceAccount | Entry-point service, port 8081 |
| `account-svc` | Deployment + Service + ServiceAccount | Mid-tier service, port 8082 |
| `statement-svc` | Deployment + Service + ServiceAccount | Leaf service, port 8083 |
| `retail-banking-istio-igw` | Gateway | Istio ingress gateway, HTTP on port 80 |
| `customer-profile` | VirtualService | Routes `retail-banking.example.com` → `customer-profile-svc` |

## Verify

```bash
# Check pods — each should show 2/2 (app + istio-proxy sidecar)
kubectl get pods -n retail-banking-team

# Check Istio ingress gateway external IP (assigned by MetalLB)
kubectl get svc istio-ingressgateway -n istio-system

# Test the full service chain
curl -H "Host: retail-banking.example.com" http://<EXTERNAL-IP>
```

Expected response — `customer-profile-svc` calls `account-svc`, which calls `statement-svc`:

```json
{
  "name": "customer-profile-svc",
  "body": "HelloCloudBank | Retail Banking | customer-profile-svc",
  "upstream_calls": {
    "http://account-svc...": {
      "name": "account-svc",
      "body": "HelloCloudBank | Retail Banking | account-svc",
      "upstream_calls": {
        "http://statement-svc...": {
          "name": "statement-svc",
          "body": "HelloCloudBank | Retail Banking | statement-svc",
          "code": 200
        }
      },
      "code": 200
    }
  },
  "code": 200
}
```

The `X-Envoy-Upstream-Service-Time` header on each call confirms traffic is flowing through Envoy sidecars.

## Manifests

| File | Contents |
|------|----------|
| [customer-profile.yaml](customer-profile.yaml) | `customer-profile-svc` Service, ServiceAccount, Deployment |
| [account.yaml](account.yaml) | `account-svc` Service, ServiceAccount, Deployment |
| [statement.yaml](statement.yaml) | `statement-svc` Service, ServiceAccount, Deployment |
| [istio-gateway.yaml](istio-gateway.yaml) | Istio `Gateway` — HTTP on `retail-banking.example.com` |
| [virtual-service.yaml](virtual-service.yaml) | Istio `VirtualService` — routes to `customer-profile-svc` |

## Teardown

```bash
kubectl delete -f ./retail-banking-app-istio/
kubectl delete ns retail-banking-team
istioctl uninstall --purge -y
kubectl delete ns istio-system
```
