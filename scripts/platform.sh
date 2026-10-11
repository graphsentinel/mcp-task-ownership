#!/usr/bin/env bash
# Layer 1, the platform: tools on the host and a Kubernetes cluster. The lab (scripts/lab.sh) is installed on top.
#
#   scripts/platform.sh install       install what is missing on an Ubuntu host (24.04 / 26.04, amd64 or arm64)
#   scripts/platform.sh cluster-up    create the k3d cluster (1 server, 1 agent, 1 tainted drain-demo node)
#   scripts/platform.sh cluster-down  delete the k3d cluster
#   scripts/platform.sh status        tool versions, kube context, nodes
#
# 'install' never replaces what is already there:
#   - Ubuntu's own packages, at the version Ubuntu ships: Docker (docker.io, docker-buildx), python3, git, openssl, curl.
#     An existing Docker engine of any source is left unchanged.
#   - not packaged by Ubuntu: kubectl, k3d and helm, at the versions in scripts/versions.env (sha256-checked),
#     only when missing. Existing ones are kept and a version difference is reported. UPGRADE_TOOLS=1 replaces them.
#
# An existing cluster instead of k3d: skip 'cluster-up' and set KUBE_CONTEXT for scripts/lab.sh (see README).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
K="kubectl --context k3d-$CLUSTER"
ME=$(id -un)

# ---------------------------------------------------------------- install
# keep <tool> <pinned> <installed version>: true (skip install) when the tool exists and no upgrade was asked for
keep() {
  command -v "$1" >/dev/null 2>&1 || return 1
  [ "${UPGRADE_TOOLS:-0}" = 1 ] && return 1
  if [ "$3" = "$2" ]; then log "$1 $3 already installed"
  else log "$1 $3 already installed, kept (lab pins $2; UPGRADE_TOOLS=1 replaces it)"; fi
}

cmd_install() {
  command -v apt-get >/dev/null || die "install supports Ubuntu (apt); on other systems install docker, python3, kubectl, k3d and helm yourself"
  local arch; arch=$(dpkg --print-architecture)
  case "$arch" in amd64|arm64) ;; *) die "unsupported architecture: $arch" ;; esac
  export DEBIAN_FRONTEND=noninteractive

  # only packages that are missing: 'apt-get install' of an installed package would also upgrade it
  missing_pkgs() { local p; for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || echo "$p"; done; }
  local need; need=$(missing_pkgs git openssl python3 curl ca-certificates)
  if [ -n "$need" ]; then
    log "apt packages (Ubuntu's versions): $(echo $need)"
    sudo apt-get update -y
    # shellcheck disable=SC2086
    sudo -E apt-get install -y --no-install-recommends $need
  else
    log "apt packages: git, openssl, python3, curl, ca-certificates already installed, left unchanged"
  fi

  local new_group=0
  if command -v docker >/dev/null 2>&1; then
    # any existing engine (docker-ce, docker.io, rootless, snap, Desktop) is left as it is: no service or group change
    log "Docker already installed, left unchanged: $(docker --version 2>/dev/null || echo unknown)"
    docker info >/dev/null 2>&1 || echo "note: 'docker info' fails for $ME; the lab needs a Docker engine this user can use"
    docker buildx version >/dev/null 2>&1 || echo "note: no buildx plugin; needed only for WITH_PR2995=1 (Ubuntu package: docker-buildx)"
  else
    log "Docker from Ubuntu's docker.io and docker-buildx packages, service enabled, $ME added to group docker"
    sudo apt-get update -y
    sudo -E apt-get install -y docker.io docker-buildx
    sudo systemctl enable --now docker
    if ! id -nG "$ME" | grep -qw docker; then sudo usermod -aG docker "$ME"; new_group=1; fi
  fi

  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

  if ! keep kubectl "$KUBECTL_VERSION" "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null)"; then
    log "kubectl $KUBECTL_VERSION (dl.k8s.io)"
    curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$arch/kubectl"
    curl -fsSLo "$tmp/kubectl.sha256" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$arch/kubectl.sha256"
    echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum -c -
    sudo install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  fi

  if ! keep k3d "$K3D_VERSION" "$(k3d version 2>/dev/null | sed -n 's/^k3d version //p')"; then
    log "k3d $K3D_VERSION (github.com/k3d-io/k3d)"
    curl -fsSLo "$tmp/k3d" "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-$arch"
    curl -fsSLo "$tmp/k3d.sums" "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/checksums.txt"
    local sum; sum=$(grep "/k3d-linux-$arch\$" "$tmp/k3d.sums" | cut -d' ' -f1 || true)
    [ -n "$sum" ] || die "no checksum for k3d-linux-$arch in checksums.txt"
    echo "$sum  $tmp/k3d" | sha256sum -c -
    sudo install -m 0755 "$tmp/k3d" /usr/local/bin/k3d
  fi

  if ! keep helm "$HELM_VERSION" "$(helm version --template '{{.Version}}' 2>/dev/null)"; then
    log "helm $HELM_VERSION (get.helm.sh)"
    local t="helm-$HELM_VERSION-linux-$arch.tar.gz"
    curl -fsSLo "$tmp/$t" "https://get.helm.sh/$t"
    curl -fsSLo "$tmp/$t.sha256sum" "https://get.helm.sh/$t.sha256sum"
    (cd "$tmp" && sha256sum -c "$t.sha256sum")
    tar -xzf "$tmp/$t" -C "$tmp"
    sudo install -m 0755 "$tmp/linux-$arch/helm" /usr/local/bin/helm
  fi

  # k3s inside Docker needs enough inotify watches for several nodes; only raised, never lowered
  log "inotify limits for k3s-in-docker"
  local conf="" key want cur
  for kv in fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576; do
    key=${kv%=*}; want=${kv#*=}; cur=$(sysctl -n "$key")
    if [ "$cur" -lt "$want" ]; then conf+="$key=$want"$'\n'; echo "  $key $cur -> $want"; else echo "  $key $cur (kept)"; fi
  done
  if [ -n "$conf" ]; then printf '%s' "$conf" | sudo tee /etc/sysctl.d/99-ai1-lab.conf >/dev/null; sudo sysctl --system >/dev/null; fi

  cmd_status_tools
  echo
  [ "$new_group" = 1 ] && echo "You were added to the docker group; the next commands pick it up by themselves (sg docker). Next:"
  echo "  scripts/platform.sh cluster-up   # or use an existing cluster: export KUBE_CONTEXT=<context>"
  echo "  scripts/lab.sh all"
}

