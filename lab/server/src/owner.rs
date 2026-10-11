//! Caller identity for P1: validate the bearer token against the identity provider's JWKS and
//! derive the task owner as (iss, sub, azp).

use std::collections::HashMap;

use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use rmcp::ErrorData as McpError;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use tracing::{info, warn};

/// The owner bound into a sealed task handle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    pub iss: String,
    pub sub: String,
    pub azp: String,
}

impl Owner {
    /// Structured encoding used as associated data: a JSON object with fixed field order, so
    /// no field can be confused with another (no delimiter concatenation).
    pub fn associated_data(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("owner serializes")
    }
}

#[derive(Debug, Deserialize)]
struct Claims {
    iss: String,
    sub: Option<String>,
    azp: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Jwk {
    kid: Option<String>,
    kty: String,
    n: Option<String>,
    e: Option<String>,
    #[serde(rename = "use")]
    use_: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Jwks {
    keys: Vec<Jwk>,
}

pub struct OwnerVerifier {
    issuer: String,
    jwks_url: String,
    keys: RwLock<HashMap<String, DecodingKey>>,
}

fn auth_error(msg: &str) -> McpError {
    McpError::invalid_request(format!("authentication required: {msg}"), None)
}

impl OwnerVerifier {
    pub async fn load(issuer: String, jwks_url: String) -> anyhow::Result<Self> {
        let v = Self { issuer, jwks_url, keys: RwLock::new(HashMap::new()) };
        // The identity provider may start after us; retry for a while.
        for attempt in 1..=60 {
            match v.refresh().await {
                Ok(n) if n > 0 => {
                    info!(keys = n, url = %v.jwks_url, "JWKS loaded");
                    return Ok(v);
                }
                Ok(_) => warn!(attempt, "JWKS empty"),
                Err(e) => warn!(attempt, error = %e, "JWKS fetch failed"),
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
        anyhow::bail!("could not load JWKS from {}", v.jwks_url)
    }

    async fn refresh(&self) -> anyhow::Result<usize> {
        let jwks: Jwks = reqwest::get(&self.jwks_url).await?.error_for_status()?.json().await?;
        let mut map = HashMap::new();
        for k in jwks.keys {
            if k.kty != "RSA" || k.use_.as_deref() == Some("enc") {
                continue;
            }
            if let (Some(kid), Some(n), Some(e)) = (k.kid, k.n, k.e) {
                map.insert(kid, DecodingKey::from_rsa_components(&n, &e)?);
            }
        }
        let n = map.len();
        *self.keys.write().await = map;
        Ok(n)
    }

    pub async fn owner_from_parts(&self, parts: &http::request::Parts) -> Result<Owner, McpError> {
        let header = parts
            .headers
            .get(http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| auth_error("missing Authorization header"))?;
        let token = header
            .strip_prefix("Bearer ")
            .or_else(|| header.strip_prefix("bearer "))
            .ok_or_else(|| auth_error("not a bearer token"))?;
        let kid = decode_header(token)
            .map_err(|_| auth_error("malformed token"))?
            .kid
            .ok_or_else(|| auth_error("token has no kid"))?;

        let mut key = self.keys.read().await.get(&kid).cloned();
        if key.is_none() {
            let _ = self.refresh().await;
            key = self.keys.read().await.get(&kid).cloned();
        }
        let key = key.ok_or_else(|| auth_error("unknown signing key"))?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[self.issuer.as_str()]);
        // Audience: enforced when OIDC_AUDIENCE is set (config v2: aud=task-server); off otherwise.
        match std::env::var("OIDC_AUDIENCE").ok().filter(|v| !v.is_empty()) {
            Some(aud) => {
                validation.set_audience(&[aud]);
                // jsonwebtoken checks `aud` only when the claim is present; make it required.
                validation.set_required_spec_claims(&["exp", "iss", "aud"]);
            }
            None => validation.validate_aud = false,
        }
        let data = decode::<Claims>(token, &key, &validation).map_err(|e| auth_error(&e.to_string()))?;
        let c = data.claims;
        Ok(Owner {
            iss: c.iss,
            sub: c.sub.ok_or_else(|| auth_error("token has no sub"))?,
            azp: c.azp.ok_or_else(|| auth_error("token has no azp"))?,
        })
    }
}
