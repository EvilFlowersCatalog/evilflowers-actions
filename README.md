# evilflowers-actions

Shared GitHub Actions for the EvilFlowers / ELVIRA services: build the image, deploy it to the
environment of the pushed branch, and report every deploy to LGTM.

Design and rationale: knowledge vault `Proposals/CI-Deploy-Unification.md`.
Runners: `Cookbooks/CI-Runner.md`. Service contract: `Deploy-a-Service`.

## The rule

The same in every repository. No per-repository switches.

| Ref | Image tags | GitHub environment | Namespace | `instance` |
|---|---|---|---|---|
| `develop` | `:develop`, `:sha-<short>` | `development` | `evilflowers-dev` | `dev` |
| `master` or `main` | `:master` / `:main`, `:sha-<short>` | `production` | none until prod runs in k3s, then `evilflowers-prod` | `prod` |
| tag `X.Y.Z` / `vX.Y.Z` | `:X.Y.Z`, `:sha-<short>` | — | — | — |
| other branches | `:sha-<short>` | — | — | — |
| pull request | nothing pushed (build and smoke test only) | — | — | — |

- A push to `develop` restarts, in `evilflowers-dev`, every Deployment labelled
  `elvira.stuba.sk/image=<image-label>,app.kubernetes.io/instance=dev`.
- If no Deployment matches, the deploy fails.
- A push to `master`/`main` builds and pushes the image. The deploy then ends with a notice:
  production is not on k3s yet.
- The branch → namespace table exists in exactly one place, the `resolve` job of
  [`deploy.yml`](.github/workflows/deploy.yml).

## Adopt it in a service

The whole build-and-deploy part of a service repository:

```yaml
name: image

on:
  push:
    branches: [develop, master, main]
    tags: ["*.*.*", "v*.*.*"]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

# A newer push supersedes a running build + deploy: the deploy checks the digest it built,
# so two overlapping runs would fail each other.
concurrency:
  group: image-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' || github.ref == 'refs/heads/develop' }}

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "the service's own lint and tests (uv / poetry / go)"

  image:
    needs: test
    uses: EvilFlowersCatalog/evilflowers-actions/.github/workflows/image.yml@v1
    permissions: { contents: read, packages: write, id-token: write, attestations: write }
    with:
      platforms: linux/amd64

  deploy:
    needs: image
    if: github.event_name == 'push'
    uses: EvilFlowersCatalog/evilflowers-actions/.github/workflows/deploy.yml@v1
    with:
      digest: ${{ needs.image.outputs.digest }}
```

Before the first push:

1. Label the Deployments and their pod templates with `elvira.stuba.sk/image=<lowercase repository name>`
   and `app.kubernetes.io/instance=<dev|prod>`. Use knowledge `roles/evilflowers_k8s`, then apply
   `playbooks/evilflowers-k8s.yml`.
2. Pin the dev instance to `:develop` with `imagePullPolicy: Always`. Otherwise the restart pulls an
   unchanged image and the digest check fails.
3. Delete the old deploy job and any `DEPLOY_DEV` / `PRODUCTION_DEPLOY_ENABLED` variable.

### `image.yml` inputs

| Input | Default | Use |
|---|---|---|
| `platforms` | `linux/amd64` | `linux/amd64,linux/arm64` for catalog, lcpencrypt and readium. QEMU is set up when needed. |
| `build-args` | `""` | One `KEY=value` per line. `IMAGE_TAG=<ref>@<sha>` is always added. |
| `cache` | `gha` | `registry` stores `:buildcache` next to the image, the better choice for multi-platform builds. |
| `context`, `file` | `.`, `<context>/Dockerfile` | |
| `prepare` | `""` | Shell command run after checkout, before the build. The catalog uses it for `poetry export … > requirements.txt`. |
| `smoke-test` | `""` | Shell command run before anything is pushed. It runs against an image built for the first platform and loaded as `$SMOKE_IMAGE`. |
| `artifact`, `artifact-path` | `""`, `.` | An artifact of this run, downloaded over the checkout before the build. A kit consumer passes the `pyproject.toml` + `uv.lock` that `resolve-worker` locked. |
| `worker-revision`, `worker-ref` | `""` | Labels `sk.stuba.elvira.evilflowers-worker.revision` / `.ref`, plus the build arg `EVILFLOWERS_WORKER_REVISION`. Set only when given. |

