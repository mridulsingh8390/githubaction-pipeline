#!/usr/bin/env python3
"""
Correct terraform import flow:
1. Read existing Azure resources
2. Run terraform import for each one (adds to state WITHOUT creating)
3. Run terraform plan to verify state matches reality
4. Report any drift

This does NOT create new resources. It only tells Terraform about
existing ones so it can manage them going forward.
"""
import json, subprocess, os, sys

with open('/tmp/all-resources-raw.json') as f:
    resources = json.load(f)

tag_filter = os.environ.get('TAG_FILTER', '')
if tag_filter:
    key, val = tag_filter.split('=', 1)
    resources = [r for r in resources if r.get('tags', {}).get(key) == val]

environment     = os.environ.get('ENVIRONMENT', 'dev')
subscription_id = os.environ.get('SUBSCRIPTION_ID', '')

print(f'Found {len(resources)} resources to import into Terraform state')
print('NOTE: This imports EXISTING resources - no new resources are created')
print('='*60)

# Map Azure resource types to Terraform module addresses
# These must match the module structure in Terraform-LAB
type_map = {
    'microsoft.network/virtualnetworks':
        'module.vnet.azurerm_virtual_network.vnet',
    'microsoft.network/networksecuritygroups':
        'module.vnet.azurerm_network_security_group.aks_user',
    'microsoft.keyvault/vaults':
        'module.keyvault.azurerm_key_vault.kv',
    'microsoft.storage/storageaccounts':
        'module.storage.azurerm_storage_account.sa',
    'microsoft.containerservice/managedclusters':
        'module.aks.azurerm_kubernetes_cluster.aks',
}

imported  = []
skipped   = []
failed    = []

for r in resources:
    rtype   = r['type'].lower()
    rid     = r['id']
    rname   = r['name']
    tf_addr = type_map.get(rtype)

    if not tf_addr:
        skipped.append(rname)
        print(f'SKIP  : {rname} ({rtype}) - no Terraform mapping defined')
        continue

    print(f'IMPORT: {rname} -> {tf_addr}')

    cmd = [
        'terraform', 'import',
        '-input=false',
        f'-var-file=values/{environment}.tfvars',
    ]
    if subscription_id:
        cmd.append(f'-var=subscription_id={subscription_id}')
    cmd += [tf_addr, rid]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode == 0:
        imported.append(rname)
        print(f'  OK  : {rname} added to state')
    else:
        # Already in state is not a failure
        if 'already managed' in result.stderr or 'already exists' in result.stderr:
            imported.append(rname)
            print(f'  OK  : {rname} already in state')
        else:
            failed.append(rname)
            print(f'  WARN: {rname} - {result.stderr.strip()[:300]}')

print('')
print('='*60)
print(f'Import Summary:')
print(f'  Imported : {len(imported)} resources')
print(f'  Skipped  : {len(skipped)} resources (no mapping)')
print(f'  Failed   : {len(failed)} resources')
print('='*60)

if failed:
    print(f'\nFailed resources: {failed}')
    print('Check the Terraform address mapping in type_map')

print('\nRunning terraform plan to verify state matches reality...')
print('Expected: No changes (or only minor config drift)')
print('='*60)

# Build plan command with all required variables
cmd = [
    'terraform', 'plan',
    '-input=false',
    '-detailed-exitcode',
    f'-var-file=values/{environment}.tfvars',
]
if subscription_id:
    cmd.append(f'-var=subscription_id={subscription_id}')

result = subprocess.run(cmd, capture_output=False, text=True)

if result.returncode == 0:
    print('\nSUCCESS: No changes - Terraform state perfectly matches Azure reality')
elif result.returncode == 2:
    print('\nINFO: Some drift detected - review plan above before applying')
    print('This is normal if your tfvars values differ slightly from actual config')
else:
    print(f'\nERROR: Plan failed - check errors above')
    sys.exit(1)
