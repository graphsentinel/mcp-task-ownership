#!/usr/bin/env bash
# Layer 2, the lab: our images, the Helm chart (lab/k8s) and the tests, on top of the platform (scripts/platform.sh).
#
#   scripts/lab.sh build       build the lab images (Rust compiled inside a container, nothing on the host)
#   scripts/lab.sh install     load the images into the cluster, helm upgrade --install ai1-lab, wait until ready
#   scripts/lab.sh uninstall   helm uninstall: removes everything the release created (the cluster and the platform stay)
#   scripts/lab.sh reinstall   build + uninstall + install: start again from zero after a code or config change
#   scripts/lab.sh test        run every placement RUNS times and the drain demo, then summary
#   scripts/lab.sh summary     table for the last 'test', checked against the expected outcomes (exit 1 if not)
#   scripts/lab.sh status      release, pods
#   scripts/lab.sh uninstall-legacy  remove a lab deployed before the Helm chart (kubectl apply), on k3d-ai1-tasks only
#   scripts/lab.sh all         build + install + test
#
# Options (environment):
#   KUBE_CONTEXT=...  cluster to use (default k3d-ai1-tasks, created by scripts/platform.sh cluster-up)
#   REGISTRY=...      push the lab images to this registry instead of importing them into k3d
#                     (needed for any cluster that is not the lab's k3d cluster), e.g. registry.example.com/ai1
#   RUNS=5            runs per placement (the published results use 5)
#   WITH_PR2995=1     also build, install and test agentgateway from PR #2995 (P-AGW2995 / P-AGW2995-SEAL; adds ~30 min);
#                     set it for build, install and all
#   FULL=1            also run token lifetime (T2a/T2b, once per placement; waits for token expiry) and key rotation (R-8)
#   ENGINE=docker     container engine for builds (docker or podman); detected when unset
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
RUNS=${RUNS:-5}; WITH_PR2995=${WITH_PR2995:-0}; FULL=${FULL:-0}; REGISTRY=${REGISTRY:-}
export KUBE_CONTEXT=${KUBE_CONTEXT:-k3d-$CLUSTER}
K="kubectl --context $KUBE_CONTEXT"
H="helm --kube-context $KUBE_CONTEXT"
RELEASE=ai1-lab; RELEASE_NS=ai1-lab; CHART="$ROOT/lab/k8s"
STATE="$ROOT/lab/.runtime"; mkdir -p "$STATE"

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 not found: run scripts/platform.sh install"; }

# right after 'platform.sh install' the docker group is not active in this shell yet: run again under it
if [ -z "${ENGINE:-}" ] && command -v docker >/dev/null && ! docker info >/dev/null 2>&1 \
   && [ -z "${AI1_SG:-}" ] && getent group docker | grep -qw "$(id -un)" && command -v sg >/dev/null; then
  export AI1_SG=1; exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi
if [ -z "${ENGINE:-}" ]; then
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then ENGINE=docker
  elif command -v podman >/dev/null; then ENGINE=podman
  else die "no usable container engine: scripts/platform.sh install, then log in again (docker group)"; fi
fi
Z=""; [ "$ENGINE" = podman ] && Z=":Z"
# k3d's nodes run in the runtime k3d talks to (docker CLI / DOCKER_HOST), whatever engine builds the images
NODE_RT=docker; command -v docker >/dev/null || NODE_RT=podman
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "unsupported architecture $(uname -m)" ;; esac

