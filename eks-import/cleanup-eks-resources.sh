#!/bin/bash
# =============================================================================
# Cleanup AWS EKS Import Demo Resources
# Deletes everything created by create-eks-resources.sh in the correct order
#
# Usage: bash cleanup-eks-resources.sh
# =============================================================================

REGION="us-east-1"
PREFIX="eks-import-demo"
CLUSTER_NAME="eks-import-demo-cluster"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "================================================="
echo " Cleaning up EKS Import Demo Resources"
echo "================================================="

# =============================================================================
# 1. Delete EKS Node Group (must happen before cluster deletion)
# =============================================================================
echo ""
echo "=== Step 1: Deleting EKS Node Group ==="
aws eks delete-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${PREFIX}-user" \
  --region "$REGION" 2>/dev/null \
  && ok "Node group deletion started" \
  || warn "Node group not found or already deleted"

echo "Waiting for node group deletion (this can take 5-10 mins)..."
aws eks wait nodegroup-deleted \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${PREFIX}-user" \
  --region "$REGION" 2>/dev/null \
  && ok "Node group deleted" \
  || warn "Node group already gone"

# =============================================================================
# 2. Delete EKS Cluster
# =============================================================================
echo ""
echo "=== Step 2: Deleting EKS Cluster ==="
aws eks delete-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" 2>/dev/null \
  && ok "Cluster deletion started" \
  || warn "Cluster not found or already deleted"

echo "Waiting for cluster deletion (this can take 5-10 mins)..."
aws eks wait cluster-deleted \
  --name "$CLUSTER_NAME" \
  --region "$REGION" 2>/dev/null \
  && ok "Cluster deleted" \
  || warn "Cluster already gone"

# =============================================================================
# 3. Delete OIDC Provider (if exists)
# =============================================================================
echo ""
echo "=== Step 3: Deleting OIDC Provider ==="
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${PREFIX}')].Arn | [0]" \
  --output text 2>/dev/null)

if [ -n "$OIDC_ARN" ] && [ "$OIDC_ARN" != "None" ]; then
  aws iam delete-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_ARN" \
    && ok "OIDC provider deleted" \
    || fail "Failed to delete OIDC provider"
else
  warn "No OIDC provider found"
fi

# =============================================================================
# 4. Delete IAM Roles
# =============================================================================
echo ""
echo "=== Step 4: Deleting IAM Roles ==="

NODE_ROLE_NAME="${PREFIX}-node-role"
for POLICY in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
  aws iam detach-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/${POLICY}" 2>/dev/null
done
aws iam delete-role --role-name "$NODE_ROLE_NAME" 2>/dev/null \
  && ok "Node IAM role deleted" \
  || warn "Node role not found or already deleted"

CLUSTER_ROLE_NAME="${PREFIX}-cluster-role"
aws iam detach-role-policy \
  --role-name "$CLUSTER_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" 2>/dev/null
aws iam delete-role --role-name "$CLUSTER_ROLE_NAME" 2>/dev/null \
  && ok "Cluster IAM role deleted" \
  || warn "Cluster role not found or already deleted"

# =============================================================================
# 5. Find VPC by tag
# =============================================================================
echo ""
echo "=== Step 5: Finding VPC ==="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  warn "No VPC found - may already be deleted"
  echo ""
  echo "================================================="
  echo " Cleanup complete (VPC and networking already gone)"
  echo "================================================="
  exit 0
fi

ok "Found VPC: $VPC_ID"

# =============================================================================
# 6. Delete Security Groups (non-default)
# =============================================================================
echo ""
echo "=== Step 6: Deleting Security Groups ==="
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text)

for SG in $SG_IDS; do
  aws ec2 delete-security-group --group-id "$SG" --region "$REGION" \
    && ok "Deleted SG: $SG" \
    || warn "Could not delete SG: $SG (may have dependencies)"
done

# =============================================================================
# 7. Delete NAT Gateway
# =============================================================================
echo ""
echo "=== Step 7: Deleting NAT Gateway ==="
NAT_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --region "$REGION" \
  --query 'NatGateways[0].NatGatewayId' --output text)

if [ -n "$NAT_ID" ] && [ "$NAT_ID" != "None" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$REGION" \
    && ok "NAT Gateway deletion started: $NAT_ID"
  echo "Waiting 45s for NAT Gateway to delete..."
  sleep 45
else
  warn "No NAT Gateway found"
fi

# =============================================================================
# 8. Release Elastic IP
# =============================================================================
echo ""
echo "=== Step 8: Releasing Elastic IP ==="
EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PREFIX}-nat-eip" \
  --region "$REGION" \
  --query 'Addresses[0].AllocationId' --output text)

if [ -n "$EIP_ALLOC" ] && [ "$EIP_ALLOC" != "None" ]; then
  aws ec2 release-address --allocation-id "$EIP_ALLOC" --region "$REGION" \
    && ok "EIP released: $EIP_ALLOC" \
    || warn "Could not release EIP (may still be in use)"
else
  warn "No EIP found"
fi

# =============================================================================
# 9. Delete Internet Gateway
# =============================================================================
echo ""
echo "=== Step 9: Deleting Internet Gateway ==="
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)

if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" \
    && ok "IGW deleted: $IGW_ID"
else
  warn "No IGW found"
fi

# =============================================================================
# 10. Delete Subnets
# =============================================================================
echo ""
echo "=== Step 10: Deleting Subnets ==="
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'Subnets[].SubnetId' --output text)

for SUBNET in $SUBNET_IDS; do
  aws ec2 delete-subnet --subnet-id "$SUBNET" --region "$REGION" \
    && ok "Deleted subnet: $SUBNET" \
    || warn "Could not delete subnet: $SUBNET"
done

# =============================================================================
# 11. Delete Route Tables (non-main)
# =============================================================================
echo ""
echo "=== Step 11: Deleting Route Tables ==="
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query "RouteTables[?Associations[0].Main != \`true\`].RouteTableId" \
  --output text)

for RT in $RT_IDS; do
  aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" \
    && ok "Deleted route table: $RT" \
    || warn "Could not delete route table: $RT"
done

# =============================================================================
# 12. Delete VPC
# =============================================================================
echo ""
echo "=== Step 12: Deleting VPC ==="
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" \
  && ok "VPC deleted: $VPC_ID" \
  || fail "Could not delete VPC - check for remaining dependencies"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================================="
echo " Cleanup complete"
echo "================================================="
echo ""
echo " If VPC deletion failed, check for:"
echo "   - Remaining ENIs (network interfaces)"
echo "   - Load balancers still attached"
echo "   - VPC endpoints"
echo ""
echo " Verify with:"
echo "   aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION"
echo "================================================="