Outputs: `digest` (empty on a PR), `image` (`ghcr.io/<owner>/<repo>`), `tags`. Every pushed image
gets provenance, an SBOM and a GitHub build-provenance attestation.

The OCR service's smoke test as an example:

```yaml
    with:
      smoke-test: >-
        docker run --rm --read-only --network none --user 65534:65534 --tmpfs /tmp
        "$SMOKE_IMAGE" python -m evilflowers_ocr_worker selftest -l slk ces eng rus
```

### `deploy.yml` inputs

| Input | Default | Use |
|---|---|---|
| `digest` | required | `needs.image.outputs.digest` |
| `image-label` | lowercase repository name | The catalog passes `evilflowers-catalog`. |
| `timeout` | `900s` | `rollout status` timeout, per Deployment. |
| `actions-ref` | `v1` | Ref of this repository to load `scripts/otlp-deploy.sh` from. Keep it equal to the `@ref` you call. Set it only while testing a branch or SHA. |
| `reason` | `""` | Sent as `evilflowers.deploy.trigger`. Pass the caller's dispatch input `reason`. If empty, it is `push`, or `manual` for a dispatch. |
| `worker-revision`, `worker-ref` | `""` | Sent as `evilflowers.worker.revision` / `.ref`, and only when set. |

What the `rollout` job does on the `elvira-k3s` runner:

1. Installs a checksum-pinned kubectl.
2. Restarts every Deployment matching the selector, then waits for each one.
3. Fails unless every running container and init container uses `@<digest>`.
4. Reports the deploy to LGTM, succeeded or failed. A run cancelled by a newer push reports
   nothing.
5. Writes a step summary.

The job runs only for repositories owned by `EvilFlowersCatalog`, one deploy per repository and
namespace at a time.

The digest check is strict. A pod matched by the selector fails it if any of its containers
(a sidecar, for example) runs a different image.

## Services built on evilflowers-worker

Rule set: EvilFlowersCatalog/evilflowers-worker#13. Diagram:
[`docs/diagrams/sequence-worker-nightly.puml`](docs/diagrams/sequence-worker-nightly.puml).

The kit is resolved at build time, never committed. The source in `pyproject.toml` stays on
`branch = "master"`:

```toml
[tool.uv.sources]
evilflowers-worker = { git = "https://github.com/EvilFlowersCatalog/evilflowers-worker", branch = "master" }
```

| Service ref | Kit ref the build locks |
|---|---|
| `develop`, PRs, other branches | `master` head |
| `main` / `master`, tags | newest `vX.Y.Z`. If no tag exists, the build fails. |
| repository variable `KIT_REF` set | that ref: a hold on a known-good tag, or a test of a kit branch. It also pauses the nightly. |

Cut a kit tag before you merge a service's `develop` → `main`. Otherwise the `main` build locks an
older kit than the one `develop` was tested against.

### The image workflow of a kit consumer

