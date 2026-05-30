use std::io::{self, BufRead, BufReader, Write as IoWrite};
use std::path::Path;
use std::process::{Child, Command, Stdio};

use super::{PluginTransport, TransportError};
use crate::manifest::PluginManifest;

/// Subprocess-based plugin transport.
///
/// Spawns a child process with stdin/stdout pipes. Messages are newline-delimited
/// JSON lines over stdio. Stdout is set to non-blocking on unix so `recv()` never
/// blocks the main thread.
pub struct SubprocessTransport {
    child: Option<Child>,
    stdin: Option<std::io::BufWriter<std::process::ChildStdin>>,
    stdout_buf: Option<BufReader<std::process::ChildStdout>>,
    line_buf: String,
}

impl SubprocessTransport {
    /// Create a new, idle subprocess transport.
    pub fn new() -> Self {
        Self {
            child: None,
            stdin: None,
            stdout_buf: None,
            line_buf: String::with_capacity(4096),
        }
    }
}

impl Default for SubprocessTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl PluginTransport for SubprocessTransport {
    fn spawn(
        &mut self,
        manifest: &PluginManifest,
        plugin_dir: &Path,
    ) -> Result<(), TransportError> {
        if self.is_running() {
            return Err(TransportError::SpawnFailed(
                "transport already running".into(),
            ));
        }

        let command_str = &manifest.plugin.entry;
        let parts: Vec<&str> = command_str.split_whitespace().collect();
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

        self.child = Some(child);
        self.stdin = Some(std::io::BufWriter::new(stdin));
        self.stdout_buf = Some(BufReader::new(stdout));

        Ok(())
    }

    fn send(&mut self, msg: &str) -> Result<(), TransportError> {
        let stdin = self.stdin.as_mut().ok_or(TransportError::NotRunning)?;
        stdin
            .write_all(msg.as_bytes())
            .map_err(|e| TransportError::SendFailed(e.to_string()))?;
        stdin
            .flush()
            .map_err(|e| TransportError::SendFailed(e.to_string()))?;
        Ok(())
    }

    fn recv(&mut self) -> Result<Option<String>, TransportError> {
        let reader = self.stdout_buf.as_mut().ok_or(TransportError::NotRunning)?;

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

    fn stop(&mut self) -> Result<(), TransportError> {
        // Drop stdin first to signal EOF to child
        self.stdin = None;

        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        self.stdout_buf = None;
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.child.is_some()
    }
}

impl Drop for SubprocessTransport {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_transport_not_running() {
        let t = SubprocessTransport::new();
        assert!(!t.is_running());
    }

    #[test]
    fn default_transport_not_running() {
        let t = SubprocessTransport::default();
        assert!(!t.is_running());
    }

    #[test]
    fn send_without_spawn_returns_not_running() {
        let mut t = SubprocessTransport::new();
        let result = t.send("hello\n");
        assert!(result.is_err());
        match result.unwrap_err() {
            TransportError::NotRunning => {}
            other => panic!("expected NotRunning, got: {other}"),
        }
    }

    #[test]
    fn recv_without_spawn_returns_not_running() {
        let mut t = SubprocessTransport::new();
        let result = t.recv();
        assert!(result.is_err());
        match result.unwrap_err() {
            TransportError::NotRunning => {}
            other => panic!("expected NotRunning, got: {other}"),
        }
    }

    #[test]
    fn stop_without_spawn_is_ok() {
        let mut t = SubprocessTransport::new();
        let result = t.stop();
        assert!(result.is_ok());
    }

    #[test]
    fn spawn_with_empty_command_fails() {
        let manifest = crate::manifest::PluginManifest::parse(
            r#"
[plugin]
name = "Bad"
version = "0.1.0"
entry = ""
"#,
        )
        .unwrap();
        let mut t = SubprocessTransport::new();
        let result = t.spawn(&manifest, std::path::Path::new("/tmp"));
        assert!(result.is_err());
        match result.unwrap_err() {
            TransportError::SpawnFailed(msg) => {
                assert!(msg.contains("empty command"), "got: {msg}");
            }
            other => panic!("expected SpawnFailed, got: {other}"),
        }
    }

    #[test]
    fn spawn_nonexistent_binary_fails() {
        let manifest = crate::manifest::PluginManifest::parse(
            r#"
[plugin]
name = "NoSuchBinary"
version = "0.1.0"
entry = "absolutely_nonexistent_binary_xyz_123"
"#,
        )
        .unwrap();
        let mut t = SubprocessTransport::new();
        let result = t.spawn(&manifest, std::path::Path::new("/tmp"));
        assert!(result.is_err());
        match result.unwrap_err() {
            TransportError::SpawnFailed(_) => {}
            other => panic!("expected SpawnFailed, got: {other}"),
        }
    }

    #[test]
    fn spawn_and_stop_cat() {
        let manifest = crate::manifest::PluginManifest::parse(
            r#"
[plugin]
name = "Echo"
version = "0.1.0"
entry = "cat"
"#,
        )
        .unwrap();
        let mut t = SubprocessTransport::new();
        let result = t.spawn(&manifest, std::path::Path::new("/tmp"));
        assert!(result.is_ok(), "spawn failed: {:?}", result.err());
        assert!(t.is_running());

        let stop = t.stop();
        assert!(stop.is_ok());
        assert!(!t.is_running());
    }

    #[test]
    fn spawn_send_recv_with_cat() {
        let manifest = crate::manifest::PluginManifest::parse(
            r#"
[plugin]
name = "Cat"
version = "0.1.0"
entry = "cat"
"#,
        )
        .unwrap();
        let mut t = SubprocessTransport::new();
        t.spawn(&manifest, std::path::Path::new("/tmp")).unwrap();

        // cat echoes stdin to stdout
        t.send("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n")
            .unwrap();

        // Give cat a moment to echo back, then read.
        std::thread::sleep(std::time::Duration::from_millis(50));

        let msg = t.recv().unwrap();
        assert!(msg.is_some(), "expected a message from cat");
        let line = msg.unwrap();
        assert!(line.contains("jsonrpc"));

        t.stop().unwrap();
    }

    #[test]
    fn double_spawn_fails() {
        let manifest = crate::manifest::PluginManifest::parse(
            r#"
[plugin]
name = "Double"
version = "0.1.0"
entry = "cat"
"#,
        )
        .unwrap();
        let mut t = SubprocessTransport::new();
        t.spawn(&manifest, std::path::Path::new("/tmp")).unwrap();
        let result = t.spawn(&manifest, std::path::Path::new("/tmp"));
        assert!(result.is_err());
        match result.unwrap_err() {
            TransportError::SpawnFailed(msg) => {
                assert!(msg.contains("already running"), "got: {msg}");
            }
            other => panic!("expected SpawnFailed, got: {other}"),
        }
        t.stop().unwrap();
    }
}
