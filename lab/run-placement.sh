#!/usr/bin/env bash
# Run the driver against one placement and collect the evidence.
#   lab/run-placement.sh P0|P0-OFF|P0-OFF-LIT|P1|P-AGW|P-AGW2995|P-AGW2995-SEAL|P2|P2-NP [tests]
#   CONFIG (default v2) is appended to the run id: v1 = no audience validation, v2 = aud=task-server
#   ONLY_MAIN=1 lab/run-placement.sh P1 T0,T2a,T2b   # only the given tests (no TL / TB / TR / R-1)
# Raw evidence -> evidence/<run-id>/ ; one row per test -> results/measurements.tsv
set -euo pipefail
P=${1:?placement}; TESTS=${2:-T0,T0-B,PC,AUD,T1,T3a,T3b,T4}; CONFIG=${CONFIG:-v2}; PROFILE=lab
ROOT=$(cd "$(dirname "$0")/.." && pwd)
K="kubectl --context ${KUBE_CONTEXT:-k3d-ai1-tasks}"
# DEP = the task server; GW = gateway in front, if any; TB/TR only where a gateway layer seals
GW=""; GWNS=gateway; TB_EXPECT=""; DO_TR=""; LEAK_FROM_GW=""
case $P in
  P0) DEP=task-server-p0; EXPECT=baseline; EXPECT_PC=baseline ;;
  # rmcp's official Tasks example handler, unmodified (lab/official-p0)
  P0-OFF) DEP=official-p0; EXPECT=baseline; EXPECT_PC=baseline; PROFILE=official ;;
  P0-OFF-LIT) DEP=official-p0-literal; EXPECT=baseline; EXPECT_PC=baseline; PROFILE=official ;;
  P1) DEP=task-server-p1; EXPECT=refused; EXPECT_PC=refused ;;
  # agentgateway as released: no ownership expectation; its JWT + CEL policy must stop PC
  P-AGW) DEP=task-server-p0; EXPECT=baseline; EXPECT_PC=refused; GW=agentgateway ;;
  # agentgateway built from unmerged PR #2995 (lab/k8s/templates/45-agentgateway-pr2995.yaml): same policy, then + ExtMcp sealing
  P-AGW2995) DEP=task-server-p0; EXPECT=baseline; EXPECT_PC=refused; GW=agentgateway-pr2995 ;;
  P-AGW2995-SEAL) DEP=task-server-p0; EXPECT=refused; EXPECT_PC=refused; GW=agentgateway-pr2995-seal ;;
  # our sealing proxy in front of the unchanged task-server-p2
  P2) DEP=task-server-p2; EXPECT=refused; EXPECT_PC=refused; GW=seal-proxy; TB_EXPECT=reached; DO_TR=1; LEAK_FROM_GW=1 ;;
  P2-NP) DEP=task-server-p2; EXPECT=refused; EXPECT_PC=refused; GW=seal-proxy; TB_EXPECT=blocked; LEAK_FROM_GW=1
         TESTS=${2:-T0,T1} ;;
  *) echo "unknown placement $P" >&2; exit 2 ;;
esac
SERVER_URL="http://$DEP.mcp-shared.svc.cluster.local:8080/mcp"
URL=$SERVER_URL
[ -n "$GW" ] && URL="http://$GW.$GWNS.svc.cluster.local:8080/mcp"
RUN="$(date -u +%Y%m%dT%H%M%SZ)-$P-$CONFIG"
OUT="$ROOT/evidence/$RUN"; mkdir -p "$OUT" "$ROOT/results"
D="/evidence/$RUN"
nocolor() { sed 's/\x1b\[[0-9;]*m//g'; }
gwlogs() { $K -n "$GWNS" logs -l app="$GW" --tail=-1 "$@" | nocolor; }

if [ "$P" = P2-NP ]; then
  $K apply -f "$ROOT/lab/k8s/extra/55-netpol-p2.yaml" >/dev/null
  trap '$K delete -f "$ROOT/lab/k8s/extra/55-netpol-p2.yaml" --ignore-not-found >/dev/null' EXIT
  sleep 3
fi

