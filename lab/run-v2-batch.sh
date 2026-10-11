#!/usr/bin/env bash
# Config v2 (aud=task-server enforced in P1, P2, P-agw) full measurement batch.
set -uo pipefail
cd "$(dirname "$0")/.."
log() { echo "$(date -u +%FT%TZ) $*"; }
log "phase 1: full matrix, sequential"
for i in 1 2 3 4 5; do
  for P in P0-OFF P0 P1 P-AGW P2 P2-NP; do lab/run-placement.sh $P 2>&1 | grep -E 'evidence:|DEVIATION|FAIL|77 ' ; done
  [ $i -le 4 ] && ONLY_MAIN=1 lab/run-placement.sh P0-OFF-LIT T0 2>&1 | grep -E 'evidence:'
done
log "phase 2: token tests, placements in parallel"
for i in 1 2 3 4 5; do
  for P in P0-OFF P1 P-AGW P2; do ONLY_MAIN=1 lab/run-placement.sh $P T0,T2a,T2b,T2a-exp 2>&1 | grep -E 'evidence:|DEVIATION|FAIL|77 |T2a-exp' & done
  wait
done
log "phase 3: R-8"
for i in 1 2 3 4 5; do lab/run-r8.sh 2>&1 | grep -E 'R-8:|evidence:'; done
log "done"
