//! P2: a thin owner-sealing proxy for MCP Tasks (2026-07-28) in front of an **unchanged** server.
//!
//! * Every request needs a bearer token valid for the configured issuer; the owner is (iss, sub, azp).
//! * `tools/call` → if the server answers with a task, its ID is replaced by a sealed handle:
//!   `v1.` + base64url(nonce ‖ XChaCha20-Poly1305(key, {v, target, upstream, owner, exp})).
//!   The handle is encrypted (R-1: the client never sees the upstream ID) and authenticated.
//! * `tasks/get · update · cancel` → the handle must open with the active or previous key, belong to the
//!   caller, not be expired, and match `Mcp-Name`. Both `params.taskId` and `Mcp-Name` are then
//!   translated to the upstream ID (R-5); IDs in the response are translated back.
//! * Every failure is answered byte-for-byte like the server's own unknown-task error (R-3, R-4).
//! * No shared state: any replica opens any handle (R-7); `x-ai1-replica` names the replica (TR).

#[path = "../../server/src/owner.rs"]
mod owner;

use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    body::{to_bytes, Body},
    extract::{Request, State},
    response::Response,
    routing::{get, post},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use chacha20poly1305::{
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
    XChaCha20Poly1305, XNonce,
};
use http::{HeaderMap, HeaderValue, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tracing::{info, warn};

use owner::{Owner, OwnerVerifier};

const AD: &[u8] = b"ai1-task-handle-v1";
const PREFIX: &str = "v1.";

#[derive(Serialize, Deserialize)]
struct Sealed {
    v: u8,
    target: String,
    upstream: String,
    owner: Owner,
    exp: u64,
    /// Delegated handle: the principal it was issued to, and the methods it allows. The owner
    /// keeps full rights on any handle of its task; a delegate gets only `rights`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    delegate: Option<Owner>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    rights: Vec<String>,
}

struct AppState {
    upstream_url: String,
    target: String,
    verifier: OwnerVerifier,
    active: XChaCha20Poly1305,
    previous: Option<XChaCha20Poly1305>,
    ttl_ceiling: Duration,
    ttl_margin: Duration,
    replica: String,
    http: reqwest::Client,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn key_from_env(name: &str) -> anyhow::Result<Option<XChaCha20Poly1305>> {
    let Some(v) = std::env::var(name).ok().filter(|v| !v.is_empty()) else { return Ok(None) };
    let raw = base64::engine::general_purpose::STANDARD.decode(v.trim())?;
    anyhow::ensure!(raw.len() == 32, "{name} must be 32 bytes (base64)");
    Ok(Some(XChaCha20Poly1305::new_from_slice(&raw).map_err(|e| anyhow::anyhow!("{e}"))?))
}

impl AppState {
    fn seal(&self, upstream: &str, owner: &Owner, ttl_ms: Option<u64>) -> String {
        let life = match ttl_ms {
            Some(ms) => (Duration::from_millis(ms) + self.ttl_margin).min(self.ttl_ceiling),
            None => self.ttl_ceiling,
        };
        self.seal_body(&Sealed {
            v: 1,
            target: self.target.clone(),
            upstream: upstream.to_string(),
            owner: owner.clone(),
            exp: now() + life.as_secs(),
            delegate: None,
            rights: vec![],
        })
    }

    fn seal_body(&self, body: &Sealed) -> String {
        let plain = serde_json::to_vec(body).expect("serializes");
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let ct = self.active.encrypt(&nonce, Payload { msg: &plain, aad: AD }).expect("encrypts");
        let mut out = nonce.to_vec();
        out.extend_from_slice(&ct);
        format!("{PREFIX}{}", B64.encode(out))
    }

    /// Opens a handle for `caller` and `method`; the reason is only logged, never returned.
    fn open(&self, handle: &str, caller: &Owner, method: &str) -> Result<String, &'static str> {
        let s = self.open_sealed(handle)?;
        if &s.owner == caller {
            return Ok(s.upstream);
        }
        match &s.delegate {
            Some(d) if d == caller && s.rights.iter().any(|r| r == method) => Ok(s.upstream),
            Some(d) if d == caller => Err("right not delegated"),
            _ => Err("foreign owner"),
        }
    }

    fn open_sealed(&self, handle: &str) -> Result<Sealed, &'static str> {
        let raw = handle.strip_prefix(PREFIX).ok_or("not a v1 handle")?;
        let bytes = B64.decode(raw).map_err(|_| "malformed")?;
        if bytes.len() < 24 + 16 {
            return Err("malformed");
        }
        let (nonce, ct) = bytes.split_at(24);
        let nonce = XNonce::from_slice(nonce);
        let payload = Payload { msg: ct, aad: AD };
        let plain = self
            .active
            .decrypt(nonce, payload)
            .or_else(|_| match &self.previous {
                Some(prev) => prev.decrypt(nonce, Payload { msg: ct, aad: AD }),
                None => Err(chacha20poly1305::aead::Error),
            })
            .map_err(|_| "does not open")?;
        let s: Sealed = serde_json::from_slice(&plain).map_err(|_| "bad payload")?;
        if s.v != 1 || s.target != self.target {
            return Err("wrong target");
        }
        if s.exp < now() {
            return Err("expired");
        }
        Ok(s)
    }
}

