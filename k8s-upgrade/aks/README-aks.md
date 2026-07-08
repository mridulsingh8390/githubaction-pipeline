# AKS Pipelines

Two standalone GitHub Actions workflows for AKS — portable, no dependency
on any other pipeline or repo. Drop both into `.github/workflows/` of any
project that needs them.

| File | Purpose |
|---|---|
| `upgrade-aks.yml` | Two-stage approval upgrade (control plane, then worker nodes) |
| `aks-cluster-info.yml` | Read-only diagnostic snapshot of a cluster |

## Prerequisites

### Secrets (repo → Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | App Registration client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

Both pipelines share the same three secrets — set up once, use for both.

### GitHub Environments (repo → Settings → Environments)

Only `upgrade-aks.yml` needs these — `aks-cluster-info.yml` has no approval
gate since it's read-only:

- `aks-upgrade-control-plane`
- `aks-upgrade-worker-nodes`

Add required reviewers to each if you want the pipeline to actually pause
for approval (empty environments still work, they just won't block).

### OIDC setup (one-time per project)

```bash
APP_ID=$(az ad app create --display-name "github-actions-aks" --query appId -o tsv)
az ad sp create --id "$APP_ID"

TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az role assignment create --assignee "$APP_ID" --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Branch-based subject — covers aks-cluster-info.yml and the plan/validation
# jobs in upgrade-aks.yml, which have no environment: block
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "gh-branch-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# Environment-based subjects — one per environment name used in upgrade-aks.yml
for ENV in aks-upgrade-control-plane aks-upgrade-worker-nodes; do
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"gh-env-${ENV}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:<owner>/<repo>:environment:${ENV}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

> **Windows / Git Bash users**: prefix the `az role assignment create`
> command with `MSYS_NO_PATHCONV=1` — Git Bash silently mangles the
> `/subscriptions/...` argument into a Windows path otherwise, which fails
> with `(MissingSubscription)` and no obvious cause.

## `upgrade-aks.yml`

### Flow

```
plan → upgrade-control-plane (approval) → upgrade-worker-nodes (approval) → post-upgrade-validation
```

- **`plan`**: validates the cluster is healthy, discovers current/available
  versions, runs a pre-upgrade node + PDB scan (surfaces drain-blocking PDBs
  *before* you approve anything), publishes a summary.
- **`upgrade-control-plane`**: optional pre-upgrade snapshot, then upgrades
  the control plane only.
- **`upgrade-worker-nodes`**: upgrades **system node pools first, then user
  node pools** (skipped entirely if `controlPlaneOnly=true`).
- **`post-upgrade-validation`**: waits for nodes to be Ready, checks pod
  health, generates a full markdown report uploaded as a build artifact
  (retained 90 days).

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `aksResourceGroup` | Yes | — | |
| `aksClusterName` | Yes | — | |
| `targetKubernetesVersion` | No | blank (auto-pick latest) | |
| `controlPlaneOnly` | No | `false` | |
| `nodePoolName` | No | blank (all pools) | |
| `maxSurge` | No | `33%` | |
| `drainTimeoutMinutes` | No | `30` | |
| `nodeSoakDurationMinutes` | No | `5` | Wait after each **node** upgrades before continuing — AKS supports this natively |
| `createSnapshot` | No | `true` | Non-fatal if the snapshot permission is missing |

## `aks-cluster-info.yml`

Read-only — no mutations, no approval gate. Fetches cluster info, node pool
details, and per-node version/OS/runtime info via `kubectl`.

| Input | Required |
|---|---|
| `aksResourceGroup` | Yes |
| `aksClusterName` | Yes |

## Notes

- Both pipelines assume `kubectl`/`az` CLI tooling installed fresh per run
  (via `azure/setup-kubectl` and the pre-installed `az` CLI on GitHub-hosted
  runners) — no persistent state between runs.
- The snapshot feature (`az aks snapshot create`) requires the
  `Microsoft.ContainerService/snapshots/write` permission on top of
  `Contributor` — if missing, the step logs a warning and continues rather
  than failing the whole run.
