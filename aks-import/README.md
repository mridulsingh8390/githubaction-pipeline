# Azure Terraform Import Pipeline

Auto-discovers existing Azure resources and generates ready-to-use Terraform code using Microsoft's official `aztfexport` tool.

---

## What it does

```
┌─────────────────────────────────────────────────────┐
│  You provide: resource_group + environment           │
└─────────────────────────┬───────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────┐
│  DISCOVER                                            │
│  Scans the resource group using Azure CLI            │
│  Lists every resource grouped by type               │
│  → Artifact: discovery-report.json                  │
└─────────────────────────┬───────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────┐
│  GENERATE                                            │
│  Runs aztfexport on the resource group              │
│  Generates main.tf + import.tf for all resources    │
│  → Artifact: generated-tf/ folder                  │
└─────────────────────────┬───────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────┐
│  VALIDATE                                            │
│  Runs terraform plan against generated code          │
│  Shows any drift between code and actual resources   │
│  → Artifact: plan-output.txt                        │
└─────────────────────────────────────────────────────┘
```

---

## Running the pipeline

Go to **Actions → Azure Terraform Import → Run workflow**:

| Input | Description | Example |
|-------|-------------|---------|
| `resource_group` | Azure RG to scan | `rg-aks-dev` |
| `environment` | Environment label | `dev` |
| `action` | What to run | see below |
| `tag_filter` | Optional tag filter | `environment=dev` |
| `branch` | Branch to run from | `main` |

### Actions

| Action | What runs | Use when |
|--------|-----------|----------|
| `discover` | Step 1 only | Just want to see what resources exist |
| `generate` | Steps 1 + 2 | Want to generate TF code without validating |
| `discover-generate-validate` | All steps | Full import workflow |

---

## Typical workflow

### 1. First run — discover only
```
action = discover
resource_group = rg-aks-dev
```
Download `discovery-report.json` from artifacts. Review what resources exist.

### 2. Second run — generate code
```
action = generate
resource_group = rg-aks-dev
```
Download `generated-tf/` folder from artifacts. Review the generated `.tf` files.

### 3. Third run — full validation
```
action = discover-generate-validate
resource_group = rg-aks-dev
```
Download `plan-output.txt` from artifacts. Check for any drift.

### 4. Apply the import (manual step)
```bash
# Copy generated files to your project
cp generated-tf/* terraform/azure/azure-kubernetes-service/

# Run locally
cd terraform/azure/azure-kubernetes-service
terraform init -backend-config="backend/dev.backend.hcl"
terraform apply   # import blocks run automatically in TF 1.5+
```

---

## How aztfexport works

`aztfexport` is Microsoft's official tool for generating Terraform code from existing Azure resources. It:

1. Calls Azure Resource Manager API to list all resources in the RG
2. Maps each resource type to the correct `azurerm_*` Terraform resource
3. Reads all resource properties from Azure
4. Generates `main.tf` with complete resource blocks
5. Generates `import.tf` with native Terraform import blocks (TF 1.5+)

The generated `import.tf` looks like:
```hcl
import {
  id = "/subscriptions/.../resourceGroups/rg-aks-dev/providers/Microsoft.Network/virtualNetworks/vnet-aks-dev"
  to = azurerm_virtual_network.res-0
}

import {
  id = "/subscriptions/.../resourceGroups/rg-aks-dev/providers/Microsoft.KeyVault/vaults/kv-aksdev-mridul05"
  to = azurerm_key_vault.res-1
}
```

When you run `terraform apply`, these import blocks pull the existing resources into state automatically — no manual `terraform import` commands needed.

---

## Tag filtering

To import only specific resources, use the `tag_filter` input:

```
tag_filter = environment=dev
tag_filter = managed_by=terraform
tag_filter = project=aks-lab
```

This filters resources by Azure tag before passing them to aztfexport.

---

## Artifacts produced

| Artifact | Contents | Retention |
|----------|----------|-----------|
| `discovery-report-<rg>-<runid>` | JSON inventory of all resources found, grouped by type | 30 days |
| `generated-tf-<rg>-<runid>` | Ready-to-use .tf files + import blocks + README | 30 days |
| `plan-output-<rg>-<runid>` | Full terraform plan output showing drift | 30 days |

---

## Required secrets

Same secrets as the main Terraform pipeline — no extra secrets needed:

- `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`
- `TF_STATE_BUCKET`, `TF_STATE_LOCK_TABLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`

---

## Notes

- Generated code is verbose — aztfexport includes every property. Clean it up before merging into your main Terraform code.
- Resource names in generated code use `res-0`, `res-1` etc. Rename them to match your naming convention.
- Some resource types are not supported by aztfexport yet — they'll be skipped with a warning.
- Always run `discover` first to review what will be imported before running `generate`.
