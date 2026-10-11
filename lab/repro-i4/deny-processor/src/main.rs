//! Repro for issue I-4: an agentgateway `mcpGuardrails` (ExtMcp) processor that refuses every request it is asked
//! about, with an explicit `mcp_error`, so the shape of the error the client receives can be compared with the
//! proto comment ("Optional explicit JSON-RPC error payload, as raw JSON bytes. Overrides the code-derived default.").
//!
//! Refusal: `AuthorizationError { code: INVALID, reason: REASON, mcp_error: {"code": -32602, "message": MESSAGE} }`.
//! Responses are always passed through. Listens on 0.0.0.0:9000.

use tonic::{Request, Response, Status};
use tracing::info;

pub mod pb {
    tonic::include_proto!("agentgateway.dev.ext_mcp");
}
use pb::ext_mcp_server::{ExtMcp, ExtMcpServer};
use pb::{
    authorization_error::Code, mcp_request_result, mcp_response_result, AuthorizationError, McpRequest,
    McpRequestResult, McpResponse, McpResponseResult, Pass,
};

const REASON: &str = "denied by repro processor";
const MESSAGE: &str = "custom error from processor";

struct Svc;

#[tonic::async_trait]
impl ExtMcp for Svc {
    async fn check_request(&self, req: Request<McpRequest>) -> Result<Response<McpRequestResult>, Status> {
        let method = req.into_inner().method;
        let mcp_error = serde_json::json!({"code": -32602, "message": MESSAGE});
        info!(%method, "refused");
        Ok(Response::new(McpRequestResult {
            result: Some(mcp_request_result::Result::Error(AuthorizationError {
                code: Code::Invalid as i32,
                reason: REASON.into(),
                mcp_error: Some(serde_json::to_vec(&mcp_error).unwrap()),
            })),
            header_mutation: None,
            metadata: None,
        }))
    }

    async fn check_response(&self, _req: Request<McpResponse>) -> Result<Response<McpResponseResult>, Status> {
        Ok(Response::new(McpResponseResult { result: Some(mcp_response_result::Result::Pass(Pass {})) }))
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_ansi(false).init();
    let addr = "0.0.0.0:9000".parse()?;
    info!(%addr, "deny-processor listening");
    tonic::transport::Server::builder().add_service(ExtMcpServer::new(Svc)).serve(addr).await?;
    Ok(())
}
