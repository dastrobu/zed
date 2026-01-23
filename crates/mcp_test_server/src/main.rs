//! MCP Test Server for File Descriptor Exhaustion Testing
//!
//! This server is designed to test the fix for PR #47229 by deliberately
//! leaking file descriptors to trigger the "too many open files" scenario
//! that can cause orphaned tool_result blocks.
//!
//! Usage:
//!   cargo run --bin mcp-fd-exhaustion-server

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::sync::{Arc, Mutex};

/// Shared state for tracking leaked file descriptors
#[derive(Clone)]
struct ServerState {
    leaked_files: Arc<Mutex<Vec<File>>>,
    call_count: Arc<Mutex<u64>>,
}

impl ServerState {
    fn new() -> Self {
        Self {
            leaked_files: Arc::new(Mutex::new(Vec::new())),
            call_count: Arc::new(Mutex::new(0)),
        }
    }

    fn leak_file(&self) -> Result<usize> {
        let mut leaked = self.leaked_files.lock().unwrap();

        // Try to open /dev/null (cross-platform: use /dev/null on Unix, NUL on Windows)
        #[cfg(unix)]
        let file = File::open("/dev/null")?;

        #[cfg(windows)]
        let file = File::open("NUL")?;

        leaked.push(file);
        Ok(leaked.len())
    }

    fn leak_many(&self, count: usize) -> Result<usize> {
        for _ in 0..count {
            if let Err(e) = self.leak_file() {
                eprintln!("Warning: Failed to leak file descriptor: {}", e);
                break;
            }
        }
        Ok(self.leaked_files.lock().unwrap().len())
    }

    fn increment_count(&self) -> u64 {
        let mut count = self.call_count.lock().unwrap();
        *count += 1;
        *count
    }

    fn get_leaked_count(&self) -> usize {
        self.leaked_files.lock().unwrap().len()
    }
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    #[allow(dead_code)]
    jsonrpc: String,
    id: Option<serde_json::Value>,
    method: String,
    params: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    id: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
}

fn handle_initialize(id: serde_json::Value) -> JsonRpcResponse {
    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id,
        result: Some(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "mcp-fd-exhaustion-test-server",
                "version": "0.1.0"
            }
        })),
        error: None,
    }
}

fn handle_tools_list(id: serde_json::Value) -> JsonRpcResponse {
    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id,
        result: Some(json!({
            "tools": [
                {
                    "name": "leak_fd",
                    "description": "Leaks a single file descriptor to simulate FD exhaustion",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "message": {
                                "type": "string",
                                "description": "Optional message"
                            }
                        }
                    }
                },
                {
                    "name": "leak_many_fds",
                    "description": "Leaks multiple file descriptors at once",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "count": {
                                "type": "number",
                                "description": "Number of FDs to leak (default: 10)",
                                "default": 10
                            }
                        }
                    }
                },
                {
                    "name": "aggressive_leak",
                    "description": "Aggressively leaks FDs on every call, plus extra on every 10th call",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "message": {
                                "type": "string",
                                "description": "Optional message"
                            }
                        }
                    }
                },
                {
                    "name": "status",
                    "description": "Reports current FD leak status",
                    "inputSchema": {
                        "type": "object",
                        "properties": {}
                    }
                }
            ]
        })),
        error: None,
    }
}

fn handle_tool_call(
    id: serde_json::Value,
    params: serde_json::Value,
    state: &ServerState,
) -> JsonRpcResponse {
    let tool_name = params
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    let arguments = params.get("arguments").cloned().unwrap_or(json!({}));

    match tool_name {
        "leak_fd" => match state.leak_file() {
            Ok(total) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: Some(json!({
                    "content": [{
                        "type": "text",
                        "text": format!("Leaked 1 FD. Total leaked: {}", total)
                    }]
                })),
                error: None,
            },
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: None,
                error: Some(JsonRpcError {
                    code: -32000,
                    message: format!("Failed to leak FD: {}", e),
                }),
            },
        },
        "leak_many_fds" => {
            let count = arguments
                .get("count")
                .and_then(|v| v.as_u64())
                .unwrap_or(10) as usize;

            match state.leak_many(count) {
                Ok(total) => JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: Some(json!({
                        "content": [{
                            "type": "text",
                            "text": format!("Leaked {} FDs. Total leaked: {}", count, total)
                        }]
                    })),
                    error: None,
                },
                Err(e) => JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32000,
                        message: format!("Failed to leak FDs: {}", e),
                    }),
                },
            }
        }
        "aggressive_leak" => {
            let call_count = state.increment_count();

            // Always leak 5 FDs
            let _ = state.leak_many(5);

            // Every 10th call, leak 50 more
            if call_count % 10 == 0 {
                let _ = state.leak_many(50);
            }

            let total = state.get_leaked_count();

            JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: Some(json!({
                    "content": [{
                        "type": "text",
                        "text": format!("Call #{}, Total leaked FDs: {}", call_count, total)
                    }]
                })),
                error: None,
            }
        }
        "status" => {
            let total = state.get_leaked_count();
            let calls = *state.call_count.lock().unwrap();

            JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: Some(json!({
                    "content": [{
                        "type": "text",
                        "text": format!("Status: {} FDs leaked, {} aggressive calls made", total, calls)
                    }]
                })),
                error: None,
            }
        }
        _ => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code: -32601,
                message: format!("Unknown tool: {}", tool_name),
            }),
        },
    }
}

fn handle_request(request: JsonRpcRequest, state: &ServerState) -> JsonRpcResponse {
    let id = request.id.unwrap_or(json!(null));

    match request.method.as_str() {
        "initialize" => handle_initialize(id),
        "tools/list" => handle_tools_list(id),
        "tools/call" => {
            if let Some(params) = request.params {
                handle_tool_call(id, params, state)
            } else {
                JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32602,
                        message: "Invalid params".to_string(),
                    }),
                }
            }
        }
        _ => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code: -32601,
                message: format!("Method not found: {}", request.method),
            }),
        },
    }
}

fn main() -> Result<()> {
    eprintln!("MCP FD Exhaustion Test Server starting");
    eprintln!("This server deliberately leaks file descriptors to test PR #47229");

    let state = ServerState::new();

    let stdin = std::io::stdin();
    let reader = BufReader::new(stdin);

    for line in reader.lines() {
        match line {
            Ok(line) => {
                if line.trim().is_empty() {
                    continue;
                }

                match serde_json::from_str::<JsonRpcRequest>(&line) {
                    Ok(request) => {
                        let response = handle_request(request, &state);
                        if let Ok(json) = serde_json::to_string(&response) {
                            println!("{}", json);
                            let _ = std::io::stdout().flush();
                        }
                    }
                    Err(e) => {
                        eprintln!("Error: Failed to parse request: {}", e);
                    }
                }
            }
            Err(e) => {
                eprintln!("Error: Error reading stdin: {}", e);
                break;
            }
        }
    }

    Ok(())
}