# ---------------------------------------------------------------- cluster
cmd_cluster_up() {
  command -v k3d >/dev/null || die "k3d not found: scripts/platform.sh install"
  if ! docker info >/dev/null 2>&1; then
    # right after 'install' the docker group is not active in this shell yet: run again under it
    if [ -z "${AI1_SG:-}" ] && getent group docker | grep -qw "$ME" && command -v sg >/dev/null; then
      export AI1_SG=1; exec sg docker -c "$(printf '%q ' "$0" cluster-up)"
    fi
    die "docker not usable by $ME (log out and in again so the docker group applies)"
  fi
  if k3d cluster list -o json | python3 -c 'import sys,json;sys.exit(0 if any(c["name"]=="'"$CLUSTER"'" for c in json.load(sys.stdin)) else 1)'; then
    log "k3d cluster $CLUSTER exists"
  else
    log "k3d cluster $CLUSTER ($K3S_IMAGE): 1 server, 1 agent"
    k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --servers 1 --agents 1 \
      --k3s-arg '--disable=traefik@server:0' --wait
  fi
  if ! $K get node k3d-drain-0-0 >/dev/null 2>&1; then
    log "drain-demo node k3d-drain-0-0"
    k3d node create drain-0 --cluster "$CLUSTER" --image "$K3S_IMAGE" --wait
  fi
  # nothing else is scheduled on the drain node; only the drain demo's payments workload tolerates the taint
  $K label node k3d-drain-0-0 ai1/drain-demo=true --overwrite >/dev/null
  $K taint node k3d-drain-0-0 ai1/drain-demo=true:NoSchedule --overwrite >/dev/null
  $K wait --for=condition=Ready node --all --timeout=180s
  echo "kube context: k3d-$CLUSTER"
}

cmd_cluster_down() {
  command -v k3d >/dev/null || die "k3d not found"
  k3d cluster delete "$CLUSTER"
}

# ---------------------------------------------------------------- status
cmd_status_tools() {
  log "tools"
  printf '  %-8s %s\n' docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version 2>/dev/null || echo missing)"
  printf '  %-8s %s\n' python3 "$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo missing)"
  printf '  %-8s %s\n' kubectl "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo missing)"
  printf '  %-8s %s\n' k3d "$(k3d version 2>/dev/null | sed -n 's/^k3d version //p' || echo missing)"
  printf '  %-8s %s\n' helm "$(helm version --template '{{.Version}}' 2>/dev/null || echo missing)"
}

cmd_status() {
  cmd_status_tools
  local ctx=${KUBE_CONTEXT:-k3d-$CLUSTER}
  log "cluster (context $ctx)"
  kubectl --context "$ctx" get nodes -L ai1/drain-demo 2>/dev/null || echo "  not reachable"
}

case "${1:-}" in
  install) cmd_install ;;
  cluster-up) cmd_cluster_up ;;
  cluster-down) cmd_cluster_down ;;
  status) cmd_status ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