#[derive(Deserialize)]
struct DelegateRequest {
    handle: String,
    /// The delegate's (sub, azp); the issuer is the caller's own.
    sub: String,
    azp: String,
    rights: Vec<String>,
    #[serde(default)]
    ttl_secs: Option<u64>,
}

/// POST /delegate (lab endpoint of the gateway): the OWNER of a handle mints a delegated handle
/// for another principal with a subset of task methods. Anything else is answered 404, so a
/// non-owner learns nothing about the handle.
async fn delegate(State(st): State<Arc<AppState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let Ok(caller) = st.verifier.owner_from_parts(&parts).await else {
        return respond(StatusCode::UNAUTHORIZED, "text/plain", "authentication required".into(), &st.replica);
    };
    let not_found = || respond(StatusCode::NOT_FOUND, "text/plain", "not found".into(), &st.replica);
    let Ok(bytes) = to_bytes(body, 64 << 10).await else { return not_found() };
    let Ok(d) = serde_json::from_slice::<DelegateRequest>(&bytes) else { return not_found() };
    const ALLOWED: [&str; 3] = ["tasks/get", "tasks/update", "tasks/cancel"];
    if d.rights.is_empty() || d.rights.iter().any(|r| !ALLOWED.contains(&r.as_str())) {
        return not_found();
    }
    let Ok(s) = st.open_sealed(&d.handle) else { return not_found() };
    if s.owner != caller || s.delegate.is_some() {
        warn!(op = "delegate", reason = "not the owner", sub = %caller.sub, azp = %caller.azp, "refused");
        return not_found();
    }
    let exp = d.ttl_secs.map(|t| (now() + t).min(s.exp)).unwrap_or(s.exp);
    let delegate = Owner { iss: caller.iss.clone(), sub: d.sub, azp: d.azp };
    info!(op = "delegate", upstream = %s.upstream, to_sub = %delegate.sub, to_azp = %delegate.azp, rights = ?d.rights, "delegated handle issued");
    let handle = st.seal_body(&Sealed { delegate: Some(delegate), rights: d.rights, exp, ..s });
    respond(StatusCode::OK, "application/json", json!({ "handle": handle }).to_string().into(), &st.replica)
}

/// Byte-for-byte the error rmcp's server returns for an unknown task (HTTP 200, JSON-RPC -32602).
fn unknown_task(id: &Value, presented: &str, replica: &str) -> Response {
    let body = format!(
        r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32602,"message":{}}}}}"#,
        serde_json::to_string(id).unwrap(),
        serde_json::to_string(&format!("unknown task: {presented}")).unwrap()
    );
    respond(StatusCode::OK, "application/json", body.into(), replica)
}

fn respond(status: StatusCode, ctype: &str, body: Body, replica: &str) -> Response {
    let mut r = Response::new(body);
    *r.status_mut() = status;
    r.headers_mut().insert(http::header::CONTENT_TYPE, HeaderValue::from_str(ctype).unwrap());
    r.headers_mut().insert("x-ai1-replica", HeaderValue::from_str(replica).unwrap());
    r
}

fn header(h: &HeaderMap, n: &str) -> String {
    h.get(n).and_then(|v| v.to_str().ok()).unwrap_or("-").to_string()
}

async fn mcp(State(st): State<Arc<AppState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let mcp_method = header(&parts.headers, "mcp-method");
    let mcp_name = header(&parts.headers, "mcp-name");
    let res = handle(&st, parts, body).await;
    // Gateway-side access log: what this intermediary sees (sealed handles only).
    info!(target: "access", %mcp_method, %mcp_name, status = res.status().as_u16(), replica = %st.replica, "request");
    res
}

