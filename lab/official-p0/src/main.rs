//! P0-official: rmcp 3.5.1's official Tasks example **handler**, unmodified
//! (`src/common/task_demo.rs` is byte-identical to `examples/servers/src/common/task_demo.rs`
//! at tag `rmcp-v3.5.1`, git blob 30aed176…). The official example only ships a stdio
//! transport (`task_stdio.rs`); this file serves the same handler over streamable HTTP the way
//! rmcp's official `counter_streamhttp.rs` does, plus our access log (no authorization logic).
//!
//! `FACTORY=per-request` (default, as in `counter_streamhttp.rs`): `|| Ok(TaskDemo::new())`, a new
//! handler, and so a new TaskManager, per request.
//! `FACTORY=shared`: one TaskDemo, cloned per request (its TaskManager is shared).

mod common;

use common::task_demo::TaskDemo;
use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use tracing::info;

fn header_str(headers: &http::HeaderMap, name: &str) -> String {
    headers.get(name).and_then(|v| v.to_str().ok()).unwrap_or("-").to_string()
}

async fn access_log(req: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    let mcp_method = header_str(req.headers(), "mcp-method");
    let mcp_name = header_str(req.headers(), "mcp-name");
    let http_method = req.method().to_string();
    let res = next.run(req).await;
    info!(target: "access", %http_method, %mcp_method, %mcp_name, status = res.status().as_u16(), "request");
    res
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let shared = std::env::var("FACTORY").as_deref() == Ok("shared");
    let hosts: Vec<String> = std::env::var("ALLOWED_HOSTS")
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect())
        .unwrap_or_else(|_| vec!["localhost".into(), "127.0.0.1".into()]);
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_allowed_hosts(hosts);
    let demo = TaskDemo::new();
    let service = if shared {
        StreamableHttpService::new(move || Ok(demo.clone()), LocalSessionManager::default().into(), config)
    } else {
        StreamableHttpService::new(|| Ok(TaskDemo::new()), LocalSessionManager::default().into(), config)
    };
    let app = axum::Router::new()
        .nest_service("/mcp", service)
        .layer(axum::middleware::from_fn(access_log))
        .route("/healthz", axum::routing::get(|| async { "ok" }));
    info!(factory = if shared { "shared" } else { "per-request" }, "official task demo over HTTP on 0.0.0.0:8080");
    axum::serve(tokio::net::TcpListener::bind("0.0.0.0:8080").await?, app).await?;
    Ok(())
}
