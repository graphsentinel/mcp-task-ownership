//! P-agw-2995: the P2 owner-sealing rule as an agentgateway `mcpGuardrails` (ExtMcp) processor.
//!
//! agentgateway PR #2995 runs guardrail processors on `tasks/get|update|cancel` (request phase);
//! v1.6.0 did not. The gateway validates the JWT and passes the caller to us as CEL metadata
//! (`iss`, `sub`, `azp` = `jwt.iss`, `jwt.sub`, `jwt.azp`), so we never parse tokens here.
//!
//! * Response phase (`tools/call`, `tasks/*`): a `taskId` in the result is replaced by
//!   `v1.` + base64url(nonce ‖ XChaCha20-Poly1305(key, {v, target, upstream, owner, exp})), the same
//!   handle format as the P2 proxy.
//! * Request phase (`tasks/*`): the handle is opened; the caller must be its owner. On success the
//!   params get the upstream id and `Mcp-Name` is rewritten; otherwise the processor returns the same
//!   JSON-RPC error the upstream gives for an unknown task (`-32602`, "unknown task: <presented>").

use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use chacha20poly1305::{
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
    XChaCha20Poly1305, XNonce,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};
use tonic::{Request, Response, Status};
use tracing::{info, warn};

pub mod pb {
    tonic::include_proto!("agentgateway.dev.ext_mcp");
}
use pb::ext_mcp_server::{ExtMcp, ExtMcpServer};
use pb::{
    authorization_error::Code, mcp_request_result, mcp_response_result, AuthorizationError, HeaderMutation, McpHeader,
    McpRequest, McpRequestResult, McpResponse, McpResponseResult, Pass,
};

const AD: &[u8] = b"ai1-task-handle-v1";
const PREFIX: &str = "v1.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Owner {
    iss: String,
    sub: String,
    azp: String,
}

#[derive(Serialize, Deserialize)]
struct Sealed {
    v: u8,
    target: String,
    upstream: String,
    owner: Owner,
    exp: u64,
}

struct Seal {
    active: XChaCha20Poly1305,
    target: String,
    ttl_secs: u64,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

impl Seal {
    fn seal(&self, upstream: &str, owner: &Owner) -> String {
        let body = Sealed { v: 1, target: self.target.clone(), upstream: upstream.into(), owner: owner.clone(), exp: now() + self.ttl_secs };
        let plain = serde_json::to_vec(&body).expect("serializes");
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let ct = self.active.encrypt(&nonce, Payload { msg: &plain, aad: AD }).expect("encrypts");
        let mut out = nonce.to_vec();
        out.extend_from_slice(&ct);
        format!("{PREFIX}{}", B64.encode(out))
    }

    fn open(&self, handle: &str, caller: &Owner) -> Result<String, &'static str> {
        let raw = handle.strip_prefix(PREFIX).ok_or("not a v1 handle")?;
        let bytes = B64.decode(raw).map_err(|_| "malformed")?;
        if bytes.len() < 24 + 16 {
            return Err("malformed");
        }
        let (nonce, ct) = bytes.split_at(24);
        let plain = self.active.decrypt(XNonce::from_slice(nonce), Payload { msg: ct, aad: AD }).map_err(|_| "does not open")?;
        let s: Sealed = serde_json::from_slice(&plain).map_err(|_| "bad payload")?;
        if s.v != 1 || s.target != self.target {
            return Err("wrong target");
        }
        if s.exp < now() {
            return Err("expired");
        }
        if &s.owner != caller {
            return Err("foreign owner");
        }
        Ok(s.upstream)
    }
}

fn caller(meta: &Option<prost_types::Struct>) -> Option<Owner> {
    let f = &meta.as_ref()?.fields;
    let s = |k: &str| match f.get(k)?.kind.as_ref()? {
        prost_types::value::Kind::StringValue(v) if !v.is_empty() => Some(v.clone()),
        _ => None,
    };
    Some(Owner { iss: s("iss")?, sub: s("sub")?, azp: s("azp")? })
}

