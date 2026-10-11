//! MCP Tasks (2026-07-28) test server built on rmcp 3.5.1.
//!
//! One binary, two placements, selected with `OWNERSHIP_MODE`:
//!
//! * `p0` — written like rmcp's official Tasks example (`examples/servers/src/common/task_demo.rs`):
//!   `tasks/get`, `tasks/update` and `tasks/cancel` ignore the request context. This is the
//!   baseline (P0) of the measurement contract.
//! * `p1` — the same server with an owner-sealing wrapper around the `TaskManager` handlers.
//!   The caller is taken from the validated bearer token (iss, sub, azp). The upstream task ID
//!   is sealed to that owner with rmcp's own `RequestStateCodec` (the SDK's integrity helper
//!   for MRTR `requestState`), and every task request must present a handle that opens for the
//!   same owner. Any failure is answered exactly like an unknown task.
//!
//! Tools (both always run as tasks when the client declares the tasks extension):
//! * `cluster_audit { label, seconds }` — sleeps, then returns a result that echoes `label`.
//! * `backup { label }` — asks for confirmation through an `input_required` elicitation, then
//!   returns the answer it received.

mod kube;
mod owner;

use std::{sync::Arc, time::Duration};

use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    schemars,
    service::{RequestContext, RoleServer},
    task_manager::{TaskExit, TaskManager, TaskOptions},
    tool, tool_router,
    transport::streamable_http_server::{
        session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
    },
    ErrorData as McpError, ServerHandler,
};
use serde_json::json;
use tracing::{info, warn};

use owner::{Owner, OwnerVerifier};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    P0,
    P1,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct AuditArgs {
    /// Free text echoed in the result, so the driver can tell whose result it received.
    pub label: String,
    /// How long the task stays `working`.
    #[serde(default = "default_seconds")]
    pub seconds: u64,
}

