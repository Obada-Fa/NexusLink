use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::sync::Arc;
use tokio::sync::{Mutex, oneshot};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RpcRequest {
    id: u64,
    method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RpcResponse {
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let reader = BufReader::new(stdin);

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let req: RpcRequest = serde_json::from_str(&line)?;
        let id = req.id;
        let method = req.method;

        let response = match method.as_str() {
            "ping" => RpcResponse {
                id,
                result: Some(Value::String("pong".to_string())),
                error: None,
            },
            _ => RpcResponse {
                id,
                result: None,
                error: Some("method not implemented".to_string()),
            },
        };

        let json = serde_json::to_string(&response)?;
        writeln!(stdout.lock(), "{}", json)?;
        stdout.flush()?;
    }

    Ok(())
}
