# AWS EKS Terraform Import Pipeline

Auto-discovers existing AWS EKS + VPC resources, imports them into
Terraform state, generates a tfvars file, and commits it to the repo —
all using OIDC (no long-lived AWS access keys required).

---

## How it works

```
Step 1: DISCOVER
  Connects to AWS via OIDC and describes:
    - EKS cluster details (version, VPC, subnets, role ARN)
    - VPC (CIDR, DNS settings)
    - Subnets (CIDRs, availability zones)
    - EKS node groups (instance types, scaling config)
    - OIDC provider
  Output: eks-discovery-report.json artifact

Step 2: IMPORT TO STATE
  Imports VPC and subnets FIRST (required - EFS module count depends
  on subnet outputs, so subnets must be in state before EKS imports)
  Then imports EKS cluster + node groups
  No new resources are created - only existing ones are registered
  Runs terraform plan to verify state matches reality

Step 3: GENERATE TFVARS
  Reads discovered resource properties
  Generates accurate tfvars with real values
  Auto-commits to eks-import/tfvars/<env>-<cluster>.tfvars
```

---

## Pipeline inputs

| Input | Description | Example |
|-------|-------------|---------|
| `cluster_name` | EKS cluster name | `eks-import-demo-cluster` |
| `environment` | Environment label | `dev` |
| `action` | What to run | see below |
| `aws_region` | AWS region | `us-east-1` |
| `branch` | Branch to run from | `main` |

### Actions

| Action | Jobs that run |
|--------|--------------|
| `discover` | Discover only (safe, no changes) |
| `generate-tfvars` | Discover + Generate tfvars |
| `import-state` | Discover + Import to state |
| `all` | All three steps in order |

---

## One-time AWS OIDC setup

This pipeline uses OIDC (Workload Identity Federation) — no AWS access
keys stored in GitHub. Run these commands once per AWS account.

### 1. Create the OIDC Identity Provider

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

If it already exists you'll get an `EntityAlreadyExists` error — safe to ignore.

### 2. Create the trust policy

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > trust-policy.json << 'POLICYEOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID_PLACEHOLDER:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:mridulsingh8390/githubaction-pipeline:*"
      }
    }
  }]
}
POLICYEOF

sed -i "s/ACCOUNT_ID_PLACEHOLDER/$ACCOUNT_ID/" trust-policy.json
```

### 3. Create the IAM role and attach permissions

```bash
aws iam create-role \
  --role-name github-actions-eks-import \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name github-actions-eks-import \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam get-role \
  --role-name github-actions-eks-import \
  --query 'Role.Arn' --output text
```

### 4. Add ONE secret to GitHub

Go to `githubaction-pipeline` repo -> Settings -> Secrets -> New repository secret:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | ARN from step 3, e.g. `arn:aws:iam::730335612245:role/github-actions-eks-import` |

That's the only AWS credential needed for this pipeline.

---

## GitHub Secrets required

| Secret | Purpose |
|--------|---------|
| `AWS_ROLE_ARN` | OIDC role for AWS access (EKS/VPC read + Terraform import) |
| `TF_STATE_BUCKET` | S3 bucket name (state storage) |
| `TF_STATE_LOCK_TABLE` | DynamoDB table name (state locking) |

The S3 backend uses the same OIDC-derived credentials as the AWS provider,
since `AdministratorAccess` also covers S3 and DynamoDB.

---

## Prerequisites: EKS cluster must exist

If you need to create a demo cluster first:

```bash
bash create-eks-resources.sh
```

Creates in ~20-25 minutes:
- VPC (10.1.0.0/16) + 2 private subnets + 1 public subnet
- Internet Gateway + NAT Gateway + Route Tables
- Security Group
- IAM roles (cluster + node)
- EKS Cluster (eks-import-demo-cluster)
- Node group with 1 t3.medium node

---

## Running the pipeline

Go to Actions -> AWS EKS Terraform Import -> Run workflow

### Full import (recommended)

```
cluster_name = eks-import-demo-cluster
environment  = dev
action       = all
aws_region   = us-east-1
branch       = main
```

### Just discover (safe, no changes)

```
action = discover
```

---

## After pipeline runs

### Generated tfvars location in repo

```
eks-import/tfvars/dev-eks-import-demo-cluster.tfvars
```

Format: `<environment>-<cluster_name>.tfvars`

### Use generated tfvars in Terraform-LAB

```bash
cd terraform/aws/eks-cluster

cp ../../../eks-import/tfvars/dev-eks-import-demo-cluster.tfvars \
   values/dev-import-demo.tfvars

terraform plan -var-file="values/dev-import-demo.tfvars"
```

Expected: "No changes" — confirms import was fully successful.

---

## Resource type to Terraform address mapping

| AWS Resource | Terraform Address |
|-------------|-------------------|
| VPC | module.vpc.aws_vpc.vpc |
| Private Subnets | module.vpc.aws_subnet.private[N] (indexed 0, 1, 2...) |
| EKS Cluster | module.eks.aws_eks_cluster.eks |
| System Node Group | module.eks.aws_eks_node_group.system[0] |
| User Node Group | module.eks.aws_eks_node_group.user |
| OIDC Provider | module.eks.aws_iam_openid_connect_provider.eks |

To add more resource types, update `type_map` in `eks-import/scripts/run_import.py`.

---

## Important: import order matters

VPC and subnets must import before the EKS cluster. The `run_import.py`
script sorts resources by this priority automatically:

```python
import_priority = {
    'aws_vpc':                         0,
    'aws_subnet':                      1,
    'aws_iam_openid_connect_provider': 2,
    'aws_eks_cluster':                 3,
    'aws_eks_node_group':              4,
}
```

Reason: the EFS module's `count = length(var.subnet_ids)` depends on
`module.vpc.private_subnet_ids`. If subnets aren't in state yet, that
output is null/unknown and Terraform can't resolve the count, causing
"Invalid count argument" errors on unrelated resources.

---

## Clear state lock (if pipeline gets stuck)

```bash
aws dynamodb delete-item \
  --table-name terraform-state-lock \
  --key '{"LockID": {"S": "terraform-lab-state-mridulsingh05/aws/eks-cluster/dev/terraform.tfstate"}}' \
  --region us-east-1
```

---

## Cleanup demo resources

```bash
bash cleanup-eks-resources.sh
```

Deletes in the correct dependency order:
Node Group -> Cluster -> OIDC Provider -> IAM Roles ->
Security Groups -> NAT Gateway -> EIP -> IGW ->
Subnets -> Route Tables -> VPC

---

## Common errors and fixes

| Error | Fix |
|-------|-----|
| SyntaxError: invalid syntax in run_import.py | File got overwritten with YAML content by mistake - re-check file content matches the Python script |
| Invalid count argument on EFS module | Import order issue - VPC/subnets must import before EKS cluster (fixed via import_priority sort) |
| Subnets all importing to same [0] index | Indexing bug - use dedicated counter, not substring match on resource names |
| No valid credential sources found | AWS secrets missing or OIDC role not configured - check AWS_ROLE_ARN secret exists |
| Error acquiring state lock | Clear DynamoDB lock (see command above) |
| EntityAlreadyExists on OIDC/Role creation | Already set up from a previous run - safe to ignore, just get the ARN with aws iam get-role |
| AccessDeniedException | OIDC role needs EKS/EC2/IAM permissions - verify AdministratorAccess policy is attached |
| ResourceNotFoundException | Cluster name doesn't exist in that region - check cluster_name input matches exactly |