fn default_seconds() -> u64 {
    5
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct SlowArgs {
    /// How long the task stays `working`.
    #[serde(default)]
    pub seconds: u64,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct DrainArgs {
    /// Node to drain.
    pub node: String,
    /// Free text echoed in the prompt and the result.
    pub label: String,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct BackupArgs {
    /// Free text echoed in the confirmation prompt and the result.
    pub label: String,
}

#[derive(Clone)]
pub struct Lab {
    tool_router: ToolRouter<Lab>,
    tasks: TaskManager,
    mode: Mode,
    owners: Option<Arc<OwnerVerifier>>,
    codec: Option<Arc<RequestStateCodec>>,
    handle_ttl: Duration,
    kube: Option<Arc<kube::Kube>>,
}

/// Exactly the error rmcp's `TaskManager` returns for an unknown task ID
/// (`task_manager.rs`: `McpError::invalid_params(format!("unknown task: {task_id}"), None)`).
fn unknown_task(task_id: &str) -> McpError {
    McpError::invalid_params(format!("unknown task: {task_id}"), None)
}

#[tool_router]
impl Lab {
    fn new(
        tasks: TaskManager,
        mode: Mode,
        owners: Option<Arc<OwnerVerifier>>,
        codec: Option<Arc<RequestStateCodec>>,
        handle_ttl: Duration,
    ) -> Self {
        Self { tool_router: Self::tool_router(), tasks, mode, owners, codec, handle_ttl, kube: kube::Kube::in_cluster().map(Arc::new) }
    }

    /// Long-running audit; runs as a task.
    #[tool(description = "Audit the cluster (long-running; runs as a task)")]
    async fn cluster_audit(&self, Parameters(_a): Parameters<AuditArgs>) -> Result<CallToolResult, McpError> {
        Err(McpError::invalid_request("cluster_audit must run as a task: declare the tasks extension", None))
    }

    /// Fixture expected by the MCP conformance suite's task scenarios.
    #[tool(description = "Sleep `seconds`, then return a result (conformance fixture; runs as a task)")]
    async fn slow_compute(&self, Parameters(_a): Parameters<SlowArgs>) -> Result<CallToolResult, McpError> {
        Err(McpError::invalid_request("slow_compute must run as a task: declare the tasks extension", None))
    }

    /// Drain a Kubernetes node; asks before breaking a PodDisruptionBudget. Runs as a task.
    #[tool(description = "Drain a Kubernetes node (cordon, evict; asks before breaking a PodDisruptionBudget; runs as a task)")]
    async fn node_drain(&self, Parameters(_a): Parameters<DrainArgs>) -> Result<CallToolResult, McpError> {
        Err(McpError::invalid_request("node_drain must run as a task: declare the tasks extension", None))
    }

    /// Backup that asks for confirmation; runs as a task.
    #[tool(description = "Back up a database after confirmation (runs as a task)")]
    async fn backup(&self, Parameters(_a): Parameters<BackupArgs>) -> Result<CallToolResult, McpError> {
        Err(McpError::invalid_request("backup must run as a task: declare the tasks extension", None))
    }
}

impl Lab {
    /// P1: the authenticated caller, or an error if there is no valid bearer token.
    async fn caller(&self, ctx: &RequestContext<RoleServer>) -> Result<Owner, McpError> {
        let verifier = self.owners.as_ref().expect("P1 has a verifier");
        let parts = ctx
            .extensions
            .get::<http::request::Parts>()
            .ok_or_else(|| McpError::invalid_request("authentication required", None))?;
        verifier.owner_from_parts(parts).await
    }

    /// P1: the `Mcp-Name` header must carry the same task ID as the body.
    fn mcp_name_matches(ctx: &RequestContext<RoleServer>, presented: &str) -> bool {
        ctx.extensions
            .get::<http::request::Parts>()
            .and_then(|p| p.headers.get("mcp-name"))
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v == presented)
    }

    fn seal(&self, upstream_id: &str, owner: &Owner) -> String {
        let codec = self.codec.as_ref().expect("P1 has a codec");
        let ad = owner.associated_data();
        codec.seal_with(
            upstream_id.as_bytes(),
            &SealOptions::new().associated_data(&ad).ttl(self.handle_ttl),
        )
    }

    /// P1: open a presented handle for the current caller. Every failure (no token, foreign
    /// owner, forged or expired handle, header/body mismatch) except a missing token is answered
    /// exactly like an unknown task.
    async fn open(&self, presented: &str, ctx: &RequestContext<RoleServer>, op: &str) -> Result<String, McpError> {
        let owner = self.caller(ctx).await?;
        if !Self::mcp_name_matches(ctx, presented) {
            warn!(op, reason = "mcp-name-mismatch", sub = %owner.sub, azp = %owner.azp, "refused");
            return Err(unknown_task(presented));
        }
        let codec = self.codec.as_ref().expect("P1 has a codec");
        match codec.open_with(presented, &owner.associated_data()) {
            Ok(bytes) => String::from_utf8(bytes).map_err(|_| unknown_task(presented)),
            Err(e) => {
                warn!(op, reason = %e, sub = %owner.sub, azp = %owner.azp, "refused");
                Err(unknown_task(presented))
            }
        }
    }

    fn spawn_tool(&self, request: &CallToolRequestParams) -> Result<Task, McpError> {
        let args = serde_json::Value::Object(request.arguments.clone().unwrap_or_default());
        let options = TaskOptions::new().with_ttl_ms(600_000u64).with_poll_interval_ms(500);
        match request.name.as_ref() {
            "cluster_audit" => {
                let a: AuditArgs =
                    serde_json::from_value(args).map_err(|e| McpError::invalid_params(e.to_string(), None))?;
                Ok(self.tasks.spawn(options, move |tctx| {
                    Box::pin(async move {
                        tokio::select! {
                            _ = tctx.cancelled() => Err(TaskExit::Cancelled),
                            _ = tokio::time::sleep(Duration::from_secs(a.seconds)) => {
                                Ok(CallToolResult::success(vec![ContentBlock::text(
                                    format!("audit complete; label={}", a.label),
                                )]))
                            }
                        }
                    })
                }))
            }
            "backup" => {
                let a: BackupArgs =
                    serde_json::from_value(args).map_err(|e| McpError::invalid_params(e.to_string(), None))?;
                let prompt: InputRequest = serde_json::from_value(json!({
                    "method": "elicitation/create",
                    "params": {
                        "message": format!("Continue with the backup of {}?", a.label),
                        "requestedSchema": {
                            "type": "object",
                            "properties": { "confirm": { "type": "boolean" }, "by": { "type": "string" } },
                            "required": ["confirm"]
                        }
                    }
                }))
                .map_err(|e| McpError::internal_error(e.to_string(), None))?;
                Ok(self.tasks.spawn(options, move |tctx| {
                    Box::pin(async move {
                        let answer = tctx.request_input("confirm", prompt).await?;
                        Ok(CallToolResult::success(vec![ContentBlock::text(format!(
                            "backup label={} answer={}",
                            a.label, answer
                        ))]))
                    })
                }))
            }
            "slow_compute" => {
                let a: SlowArgs =
                    serde_json::from_value(args).map_err(|e| McpError::invalid_params(e.to_string(), None))?;
                Ok(self.tasks.spawn(options, move |tctx| {
                    Box::pin(async move {
                        tokio::select! {
                            _ = tctx.cancelled() => Err(TaskExit::Cancelled),
                            _ = tokio::time::sleep(Duration::from_secs(a.seconds)) => {
                                Ok(CallToolResult::success(vec![ContentBlock::text(format!("computed after {}s", a.seconds))]))
                            }
                        }
                    })
                }))
            }
            "node_drain" => {
                let a: DrainArgs =
                    serde_json::from_value(args).map_err(|e| McpError::invalid_params(e.to_string(), None))?;
                let kube = self.kube.clone().ok_or_else(|| McpError::invalid_request("node_drain needs an in-cluster ServiceAccount", None))?;
                Ok(self.tasks.spawn(options, move |tctx| {
                    Box::pin(async move {
                        let fail = |e: anyhow::Error| TaskExit::Error(McpError::internal_error(e.to_string(), None));
                        kube.set_unschedulable(&a.node, true).await.map_err(fail)?;
                        let mut blocked = vec![];
                        let mut evicted = 0;
                        for pod in kube.pods_on(&a.node).await.map_err(fail)? {
                            if kube.evict(&pod).await.map_err(fail)? { evicted += 1 } else { blocked.push(pod) }
                        }
                        if blocked.is_empty() {
                            return Ok(CallToolResult::success(vec![ContentBlock::text(format!(
                                "drained node={} label={} evicted={evicted}", a.node, a.label))]));
                        }
                        let names: Vec<String> = blocked.iter().map(|p| format!("{}/{}", p.namespace, p.name)).collect();
                        let prompt: InputRequest = serde_json::from_value(json!({
                            "method": "elicitation/create",
                            "params": {
                                "message": format!("Draining {} ({}) would break a PodDisruptionBudget for {}. Force the drain?", a.node, a.label, names.join(", ")),
                                "requestedSchema": {
                                    "type": "object",
                                    "properties": { "confirm": { "type": "boolean" }, "by": { "type": "string" } },
                                    "required": ["confirm"]
                                }
                            }
                        })).map_err(|e| fail(e.into()))?;
                        let answer = tctx.request_input("confirm", prompt).await?;
                        let by = answer["content"]["by"].as_str().unwrap_or("?").to_string();
                        let accepted = answer["action"] == "accept" && answer["content"]["confirm"] == true;
                        if accepted {
                            for pod in &blocked {
                                kube.delete(pod).await.map_err(fail)?;
                            }
                            Ok(CallToolResult::success(vec![ContentBlock::text(format!(
                                "drain FORCED node={} label={} by={by} deleted={} (PodDisruptionBudget broken)", a.node, a.label, blocked.len()))]))
                        } else {
                            kube.set_unschedulable(&a.node, false).await.map_err(fail)?;
                            Ok(CallToolResult::success(vec![ContentBlock::text(format!(
                                "drain ABORTED node={} label={} by={by}; node uncordoned", a.node, a.label))]))
                        }
                    })
                }))
            }
            other => Err(McpError::invalid_params(format!("unknown tool: {other}"), None)),
        }
    }
}

impl ServerHandler for Lab {
    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let client_supports_tasks = context.client_capabilities().is_some_and(|caps| caps.supports_tasks());
        if !client_supports_tasks {
            let tcc = rmcp::handler::server::tool::ToolCallContext::new(self, request, context);
            return self.tool_router.call(tcc).await;
        }
        match self.mode {
            Mode::P0 => {
                let task = self.spawn_tool(&request)?;
                info!(op = "create", mode = "p0", task_id = %task.task_id, tool = %request.name, "task created");
                Ok(CallToolResponse::Task(CreateTaskResult::new(task)))
            }
            Mode::P1 => {
                let owner = self.caller(&context).await?;
                let mut task = self.spawn_tool(&request)?;
                let upstream = task.task_id.clone();
                task.task_id = self.seal(&upstream, &owner);
                info!(op = "create", mode = "p1", upstream = %upstream, sub = %owner.sub, azp = %owner.azp, tool = %request.name, "task created");
                Ok(CallToolResponse::Task(CreateTaskResult::new(task)))
            }
        }
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult::with_all_items(self.tool_router.list_all()))
    }

    async fn get_task(&self, request: GetTaskParams, context: RequestContext<RoleServer>) -> Result<GetTaskResult, McpError> {
        match self.mode {
            Mode::P0 => Ok(GetTaskResult::new(self.tasks.get_task(&request.task_id)?)),
            Mode::P1 => {
                let presented = request.task_id.clone();
                let upstream = self.open(&presented, &context, "get").await?;
                let mut detailed = self.tasks.get_task(&upstream).map_err(|_| unknown_task(&presented))?;
                detailed.task.task_id = presented;
                Ok(GetTaskResult::new(detailed))
            }
        }
    }

    async fn update_task(&self, request: UpdateTaskParams, context: RequestContext<RoleServer>) -> Result<(), McpError> {
        match self.mode {
            Mode::P0 => self.tasks.update_task(&request.task_id, request.input_responses),
            Mode::P1 => {
                let presented = request.task_id.clone();
                let upstream = self.open(&presented, &context, "update").await?;
                self.tasks
                    .update_task(&upstream, request.input_responses)
                    .map_err(|_| unknown_task(&presented))
            }
        }
    }

    async fn cancel_task(&self, request: CancelTaskParams, context: RequestContext<RoleServer>) -> Result<(), McpError> {
        match self.mode {
            Mode::P0 => self.tasks.cancel_task(&request.task_id),
            Mode::P1 => {
                let presented = request.task_id.clone();
                let upstream = self.open(&presented, &context, "cancel").await?;
                self.tasks.cancel_task(&upstream).map_err(|_| unknown_task(&presented))
            }
        }
    }

    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_tasks().build())
            .with_instructions(format!("AI1 task-ownership lab server, mode {:?}", self.mode))
    }
}

