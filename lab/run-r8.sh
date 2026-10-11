#!/usr/bin/env bash
# R-8 key rotation on P2 (sealing proxy). Handle sealed with K1 -> rotate to active=K2, previous=K1
# (old handle must open) -> delete previous (old handle must not open). Leaves active=K2.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
K="kubectl --context ${KUBE_CONTEXT:-k3d-ai1-tasks}"
RUN="$(date -u +%Y%m%dT%H%M%SZ)-P2-R8-${CONFIG:-v2}"; OUT="$ROOT/evidence/$RUN"; D="/evidence/$RUN"; mkdir -p "$OUT"
URL=http://seal-proxy.gateway.svc.cluster.local:8080/mcp
$K -n team-a cp "$ROOT/lab/driver/driver.py" driver:/driver.py
drv() { $K -n team-a exec driver -- python3 /driver.py --placement P2 --url "$URL" --out "$D" --run-id "$RUN" --expect refused --tests R-8 "$@"; }
setkeys() {  # $1 = active, $2 = previous (may be empty)
  args=(--from-literal=active="$1"); [ -n "${2:-}" ] && args+=(--from-literal=previous="$2")
  $K -n gateway create secret generic task-seal-key-p2 "${args[@]}" --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K -n gateway rollout restart deploy/seal-proxy >/dev/null
  $K -n gateway rollout status deploy/seal-proxy --timeout=180s >/dev/null
  echo "$(date -u +%FT%TZ) keys: active=$(echo "$1" | sha256sum | cut -c1-8) previous=$( [ -n "${2:-}" ] && echo "$2" | sha256sum | cut -c1-8 || echo none)" >> "$OUT/rotation.log"
}
K1=$($K -n gateway get secret task-seal-key-p2 -o jsonpath='{.data.active}' | base64 -d)
K2=$(openssl rand -base64 32)
drv --r8-stage setup
setkeys "$K2" "$K1"; drv --r8-stage rotated
setkeys "$K2" "";    drv --r8-stage removed
$K -n team-a cp "driver:$D" "$OUT" >/dev/null 2>&1
$K -n gateway logs -l app=seal-proxy --tail=-1 --prefix > "$OUT/gateway-seal-proxy.log"
echo "run_id: $RUN"$'\n'"placement: P2"$'\n'"test: R-8 (key fingerprints in rotation.log, sha256 prefix only)" > "$OUT/manifest.txt"
tail -n +2 "$OUT/measurements.tsv" >> "$ROOT/results/measurements.tsv"
echo "evidence: $OUT"
