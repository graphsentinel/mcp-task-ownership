#!/usr/bin/env bash
# Compares the pins in scripts/versions.env with the latest upstream stable releases.
# Read-only: it changes nothing. Update versions.env by hand, then run scripts/lab.sh all to re-measure.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || echo "?"; }
rust_latest() { curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml 2>/dev/null | grep -m1 -A2 '^\[pkg.rustc\]' | sed -n 's/^version = "\([0-9.]*\).*/\1/p'; }
python_latest() {
  curl -fsSL "https://hub.docker.com/v2/repositories/library/python/tags?page_size=100&name=-slim-trixie" \
    | python3 -c 'import sys,json,re
v=[t["name"] for t in json.load(sys.stdin)["results"] if re.fullmatch(r"3\.\d+\.\d+-slim-trixie",t["name"])]
print(max(v,key=lambda s:tuple(map(int,s.split("-")[0].split("."))))) if v else print("?")'
}

row() { local s="same"; [ "$2" != "$3" ] && s="NEWER AVAILABLE"; [ "$3" = "?" ] && s="unknown"; printf '%-12s %-26s %-26s %s\n' "$1" "$2" "$3" "$s"; }
printf '%-12s %-26s %-26s %s\n' COMPONENT PINNED LATEST STATUS
printf '%-12s %-26s %-26s %s\n' kubectl-here "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo none)" "" "installed on this host"
printf '%-12s %-26s %-26s %s\n' k3d-here "$(k3d version 2>/dev/null | sed -n 's/^k3d version //p' || true)" "" "installed on this host"
printf '%-12s %-26s %-26s %s\n' docker-here "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo none)" "" "from the host's packages, not pinned"
row k3d        "$K3D_VERSION"               "$(gh_latest k3d-io/k3d)"
row kubernetes "$KUBECTL_VERSION"           "$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
row k3s        "${K3S_IMAGE##*:}"           "$(gh_latest k3s-io/k3s | tr + -)"
row rust       "$(echo "${RUST_IMAGE%%@*}" | sed 's/.*://; s/-.*//')" "$(rust_latest)"
row keycloak   "${KEYCLOAK_IMAGE##*:}"      "$(gh_latest keycloak/keycloak)"
row python     "${PYTHON_IMAGE##*:}"        "$(python_latest)"
row agentgw    "${AGW_IMAGE##*:}"           "$(gh_latest agentgateway/agentgateway)"