# one copy per run: parallel runs must not overwrite each other's driver
for ns in team-a team-b; do $K -n $ns cp "$ROOT/lab/driver/driver.py" "driver:/driver-$RUN.py"; done
DELEG=(); [ "$GW" = seal-proxy ] && DELEG=(--delegate-url "http://$GW.$GWNS.svc.cluster.local:8080/delegate")
drv()  { $K -n team-a exec driver -- python3 "/driver-$RUN.py" --placement "$P" --url "$URL" --out "$D" --run-id "$RUN" --expect "$EXPECT" --expect-pc "$EXPECT_PC" --profile "$PROFILE" "${DELEG[@]}" ${DRAIN_NODE:+--drain-node "$DRAIN_NODE"} "$@"; }
drvb() { $K -n team-b exec driver -- python3 "/driver-$RUN.py" --placement "$P" --url "$URL" --out "$D" --run-id "$RUN" --expect "$EXPECT" "$@"; }

# 1. Main tests
drv --tests "$TESTS"

if [ -n "${ONLY_MAIN:-}" ]; then TB_EXPECT=""; DO_TR=""; LEAK_FROM_GW=""; fi
if [ -z "${ONLY_MAIN:-}" ]; then
# 2. TL: A's handle is read from an access log (what an intermediary logs as Mcp-Name)
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
drv --tests TL-setup
SLOG=$($K -n mcp-shared logs "deploy/$DEP" --since-time="$SINCE" | nocolor)
if [ -n "$LEAK_FROM_GW" ]; then
  LOG=$(gwlogs --since-time="$SINCE" | sort)
  SRC="access log of $GW (Mcp-Name of A's last tasks/get, all replicas)"
else
  LOG=$SLOG
  SRC="access log of $DEP (Mcp-Name of A's last tasks/get)"
  # agentgateway v1.6.0's default access log does not contain the task ID, so the leak is taken
  # from the server behind it
  [ -n "$GW" ] && SRC="$SRC; behind $GW, whose default access log has no task ID"
fi
LEAK=$(echo "$LOG" | { grep 'access:' || true; } | { grep 'mcp_method=tasks/get' || true; } | tail -1 | sed -E 's/.*mcp_name=([^ ]+).*/\1/')
UP=$(echo "$SLOG" | { grep 'task created' || true; } | tail -1 | sed -E 's/.*task_id=([^ ]+).*/\1/; s/.*upstream=([^ ]+).*/\1/')
TLARGS=(--leaked-handle "$LEAK" --leak-source "$SRC")
case $P in P1|P2|P2-NP) TLARGS+=(--leaked-upstream "$UP") ;; esac
drv --tests TL "${TLARGS[@]}"

fi

# 3. TB: B, from a pod in team-b, calls the server directly with A's upstream ID (from the server log)
if [ -n "$TB_EXPECT" ]; then
  drvb --tests TB --direct-url "$SERVER_URL" --leaked-upstream "$UP" --expect-tb "$TB_EXPECT"
fi

# 4. TR: A polls a long task while the proxy replicas are deleted one by one
if [ -n "$DO_TR" ]; then
  PODS=$($K -n "$GWNS" get pod -l app="$GW" -o jsonpath='{.items[*].metadata.name}')
  drv --tests TR --tr-seconds 25 > "$OUT/tr-driver.out" 2>&1 &
  TRPID=$!; TR_START=$SECONDS
  # wait at most 120 s for the driver to start polling; stop waiting if it exited
  for _ in $(seq 1 240); do
    grep -q TR-started "$OUT/tr-driver.out" 2>/dev/null && break
    kill -0 $TRPID 2>/dev/null || break
    sleep 0.5
  done
  grep -q TR-started "$OUT/tr-driver.out" 2>/dev/null || { echo "TR: driver did not start (see $OUT/tr-driver.out)" >&2; PODS=""; }
  for pod in $PODS; do
    sleep 5
    echo "$(date -u +%FT%TZ) delete $pod" >> "$OUT/tr-deletions.log"
    $K -n "$GWNS" delete pod "$pod" --wait=false >/dev/null
  done
  # at most 240 s from launch (25 s of polling, replica deletions, margin); after that the driver and its kubectl are
  # stopped and the run fails with 124
  while kill -0 $TRPID 2>/dev/null && [ $((SECONDS - TR_START)) -lt 240 ]; do sleep 1; done
  if kill -0 $TRPID 2>/dev/null; then
    pkill -P $TRPID 2>/dev/null; kill $TRPID 2>/dev/null
    echo "TR: driver stopped after 240 s" >&2; TR_RC=124
  fi
  wait $TRPID || TR_RC=${TR_RC:-$?}
  grep '\[' "$OUT/tr-driver.out" || true
  $K -n "$GWNS" rollout status deploy/"$GW" --timeout=120s >/dev/null
