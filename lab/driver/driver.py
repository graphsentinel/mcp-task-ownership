#!/usr/bin/env python3
"""AI1 lab driver: runs the measurement contract's tests against one placement.

Standard library only. Every request and raw response is written to an evidence file
(JSON lines); one summary row per test is appended to a TSV.

Usage:
  driver.py --placement P0 --url http://task-server-p0.mcp-shared.svc:8080/mcp \
            --out /evidence/<run-id> [--tests T0,PC,T1,T3a,T3b,T4] [--expect baseline|refused]
            [--expect-pc baseline|refused]

Leaked-handle test (TL) runs in two phases, so the handle provably comes from a log and not
from the driver's memory:
  driver.py ... --tests TL-setup          # A creates and polls a task; nothing is printed
  (the caller reads A's handle from the access log)
  driver.py ... --tests TL --leaked-handle <h> --leak-source "<where it was read>"
                [--leaked-upstream <id>]  # P1 only: the upstream ID from the server log

Identities: A (alice via client agent-a) and B (bob via client agent-b), from Keycloak
with the password grant (lab only). Environment: KC_TOKEN_URL, KC_SECRET_A, KC_SECRET_B,
KC_USER_A/KC_PASS_A, KC_USER_B/KC_PASS_B. Optional C (alice via client agent-c, for PC): KC_SECRET_C.

Verdicts (TSV column `verdict`):
  MATCH      observed == expected
  DEVIATION  observed != expected
  OBSERVED   no expectation (P0 baseline: the specification permits bearer task IDs, DEC-16)
  77         inconclusive: T0 (positive control) failed in this run, or the setup step failed
"""
import argparse
import base64
import hashlib
import datetime as dt
import json
import os
import random
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

PROTOCOL = "2026-07-28"
META = {
    "io.modelcontextprotocol/protocolVersion": PROTOCOL,
    "io.modelcontextprotocol/clientInfo": {"name": "ai1-driver", "version": "0.1"},
    "io.modelcontextprotocol/clientCapabilities": {"extensions": {"io.modelcontextprotocol/tasks": {}}},
}
# Tool profile. "lab": our test server (cluster_audit, backup). "official": rmcp's official Tasks
# example (slow_sum(a, b), 2 s, no input_required tool): cluster_audit calls are mapped to
# slow_sum with a = a number derived from the label, so the owner's result is still recognisable.
PROFILE = "lab"
LABEL_NUM = {}


def shows(text, label):
    """Does a result text show the owner's label (or, in the official profile, its number)?"""
    return bool(label) and (label in text or (LABEL_NUM.get(label) is not None and text.strip() == LABEL_NUM[label]))


TSV_HEADER = ["time", "run_id", "placement", "test", "verdict", "expected", "observed", "detail"]


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def rand(n=8):
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=n))


class Evidence:
    def __init__(self, out_dir, placement, run_id, tsv_path=None):
        os.makedirs(out_dir, exist_ok=True)
        self.dir = out_dir
        self.placement = placement
        self.run_id = run_id
        self.log = open(os.path.join(out_dir, f"{placement}-requests.jsonl"), "a")
        self.tsv_path = tsv_path or os.path.join(out_dir, "measurements.tsv")
        if not os.path.exists(self.tsv_path):
            with open(self.tsv_path, "w") as f:
                f.write("\t".join(TSV_HEADER) + "\n")

    def record(self, entry):
        entry["time"] = now()
        entry["placement"] = self.placement
        entry["run_id"] = self.run_id
        self.log.write(json.dumps(entry) + "\n")
        self.log.flush()

    def row(self, test, verdict, expected, observed, detail=""):
        cells = [now(), self.run_id, self.placement, test, verdict, expected, observed, detail]
        line = "\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in cells)
        with open(self.tsv_path, "a") as f:
            f.write(line + "\n")
        print(f"[{self.placement}] {test:12} {verdict:9} expected={expected} observed={observed} {detail}", flush=True)


def jwt_claims(token):
    try:
        p = token.split(".")[1]
        p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p))
    except Exception:
        return {}


class Identity:
    def __init__(self, name, token_url, client_id, client_secret, user, password):
        self.name = name
        self.token_url, self.client_id, self.client_secret = token_url, client_id, client_secret
        self.user, self.password = user, password
        self.token = None
        self.claims = {}

    def login(self, ev=None):
        data = urllib.parse.urlencode({
            "grant_type": "password", "client_id": self.client_id, "client_secret": self.client_secret,
            "username": self.user, "password": self.password, "scope": "openid",
        }).encode()
        with urllib.request.urlopen(urllib.request.Request(self.token_url, data), timeout=15) as r:
            body = json.loads(r.read())
        self.token = body["access_token"]
        self.refresh_token = body.get("refresh_token")
        self.claims = jwt_claims(self.token)
        if ev:
            # The caller as the server will see it (contract §5); the token itself is not recorded.
            ev.record({"event": "login", "who": self.name,
                       "caller": {k: self.claims.get(k) for k in ("iss", "sub", "azp", "jti", "exp")}})
        return self


def form_post(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data), timeout=15) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def introspect(token_url, token, ev, test):
    """Token introspection as the `task-server` client: the separate control DEC-17 talks about."""
    st, body = form_post(token_url + "/introspect", {
        "client_id": "task-server", "client_secret": os.environ.get("KC_INTROSPECT_SECRET", ""), "token": token})
    try:
        active = json.loads(body).get("active")
    except Exception:
        active = None
    ev.record({"event": "introspect", "test": test, "status": st, "active": active})
    return active


