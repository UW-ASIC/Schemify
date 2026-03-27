// schemify_host.js — Schemify WASM host imports.
//
// Provides the "host" namespace for the main schemify.wasm module.
// Implements two APIs:
//
//   VFS (virtual filesystem)
//     vfs_file_len / vfs_file_read / vfs_file_write / vfs_file_delete
//     vfs_dir_make / vfs_dir_list_len / vfs_dir_list_read
//
//   Platform (OS abstraction)
//     platform_open_url
//     platform_http_get_start / platform_http_get_poll
//     platform_env_get
//
// All pointer/length arguments are i32 offsets into the WASM linear memory.
// `SchemifyHost.setMemory(instance.exports.memory)` must be called after
// the WASM module is instantiated.
//
// Requires: vfs.js (window.SchemifyVFS) loaded first.

window.SchemifyHost = (() => {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  let mem = null; // WebAssembly.Memory, set after instantiation

  function readStr(ptr, len) {
    return dec.decode(new Uint8Array(mem.buffer, ptr, len));
  }
  function writeBytes(ptr, len, src) {
    const n = Math.min(src.length, len);
    new Uint8Array(mem.buffer, ptr, n).set(src.subarray(0, n));
    return n;
  }

  // ── VFS backed by SchemifyVFS (OPFS-persistent) ────────────────────── //
  const vfs = window.SchemifyVFS.files;

  // ── Pending HTTP requests ─────────────────────────────────────────────── //
  // req_id → { status: 'pending'|'done'|'error', data?: Uint8Array }
  const httpReqs = new Map();

  const imports = {
    // ── VFS ────────────────────────────────────────────────────────────── //

    vfs_file_len(path_ptr, path_len) {
      const path = readStr(path_ptr, path_len);
      const f = vfs.get(path);
      return f != null ? f.length : -1;
    },

    vfs_file_read(path_ptr, path_len, dest, dlen) {
      const path = readStr(path_ptr, path_len);
      const f = vfs.get(path);
      if (!f) return -1;
      return writeBytes(dest, dlen, f);
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
      return 0; // flat VFS — directories are implicit
    },

    vfs_dir_list_len(path_ptr, path_len) {
      const dir = readStr(path_ptr, path_len);
      const prefix = dir.endsWith('/') ? dir : dir + '/';
      let total = 0;
      for (const k of vfs.keys()) {
        if (!k.startsWith(prefix)) continue;
        const rel = k.slice(prefix.length);
        if (rel.includes('/')) continue; // skip subdirectory entries
        total += enc.encode(rel).length + 1; // NUL-terminated
      }
      return total > 0 ? total : -1;
    },

    vfs_dir_list_read(path_ptr, path_len, dest, dlen) {
      const dir = readStr(path_ptr, path_len);
      const prefix = dir.endsWith('/') ? dir : dir + '/';
      const view = new Uint8Array(mem.buffer, dest, dlen);
      let pos = 0;
      for (const k of vfs.keys()) {
        if (!k.startsWith(prefix)) continue;
        const rel = k.slice(prefix.length);
        if (rel.includes('/')) continue;
        const b = enc.encode(rel);
        if (pos + b.length + 1 > dlen) break;
        view.set(b, pos);
        pos += b.length;
        view[pos++] = 0;
      }
      return pos;
    },

    // ── Platform ───────────────────────────────────────────────────────── //

    platform_open_url(ptr, len) {
      const url = readStr(ptr, len);
      window.open(url, '_blank', 'noopener,noreferrer');
    },

    platform_http_get_start(url_ptr, url_len, req_id) {
      const url = readStr(url_ptr, url_len);
      httpReqs.set(req_id, { status: 'pending' });
      fetch(url)
        .then(r => r.arrayBuffer())
        .then(ab => httpReqs.set(req_id, { status: 'done', data: new Uint8Array(ab) }))
        .catch(() => httpReqs.set(req_id, { status: 'error' }));
    },

    platform_http_get_poll(req_id, buf_ptr, buf_len) {
      const req = httpReqs.get(req_id);
      if (!req || req.status === 'pending') return -1;
      if (req.status === 'error') { httpReqs.delete(req_id); return -2; }
      const n = writeBytes(buf_ptr, buf_len, req.data);
      httpReqs.delete(req_id);
      return n;
    },

    platform_env_get(_name_ptr, _name_len, _out_ptr, _out_len) {
      return -1; // browser has no process environment
    },
  };

  return {
    imports,
    /** Must be called with instance.exports.memory after WASM instantiation. */
    setMemory(memory) { mem = memory; },
  };
})();
