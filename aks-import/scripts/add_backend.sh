#!/bin/bash
cat > /tmp/generated-tf/backend.tf << TFEOF
terraform {
  backend "s3" {}
}
provider "azurerm" {
  subscription_id = var.subscription_id
  use_oidc        = true
  features {}
}
variable "subscription_id" {
  type    = string
  default = null
}
TFEOF
echo "Backend config added"
