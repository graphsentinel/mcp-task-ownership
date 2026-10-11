#!/usr/bin/env bash
# End-to-end check of the README quickstart in a fresh Ubuntu VM (multipass), from zero:
#   copy what a clone contains -> platform.sh install -> platform.sh cluster-up -> lab.sh all
#   -> lab.sh reinstall + one more test run (checks that the lab can be removed and installed again) -> fetch results.
#
#   scripts/multipass-e2e.sh                    Ubuntu 26.04, VM ai1-e2e (deleted at the end unless KEEP=1)
#   UBUNTU=24.04 RUNS=1 scripts/multipass-e2e.sh
#
# Options (environment): UBUNTU (26.04), VM (ai1-e2e), CPUS (8), MEM (16G), DISK (60G), RUNS (5),
#   WITH_PR2995 (0), FULL (0), REINSTALL_CHECK (1), KEEP (0: delete the VM afterwards).
# Output: evidence/e2e-multipass/<UTC>-ubuntu<ver>/ (logs, summary.md, the VM's new measurement rows).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UBUNTU=${UBUNTU:-26.04}; VM=${VM:-ai1-e2e}; CPUS=${CPUS:-8}; MEM=${MEM:-16G}; DISK=${DISK:-60G}
RUNS=${RUNS:-5}; WITH_PR2995=${WITH_PR2995:-0}; FULL=${FULL:-0}; KEEP=${KEEP:-0}; REINSTALL_CHECK=${REINSTALL_CHECK:-1}
# the source state is read before this run writes anything into the tree (its own output directory)
CLEAN=0; [ -z "$(cd "$ROOT" && git status --porcelain 2>/dev/null)" ] && CLEAN=1
OUT="$ROOT/evidence/e2e-multipass/$(date -u +%Y%m%dT%H%M%SZ)-ubuntu$UBUNTU"; mkdir -p "$OUT"
log() { printf '\n==> %s\n' "$*" | tee -a "$OUT/host.log"; }

command -v multipass >/dev/null || { echo "multipass not installed (sudo snap install multipass)" >&2; exit 1; }
if multipass info "$VM" >/dev/null 2>&1; then echo "VM $VM exists; delete it first: multipass delete --purge $VM" >&2; exit 1; fi

log "launch $VM: Ubuntu $UBUNTU, $CPUS CPU, $MEM, $DISK"
multipass launch "$UBUNTU" --name "$VM" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" --timeout 900
# the VM is kept when the run failed, so it can be inspected (delete it with: multipass delete --purge $VM)
cleanup() { [ "$KEEP" = 1 ] || [ "${rc:-0}" != 0 ] || { multipass delete --purge "$VM" 2>/dev/null || true; }; }
trap cleanup EXIT

# Source: the committed tree (git archive HEAD) when the working tree is clean, which is exactly what a clone gets.
# With uncommitted changes the working tree is copied instead (tracked + untracked, not ignored) and recorded as such.
# evidence/ and presentation/ are not needed to run. Streamed over stdin: the multipass snap cannot read the host's /tmp.
if [ "$CLEAN" = 1 ]; then
  SRC="committed tree $(cd "$ROOT" && git rev-parse HEAD)"
  pack() { (cd "$ROOT" && git archive --format=tar.gz HEAD -- . ':(exclude)evidence' ':(exclude)presentation'); }
else
  SRC="working tree with uncommitted changes (base $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo none)); NOT what a clone gets"
  pack() { (cd "$ROOT" && git ls-files -co --exclude-standard | grep -v -E '^(evidence|presentation)/' | tar -czf - -T -); }
fi
log "copy source: $SRC"
echo "$SRC" > "$OUT/source.txt"
[ "$CLEAN" = 1 ] || (cd "$ROOT" && git status --short) >> "$OUT/source.txt"
pack | multipass exec "$VM" -- bash -c 'mkdir -p ~/ai1 && tar -xzf - -C ~/ai1 && find ~/ai1 -type f | wc -l'

run() { # <log name> <command>: runs in a fresh login shell, so group changes from bootstrap apply
  local name=$1; shift
  log "$*"
  local start=$SECONDS rc=0
  multipass exec "$VM" -- sudo -iu ubuntu bash -lc "cd ~/ai1 && $*" 2>&1 | tee "$OUT/$name.log" || rc=$?
  echo "$name: exit $rc, $((SECONDS - start)) s" | tee -a "$OUT/host.log"
  return $rc
}

rc=0
step() { [ $rc = 0 ] || return 0; run "$@" || rc=$?; }
# install and cluster-up in one shell, as a reader pastes them: cluster-up must pick up the new docker group itself
step 01-platform-install-cluster-up "scripts/platform.sh install && scripts/platform.sh cluster-up"
step 02-lab-all "RUNS=$RUNS WITH_PR2995=$WITH_PR2995 FULL=$FULL scripts/lab.sh all"
# raw evidence of every run (requests, responses, logs), before anything is removed; a failed export fails the run
capture() {
  [ $rc = 0 ] || return 0
  multipass exec "$VM" -- bash -c 'cd ~/ai1 && tar -czf - evidence results' > "$OUT/raw-evidence-$1.tar.gz" \
    && tar -tzf "$OUT/raw-evidence-$1.tar.gz" >/dev/null && echo "raw evidence: raw-evidence-$1.tar.gz" | tee -a "$OUT/host.log" \
    || { echo "raw evidence export failed ($1)" | tee -a "$OUT/host.log"; rc=1; }
}
capture main
if [ "$REINSTALL_CHECK" = 1 ]; then
  multipass exec "$VM" -- bash -c 'cp ~/ai1/lab/.runtime/summary.md ~/summary-main.md 2>/dev/null; cp ~/ai1/lab/.runtime/test-started ~/test-started-main 2>/dev/null' || true
  step 03-lab-reinstall "WITH_PR2995=$WITH_PR2995 scripts/lab.sh reinstall && scripts/lab.sh status"
  step 04-lab-test-after-reinstall "RUNS=1 scripts/lab.sh test"
  capture after-reinstall
  step 05-lab-uninstall "scripts/lab.sh uninstall"
  # 'uninstall' checks that nothing of the lab is left; the platform must still work
  step 06-platform-after-uninstall "scripts/platform.sh status && kubectl --context k3d-ai1-tasks wait --for=condition=Ready node --all --timeout=60s"
fi

log "fetch results"
multipass exec "$VM" -- bash -c 'cat ~/summary-main.md 2>/dev/null || cat ~/ai1/lab/.runtime/summary.md' > "$OUT/summary.md" 2>/dev/null || true
multipass exec "$VM" -- bash -c 'cd ~/ai1 && s=$(cat ~/test-started-main 2>/dev/null || cat lab/.runtime/test-started) && awk -F"\t" -v s="$s" "NR==1 || substr(\$1,1,19)>=s" results/measurements.tsv' \
  > "$OUT/measurements.tsv" || true
multipass exec "$VM" -- bash -c 'lsb_release -ds; uname -r; nproc; free -h | head -2; cd ~/ai1 && scripts/platform.sh status' \
  > "$OUT/environment.txt" 2>&1 || true
echo "result: exit $rc" | tee -a "$OUT/host.log"
echo "output: $OUT"
exit $rc
