#!/usr/bin/env python3
"""
Discovers AWS VPC and EKS resources and generates a discovery report.
"""
import json, subprocess, os, sys
from collections import defaultdict

cluster_name = os.environ.get('CLUSTER_NAME', '')
region       = os.environ.get('AWS_REGION', 'us-east-1')

print(f"Discovering resources for cluster: {cluster_name}")
print(f"Region: {region}")
print("=" * 50)

resources = []

# ── EKS Cluster ──────────────────────────────────────────────────────────────
def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    return None

# EKS Cluster
eks = run(['aws', 'eks', 'describe-cluster',
           '--name', cluster_name, '--region', region])
if eks:
    c = eks['cluster']
    resources.append({
        'type': 'aws_eks_cluster',
        'name': c['name'],
        'id':   c['name'],
        'arn':  c['arn'],
        'details': {
            'version':    c.get('version'),
            'endpoint':   c.get('endpoint'),
            'vpc_id':     c.get('resourcesVpcConfig', {}).get('vpcId'),
            'subnet_ids': c.get('resourcesVpcConfig', {}).get('subnetIds', []),
            'role_arn':   c.get('roleArn'),
        }
    })
    print(f"Found EKS cluster: {c['name']} (v{c.get('version')})")

    # VPC from cluster config
    vpc_id = c.get('resourcesVpcConfig', {}).get('vpcId')
    if vpc_id:
        vpc = run(['aws', 'ec2', 'describe-vpcs',
                   '--vpc-ids', vpc_id, '--region', region])
        if vpc and vpc.get('Vpcs'):
            v = vpc['Vpcs'][0]
            name_tag = next((t['Value'] for t in v.get('Tags', [])
                             if t['Key'] == 'Name'), vpc_id)
            resources.append({
                'type': 'aws_vpc',
                'name': name_tag,
                'id':   vpc_id,
                'details': {
                    'cidr_block':           v.get('CidrBlock'),
                    'enable_dns_support':   True,
                    'enable_dns_hostnames': True,
                }
            })
            print(f"Found VPC: {name_tag} ({vpc_id}) - {v.get('CidrBlock')}")

        # Subnets
        subnets = run(['aws', 'ec2', 'describe-subnets',
                       '--filters', f'Name=vpc-id,Values={vpc_id}',
                       '--region', region])
        if subnets:
            for s in subnets.get('Subnets', []):
                name_tag = next((t['Value'] for t in s.get('Tags', [])
                                 if t['Key'] == 'Name'), s['SubnetId'])
                resources.append({
                    'type': 'aws_subnet',
                    'name': name_tag,
                    'id':   s['SubnetId'],
                    'details': {
                        'cidr_block':        s.get('CidrBlock'),
                        'availability_zone': s.get('AvailabilityZone'),
                        'vpc_id':            vpc_id,
                    }
                })
                print(f"Found Subnet: {name_tag} ({s['SubnetId']}) - {s.get('CidrBlock')}")

# EKS Node Groups
node_groups = run(['aws', 'eks', 'list-nodegroups',
                   '--cluster-name', cluster_name, '--region', region])
if node_groups:
    for ng_name in node_groups.get('nodegroups', []):
        ng = run(['aws', 'eks', 'describe-nodegroup',
                  '--cluster-name', cluster_name,
                  '--nodegroup-name', ng_name, '--region', region])
        if ng:
            n = ng['nodegroup']
            resources.append({
                'type': 'aws_eks_node_group',
                'name': ng_name,
                'id':   f'{cluster_name}:{ng_name}',
                'details': {
                    'instance_types': n.get('instanceTypes', []),
                    'desired_size':   n.get('scalingConfig', {}).get('desiredSize'),
                    'min_size':       n.get('scalingConfig', {}).get('minSize'),
                    'max_size':       n.get('scalingConfig', {}).get('maxSize'),
                    'node_role_arn':  n.get('nodeRole'),
                }
            })
            print(f"Found Node Group: {ng_name}")

# OIDC Provider
oidc_providers = run(['aws', 'iam', 'list-open-id-connect-providers'])
if oidc_providers and eks:
    cluster_oidc = eks['cluster'].get('identity', {}).get('oidc', {}).get('issuer', '')
    oidc_id = cluster_oidc.split('/')[-1] if cluster_oidc else ''
    for p in oidc_providers.get('OpenIDConnectProviderList', []):
        if oidc_id and oidc_id in p['Arn']:
            resources.append({
                'type': 'aws_iam_openid_connect_provider',
                'name': 'eks_oidc',
                'id':   p['Arn'],
                'details': {'url': cluster_oidc}
            })
            print(f"Found OIDC Provider: {p['Arn']}")

# Summary
by_type = defaultdict(list)
for r in resources:
    by_type[r['type']].append(r['name'])

report = {
    'cluster_name': cluster_name,
    'region':       region,
    'total':        len(resources),
    'resources':    resources,
    'summary':      {t: len(v) for t, v in by_type.items()}
}

with open('/tmp/eks-discovery-report.json', 'w') as f:
    json.dump(report, f, indent=2)

with open('/tmp/eks-resources.json', 'w') as f:
    json.dump(resources, f, indent=2)

with open('/tmp/resource_count.txt', 'w') as f:
    f.write(str(len(resources)))

print(f"\nTotal resources found: {len(resources)}")
print("Saved to /tmp/eks-discovery-report.json")