fi

# 5. Collect
$K -n team-a cp "driver:$D" "$OUT" >/dev/null 2>&1
if [ -n "$TB_EXPECT" ]; then
  $K -n team-b cp "driver:$D" "$OUT/team-b" >/dev/null 2>&1
fi
$K -n mcp-shared logs "deploy/$DEP" | nocolor > "$OUT/server-$DEP.log"
[ -n "$GW" ] && gwlogs --prefix > "$OUT/gateway-$GW.log"

# 6. R-1 (sealing placements; LEAK_FROM_GW is cleared by ONLY_MAIN): no upstream ID in anything the client received
if [ -n "$LEAK_FROM_GW" ]; then
  python3 - "$OUT" "$P" "$RUN" <<'PY'
import glob, json, re, sys, datetime
out, placement, run = sys.argv[1:]
ups = set(re.findall(r'task created op="create" mode="p0" task_id=([0-9a-f-]{36})', open(glob.glob(f"{out}/server-*.log")[0]).read()))
hits, checked = 0, 0
for f in glob.glob(f"{out}/{placement}-requests.jsonl"):
    for line in open(f):
        e = json.loads(line)
        if "response" not in e or e.get("test") in ("TL-upstream", "TB"):
            continue  # those responses echo an ID the caller itself presented
        checked += 1
        body = json.dumps(e["response"])
        hits += sum(u in body for u in ups)
verdict = "MATCH" if hits == 0 and ups else ("77" if not ups else "DEVIATION")
row = [datetime.datetime.now(datetime.timezone.utc).isoformat(), run, placement, "R-1", verdict, "0 upstream IDs",
       f"{hits} hits", f"{len(ups)} upstream IDs from the server log searched in {checked} client-side responses (TL-upstream, TB excluded)"]
open(f"{out}/measurements.tsv", "a").write("\t".join(row) + "\n")
print(f"[{placement}] R-1          {verdict:9} expected=0 upstream IDs observed={hits} hits ({len(ups)} IDs, {checked} responses)")
PY
fi
if [ -n "$TB_EXPECT" ] && [ -f "$OUT/team-b/measurements.tsv" ]; then
  tail -n +2 "$OUT/team-b/measurements.tsv" >> "$OUT/measurements.tsv"
fi

{
  echo "run_id: $RUN"; echo "placement: $P"; echo "config: $CONFIG"; echo "profile: $PROFILE"; echo "url: $URL"; echo "server_url: $SERVER_URL"; echo "expect: $EXPECT"
  echo "tests: $TESTS$([ -z "${ONLY_MAIN:-}" ] && echo ,TL)${TB_EXPECT:+,TB}${DO_TR:+,TR}"
  echo "server_image: $($K -n mcp-shared get deploy "$DEP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "server_image_id: $($K -n mcp-shared get pod -l app="$DEP" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  echo "server_env: $($K -n mcp-shared get deploy "$DEP" -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{" "}{end}')"
  if [ -n "$GW" ]; then
    echo "gateway: $GW image_id=$($K -n "$GWNS" get pod -l app="$GW" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}') replicas=$($K -n "$GWNS" get deploy "$GW" -o jsonpath='{.status.readyReplicas}')"
    [ "$GW" = agentgateway ] && echo "gateway_config: $($K -n gateway get cm agw-config -o jsonpath='{.data.config\.yaml}' | tr '\n' ' ' | tr -s ' ')"
    [ "$GW" = seal-proxy ] && echo "gateway_env: $($K -n gateway get deploy seal-proxy -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{" "}{end}')"
  fi
  [ "$P" = P2-NP ] && echo "networkpolicy: lab/k8s/extra/55-netpol-p2.yaml (applied for this run only)"
  echo "keycloak_image_id: $($K -n keycloak get pod -l app=keycloak -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  echo "rmcp: $(grep -A1 'name = "rmcp"' "$ROOT/lab/server/Cargo.lock" | grep version | head -1)"
  echo "spec: 2026-07-28"
} > "$OUT/manifest.txt"
[ -f "$ROOT/results/measurements.tsv" ] || head -1 "$OUT/measurements.tsv" > "$ROOT/results/measurements.tsv"
tail -n +2 "$OUT/measurements.tsv" >> "$ROOT/results/measurements.tsv"
echo "evidence: $OUT"
exit "${TR_RC:-0}"
