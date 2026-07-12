//! Unix-socket transport between a live Schemify process and spawned agents.
//!
//! The GUI process calls [`serve`] on a background thread: it listens on a
//! socket and answers MCP protocol lines against the shared App. The agent
//! CLI can't connect to a socket itself, so it spawns `schemify mcp-bridge
//! <socket>` as a stdio MCP server; [`run_bridge`] pumps stdio ↔ socket.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::protocol::McpToolServer;

/// Socket path for this process (temp dir + pid; stale files from dead
/// processes are unlinked by the next `serve` on the same path).
pub fn default_socket_path() -> PathBuf {
    std::env::temp_dir().join(format!("schemify-mcp-{}.sock", std::process::id()))
}

/// Accept loop: serve MCP protocol lines on `path`. Blocks forever — run on
/// a background thread. One thread per connection: agent CLIs connect more
/// than once per session (discovery + live), and a lingering bridge must
/// never block the next handshake. The server is locked per line, so
/// concurrent connections interleave at request granularity.
pub fn serve(server: McpToolServer, path: &Path) -> io::Result<()> {
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    let server = Arc::new(Mutex::new(server));
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let srv = Arc::clone(&server);
        std::thread::spawn(move || {
            let _ = handle_conn(&srv, stream);
        });
    }
    Ok(())
}

fn handle_conn(server: &Mutex<McpToolServer>, stream: UnixStream) -> io::Result<()> {
    let mut writer = stream.try_clone()?;
    for line in BufReader::new(stream).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let resp = match server.lock() {
            Ok(mut srv) => srv.handle_line(&line),
            Err(_) => return Ok(()), // poisoned: drop the connection
        };
        if let Some(resp) = resp {
            writeln!(writer, "{resp}")?;
            writer.flush()?;
        }
    }
    Ok(())
}

/// `schemify mcp-bridge <socket>`: stdio MCP server that proxies to a live
/// process's socket. Runs until stdin closes (agent session end).
pub fn run_bridge(path: &Path) -> io::Result<()> {
    let sock = UnixStream::connect(path)?;
    let mut sock_writer = sock.try_clone()?;

    // stdin → socket on a helper thread; socket → stdout here.
    std::thread::spawn(move || -> io::Result<()> {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            writeln!(sock_writer, "{}", line?)?;
            sock_writer.flush()?;
        }
        // EOF: shut down the write side so the serve loop's reader ends too.
        let _ = sock_writer.shutdown(std::net::Shutdown::Write);
        Ok(())
    });

    let mut stdout = io::stdout();
    for line in BufReader::new(sock).lines() {
        writeln!(stdout, "{}", line?)?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::McpServer;
    use schemify_editor::handler::App;
    use serde_json::{json, Value};

    #[test]
    fn socket_round_trip() {
        let path = std::env::temp_dir()
            .join(format!("schemify-agent-test-{}.sock", std::process::id()));
        let srv = McpToolServer::new(McpServer::direct(App::new()));
        let p = path.clone();
        std::thread::spawn(move || serve(srv, &p));

        // Wait for the listener to bind.
        let mut stream = None;
        for _ in 0..50 {
            if let Ok(s) = UnixStream::connect(&path) {
                stream = Some(s);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let stream = stream.expect("socket up");
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);

        writeln!(writer, r#"{{"jsonrpc":"2.0","id":1,"method":"tools/list"}}"#).unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let resp: Value = serde_json::from_str(&line).unwrap();
        assert!(resp["result"]["tools"].as_array().unwrap().len() > 10);

        writeln!(
            writer,
            "{}",
            json!({"jsonrpc":"2.0","id":2,"method":"tools/call",
                "params":{"name":"session_state","arguments":{}}})
        )
        .unwrap();
        line.clear();
        reader.read_line(&mut line).unwrap();
        let resp: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(resp["result"]["isError"], false);

        let _ = std::fs::remove_file(&path);
    }
}
