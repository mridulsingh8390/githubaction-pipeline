# Multi-Domain AKS Deployment Pipeline

Deploys 4 independent microservices to AKS, each behind its own domain via
**AGIC** (Application Gateway Ingress Controller), each packaged with **one
shared, reusable Helm chart**, each deployed as its **own independent Helm
release**. Redeploying one service with a new tag never touches the other
three.

| Domain (prod)         | DockerHub image              | Helm release name    |
|------------------------|-------------------------------|-----------------------|
| `login.example.com`   | `mridul08/discovery-service`  | `discovery-service`  |
| `billing.example.com` | `mridul08/car-service`        | `car-service`        |
| `api.example.com`     | `mridul08/api-gateway`        | `api-gateway`         |
| `app.example.com`     | `mridul08/myhttpdimage101`    | `myhttpdimage101`    |

Staging/dev reuse the same names with subdomains (`login.staging.example.com`,
`login.dev.example.com`, etc.) — see `helm-chart/values-<service>-staging.yaml`
and `helm-chart/values-<service>-dev.yaml`.

## How it works

```
lint chart → resolve image ref → scan image (Trivy) → helm upgrade --atomic
   → verify rollout → smoke test (rollback if it fails) → notify → summary
```

Two workflows, both self-contained (no reusable `workflow_call`, matching
this repo's existing flat-per-workflow style):

- **`deploy-single-service.yml`** — day-2 pipeline. Redeploys ONE service in
  ONE environment with a new tag.
- **`deploy-all-services.yml`** — day-0 pipeline. Deploys all 4 into ONE
  environment (initial setup, or a deliberate bulk refresh). Loops over all
  4 in one job; one service failing doesn't stop the other 3 from being
  attempted — failures are collected and the job fails at the end with a
  clear list of which service(s) had a problem.

## Prerequisites

### 1. Auth — nothing new to configure

This reuses the **same OIDC secrets already used by every other AKS workflow
in this repo** (`deploy-multicloud-helm.yml`, `upgrade-aks.yml`,
`aks-cluster-info.yml`, `azure-import.yml`):

| Secret | Already used by |
|---|---|
| `AZURE_CLIENT_ID` | all of the above |
| `AZURE_TENANT_ID` | all of the above |
| `AZURE_SUBSCRIPTION_ID` | all of the above |

If those are already set at the repo/org level (they must be, for the
existing pipelines to work), **there is nothing to add**. Same federated
credential, same App Registration, same trust — this pipeline just uses it
too.

Like `deploy-multicloud-helm.yml`, `aksResourceGroup` and `aksClusterName`
are typed in at run time as workflow inputs, not stored as GitHub variables
— consistent with how this repo already does it, and one less thing to
configure or accidentally point at the wrong cluster.

### 2. Optional secrets (skip entirely if not needed)

| Secret | Needed for |
|---|---|
| `SLACK_WEBHOOK_URL` | Success/failure notifications |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | Only if `mridul08/*` repos are private (Trivy needs to auth to scan them) |

### 3. GitHub Environments (approval gate for prod)

**Settings → Environments**, create `dev`, `staging`, `prod`. Add required
reviewers on `prod` only — same pattern as `multicloud-deploy-prod` in
`Multi-Cloud-Helm-Deployment`. Delete/skip this if you want unattended
deploys everywhere.

### 4. Namespace per environment

Use one namespace per environment on your existing cluster, e.g.
`myapp-dev`, `myapp-staging`, `myapp-prod` — typed as the `namespace` input
each run. `--create-namespace` handles creation automatically.

### 5. Private images (skip if public)

```bash
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<dockerhub-user> \
  --docker-password=<dockerhub-token> \
  --namespace myapp-dev        # repeat per namespace
```

Then in each `helm-chart/values-<service>.yaml`:
```yaml
imagePullSecrets:
  - name: dockerhub-secret
```

## Running the pipeline

### First-time / bulk setup

**Actions → Deploy All Services (AKS Initial Setup) → Run workflow**
1. `environment` (start with `dev`)
2. `aksResourceGroup`, `aksClusterName`, `namespace`
3. The 4 tag inputs (or leave `latest` — blocked automatically if
   `environment = prod`)
4. Run — repeat for `staging`, then `prod`

### Day-2 (redeploy one service)

**Actions → Deploy Single Service (AKS) → Run workflow**
1. `environment`, `service`, `imageTag`
2. `aksResourceGroup`, `aksClusterName`, `namespace`
3. Run

## Safety behavior

- **`imageTag = latest` is rejected in `prod`** (dev/staging can still use
  it, unlike `deploy-multicloud-helm.yml` which blocks it everywhere —
  loosen or tighten this per your policy).
- **Trivy scans the exact `repository:tag` being deployed** for
  CRITICAL/HIGH CVEs before `helm upgrade` runs. A vulnerable image blocks
  the deploy entirely.
- **`helm upgrade --atomic --cleanup-on-fail`** auto-rolls-back to the last
  good revision if the deploy fails at the Kubernetes level (bad manifest,
  pod never Ready, timeout).
- **Post-deploy smoke test** catches what `--atomic` can't — pod is Ready
  but the app itself errors — and triggers an explicit `helm rollback` if
  it fails.
- **`concurrency` group** is scoped to environment + service (or
  environment alone for deploy-all), so two dispatches targeting the same
  release can't race and corrupt Helm's release history.
- Each service is its own Helm release — a bad `api-gateway` deploy rolling
  back never touches `discovery-service`, `car-service`,
  `myhttpdimage101`, or the same service in other environments.

## Enterprise-grade checklist

| # | Item | Status | Where |
|---|------|--------|-------|
| 1 | Health probes for zero-downtime deploys | ✅ | `helm-chart/values.yaml` + `templates/deployment.yaml` |
| 2 | Auto-rollback on failure | ✅ | `--atomic --cleanup-on-fail` + smoke-test rollback |
| 3 | Monitoring (Prometheus/Grafana) | ✅ opt-in | `monitoring.enabled: true` in `helm-chart/values-<service>-<env>.yaml`; `templates/servicemonitor.yaml` if the Prometheus Operator CRD is present |
| 4 | Slack/Teams notifications | ✅ opt-in | Set `SLACK_WEBHOOK_URL` |
| 5 | Deployment approval gates for prod | ✅ | GitHub Environments, required reviewers on `prod` |
| 6 | Image scanning before deployment | ✅ | Trivy, blocks on CRITICAL/HIGH |
| 7 | Network policies | ✅ opt-in | `networkPolicy.enabled: true` in `helm-chart/values-<service>-<env>.yaml`; `templates/networkpolicy.yaml` |
| 8 | Resource limits | ✅ | `resources.requests`/`resources.limits`, tighter in dev, larger in prod |

## Known limitations

- **`Verify rollout` and the smoke test assume the standard
  `app.kubernetes.io/instance` label and that the app answers on `/` at
  `service.targetPort`.** If a service uses a different health path, tell
  me and I'll adjust that service's step.
- **This pipeline doesn't build or push images** — it assumes
  `repository:tag` already exists on DockerHub, same assumption as
  `deploy-multicloud-helm.yml`.
- **Monitoring/NetworkPolicy are off by default.** Confirm AGIC's actual
  namespace (`kubectl get pods -n kube-system -l app=ingress-appgw`) before
  turning on `networkPolicy.enabled` — enable in `dev` first.
