//! Minimal in-cluster Kubernetes client for the `node_drain` demo tool: plain REST calls with the
//! pod's ServiceAccount token and CA, no kube-rs. Lab only.

use serde_json::{json, Value};

const SA: &str = "/var/run/secrets/kubernetes.io/serviceaccount";

pub struct Kube {
    base: String,
    token: String,
    http: reqwest::Client,
}

/// A pod the drain tried to evict.
pub struct PodRef {
    pub namespace: String,
    pub name: String,
}

impl Kube {
    /// `None` outside a cluster (no ServiceAccount mounted).
    pub fn in_cluster() -> Option<Self> {
        let host = std::env::var("KUBERNETES_SERVICE_HOST").ok()?;
        let port = std::env::var("KUBERNETES_SERVICE_PORT").unwrap_or_else(|_| "443".into());
        let token = std::fs::read_to_string(format!("{SA}/token")).ok()?;
        let ca = std::fs::read(format!("{SA}/ca.crt")).ok()?;
        let cert = reqwest::Certificate::from_pem(&ca).ok()?;
        let http = reqwest::Client::builder().add_root_certificate(cert).build().ok()?;
        Some(Self { base: format!("https://{host}:{port}"), token: token.trim().to_string(), http })
    }

    async fn call(&self, method: reqwest::Method, path: &str, ctype: &str, body: Option<Value>) -> anyhow::Result<(u16, Value)> {
        let mut req = self.http.request(method, format!("{}{}", self.base, path)).bearer_auth(&self.token);
        if let Some(b) = body {
            req = req.header("content-type", ctype).body(b.to_string());
        }
        let res = req.send().await?;
        let status = res.status().as_u16();
        let v = res.json::<Value>().await.unwrap_or(Value::Null);
        Ok((status, v))
    }

    pub async fn set_unschedulable(&self, node: &str, on: bool) -> anyhow::Result<()> {
        let (s, v) = self
            .call(reqwest::Method::PATCH, &format!("/api/v1/nodes/{node}"), "application/merge-patch+json",
                  Some(json!({"spec": {"unschedulable": on}})))
            .await?;
        anyhow::ensure!(s == 200, "patch node {node}: HTTP {s} {v}");
        Ok(())
    }

    /// Pods on `node`, without DaemonSet-owned and mirror pods (what `kubectl drain` skips).
    pub async fn pods_on(&self, node: &str) -> anyhow::Result<Vec<PodRef>> {
        let (s, v) = self
            .call(reqwest::Method::GET, &format!("/api/v1/pods?fieldSelector=spec.nodeName%3D{node}"), "", None)
            .await?;
        anyhow::ensure!(s == 200, "list pods: HTTP {s}");
        let mut out = vec![];
        for p in v["items"].as_array().cloned().unwrap_or_default() {
            let owners = p["metadata"]["ownerReferences"].as_array().cloned().unwrap_or_default();
            let daemon = owners.iter().any(|o| o["kind"] == "DaemonSet");
            let mirror = !p["metadata"]["annotations"]["kubernetes.io/config.mirror"].is_null();
            let done = matches!(p["status"]["phase"].as_str(), Some("Succeeded") | Some("Failed"));
            if daemon || mirror || done {
                continue;
            }
            out.push(PodRef {
                namespace: p["metadata"]["namespace"].as_str().unwrap_or_default().into(),
                name: p["metadata"]["name"].as_str().unwrap_or_default().into(),
            });
        }
        Ok(out)
    }

    /// Eviction API: `Ok(true)` evicted, `Ok(false)` refused by a PodDisruptionBudget (HTTP 429).
    pub async fn evict(&self, pod: &PodRef) -> anyhow::Result<bool> {
        let body = json!({"apiVersion": "policy/v1", "kind": "Eviction",
                          "metadata": {"name": pod.name, "namespace": pod.namespace}});
        let (s, v) = self
            .call(reqwest::Method::POST, &format!("/api/v1/namespaces/{}/pods/{}/eviction", pod.namespace, pod.name),
                  "application/json", Some(body))
            .await?;
        match s {
            200 | 201 => Ok(true),
            429 => Ok(false),
            _ => anyhow::bail!("evict {}/{}: HTTP {s} {v}", pod.namespace, pod.name),
        }
    }

    /// Delete bypassing the PodDisruptionBudget (what a forced drain does).
    pub async fn delete(&self, pod: &PodRef) -> anyhow::Result<()> {
        let (s, v) = self
            .call(reqwest::Method::DELETE, &format!("/api/v1/namespaces/{}/pods/{}", pod.namespace, pod.name),
                  "application/json", Some(json!({"gracePeriodSeconds": 0})))
            .await?;
        anyhow::ensure!(s == 200 || s == 202 || s == 404, "delete {}/{}: HTTP {s} {v}", pod.namespace, pod.name);
        Ok(())
    }
}
