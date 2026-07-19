# Multi-Language Build, Scan & Deploy — GitHub Actions

One reusable workflow. Pick a platform + version, point it at any external
repo, and it clones that repo, builds it natively, runs three vulnerability
scanners, builds the Docker image using **that repo's own existing
Dockerfile**, scans the image, and pushes it to Docker Hub.

## Where this lives vs. what it builds

This workflow file lives in **one repo** (a "CI tools" repo — could be brand
new, doesn't need any code of its own). The `repo_url` + `branch` inputs
tell it which **other** repo to actually clone and build each time you run
it — that target repo can be anything: a different repo in your org, a
public repo elsewhere on GitHub, or hosted on GitLab/Bitbucket (any `git`
URL works, not just GitHub, since it clones with a plain `git clone` rather
than `actions/checkout`).

## Design assumptions (confirmed with you before building this)

- **The source repo already has a Dockerfile.** This workflow does not
  generate one — it fails fast with a clear error if the Dockerfile isn't
  found at `dockerfile_path` (default: `Dockerfile` at the repo root).
- **SonarQube is self-hosted** (e.g. running as a Docker container on your
  own infrastructure) — the workflow points `sonar-scanner` at
  `SONAR_HOST_URL`/`SONAR_TOKEN` rather than SonarCloud.
- **Trivy + OWASP Dependency-Check** round out the scanning, per your
  answers. All three scanners (Trivy fs, Dependency-Check, SonarQube) and
  the final Trivy image scan are **non-blocking by default** — findings get
  reported (Security tab, artifact, or your Sonar server) but don't stop
  the pipeline. See "Making a scan blocking" below if you want that to
  change for any of them.

## How to run it

1. **Actions tab -> "Multi-Language Build, Scan & Deploy" -> Run workflow.**
2. Fill in:
   - **platform**: `java` / `dotnet` / `python` / `nodejs` / `go`
   - **version**: format depends on platform — see the input's own
     description on the form (e.g. `17` for Java, `8.0.x` for .NET, `3.12`
     for Python, `20` for Node, `1.22` for Go)
   - **repo_url**: e.g. `https://github.com/yourorg/yourapp.git`
   - **branch**: e.g. `main`
   - **dockerfile_path**: only change this if the Dockerfile isn't at the
     repo root
   - **image_name**: your Docker Hub repo, e.g. `yourorg/yourapp`
   - **image_tag**: leave blank to auto-use the short git commit SHA
   - **sonar_project_key**: must already exist as a project on your
     SonarQube server
3. Run. Watch the job's step-by-step log, or wait for it to finish and
   check the **Summary** tab for a quick recap + where each report landed.

## Required GitHub secrets

Settings -> Secrets and variables -> Actions -> New repository secret
(or organization-level, if this tool workflow is shared across teams):

| Secret | Used for |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Account Settings -> Security -> New Access Token — not your password) |
| `SONAR_HOST_URL` | URL of your self-hosted SonarQube server, e.g. `https://sonar.yourcompany.com` |
| `SONAR_TOKEN` | SonarQube user/project token (My Account -> Security -> Generate Token on your Sonar server) |
| `SOURCE_REPO_TOKEN` | *Optional* — only needed if `repo_url` points at a **private** repo. A GitHub PAT (or equivalent for other git hosts) with read access. |
| `NVD_API_KEY` | *Optional but recommended* — OWASP Dependency-Check hits the National Vulnerability Database, which rate-limits/blocks unauthenticated requests. Get a free key at https://nvd.nist.gov/developers/request-an-api-key. Without it, Dependency-Check may intermittently fail to update its database. |

## Important: network access for self-hosted SonarQube

GitHub-hosted runners (`ubuntu-latest`) need to be able to reach
`SONAR_HOST_URL` over the network. If your SonarQube server is inside a
private network/VPN/corporate firewall, GitHub's hosted runners **cannot
reach it** — you'll need either:
- A [self-hosted GitHub Actions runner](https://docs.github.com/en/actions/hosting-your-own-runners) with network access to your SonarQube server, or
- Expose SonarQube through a properly secured HTTPS endpoint reachable from the internet.

## Making a scan blocking (fail the pipeline on findings)

By default, all three scanners report findings without stopping the run —
this matches the pattern where you review results as they come in, and
tighten enforcement once you've established a baseline. To make one strict:

- **Trivy** (either scan): change `exit-code: '0'` to `exit-code: '1'` in
  that step. It'll then fail the job if any CRITICAL/HIGH vulnerability is found.
- **OWASP Dependency-Check**: add `--failOnCVSS <score>` (e.g. `7`) to the
  `NVD_ARGS` line, and remove the trailing `|| echo ...` fallback so a
  non-zero exit actually fails the step.
- **SonarQube**: remove `continue-on-error: true` from that step, and
  configure a Quality Gate on your SonarQube server (the scan action fails
  automatically if the Quality Gate fails, once you're not swallowing
  errors with `continue-on-error`).

## Adjusting per-platform build assumptions

The native build step makes a few reasonable defaults, documented inline
in the workflow file — adjust if your repos differ:

- **Java**: auto-detects Maven (`pom.xml`) vs Gradle (`build.gradle`/`.kts`)
  at the repo root; runs `mvn -B clean package` or `./gradlew build`.
- **.NET**: `dotnet restore && dotnet build --configuration Release` —
  assumes a single project/solution discoverable from the repo root.
- **Python**: installs from `requirements.txt` if present, else
  `pyproject.toml` via `pip install .`; no build step beyond that (Python
  doesn't typically need one before Docker).
- **Node.js**: `npm ci` (or `npm install` if no lockfile) then
  `npm run build --if-present` (skips cleanly if there's no `build` script).
- **Go**: `go build ./...`.

If a given repo doesn't fit these assumptions (e.g. a monorepo with the
app in a subdirectory, or a non-standard Java build layout), you'll likely
need a small per-repo tweak — happy to help adjust the workflow for a
specific case once you hit one.

## What's NOT included (flag if you want these added)

- Automated triggers (push/PR) — this is `workflow_dispatch`-only
  (manual), matching "I push repo url and branch so it can clone and
  build." Can add a `push`/`pull_request` trigger later if you want CI to
  run automatically on the *tool* repo itself, though that's a slightly
  different use case (building a fixed repo on every commit, vs. building
  an arbitrary repo on demand).
- Multi-arch image builds (linux/amd64 only) — can add `docker buildx` with
  `--platform linux/amd64,linux/arm64` if you need ARM images too.
- Caching (Maven `.m2`, npm, pip, Go modules) — every run currently starts
  cold. Worth adding once you're running this often enough that build time
  matters; each `setup-*` action supports a `cache:` option for exactly this.
