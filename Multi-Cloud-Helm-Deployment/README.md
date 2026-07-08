# Multi-Cloud Kubernetes Helm Deploy Pipeline

A single GitHub Actions workflow (`deploy-multicloud-helm.yml`) that deploys a Helm
chart to **AKS**, **EKS**, or **GKE** — you pick the provider at run time. Only
cluster-context setup (login + credentials) differs per provider; the actual Helm
install, rollback behavior, and rollout verification are identical across all three.

## How it works

```
validate inputs → reject 'latest' tag → cloud login → get cluster credentials
   → helm upgrade --install --atomic → verify rollout → summary
```

Everything from "get cluster credentials" onward is shared code — once `kubectl`/
`helm` are pointed at a cluster, the deploy logic doesn't care which cloud it's on.

> **GitHub Actions UI limitation:** `workflow_dispatch` forms can't show/hide fields
> based on another field's value. All provider-specific inputs are always visible —
> fill in only the block matching your chosen `clusterProvider`.

## Prerequisites

### 1. Cloud credentials (OIDC — no long-lived secrets)

Only the secrets for the provider you plan to use are needed:

| Provider | Secrets |
|---|---|
| AKS | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| EKS | `AWS_DEPLOY_ROLE_ARN` |
| GKE | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

Each requires a one-time federated identity setup (App Registration + federated
credential for Azure; IAM role trusting GitHub's OIDC provider for AWS; Workload
Identity Federation pool for GCP) — no static keys stored in GitHub.

**EKS is two-layered and easy to get wrong:** the IAM role needs `eks:DescribeCluster`
to fetch kubeconfig, but actually running `helm`/`kubectl` inside the cluster also
requires that IAM principal to be mapped to Kubernetes RBAC via the cluster's
**access entries** (or the legacy `aws-auth` ConfigMap). IAM permissions alone are
not sufficient on EKS, unlike AKS (Azure AD) or GKE (Cloud IAM), where cloud-level
permissions map through more directly.

### 2. GitHub environment

The workflow gates on an `environment: multicloud-deploy-prod` block. In
**Settings → Environments**, either:
- create `multicloud-deploy-prod` and assign required reviewers (recommended if this
  can touch production), or
- delete the `environment:` block from the workflow entirely if you want unattended
  deploys (e.g. for a dev/staging-only pipeline)

### 3. Helm chart already in the repo

`helmChartPath` must point to a chart that exists in the checked-out repo (default
`./helm/my-app`). This workflow doesn't package or publish charts — it only deploys
what's already there.

## Inputs

### `clusterProvider` (required)
`aks` | `eks` | `gke` — default `aks`

### AKS (`clusterProvider = aks`)
| Input | Required | Notes |
|---|---|---|
| `aksResourceGroup` | **Yes** | |
| `aksClusterName` | **Yes** | |

### EKS (`clusterProvider = eks`)
| Input | Required | Notes |
|---|---|---|
| `eksClusterName` | **Yes** | |
| `awsRegion` | No | Default `us-east-1` |

### GKE (`clusterProvider = gke`)
| Input | Required | Notes |
|---|---|---|
| `gkeClusterName` | **Yes** | |
| `gkeLocation` | **Yes** | Zone or region, e.g. `us-central1-a` |
| `gcpProject` | **Yes** | |

### Common (all providers)
| Input | Required | Default | Notes |
|---|---|---|---|
| `namespace` | **Yes** | `default` | |
| `imageName` | **Yes** | — | No placeholder default — always type the real image |
| `imageTag` | **Yes** | `latest` | **Blocked if left as `latest`** — see below |
| `helmReleaseName` | **Yes** | `my-app` | |
| `helmChartPath` | **Yes** | `./helm/my-app` | |

## Safety behavior

- **`imageTag = latest` is rejected outright** with a clear error before any cloud
  login happens. Deploy an immutable version/digest instead. If your use case
  genuinely needs `latest` to remain deployable (e.g. a throwaway dev environment),
  this check can be turned into a toggleable input instead of a hard block — ask if
  you want that.
- **`helm upgrade --atomic`** auto-rolls-back to the last good release revision if
  the deploy fails, instead of leaving the release in a `failed`/`pending-upgrade`
  state.
- **`Verify rollout`** actually checks rollout status (`kubectl rollout status` with
  a 60s timeout) rather than just printing an unchecked pod list.
- **`concurrency` group** is scoped to provider + cluster + namespace + release, so
  two dispatches targeting the same release can't race and corrupt Helm's release
  history.

## Running the pipeline

**Actions → Multi-Cloud Kubernetes Helm Deploy → Run workflow**, then:

1. Select `clusterProvider`
2. Fill in that provider's required fields
3. Fill in the common deployment fields (namespace, image, tag, release, chart path)
4. Run — if an environment approval is configured, it pauses until a reviewer
   approves

## Known limitations

- **`Verify rollout` assumes the standard `app.kubernetes.io/instance` Helm label.**
  If your chart doesn't set it, adjust the label selector in that step.
- **No native rollback trigger beyond `--atomic`.** If you need a separate
  "rollback to a specific prior revision" workflow (independent of a failed deploy),
  that's not covered here — ask if you want a companion rollback pipeline.
- **This workflow doesn't build or push the image** — it assumes `imageName:imageTag`
  already exists in a registry reachable by the target cluster (ACR for AKS, ECR for
  EKS, Artifact Registry for GKE, or any registry the cluster's nodes can pull from).
