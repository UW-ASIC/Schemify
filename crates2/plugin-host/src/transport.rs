//! Subprocess transport: newline-delimited JSON-RPC over stdin/stdout.
// WASM transport: reintroduce behind feature when needed.

use std::io::{self, BufRead, BufReader, Write as IoWrite};
use std::path::Path;
use std::process::{Child, Command, Stdio};

/// Errors arising from plugin transport operations.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("spawn failed: {0}")]
    SpawnFailed(String),
    #[error("send failed: {0}")]
    SendFailed(String),
    #[error("recv failed: {0}")]
    RecvFailed(String),
    #[error("transport not running")]
    NotRunning,
}


/// Child process with stdin/stdout pipes. Stdout is O_NONBLOCK on unix so
/// `recv()` never blocks the main thread.
pub struct SubprocessTransport {
    child: Option<Child>,
    stdin: Option<io::BufWriter<std::process::ChildStdin>>,
    stdout: Option<BufReader<std::process::ChildStdout>>,
    line_buf: String,
}

impl SubprocessTransport {
    /// Spawn `entry` (whitespace-split command line) inside `plugin_dir`.
    pub fn spawn(entry: &str, plugin_dir: &Path) -> Result<Self, TransportError> {
        let parts: Vec<&str> = entry.split_whitespace().collect();
        if parts.is_empty() {
            return Err(TransportError::SpawnFailed("empty command".into()));
        }

        let mut child = Command::new(parts[0])
            .args(&parts[1..])
            .current_dir(plugin_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| TransportError::SpawnFailed(e.to_string()))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| TransportError::SpawnFailed("failed to open stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| TransportError::SpawnFailed("failed to open stdout".into()))?;

        // Non-blocking stdout on unix.
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let fd = stdout.as_raw_fd();
            unsafe {
                let flags = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
            }
        }

        Ok(Self {
            child: Some(child),
            stdin: Some(io::BufWriter::new(stdin)),
            stdout: Some(BufReader::new(stdout)),
            line_buf: String::with_capacity(4096),
        })
    }

    /// Send one newline-terminated JSON line.
    pub fn send(&mut self, msg: &str) -> Result<(), TransportError> {
        let stdin = self.stdin.as_mut().ok_or(TransportError::NotRunning)?;
        stdin
            .write_all(msg.as_bytes())
            .and_then(|()| stdin.flush())
            .map_err(|e| TransportError::SendFailed(e.to_string()))
    }

    /// Try to receive one line (non-blocking). `Ok(None)` = nothing available.
    pub fn recv(&mut self) -> Result<Option<String>, TransportError> {
        let reader = self.stdout.as_mut().ok_or(TransportError::NotRunning)?;
        self.line_buf.clear();
        match reader.read_line(&mut self.line_buf) {
            Ok(0) => Err(TransportError::RecvFailed("subprocess exited".into())),
            Ok(_) => {
                let trimmed = self.line_buf.trim();
                if trimmed.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(trimmed.to_owned()))
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => Err(TransportError::RecvFailed(e.to_string())),
        }
    }

    /// Kill the child and release pipes.
    pub fn stop(&mut self) {
        // Drop stdin first to signal EOF to the child.
        self.stdin = None;
        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        self.stdout = None;
    }

    /// Whether the child process is still alive.
    pub fn is_running(&mut self) -> bool {
        match self.child {
            Some(ref mut child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }
}

impl Drop for SubprocessTransport {
    fn drop(&mut self) {
        self.stop();
    }
}
