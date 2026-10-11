# Possession Is Not Permission — who owns an MCP task?

A Kubernetes lab that measures what happens when one authenticated agent uses **another agent's MCP task ID**,
and where an owner check can be enforced: in the server, in front of an unchanged server, or in a gateway.
Everything runs on a local k3d cluster and can be reproduced from zero with a few commands ([Quickstart](#quickstart)).

Project page: https://graphsentinel.github.io/mcp-task-ownership/

- [The problem](#the-problem)
- [The approach: an owner-sealed task handle](#the-approach-an-owner-sealed-task-handle)
- [What is measured](#what-is-measured)
- [Results](#results)
- [Quickstart](#quickstart)
- [How-to](#how-to)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## The problem

The MCP Tasks extension (`io.modelcontextprotocol/tasks`, specification `2026-07-28`) lets a server answer a long
`tools/call` with a **task ID**. The client then polls with `tasks/get`, can stop the work with `tasks/cancel`, and
can answer a question the task asks mid-way (for example *"continue with the backup?"*) with `tasks/update`.

The specification says both:

> Servers **MUST** perform authentication and authorization checks on each task-related request to ensure that the
> client has permission to access a task.

> A server **MAY** use task IDs as bearer tokens for a server's stored state.

It defines no mechanism for binding a task to the principal that created it. Sessions, the scope the protocol's
designers originally planned to use for this, have since been removed from MCP.

On a **shared** MCP server (several teams or agents on one Kubernetes cluster) this matters when a task ID leaks
through a log, a persisted client store or an agent's context. Team B's agent, fully authenticated, can then try to:

| Operation | Impact on team A |
|---|---|
| `tasks/get` | read the result (confidentiality) |
| `tasks/cancel` | stop a long-running operation (availability) |
| `tasks/update` | answer an approval prompt on A's behalf (integrity) |

This is **not** a vulnerability report: bearer task IDs are permitted. Per-owner isolation is a stricter policy that
some deployments need, and this lab measures how and where it can be enforced.

**Threat model.** The attacker is an *authenticated* caller of the same shared MCP server (another team, another agent)
that obtained a task ID from a log, a persisted client store, an agent's context or a shared ticket. Out of scope:
single-tenant servers and attackers holding the owner's own token.

## The approach: an owner-sealed task handle

MCP already has a rule for an opaque value that a server issues and the client echoes back: `requestState`. If it
influences authorization, servers **MUST** protect its integrity (HMAC or AEAD) and **SHOULD** bind it to the
authenticated principal and a short expiry. The lab applies the same rule to task IDs:

```
client sees:  v1.<base64url(nonce || AEAD(payload))>
payload:      {v, target, upstream task id, owner: {iss, sub, azp}, exp}
```

- The **upstream task ID never reaches the client**; only the sealed handle does.
- On `tasks/get|update|cancel` the handle is opened and its owner is compared with the caller's token
  (`iss`, `sub`, `azp`). A different owner, a tampered handle, an expired handle and an unknown ID all get the
  **same** error (`unknown task`), so a refusal does not reveal that a task exists.
- Any replica holding the key can open a handle. No ownership table is shared between replicas (the server still
  stores tasks; that does not change).

The same handle is enforced in three places:

| Placement | Where the check runs | Server changed? |
|---|---|---|
| **P1** | wrapper around the SDK's task manager, inside the server | yes |
| **P2** | sealing proxy in front of the server ([lab/proxy](lab/proxy)) | no |
| **P-AGW2995-SEAL** | agentgateway (built from the unmerged [PR #2995](https://github.com/agentgateway/agentgateway/pull/2995)) + an ExtMcp processor ([lab/ext-seal](lab/ext-seal)) | no |

## What is measured

Identities come from Keycloak (realm `ai1`): agent A (owner), agent B (another team), agent C (not on the gateway
allow-list). Requests are sent from driver pods inside the cluster ([lab/driver/driver.py](lab/driver/driver.py)).

**Placements**

| Placement | What runs | Owner binding |
|---|---|---|
| P0-OFF | rmcp's official Tasks example handler, unmodified, served over HTTP (shared handler) | none |
| P0-OFF-LIT | the same handler built per request, as a literal reading of the example | — (store lives one request) |
| P0 | lab task server in the style of the rmcp example | none |
| P-AGW | agentgateway v1.6.0 in front of P0, JWT + CEL method policy, 3 replicas | none (method-level only) |
| P-AGW2995 | agentgateway PR #2995 build, same policy (optional) | none |
| P1 | lab task server with the owner wrapper | sealed handle |
| P2 | sealing proxy (3 replicas) in front of an unchanged server | sealed handle |
| P2-NP | P2 + a NetworkPolicy that blocks direct access to the server | sealed handle |
| P-AGW2995-SEAL | agentgateway PR #2995 + ExtMcp sealing processor (optional) | sealed handle |

**Tests**

| Test | Question |
|---|---|
| T0, T0-B | do the owners' own operations still work? |
| PC-anon, PC-agent-c | positive controls: no token / agent outside the allow-list |
| AUD | token without the expected audience |
| **T1** | can B read A's task? |
| **T3a** | can B cancel A's task? |
| **T3b** | can B answer A's `input_required` prompt? |
| T4 | is "not yours" indistinguishable from "does not exist"? |
| **TL** | can B replay A's ID taken from a server or gateway access log? |
| TB | can B bypass the proxy and call the server directly? |
| TR | does a handle still open while proxy replicas are deleted? |
| DRAIN | Kubernetes demo: a node-drain agent and a payments workload (see below) |
| T2a, T2b, R-8 | token revocation / new token for the same identity / key rotation (`FULL=1`) |

Each test is implemented in [lab/driver/driver.py](lab/driver/driver.py) (requests, expected outcome, verdict);
[lab/run-placement.sh](lab/run-placement.sh) shows which tests run against which placement.

## Results

Measured with config `v2.1`, 5 runs per placement; every run gave the same outcome. Where each part comes from:

| Part | Stack | Evidence |
|---|---|---|
| Table rows P0-OFF … P2-NP, items 1–4 and 7 | reproduced from zero on 2026-10-11 from this repository's committed tree in a fresh Ubuntu 26.04 VM with the pinned versions (k3s v1.37.1, Keycloak 26.8.0, Docker 29.1.3): 5 runs, 405 measurements, all checks passed, also after `scripts/lab.sh reinstall` | [evidence/e2e-multipass/20261011T095813Z-ubuntu26.04](evidence/e2e-multipass/20261011T095813Z-ubuntu26.04) |
| The quickstart exactly as written | `git clone` of github.com/graphsentinel/mcp-task-ownership (commit `0f8d50f`) in a fresh Ubuntu 26.04 VM, then `platform.sh install`, `platform.sh cluster-up`, `lab.sh all`, nothing copied from another machine: 5 runs, 405 measurements, all checks passed, the same table | [evidence/e2e-clone/20261011T105621Z-ubuntu26.04](evidence/e2e-clone/20261011T105621Z-ubuntu26.04) |
| Rows P-AGW2995, P-AGW2995-SEAL, item 5 | 5 runs on 2026-10-10 on the earlier stack (k3s v1.31.5, Keycloak 26.7.0; summary and logs included, per-run raw data not); the same outcomes in 1 run on the current stack on 2026-10-11 (`WITH_PR2995=1`) | [evidence/agw-pr2995](evidence/agw-pr2995/README.md), [evidence/e2e-multipass/20261011T053826Z-ubuntu26.04](evidence/e2e-multipass/20261011T053826Z-ubuntu26.04) |
| Item 6 (T2a, T2b, R-8) | 1 run on the current stack on 2026-10-11 (`FULL=1`); an earlier 5-run measurement on k3s v1.31.5 gave the same outcomes (not included) | [evidence/e2e-multipass/20261011T053826Z-ubuntu26.04](evidence/e2e-multipass/20261011T053826Z-ubuntu26.04) |

The same flow with one run per placement also passed on Ubuntu 24.04.5 (Docker 29.1.3 and Python 3.12.3 from its packages;
[evidence/e2e-multipass/20261010T224824Z-ubuntu24.04](evidence/e2e-multipass/20261010T224824Z-ubuntu24.04)).

| Placement | T1 read | T3a cancel | T3b answer | TL replay | T4 | Positive controls |
|---|---|---|---|---|---|---|
| P0-OFF | access | access | n/a | access | distinguishable | no auth layer |
| P0 | access | access | access | access | distinguishable | no auth layer |
| P-AGW | access | access | access | access | distinguishable | refused |
| P-AGW2995 | access | access | access | access | distinguishable | refused |
| **P1** | **refused** | **refused** | **refused** | **refused** | indistinguishable | refused |
| **P2** | **refused** | **refused** | **refused** | **refused** | indistinguishable | refused |
| **P2-NP** | **refused** | — | — | **refused** | — | — |
| **P-AGW2995-SEAL** | **refused** | **refused** | **refused** | **refused** | indistinguishable | refused |

In words:

1. **Without an owner binding, another caller who has the ID can read, cancel and answer the task.** With rmcp's own
   example handler (P0-OFF) B reads and cancels A's task (the example has no tool that asks a question, so answering
   is not applicable); with the example-style server (P0) B also answers A's question. Neither server checks a token,
   so the caller does not even need to be authenticated (PC-anon = access). This is permitted by the specification;
   it is the baseline that a shared deployment has to change.
2. **A gateway that authorizes methods does not authorize tasks.** agentgateway v1.6.0 correctly refuses anonymous
   callers and agents outside its policy, but an allowed agent still reaches another agent's task (P-AGW).
3. **The sealed handle refuses every cross-tenant operation measured.** P1 and P2 refuse all four (read, cancel,
   answer, replay from a log), and the refusal looks the same as for a task that does not exist (T4). P2-NP repeats
   the read and replay tests with the NetworkPolicy in place: both refused.
4. **A proxy needs a NetworkPolicy.** Without one, B can call the server directly (TB = reached); with one the bypass
   is blocked (P2-NP, TB = blocked).
5. **The check can live in the gateway.** PR #2995 (unmerged) adds request hooks for `tasks/*`; with an ExtMcp
   processor that seals and opens handles (`lab/ext-seal`, written for this lab), agentgateway refuses all four
   operations without any change to the server. In those runs,
   all 329 task IDs returned to clients were sealed handles, and both processor replicas opened handles (202 / 81).
6. **Token lifetime is a separate property.** After A's session is revoked in Keycloak, A's access token keeps
   working in P1, P-AGW and P2, which validate JWTs locally; introspection reports it inactive (T2a). With a 60 s token
   it was last accepted at `exp`+56–57 s and refused from `exp`+61–62 s (the validators' clock leeway; requests every 5 s); P0-OFF checks no
   token and kept accepting it. A new token for the same identity keeps access
   (T2b). Key rotation works: an old handle opens with the previous key and is refused once that key is removed (R-8).
7. **Kubernetes drain demo** (`lab/k8s/templates/60-drain-demo.yaml`): agent A starts a drain of a node running a
   PDB-protected `payments` workload as a task; agent B obtains the ID. Without a binding (P0, P-AGW) B can read the
   task and force the drain; with P1 B is refused both; P2 additionally lets B *watch* a read-only handle while still
   refusing the force.

Each verification run in [evidence/e2e-multipass/](evidence/e2e-multipass) has the step logs, the summary table, the
measurement rows (`measurements.tsv`) and, for the latest runs, the raw requests, responses and server logs of every
test run (`raw-evidence-*.tar.gz`). Running the lab yourself writes the same to `evidence/<run>/` and
`results/measurements.tsv` (both ignored by git). agentgateway PR #2995:
[evidence/agw-pr2995/README.md](evidence/agw-pr2995/README.md); released v1.6.0 `mcp_error` repro:
`evidence/i4-repro-*/`.

**Scope of the claims.** Results are for this lab: rmcp 3.5.1, agentgateway v1.6.0 and PR #2995 at `2bc5d041`,
Keycloak, and the configurations in [lab/k8s](lab/k8s). They say nothing about other SDKs or gateways.

## Quickstart

Requirements: Ubuntu 24.04 or 26.04 (amd64 or arm64), 4+ CPUs, 12 GB RAM, 40 GB disk, sudo, internet access.
A clean VM is the easiest way (see [Test in a throwaway VM](#test-in-a-throwaway-vm)).

```bash
sudo apt-get update && sudo apt-get install -y git   # if git is not there yet
git clone https://github.com/graphsentinel/mcp-task-ownership.git && cd mcp-task-ownership
scripts/platform.sh install      # Docker and python3 from Ubuntu; kubectl, k3d, helm only if missing
scripts/platform.sh cluster-up   # k3d cluster: 1 server, 1 agent, 1 drain-demo node
scripts/lab.sh all               # build images, helm install the lab, run all tests, print the summary
```

If `install` added you to the `docker` group, the next commands pick the group up by themselves (they re-run under
`sg docker`); in a new terminal or after logging in again it is active anyway.

Measured on a fresh 8-CPU VM: `platform.sh install` 42 s, `cluster-up` 49 s, `lab.sh all` 25 min with `RUNS=5`
(Rust build included), `lab.sh reinstall` 2.5 min. `scripts/lab.sh all` ends with a placement × test table and either
`ALL CHECKS PASSED` or the list of failed checks (exit status 1): a wrong outcome, a planned placement, test or run
that is missing, or a test runner that exited with an error. The table is also written to `lab/.runtime/summary.md`.

To remove the lab and keep the cluster: `scripts/lab.sh uninstall`. To remove the cluster too:
`scripts/platform.sh cluster-down`.

## How-to

### Two layers

| Layer | Script | What it owns |
|---|---|---|
| **platform** | `scripts/platform.sh` | host tools (Docker, python3, kubectl, k3d, helm) and the Kubernetes cluster |
| **lab** | `scripts/lab.sh` | our images, the Helm chart `lab/k8s` (release `ai1-lab`), the tests and their results |

The lab can be removed and installed again without touching the platform, for example after a code or
configuration change: `scripts/lab.sh reinstall`.

### Platform commands

| Command | What it does |
|---|---|
| `scripts/platform.sh install` | installs only what is missing: packages already installed are not reinstalled or upgraded by name (installing a missing one can still pull a newer dependency if apt requires it). From Ubuntu's packages: Docker (`docker.io` and `docker-buildx`, then its service is enabled and you are added to the `docker` group), python3, git, openssl, curl. Not packaged by Ubuntu: kubectl, k3d, helm at the versions in `scripts/versions.env` (sha256-checked). An existing Docker engine of any kind (docker-ce, rootless, snap) is not touched, nor its service or groups; an existing kubectl, k3d or helm is kept unless `UPGRADE_TOOLS=1`. inotify limits are raised if lower than k3s needs, never lowered |
| `scripts/platform.sh cluster-up` | creates the k3d cluster `ai1-tasks` (1 server, 1 agent) and the drain-demo node `k3d-drain-0-0` (label and taint `ai1/drain-demo=true`); idempotent |
| `scripts/platform.sh cluster-down` | deletes the k3d cluster |
| `scripts/platform.sh status` | tool versions and the cluster's nodes |

### Lab commands

| Command | What it does |
|---|---|
| `scripts/lab.sh build` | builds the four lab images; Rust is compiled inside a `rust` container, nothing on the host |
| `scripts/lab.sh install` | loads the images into the cluster (k3d import, checked on every node, or push to `REGISTRY`), then `helm upgrade --install ai1-lab lab/k8s` and waits until every pod is ready and the Keycloak realm answers |
| `scripts/lab.sh uninstall` | `helm uninstall`: removes what the release created (its namespaces with everything in them, Secrets, RBAC), then checks that none of it is left. The release namespace `ai1-lab` is deleted only if `lab.sh` created it and nothing but Helm's records is in it. The cluster stays |
| `scripts/lab.sh uninstall-legacy` | only for a lab deployed with `kubectl apply` before the chart existed, on `k3d-ai1-tasks`: lists, then deletes the namespaces labelled `ai1/role` and the drain RBAC |
| `scripts/lab.sh reinstall` | `build` + `uninstall` + `install`: from zero again, with new seal keys |
| `scripts/lab.sh test` | runs every placement `RUNS` times, the drain demo, then `summary` |
| `scripts/lab.sh summary` | prints the table for the last `test` and checks the outcomes, the completeness of the plan (placements × tests × runs) and the runners' exit status |
| `scripts/lab.sh status` | release and pods |
| `scripts/lab.sh all` | `build` + `install` + `test` |
| `scripts/check-versions.sh` | the host's Docker, k3d, kubectl, and the pinned versions against the latest upstream releases |
| `scripts/multipass-e2e.sh` | the whole quickstart, then `reinstall` and `uninstall`, in a fresh multipass VM |

Options (environment variables):

| Variable | Default | Effect |
|---|---|---|
| `KUBE_CONTEXT` | `k3d-ai1-tasks` | cluster to install on |
| `REGISTRY` | — | push the lab images there instead of importing them into k3d (required for any other cluster) |
| `RUNS` | `5` | runs per placement; `RUNS=1` for a quick check |
| `WITH_PR2995` | `0` | `1` builds agentgateway from PR #2995 (about 25 min more; with Docker it needs the buildx plugin), installs it and adds P-AGW2995 and P-AGW2995-SEAL; give it to `build`, `install` and `all` alike |
| `FULL` | `0` | `1` adds token lifetime (T2a, T2b; once per placement, waits for token expiry) and key rotation (R-8, `RUNS` times) |
| `ENGINE` | auto | `docker` or `podman` for builds (k3d nodes are inspected with the runtime k3d uses) |

### The Helm chart

`lab/k8s` is the chart (`Chart.yaml`, `values.yaml`, `templates/`). `scripts/lab.sh install` sets every image from
`scripts/versions.env`, so there is one place for versions. Values:

| Value | Default | Meaning |
|---|---|---|
| `images.*` | see `values.yaml` | image references |
| `imagePullPolicy` | `Never` | `Never` for images imported into k3d; `lab.sh` sets `IfNotPresent` with `REGISTRY` |
| `pr2995.enabled` | `false` | agentgateway PR #2995 build, the same with the ExtMcp sealing processor, and `ext-seal` |
| `drainDemo.enabled` | `true` | `payments` with a PodDisruptionBudget on the node labelled `ai1/drain-demo=true`, and the drain tool's RBAC; `lab.sh` turns it off when no such node exists |
| `drainDemo.node` | `k3d-drain-0-0` | that node's name; `lab.sh` sets it. The RBAC lets the drain tool cordon only this node |

Seal keys are random on first install and kept on upgrade; `uninstall` deletes them. The NetworkPolicy of P2-NP
(`lab/k8s/extra/55-netpol-p2.yaml`) is not part of the chart: `lab/run-placement.sh P2-NP` applies it for that run
only.

**agentgateway is installed standalone, not with its official Helm chart.** The chart deploys the released binary
(`ghcr.io/agentgateway/agentgateway`) as a plain Deployment configured by a ConfigMap
(`lab/k8s/templates/40-agentgateway.yaml`). agentgateway's own Helm chart installs its Gateway API control plane,
which is a different configuration path; the measurements are for the standalone setup.

### Use an existing cluster

```bash
export KUBE_CONTEXT=my-cluster REGISTRY=registry.example.com/ai1   # a registry the cluster can pull from
scripts/lab.sh build && scripts/lab.sh install && scripts/lab.sh test
```

The chart creates the namespaces `keycloak`, `mcp-shared`, `gateway`, `team-a`, `team-b` (and `ai1-lab` for the
release) and, with the drain demo, a ClusterRole `ai1-node-drain`; Helm refuses to install if any of them already
exists and does not belong to the release. Only the lab images are pushed to `REGISTRY`: the cluster pulls Keycloak,
Python and agentgateway itself from quay.io, docker.io and ghcr.io. The lab is deliberately insecure (P0 accepts
callers without a token), so use a cluster that is not shared with anything you care about.

The drain demo is installed only if a node is labelled `ai1/drain-demo=true` (and it should carry the matching
`NoSchedule` taint). The demo cordons that node and evicts and deletes its pods, and the drain tool's RBAC allows
deleting pods cluster-wide, so use a dedicated node and leave the label off anywhere else. Without the label there is
no drain RBAC at all. P2-NP needs a CNI that enforces NetworkPolicy (k3s does).

### Run one placement or one test

```bash
CONFIG=v2.1 lab/run-placement.sh P2              # default tests for one placement
CONFIG=v2.1 lab/run-placement.sh P1 T0,T1        # only T0 and T1 (TL/TB/TR still run where applicable)
ONLY_MAIN=1 lab/run-placement.sh P1 T0,T2a,T2b   # only the listed tests
lab/run-drain.sh P2 3                            # drain demo, 3 runs
```

These use `KUBE_CONTEXT` too. Each run prints a line per test and the evidence directory, and appends rows to
`results/measurements.tsv`.

### Look at a run

```bash
ls evidence/<run>/                 # manifest.txt, requests/responses per test, server and gateway logs
scripts/lab.sh status
kubectl --context k3d-ai1-tasks -n gateway logs deploy/seal-proxy
```

### Change code, configuration or a version

Edit the code, a template under `lab/k8s/templates/`, or `scripts/versions.env`, then `scripts/lab.sh reinstall`.
When you change one of the `localhost/ai1-*` images, also bump its tag in `scripts/versions.env`.
`scripts/check-versions.sh` shows what is newer upstream.

### Test in a throwaway VM

*For maintainers: checks a commit in a fresh VM before publishing. You do not need this to run the lab; the
[quickstart](#quickstart) is all a user runs, on their own machine.*

On an Ubuntu host with [multipass](https://canonical.com/multipass) (it uses the standard Ubuntu server cloud image):

```bash
scripts/multipass-e2e.sh                         # Ubuntu 26.04, 8 CPU, 16 GB; VM deleted afterwards
UBUNTU=24.04 RUNS=1 KEEP=1 scripts/multipass-e2e.sh
```

It copies the repository into a new VM (the committed tree when the working tree is clean, otherwise the working
tree, recorded in `source.txt`) and runs `platform.sh install && platform.sh cluster-up` in one shell, `lab.sh all`,
`lab.sh reinstall` with one more test run, and `lab.sh uninstall`. Logs per step, the summary and the new measurement
rows go to `evidence/e2e-multipass/<time>/`.

### Versions

`scripts/platform.sh install` does not change what the host already has:

| Comes from | Components | Version |
|---|---|---|
| Ubuntu's packages | Docker (`docker.io`, `docker-buildx`), python3, git, openssl, curl | whatever the Ubuntu release ships; an existing Docker of any source is kept |
| upstream, installed only if missing | kubectl, k3d, helm | v1.37.1, v5.9.0, v4.3.0 (an existing k3d 5.x, helm 3 or 4, and kubectl within one minor version of the cluster work; `UPGRADE_TOOLS=1` replaces them) |
| container images, pinned (`scripts/versions.env`) | Kubernetes (k3s) | v1.37.1-k3s1 |
| | Keycloak | 26.8.0 |
| | agentgateway | v1.6.0 (and PR #2995 at `2bc5d041`, optional) |
| | Rust (build), Python (driver), Debian (runtime base) | 1.99.0, 3.14.8, trixie-slim |

The pinned versions were the latest stable releases on 2026-10-11, except Python: 3.15.0 was released on 2026-10-09
but had no official `python` container image yet, so the driver uses 3.14.8. `scripts/check-versions.sh` shows what is
newer. The Rust build image and the Debian base of the lab images are pinned by digest; the other images by release
tag. Package installs inside image builds (`ca-certificates`, `protobuf-compiler`) come from Debian trixie at build
time.
The cluster runs in containers, so its versions are the same on every host.

Rust dependencies are locked by `Cargo.lock` (`cargo build --locked`). Seal keys are created fresh on each install; identities and lab secrets are fixed in [lab/k8s/realm-ai1.json](lab/k8s/realm-ai1.json) (lab-only
values, never use them elsewhere).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied ... docker.sock` | the docker group is not active in this shell: log out and in again (the scripts try `sg docker` first) |
| `k3d cluster create` hangs or nodes stay `NotReady` | check free memory and disk (`free -h`, `df -h`); `platform.sh install` raises the inotify limits k3s needs |
| `missing in <node>: <image>` | the import into k3d failed; `scripts/lab.sh install` checks every image on every node. Run `scripts/lab.sh build`, then `scripts/lab.sh install` again |
| `ctr: content digest ... not found` during an import by hand | a multi-platform image saved from Docker's containerd image store; save with `docker save --platform linux/amd64` (as `lab.sh` does) |
| `ImagePullBackOff` on another cluster | the cluster cannot pull from `REGISTRY`; check the registry address and pull credentials |
| `Error: ... exists and cannot be imported into the current release` | a namespace of the same name exists. If it is from a lab installed before the chart: `scripts/lab.sh uninstall-legacy`, then `scripts/lab.sh install`; otherwise use another cluster |
| `helm upgrade` times out | `scripts/lab.sh status` shows the pod that is not ready; Keycloak takes 1–2 minutes on first start |
| `warning: kubectl 1.x vs cluster 1.y is outside the supported skew` | an older kubectl was kept; `UPGRADE_TOOLS=1 scripts/platform.sh install` installs the pinned one |
| a test shows `77 setup-failed` | the setup step (for example getting a token) failed; the evidence directory has the reason |
| start over | `scripts/lab.sh reinstall` (lab only) or `scripts/platform.sh cluster-down && scripts/platform.sh cluster-up && scripts/lab.sh all` |

The lab uses only its kube context (`k3d-ai1-tasks` unless `KUBE_CONTEXT` is set); other clusters are not touched.

## Repository layout

```
scripts/                  platform.sh (layer 1), lab.sh (layer 2), versions.env, summary, VM test
lab/server/               lab task server (P0 / P1), Rust, rmcp 3.5.1
lab/official-p0/          rmcp's official Tasks example handler over HTTP (P0-OFF, P0-OFF-LIT)
lab/proxy/                sealing proxy (P2)
lab/ext-seal/             ExtMcp sealing processor for agentgateway PR #2995
lab/repro-i4/             repro on released agentgateway: how mcpGuardrails returns a processor's mcp_error
lab/driver/driver.py      test driver (runs inside the cluster)
lab/k8s/                  Helm chart ai1-lab: namespaces, Keycloak, servers, gateways, drain demo
lab/k8s/extra/            NetworkPolicy for P2-NP (applied per run)
lab/run-*.sh              per-placement, drain, key-rotation runners
evidence/e2e-multipass/   from-zero verification runs in fresh VMs (logs, summaries, raw evidence archives)
evidence/e2e-clone/       the quickstart as written, from a GitHub clone in a fresh VM
evidence/agw-pr2995/      agentgateway PR #2995 build and runs
evidence/i4-repro-*/      released agentgateway v1.6.0: mcp_error repro
results/, evidence/<run>/ written by your own runs (git-ignored)
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
