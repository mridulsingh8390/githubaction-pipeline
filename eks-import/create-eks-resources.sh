#!/bin/bash
# =============================================================================
# Create AWS VPC + EKS Resources for Import Demo
# These resources will then be imported into Terraform using the import pipeline
#
# Resources created:
#   - VPC + Subnets (2 private, 2 public)
#   - Internet Gateway + NAT Gateway
#   - Route Tables
#   - Security Groups
#   - EKS Cluster
#   - EKS Node Group (user only, simpler)
#
# Usage: bash create-eks-resources.sh
# =============================================================================

REGION="us-east-1"
PREFIX="eks-import-demo"
VPC_CIDR="10.1.0.0/16"
CLUSTER_NAME="eks-import-demo-cluster"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "================================================="
echo " Creating AWS EKS Import Demo Resources"
echo " Region  : $REGION"
echo " Prefix  : $PREFIX"
echo "================================================="

# =============================================================================
# 1. VPC
# =============================================================================
echo ""
echo "=== Step 1: VPC ==="
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc},{Key=environment,Value=demo},{Key=managed_by,Value=cli}]" \
  --query 'Vpc.VpcId' --output text) && ok "VPC created: $VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" --region "$REGION"
ok "DNS support enabled"

# =============================================================================
# 2. Subnets
# =============================================================================
echo ""
echo "=== Step 2: Subnets ==="

AZ1="${REGION}a"
AZ2="${REGION}b"

PRIVATE_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.1.1.0/24" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-private-1},{Key=environment,Value=demo},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' --output text) && ok "Private subnet 1: $PRIVATE_SUBNET_1"

PRIVATE_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.1.2.0/24" \
  --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-private-2},{Key=environment,Value=demo},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' --output text) && ok "Private subnet 2: $PRIVATE_SUBNET_2"

PUBLIC_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.1.101.0/24" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-public-1},{Key=environment,Value=demo},{Key=kubernetes.io/role/elb,Value=1}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' --output text) && ok "Public subnet 1: $PUBLIC_SUBNET_1"

# =============================================================================
# 3. Internet Gateway
# =============================================================================
echo ""
echo "=== Step 3: Internet Gateway ==="
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw}]" \
  --region "$REGION" \
  --query 'InternetGateway.InternetGatewayId' --output text) && ok "IGW created: $IGW_ID"

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" && ok "IGW attached to VPC"

# =============================================================================
# 4. NAT Gateway
# =============================================================================
echo ""
echo "=== Step 4: NAT Gateway ==="
EIP_ALLOC=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-nat-eip}]" \
  --region "$REGION" \
  --query 'AllocationId' --output text) && ok "EIP allocated: $EIP_ALLOC"

NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_1" \
  --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-nat}]" \
  --region "$REGION" \
  --query 'NatGateway.NatGatewayId' --output text) && ok "NAT Gateway created: $NAT_ID (creating, ~1 min)"

echo "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$REGION"
ok "NAT Gateway available"

# =============================================================================
# 5. Route Tables
# =============================================================================
echo ""
echo "=== Step 5: Route Tables ==="
PUBLIC_RT=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-rt-public}]" \
  --region "$REGION" \
  --query 'RouteTable.RouteTableId' --output text) && ok "Public route table: $PUBLIC_RT"

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$REGION" > /dev/null && ok "Public route added"

aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_1" --region "$REGION" > /dev/null

PRIVATE_RT=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-rt-private}]" \
  --region "$REGION" \
  --query 'RouteTable.RouteTableId' --output text) && ok "Private route table: $PRIVATE_RT"

aws ec2 create-route \
  --route-table-id "$PRIVATE_RT" \
  --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_ID" \
  --region "$REGION" > /dev/null && ok "Private route added"

aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_1" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_2" --region "$REGION" > /dev/null
ok "Route tables associated"

# =============================================================================
# 6. Security Group
# =============================================================================
echo ""
echo "=== Step 6: Security Group ==="
SG_ID=$(aws ec2 create-security-group \
  --group-name "${PREFIX}-eks-sg" \
  --description "EKS import demo security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-eks-sg}]" \
  --region "$REGION" \
  --query 'GroupId' --output text) && ok "Security group: $SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol -1 \
  --source-group "$SG_ID" \
  --region "$REGION" > /dev/null && ok "Self-referencing ingress rule added"

# =============================================================================
# 7. IAM Roles for EKS
# =============================================================================
echo ""
echo "=== Step 7: IAM Roles ==="

CLUSTER_ROLE_NAME="${PREFIX}-cluster-role"
aws iam create-role \
  --role-name "$CLUSTER_ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "eks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' > /dev/null && ok "Cluster IAM role created"

aws iam attach-role-policy \
  --role-name "$CLUSTER_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" && ok "Cluster policy attached"

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name "$CLUSTER_ROLE_NAME" --query 'Role.Arn' --output text)

NODE_ROLE_NAME="${PREFIX}-node-role"
aws iam create-role \
  --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' > /dev/null && ok "Node IAM role created"

for POLICY in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
  aws iam attach-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/${POLICY}"
done
ok "Node policies attached"

NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query 'Role.Arn' --output text)

# Wait for IAM propagation
echo "Waiting 15s for IAM role propagation..."
sleep 15

# =============================================================================
# 8. EKS Cluster
# =============================================================================
echo ""
echo "=== Step 8: EKS Cluster (takes 10-15 mins) ==="
aws eks create-cluster \
  --name "$CLUSTER_NAME" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config subnetIds="${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}",securityGroupIds="${SG_ID}" \
  --region "$REGION" \
  --tags environment=demo,managed_by=cli \
  > /dev/null && ok "EKS cluster creation started: $CLUSTER_NAME"

echo "Waiting for cluster to become ACTIVE (10-15 mins)..."
aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION"
ok "EKS cluster ACTIVE"

# =============================================================================
# 9. EKS Node Group
# =============================================================================
echo ""
echo "=== Step 9: EKS Node Group (takes 5-10 mins) ==="
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${PREFIX}-user" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" \
  --instance-types t3.medium \
  --scaling-config minSize=1,maxSize=2,desiredSize=1 \
  --region "$REGION" \
  --tags environment=demo,managed_by=cli \
  > /dev/null && ok "Node group creation started"

echo "Waiting for node group to become ACTIVE (5-10 mins)..."
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "${PREFIX}-user" --region "$REGION"
ok "Node group ACTIVE"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================================="
echo " All resources created successfully!"
echo "================================================="
echo ""
echo " VPC:          $VPC_ID"
echo " Subnets:      $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2, $PUBLIC_SUBNET_1"
echo " EKS Cluster:  $CLUSTER_NAME"
echo " Node Group:   ${PREFIX}-user"
echo ""
echo "================================================="
echo " Now run the EKS Import Pipeline with:"
echo "   cluster_name = $CLUSTER_NAME"
echo "   environment  = dev"
echo "   action       = all"
echo "   aws_region   = $REGION"
echo "   branch       = main"
echo "================================================="