LAB_IMAGES=("$TASK_SERVER_IMAGE" "$SEAL_PROXY_IMAGE" "$OFFICIAL_P0_IMAGE" "$EXT_SEAL_IMAGE")
THIRD_PARTY=("$KEYCLOAK_IMAGE" "$PYTHON_IMAGE" "$AGW_IMAGE")
have_image() { $ENGINE image inspect "$1" >/dev/null 2>&1; }
with_pr2995() { [ "$WITH_PR2995" = 1 ]; }
# reference the cluster pulls: the local tag (k3d import) or the registry copy
ref() { if [ -n "$REGISTRY" ] && [[ "$1" == localhost/* ]]; then echo "$REGISTRY/${1#localhost/}"; else echo "$1"; fi; }
on_lab_k3d() { [ "$KUBE_CONTEXT" = "k3d-$CLUSTER" ] && [ -z "$REGISTRY" ]; }

# ---------------------------------------------------------------- build
# rust_build <mount dir> <workdir inside /src> <binary> <dist dir> [extra apt packages]
rust_build() {
  local mount=$1 wd=$2 bin=$3 dist=$4 apt=${5:-}
  local pre=""; [ -n "$apt" ] && pre="apt-get update -qq >/dev/null && apt-get install -y -qq $apt >/dev/null && "
  $ENGINE run --rm -v "$mount:/src$Z" -v ai1-cargo-registry:/usr/local/cargo/registry -w "/src/$wd" "$RUST_IMAGE" \
    sh -c "${pre}cargo build --release --locked && mkdir -p dist && cp target/release/$bin dist/ && chown -R $(id -u):$(id -g) target dist"
  test -x "$dist/$bin" || die "build of $bin produced no binary"
}

image_build() { # <tag> <context dir>
  $ENGINE build -q --build-arg BASE="$DEBIAN_IMAGE" -t "$1" -f "$2/Containerfile" "$2" >/dev/null
}

cmd_build() {
  log "pull $RUST_IMAGE and $DEBIAN_IMAGE"
  $ENGINE pull -q "$RUST_IMAGE" >/dev/null; $ENGINE pull -q "$DEBIAN_IMAGE" >/dev/null
  log "task server (P0 / P1)";          rust_build "$ROOT/lab/server" . task-lab-server "$ROOT/lab/server/dist"
  image_build "$TASK_SERVER_IMAGE" "$ROOT/lab/server"
  log "sealing proxy (P2)";             rust_build "$ROOT/lab" proxy task-seal-proxy "$ROOT/lab/proxy/dist"
  image_build "$SEAL_PROXY_IMAGE" "$ROOT/lab/proxy"
  log "rmcp example over HTTP (P0-OFF)"; rust_build "$ROOT/lab/official-p0" . official-task-demo-http "$ROOT/lab/official-p0/dist"
  image_build "$OFFICIAL_P0_IMAGE" "$ROOT/lab/official-p0"
  log "ExtMcp sealing processor";       rust_build "$ROOT/lab/ext-seal" . ext-seal "$ROOT/lab/ext-seal/dist" protobuf-compiler
  image_build "$EXT_SEAL_IMAGE" "$ROOT/lab/ext-seal"
  if [ "$WITH_PR2995" = 1 ]; then
    log "agentgateway from PR #2995 at $AGW_PR2995_SHA (slow)"
    # its Dockerfile uses RUN --mount, which needs BuildKit (Docker: the buildx plugin; podman supports it natively)
    if [ "$ENGINE" = docker ] && ! docker buildx version >/dev/null 2>&1; then
      die "building agentgateway needs Docker's buildx plugin: sudo apt-get install docker-buildx (Ubuntu) or docker-buildx-plugin (docker-ce)"
    fi
    local src="$STATE/agentgateway-pr2995"
    [ -d "$src/.git" ] || git clone -q --filter=blob:none "$AGW_PR2995_REPO" "$src"
    git -C "$src" checkout -q "$AGW_PR2995_SHA"
    DOCKER_BUILDKIT=1 $ENGINE build -q -t "$AGW_PR2995_IMAGE" --build-arg PROFILE=release \
      --build-arg VERSION="pr2995-$AGW_PR2995_SHA" --build-arg GIT_REVISION="$AGW_PR2995_SHA" -f "$src/Dockerfile" "$src" >/dev/null
  fi
  log "built images"
  $ENGINE images --format '{{.Repository}}:{{.Tag}}' | grep -E 'ai1-|agentgateway:pr2995' | sort
}

# ---------------------------------------------------------------- install
# k3d: images go into the nodes as one single-platform tarball. Docker 29 uses the containerd image store, where
# 'docker save' of a multi-platform image writes an index whose other-platform blobs are missing; k3s's
# 'ctr import' then fails while k3d still reports success. Hence --platform, and the check afterwards.
import_k3d() {
  local tar="$STATE/images.tar"
  if [ "$ENGINE" = podman ]; then podman save -m -o "$tar" "$@"
  # --platform needs Docker API 1.48+ (Docker 28); older engines use the classic image store, where plain save works
  elif ! docker save --platform "linux/$ARCH" -o "$tar" "$@" 2>/dev/null; then docker save -o "$tar" "$@"; fi
  k3d image import -c "$CLUSTER" "$tar"
  rm -f "$tar"
  local node img have missing=0
  for node in $(k3d node list -o json | python3 -c 'import sys,json;[print(n["name"]) for n in json.load(sys.stdin) if n["role"] in ("server","agent") and n["runtimeLabels"].get("k3d.cluster")=="'"$CLUSTER"'"]'); do
    have=$($NODE_RT exec "$node" crictl images -o json | python3 -c 'import sys,json;[print(t) for i in json.load(sys.stdin)["images"] for t in i["repoTags"]]')
    for img in "$@"; do grep -qx "$img" <<<"$have" || { echo "missing in $node: $img" >&2; missing=1; }; done
  done
  [ "$missing" = 0 ] || die "image import incomplete (see above)"
  echo "all $# images present on every node"
}

load_images() {
  local imgs=("${LAB_IMAGES[@]}")
  if with_pr2995; then imgs+=("$AGW_PR2995_IMAGE"); fi
  for i in "${imgs[@]}"; do have_image "$i" || die "$i missing: run scripts/lab.sh build"; done
  if on_lab_k3d; then
    log "images: pull third-party, import all into k3d"
    for i in "${THIRD_PARTY[@]}"; do $ENGINE pull -q --platform "linux/$ARCH" "$i" >/dev/null; done
    import_k3d "${THIRD_PARTY[@]}" "${imgs[@]}"
  elif [ -n "$REGISTRY" ]; then
    log "images: push lab images to $REGISTRY (third-party images are pulled by the cluster)"
    for i in "${imgs[@]}"; do $ENGINE tag "$i" "$(ref "$i")" && $ENGINE push -q "$(ref "$i")" >/dev/null && echo "  $(ref "$i")"; done
  else
    die "context $KUBE_CONTEXT is not the lab's k3d cluster: set REGISTRY=<registry/prefix> the cluster can pull from"
  fi
}

cmd_install() {
  need kubectl; need helm
  $K get --raw /readyz >/dev/null 2>&1 || die "cluster $KUBE_CONTEXT not reachable: scripts/platform.sh cluster-up (or set KUBE_CONTEXT)"
  local skew
  skew=$($K version -o json 2>/dev/null | python3 -c 'import sys,json;v=json.load(sys.stdin);c,s=int(v["clientVersion"]["minor"]),int(v["serverVersion"]["minor"].rstrip("+"));print(f"{c} {s}" if abs(c-s)>1 else "")' 2>/dev/null || true)
  if [ -n "$skew" ]; then echo "warning: kubectl 1.${skew% *} vs cluster 1.${skew#* } is outside the supported skew (±1); UPGRADE_TOOLS=1 scripts/platform.sh install" >&2; fi
  load_images

  local drain=false pr=false pull=IfNotPresent drain_node
  drain_node=$($K get nodes -l ai1/drain-demo=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$drain_node" ]; then drain=true; else drain_node=none; echo "no node labelled ai1/drain-demo=true: drain demo not installed"; fi
  if with_pr2995; then pr=true; fi
  if on_lab_k3d; then pull=Never; fi
  log "helm upgrade --install $RELEASE (context $KUBE_CONTEXT, drainDemo=$drain, pr2995=$pr)"
  # the release namespace holds only Helm's records; created here (and labelled) so that uninstall can tell it is ours
  if ! $K get ns "$RELEASE_NS" >/dev/null 2>&1; then
    $K create ns "$RELEASE_NS" >/dev/null && $K label ns "$RELEASE_NS" ai1/release-namespace=true >/dev/null
  fi
  $H upgrade --install "$RELEASE" "$CHART" -n "$RELEASE_NS" --wait --timeout 15m \
    --set imagePullPolicy="$pull" \
    --set images.keycloak="$KEYCLOAK_IMAGE" --set images.python="$PYTHON_IMAGE" --set images.agentgateway="$AGW_IMAGE" \
    --set images.taskServer="$(ref "$TASK_SERVER_IMAGE")" --set images.sealProxy="$(ref "$SEAL_PROXY_IMAGE")" \
    --set images.officialP0="$(ref "$OFFICIAL_P0_IMAGE")" --set images.extSeal="$(ref "$EXT_SEAL_IMAGE")" \
    --set images.agentgatewayPr2995="$(ref "$AGW_PR2995_IMAGE")" \
    --set pr2995.enabled="$pr" --set drainDemo.enabled="$drain" --set drainDemo.node="$drain_node"

  log "Keycloak realm ai1 answers"
  for _ in $(seq 1 60); do
    if $K -n team-a exec driver -- python3 -c "import urllib.request;urllib.request.urlopen('http://keycloak.keycloak.svc.cluster.local:8080/realms/ai1/.well-known/openid-configuration',timeout=5)" 2>/dev/null; then
      echo "ready"; return 0; fi
    sleep 5
  done
  die "Keycloak realm ai1 not reachable"
}

cmd_uninstall() {
  need kubectl; need helm
  if $H status "$RELEASE" -n "$RELEASE_NS" >/dev/null 2>&1; then
    log "helm uninstall $RELEASE (removes only what the release created: its namespaces, Secrets, RBAC, workloads)"
    $H uninstall "$RELEASE" -n "$RELEASE_NS" --wait --timeout 10m
  else
    echo "release $RELEASE not installed in $KUBE_CONTEXT"
  fi
  # The release namespace is removed only if this script created it (label ai1/release-namespace) and nothing but
  # Helm's records and the namespace defaults is left in it, checked over every namespaced resource type; if the
  # check itself fails, the namespace is kept.
  if [ "$($K get ns "$RELEASE_NS" -o jsonpath='{.metadata.labels.ai1/release-namespace}' 2>/dev/null)" = "true" ]; then
    local types other
    if types=$($K api-resources --namespaced --verbs=list -o name 2>/dev/null | grep -v '^events' | paste -sd, -) \
       && other=$($K -n "$RELEASE_NS" get "$types" -o name 2>/dev/null); then
      other=$(grep -v -E "^(configmap/kube-root-ca\.crt|serviceaccount/default|secret/sh\.helm\.release\.v1\.$RELEASE\.v[0-9]+)\$" <<<"$other" || true)
      if [ -z "$other" ]; then $K delete ns "$RELEASE_NS" --wait=true --timeout=120s
      else echo "namespace $RELEASE_NS kept, it holds: $(tr '\n' ' ' <<<"$other")"; fi
    else
      echo "namespace $RELEASE_NS kept: could not list its contents"
    fi
  fi
  rm -f "$STATE/test-started" "$STATE/test-plan"
  # check: none of the chart's namespaces or cluster-scoped objects is left
  local left more
  left=$($K get ns keycloak mcp-shared gateway team-a team-b -o name --ignore-not-found) || die "could not verify the removal (API error)"
  more=$($K get clusterrole,clusterrolebinding ai1-node-drain -o name --ignore-not-found) || die "could not verify the removal (API error)"
  left+=$more
  [ -z "$left" ] || die "still present after uninstall: $(tr '\n' ' ' <<<"$left")"
  echo "removed; the cluster is still there (scripts/platform.sh cluster-down deletes it)"
}

# A lab deployed with 'kubectl apply' before the chart existed has no Helm release. Only on the lab's own k3d
# cluster: delete the namespaces labelled ai1/role and the drain RBAC, after listing them.
cmd_uninstall_legacy() {
  need kubectl
  [ "$KUBE_CONTEXT" = "k3d-$CLUSTER" ] || die "uninstall-legacy only runs on k3d-$CLUSTER"
  $H status "$RELEASE" -n "$RELEASE_NS" >/dev/null 2>&1 && die "a Helm release exists: use scripts/lab.sh uninstall"
  log "legacy objects in $KUBE_CONTEXT"
  $K get ns -l ai1/role
  $K get clusterrole,clusterrolebinding ai1-node-drain --ignore-not-found
  $K delete ns -l ai1/role --wait=true --timeout=300s
  $K delete clusterrolebinding,clusterrole ai1-node-drain --ignore-not-found
}

cmd_status() {
  $H status "$RELEASE" -n "$RELEASE_NS" 2>/dev/null | sed -n '1,6p' || echo "release $RELEASE not installed"
  $K get pods -A -l ai1/role 2>/dev/null || true
  for ns in keycloak mcp-shared gateway team-a team-b; do $K -n "$ns" get pods --no-headers 2>/dev/null | sed "s/^/$ns  /"; done
}

# ---------------------------------------------------------------- test
cmd_test() {
  need kubectl; need helm
  $H status "$RELEASE" -n "$RELEASE_NS" >/dev/null 2>&1 || die "lab not installed: scripts/lab.sh install"
  rm -f "$STATE/test-plan"
  date -u +%Y-%m-%dT%H:%M:%S > "$STATE/test-started"
  : > "$STATE/runner-failures"
  # run <label> <command...>: show the result lines, record a non-zero exit of the runner
  run() {
    local label=$1; shift
    local rc=0
    "$@" > "$STATE/last-run.log" 2>&1 || rc=$?
    grep -E '^\[|^evidence|cluster:' "$STATE/last-run.log" || true
    [ "$rc" = 0 ] || { echo "$label: exit $rc" | tee -a "$STATE/runner-failures" >&2; tail -5 "$STATE/last-run.log" >&2; }
  }
  local placements=(P0-OFF P0-OFF-LIT P0 P1 P-AGW P2 P2-NP) drain=0
  if $K -n gateway get deploy agentgateway-pr2995-seal >/dev/null 2>&1; then placements+=(P-AGW2995 P-AGW2995-SEAL)
  elif with_pr2995; then die "WITH_PR2995=1 but the PR #2995 gateways are not installed: WITH_PR2995=1 scripts/lab.sh install"; fi
  if $K -n team-a get deploy payments >/dev/null 2>&1; then drain=1; fi
  # the plan is written before anything runs; summary fails unless the run reached the end ('complete')
  printf 'runs=%s\nplacements=%s\ndrain=%s\nfull=%s\ncomplete=0\n' "$RUNS" "$(IFS=,; echo "${placements[*]}")" "$drain" "$FULL" > "$STATE/test-plan"
  log "placements: ${placements[*]} x $RUNS runs"
  for i in $(seq 1 "$RUNS"); do
    for p in "${placements[@]}"; do
      echo "--- run $i/$RUNS $p"
      # P0-OFF-LIT: the handler is built per request, so only the owner's own read (T0) is meaningful
      if [ "$p" = P0-OFF-LIT ]; then
        ONLY_MAIN=1 CONFIG=v2.1 run "$p run $i" bash "$ROOT/lab/run-placement.sh" "$p" T0
      else
        CONFIG=v2.1 run "$p run $i" bash "$ROOT/lab/run-placement.sh" "$p"
      fi
    done
  done
  if [ "$drain" = 1 ]; then
    log "drain demo (P0, P1, P-AGW, P2) x $RUNS runs"
    for p in P0 P1 P-AGW P2; do CONFIG=v2.1 run "$p drain" bash "$ROOT/lab/run-drain.sh" "$p" "$RUNS"; done
  else
    log "drain demo skipped (not installed)"
  fi
  if [ "$FULL" = 1 ]; then
    log "token lifetime (T2a, T2b, T2a-exp) on P0-OFF, P1, P-AGW, P2; key rotation R-8 on P2"
    for p in P0-OFF P1 P-AGW P2; do ONLY_MAIN=1 CONFIG=v2.1 run "$p T2" bash "$ROOT/lab/run-placement.sh" "$p" T0,T2a,T2b,T2a-exp; done
    for i in $(seq 1 "$RUNS"); do run "R-8 run $i" bash "$ROOT/lab/run-r8.sh"; done
  fi
  sed -i 's/^complete=0$/complete=1/' "$STATE/test-plan"
  cmd_summary
}

cmd_summary() {
  [ -f "$STATE/test-started" ] || die "no test run recorded: run scripts/lab.sh test"
  [ -f "$STATE/test-plan" ] || die "no test plan recorded: run scripts/lab.sh test"
  local runs placements drain full complete
  # shellcheck disable=SC1091
  . "$STATE/test-plan"
  [ "$complete" = 1 ] || echo "warning: the last test run did not reach its end; the summary will list what is missing" >&2
  local plan=(--runs "$runs" --placements "$placements" --drain "$drain" --full "$full" --runner-failures "$STATE/runner-failures")
  [ "$complete" = 1 ] || plan+=(--incomplete)
  python3 "$ROOT/scripts/summary.py" --since "$(cat "$STATE/test-started")" --markdown "$STATE/summary.md" "${plan[@]}" \
    "$ROOT/results/measurements.tsv"
}

case "${1:-}" in
  build) cmd_build ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  uninstall-legacy) cmd_uninstall_legacy ;;
  reinstall) cmd_build; cmd_uninstall; cmd_install ;;
  test) cmd_test ;;
  summary) cmd_summary ;;
  status) cmd_status ;;
  all) cmd_build; cmd_install; cmd_test ;;
  *) sed -n '2,23p' "$0"; exit 2 ;;
esac
