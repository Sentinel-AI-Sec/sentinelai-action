# sentinelai-action

GitHub Actions composite: runs the scanners and graph extraction on the runner, ships a findings + graph-inputs bundle to the SentinelAI backend (D2 model).

**SEC-11** · the runner side of the pipe. Full design notes: [`docs/SEC-11-runner-workflow.md`](docs/SEC-11-runner-workflow.md).

---

## Usage

```yaml
- uses: Sentinel-AI-Sec/sentinelai-action@dev
  with:
    backend-url: ${{ vars.SENTINELAI_BACKEND_URL }}
    machine-token: ${{ secrets.SENTINELAI_MACHINE_TOKEN }}
    project-id: ${{ vars.SENTINELAI_PROJECT_ID }}
    dotnet-project: src/OrderApp/OrderApp.csproj
    infra-dir: infra
```

A complete caller workflow is in [`examples/fixture-pr-scan.yml`](examples/fixture-pr-scan.yml).

Before the backend endpoint exists (SEC-13), add `upload: "false"` — the action builds and verifies the bundle without needing a server.

**Runner prerequisites.** Checkov, Gitleaks, Trivy and OSV-Scanner are installed by the action. The Roslyn pass is not: it needs a .NET SDK matching the project's target framework already on the runner. `ubuntu-latest` ships .NET 8, which is what the fixture targets; anything else needs an `actions/setup-dotnet` step before this one. Without a usable `dotnet`, the code layer is skipped and the rest of the bundle is still produced.

## What it does

```
checkout → secret pre-scan → scanners → graph inputs → metadata
         → source guard → package → POST /v1/scans
```

The bundle it produces:

```
metadata.json               the JSON part of the multipart upload
scanner-versions.json       which tool, which version
findings/
  roslyn.sarif              Security Code Scan, inside `dotnet build`   (code)
  osv.sarif                 OSV-Scanner against packages.lock.json      (dep)
  trivy.sarif               Trivy fs — misconfig + vuln                 (infra/dep)
  checkov_infra.sarif       Checkov against the Terraform directory     (infra)
  checkov_docker.sarif      Checkov against the Dockerfile              (infra)
graph-inputs/
  terraform-graph.dot       the infra spine
  infra/*.tf                spine fallback + role→resource edges
  Dockerfile                the code→infra image-name join
  **/*.csproj               the dep→code seam
  **/packages.lock.json     the dep→code seam
```

**No application source is ever in the bundle.** The collector is a whitelist, and a separate guard re-checks the directory and then the packed tarball. The backend checks again on ingest. See [the core promise](docs/SEC-11-runner-workflow.md#the-core-promise-no-source-leaves-the-runner).

## Inputs

| Input | Required | Default | What it does |
|-------|----------|---------|--------------|
| `backend-url` | yes | — | Backend base URL; the action posts to `<url>/v1/scans` |
| `machine-token` | yes | — | Scoped machine token (`scan:write`) |
| `auth-scheme` | no | `Bearer` | Authorization scheme for the token |
| `project-id` | no | `""` | Recorded in the bundle metadata |
| `checkout` | no | `true` | Set `false` if the caller already checked out |
| `scan-dir` | no | `.` | Directory to scan |
| `infra-dir` | no | `infra` | Terraform directory, relative to `scan-dir` |
| `bundle-dir` | no | `sentinelai-bundle` | Where the bundle is assembled |
| `dotnet-project` | no | `""` | `.csproj` to build for Roslyn; empty skips the code layer |
| `lockfile-path` | no | `""` | Lock file for OSV-Scanner; empty auto-discovers |
| `install-scanners` | no | `true` | Install the pinned toolchain |
| `upload` | no | `true` | `false` builds the bundle only (dry run) |
| `fail-on-upload-error` | no | `true` | Fail the job on a non-2xx response |
| `retain-report` | no | `false` | Opt in to report retention |
| `model-tier-hint` | no | `auto` | `auto` \| `economy` \| `premium` |
| `upload-artifact` | no | `false` | Also attach the bundle to the run, for debugging |

Pinned versions: `gitleaks-version` `8.18.4`, `checkov-version` `3.2.0`, `trivy-version` `0.55.0`, `osv-scanner-version` `2.3.8`, `security-code-scan-version` `5.6.7`.

## Outputs

| Output | What it is |
|--------|------------|
| `scan-job-id` | Job id from the backend; empty on a dry run |
| `poll-url` | Where to poll for the result (SEC-41 uses this) |
| `bundle-path` | Path to the packaged tarball |
| `bundle-sha256` | Digest of what was uploaded |

## Development

```bash
git clone https://github.com/Sentinel-AI-Sec/sentinelai-fixtures.git ../sentinelai-fixtures
FIXTURE_DIR=../sentinelai-fixtures bash test/bundle-shape.test.sh
```

The tests run with no scanners installed on purpose — the degraded path still has to produce a well-formed, source-free bundle. CI runs the same tests plus shellcheck, actionlint, and a full dry run of the action against the fixture.