async fn handle(st: &AppState, parts: http::request::Parts, body: Body) -> Response {
    let caller = match st.verifier.owner_from_parts(&parts).await {
        Ok(o) => o,
        Err(e) => {
            return respond(StatusCode::UNAUTHORIZED, "text/plain", e.message.to_string().into(), &st.replica);
        }
    };
    let Ok(bytes) = to_bytes(body, 4 << 20).await else {
        return respond(StatusCode::BAD_REQUEST, "text/plain", "body too large".into(), &st.replica);
    };
    let Ok(mut msg) = serde_json::from_slice::<Value>(&bytes) else {
        return respond(StatusCode::BAD_REQUEST, "text/plain", "not JSON".into(), &st.replica);
    };
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("").to_string();
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    let mut headers = parts.headers.clone();

    let mut presented: Option<String> = None;
    if matches!(method.as_str(), "tasks/get" | "tasks/update" | "tasks/cancel") {
        let h = msg.pointer("/params/taskId").and_then(Value::as_str).unwrap_or("").to_string();
        if header(&parts.headers, "mcp-name") != h {
            warn!(op = %method, reason = "mcp-name-mismatch", sub = %caller.sub, azp = %caller.azp, "refused");
            return unknown_task(&id, &h, &st.replica);
        }
        match st.open(&h, &caller, &method) {
            Ok(up) => {
                msg["params"]["taskId"] = json!(up);
                headers.insert("mcp-name", HeaderValue::from_str(&up).unwrap());
                presented = Some(h);
            }
            Err(reason) => {
                warn!(op = %method, reason, sub = %caller.sub, azp = %caller.azp, "refused");
                return unknown_task(&id, &h, &st.replica);
            }
        }
    }

    // Forward to the unchanged server.
    let mut fwd = st.http.post(&st.upstream_url).body(serde_json::to_vec(&msg).unwrap());
    for n in ["content-type", "accept", "mcp-protocol-version", "mcp-method", "mcp-name", "authorization"] {
        if let Some(v) = headers.get(n) {
            fwd = fwd.header(n, v);
        }
    }
    let up = match fwd.send().await {
        Ok(r) => r,
        Err(e) => return respond(StatusCode::BAD_GATEWAY, "text/plain", e.to_string().into(), &st.replica),
    };
    let status = up.status();
    let ctype = up.headers().get(http::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("application/json").to_string();
    let raw = up.bytes().await.unwrap_or_default();
    let Ok(mut out) = serde_json::from_slice::<Value>(&raw) else {
        return respond(status, &ctype, raw.into(), &st.replica);
    };

    // Translate IDs in the response: seal new tasks, put the presented handle back for existing ones.
    if let Some(r) = out.get_mut("result") {
        if let Some(tid) = r.get("taskId").and_then(Value::as_str).map(str::to_string) {
            let handle = match &presented {
                Some(h) => h.clone(),
                None => {
                    let ttl = r.get("ttlMs").and_then(Value::as_u64);
                    let h = st.seal(&tid, &caller, ttl);
                    info!(op = "create", upstream = %tid, sub = %caller.sub, azp = %caller.azp, "task sealed");
                    h
                }
            };
            r["taskId"] = json!(handle);
        }
    }
    respond(status, &ctype, serde_json::to_vec(&out).unwrap().into(), &st.replica)
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let issuer = env("OIDC_ISSUER").expect("OIDC_ISSUER is required");
    let jwks = env("OIDC_JWKS_URL").unwrap_or_else(|| format!("{issuer}/protocol/openid-connect/certs"));
    let st = AppState {
        upstream_url: env("UPSTREAM_URL").expect("UPSTREAM_URL is required"),
        target: env("TARGET_NAME").unwrap_or_else(|| "shared".into()),
        verifier: OwnerVerifier::load(issuer, jwks).await?,
        active: key_from_env("SEAL_KEY_ACTIVE")?.expect("SEAL_KEY_ACTIVE is required"),
        previous: key_from_env("SEAL_KEY_PREVIOUS")?,
        ttl_ceiling: Duration::from_secs(env("HANDLE_TTL_CEILING_SECS").and_then(|v| v.parse().ok()).unwrap_or(86_400)),
        ttl_margin: Duration::from_secs(300),
        replica: env("HOSTNAME").unwrap_or_else(|| "unknown".into()),
        http: reqwest::Client::new(),
    };
    let app = Router::new()
        .route("/mcp", post(mcp))
        .route("/delegate", post(delegate))
        .route("/healthz", get(|| async { "ok" }))
        .with_state(Arc::new(st));
    let addr = env("LISTEN").unwrap_or_else(|| "0.0.0.0:8080".into());
    info!(%addr, "sealing proxy listening");
    axum::serve(tokio::net::TcpListener::bind(&addr).await?, app).await?;
    Ok(())
}
