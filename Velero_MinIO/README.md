# Kubernetes Backup & Restore with Velero (AKS / EKS / GKE)

End-to-end GitHub Actions pipeline suite for backing up and restoring
Kubernetes workloads using [Velero](https://velero.io/), with a separate,
self-contained 3-pipeline set per cloud provider. Each provider uses its
native object storage as the Velero backend:

| Provider | Storage backend | Workflow prefix |
|---|---|---|
| AKS (Azure Kubernetes Service) | Azure Blob Storage | `01-*` / `02-*` / `03-*` |
| EKS (Amazon Elastic Kubernetes Service) | S3 bucket | `04-*` / `05-*` / `06-*` |
| GKE (Google Kubernetes Engine) | GCS bucket | `07-*` / `08-*` / `09-*` |

Nine workflow files total, three per provider:

| # | Workflow file | Purpose |
|---|----------------|---------|
| 1 | `01-velero-prerequisites.yml` | Install/configure Velero on AKS, wired to Azure Blob |
| 2 | `02-velero-backup.yml` | Backup a namespace on an AKS cluster |
| 3 | `03-velero-restore.yml` | Restore a backup into an AKS cluster |
| 4 | `04-velero-eks-prerequisites.yml` | Install/configure Velero on EKS, wired to S3 |
| 5 | `05-velero-eks-backup.yml` | Backup a namespace on an EKS cluster |
| 6 | `06-velero-eks-restore.yml` | Restore a backup into an EKS cluster |
| 7 | `07-velero-gke-prerequisites.yml` | Install/configure Velero on GKE, wired to GCS |
| 8 | `08-velero-gke-backup.yml` | Backup a namespace on a GKE cluster |
| 9 | `09-velero-gke-restore.yml` | Restore a backup into a GKE cluster |

All nine are `workflow_dispatch` (manual trigger with input form) so they
can be run from the **Actions** tab whenever needed, in any order, across
whichever provider(s) you use. The three sets are fully independent —
you can adopt just AKS, just EKS, just GKE, or all three side by side.

**v1.2 fixes (this round, EKS/GKE-focused):**
- **GKE must-fix**: removed `gcloud auth login --brief --cred-file=...` from
  the `service_account_key` fallback path. That call switched the runner's
  active identity away from Workload Identity Federation mid-workflow and
  is interactive-oriented — unpredictable on CI. The key is now only
  validated locally (JSON structure check) and consumed by Velero via
  `--secret-file`; the runner's WIF identity is never touched.
- Concurrency groups for EKS (`04-06`) now include `aws_region`, and for
  GKE (`07-09`) now include `gcp_project_id` — prevents same-named
  clusters in different accounts/regions/projects from blocking each
  other's runs.
- EKS/GKE pipelines now install `kubectl` via direct binary download
  (`dl.k8s.io`) instead of the Azure-branded `azure/setup-kubectl` action,
  for provider-neutral tooling.
- GKE bucket IAM binding and Workload Identity binding now retry up to 5
  times (15s apart) to absorb IAM propagation delay right after GSA creation.
- EKS IAM policy has an inline comment on the EC2 wildcard-resource
  requirement and how to scope it down with `aws:ResourceTag` conditions
  for production use (see section 4 below).
- See section 11 for the recommended action-pinning-to-SHA hardening step
  (not applied inline — see why, and how to do it safely, below).

**v1.1 fixes applied to all AKS workflows (carried into EKS/GKE from the start):**
- `jq` is now explicitly installed on the runner (was previously assumed present)
- `velero_version` is now an explicit input on all three workflows — keep it
  identical across all three runs against the same cluster/backup set
- Namespace / resource-list / namespace-mapping inputs are whitespace-stripped
  before use, so `ns1, ns2` and `ns1,ns2` behave the same
- Service Principal auth method now validates the SP actually has a Blob-capable
  role assignment on the storage account before installing Velero, and fails
  fast with the exact `az role assignment create` command to fix it
- Each workflow has a `concurrency` group (per RG+cluster) and a 60-minute
  job `timeout-minutes`, so two backups/restores against the same cluster
  can't collide, and a hung run can't block the group indefinitely
- Backup/restore pipelines check Velero CRDs are present before doing anything
- Restore supports `--existing-resource-policy` (none/update) and
  `--preserve-nodeports`; backup supports `--include-resources`,
  `--exclude-resources`, and `--default-volumes-to-fs-backup`

---

## 1. Architecture

```
                     ┌─────────────────────────┐
                     │   Azure Storage Account   │
                     │   Blob Container: velero  │
                     └────────────▲─────────────┘
                                  │ backup/restore objects
                     ┌────────────┴─────────────┐
                     │   Velero (in "velero" ns) │
                     │   + Azure plugin          │
                     └───┬───────────────────┬───┘
                         │                   │
                 ┌───────▼──────┐   ┌────────▼───────┐
                 │  AKS Source   │   │  AKS Target     │
                 │  Cluster      │   │  Cluster (opt.) │
                 └───────────────┘   └─────────────────┘

GitHub Actions (OIDC via azure/login) drives all three pipelines.
No long-lived Azure credentials are stored in GitHub — auth is
federated (Workload Identity) unless you opt into the Service
Principal fallback.
```

---

## 2. AKS: One-time setup (before running any AKS pipeline)

### 2.1 Azure AD App Registration for GitHub OIDC

This is what lets `azure/login` authenticate without a stored secret.

```bash
az ad app create --display-name "gh-actions-velero"
APP_ID=$(az ad app list --display-name "gh-actions-velero" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"

# Federated credential trusting your GitHub repo + branch
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "gh-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<ORG>/<REPO>:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# Grant Contributor (or a tighter custom role) at the subscription
# or resource-group scope so it can create RG/Storage/AKS resources
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope /subscriptions/<SUBSCRIPTION_ID>
```

> If you'll also run PR-triggered runs, add a federated credential with
> `subject: repo:<ORG>/<REPO>:pull_request` too. Adjust the `subject` to
> match how you actually trigger these workflows (manual `workflow_dispatch`
> runs still use the branch the workflow file lives on).

### 2.2 GitHub Secrets

Repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID from 2.1 |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `VELERO_SP_CLIENT_ID` *(optional)* | Only if using `service_principal` auth method in Pipeline 1 |
| `VELERO_SP_CLIENT_SECRET` *(optional)* | Only if using `service_principal` auth method in Pipeline 1 |

### 2.3 Repo layout

```
.github/
  workflows/
    01-velero-prerequisites.yml
    02-velero-backup.yml
    03-velero-restore.yml
    04-velero-eks-prerequisites.yml
    05-velero-eks-backup.yml
    06-velero-eks-restore.yml
    07-velero-gke-prerequisites.yml
    08-velero-gke-backup.yml
    09-velero-gke-restore.yml
README.md
```

---

## 3. AKS: End-to-end walkthrough

### Step 1 — Run Prerequisites (per cluster)

Actions tab → **01 - Velero Prerequisites** → Run workflow, fill in:

| Input | Example | Notes |
|---|---|---|
| `resource_group` | `rg-aks-prod` | RG containing AKS + will contain Storage Account |
| `location` | `eastus` | Only used if RG/Storage Account need creating |
| `aks_name` | `aks-source-cluster` | Cluster to install Velero into |
| `storage_account` | `stveleroaksbackup01` | Must be globally unique, lowercase, ≤24 chars |
| `blob_container` | `velero` | |
| `velero_namespace` | `velero` | |
| `auth_method` | `workload_identity` | Recommended. Use `service_principal` only for quick labs |
| `enable_node_agent` | `true` | Needed for filesystem-level PV backup/restore |

What it does:
1. Creates RG / Storage Account / Blob Container if missing (safe to re-run).
2. Installs `kubectl`, `helm`, `velero` CLI on the runner.
3. `az aks get-credentials` for the target cluster.
4. **Workload Identity path**: enables OIDC issuer + workload identity on
   AKS, creates a user-assigned managed identity, grants it **Storage Blob
   Data Contributor** on the storage account, federates it to the
   `velero` service account.
5. **Service Principal path**: writes a `credentials-velero` file from
   `VELERO_SP_CLIENT_ID`/`SECRET` and passes it to `velero install`.
6. Runs `velero install` with the Azure plugin and configures the
   BackupStorageLocation (BSL).
7. Polls `velero backup-location get` until phase = `Available` and fails
   the run if it doesn't.

Run this once per cluster you intend to back up **or** restore into
(so run it again for the target cluster if you're testing cross-cluster
restore).

### Step 2 — Run a Backup

Actions tab → **02 - Velero Backup** → Run workflow, fill in:

| Input | Example |
|---|---|
| `resource_group` | `rg-aks-prod` |
| `aks_name` | `aks-source-cluster` |
| `namespace` | `payments` (or `*` for all namespaces, or `ns1,ns2`) |
| `velero_version` | must match whatever Pipeline 1 installed, e.g. `v1.14.1` |
| `backup_name` | leave blank to auto-generate |
| `ttl` | `720h0m0s` (30 days) |
| `snapshot_volumes` | `true` |
| `default_volumes_to_fs_backup` | `false` — set `true` to force Velero's node-agent File System Backup for all volumes instead of CSI/native snapshots |
| `include_resources` / `exclude_resources` | optional comma-separated resource types, e.g. `exclude_resources: events,events.events.k8s.io` |
| `wait_for_completion` | `true` |

What it does:
1. Confirms the BSL is `Available` (fails fast with a clear error if
   Pipeline 1 hasn't been run / isn't healthy).
2. `velero backup create ... --wait`.
3. `velero backup describe --details` and `velero backup logs` are
   captured and uploaded as a workflow artifact.
4. Fails the pipeline if the final phase isn't `Completed` /
   `PartiallyFailed` (warns on partial failures).

### Step 3 — Run a Restore

Actions tab → **03 - Velero Restore** → Run workflow, fill in:

| Input | Example |
|---|---|
| `resource_group` | `rg-aks-target` (same as source, or a different cluster's RG) |
| `aks_name` | `aks-target-cluster` |
| `velero_version` | must match whatever Pipeline 1 installed, e.g. `v1.14.1` |
| `list_backups_only` | `true` first time, to see what's available |
| `backup_name` | e.g. `backup-payments-42-20260720120000` |
| `restore_name` | leave blank to auto-generate |
| `namespace_mapping` | e.g. `payments:payments-restored` (optional) |
| `restore_volumes` | `true` |
| `existing_resource_policy` | `none` (default, Velero skips resources that already exist) or `update` (patch existing resources to match the backup) |
| `preserve_nodeports` | `false` — set `true` to keep original Service NodePort values on restore |

Recommended flow:
1. Run once with **`list_backups_only = true`** — this just runs
   `velero backup get` against the target cluster's Velero (same BSL) and
   exits, so you can copy the exact backup name.
2. Run again with `list_backups_only = false` and the chosen `backup_name`
   to actually perform the restore.

What it does:
1. Confirms Velero + BSL are healthy on the **target** cluster (must have
   had Pipeline 1 run against it).
2. Confirms the named backup exists and is in a restorable phase.
3. `velero restore create ... --from-backup <name> --wait`.
4. Captures `velero restore describe --details`, `velero restore logs`,
   and a post-restore snapshot (`kubectl get pods/pvc -A`, recent warning
   events) — all uploaded as a workflow artifact.
5. Fails the pipeline if the final phase isn't `Completed` /
   `PartiallyFailed`.

---

## 4. EKS: One-time setup (before running any EKS pipeline)

### 4.1 IAM role for GitHub OIDC (runner identity)

This is what lets `aws-actions/configure-aws-credentials` authenticate
without a stored access key. This role only needs permissions to manage
S3/IAM/EKS resources during setup and to call `eks:DescribeCluster` /
`eks:AccessKubernetesApi` for the backup/restore pipelines — it is
**not** the identity Velero itself uses to write to S3 (that's IRSA,
set up per-cluster inside Pipeline 4).

```bash
# 1) Create (or reuse) the GitHub OIDC provider in IAM — once per AWS account
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 2) Create the role GitHub Actions will assume
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*" }
    }
  }]
}
EOF

aws iam create-role --role-name gh-actions-velero --assume-role-policy-document file://trust-policy.json

# 3) Attach a policy with EKS/IAM/S3 admin rights (tighten for production)
aws iam attach-role-policy --role-name gh-actions-velero \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

> Scope the attached policy down once past initial lab setup — it only
> genuinely needs `eks:*`, `iam:*Role*`/`iam:*Policy*` (for IRSA setup),
> and `s3:*` on the specific bucket(s) you use.

### 4.2 GitHub Secrets

| Secret | Value |
|---|---|
| `AWS_ROLE_TO_ASSUME` | ARN of the role created in 4.1, e.g. `arn:aws:iam::<ACCOUNT_ID>:role/gh-actions-velero` |
| `VELERO_AWS_ACCESS_KEY_ID` *(optional)* | Only if using `static_credentials` auth method in Pipeline 4 |
| `VELERO_AWS_SECRET_ACCESS_KEY` *(optional)* | Only if using `static_credentials` auth method in Pipeline 4 |

---

## 5. EKS: End-to-end walkthrough

### Step 1 — Run Prerequisites (per cluster)

Actions tab → **04 - Velero EKS Prerequisites** → Run workflow, fill in:

| Input | Example | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `cluster_name` | `eks-source-cluster` | |
| `s3_bucket` | `s3-velero-eks-backup-01` | Must be globally unique |
| `velero_namespace` | `velero` | |
| `auth_method` | `irsa` | Recommended. Use `static_credentials` only for quick labs |
| `enable_node_agent` | `true` | Needed for filesystem-level PV backup/restore |

What it does:
1. Creates the S3 bucket if missing (versioned, public access blocked).
2. Installs `kubectl`, `helm`, `velero` CLI, `eksctl`, `jq` on the runner.
3. `aws eks update-kubeconfig` for the target cluster.
4. **IRSA path**: associates the cluster's IAM OIDC provider, creates an
   IAM policy scoped to the bucket (+ EBS snapshot permissions), creates
   an IAM role trusted by that OIDC provider for the `velero` service
   account subject, installs Velero, then annotates the service account
   with `eks.amazonaws.com/role-arn` and restarts the deployment.
5. **Static Credentials path**: writes a `credentials-velero` file from
   `VELERO_AWS_ACCESS_KEY_ID`/`SECRET_ACCESS_KEY` and validates it can
   reach the bucket before installing Velero with `--secret-file`.
6. Runs `velero install` with the AWS plugin and configures the BSL.
7. Polls `velero backup-location get` until phase = `Available`.

### Step 2 — Run a Backup

Actions tab → **05 - Velero EKS Backup** → Run workflow, fill in
`aws_region`, `cluster_name`, `namespace` (or `*`), and optionally
`backup_name`, `ttl`, `snapshot_volumes` (EBS snapshots),
`default_volumes_to_fs_backup`, `include_resources`/`exclude_resources`.
Same behavior as the AKS backup pipeline: waits, validates phase,
uploads `backup-describe.txt` + `backup-logs.txt` as an artifact.

### Step 3 — Run a Restore

Actions tab → **06 - Velero EKS Restore** → Run workflow. Same pattern as
AKS: run once with `list_backups_only = true` to see available backups,
then again with the chosen `backup_name` to restore. Supports
`namespace_mapping`, `existing_resource_policy`, and `preserve_nodeports`.

---

## 6. GKE: One-time setup (before running any GKE pipeline)

### 6.1 Workload Identity Federation for GitHub OIDC (runner identity)

This is what lets `google-github-actions/auth` authenticate without a
stored JSON key, for the runner's own `gcloud`/`kubectl` commands. Like
the EKS runner role, this is separate from the identity Velero itself
uses to write to GCS (that's GKE Workload Identity, set up per-cluster
inside Pipeline 7).

```bash
PROJECT_ID=<PROJECT_ID>
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# 1) Create a Workload Identity Pool + GitHub OIDC provider (once per project)
gcloud iam workload-identity-pools create "github-pool" \
  --project="$PROJECT_ID" --location="global" --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub OIDC" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='<ORG>/<REPO>'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 2) Create a GSA for the runner and bind it to the pool
gcloud iam service-accounts create gh-actions-velero --project="$PROJECT_ID"

gcloud iam service-accounts add-iam-policy-binding \
  "gh-actions-velero@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/<ORG>/<REPO>"

# 3) Grant the GSA rights to manage GKE/IAM/Storage (tighten for production)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:gh-actions-velero@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/editor"
```

### 6.2 GitHub Secrets

| Secret | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SERVICE_ACCOUNT` | `gh-actions-velero@<PROJECT_ID>.iam.gserviceaccount.com` |
| `VELERO_GCP_SA_KEY_BASE64` *(optional)* | Only if using `service_account_key` auth method in Pipeline 7 — `base64 -w0 key.json` |

---

## 7. GKE: End-to-end walkthrough

### Step 1 — Run Prerequisites (per cluster)

Actions tab → **07 - Velero GKE Prerequisites** → Run workflow, fill in:

| Input | Example | Notes |
|---|---|---|
| `gcp_project_id` | `my-project-id` | |
| `gke_cluster_name` | `gke-source-cluster` | |
| `gke_location` | `us-central1-a` | |
| `gke_location_type` | `zone` | or `region` for regional clusters |
| `gcs_bucket` | `gcs-velero-gke-backup-01` | Must be globally unique |
| `velero_namespace` | `velero` | |
| `auth_method` | `workload_identity` | Recommended. Use `service_account_key` only for quick labs |
| `enable_node_agent` | `true` | Needed for filesystem-level PV backup/restore |

What it does:
1. Creates the GCS bucket if missing (uniform bucket-level access).
2. Installs `kubectl`, `helm`, `velero` CLI, `gcloud`, `jq` on the runner.
3. `gcloud container clusters get-credentials` for the target cluster.
4. **Workload Identity path**: enables Workload Identity on the cluster if
   not already enabled (⚠️ can trigger a node pool upgrade on existing
   clusters — see the note in the workflow file), creates a Google
   Service Account, grants it `roles/storage.objectAdmin` on the bucket,
   binds the `velero` Kubernetes service account to it via
   `roles/iam.workloadIdentityUser`, installs Velero, then annotates the
   service account with `iam.gke.io/gcp-service-account` and restarts
   the deployment.
5. **Service Account Key path**: decodes `VELERO_GCP_SA_KEY_BASE64` into
   a JSON key file and installs Velero with `--secret-file`.
6. Runs `velero install` with the GCP plugin and configures the BSL.
7. Polls `velero backup-location get` until phase = `Available`.

### Step 2 — Run a Backup

Actions tab → **08 - Velero GKE Backup** → Run workflow, fill in
`gcp_project_id`, `gke_cluster_name`, `gke_location`/`gke_location_type`,
`namespace` (or `*`), and optionally `backup_name`, `ttl`,
`snapshot_volumes` (PD snapshots), `default_volumes_to_fs_backup`,
`include_resources`/`exclude_resources`. Same behavior as the other two
providers: waits, validates phase, uploads describe + logs as an artifact.

### Step 3 — Run a Restore

Actions tab → **09 - Velero GKE Restore** → Run workflow. Same pattern:
run once with `list_backups_only = true`, then again with the chosen
`backup_name`. Supports `namespace_mapping`, `existing_resource_policy`,
and `preserve_nodeports`.

---

## 8. Cross-cluster restore notes

- Run **Pipeline 1 / 4 / 7** (matching provider) against the target cluster
  too, pointing at the **same** bucket/container so it can see the source
  cluster's backups.
- Target cluster should be on a compatible Kubernetes version.
- If StorageClass names differ between clusters, you'll need a
  [`ConfigMap`-based StorageClass mapping](https://velero.io/docs/main/restore-reference/#changing-pv-pvc-storage-classes)
  in addition to (or instead of) `namespace_mapping`.
- If restoring PV data across regions, confirm your snapshot/data-mover
  strategy (cloud-native snapshots are region/zone-bound in most cases)
  supports it — otherwise use Velero's File System Backup
  (`enable_node_agent: true` in the prerequisites pipeline) instead.
- **Cross-provider restore (e.g. AKS → EKS) is not supported by this
  setup** — each provider's prerequisites pipeline installs a different
  Velero storage plugin (Azure/AWS/GCP) tied to that provider's bucket
  format. Migrating across clouds requires a different tool (e.g.
  Velero's community `migration` guidance) or an intermediate
  export/import step; it's out of scope for these three pipeline sets.

---

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Prerequisites pipeline fails at "BSL did not reach Available" | Check `kubectl logs -n velero deployment/velero`; usually an IAM/role propagation delay (wait ~1 min and re-run) or wrong bucket/region/project in the BSL config |
| Backup/Restore pipeline fails at "BackupStorageLocation is not Available" | The matching prerequisites pipeline hasn't been run against this cluster, or the Velero pod crashed — check `kubectl get pods -n velero` |
| `azure/login` fails | Federated credential `subject` doesn't match how the workflow is triggered — re-check section 2.1 |
| `aws-actions/configure-aws-credentials` fails | Trust policy `sub` condition doesn't match `repo:<ORG>/<REPO>:*`, or the OIDC provider thumbprint is stale — re-check section 4.1 |
| `google-github-actions/auth` fails | `attribute-condition` on the WIF provider doesn't match your repo, or the GSA's `workloadIdentityUser` binding is missing — re-check section 6.1 |
| Restore shows `PartiallyFailed` | Check the uploaded `restore-logs.txt` artifact — usually a missing StorageClass, CRD, or namespace conflict on the target cluster |
| Storage account/bucket name rejected | Azure: 3–24 lowercase alphanumeric, globally unique. S3/GCS: lowercase, globally unique, DNS-compliant |
| GKE prerequisites pipeline hangs/times out on Workload Identity enable | Enabling Workload Identity on an existing cluster upgrades node pools — this can take 10+ minutes per node pool; consider enabling it ahead of time outside the pipeline for non-trivial clusters |

---

## 10. Security notes

- Prefer the identity-federation auth method (`workload_identity` /
  `irsa` / `workload_identity` for AKS/EKS/GKE respectively) over the
  static-credential fallback — no long-lived secret is stored anywhere
  for Velero's own cloud access.
- Every runner-level OIDC identity (Azure app registration, AWS IAM
  role, GCP WIF provider) should be scoped as tightly as practical
  (specific resource group / account / project, not broad admin) once
  you're past initial lab setup.
- Backup/restore artifacts uploaded by these pipelines (describe/log
  output) do not contain secret values, but do contain resource
  names/namespaces — treat the Actions run history accordingly if your
  namespaces are sensitive.

---

## 11. Recommended hardening: pin actions to commit SHAs

All marketplace actions used here (`azure/login`, `aws-actions/configure-aws-credentials`,
`google-github-actions/auth`, `google-github-actions/setup-gcloud`,
`azure/setup-kubectl`, `azure/setup-helm`, `actions/checkout`,
`actions/upload-artifact`) are currently referenced by mutable version tag
(e.g. `@v2`, `@v4`). GitHub's own guidance recommends pinning third-party
actions to a full 40-character commit SHA instead, so a compromised tag
can't silently swap in malicious code on your next run.

This is intentionally **not** applied inline in these files — pinning to
a wrong or stale SHA is worse than not pinning at all (it either breaks
the run outright, or worse, silently pins a hash that doesn't correspond
to what you think it does). Resolve the current SHAs yourself with:

```bash
# Run once, review the output, then paste the pinned lines into the workflows.
for action in \
  "Azure/login@v2" \
  "aws-actions/configure-aws-credentials@v4" \
  "google-github-actions/auth@v2" \
  "google-github-actions/setup-gcloud@v2" \
  "Azure/setup-kubectl@v4" \
  "Azure/setup-helm@v4" \
  "actions/checkout@v4" \
  "actions/upload-artifact@v4"
do
  repo="${action%@*}"
  tag="${action#*@}"
  sha=$(curl -fsSL "https://api.github.com/repos/${repo}/git/refs/tags/${tag}" \
    | jq -r '.object.sha // empty')
  # Lightweight tags resolve straight to a commit; annotated tags resolve
  # to a tag object first -- follow it one more hop in that case.
  if [ -n "$sha" ]; then
    obj_type=$(curl -fsSL "https://api.github.com/repos/${repo}/git/tags/${sha}" 2>/dev/null | jq -r '.type // empty')
    if [ "$obj_type" = "commit" ]; then
      sha=$(curl -fsSL "https://api.github.com/repos/${repo}/git/tags/${sha}" | jq -r '.object.sha')
    fi
  fi
  echo "${repo}@${sha} # ${tag}"
done
```

Add a `.github/dependabot.yml` with a `github-actions` ecosystem entry so
these pins get automated update PRs going forward:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```
