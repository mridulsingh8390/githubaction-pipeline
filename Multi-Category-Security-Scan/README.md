# Multi-Category Security Scan Pipeline

A single GitHub Actions workflow (`multi-category-scan-pipeline.yml`) that runs
security scans across four categories — **Docker**, **Host/Network**, **Cloud**, and
**Codebase** — selected at trigger time via `workflow_dispatch`. Every category except
`cloud` is entirely secret-free.

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
| **`cloud`** | ScoutSuite + Prowler (account-wide posture audit) + Trivy (image CVE scan) | **Yes** — cloud auth is unavoidable |
| **`codebase`** | Gitleaks (secrets scan), Semgrep (SAST) | No (Gitleaks only uses the auto-provided `GITHUB_TOKEN`) |

### Cloud category — single-shot combined scan

Selecting `cloud` with default settings runs **all three** of the following in one job:

1. **ScoutSuite** — cloud account posture/configuration audit
2. **Prowler** — a second posture/compliance auditor, overlapping but not identical
   to ScoutSuite's checks (useful as a cross-check, different rule coverage)
3. **Trivy** — CVE/severity scan of container image(s) in the same account's registry
   (ECR / ACR / Artifact Registry). Two modes:
   - **Single image**: set `cloudImageRef` to scan exactly one image
   - **All images** (default): leave `cloudImageRef` blank and keep
     `cloudScanAllImages = true` — the pipeline auto-discovers every repository in
     the registry and scans **the most recently pushed tag of each one**

   > **Scope note:** only the latest tag per repository is scanned, not every
   > historical tag, to keep runtime bounded. Scanning full tag history across every
   > repo would multiply the job's runtime significantly — ask if you need that and
   > the discovery loop can be changed.

### Excluded tools

Considered and deliberately left out — either they're placeholders for tools that
were never confirmed, or every one of them requires a token/client ID/API key to
function at all:

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
| `cloudAwsRegion` | No | `us-east-1` | Used for ScoutSuite/Prowler/ECR discovery on AWS |
| `runScoutSuite` | No | `true` | Toggle ScoutSuite |
| `runProwler` | No | `true` | Toggle Prowler |
| `cloudRunImageScan` | No | `true` | Toggle the Trivy image scan(s) entirely |
| `cloudImageRef` | No | `""` | Set to scan exactly ONE image. Leave blank for all-image mode |
| `cloudScanAllImages` | No | `true` | Used only when `cloudImageRef` is blank — scans every repo's latest tag |
| `acrRegistryName` | No | `""` | **Required for Azure all-image mode** — ACR name without `.azurecr.io` |
| `gcpArtifactLocation` | No | `""` | **Required for GCP all-image mode** — e.g. `us-central1` |
| `gcpArtifactProject` | No | `""` | **Required for GCP all-image mode** — GCP project ID |
| `gcpArtifactRepository` | No | `""` | **Required for GCP all-image mode** — Artifact Registry repo name |

### Codebase (`scanCategory = codebase`)
| Input | Required | Default | Notes |
|---|---|---|---|
| `runGitleaks` | No | `true` | Secrets scan across full git history |
| `runSemgrep` | No | `true` | SAST using `p/security-audit`, `p/secrets`, `p/owasp-top-ten` rulesets |

## Prerequisites

### Cloud category only

You cannot authenticate to a cloud account without credentials — set whichever of
these apply as repo/org secrets:

| Provider | Secrets |
|---|---|
| AWS | `AWS_SCAN_ROLE_ARN` |
| Azure | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| GCP | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

The same OIDC role/service principal also needs:

- **ScoutSuite/Prowler**: broad read-only permissions across the account (IAM,
  networking, storage, logging, etc. — see each tool's docs for the minimal policy)
- **Registry read/pull** (if `cloudRunImageScan` is enabled):
  - AWS: `AmazonEC2ContainerRegistryReadOnly` (or equivalent ECR pull policy)
  - Azure: `AcrPull` role on the target registry
  - GCP: `Artifact Registry Reader` role
- **GCP Prowler specifically** relies on Application Default Credentials, which
  `google-github-actions/auth` sets up automatically in most configurations — if
  only the Prowler step fails on GCP, check that auth handoff first.

### All other categories

No setup beyond the default `GITHUB_TOKEN` GitHub provides automatically.

## Running the pipeline

**Actions → Multi-Category Security Scan Pipeline → Run workflow**, then:

1. Select `scanCategory`
2. Fill in the required input(s) for that category (`imageRef` for docker,
   `targets` for host/network, registry-discovery fields for cloud all-image mode)
3. Toggle whichever tool checkboxes you want on/off
4. Run — check the workflow summary for the results table

## Artifacts produced

| Category | Artifact(s) |
|---|---|
| `docker` | Trivy SARIF (uploaded to Security tab) |
| `host_network` | `host-network-scan-results` (Nmap output) |
| `cloud` | `scoutsuite-report-<provider>`, `prowler-report-<provider>`, and either a SARIF (single-image mode) or `cloud-all-images-trivy-report-<provider>` (all-image mode) |
| `codebase` | Gitleaks/Semgrep findings surface directly in workflow logs and the Security tab |

## Known limitations

- **ZAP expects a single URL target.** If `targets` contains multiple comma-separated
  hosts/IPs and `runZap` is enabled, only a URL-shaped entry will scan correctly —
  non-URL entries (bare IPs) may cause it to fail or behave unpredictably.
- **All-image discovery scans only the latest tag per repository**, not full tag
  history — see the Cloud category note above.
- **Registry name/region parsing uses simple string splitting** (`cut` on `/` and
  `.`), assuming standard registry URL formats for each provider. Non-standard
  registry naming may break the parsing.
- **Trivy and ZAP steps use `continue-on-error: true`** so a single tool failure
  doesn't block the whole job — status is captured explicitly in the `collect` step
  instead. A scan *finding* vulnerabilities won't fail the workflow by itself; check
  the summary table and uploaded artifacts/SARIF for actual results.
- **ScoutSuite and Prowler check overlapping but not identical things** — treat them
  as complementary, not redundant; don't assume a PASS from one implies a clean bill
  from the other.
