# agentgateway PR #2995 in the lab (2026-10-10)

- Build: `stevenctl/agentgateway@2bc5d041` (PR #2995 head, unmerged; `mergeable_state=dirty` on 2026-10-10), the
  repository's own Dockerfile, release profile → `localhost/agentgateway:pr2995-2bc5d041` (`build.log`, rc=0).
- Manifest: `lab/k8s/templates/45-agentgateway-pr2995.yaml` (3 replicas each, in front of the unchanged `task-server-p0`).
- Processor: `lab/ext-seal/` (ExtMcp gRPC, about 200 lines): seals `taskId` in `tools/call` and `tasks/*` responses to
  (iss, sub, azp) from the gateway's validated JWT, passed as `mcpGuardrails` metadata CEL (`jwt.iss`, `jwt.sub`,
  `jwt.azp`); on `tasks/get|update|cancel` requests opens the handle, checks the owner, rewrites `taskId` and
  `Mcp-Name`, or refuses.
- Runs: `lab/run-agw2995.sh`, 5 × `P-AGW2995` + 5 × `P-AGW2995-SEAL`, config v2.1, on k3s v1.31.5 / Keycloak 26.7.0.
  `build.log` and `runs.log` are included; the per-run raw directories are not. The same outcomes in 1 run on the current
  pinned stack: `../e2e-multipass/20261011T053826Z-ubuntu26.04/` (`WITH_PR2995=1`).

| Test | P-AGW2995 (branch, JWT + CEL) | P-AGW2995-SEAL (branch + ext-seal) |
|---|---|---|
| T0, T0-B (owners) | pass 5/5 | pass 5/5 |
| PC-anon, PC-agent-c | refused 5/5 | refused 5/5 |
| T1 foreign get | access 5/5 | refused 5/5 |
| T3a foreign cancel | access 5/5 | refused 5/5 |
| T3b foreign answer | access 5/5 | refused 5/5 |
| TL leaked upstream id replayed | access 5/5 | refused 5/5 |
| T4 refusal vs unknown task | distinguishable | indistinguishable 5/5 (echoed id masked in `message` and `data`) |
| task ids returned to clients | — | 329, all sealed, 0 upstream ids |

Notes:
- The processor's `mcp_error` (`{"code":-32602,"message":"unknown task: <id>"}`) is delivered as `error.data`; the outer
  error is `{"code":-32600,"message":"<reason>"}` (`translate_error` in `guardrails/client.rs`; the same on released v1.6.0, see `../i4-repro-*/`). The
  proto comment says `mcp_error` "Overrides the code-derived default". A refusal therefore cannot be byte-identical to
  the upstream's own unknown-task error (`-32602`, no wrapper); T4 compares processor refusals with each other.
- The driver now normalizes the echoed id inside `data` as well as `message` (`lab/driver/driver.py`, T4); earlier runs
  had `data = null`, so their results are unchanged.
- `main` (2026-10-10) has no request-phase guardrail hook for `tasks/*`; #2995 adds it.
