#!/usr/bin/env python3
import json, subprocess, os, sys

with open('/tmp/all-resources-raw.json') as f:
    resources = json.load(f)

tag_filter = os.environ.get('TAG_FILTER', '')
if tag_filter:
    key, val = tag_filter.split('=', 1)
    resources = [r for r in resources if r.get('tags', {}).get(key) == val]

print(f'Importing {len(resources)} resources...')

type_map = {
    'microsoft.network/virtualnetworks':          'module.vnet.azurerm_virtual_network.vnet',
    'microsoft.keyvault/vaults':                  'module.keyvault.azurerm_key_vault.kv',
    'microsoft.storage/storageaccounts':          'module.storage.azurerm_storage_account.sa',
    'microsoft.containerservice/managedclusters': 'module.aks.azurerm_kubernetes_cluster.aks',
    'microsoft.network/networksecuritygroups':    'module.vnet.azurerm_network_security_group.aks_user',
}

for r in resources:
    rtype  = r['type'].lower()
    rid    = r['id']
    rname  = r['name']
    tf_addr = type_map.get(rtype)

    if not tf_addr:
        print(f'SKIP (no mapping): {rtype} - {rname}')
        continue

    print(f'Importing: {rname} -> {tf_addr}')
    result = subprocess.run(
        ['terraform', 'import', '-input=false', tf_addr, rid],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        print(f'  OK: {rname}')
    else:
        print(f'  WARN: {rname} - {result.stderr.strip()[:200]}')

print('Import complete')
