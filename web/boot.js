import { Dvui } from "./web.js";

const vfs = window.SchemifyVFS;

async function fetchOk(url, reader) {
  try {
    const response = await fetch(url);
    return response.ok ? await response[reader]() : null;
  } catch (_) {
    return null;
  }
}

const fetchText = (url) => fetchOk(url, "text");

async function fetchBytes(url) {
  const buffer = await fetchOk(url, "arrayBuffer");
  return buffer ? new Uint8Array(buffer) : null;
}

function persistFile(path, data) {
  vfs.files.set(path, data);
  vfs.markDirty(path);
}

function parseExampleNames(listingHtml) {
  return [...listingHtml.matchAll(/href="([^"]+\.chn(?:_tb|_prim)?)"/g)].map((m) => m[1]);
}

async function seedBundledFiles() {
  const config = await fetchBytes("Config.toml");
  if (config) {
    persistFile("Config.toml", config);
  }

  const listing = await fetchText("examples/");
  if (!listing) {
    return;
  }

  for (const name of parseExampleNames(listing)) {
    const data = await fetchBytes(`examples/${name}`);
    if (data) {
      persistFile(`examples/${name}`, data);
    }
  }
}

await vfs.init();

if (!vfs.files.has("Config.toml")) {
  console.log("[boot] first run — loading bundled files");
  await seedBundledFiles();
}

const app = new Dvui();
const importObject = {
  dvui: app.imports,
  host: window.SchemifyHost.imports,
};

const result = await WebAssembly.instantiateStreaming(
  fetch("schemify.wasm"),
  importObject
);

window.SchemifyHost.setMemory(result.instance.exports.memory);

app.setInstance(result.instance);
app.setCanvas("#dvui-canvas");
app.run();