fn unknown_task(presented: &str) -> McpRequestResult {
    let err = serde_json::json!({"code": -32602, "message": format!("unknown task: {presented}")});
    McpRequestResult {
        result: Some(mcp_request_result::Result::Error(AuthorizationError {
            code: Code::Invalid as i32,
            reason: "unknown task".into(),
            mcp_error: Some(serde_json::to_vec(&err).unwrap()),
        })),
        header_mutation: None,
        metadata: None,
    }
}

fn pass() -> McpRequestResult {
    McpRequestResult { result: Some(mcp_request_result::Result::Pass(Pass {})), header_mutation: None, metadata: None }
}

struct Svc {
    seal: Seal,
}

#[tonic::async_trait]
impl ExtMcp for Svc {
    async fn check_request(&self, req: Request<McpRequest>) -> Result<Response<McpRequestResult>, Status> {
        let r = req.into_inner();
        if !matches!(r.method.as_str(), "tasks/get" | "tasks/update" | "tasks/cancel") {
            return Ok(Response::new(pass()));
        }
        let mut params: Value = match r.mcp_request.as_deref().map(serde_json::from_slice) {
            Some(Ok(v)) => v,
            _ => return Ok(Response::new(unknown_task(""))),
        };
        let presented = params.get("taskId").and_then(Value::as_str).unwrap_or("").to_string();
        let Some(who) = caller(&r.metadata_context) else {
            warn!(method = %r.method, reason = "no caller in metadata", "refused");
            return Ok(Response::new(unknown_task(&presented)));
        };
        match self.seal.open(&presented, &who) {
            Ok(upstream) => {
                params["taskId"] = Value::String(upstream.clone());
                info!(method = %r.method, sub = %who.sub, azp = %who.azp, "handle opened");
                Ok(Response::new(McpRequestResult {
                    result: Some(mcp_request_result::Result::Mutated(serde_json::to_vec(&params).unwrap())),
                    header_mutation: Some(HeaderMutation {
                        set: vec![McpHeader { key: "mcp-name".into(), value: upstream.into_bytes() }],
                        remove: vec![],
                    }),
                    metadata: None,
                }))
            },
            Err(reason) => {
                warn!(method = %r.method, reason, sub = %who.sub, azp = %who.azp, "refused");
                Ok(Response::new(unknown_task(&presented)))
            },
        }
    }

    async fn check_response(&self, req: Request<McpResponse>) -> Result<Response<McpResponseResult>, Status> {
        let r = req.into_inner();
        let passthrough = McpResponseResult { result: Some(mcp_response_result::Result::Pass(Pass {})) };
        let Ok(mut result) = serde_json::from_slice::<Value>(&r.mcp_response) else { return Ok(Response::new(passthrough)) };
        let Some(upstream) = result.get("taskId").and_then(Value::as_str).map(str::to_string) else {
            return Ok(Response::new(passthrough));
        };
        let Some(who) = caller(&r.metadata_context) else {
            warn!(method = %r.method, reason = "no caller in metadata", "task id left unsealed");
            return Ok(Response::new(passthrough));
        };
        result["taskId"] = Value::String(self.seal.seal(&upstream, &who));
        info!(method = %r.method, sub = %who.sub, azp = %who.azp, "task id sealed");
        Ok(Response::new(McpResponseResult {
            result: Some(mcp_response_result::Result::Mutated(serde_json::to_vec(&result).unwrap())),
        }))
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_ansi(false).init();
    let key = std::env::var("SEAL_KEY_ACTIVE")?;
    let raw = base64::engine::general_purpose::STANDARD.decode(key.trim())?;
    anyhow::ensure!(raw.len() == 32, "SEAL_KEY_ACTIVE must be 32 bytes (base64)");
    let seal = Seal {
        active: XChaCha20Poly1305::new_from_slice(&raw).map_err(|e| anyhow::anyhow!("{e}"))?,
        target: std::env::var("SEAL_TARGET").unwrap_or_else(|_| "shared".into()),
        ttl_secs: std::env::var("SEAL_TTL_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(3600),
    };
    let addr = "0.0.0.0:9000".parse()?;
    info!(%addr, "ext-seal listening");
    tonic::transport::Server::builder().add_service(ExtMcpServer::new(Svc { seal })).serve(addr).await?;
    Ok(())
}