class Client:
    def __init__(self, url, ev, timeout=30):
        self.url, self.ev, self.n, self.timeout = url, ev, 0, timeout
        self.last_replica = None

    def rpc(self, who, method, params, name=None, header_name=None, test=""):
        """Send one JSON-RPC request. `header_name` overrides the Mcp-Name header (R-5 checks)."""
        self.n += 1
        p = dict(params)
        p["_meta"] = META
        body = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": p}
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL,
            "Mcp-Method": method,
        }
        hn = header_name if header_name is not None else name
        if hn:
            headers["Mcp-Name"] = hn
        if who is not None and who.token:
            headers["Authorization"] = f"Bearer {who.token}"
        req = urllib.request.Request(self.url, json.dumps(body).encode(), headers)
        status, raw, replica = None, "", None
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                status, raw, replica = r.status, r.read().decode(), r.headers.get("x-ai1-replica")
        except urllib.error.HTTPError as e:
            status, raw, replica = e.code, e.read().decode(), e.headers.get("x-ai1-replica")
        except Exception as e:  # connection refused, timeout, NetworkPolicy drop
            status, raw = 0, f"{type(e).__name__}: {e}"
        parsed = None
        try:
            parsed = json.loads(raw)
        except Exception:
            # SSE fallback: take the last data: line
            for line in raw.splitlines()[::-1]:
                if line.startswith("data:"):
                    try:
                        parsed = json.loads(line[5:].strip())
                        break
                    except Exception:
                        pass
        self.ev.record({"test": test, "who": who.name if who else "anonymous",
                        "jti": who.claims.get("jti") if who else None, "method": method,
                        "params": params, "mcp_name": hn, "status": status, "replica": replica,
                        "response": parsed if parsed is not None else raw})
        self.last_replica = replica
        return status, parsed, raw


def result(parsed):
    return (parsed or {}).get("result")


def error(parsed):
    return (parsed or {}).get("error")


def create(c, who, tool, args, test):
    if PROFILE == "official" and tool == "cluster_audit":
        n = int(hashlib.sha256(args["label"].encode()).hexdigest()[:7], 16) % 1_000_000_000
        LABEL_NUM[args["label"]] = str(n)
        tool, args = "slow_sum", {"a": n, "b": 0}
    status, parsed, _ = c.rpc(who, "tools/call", {"name": tool, "arguments": args}, name=tool, test=test)
    r = result(parsed)
    if not r or r.get("resultType") != "task":
        raise RuntimeError(f"{test}: task not created: status={status} body={parsed}")
    return r["taskId"]


def get(c, who, task_id, test, header_name=None):
    return c.rpc(who, "tasks/get", {"taskId": task_id}, name=task_id, header_name=header_name, test=test)


def cancel(c, who, task_id, test):
    return c.rpc(who, "tasks/cancel", {"taskId": task_id}, name=task_id, test=test)


def update(c, who, task_id, answer, test):
    params = {"taskId": task_id, "inputResponses": {"confirm": answer}}
    return c.rpc(who, "tasks/update", params, name=task_id, test=test)


def poll(c, who, task_id, test, until=("completed", "failed", "cancelled", "input_required"), timeout=30):
    deadline = time.time() + timeout
    parsed = None
    while time.time() < deadline:
        _, parsed, _ = get(c, who, task_id, test)
        r = result(parsed)
        if r and r.get("status") in until:
            return r
        time.sleep(0.5)
    return result(parsed)


def text_of(task_result):
    try:
        return task_result["result"]["content"][0]["text"]
    except Exception:
        return ""


def status_of(parsed):
    r = result(parsed)
    return r.get("status") if r else None


def answer(by):
    return {"action": "accept", "content": {"confirm": True, "by": by}}


def classify_foreign(parsed, owner_label, status=None, raw=""):
    """What a foreign caller got back: `refused` (JSON-RPC error, or HTTP 401/403 from a gateway),
    `access` (the owner's task data), or `other` (anything else, kept verbatim in the detail)."""
    if status in (401, 403):
        return "refused", f"HTTP {status} {raw[:120]!r}"
    e = error(parsed)
    if e is not None:
        return "refused", f"error code={e.get('code')} message={e.get('message')!r}"
    r = result(parsed)
    if r is not None:
        shown = text_of(r) or ""
        if owner_label and (owner_label in shown or shows(shown, owner_label)):
            return "access", f"status={r.get('status')} result contains owner label {owner_label}"
        return "access", f"status={r.get('status')} (task metadata returned)"
    return "other", f"no result or error: {str(parsed)[:200]}"


