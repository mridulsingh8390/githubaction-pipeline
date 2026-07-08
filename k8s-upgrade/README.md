# Multi-Cloud Kubernetes Upgrade Pipeline

A single GitHub Actions workflow (`k8s-multicloud-upgrade-pipeline.yml`) that upgrades
**AKS**, **EKS**, or **GKE** clusters — you pick the provider at run time, and the same
plan → approve → upgrade flow handles all three.

## How it works

```
plan  →  upgrade-control-plane (approval #1)  →  upgrade-worker-nodes (approval #2)  →  post-upgrade-validation
```

| Job | What it does | Approval gate |
|---|---|---|
| `plan` | Detects current version and computes/validates the target version | — |
| `upgrade-control-plane` | Upgrades only the control plane | `k8s-upgrade-control-plane` environment |
| `upgrade-worker-nodes` | Upgrades node pools/groups (skipped if `controlPlaneOnly=true`) | `k8s-upgrade-worker-nodes` environment |
| `post-upgrade-validation` | Confirms all nodes are `Ready` after upgrade | — |

Two **separate** approval gates mean you can require different reviewers for the
control plane vs. worker nodes (e.g. platform team vs. app team), since worker node
upgrades drain and reschedule running workloads.

## Prerequisites

### 1. Cloud credentials (OIDC — no long-lived secrets)

Only the secrets for the provider(s) you plan to use are needed:

| Provider | Repo/org secrets required |
|---|---|
| AKS | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| EKS | `AWS_EKS_ROLE_ARN` |
| GKE | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

Each requires a one-time federated identity setup so GitHub Actions can authenticate
without storing static keys:

- **Azure**: App Registration + federated credential trusting your repo/branch
- **AWS**: IAM role with a trust policy for GitHub's OIDC provider, granted
  `eks:UpdateClusterVersion`, `eks:UpdateNodegroupVersion`, `eks:DescribeUpdate`,
  `eks:DescribeCluster`, `eks:ListNodegroups`, `eks:DescribeNodegroup`
- **GCP**: Workload Identity Federation pool/provider bound to a service account with
  `container.clusters.update` and related GKE permissions

### 2. GitHub environments

Create these two environments in **Settings → Environments** and assign required
reviewers to each (can be the same people or different groups):

- `k8s-upgrade-control-plane`
- `k8s-upgrade-worker-nodes`

## Creating test clusters

Use an **older Kubernetes version** so there's something to upgrade to, and disable
auto-upgrade so the cloud provider doesn't upgrade the cluster out from under your test.

### AKS

```bash
az login
az group create --name aks-test-rg --location eastus
az aks get-versions --location eastus -o table   # pick an older version

az aks create \
  --resource-group aks-test-rg \
  --name aks-test-cluster \
  --location eastus \
  --kubernetes-version 1.29.7 \
  --node-count 2 \
  --node-vm-size Standard_DS2_v2 \
  --generate-ssh-keys \
  --enable-oidc-issuer \
  --enable-workload-identity
```

### EKS

```bash
# eksctl handles VPC/subnets/IAM automatically
eksctl create cluster \
  --name eks-test-cluster \
  --region us-east-1 \
  --version 1.29 \
  --nodegroup-name eks-test-ng \
  --node-type t3.medium \
  --nodes 2 \
  --managed
```

### GKE

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud container get-server-config --zone us-central1-a --format="yaml(validMasterVersions)"

gcloud container clusters create gke-test-cluster \
  --zone us-central1-a \
  --project YOUR_PROJECT_ID \
  --cluster-version 1.29.7-gke.1104000 \
  --num-nodes 2 \
  --machine-type e2-medium \
  --release-channel None \
  --no-enable-autoupgrade
```

## Running the pipeline

Trigger via **Actions → Multi-Cloud Kubernetes Upgrade Pipeline → Run workflow**, then
fill in only the fields matching your chosen provider:

| `clusterProvider` | Required inputs |
|---|---|
| `aks` | `aksResourceGroup`, `aksClusterName` |
| `eks` | `eksClusterName` (`awsRegion` defaults to `us-east-1`) |
| `gke` | `gkeClusterName`, `gkeLocation`, `gcpProject` |

Common inputs (all optional, sensible defaults):

- `targetKubernetesVersion` — blank = auto-pick (latest allowed for AKS/GKE, current+1
  minor for EKS)
- `controlPlaneOnly` — skip worker node upgrade entirely
- `nodePoolName` — blank = upgrade all pools/groups
- `maxSurge` — percentage for AKS, integer surge count for GKE, ignored for EKS
- `drainTimeoutMinutes` — AKS only; EKS/GKE use provider defaults

The run pauses at each approval gate until a required reviewer approves it in the
Actions UI.

## Known provider differences

These aren't bugs — they're real API/CLI differences between the three services that
this pipeline works around rather than papers over:

- **EKS only allows one minor-version jump per upgrade.** If you don't specify a
  target, the pipeline computes current+1 minor automatically. Requesting a bigger
  jump will trigger a warning and likely be rejected by the AWS API.
- **`drainTimeoutMinutes` only maps directly to AKS.** EKS and GKE don't expose an
  equivalent CLI knob — those steps log a warning and fall back to provider defaults.
- **`maxSurge` semantics differ.** AKS treats it as a true percentage. GKE requires an
  integer surge count, so a `%` value gets stripped and used as a number (not a true
  equivalent). EKS instead sets `maxUnavailablePercentage` on the node group's
  update config.
- **GKE requires the `gke-gcloud-auth-plugin`** for `kubectl` to authenticate — the
  pipeline installs it automatically in the validation job.

## Cleaning up test clusters

```bash
# AKS
az aks delete --resource-group aks-test-rg --name aks-test-cluster --yes --no-wait
az group delete --name aks-test-rg --yes --no-wait

# EKS
eksctl delete cluster --name eks-test-cluster --region us-east-1

# GKE
gcloud container clusters delete gke-test-cluster --zone us-central1-a --project YOUR_PROJECT_ID --quiet
```
