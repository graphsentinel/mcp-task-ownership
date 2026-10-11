#!/usr/bin/env bash
# Kubernetes drain demo: lab/run-drain.sh P0|P1|P-AGW|P2 [runs]
# One drain node (labelled ai1/drain-demo=true; k3d-drain-0-0 on k3d), so runs are sequential; cluster state is captured after each run
# and the node and team-a/payments are reset before the next one.
set -uo pipefail
P=${1:?placement}; N=${2:-1}; ROOT=$(cd "$(dirname "$0")/.." && pwd); K="kubectl --context ${KUBE_CONTEXT:-k3d-ai1-tasks}"
NODE=$($K get nodes -l ai1/drain-demo=true -o jsonpath='{.items[0].metadata.name}'); [ -n "$NODE" ] || { echo "no node labelled ai1/drain-demo=true" >&2; exit 2; }
export DRAIN_NODE=$NODE
reset() {
  $K uncordon $NODE >/dev/null
  $K -n team-a rollout status deploy/payments --timeout=120s >/dev/null || { echo "reset: payments not ready" >&2; exit 1; }
  for _ in $(seq 1 120); do
    [ "$($K -n team-a get pdb payments -o jsonpath='{.status.currentHealthy}')" = 2 ] && return 0
    sleep 1
  done
  echo "reset: PodDisruptionBudget payments not healthy after 120 s" >&2; exit 1
}
FAIL=0
for i in $(seq 1 "$N"); do
  reset
  RC=0; OUT=$(ONLY_MAIN=1 "$ROOT/lab/run-placement.sh" "$P" T0,DRAIN 2>&1) || RC=$?
  [ "$RC" = 0 ] || { echo "run $i: run-placement.sh exited $RC" >&2; FAIL=1; }
  echo "$OUT" | grep -E '^\[' | cut -c1-230
  EV=$(echo "$OUT" | sed -n 's/^evidence: //p')
  [ -n "$EV" ] && { $K get node $NODE -o wide; echo; $K -n team-a get pods -l app=payments -o wide; echo; $K -n team-a get pdb payments; } > "$EV/cluster-after-drain.txt" 2>&1
  [ -n "$EV" ] && echo "  cluster: $(grep -c SchedulingDisabled "$EV/cluster-after-drain.txt") cordoned; payments: $($K -n team-a get pods -l app=payments --no-headers | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')"
done
reset
exit $FAIL
