# GKE Pipelines

Two standalone GitHub Actions workflows for GKE — portable, no dependency
on any other pipeline or repo. Drop both into `.github/workflows/` of any
project that needs them.

| File | Purpose |
|---|---|
| `upgrade-gke.yml` | Two-stage approval upgrade (control plane, then node pools) |
| `gke-cluster-info.yml` | Read-only diagnostic snapshot of a cluster |

## Prerequisites

### Secrets (repo → Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full WIF provider resource path |
| `GCP_SERVICE_ACCOUNT` | Service account email |

Both pipelines share the same two secrets.

### GitHub Environments (repo → Settings → Environments)

Only `upgrade-gke.yml` needs these — `gke-cluster-info.yml` has no approval
gate since it's read-only:

- `gke-upgrade-control-plane`
- `gke-upgrade-worker-nodes`

### OIDC setup (one-time per project)

```bash
GCP_PROJECT_ID="your-project-id"
PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')

gcloud iam workload-identity-pools create "github-pool" \
  --project="$GCP_PROJECT_ID" --location="global" \
  --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="$GCP_PROJECT_ID" --location="global" \
  --workload-identity-pool="github-pool" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --issuer-uri="https://token.actions.githubusercontent.com"

gcloud iam service-accounts create "github-actions-sa" --project="$GCP_PROJECT_ID"
SA_EMAIL="github-actions-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$GCP_PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/OWNER/REPO"
# Replace OWNER/REPO above before running.

gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/container.admin"

echo "GCP_WORKLOAD_IDENTITY_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
echo "GCP_SERVICE_ACCOUNT=${SA_EMAIL}"
```

## `upgrade-gke.yml`

### Flow

```
plan → upgrade-control-plane (approval) → upgrade-worker-nodes (approval) → post-upgrade-validation
```

### ⚠️ Feature parity with the AKS version — read before assuming equivalence

GKE also lacks native equivalents for a few things the AKS pipeline
supports directly:

| AKS feature | GKE substitute | Why it's not the same |
|---|---|---|
| `az aks snapshot create` (real, restorable) | Pre-upgrade **state dump** (cluster + node pool config as JSON, uploaded as an artifact) | Audit/rollback *reference* only — not restorable. GKE's control plane is fully managed by Google; there's no user-triggerable snapshot API. |
| `--node-soak-duration` (per-node wait) | `interPoolSoakMinutes` (wait **between node pools**) | Coarser — no per-node soak parameter exists in the GKE API. |
| System vs. user pool ordering | Node pools upgraded in listing order | GKE node pools have no `mode` field like AKS pools do — no equivalent ordering concept to preserve. |
| `maxSurge` as a percentage | `maxSurgeUpgrade` as an **integer node count** | GKE's surge upgrade config wants integers, not percentages — this is a real API difference, not a simplification on my part. |

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `gkeClusterName` | Yes | — | |
| `gkeLocation` | Yes | — | Zone or region, e.g. `us-central1-a` |
| `gcpProject` | Yes | — | |
| `targetKubernetesVersion` | No | blank (auto-pick latest) | |
| `controlPlaneOnly` | No | `false` | |
| `nodePoolName` | No | blank (all pools) | |
| `maxSurgeUpgrade` | No | `1` | Integer, not percentage — see parity note above |
| `interPoolSoakMinutes` | No | `5` | See parity note above |
| `createStateDump` | No | `true` | Not a restorable snapshot — see parity note above |

## `gke-cluster-info.yml`

Read-only — no mutations, no approval gate. Fetches cluster info, node pool
details, and per-node version/OS/runtime info via `kubectl`.

| Input | Required |
|---|---|
| `gkeClusterName` | Yes |
| `gkeLocation` | Yes |
| `gcpProject` | Yes |

## Notes

- **GKE requires the `gke-gcloud-auth-plugin`** for `kubectl` to
  authenticate — both pipelines install it automatically via `apt-get`
  before any `kubectl` command runs. If you see `kubectl` auth errors
  despite `gcloud` calls succeeding, this plugin is the first thing to
  check.
- If an upgrade fails mid-way, GKE has no snapshot/restore path —
  recovery means fixing forward (re-running the update), not rolling back,
  since Google manages the control plane state directly.
