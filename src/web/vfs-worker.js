let root = null;

self.onmessage = async (e) => {
  const { type, path, data } = e.data;
  switch (type) {
    case "init": {
      root = await navigator.storage.getDirectory();
      const files = [];
      await walk(root, "", files);
      self.postMessage({ type: "ready", files });
      break;
    }
    case "write": {
      await writeFile(path, data);
      break;
    }
    case "delete": {
      await deleteFile(path);
      break;
    }
  }
};

async function walk(dir, prefix, out) {
  for await (const [name, handle] of dir) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (handle.kind === "file") {
      const fh = await handle.createSyncAccessHandle();
      const size = fh.getSize();
      const buf = new Uint8Array(size);
      fh.read(buf, { at: 0 });
      fh.close();
      out.push([path, buf]);
    } else {
      await walk(handle, path, out);
    }
  }
}

async function resolveParent(path, create) {
  const parts = path.split("/").filter(Boolean);
  let dir = root;
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await dir.getDirectoryHandle(parts[i], { create });
  }
  return { dir, name: parts[parts.length - 1] };
}

async function writeFile(path, data) {
  const { dir, name } = await resolveParent(path, true);
  const fh = await dir.getFileHandle(name, { create: true });
  const access = await fh.createSyncAccessHandle();
  access.truncate(0);
  access.write(data, { at: 0 });
  access.flush();
  access.close();
}

async function deleteFile(path) {
  try {
    const { dir, name } = await resolveParent(path, false);
    await dir.removeEntry(name);
  } catch (_) { /* not found — fine */ }
}
