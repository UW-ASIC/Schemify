window.SchemifyVFS = (() => {
  const files = new Map();
  let worker = null;

  function post(type, payload = {}) {
    worker.postMessage({ type, ...payload });
  }

  function init() {
    return new Promise((resolve, reject) => {
      worker = new Worker("vfs-worker.js");
      worker.onerror = reject;
      worker.onmessage = ({ data }) => {
        if (data.type === "ready") {
          for (const [path, fileData] of data.files) {
            files.set(path, fileData);
          }
          console.log(`[vfs] loaded ${files.size} files from OPFS`);
          resolve();
        }
      };
      post("init");
    });
  }

  function markDirty(path) {
    const data = files.get(path);
    if (data) {
      post("write", { path, data });
    } else {
      post("delete", { path });
    }
  }

  return { files, init, markDirty };
})();
