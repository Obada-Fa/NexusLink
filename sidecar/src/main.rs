use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};

#[cfg(windows)]
mod win;

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

fn dispatch(method: &str, params: Option<Value>) -> Result<Value, String> {
    match method {
        "ping" => Ok(Value::String("pong".into())),
        #[cfg(windows)]
        "screen.metadata" => win::screen_metadata(),
        #[cfg(windows)]
        "screen.grab" => win::screen_grab(params),
        #[cfg(windows)]
        "input.mouseMoveAbs" => win::mouse_move_abs(params),
        #[cfg(windows)]
        "input.mouseClick" => win::mouse_click(params),
        #[cfg(windows)]
        "input.typeText" => win::type_text(params),
        #[cfg(windows)]
        "window.list" => win::window_list(),
        #[cfg(windows)]
        "terminal.create" => win::pty_create(params),
        #[cfg(windows)]
        "terminal.input" => win::pty_input(params),
        #[cfg(windows)]
        "terminal.resize" => win::pty_resize(params),
        #[cfg(windows)]
        "terminal.kill" => win::pty_kill(params),
        _ => Err("method not implemented".into()),
    }
}

fn main() -> anyhow::Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let reader = BufReader::new(stdin);

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let req: RpcRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("bad request: {e}");
                continue;
            }
        };
        let response = match dispatch(&req.method, req.params) {
            Ok(result) => RpcResponse {
                id: req.id,
                result: Some(result),
                error: None,
            },
            Err(error) => RpcResponse {
                id: req.id,
                result: None,
                error: Some(error),
            },
        };
        writeln!(stdout, "{}", serde_json::to_string(&response)?)?;
        stdout.flush()?;
    }
    Ok(())
}
