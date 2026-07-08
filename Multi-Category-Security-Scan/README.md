# Multi-Category Security Scan Pipeline

A single GitHub Actions workflow (`multi-category-scan-pipeline.yml`) that runs
security scans across four categories — **Docker**, **Host/Network**, **Cloud**, and
**Codebase** — selected at trigger time via `workflow_dispatch`. Every non-cloud
category is entirely secret-free.

## How it works

Pick a `scanCategory` when running the workflow; only that category's job runs. A
final `report` job always runs afterward and prints a results table to the GitHub
Actions run summary (and to the logs).

```
scanCategory = docker        →  docker-scan        →  report
scanCategory = host_network  →  host-network-scan   →  report
scanCategory = cloud         →  cloud-scan          →  report
scanCategory = codebase      →  codebase-scan       →  report
```

> **GitHub Actions UI limitation:** `workflow_dispatch` forms can't show/hide fields
> based on another field's value. All inputs are always visible when you trigger the
> workflow manually — just ignore the checkboxes that don't belong to the category
> you selected.

## Categories & tools

| Category | Tools | Secrets required? |
|---|---|---|
| **`docker`** | Trivy, Dockle | No |
| **`host_network`** | Nmap, Nuclei, OWASP ZAP | No |
| **`cloud`** | ScoutSuite (posture audit) + optional Trivy (registry image CVE scan) | **Yes** — cloud auth is unavoidable |
| **`codebase`** | Gitleaks (secrets scan), Semgrep (SAST) | No (Gitleaks only uses the auto-provided `GITHUB_TOKEN`) |

### Excluded tools

These were considered and deliberately left out — either they're placeholders for
tools that were never confirmed, or every one of them requires a token/client
ID/API key to function at all:

- **DockerShield** — tool never confirmed, no known public action
- **Wiz** — needs `WIZ_CLIENT_ID`/`WIZ_CLIENT_SECRET`
- **Burp Suite** — needs a licensed Enterprise instance + API key
- **Nessus** — needs a running Tenable manager + API keys
- **OpenVAS/GVM** — needs a persistent GVM server (doesn't fit an ephemeral runner)
- **Black Duck, Snyk** — need `BLACKDUCK_API_TOKEN` / `SNYK_TOKEN`
- **Grype, Lynis, Nikto** — dropped during scope narrowing, not part of the final tool list

## Inputs

### `scanCategory` (required)
`docker` | `host_network` | `cloud` | `codebase` — default `docker`

### Docker (`scanCategory = docker`)
| Input | Required | Default | Notes |
|---|---|---|---|
| `imageRef` | **Yes** | — | Image to scan, `repo:tag` — no placeholder default on purpose |
| `runTrivy` | No | `true` | CVE scan |
| `runDockle` | No | `true` | Dockerfile/image best-practice lint |

### Host/Network (`scanCategory = host_network`)
| Input | Required | Default | Notes |
|---|---|---|---|
| `targets` | **Yes** | — | Comma-separated hosts/IPs/CIDRs/URLs |
| `runNmap` | No | `true` | Port/service discovery |
| `runNuclei` | No | `true` | Template-based vuln scan |
| `runZap` | No | `true` | Assumes at least one target is a URL |

### Cloud (`scanCategory = cloud`)
| Input | Required | Default | Notes |
|---|---|---|---|
| `cloudProvider` | No | `aws` | `aws` \| `azure` \| `gcp` |
| `cloudRunImageScan` | No | `false` | Also pull + Trivy-scan an image from the provider's registry |
| `cloudImageRef` | No | `""` | Full image ref, e.g. `<acct>.dkr.ecr.<region>.amazonaws.com/repo:tag`, `<name>.azurecr.io/repo:tag`, `<region>-docker.pkg.dev/<project>/repo:tag` |

### Codebase (`scanCategory = codebase`)
| Input | Required | Default | Notes |
|---|---|---|---|
| `runGitleaks` | No | `true` | Secrets scan across full git history |
| `runSemgrep` | No | `true` | SAST using `p/security-audit`, `p/secrets`, `p/owasp-top-ten` rulesets |

## Prerequisites

### Cloud category only

The `cloud` category is the one exception to "no secrets" — you cannot authenticate
to a cloud account without credentials. Set whichever of these apply as repo/org
secrets:

| Provider | Secrets |
|---|---|
| AWS | `AWS_SCAN_ROLE_ARN` |
| Azure | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| GCP | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

If you also enable `cloudRunImageScan`, the same OIDC role/service principal needs
**registry read/pull permissions** in addition to whatever ScoutSuite needs for the
posture audit:

- AWS: `AmazonEC2ContainerRegistryReadOnly` (or equivalent ECR pull policy)
- Azure: `AcrPull` role on the target registry
- GCP: `Artifact Registry Reader` role

### All other categories

No setup beyond the default `GITHUB_TOKEN` GitHub provides automatically.

## Running the pipeline

**Actions → Multi-Category Security Scan Pipeline → Run workflow**, then:

1. Select `scanCategory`
2. Fill in the required input(s) for that category (`imageRef` for docker,
   `targets` for host/network)
3. Toggle whichever tool checkboxes you want on/off
4. Run — check the workflow summary for the results table

## Known limitations

- **ZAP expects a single URL target.** If `targets` contains multiple comma-separated
  hosts/IPs and `runZap` is enabled, only a URL-shaped entry will scan correctly —
  non-URL entries (bare IPs) may cause it to fail or behave unpredictably.
- **Cloud image registry parsing is done with simple string splitting** (`cut` on
  `/` and `.`), assuming standard registry URL formats for each provider. Non-standard
  registry naming may break the parsing in the `cloud-scan` job.
- **Trivy and ZAP steps use `continue-on-error: true` with `exit-code: '0'`** so a
  single tool failure doesn't block the whole job — status is captured explicitly in
  the `collect` step instead. This means a scan *finding* vulnerabilities won't fail
  the workflow by itself; check the summary table and uploaded SARIF/artifacts for
  actual results.
