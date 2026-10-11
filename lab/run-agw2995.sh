#!/usr/bin/env bash
# 5 runs each of P-AGW2995 (branch build, JWT + CEL only) and P-AGW2995-SEAL (+ ExtMcp sealing processor).
set -u
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5; do
  for p in P-AGW2995 P-AGW2995-SEAL; do CONFIG=v2.1 bash lab/run-placement.sh $p; done
done
