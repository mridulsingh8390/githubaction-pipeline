#!/bin/bash
# =============================================================================
# Create Azure Resources via CLI
# These resources will then be imported into Terraform using the import pipeline
#
# Resources created:
#   - Resource Group
#   - Virtual Network + Subnets
#   - Network Security Group
#   - Key Vault
#   - Storage Account
#   - AKS Cluster (basic)
#
# Usage: bash create-azure-resources.sh
# =============================================================================

# ── Variables — update these before running ───────────────────────────────────
RG="rg-import-demo"
LOCATION="eastus"
PREFIX="import-demo"
VNET_NAME="vnet-import-demo"
KV_NAME="kv-import-demo-mridul"
STORAGE_NAME="stimportdemomridul"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "================================================="
echo " Creating Azure Resources for Import Demo"
echo " Subscription : $SUBSCRIPTION_ID"
echo " Resource Group: $RG"
echo " Location      : $LOCATION"
echo "================================================="

# =============================================================================
# 1. Resource Group
# =============================================================================
echo ""
echo "=== Step 1: Resource Group ==="
az group create \
  --name "$RG" \
  --location "$LOCATION" \
  --tags environment=demo managed_by=cli project=import-demo \
  --output none && ok "Resource group: $RG"

# =============================================================================
# 2. Virtual Network + Subnets
# =============================================================================
echo ""
echo "=== Step 2: Virtual Network ==="
az network vnet create \
  --name "$VNET_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --address-prefix "10.0.0.0/8" \
  --tags environment=demo managed_by=cli \
  --output none && ok "VNet: $VNET_NAME"

az network vnet subnet create \
  --name "${PREFIX}-snet-aks" \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --address-prefix "10.0.0.0/20" \
  --output none && ok "AKS subnet created"

az network vnet subnet create \
  --name "${PREFIX}-snet-storage" \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --address-prefix "10.0.32.0/24" \
  --service-endpoints Microsoft.Storage \
  --output none && ok "Storage subnet created"

# =============================================================================
# 3. Network Security Group
# =============================================================================
echo ""
echo "=== Step 3: Network Security Group ==="
az network nsg create \
  --name "${PREFIX}-nsg" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --tags environment=demo managed_by=cli \
  --output none && ok "NSG created"

az network nsg rule create \
  --name "allow-internal" \
  --nsg-name "${PREFIX}-nsg" \
  --resource-group "$RG" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol "*" \
  --source-address-prefix "10.0.0.0/8" \
  --destination-address-prefix "10.0.0.0/8" \
  --source-port-range "*" \
  --destination-port-range "*" \
  --output none && ok "NSG rule created"

az network nsg rule create \
  --name "deny-internet-inbound" \
  --nsg-name "${PREFIX}-nsg" \
  --resource-group "$RG" \
  --priority 4000 \
  --direction Inbound \
  --access Deny \
  --protocol "*" \
  --source-address-prefix "Internet" \
  --destination-address-prefix "*" \
  --source-port-range "*" \
  --destination-port-range "*" \
  --output none && ok "NSG deny rule created"

az network vnet subnet update \
  --name "${PREFIX}-snet-aks" \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --network-security-group "${PREFIX}-nsg" \
  --output none && ok "NSG associated with AKS subnet"

# =============================================================================
# 4. Key Vault
# =============================================================================
echo ""
echo "=== Step 4: Key Vault ==="
az keyvault create \
  --name "$KV_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku standard \
  --enable-rbac-authorization true \
  --tags environment=demo managed_by=cli \
  --output none && ok "Key Vault: $KV_NAME"

# =============================================================================
# 5. Storage Account
# =============================================================================
echo ""
echo "=== Step 5: Storage Account ==="
az storage account create \
  --name "$STORAGE_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --tags environment=demo managed_by=cli \
  --output none && ok "Storage account: $STORAGE_NAME"

az storage container create \
  --name "app-data" \
  --account-name "$STORAGE_NAME" \
  --auth-mode login \
  --output none && ok "Blob container: app-data"

# =============================================================================
# 6. AKS Cluster (basic — no CMK for quick demo)
# =============================================================================
echo ""
echo "=== Step 6: AKS Cluster (this takes 5-10 mins) ==="
az aks create \
  --name "$AKS_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --node-count 1 \
  --node-vm-size Standard_D2s_v3 \
  --kubernetes-version 1.34.1 \
  --network-plugin azure \
  --vnet-subnet-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${PREFIX}-snet-aks" \
  --generate-ssh-keys \
  --enable-managed-identity \
  --tags environment=demo managed_by=cli \
  --output none && ok "AKS cluster created: $AKS_NAME"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================================="
echo " All resources created successfully!"
echo "================================================="
echo ""
echo " Resources in resource group: $RG"
echo ""
az resource list \
  --resource-group "$RG" \
  --query "[].{Name:name, Type:type}" \
  --output table

echo ""
echo "================================================="
echo " Now run the Import Pipeline:"
echo "   resource_group = $RG"
echo "   environment    = dev"
echo "   action         = discover-generate-validate"
echo "   tag_filter     = environment=demo"
echo "================================================="
