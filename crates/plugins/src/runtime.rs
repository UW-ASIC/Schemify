use std::io::{self, BufRead, BufReader, Write as IoWrite};
use std::path::Path;
use std::process::{Child, Command, Stdio};

use crate::jsonrpc;
use serde_json::Value;

/// Subprocess transport: spawns a child process with stdin/stdout pipes.
/// Communication via newline-delimited JSON-RPC over stdio.
pub struct Subprocess {
    child: Child,
    reader: BufReader<std::process::ChildStdout>,
    line_buf: String,
}

impl Subprocess {
    /// Spawn a subprocess from a command string (split on whitespace).
    /// Working directory set to `cwd`.
    pub fn spawn(command: &str, cwd: &Path) -> io::Result<Self> {
        let parts: Vec<&str> = command.split_whitespace().collect();
        if parts.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "empty command",
            ));
        }

        let mut child = Command::new(parts[0])
            .args(&parts[1..])
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;

        let stdout = child.stdout.take().expect("stdout piped");

        // Set stdout to non-blocking on unix
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let fd = stdout.as_raw_fd();
            unsafe {
                let flags = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
            }
        }

        let reader = BufReader::new(stdout);

        Ok(Self {
            child,
            reader,
            line_buf: String::with_capacity(4096),
        })
    }

    /// Write raw bytes to the subprocess stdin.
    pub fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        if let Some(ref mut stdin) = self.child.stdin {
            stdin.write_all(data)?;
            stdin.flush()?;
        }
        Ok(())
    }

    /// Send a JSON-RPC notification to the subprocess.
    pub fn send_notification(&mut self, method: &str, params: Option<Value>) -> io::Result<()> {
        let msg = jsonrpc::encode_notification(method, params);
        self.write_all(msg.as_bytes())
    }

    /// Send a JSON-RPC request to the subprocess.
    pub fn send_request(
        &mut self,
        id: u32,
        method: &str,
        params: Option<Value>,
    ) -> io::Result<()> {
        let msg = jsonrpc::encode_request(id, method, params);
        self.write_all(msg.as_bytes())
    }

    /// Send a JSON-RPC success response.
    pub fn send_response(&mut self, id: u32, result: Value) -> io::Result<()> {
        let msg = jsonrpc::encode_response(id, result);
        self.write_all(msg.as_bytes())
    }

    /// Send a JSON-RPC error response.
    pub fn send_error(&mut self, id: u32, code: i32, message: &str) -> io::Result<()> {
        let msg = jsonrpc::encode_error(id, code, message);
        self.write_all(msg.as_bytes())
    }

    /// Try to read one line from stdout (non-blocking on unix).
    /// Returns Ok(Some(msg)) if a complete line was read and parsed.
    /// Returns Ok(None) if no data available yet.
    /// Returns Err on actual I/O error or EOF.
    pub fn try_read_message(&mut self) -> io::Result<Option<jsonrpc::IncomingMessage>> {
        self.line_buf.clear();
        match self.reader.read_line(&mut self.line_buf) {
            Ok(0) => Err(io::Error::new(io::ErrorKind::UnexpectedEof, "subprocess exited")),
            Ok(_) => {
                let trimmed = self.line_buf.trim();
                if trimmed.is_empty() {
                    return Ok(None);
                }
                match jsonrpc::parse_line(trimmed) {
                    Ok(msg) => Ok(Some(msg)),
                    Err(e) => Err(io::Error::new(io::ErrorKind::InvalidData, e)),
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Drain up to `max` messages from stdout (non-blocking).
    pub fn drain_messages(&mut self, max: usize) -> Vec<jsonrpc::IncomingMessage> {
        let mut msgs = Vec::new();
        for _ in 0..max {
            match self.try_read_message() {
                Ok(Some(msg)) => msgs.push(msg),
                Ok(None) => break,
                Err(_) => break,
            }
        }
        msgs
    }

    /// Check if the child process is still alive.
    pub fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Send SIGTERM (unix) or kill (windows), then wait.
    pub fn kill(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Subprocess {
    fn drop(&mut self) {
        if self.is_alive() {
            self.kill();
        }
    }
}
