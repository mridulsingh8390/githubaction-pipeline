# sample-multicloud-app

A single Helm chart, deployable to AKS, EKS, or GKE, that switches ingress
annotations/class based on which cloud's native controller you're targeting
— or uses NGINX Ingress Controller as a cloud-agnostic default.

## Why one chart, not three

AGIC, the AWS Load Balancer Controller, and GKE's Ingress-GCE controller are
**cluster-level infrastructure** — installed once per cluster (usually by a
platform team), not bundled into every application's chart. This chart only
sets the right `ingressClassName` and annotations to talk to whichever
controller is already running; it does not install any ingress controller
itself.

## Files

```
sample-multicloud-app/
├── Chart.yaml
├── values.yaml          # defaults — nginx profile
├── values-aks.yaml       # override: AGIC annotations
├── values-eks.yaml       # override: AWS Load Balancer Controller annotations
├── values-gke.yaml       # override: GCE Ingress + NEG annotations
├── values-nginx.yaml     # explicit nginx profile (same as default, kept for symmetry)
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── serviceaccount.yaml
    └── NOTES.txt
```

## Usage

```bash
# NGINX (default, works on any cluster with ingress-nginx installed)
helm upgrade --install my-app . \
  --set image.repository=myregistry/my-app \
  --set image.tag=1.2.3

# AKS with AGIC
helm upgrade --install my-app . -f values-aks.yaml \
  --set image.repository=myacr.azurecr.io/my-app \
  --set image.tag=1.2.3

# EKS with AWS Load Balancer Controller
helm upgrade --install my-app . -f values-eks.yaml \
  --set image.repository=<account>.dkr.ecr.<region>.amazonaws.com/my-app \
  --set image.tag=1.2.3

# GKE with built-in GCE Ingress
helm upgrade --install my-app . -f values-gke.yaml \
  --set image.repository=<region>-docker.pkg.dev/<project>/<repo>/my-app \
  --set image.tag=1.2.3
```

## Prerequisites per controller

| Controller | Cluster setup needed | Notes |
|---|---|---|
| **NGINX** (`nginx`, default) | Install `ingress-nginx` via its own Helm chart | Identical behavior on all three clouds |
| **AGIC** (`agic`, AKS) | Enable the AKS `ingress-appgw` add-on, or install AGIC separately, pointing at an existing Application Gateway | Requires an Application Gateway to already exist |
| **AWS Load Balancer Controller** (`alb`, EKS) | Install via its own Helm chart, with IRSA configured so the controller can provision ALBs/NLBs | Needs the controller's own IAM role, separate from your app's |
| **Ingress-GCE** (`gce`, GKE) | **None** — built into standard GKE clusters by default | The only one of the three that needs no extra install |

## ⚠️ Verify `ingressClassName` before deploying

`templates/_helpers.tpl` maps each controller to an assumed `IngressClass`
name (`nginx`, `azure-application-gateway`, `alb`, `gce`). **These are common
defaults, not guarantees** — check what `IngressClass` objects actually
exist in your cluster before relying on this:

```bash
kubectl get ingressclass
```

If the name differs, either rename it to match, or edit
`sample-multicloud-app.ingressClassName` in `_helpers.tpl`.

## Workload identity (app-level cloud permissions)

If your application itself needs cloud permissions (not the ingress
controller — your app's own pod), set `serviceAccount.annotations` in the
relevant values file, e.g.:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<account>:role/my-app-role"      # EKS/IRSA
    # iam.gke.io/gcp-service-account: "my-app@<project>.iam.gserviceaccount.com"  # GKE Workload Identity
    # azure.workload.identity/client-id: "<client-id>"                            # AKS Workload Identity
```
