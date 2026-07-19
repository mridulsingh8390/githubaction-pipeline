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

## Skipping SonarQube entirely

Set **run_sonarqube** to `false` on the Run workflow form and the entire
`sonarqube-scan` job is skipped — including its SonarQube service
container, which never even starts. This matters because GitHub Actions
service containers always start for a job that runs, regardless of any
input inside that job; the only way to truly skip starting SonarQube (not
just skip a step that uses it) is to skip the whole job it lives in, via a
job-level `if:`. That's why SonarQube lives in its own `sonarqube-scan`
job rather than as a step inside `build-scan-deploy`.

Bonus of this split: the two jobs run **in parallel**, not one after the
other — so having SonarQube enabled doesn't add its ~1-2 minute startup
cost on top of the build job's own time; they overlap. `sonarqube_project_key`
is ignored (and can be left blank) when `run_sonarqube` is `false`.

## Design assumptions (confirmed with you before building this)

- **The source repo already has a Dockerfile.** This workflow does not
  generate one — it fails fast with a clear error if the Dockerfile isn't
  found at `dockerfile_path` (default: `Dockerfile` at the repo root).
- **SonarQube runs ephemerally, inside the pipeline job itself** — no
  persistent server, no portal to log into. It starts as a GitHub Actions
  **service container** at the beginning of the job, gets scanned against,
  prints its results (Quality Gate pass/fail + key metrics) directly into
  the job log and the run's **Summary** tab, and is torn down automatically
  when the job ends. Nothing to provision ahead of time beyond the
  `sonar_project_key` input (which just needs to be a name — it's created
  fresh on the ephemeral server every run, not looked up on some
  pre-existing instance).
- **Trivy + OWASP Dependency-Check** round out the scanning, per your
  answers. Trivy's two scans and Dependency-Check are **non-blocking**
  (findings reported, pipeline continues); the SonarQube step currently is
  too (`continue-on-error: true`) even though it now has a real, reliable
  pass/fail signal via the Quality Gate — see "Making a scan blocking" below.

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
   - **sonar_project_key**: any name you like — this becomes the project
     name on the ephemeral SonarQube instance for this one run only
3. Run. Watch the job's step-by-step log — the **"Print SonarQube results"**
   step prints the Quality Gate result and key metrics (bugs,
   vulnerabilities, code smells, coverage, lines of code) directly, no
   clicking into anything external. Or check the **Summary** tab after the
   run finishes for the same information plus the overall recap.

## Required GitHub secrets

Settings -> Secrets and variables -> Actions -> New repository secret
(or organization-level, if this tool workflow is shared across teams):

| Secret | Used for |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Account Settings -> Security -> New Access Token — not your password) |
| `SOURCE_REPO_TOKEN` | *Optional* — only needed if `repo_url` points at a **private** repo. A GitHub PAT (or equivalent for other git hosts) with read access. |
| `NVD_API_KEY` | *Optional but recommended* — OWASP Dependency-Check hits the National Vulnerability Database, which rate-limits/blocks unauthenticated requests. Get a free key at https://nvd.nist.gov/developers/request-an-api-key. Without it, Dependency-Check may intermittently fail to update its database. |

Notice there's **no `SONAR_HOST_URL`/`SONAR_TOKEN` secret anymore** — the
workflow generates its own token against the ephemeral server at
`http://localhost:9000` every run and throws it away when the job ends.

## Cost of the "no portal" approach: added time per run (if enabled)

Standing up SonarQube fresh every run (even the lightweight Community
Edition with its embedded H2 database) costs real time — expect roughly
1-2 extra minutes for the service container to report ready, on top of the
scan itself. Since `sonarqube-scan` runs as its own job in parallel with
`build-scan-deploy` (see "Skipping SonarQube entirely" above), this cost
is mostly hidden behind the build job's own runtime rather than added on
top of it sequentially — but it's still real machine time being spent if
you don't need the scan that run, which is exactly what `run_sonarqube:
false` avoids paying at all.

Also worth knowing: because nothing persists between runs, you lose
SonarQube's usual "trend over time" view (new issues vs. existing,
historical charts, etc.) — every run is a clean-slate analysis of that one
commit, not a comparison against a prior baseline. If you later want that
history back, the fix is straightforward: point `SONAR_HOST_URL`/
`SONAR_TOKEN` at a real persistent server instead of the ephemeral service
container (I can wire that up as an alternate/toggle-able mode if useful).

## Making a scan blocking (fail the pipeline on findings)

By default, all three scanners report findings without stopping the run —
this matches the pattern where you review results as they come in, and
tighten enforcement once you've established a baseline. To make one strict:

- **Trivy** (either scan): change `exit-code: '0'` to `exit-code: '1'` in
  that step. It'll then fail the job if any CRITICAL/HIGH vulnerability is found.
- **OWASP Dependency-Check**: add `--failOnCVSS <score>` (e.g. `7`) to the
  `NVD_ARGS` line, and remove the trailing `|| echo ...` fallback so a
  non-zero exit actually fails the step.
- **SonarQube**: already computes a real Quality Gate result every run
  (via `-Dsonar.qualitygate.wait=true`) — delete the `continue-on-error:
  true` line from the "SonarQube Scan" step and a failed gate will fail
  the `sonarqube-scan` job itself. Note this job runs independently of
  `build-scan-deploy` (no `needs:` between them, by design — see
  "Skipping SonarQube entirely"), so a failed Sonar quality gate will
  **not** stop the Docker build/push on its own; you'd need to add
  `needs: [sonarqube-scan]` to `build-scan-deploy` if you want the push to
  wait on and depend on Sonar's result (trade-off: that also removes the
  parallel-speed benefit, since the build would then wait for Sonar to
  finish first). Happy to wire that up if you want it.
  The default Quality Gate ("Sonar way") is reasonable out of the box;
  since the project is recreated fresh every run there's no custom gate
  configuration to carry over between runs — if you want a stricter/looser
  gate, that'd need to be set via the API right after project creation
  (happy to add that step if you want a specific threshold).

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
