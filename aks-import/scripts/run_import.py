#!/usr/bin/env python3
"""
Generates a Terraform import block file and runs a single terraform apply
to import all resources at once - avoids multiple state lock acquisitions.
"""
import json, subprocess, os, sys

with open('/tmp/all-resources-raw.json') as f:
    resources = json.load(f)

tag_filter = os.environ.get('TAG_FILTER', '')
if tag_filter:
    key, val = tag_filter.split('=', 1)
    resources = [r for r in resources if r.get('tags', {}).get(key) == val]

print(f'Found {len(resources)} resources to import')

# Map Azure resource types to Terraform addresses in our modules
type_map = {
    'microsoft.network/virtualnetworks':          'module.vnet.azurerm_virtual_network.vnet',
    'microsoft.keyvault/vaults':                  'module.keyvault.azurerm_key_vault.kv',
    'microsoft.storage/storageaccounts':          'module.storage.azurerm_storage_account.sa',
    'microsoft.containerservice/managedclusters': 'module.aks.azurerm_kubernetes_cluster.aks',
    'microsoft.network/networksecuritygroups':    'module.vnet.azurerm_network_security_group.aks_user',
}

# Generate import.tf with native import blocks (Terraform 1.5+)
# This way a single terraform apply acquires the lock once for all imports
import_blocks = []
skipped = []

for r in resources:
    rtype   = r['type'].lower()
    rid     = r['id']
    rname   = r['name']
    tf_addr = type_map.get(rtype)

    if not tf_addr:
        skipped.append(f'{rtype} - {rname}')
        continue

    import_blocks.append(f'''import {{
  id = "{rid}"
  to = {tf_addr}
}}
''')
    print(f'Will import: {rname} -> {tf_addr}')

if skipped:
    print(f'\nSkipped (no mapping):')
    for s in skipped:
        print(f'  - {s}')

if not import_blocks:
    print('No resources to import - check type_map or tag_filter')
    sys.exit(0)

# Write import blocks to a file in the working directory
with open('import_generated.tf', 'w') as f:
    f.write('\n'.join(import_blocks))

print(f'\nGenerated import_generated.tf with {len(import_blocks)} import blocks')
print('Running terraform plan to preview imports...')

environment     = os.environ.get('ENVIRONMENT', 'dev')
subscription_id = os.environ.get('SUBSCRIPTION_ID', '')

cmd = [
    'terraform', 'plan',
    '-input=false',
    '-generate-config-out=generated_resources.tf',
    f'-var-file=values/{environment}.tfvars',
]
if subscription_id:
    cmd.append(f'-var=subscription_id={subscription_id}')

result = subprocess.run(cmd, capture_output=False, text=True)

if result.returncode not in (0, 2):
    print(f'Plan failed with exit code {result.returncode}')
    # Clean up
    if os.path.exists('import_generated.tf'):
        os.remove('import_generated.tf')
    sys.exit(result.returncode)

print('\nPlan complete. Check output above for import preview.')
print('Run terraform apply to complete the import.')
