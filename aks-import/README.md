# Azure Terraform Import Pipeline

Auto-discovers existing Azure resources, imports them into Terraform state,
generates a tfvars file, and commits it to the repo — all in one pipeline run.

---

## How it works

```
Step 1: DISCOVER
  Scans the resource group
  Lists all resources by type
  Filters by tag if provided
  Output: discovery-report.json artifact

Step 2: IMPORT TO STATE
  Runs terraform import for each resource
  Adds existing Azure resources to Terraform state in S3
  Runs terraform plan to verify state matches reality
  No new resources are created - only existing ones are registered

Step 3: GENERATE TFVARS
  Fetches detailed properties from Azure
  Generates tfvars file with real values
  Auto-commits to aks-import/tfvars/<env>-<rg>.tfvars
  Output: generated-tfvars artifact
```

---

## Pipeline inputs

| Input | Description | Example |
|-------|-------------|---------|
| `resource_group` | Azure RG to scan | `rg-import-demo` |
| `environment` | Environment label | `dev` |
| `action` | What to run | see below |
| `tag_filter` | Filter by tag (optional) | `environment=demo` |
| `branch` | Branch to run from | `main` |

### Actions

| Action | Jobs that run |
|--------|--------------|
| `discover` | Discover only |
| `generate-tfvars` | Discover + Generate tfvars |
| `import-state` | Discover + Import to state |
| `all` | All three steps in order |

---

## One-time setup

### 1. Create demo Azure resources

```bash
# Run the creation script
bash create-azure-resources.sh
```

This creates in `rg-import-demo`:
- Resource Group
- VNet + 2 subnets
- NSG + rules + subnet association
- Key Vault
- Storage Account + blob container

All tagged with `environment=demo` for tag filtering.

### 2. If Key Vault name conflicts (soft delete)

```bash
# Purge the old soft-deleted Key Vault
az keyvault purge \
  --name <old-kv-name> \
  --location eastus

# Or use a different name in create-azure-resources.sh
KV_NAME="kv-import-demo-yourname2"
```

### 3. OIDC federated credentials (one-time)

```bash
# Get service principal App ID
APP_ID=$(az ad sp list \
  --display-name "github-actions-terraform" \
  --query "[].appId" -o tsv)

# Add credential for workflow_dispatch runs
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "githubaction-pipeline-dispatch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:mridulsingh8390/githubaction-pipeline:workflow_dispatch",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 4. GitHub Secrets required

Go to `githubaction-pipeline` repo → Settings → Secrets → New repository secret:

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | Service principal App ID |
| `AZURE_TENANT_ID` | Azure AD Tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure Subscription ID |
| `TF_STATE_BUCKET` | S3 bucket name |
| `TF_STATE_LOCK_TABLE` | DynamoDB table name |
| `AWS_ACCESS_KEY_ID` | IAM key for S3 access |
| `AWS_SECRET_ACCESS_KEY` | IAM secret for S3 access |
| `AWS_REGION` | S3 bucket region |

---

## Running the pipeline

Go to **Actions → Azure Terraform Import → Run workflow**

### Full import (recommended)

```
resource_group = rg-import-demo
environment    = dev
action         = all
tag_filter     = environment=demo
branch         = main
```

This runs all three steps sequentially:
```
discover → import-state → generate-tfvars
```

### Just discover (safe, no changes)

```
action = discover
```

Downloads `discovery-report.json` showing all resources found.

### Just generate tfvars (no state changes)

```
action = generate-tfvars
```

Generates tfvars from Azure resource properties.

### Just import state (no tfvars)

```
action = import-state
```

Imports existing resources into Terraform state only.

---

## After pipeline runs

### Generated tfvars location

```
aks-import/tfvars/dev-rg-import-demo.tfvars
```

Format: `<environment>-<resource_group>.tfvars`

### Use generated tfvars in Terraform-LAB

1. Copy content to `Terraform-LAB/terraform/azure/azure-kubernetes-service/values/dev.tfvars`
2. Add missing required variables:

```hcl
# Add these manually (not discoverable from resources):
prefix     = "import-demo"
dns_prefix = "aksimport"

# Uncomment subnet CIDRs from comments:
aks_system_subnet_cidr = "10.0.0.0/20"
storage_subnet_cidr    = "10.0.32.0/24"

# Add AKS settings if cluster exists:
cluster_name       = "aks-import-demo"
kubernetes_version = "1.32"
```

3. Run terraform plan to verify:

```bash
cd terraform/azure/azure-kubernetes-service

terraform plan \
  -var-file="values/dev.tfvars" \
  -var="subscription_id=<your-subscription-id>"
```

Expected output: `No changes` — confirms import was successful.

---

## Clearing state lock (if pipeline gets stuck)

```bash
aws dynamodb delete-item \
  --table-name terraform-state-lock \
  --key '{"LockID": {"S": "terraform-lab-state-mridulsingh05/azure/azure-kubernetes-service/dev/terraform.tfstate"}}' \
  --region us-east-1

echo "State lock cleared"
```

---

## Cleanup demo resources

```bash
bash cleanup-azure-import-demo.sh
```

Or manually:

```bash
az group delete --name rg-import-demo --yes --no-wait
echo "Deletion started (runs in background)"

# Check status
az group show \
  --name rg-import-demo \
  --query properties.provisioningState \
  --output tsv
```

---

## Resource type to Terraform address mapping

The import pipeline maps Azure resource types to Terraform module addresses:

| Azure Resource Type | Terraform Address |
|--------------------|-------------------|
| `Microsoft.Network/virtualNetworks` | `module.vnet.azurerm_virtual_network.vnet` |
| `Microsoft.Network/networkSecurityGroups` | `module.vnet.azurerm_network_security_group.aks_user` |
| `Microsoft.KeyVault/vaults` | `module.keyvault.azurerm_key_vault.kv` |
| `Microsoft.Storage/storageAccounts` | `module.storage.azurerm_storage_account.sa` |
| `Microsoft.ContainerService/managedClusters` | `module.aks.azurerm_kubernetes_cluster.aks` |

To add more resource types, update `type_map` in `aks-import/scripts/run_import.py`.

---

## Pipeline artifacts

| Artifact | Contents | Retention |
|----------|----------|-----------|
| `discovery-report-<runid>` | JSON inventory of all resources | 30 days |
| `generated-tfvars-<env>-<runid>` | Generated tfvars file | 30 days |
| `import-plan-<runid>` | Terraform plan output | 30 days |

---

## Common errors and fixes

| Error | Fix |
|-------|-----|
| `No matching federated identity record` | Add federated credential for `workflow_dispatch` subject |
| `Error acquiring state lock` | Clear DynamoDB lock (see command above) |
| `No value for required variable` | Pass `-var-file` to terraform import command |
| `ConflictError - vault in deleted state` | Purge soft-deleted Key Vault or use different name |
| `YAML not showing in Actions` | Non-ASCII characters in workflow file — keep all comments plain ASCII |
| `working directory not found` | Check repo name in checkout step matches actual repo |
| `Imported: 0 resources` | Check tag_filter matches actual resource tags |