class Run:
    def __init__(self, c, A, B, ev, expect):
        self.c, self.A, self.B, self.ev = c, A, B, ev
        self.expect = expect  # "refused" or "baseline"
        self.t0_ok = None

    def verdict(self, observed):
        if self.t0_ok is False:
            return "77"
        if self.expect == "baseline":
            return "OBSERVED"
        return "MATCH" if observed == self.expect else "DEVIATION"

    def expected(self):
        return "none (baseline)" if self.expect == "baseline" else self.expect

    # ------------------------------------------------------------ T0
    def t0(self):
        """Positive control: A creates, polls, re-reads with the same handle (R-6), and cancels a
        second task of its own; A's own observation confirms the cancel."""
        c, A = self.c, self.A
        checks = {}
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 2}, "T0")
        r = poll(c, A, tid, "T0")
        checks["completed"] = bool(r and r.get("status") == "completed" and shows(text_of(r), label))
        _, p2, _ = get(c, A, tid, "T0")
        checks["reuse"] = status_of(p2) == "completed"
        tid2 = create(c, A, "cluster_audit", {"label": label, "seconds": 20}, "T0")
        _, pc, _ = cancel(c, A, tid2, "T0")
        checks["cancel_ack"] = error(pc) is None and result(pc) is not None
        r2 = poll(c, A, tid2, "T0", until=("cancelled", "completed", "failed"), timeout=10)
        checks["cancelled"] = bool(r2 and r2.get("status") == "cancelled")
        self.t0_ok = all(checks.values())
        failed = [k for k, v in checks.items() if not v]
        self.ev.row("T0", "PASS" if self.t0_ok else "FAIL", "all owner operations succeed",
                    "pass" if self.t0_ok else "fail", "checks: " + ", ".join(f"{k}={v}" for k, v in checks.items())
                    + (f"; failed: {failed}" if failed else ""))
        return self.t0_ok

    # ------------------------------------------------------------ T0-B
    def t0b(self):
        """Positive control for B: B's own token works in this placement (B creates and reads its own
        task, re-reads it with the same handle). Without it, B's refusals could be a broken B."""
        c, B = self.c, self.B
        label = f"B-{rand()}"
        tid = create(c, B, "cluster_audit", {"label": label, "seconds": 1}, "T0-B")
        r = poll(c, B, tid, "T0-B")
        ok = bool(r and r.get("status") == "completed" and shows(text_of(r), label))
        _, p2, _ = get(c, B, tid, "T0-B")
        ok = ok and status_of(p2) == "completed"
        self.ev.row("T0-B", "PASS" if ok else "FAIL", "B's own operations succeed", "pass" if ok else "fail",
                    f"status={(r or {}).get('status')}")

    # ------------------------------------------------------------ T1
    def t1(self):
        """B (valid token) reads A's completed task with A's handle."""
        c, A, B = self.c, self.A, self.B
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "T1")
        r = poll(c, A, tid, "T1")
        if not (r and r.get("status") == "completed"):
            self.ev.row("T1", "77", self.expected(), "setup-failed", f"A's task did not complete: {r}")
            return
        st, pb, raw = get(c, B, tid, "T1")
        observed, detail = classify_foreign(pb, label, st, raw)
        self.ev.row("T1", self.verdict(observed), self.expected(), observed, detail)

    # ------------------------------------------------------------ T3a
    def t3a(self):
        """B cancels A's running task; A's own observation decides (an ack is not proof)."""
        c, A, B = self.c, self.A, self.B
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 6}, "T3a")
        _, pb, _ = cancel(c, B, tid, "T3a")
        b_err = error(pb)
        time.sleep(0.5)
        _, pa, _ = get(c, A, tid, "T3a")
        a_status = status_of(pa)
        if a_status == "cancelled":
            observed = "access"
        elif a_status in ("working", "completed") and b_err is not None:
            observed = "refused"
        else:
            observed = "other"
        detail = (f"B got {'error code=' + str(b_err.get('code')) + ' ' + repr(b_err.get('message')) if b_err else 'ack ' + json.dumps(result(pb))}"
                  f"; A then sees status={a_status}")
        self.ev.row("T3a", self.verdict(observed), self.expected(), observed, detail)
        if a_status == "working":
            poll(c, A, tid, "T3a", until=("completed", "failed", "cancelled"), timeout=15)

    # ------------------------------------------------------------ T3b
    def t3b(self):
        """A starts `backup` (input_required); B answers "continue?" on A's behalf."""
        c, A, B = self.c, self.A, self.B
        label = f"A-{rand()}"
        if PROFILE == "official":
            self.ev.row("T3b", "N/A", self.expected(), "not-applicable", "the official example has no input_required tool")
            return
        tid = create(c, A, "backup", {"label": label}, "T3b")
        r = poll(c, A, tid, "T3b", until=("input_required", "completed", "failed", "cancelled"))
        if not (r and r.get("status") == "input_required"):
            self.ev.row("T3b", "77", self.expected(), "setup-failed", f"A's task did not reach input_required: {r}")
            return
        _, pb, _ = update(c, B, tid, answer("B"), "T3b")
        b_err = error(pb)
        time.sleep(0.5)
        r = poll(c, A, tid, "T3b", until=("input_required", "completed", "failed", "cancelled"), timeout=5)
        a_status, a_text = (r or {}).get("status"), text_of(r or {})
        if a_status == "completed" and '"by":"B"' in a_text.replace(" ", ""):
            observed = "access"
        elif a_status == "input_required" and b_err is not None:
            observed = "refused"
        else:
            observed = "other"
        detail = (f"B got {'error code=' + str(b_err.get('code')) + ' ' + repr(b_err.get('message')) if b_err else 'ack ' + json.dumps(result(pb))}"
                  f"; A then sees status={a_status}" + (f" result={a_text!r}" if a_text else ""))
        # Clean up: if the task still waits, A answers; the task must then complete with A's answer.
        if a_status == "input_required":
            update(c, A, tid, answer("A"), "T3b")
            r = poll(c, A, tid, "T3b", until=("completed", "failed", "cancelled"), timeout=5)
            detail += f"; after A answers: status={(r or {}).get('status')} result={text_of(r or {})!r}"
        self.ev.row("T3b", self.verdict(observed), self.expected(), observed, detail)

    # ------------------------------------------------------------ TL
    def tl_setup(self):
        """A creates a task and polls it, so its handle appears in the access log as Mcp-Name."""
        c, A = self.c, self.A
        label = f"A-TL-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "TL-setup")
        r = poll(c, A, tid, "TL-setup")
        ok = bool(r and r.get("status") == "completed")
        self.ev.record({"event": "tl-setup", "label": label, "completed": ok})
        print(f"TL-setup completed={ok}", flush=True)

    def tl(self, leaked, source, leaked_upstream=None):
        """B replays a handle read from a log (never from the driver's memory)."""
        c, B = self.c, self.B
        st, pb, raw = get(c, B, leaked, "TL")
        observed, detail = classify_foreign(pb, "A-TL-", st, raw)
        self.ev.row("TL", self.verdict(observed), self.expected(), observed, f"source: {source}; {detail}")
        if leaked_upstream:
            st, pu, raw = get(c, B, leaked_upstream, "TL-upstream")
            observed, detail = classify_foreign(pu, "A-TL-", st, raw)
            self.ev.row("TL-upstream", self.verdict(observed), self.expected(), observed,
                        f"B presents the upstream ID from the server log; {detail}")

    # ------------------------------------------------------------ PC
    def pc(self, C, expect):
        """Policy control: is the placement's own access control active at all? A's completed task is
        read (i) without a token and (ii) by the same user through another agent client (agent-c, not
        allowed by the gateway policy; a different owner under DEC-14). Without this row a gateway that
        lets B through could simply be misconfigured."""
        c, A = self.c, self.A
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "PC")
        poll(c, A, tid, "PC")
        for name, who in (("PC-anon", None), ("PC-agent-c", C)):
            st, p, raw = get(c, who, tid, name)
            observed, detail = classify_foreign(p, label, st, raw)
            if self.t0_ok is False:
                verdict = "77"
            elif expect == "baseline":
                verdict = "OBSERVED"
            else:
                verdict = "MATCH" if observed == expect else "DEVIATION"
            self.ev.row(name, verdict, "none (baseline)" if expect == "baseline" else expect, observed,
                        ("no token; " if who is None else f"alice via {C.client_id}; ") + detail)

    # ------------------------------------------------------------ TB
    def tb(self, direct_url, upstream_id, expect):
        """Bypass: B, from a pod in team-b, calls the server's Service directly with A's upstream ID
        (read from the server log), skipping the gateway. `reached` = the server answered with A's
        data; `blocked` = no connection (e.g. NetworkPolicy); `refused` = the server answered with an
        error."""
        c = Client(direct_url, self.ev, timeout=5)
        st, p, raw = get(c, self.B, upstream_id, "TB")
        if st == 0:
            observed, detail = "blocked", f"no connection: {raw[:120]}"
        else:
            o, detail = classify_foreign(p, "A-TL-", st, raw)
            observed = "reached" if o == "access" else o
        verdict = "MATCH" if observed == expect else "DEVIATION"
        self.ev.row("TB", verdict, expect, observed, f"direct to {direct_url}; {detail}")

    # ------------------------------------------------------------ TR
    def tr(self, seconds):
        """Replicas: A polls a long task while the orchestrator deletes verifier replicas one by
        one. Transport errors while a pod goes away are retried and counted separately; any
        JSON-RPC error on A's own handle is a refusal of the owner."""
        c, A = self.c, self.A
        label = f"A-TR-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": seconds}, "TR")
        print("TR-started", flush=True)
        replicas, transport_errors, rpc_errors, final = set(), 0, [], None
        deadline = time.time() + seconds + 60
        while time.time() < deadline:
            st, p, raw = get(c, A, tid, "TR")
            if st == 0 or (st and st >= 500):
                transport_errors += 1
                time.sleep(0.3)
                continue
            if c.last_replica:
                replicas.add(c.last_replica)
            e = error(p)
            if e is not None:
                rpc_errors.append(e.get("message"))
            r = result(p)
            if r and r.get("status") in ("completed", "failed", "cancelled"):
                final = r
                break
            time.sleep(0.5)
        ok = bool(final and final.get("status") == "completed" and shows(text_of(final), label)) and not rpc_errors
        observed = "opens-everywhere" if ok and len(replicas) >= 2 else ("refused" if rpc_errors else "other")
        verdict = "77" if self.t0_ok is False else ("MATCH" if observed == "opens-everywhere" else "DEVIATION")
        self.ev.row("TR", verdict, "opens-everywhere", observed,
                    f"replicas seen={len(replicas)} {sorted(replicas)}; transport errors retried={transport_errors}; "
                    f"owner refusals={len(rpc_errors)}; final={(final or {}).get('status')}")

    # ------------------------------------------------------------ T2a / T2b
    def fresh(self, name="A2"):
        a = self.A
        return Identity(name, a.token_url, a.client_id, a.client_secret, a.user, a.password).login(self.ev)

    def t2a(self):
        """A's session is revoked in Keycloak; A then reuses the same access token on its own task.
        Determined by the token validation method, not by the seal (DEC-17); introspection is
        reported on its own row."""
        c = self.c
        A2 = self.fresh("A2")
        label = f"A-{rand()}"
        tid = create(c, A2, "cluster_audit", {"label": label, "seconds": 1}, "T2a")
        poll(c, A2, tid, "T2a")
        before = introspect(A2.token_url, A2.token, self.ev, "T2a")
        st, body = form_post(A2.token_url.rsplit("/token", 1)[0] + "/revoke", {
            "client_id": A2.client_id, "client_secret": A2.client_secret,
            "token": A2.refresh_token, "token_type_hint": "refresh_token"})
        self.ev.record({"event": "revoke", "test": "T2a", "status": st, "body": body[:200]})
        after = introspect(A2.token_url, A2.token, self.ev, "T2a")
        st2, p, raw = get(c, A2, tid, "T2a")
        observed = "accepted" if result(p) is not None and shows(text_of(result(p)), label) else "refused"
        left = int(A2.claims.get("exp", 0) - time.time())
        exp_ = "none (baseline)" if self.expect == "baseline" else "accepted (local JWT, until exp)"
        verdict = "77" if self.t0_ok is False else ("OBSERVED" if self.expect == "baseline" else
                                                    ("MATCH" if observed == "accepted" else "DEVIATION"))
        self.ev.row("T2a", verdict, exp_, observed,
                    f"revoke HTTP {st}; the revoked token still has {left}s to exp; "
                    + (f"error={error(p)}" if error(p) else f"status={result(p).get('status')}"))
        iv = "MATCH" if (before is True and after is False) else "DEVIATION"
        self.ev.row("T2a-introspection", "77" if self.t0_ok is False else iv, "active before, inactive after",
                    f"before={before} after={after}", "Keycloak introspection as client task-server (separate control, DEC-17)")

    def t2b(self):
        """A logs in again (same sub, same azp, new jti) and uses the handle of an older task."""
        c, A = self.c, self.A
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "T2b")
        poll(c, A, tid, "T2b")
        An = self.fresh("A-new")
        same = all(An.claims.get(k) == A.claims.get(k) for k in ("iss", "sub", "azp"))
        _, p, _ = get(c, An, tid, "T2b")
        observed = "accepted" if result(p) is not None and shows(text_of(result(p)), label) else "refused"
        exp_ = "none (baseline)" if self.expect == "baseline" else "accepted (owner = iss, sub, azp)"
        verdict = "77" if (self.t0_ok is False or not same) else ("OBSERVED" if self.expect == "baseline" else
                                                                ("MATCH" if observed == "accepted" else "DEVIATION"))
        self.ev.row("T2b", verdict, exp_, observed,
                    f"new token: same iss/sub/azp={same}, jti differs={An.claims.get('jti') != A.claims.get('jti')}")

    # ------------------------------------------------------------ R-8
    def r8(self, stage):
        """Key rotation (P2). `setup`: A creates a task; its handle is kept in a file in the pod.
        `rotated` (active=K2, previous=K1): the old handle must open. `removed` (previous deleted):
        it must not."""
        c, A = self.c, self.A
        path = "/tmp/r8-handle"
        if stage == "setup":
            label = f"A-R8-{rand()}"
            tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "R-8")
            poll(c, A, tid, "R-8")
            with open(path, "w") as f:
                json.dump({"handle": tid, "label": label}, f)
            print("R-8 setup done", flush=True)
            return
        saved = json.load(open(path))
        _, p, _ = get(c, A, saved["handle"], f"R-8:{stage}")
        observed = "opens" if result(p) is not None and shows(text_of(result(p)), saved["label"]) else "refused"
        expected = "opens" if stage == "rotated" else "refused"
        verdict = "77" if self.t0_ok is False else ("MATCH" if observed == expected else "DEVIATION")
        self.ev.row(f"R-8:{stage}", verdict, expected, observed,
                    "handle sealed with K1; " + ("active=K2, previous=K1" if stage == "rotated" else "active=K2, previous removed")
                    + (f"; error={error(p)}" if error(p) else ""))

    # ------------------------------------------------------------ TD (delegation)
    def td(self, C, delegate_url):
        """Delegation: A hands B a handle to WATCH its input_required task. With a delegate URL (P2)
        A mints a read-only handle bound to B; otherwise (today's default) A hands over the raw ID.
        B then tries to read, answer and cancel; C (alice via agent-c) tries B's handle."""
        c, A, B = self.c, self.A, self.B
        label = f"A-TD-{rand()}"
        if PROFILE == "official":
            for t in ("TD-read", "TD-update", "TD-cancel", "TD-forward"):
                self.ev.row(t, "N/A", "-", "not-applicable", "the official example has no input_required tool")
            return
        tid = create(c, A, "backup", {"label": label}, "TD")
        r0 = poll(c, A, tid, "TD", until=("input_required", "completed", "failed", "cancelled"))
        if not (r0 and r0.get("status") == "input_required"):
            self.ev.row("TD", "77", "-", "setup-failed", f"A's task did not reach input_required: {r0}")
            return
        how = "raw task ID (no delegation mechanism)"
        handle = tid
        if delegate_url:
            body = json.dumps({"handle": tid, "sub": B.claims["sub"], "azp": B.claims["azp"], "rights": ["tasks/get"]}).encode()
            req = urllib.request.Request(delegate_url, body, {"Content-Type": "application/json", "Authorization": f"Bearer {A.token}"})
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    handle = json.loads(resp.read())["handle"]
                how = "read-only handle bound to B (rights=[tasks/get])"
            except Exception as e:
                self.ev.row("TD", "77", "-", "setup-failed", f"delegate failed: {e}")
                return
        self.ev.record({"event": "delegated", "how": how})
        exp_refused = "refused" if delegate_url else "none (baseline)"
        def verdict(obs, exp):
            if self.t0_ok is False:
                return "77"
            if exp.startswith("none"):
                return "OBSERVED"
            return "MATCH" if obs == exp else "DEVIATION"
        # read
        _, p, _ = get(c, B, handle, "TD-read")
        obs = "read" if result(p) is not None else "refused"
        exp = "read" if delegate_url else "none (baseline)"
        self.ev.row("TD-read", verdict(obs, exp), exp, obs, f"{how}; status={(result(p) or {}).get('status')}")
        # answer the approval prompt on A's behalf
        _, p, _ = update(c, B, handle, answer("B"), "TD-update")
        time.sleep(0.5)
        r1 = poll(c, A, tid, "TD-update", until=("input_required", "completed", "failed", "cancelled"), timeout=5)
        a_text = text_of(r1 or {})
        obs = "answered" if '"by":"B"' in a_text.replace(" ", "") else ("refused" if error(p) is not None and (r1 or {}).get("status") == "input_required" else "other")
        self.ev.row("TD-update", verdict(obs, exp_refused), exp_refused, obs, f"A then sees status={(r1 or {}).get('status')}")
        # cancel: on a second, still-running task of A, delegated the same way (the first one may
        # already be finished by B's answer in the baseline placements)
        tid2 = create(c, A, "cluster_audit", {"label": label + "-2", "seconds": 20}, "TD-cancel")
        handle2 = tid2
        if delegate_url:
            body = json.dumps({"handle": tid2, "sub": B.claims["sub"], "azp": B.claims["azp"], "rights": ["tasks/get"]}).encode()
            req = urllib.request.Request(delegate_url, body, {"Content-Type": "application/json", "Authorization": f"Bearer {A.token}"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                handle2 = json.loads(resp.read())["handle"]
        _, p, _ = cancel(c, B, handle2, "TD-cancel")
        time.sleep(0.5)
        _, pa, _ = get(c, A, tid2, "TD-cancel")
        st_a = status_of(pa)
        if st_a == "working":
            cancel(c, A, tid2, "TD-cancel")  # clean up A's own task
        obs = "cancelled" if st_a == "cancelled" else ("refused" if error(p) is not None else "other")
        self.ev.row("TD-cancel", verdict(obs, exp_refused), exp_refused, obs, f"A then sees status={st_a}")
        # forward B's handle to C
        _, p, _ = get(c, C, handle, "TD-forward")
        obs = "read" if result(p) is not None else "refused"
        self.ev.row("TD-forward", verdict(obs, exp_refused), exp_refused, obs, "C = alice via agent-c presents B's handle")
        _, pf, _ = get(c, A, tid, "TD")
        if status_of(pf) == "input_required":
            update(c, A, tid, answer("A"), "TD")

    # ------------------------------------------------------------ DRAIN (Kubernetes demo)
    def drain(self, node, delegate_url):
        """A drains a node; the PodDisruptionBudget makes the task ask before forcing. A hands a
        watcher (B) the task: the raw ID today, a read-only handle bound to B in P2. B watches, then
        tries to answer "force it" on A's behalf."""
        c, A, B = self.c, self.A, self.B
        label = f"A-DRAIN-{rand()}"
        tid = create(c, A, "node_drain", {"node": node, "label": label}, "DRAIN")
        r0 = poll(c, A, tid, "DRAIN", until=("input_required", "completed", "failed", "cancelled"), timeout=30)
        if not (r0 and r0.get("status") == "input_required"):
            self.ev.row("DRAIN", "77", "-", "setup-failed", f"drain did not stop at the PodDisruptionBudget prompt: {r0}")
            return
        prompt = next(iter((r0.get("inputRequests") or {}).values()), {}).get("params", {}).get("message", "")
        handle, how = tid, "raw task ID"
        if delegate_url:
            body = json.dumps({"handle": tid, "sub": B.claims["sub"], "azp": B.claims["azp"], "rights": ["tasks/get"]}).encode()
            req = urllib.request.Request(delegate_url, body, {"Content-Type": "application/json", "Authorization": f"Bearer {A.token}"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                handle = json.loads(resp.read())["handle"]
            how = "read-only handle bound to B"
        base = "none (baseline)" if not delegate_url else None
        def verdict(obs, exp):
            return "77" if self.t0_ok is False else ("OBSERVED" if exp.startswith("none") else ("MATCH" if obs == exp else "DEVIATION"))
        _, p, _ = get(c, B, handle, "DRAIN-watch")
        obs = "read" if result(p) is not None else "refused"
        exp = base or "read"
        self.ev.row("DRAIN-watch", verdict(obs, exp), exp, obs, f"{how}; B sees status={(result(p) or {}).get('status')}; prompt={prompt!r}")
        _, p, _ = update(c, B, handle, {"action": "accept", "content": {"confirm": True, "by": "B"}}, "DRAIN-force")
        time.sleep(1.5)
        r1 = poll(c, A, tid, "DRAIN-force", until=("input_required", "completed", "failed", "cancelled"), timeout=10)
        txt = text_of(r1 or {})
        if "FORCED" in txt and "by=B" in txt:
            obs = "forced-by-B"
        elif (r1 or {}).get("status") == "input_required" and error(p) is not None:
            obs = "refused"
        else:
            obs = "other"
        exp = base or "refused"
        self.ev.row("DRAIN-force", verdict(obs, exp), exp, obs, f"A then sees status={(r1 or {}).get('status')} result={txt!r}")
        if (r1 or {}).get("status") == "input_required":
            update(c, A, tid, {"action": "accept", "content": {"confirm": False, "by": "A"}}, "DRAIN")
            r2 = poll(c, A, tid, "DRAIN", until=("completed", "failed", "cancelled"), timeout=10)
            self.ev.record({"event": "drain-owner-decision", "result": text_of(r2 or {})})

    # ------------------------------------------------------------ AUD (config v2)
    def aud(self, D):
        """A token WITHOUT aud=task-server (alice via agent-noaud) tries to create its own task."""
        tool = "slow_sum" if PROFILE == "official" else "cluster_audit"
        args = {"a": 1, "b": 1} if PROFILE == "official" else {"label": "D-aud", "seconds": 1}
        st, p, raw = self.c.rpc(D, "tools/call", {"name": tool, "arguments": args}, name=tool, test="AUD")
        r = result(p)
        observed = "accepted" if (r and r.get("resultType") == "task") else "refused"
        detail = f"HTTP {st}; " + (f"error={error(p)}" if error(p) else (raw[:100] if not r else "task created"))
        exp_ = "none (baseline)" if self.expect == "baseline" else "refused"
        verdict = "OBSERVED" if self.expect == "baseline" else ("MATCH" if observed == "refused" else "DEVIATION")
        self.ev.row("AUD", verdict, exp_, observed, "alice via agent-noaud (no aud claim); " + detail)

    # ------------------------------------------------------------ T2a-exp
    def t2a_exp(self, S, wait_max=200):
        """A 60 s token (alice via agent-s) is revoked, then reused on its own task every 5 s until it
        is refused or `wait_max` passes. Records when the refusal happens relative to the token's exp."""
        c = self.c
        label = f"S-{rand()}"
        tid = create(c, S, "cluster_audit", {"label": label, "seconds": 1}, "T2a-exp")
        poll(c, S, tid, "T2a-exp")
        st, _ = form_post(S.token_url.rsplit("/token", 1)[0] + "/revoke", {
            "client_id": S.client_id, "client_secret": S.client_secret, "token": S.refresh_token,
            "token_type_hint": "refresh_token"})
        exp = S.claims.get("exp", 0)
        last_ok, first_refused = None, None
        start = time.time()
        while time.time() - start < wait_max:
            _, p, _ = get(c, S, tid, "T2a-exp")
            ok = result(p) is not None and shows(text_of(result(p)), label)
            if ok:
                last_ok = time.time() - exp
            else:
                first_refused = time.time() - exp
                break
            time.sleep(5)
        if first_refused is None:
            observed = f"accepted throughout (last at exp{last_ok:+.0f}s)"
        else:
            observed = f"refused at exp{first_refused:+.0f}s"
        expected = "none (baseline)" if self.expect == "baseline" else "refused after exp (+ leeway)"
        if self.expect == "baseline":
            verdict = "OBSERVED"
        else:
            verdict = "MATCH" if first_refused is not None else "DEVIATION"
        self.ev.row("T2a-exp", verdict, expected, observed,
                    f"60 s token revoked at once (HTTP {st}); last accepted at exp{(last_ok if last_ok is not None else float('nan')):+.0f}s; polled every 5 s")

    # ------------------------------------------------------------ T4
    def t4(self):
        """B presents (i) A's handle, (ii) a random handle of the same shape, (iii) a malformed
        handle. Compares HTTP status, error code, message and data. rmcp echoes the presented ID
        in its "unknown task" message, so the message is also compared with that echo normalized.
        A gateway may wrap a processor's error in `data` (agentgateway mcpGuardrails puts `mcp_error`
        there); the echoed ID is normalized in `data` the same way."""
        c, A, B = self.c, self.A, self.B
        label = f"A-{rand()}"
        tid = create(c, A, "cluster_audit", {"label": label, "seconds": 1}, "T4")
        poll(c, A, tid, "T4")
        cases = {"own-of-A": tid, "random": same_shape(tid), "tampered": tampered(tid), "malformed": "not-a-task-handle!"}
        seen = {}
        for name, h in cases.items():
            status, parsed, _ = get(c, B, h, f"T4:{name}")
            e = error(parsed) or {}
            seen[name] = {"http": status, "code": e.get("code"), "message": e.get("message"),
                          "data": e.get("data"), "result": result(parsed) is not None, "presented": h}
        def norm(s):
            msg = s["message"] or ""
            return msg.replace(s["presented"], "<ID>")
        fields = {
            "http": {k: v["http"] for k, v in seen.items()},
            "code": {k: v["code"] for k, v in seen.items()},
            "message_raw": {k: v["message"] for k, v in seen.items()},
            "message_normalized": {k: norm(v) for k, v in seen.items()},
            "data_raw": {k: json.dumps(v["data"]) for k, v in seen.items()},
            "data_normalized": {k: json.dumps(v["data"]).replace(v["presented"], "<ID>") for k, v in seen.items()},
            "result_returned": {k: v["result"] for k, v in seen.items()},
        }
        differ = [f for f, vals in fields.items() if len(set(map(str, vals.values()))) > 1]
        differ_semantic = [f for f in differ if f not in ("message_raw", "data_raw")]
        observed = "indistinguishable" if not differ_semantic else "distinguishable"
        expected = "none (baseline)" if self.expect == "baseline" else "indistinguishable"
        if self.t0_ok is False:
            verdict = "77"
        elif self.expect == "baseline":
            verdict = "OBSERVED"
        else:
            verdict = "MATCH" if observed == "indistinguishable" else "DEVIATION"
        detail = (f"differs in: {differ or 'nothing'}; codes={fields['code']}; http={fields['http']}; "
                  f"normalized messages={fields['message_normalized']}")
        self.ev.row("T4", verdict, expected, observed, detail)


def same_shape(h):
    """A forged handle with the same length and character classes as `h`. Separators and the
    version prefix (`rs1.`, `v1.`) are kept, so the forgery reaches the integrity check instead of
    failing the format check."""
    try:
        uuid.UUID(h)
        return str(uuid.uuid4())
    except ValueError:
        pass
    prefix, dot, rest = h.partition(".")
    if not dot:
        prefix, rest = "", h
    out = [prefix + dot]
    for ch in rest:
        if ch.isdigit():
            out.append(random.choice(string.digits))
        elif ch.islower():
            out.append(random.choice(string.ascii_lowercase))
        elif ch.isupper():
            out.append(random.choice(string.ascii_uppercase))
        else:
            out.append(ch)
    return "".join(out)


def tampered(h):
    """A's own handle with one character in the middle of its body changed (same alphabet)."""
    i = len(h) // 2
    while not h[i].isalnum():
        i += 1
    alphabet = string.digits if h[i].isdigit() else (string.ascii_lowercase if h[i].islower() else string.ascii_uppercase)
    return h[:i] + random.choice([c for c in alphabet if c != h[i]]) + h[i + 1:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--placement", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-id", default=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    ap.add_argument("--tsv", default=None, help="defaults to <out>/measurements.tsv")
    ap.add_argument("--tests", default="T0,T1,T3a,T3b,T4")
    ap.add_argument("--expect", choices=["baseline", "refused"], required=True,
                    help="baseline for P0 (no expectation), refused for owner-enforcing placements")
    ap.add_argument("--expect-pc", choices=["baseline", "refused"],
                    help="expectation for the policy control PC (defaults to --expect)")
    ap.add_argument("--leaked-handle")
    ap.add_argument("--leak-source", default="unspecified")
    ap.add_argument("--leaked-upstream")
    ap.add_argument("--direct-url", help="TB: the server's Service URL, skipping the gateway")
    ap.add_argument("--expect-tb", choices=["reached", "blocked", "refused"], default="reached")
    ap.add_argument("--tr-seconds", type=int, default=25)
    ap.add_argument("--r8-stage", choices=["setup", "rotated", "removed"])
    ap.add_argument("--profile", choices=["lab", "official"], default="lab")
    ap.add_argument("--drain-node", default="k3d-drain-0-0")
    ap.add_argument("--delegate-url", help="TD: the gateway's delegation endpoint (P2); absent = hand over the raw ID")
    args = ap.parse_args()

    global PROFILE
    PROFILE = args.profile
    ev = Evidence(args.out, args.placement, args.run_id, args.tsv)
    token_url = os.environ["KC_TOKEN_URL"]
    A = Identity("A", token_url, os.environ.get("KC_CLIENT_A", "agent-a"), os.environ["KC_SECRET_A"],
                 os.environ.get("KC_USER_A", "alice"), os.environ["KC_PASS_A"]).login(ev)
    B = Identity("B", token_url, os.environ.get("KC_CLIENT_B", "agent-b"), os.environ["KC_SECRET_B"],
                 os.environ.get("KC_USER_B", "bob"), os.environ["KC_PASS_B"]).login(ev)
    C = None
    if os.environ.get("KC_SECRET_C"):
        C = Identity("C", token_url, os.environ.get("KC_CLIENT_C", "agent-c"), os.environ["KC_SECRET_C"],
                     os.environ.get("KC_USER_A", "alice"), os.environ["KC_PASS_A"]).login(ev)
    def optional(name, client, secret_env):
        if not os.environ.get(secret_env):
            return None
        return Identity(name, token_url, client, os.environ[secret_env], os.environ.get("KC_USER_A", "alice"),
                        os.environ["KC_PASS_A"]).login(ev)
    run = Run(Client(args.url, ev), A, B, ev, args.expect)

    tests = [t.strip() for t in args.tests.split(",") if t.strip()]
    ev.record({"event": "run-start", "url": args.url, "tests": tests, "expect": args.expect})
    # Every negative test is paired with the positive control in the same run (contract §1).
    setup_only = ("T0", "TL-setup", "TB") + (("R-8",) if args.r8_stage == "setup" else ())
    if any(t not in setup_only for t in tests) and "T0" not in tests:
        tests.insert(0, "T0")
    for t in tests:
        try:
            if t == "T0":
                run.t0()
            elif t == "T0-B":
                run.t0b()
            elif t == "T1":
                run.t1()
            elif t == "T3a":
                run.t3a()
            elif t == "T3b":
                run.t3b()
            elif t == "T4":
                run.t4()
            elif t == "TB":
                if not (args.direct_url and args.leaked_upstream):
                    ev.row("TB", "77", args.expect_tb, "setup-failed", "--direct-url and --leaked-upstream required")
                else:
                    run.tb(args.direct_url, args.leaked_upstream, args.expect_tb)
            elif t == "DRAIN":
                run.drain(args.drain_node, args.delegate_url)
            elif t == "TD":
                if C is None:
                    ev.row("TD", "77", "-", "setup-failed", "KC_SECRET_C not set")
                else:
                    run.td(C, args.delegate_url)
            elif t == "AUD":
                D = optional("D", "agent-noaud", "KC_SECRET_NOAUD")
                run.aud(D) if D else ev.row("AUD", "77", "-", "setup-failed", "KC_SECRET_NOAUD not set")
            elif t == "T2a-exp":
                Sx = optional("S", "agent-s", "KC_SECRET_S")
                run.t2a_exp(Sx) if Sx else ev.row("T2a-exp", "77", "-", "setup-failed", "KC_SECRET_S not set")
            elif t == "T2a":
                run.t2a()
            elif t == "T2b":
                run.t2b()
            elif t == "R-8":
                run.r8(args.r8_stage)
            elif t == "TR":
                run.tr(args.tr_seconds)
            elif t == "PC":
                if C is None:
                    ev.row("PC", "77", "-", "setup-failed", "KC_SECRET_C not set")
                else:
                    run.pc(C, args.expect_pc or args.expect)
            elif t == "TL-setup":
                run.tl_setup()
            elif t == "TL":
                if not args.leaked_handle:
                    ev.row("TL", "77", run.expected(), "setup-failed", "no leaked handle given")
                else:
                    run.tl(args.leaked_handle, args.leak_source, args.leaked_upstream)
            else:
                print(f"unknown test {t}", file=sys.stderr)
        except Exception as e:  # a broken step is inconclusive, never a result
            ev.row(t, "77", run.expected(), "error", f"{type(e).__name__}: {e}")
    ev.record({"event": "run-end"})


if __name__ == "__main__":
    main()