```yaml
on:
  push:
    branches: [develop, master, main]
    tags: ["*.*.*", "v*.*.*"]
  pull_request:
  workflow_dispatch:
    inputs:
      reason:
        description: push | nightly | manual (worker-nightly.yml sends nightly)
        type: string
        default: manual

jobs:
  test:
    runs-on: ubuntu-24.04
    outputs:
      worker-revision: ${{ steps.worker.outputs.revision }}
      worker-ref: ${{ steps.worker.outputs.ref }}
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@v10
      - id: worker
        uses: EvilFlowersCatalog/evilflowers-actions/.github/actions/resolve-worker@v1
        with:
          kit-ref: ${{ vars.KIT_REF }}
      - uses: actions/upload-artifact@v7
        with:
          name: uv-lock
          path: |
            pyproject.toml
            uv.lock
      - run: uv sync --locked && uv run pytest

  image:
    needs: test
    uses: EvilFlowersCatalog/evilflowers-actions/.github/workflows/image.yml@v1
    permissions: { contents: read, packages: write, id-token: write, attestations: write }
    with:
      artifact: uv-lock
      worker-revision: ${{ needs.test.outputs.worker-revision }}
      worker-ref: ${{ needs.test.outputs.worker-ref }}

  deploy:
    needs: [test, image]
    if: github.event_name != 'pull_request'
    uses: EvilFlowersCatalog/evilflowers-actions/.github/workflows/deploy.yml@v1
    with:
      digest: ${{ needs.image.outputs.digest }}
      reason: ${{ inputs.reason }}
      worker-revision: ${{ needs.test.outputs.worker-revision }}
      worker-ref: ${{ needs.test.outputs.worker-ref }}

  report-nightly-failure:
    needs: [test, image, deploy]
    if: failure() && inputs.reason == 'nightly'
    runs-on: ubuntu-24.04
    permissions: { issues: write }
    steps:
      - uses: EvilFlowersCatalog/evilflowers-actions/.github/actions/report-nightly-failure@v1
        with:
          revision: ${{ needs.test.outputs.worker-revision }}
          results: test=${{ needs.test.result }} image=${{ needs.image.result }} deploy=${{ needs.deploy.result }}
```

The deploy condition is `github.event_name != 'pull_request'`, not `== 'push'`, because the nightly
arrives as a `workflow_dispatch`. `deploy.yml` still deploys only `develop`, and later `master`/`main`.

### The nightly

```yaml
name: nightly

on:
  schedule: [{ cron: "17 2 * * *" }]
  workflow_dispatch:
    inputs:
      force: { type: boolean, default: false }

permissions: {}

jobs:
  nightly:
    uses: EvilFlowersCatalog/evilflowers-actions/.github/workflows/worker-nightly.yml@v1
    permissions: { actions: write, packages: read }
    with:
      workflow: image.yml
      force: ${{ inputs.force || false }}
```

`schedule` fires only from the default branch, so the nightly runs once this file is on `main`/`master`.
On each run it:

1. Reads the kit's `master` head with `git ls-remote`.
2. Reads the label `sk.stuba.elvira.evilflowers-worker.revision` of `ghcr.io/<repository>:develop`.
3. If the two differ, the label is missing, or `force` is set, it dispatches `workflow` on `develop`
   with `reason=nightly`.
4. Writes a step summary.

A hold (`KIT_REF`) makes it do nothing, unless `force` is set. It never commits and never builds
`main`/`master`.

### `resolve-worker`

| Input | Default | Use |
|---|---|---|
| `kit-ref` | `""` | Pass `${{ vars.KIT_REF }}`. A composite action cannot read `vars` itself. |
| `working-directory` | `.` | The directory that holds `pyproject.toml` and `uv.lock`. |

Outputs: `ref` (`master`, `vX.Y.Z`, or a branch) and `revision` (the 40-hex commit `uv.lock` pins).

- It needs `uv` on PATH.
- When the ref is not `master`, it rewrites the source to `tag = "<ref>"` (or `branch = "<ref>"`).
- It fails if the source is not on `branch = "master"`.

### `report-nightly-failure`

Inputs: `revision`, `results`, `service` (default: the repository name), `token` (default:
`github.token`).

It opens `nightly: evilflowers-worker <sha> breaks <service>`. While that issue is open, every
later failing night comments on it instead of opening a new one.

## Deployments in LGTM

`scripts/otlp-deploy.sh` sends OTLP/HTTP JSON with `curl` to `$ELVIRA_OTLP_HTTP_ENDPOINT`, the
node's Alloy (`http://$HOST_IP:4318`).

- The runner pods get the variable from knowledge `roles/github_runner`.
- It sends no token or secret, and nothing leaves the cluster.
- If the variable is missing or Alloy is unreachable, the script logs a warning. It never fails
  the deploy.

What gets sent:

- Emitter: `service.name=github-actions`, `service.namespace=ci`. It does not pose as the deployed
  service.
