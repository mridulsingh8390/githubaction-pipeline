# EKS Pipelines

Two standalone GitHub Actions workflows for EKS — portable, no dependency
on any other pipeline or repo. Drop both into `.github/workflows/` of any
project that needs them.

| File | Purpose |
|---|---|
| `upgrade-eks.yml` | Two-stage approval upgrade (control plane, then node groups) |
| `eks-cluster-info.yml` | Read-only diagnostic snapshot of a cluster |

## Prerequisites

### Secret (repo → Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `AWS_EKS_ROLE_ARN` | IAM role ARN, trusted via GitHub OIDC |

Both pipelines share this one secret.

### GitHub Environments (repo → Settings → Environments)

Only `upgrade-eks.yml` needs these — `eks-cluster-info.yml` has no approval
gate since it's read-only:

- `eks-upgrade-control-plane`
- `eks-upgrade-worker-nodes`

### OIDC setup (one-time per project)

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Skip if this account already has a GitHub OIDC provider from another project
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"

cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": [
        "repo:OWNER/REPO:ref:refs/heads/main",
        "repo:OWNER/REPO:environment:eks-upgrade-control-plane",
        "repo:OWNER/REPO:environment:eks-upgrade-worker-nodes"
      ]}
    }
  }]
}
EOF
# Replace ACCOUNT_ID, OWNER, REPO above before running.

aws iam create-role --role-name gh-eks-upgrade \
  --assume-role-policy-document file://trust-policy.json

# Attach a policy granting: eks:UpdateClusterVersion, eks:UpdateNodegroupVersion,
# eks:DescribeUpdate, eks:DescribeCluster, eks:ListNodegroups, eks:DescribeNodegroup
```

## `upgrade-eks.yml`

### Flow

```
plan → upgrade-control-plane (approval) → upgrade-worker-nodes (approval) → post-upgrade-validation
```

### ⚠️ Feature parity with the AKS version — read before assuming equivalence

EKS's API genuinely lacks native equivalents for a few things the AKS
pipeline supports directly:

| AKS feature | EKS substitute | Why it's not the same |
|---|---|---|
| `az aks snapshot create` (real, restorable) | Pre-upgrade **state dump** (cluster + node group config as JSON, uploaded as an artifact) | Audit/rollback *reference* only — not something you can restore from. EKS has no user-triggerable control plane snapshot API; AWS manages that state directly. |
| `--node-soak-duration` (per-node wait) | `interGroupSoakMinutes` (wait **between node groups**) | Coarser — EKS's node group update API has no per-node soak parameter. |
| System vs. user pool ordering | Node groups upgraded in listing order | EKS node groups have no `mode` field distinguishing system/user like AKS does — there's no equivalent ordering concept to preserve. |

### Known limitation: one minor version per upgrade

EKS's API only allows upgrading exactly one minor version at a time
(e.g. 1.29→1.30, not 1.29→1.31). If `targetKubernetesVersion` is left
blank, the pipeline auto-computes current+1 minor. A bigger jump will
trigger a warning and likely be rejected by AWS.

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `eksClusterName` | Yes | — | |
| `awsRegion` | No | `us-east-1` | |
| `targetKubernetesVersion` | No | blank (auto current+1 minor) | |
| `controlPlaneOnly` | No | `false` | |
| `nodeGroupName` | No | blank (all groups) | |
| `maxUnavailablePercentage` | No | `33` | |
| `interGroupSoakMinutes` | No | `5` | See parity note above |
| `createStateDump` | No | `true` | Not a restorable snapshot — see parity note above |

## `eks-cluster-info.yml`

Read-only — no mutations, no approval gate. Fetches cluster info, node
group details, and per-node version/OS/runtime info via `kubectl`.

| Input | Required | Default |
|---|---|---|
| `eksClusterName` | Yes | — |
| `awsRegion` | No | `us-east-1` |

## Notes

- **Two-layered EKS access**: the IAM role needs `eks:DescribeCluster` etc.
  to fetch kubeconfig, but actually running `kubectl` inside the cluster
  also requires that IAM principal to be mapped to Kubernetes RBAC via the
  cluster's **access entries** (or the legacy `aws-auth` ConfigMap). IAM
  permissions alone are not sufficient on EKS — this trips people up
  constantly, so check it first if `kubectl` commands fail with permission
  errors despite the AWS CLI calls succeeding.
- If an upgrade fails mid-way, EKS has no snapshot/restore path — recovery
  means fixing forward (re-running the update), not rolling back.
