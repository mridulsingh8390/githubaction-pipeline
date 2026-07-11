import json
import sys
import os
from collections import defaultdict

tag_filter = os.environ.get('TAG_FILTER', '')
rg = os.environ.get('RESOURCE_GROUP', '')

with open('/tmp/all-resources-raw.json') as f:
    resources = json.load(f)

# Filter by tag if provided
if tag_filter:
    key, val = tag_filter.split('=', 1)
    resources = [r for r in resources
                 if r.get('tags', {}).get(key) == val]
    print(f"Tag filter {key}={val}: matched {len(resources)} resources")

by_type = defaultdict(list)
for r in resources:
    by_type[r['type']].append({'name': r['name'], 'id': r['id']})

report = {
    'resource_group': rg,
    'total': len(resources),
    'by_type': dict(by_type),
    'summary': {t: len(v) for t, v in by_type.items()}
}

with open('/tmp/all-resources.json', 'w') as f:
    json.dump(resources, f)

with open('/tmp/discovery-report.json', 'w') as f:
    json.dump(report, f, indent=2)

print(f"\nTotal resources: {len(resources)}")
for t, items in sorted(by_type.items()):
    print(f"  {t}: {len(items)}")
    for item in items:
        print(f"    - {item['name']}")

print(len(resources), file=open('/tmp/resource_count.txt', 'w'), end='')
print(','.join(report['summary'].keys()), file=open('/tmp/resource_types.txt', 'w'), end='')