/// Access log of what an intermediary sees: the routing headers the specification puts on every
/// request (`Mcp-Method`, `Mcp-Name`) and the HTTP status. No authorization logic. The leaked-handle
/// test (TL) takes the owner's handle from this log.
async fn access_log(req: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    let mcp_method = header_str(req.headers(), "mcp-method");
    let mcp_name = header_str(req.headers(), "mcp-name");
    let http_method = req.method().to_string();
    let res = next.run(req).await;
    info!(target: "access", %http_method, %mcp_method, %mcp_name, status = res.status().as_u16(), "request");
    res
}

fn header_str(headers: &http::HeaderMap, name: &str) -> String {
    headers.get(name).and_then(|v| v.to_str().ok()).unwrap_or("-").to_string()
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let mode = match env("OWNERSHIP_MODE").as_deref() {
        Some("p1") => Mode::P1,
        _ => Mode::P0,
    };
    let (owners, codec) = if mode == Mode::P1 {
        let issuer = env("OIDC_ISSUER").expect("OIDC_ISSUER is required in p1");
        let jwks = env("OIDC_JWKS_URL").unwrap_or_else(|| format!("{issuer}/protocol/openid-connect/certs"));
        let key = env("SEAL_KEY").expect("SEAL_KEY (>= 32 bytes) is required in p1");
        let verifier = OwnerVerifier::load(issuer, jwks).await?;
        let codec = RequestStateCodec::try_new(key.into_bytes()).map_err(|e| anyhow::anyhow!("{e}"))?;
        (Some(Arc::new(verifier)), Some(Arc::new(codec)))
    } else {
        (None, None)
    };
    let handle_ttl = Duration::from_secs(env("HANDLE_TTL_SECS").and_then(|v| v.parse().ok()).unwrap_or(3600));

    let tasks = TaskManager::new();
    let lab = Lab::new(tasks, mode, owners, codec, handle_ttl);

    let allowed_hosts: Vec<String> = env("ALLOWED_HOSTS")
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect())
        .unwrap_or_else(|| vec!["localhost".into(), "127.0.0.1".into()]);
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_allowed_hosts(allowed_hosts);
    let service = StreamableHttpService::new(move || Ok(lab.clone()), Arc::new(LocalSessionManager::default()), config);

    let app = axum::Router::new()
        .nest_service("/mcp", service)
        .layer(axum::middleware::from_fn(access_log))
        .route("/healthz", axum::routing::get(|| async { "ok" }));
    let addr = env("LISTEN").unwrap_or_else(|| "0.0.0.0:8080".into());
    info!(?mode, %addr, "listening");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
