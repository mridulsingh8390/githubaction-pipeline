#!/bin/bash
set -e
OUTPUT_DIR="/tmp/generated-tf"
cd "$OUTPUT_DIR"

echo "=== Files before cleanup ==="
ls -la *.tf 2>/dev/null || echo "no tf files"

# Remove ALL files aztfexport generates for backend/provider
rm -f backend.tf terraform.tf provider.tf

# Create clean backend.tf using printf to avoid heredoc issues
printf 'terraform {\n  backend "s3" {}\n}\n' > backend.tf

# Create clean provider.tf using printf
printf 'provider "azurerm" {\n  features {}\n  use_oidc        = true\n  subscription_id = var.subscription_id\n}\n\nvariable "subscription_id" {\n  type    = string\n  default = null\n}\n' > provider.tf

echo "=== Files after cleanup ==="
echo "--- backend.tf ---"
cat backend.tf
echo "--- provider.tf ---"
cat provider.tf
echo "All done"
