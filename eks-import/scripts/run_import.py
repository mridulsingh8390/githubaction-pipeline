#!/usr/bin/env python3
"""
Imports existing AWS VPC + EKS resources into Terraform state.
Does NOT create new resources - only registers existing ones.
"""
import json, subprocess, os, sys

with open('/tmp/eks-resources.json') as f:
    resources = json.load(f)

cluster_name    = os.environ.get('CLUSTER_NAME', '')
environment     = os.environ.get('ENVIRONMENT', 'dev')
aws_region      = os.environ.get('AWS_REGION', 'us-east-1')

print(f"Importing {len(resources)} resources into Terraform state")
print("NOTE: Only existing resources are registered - nothing is created")
print("=" * 60)

# Map resource type to Terraform module address
# Must match the module structure in Terraform-LAB
type_map = {
    'aws_vpc':                         'module.vpc.aws_vpc.vpc',
    'aws_subnet':                      None,   # handled dynamically below
    'aws_eks_cluster':                 'module.eks.aws_eks_cluster.eks',
    'aws_eks_node_group':              None,   # handled dynamically below
    'aws_iam_openid_connect_provider': 'module.eks.aws_iam_openid_connect_provider.eks',
}

# Import order matters: VPC and subnets must exist in state before EKS
# cluster/node groups, because the EFS module's resource count depends on
# module.vpc.private_subnet_ids - if VPC/subnets aren't in state yet, that
# output is null/unknown and Terraform can't resolve `count = length(...)`.
import_priority = {
    'aws_vpc':                         0,
    'aws_subnet':                      1,
    'aws_iam_openid_connect_provider': 2,
    'aws_eks_cluster':                 3,
    'aws_eks_node_group':              4,
}
resources.sort(key=lambda r: import_priority.get(r['type'], 99))

imported     = []
skipped      = []
failed       = []
subnet_index = 0   # separate counter, not derived from resource names

# Build var-file args
var_args = [
    f'-var-file=values/{environment}.tfvars',
    f'-var=aws_region={aws_region}',
]

for r in resources:
    rtype  = r['type']
    rid    = r['id']
    rname  = r['name']

    # Dynamic address for subnets (indexed by position)
    if rtype == 'aws_subnet':
        tf_addr = f'module.vpc.aws_subnet.private[{subnet_index}]'
        subnet_index += 1

    elif rtype == 'aws_eks_node_group':
        ng_name = rid.split(':')[-1]
        if 'system' in ng_name:
            tf_addr = 'module.eks.aws_eks_node_group.system[0]'
        else:
            tf_addr = 'module.eks.aws_eks_node_group.user'
    else:
        tf_addr = type_map.get(rtype)

    if not tf_addr:
        skipped.append(rname)
        print(f"SKIP  : {rname} ({rtype}) - no mapping")
        continue

    print(f"IMPORT: {rname} -> {tf_addr}")

    cmd = ['terraform', 'import', '-input=false'] + var_args + [tf_addr, rid]
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode == 0:
        imported.append(rname)
        print(f"  OK  : {rname} added to state")
    else:
        if 'already managed' in result.stderr or 'already exists' in result.stderr:
            imported.append(rname)
            print(f"  OK  : {rname} already in state")
        else:
            failed.append(rname)
            print(f"  WARN: {rname}")
            print(f"        {result.stderr.strip()[:300]}")

print("")
print("=" * 60)
print(f"Import Summary:")
print(f"  Imported : {len(imported)} resources")
print(f"  Skipped  : {len(skipped)} resources (no mapping)")
print(f"  Failed   : {len(failed)} resources")
print("=" * 60)

# Run terraform plan to verify
print("\nRunning terraform plan to verify state matches reality...")
print("Expected: No changes (or minor config drift)")
print("=" * 60)

plan_cmd = ['terraform', 'plan', '-input=false', '-detailed-exitcode'] + var_args
result   = subprocess.run(plan_cmd, capture_output=False, text=True)

if result.returncode == 0:
    print("\nSUCCESS: No changes - state matches AWS reality perfectly")
elif result.returncode == 2:
    print("\nINFO: Some drift detected - review plan above")
    print("Normal if tfvars values differ slightly from actual config")
else:
    print(f"\nERROR: Plan failed - check errors above")
    sys.exit(1)
