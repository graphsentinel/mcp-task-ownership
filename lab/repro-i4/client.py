"""I-4 repro client (Python standard library only): initialize, then tools/call and resources/read through the
gateway; prints each raw HTTP status and JSON-RPC body."""
import json, sys, urllib.request

URL = sys.argv[1] if len(sys.argv) > 1 else "http://agw-i4.i4-repro.svc.cluster.local:8080/mcp"
HDR = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
session = {}


def post(msg):
    h = dict(HDR, **session)
    req = urllib.request.Request(URL, json.dumps(msg).encode(), h)
    try:
        r = urllib.request.urlopen(req, timeout=20)
        status, headers, body = r.status, r.headers, r.read().decode()
    except urllib.error.HTTPError as e:
        status, headers, body = e.code, e.headers, e.read().decode()
    if headers.get("mcp-session-id"):
        session["Mcp-Session-Id"] = headers["mcp-session-id"]
    # streamable HTTP may answer as SSE: take the data line(s)
    data = [l[5:].strip() for l in body.splitlines() if l.startswith("data:")]
    return status, (json.loads(data[-1]) if data else (json.loads(body) if body.strip() else None))


init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "i4-repro", "version": "1"}}}
st, _ = post(init)
print("initialize HTTP", st)
post({"jsonrpc": "2.0", "method": "notifications/initialized"})
for i, (method, params) in enumerate([("tools/call", {"name": "cluster_audit", "arguments": {}}),
                                      ("resources/read", {"uri": "file:///anything"})], start=2):
    st, body = post({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    print(f"\n{method} HTTP {st}")
    print(json.dumps(body, indent=1))
