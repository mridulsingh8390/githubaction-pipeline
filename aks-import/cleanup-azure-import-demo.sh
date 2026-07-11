#!/bin/bash
# =============================================================================
# Cleanup Azure Import Demo Resources
# Deletes the resource group and everything inside it
# =============================================================================

RG="rg-import-demo"

echo "Deleting resource group: $RG"
echo "This will delete ALL resources inside it..."
echo ""

az group delete \
  --name "$RG" \
  --yes \
  --no-wait

echo "Deletion started (running in background)"
echo "Check status: az group show --name $RG --query properties.provisioningState"
