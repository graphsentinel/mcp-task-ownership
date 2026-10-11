#!/usr/bin/env bash
# Repro for issue I-4 on released agentgateway (scripts/versions.env AGW_IMAGE), independent of PR #2995:
# a remote mcpGuardrails processor refuses tools/call and resources/read with an explicit mcp_error; the client prints
# what comes back. Needs the lab's task-server-p0 (scripts/lab.sh install) in the same cluster.
#
#   lab/repro-i4/run.sh          build the processor, deploy, run the client, save evidence/i4-repro-<UTC>/
#   lab/repro-i4/run.sh clean    delete namespace i4-repro
#
# KUBE_CONTEXT (default k3d-ai1-tasks), ENGINE (docker or podman; detected) as for scripts/lab.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=../../scripts/versions.env
source "$ROOT/scripts/versions.env"
KUBE_CONTEXT=${KUBE_CONTEXT:-k3d-$CLUSTER}; K="kubectl --context $KUBE_CONTEXT"
DENY_IMAGE=localhost/ai1-i4-deny-processor:0.1.0
if [ -z "${ENGINE:-}" ]; then
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then ENGINE=docker; else ENGINE=podman; fi
fi
Z=""; [ "$ENGINE" = podman ] && Z=":Z"

if [ "${1:-}" = clean ]; then
  # only the namespace this script created (label ai1/repro=i4)
  [ "$($K get ns i4-repro -o jsonpath='{.metadata.labels.ai1/repro}' 2>/dev/null)" = i4 ] && $K delete ns i4-repro
  exit 0
fi
$K -n mcp-shared get deploy task-server-p0 >/dev/null || { echo "task-server-p0 not found: scripts/lab.sh install" >&2; exit 1; }

echo "==> build deny-processor"
D="$HERE/deny-processor"
$ENGINE run --rm -v "$D:/src$Z" -v ai1-cargo-registry:/usr/local/cargo/registry -w /src "$RUST_IMAGE" \
  sh -c "apt-get update -qq >/dev/null && apt-get install -y -qq protobuf-compiler >/dev/null && cargo build --release --locked && mkdir -p dist && cp target/release/deny-processor dist/ && chown -R $(id -u):$(id -g) target dist"
$ENGINE build -q --build-arg BASE="$DEBIAN_IMAGE" -t "$DENY_IMAGE" -f "$D/Containerfile" "$D" >/dev/null

echo "==> load images ($KUBE_CONTEXT)"
if [ "$KUBE_CONTEXT" = "k3d-$CLUSTER" ]; then
  tar="$ROOT/lab/.runtime/i4-images.tar"; mkdir -p "$ROOT/lab/.runtime"
  $ENGINE pull -q "$AGW_IMAGE" >/dev/null; $ENGINE pull -q "$PYTHON_IMAGE" >/dev/null
  if [ "$ENGINE" = podman ]; then podman save -m -o "$tar" "$DENY_IMAGE" "$AGW_IMAGE" "$PYTHON_IMAGE"
  # --platform needs Docker API 1.48+; older engines use the classic image store, where plain save works
  elif ! docker save --platform "linux/$(dpkg --print-architecture)" -o "$tar" "$DENY_IMAGE" "$AGW_IMAGE" "$PYTHON_IMAGE" 2>/dev/null; then
    docker save -o "$tar" "$DENY_IMAGE" "$AGW_IMAGE" "$PYTHON_IMAGE"; fi
  k3d image import -c "$CLUSTER" "$tar"; rm -f "$tar"
else
  echo "not the lab's k3d cluster: push $DENY_IMAGE to a registry the cluster can pull from and edit k8s.yaml" >&2; exit 1
fi

echo "==> deploy"
# own namespace only: created and labelled here; an existing one without the label is someone else's
if $K get ns i4-repro >/dev/null 2>&1; then
  [ "$($K get ns i4-repro -o jsonpath='{.metadata.labels.ai1/repro}')" = i4 ] || { echo "namespace i4-repro exists and is not this repro's" >&2; exit 1; }
else
  $K create ns i4-repro >/dev/null && $K label ns i4-repro ai1/repro=i4 >/dev/null
fi
sed -e "s#AGW_IMAGE#$AGW_IMAGE#" -e "s#DENY_IMAGE#$DENY_IMAGE#" "$HERE/k8s.yaml" | $K apply -f -
$K -n i4-repro rollout status deploy/deny-processor --timeout=180s
$K -n i4-repro rollout status deploy/agw-i4 --timeout=180s
$K -n i4-repro delete pod i4-client --ignore-not-found >/dev/null
$K -n i4-repro run i4-client --image="$PYTHON_IMAGE" --image-pull-policy=IfNotPresent --restart=Never --command -- sleep 600 >/dev/null
$K -n i4-repro wait --for=condition=Ready pod/i4-client --timeout=120s >/dev/null
$K -n i4-repro cp "$HERE/client.py" i4-client:/client.py

OUT="$ROOT/evidence/i4-repro-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
echo "==> client (output also in $OUT/client.out)"
$K -n i4-repro exec i4-client -- python3 /client.py | tee "$OUT/client.out"
{
  echo "agentgateway image: $AGW_IMAGE"
  echo "agentgateway image id: $($K -n i4-repro get pod -l app=agw-i4 -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  echo "processor: lab/repro-i4/deny-processor (AuthorizationError{INVALID, \"denied by repro processor\", mcp_error {\"code\":-32602,\"message\":\"custom error from processor\"}})"
  echo "upstream: task-server-p0 (unchanged); config: lab/repro-i4/k8s.yaml"
  echo "kubernetes: $($K version -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
  echo "time: $(date -u +%FT%TZ)"
} > "$OUT/manifest.txt"
$K -n i4-repro logs deploy/deny-processor > "$OUT/deny-processor.log" 2>&1 || true
$K -n i4-repro logs deploy/agw-i4 > "$OUT/agentgateway.log" 2>&1 || true
$K -n i4-repro get cm agw-i4-config -o jsonpath='{.data.config\.yaml}' > "$OUT/agentgateway-config.yaml"
echo "evidence: $OUT"
