// schemify_host.js - Browser host bridge for schemify.wasm.
//
// Exposes the WASM import namespace "host" for:
// - VFS functions backed by window.SchemifyVFS
// - Platform functions (open_url, async HTTP, env lookup)
// - Plugin Web Worker management (spawn, send, recv, kill)
//
// Pointer/length arguments are i32 offsets into the main WASM memory.
// Call SchemifyHost.setMemory(instance.exports.memory) after instantiation.

window.SchemifyHost = (() => {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const vfs = window.SchemifyVFS.files;
  const httpReqs = new Map(); // req_id -> { status, data? }
  let mem = null;

  const readStr = (ptr, len) => dec.decode(new Uint8Array(mem.buffer, ptr, len));

  function writeBytes(ptr, len, src) {
    const n = Math.min(src.length, len);
    new Uint8Array(mem.buffer, ptr, n).set(src.subarray(0, n));
    return n;
  }

  function eachImmediateEntry(dir, fn) {
    const prefix = dir.endsWith('/') ? dir : `${dir}/`;
    for (const key of vfs.keys()) {
      if (!key.startsWith(prefix)) continue;
      const rel = key.slice(prefix.length);
      if (rel.includes('/')) continue;
      fn(rel);
    }
  }

  function setReqPending(reqId) {
    httpReqs.set(reqId, { status: 'pending' });
  }

  function setReqDone(reqId, bytes) {
    httpReqs.set(reqId, { status: 'done', data: bytes });
  }

  function setReqError(reqId) {
    httpReqs.set(reqId, { status: 'error' });
  }

  // -- Plugin Web Worker management -------------------------------------------
  // Each plugin runs as a Web Worker. JSON-RPC messages arrive via postMessage
  // and are queued for the WASM side to poll via plugin_recv.

  const pluginWorkers = new Map(); // id -> { worker, recvQueue: string[], alive: bool }
  let nextPluginId = 1;

  const imports = {
    // -- VFS ------------------------------------------------------------------

    vfs_file_len(path_ptr, path_len) {
      const file = vfs.get(readStr(path_ptr, path_len));
      return file != null ? file.length : -1;
    },

    vfs_file_read(path_ptr, path_len, dest, dlen) {
      const file = vfs.get(readStr(path_ptr, path_len));
      return file ? writeBytes(dest, dlen, file) : -1;
    },

    vfs_file_write(path_ptr, path_len, src, slen) {
      const path = readStr(path_ptr, path_len);
      vfs.set(path, new Uint8Array(mem.buffer, src, slen).slice());
      window.SchemifyVFS.markDirty(path);
      return 0;
    },

    vfs_file_delete(path_ptr, path_len) {
      const path = readStr(path_ptr, path_len);
      vfs.delete(path);
      window.SchemifyVFS.markDirty(path);
      return 0;
    },

    vfs_dir_make(_path_ptr, _path_len) {
      return 0; // Directories are implicit in this flat file map.
    },

    vfs_dir_list_len(path_ptr, path_len) {
      let total = 0;
      eachImmediateEntry(readStr(path_ptr, path_len), (entry) => {
        total += enc.encode(entry).length + 1;
      });
      return total > 0 ? total : -1;
    },

    vfs_dir_list_read(path_ptr, path_len, dest, dlen) {
      const out = new Uint8Array(mem.buffer, dest, dlen);
      let pos = 0;
      eachImmediateEntry(readStr(path_ptr, path_len), (entry) => {
        const bytes = enc.encode(entry);
        if (pos + bytes.length + 1 > dlen) return;
        out.set(bytes, pos);
        pos += bytes.length;
        out[pos++] = 0;
      });
      return pos;
    },

    // -- Platform -------------------------------------------------------------

    platform_open_url(ptr, len) {
      window.open(readStr(ptr, len), '_blank', 'noopener,noreferrer');
    },

    platform_http_get_start(url_ptr, url_len, req_id) {
      setReqPending(req_id);
      fetch(readStr(url_ptr, url_len))
        .then((resp) => resp.arrayBuffer())
        .then((ab) => setReqDone(req_id, new Uint8Array(ab)))
        .catch(() => setReqError(req_id));
    },

    platform_http_get_poll(req_id, buf_ptr, buf_len) {
      const req = httpReqs.get(req_id);
      if (!req || req.status === 'pending') return -1;
      httpReqs.delete(req_id);
      if (req.status === 'error') return -2;
      return writeBytes(buf_ptr, buf_len, req.data);
    },

    platform_env_get(_name_ptr, _name_len, _out_ptr, _out_len) {
      return -1;
    },

    // -- Plugin Workers -------------------------------------------------------
    // Plugins run as Web Workers loading Pyodide (Python in WASM).
    // The worker.js in each plugin bundle sets up the JSON-RPC bridge.

    plugin_spawn(url_ptr, url_len) {
      const url = readStr(url_ptr, url_len);
      const id = nextPluginId++;
      try {
        const worker = new Worker(url);
        const entry = { worker, recvQueue: [], alive: true };

        worker.onmessage = (e) => {
          // Each message from the worker is a JSON-RPC line.
          if (typeof e.data === 'string') {
            entry.recvQueue.push(e.data);
          }
        };

        worker.onerror = (err) => {
          console.error(`[schemify] plugin worker ${id} error:`, err.message);
          entry.alive = false;
        };

        pluginWorkers.set(id, entry);
        return id;
      } catch (err) {
        console.error(`[schemify] failed to spawn plugin worker:`, err);
        return -1;
      }
    },

    plugin_send(id, data_ptr, data_len) {
      const entry = pluginWorkers.get(id);
      if (!entry || !entry.alive) return;
      const msg = readStr(data_ptr, data_len);
      try {
        entry.worker.postMessage(msg);
      } catch {
        entry.alive = false;
      }
    },

    plugin_recv(id, buf_ptr, buf_len) {
      const entry = pluginWorkers.get(id);
      if (!entry || entry.recvQueue.length === 0) return -1;
      const msg = entry.recvQueue.shift();
      const bytes = enc.encode(msg);
      const n = Math.min(bytes.length, buf_len);
      new Uint8Array(mem.buffer, buf_ptr, n).set(bytes.subarray(0, n));
      return n;
    },

    plugin_kill(id) {
      const entry = pluginWorkers.get(id);
      if (!entry) return;
      if (entry.worker) {
        try { entry.worker.terminate(); } catch { /* already dead */ }
      }
      pluginWorkers.delete(id);
    },

    plugin_alive(id) {
      const entry = pluginWorkers.get(id);
      return (entry && entry.alive) ? 1 : 0;
    },
  };

  return {
    imports,
    setMemory(memory) {
      mem = memory;
    },
  };
})();
