#!/usr/bin/env python3
import json, subprocess

with open('/tmp/all-resources.json') as f:
    resources = json.load(f)

detailed = []
for r in resources:
    result = subprocess.run(
        ['az', 'resource', 'show', '--ids', r['id'], '--output', 'json'],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        detailed.append(json.loads(result.stdout))
        print(f'Fetched: {r["name"]}')
    else:
        detailed.append(r)
        print(f'Skipped: {r["name"]}')

with open('/tmp/all-resources.json', 'w') as f:
    json.dump(detailed, f, indent=2)
print(f'Done - {len(detailed)} resources')
