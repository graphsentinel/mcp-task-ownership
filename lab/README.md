# Lab: MCP task ownership (k3d `ai1-tasks`)

Set up and run everything with `scripts/platform.sh` (tools, cluster) and `scripts/lab.sh` (this lab); see the
[root README](../README.md#quickstart). This file describes the parts.

| Path | What |
|---|---|
| `server/` | rmcp 3.5.1 task server; `OWNERSHIP_MODE=p0` (like rmcp's official Tasks example) or `p1` (owner-sealed handles). Image `localhost/ai1-task-server:0.3.1` |
| `official-p0/` | rmcp's official Tasks example handler, unmodified, served over streamable HTTP; `FACTORY=shared` (P0-OFF) or `per-request` (P0-OFF-LIT). Image `localhost/ai1-official-p0:0.1.0` |
| `proxy/` | P2 sealing proxy (XChaCha20-Poly1305 handles; shares `server/src/owner.rs`, so it is built from `lab/`). Image `localhost/ai1-seal-proxy:0.3.0` |
| `ext-seal/` | ExtMcp gRPC processor that seals and opens handles for agentgateway PR #2995. Image `localhost/ai1-ext-seal:0.1.0` |
| `driver/driver.py` | test driver, Python standard library only; copied into the driver pods by `run-placement.sh` |
| `k8s/` | Helm chart `ai1-lab` (`Chart.yaml`, `values.yaml`, `templates/`), installed by `scripts/lab.sh install`; `k8s/extra/` holds the P2-NP NetworkPolicy |
| `run-placement.sh` | runs the driver in-cluster against one placement; evidence to `evidence/<run>/`, rows to `results/measurements.tsv` |
| `run-drain.sh` | Kubernetes drain demo (needs a node labelled `ai1/drain-demo=true`; `scripts/platform.sh cluster-up` creates one) |
| `run-r8.sh` | key rotation on P2 (leaves a new active key in Secret `task-seal-key-p2`) |
| `run-agw2995.sh`, `run-v2-batch.sh` | batch runners used for the published results |

## Chart templates (`k8s/templates/`)

| File | Namespace | Contents |
|---|---|---|
| `00-namespaces.yaml` | — | `keycloak`, `mcp-shared`, `gateway`, `team-a`, `team-b` |
| `05-seal-keys.yaml` | mcp-shared, gateway | Secrets `task-seal-key`, `task-seal-key-p2`, `task-seal-key-agw`: random on first install, kept on upgrade |
| `10-keycloak.yaml` | keycloak | Keycloak with realm `ai1` |
| `11-realm.yaml` | keycloak | ConfigMap `realm-ai1` from `k8s/realm-ai1.json` |
| `20-task-servers.yaml` | mcp-shared | `task-server-p0`, `task-server-p1` (key from Secret `task-seal-key`) |
| `25-official-p0.yaml` | mcp-shared | `official-p0`, `official-p0-literal` |
| `30-driver.yaml` | team-a, team-b | driver pods and lab credentials |
| `40-agentgateway.yaml` | gateway | agentgateway v1.6.0 ×3, standalone (released binary + ConfigMap, not agentgateway's Helm chart), JWT + CEL policy |
| `45-agentgateway-pr2995.yaml` | gateway | PR #2995 build ×3, the same build with the ExtMcp processor ×3, `ext-seal` ×2 (key from Secret `task-seal-key-agw`; `pr2995.enabled`) |
| `50-seal-proxy.yaml` | mcp-shared, gateway | unchanged `task-server-p2`; `seal-proxy` ×3 (key from Secret `task-seal-key-p2`) |
| `60-drain-demo.yaml` | mcp-shared, team-a | ServiceAccount and RBAC for the drain tool; `payments` with a PDB on the node labelled `ai1/drain-demo=true` (`drainDemo.enabled`) |

`k8s/extra/55-netpol-p2.yaml` (mcp-shared): NetworkPolicy, applied by `run-placement.sh P2-NP` for that run only.

Images are set by `scripts/lab.sh install` from `scripts/versions.env`. On the lab's k3d cluster they are imported into
the nodes (`imagePullPolicy: Never`); with `REGISTRY` they are pushed there and pulled. Credentials in
`k8s/realm-ai1.json` and `k8s/templates/30-driver.yaml` are lab-only values.

## Change something

```bash
# edit lab/server, lab/proxy, ..., or a template, then:
scripts/lab.sh reinstall      # build + uninstall + install (new seal keys)
RUNS=1 scripts/lab.sh test
```

When you change code, bump the image tag in `scripts/versions.env`.