- Loki: one log record per restarted Deployment, with `event.name=deployment`,
  `k8s.deployment.name`, `deployment.status` (`succeeded` / `failed`), and the `vcs.*`,
  `cicd.pipeline.*`, `oci.manifest.digest` and `container.image.name` attributes.
- On the records and on the span: `evilflowers.deploy.trigger` (`push` | `nightly` | `manual`). For
  services built on the kit, also `evilflowers.worker.revision` and `evilflowers.worker.ref`.
- Tempo: one span `deploy` per job, from the restart to the end of the digest check. Its status is
  ERROR on failure.

Queries:

```text
Loki   {service_name="github-actions"} | event_name="deployment" | k8s_deployment_name="text"
Tempo  { resource.service.name = "github-actions" && name = "deploy" && status = error }
Mimir  kube_replicaset_created{namespace="evilflowers-dev"}
         * on (namespace, replicaset) group_left (owner_name) kube_replicaset_owner{owner_kind="Deployment"}
```

Mimir sees every rollout, including Ansible and manual ones. A rollout there with no CI event next
to it was not made by CI.

Try the payloads locally; this prints them and sends nothing:

```bash
TARGET_ENVIRONMENT=development TARGET_NAMESPACE=evilflowers-dev DEPLOY_DEPLOYMENTS="web worker" \
  scripts/otlp-deploy.sh --print succeeded | python3 -m json.tool --json-lines
```

## Releasing

Callers pin `@v1`, a moving major tag. A release is an immutable `v1.x.y` plus a move of `v1`:

```bash
git tag -a v1.2.0 -m "v1.2.0"
git tag -f v1 v1.2.0
git push origin v1.2.0
git push -f origin v1
```

What `v1` promises:

- Inputs, outputs and the telemetry attribute names stay backward compatible. Renaming or removing
  one needs `v2`.
- `deploy.yml` downloads `scripts/otlp-deploy.sh` at `actions-ref` (default `v1`) from
  `raw.githubusercontent.com`. Two consequences:
  - The repository must stay **public**.
  - The script's arguments and variables are part of the `v1` contract.

## Repository and organization settings

- **Runner group `elvira-k3s`:**
  - Set Repository access to **All repositories**, so a new service needs no click. The only thing
    a job can do in the cluster is the `arc-deployer` Role, limited to
    `github_runner_deploy_namespaces`.
  - **Open: "Allow public repositories".** The CI-Runner cookbook says to leave it off, so that a
    fork PR can never run in the cluster. But the service repositories are public and already
    deploy on `elvira-k3s`, so the live setting has to be checked. If it is on, require approval
    for workflows from fork PRs (Settings → Actions → General). A fork PR can add its own
    `runs-on: elvira-k3s` job, and the owner check in `deploy.yml` does not cover that case.
- **This repository, if it ever becomes private:** set Settings → Actions → General → Access to
  "Accessible from repositories in the organization". Otherwise no caller can use it, and the
  script download in `deploy.yml` stops working.
- **GitHub environment `production`:** add required reviewers at the k3s cutover.

## At the prod cutover

1. In `deploy.yml` → `resolve`, set `ns=evilflowers-prod` on the `master|main` row.
2. Add `evilflowers-prod` to `github_runner_deploy_namespaces` (knowledge `roles/github_runner`).
3. Release `v1.y`. No service repository changes.

## Development

`self-test.yml` runs on every push. It covers:

- actionlint, which also runs shellcheck on every `run:` block;
- shellcheck on `scripts/`, `tests/` and the scripts of the composite actions (actionlint does not
  read `.github/actions/`);
- a contract test of `otlp-deploy.sh`'s payloads;
- `tests/resolve-worker.sh` against the real kit: a develop build, a main build, a hold, and a
  pinned source. Then the `resolve-worker` action itself, run as a caller would run it.

To run the same checks locally:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color
docker run --rm -v "$PWD:/repo" -w /repo koalaman/shellcheck:stable scripts/*.sh tests/*.sh .github/actions/*/*.sh
tests/resolve-worker.sh   # needs git, uv and network
```

`.github/actionlint.yaml` declares the self-hosted label `elvira-k3s`.
