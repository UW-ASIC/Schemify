# Live Demo

Browse the Schemify example schematics directly in your browser — no install required.

<div id="schematic-embed" style="width:100%;height:80vh;border:1px solid #1e3a4a;border-radius:6px;overflow:hidden;background:#0d1117;">
  <iframe
    id="schemify-frame"
    src=""
    style="width:100%;height:100%;border:none;"
    title="Schemify live demo"
    loading="lazy"
    allow="fullscreen"
  ></iframe>
</div>

<script>
(function () {
  // Resolve /schematic/ relative to the Pages root regardless of subpath.
  // e.g. https://uwasic.github.io/Schemify/  →  /Schemify/schematic/
  var origin = window.location.origin;
  var pathParts = window.location.pathname.split('/').filter(Boolean);
  // The first path segment is the repo name when hosted at <org>.github.io/<repo>
  var repoSegment = pathParts.length > 0 ? '/' + pathParts[0] : '';
  var viewerUrl = origin + repoSegment + '/schematic/';

  // Probe first — iframe onerror does not fire on 404.
  fetch(viewerUrl, { method: 'HEAD' }).then(function (res) {
    if (res.ok) {
      document.getElementById('schemify-frame').src = viewerUrl;
    } else {
      showFallback();
    }
  }).catch(function () {
    showFallback();
  });

  function showFallback() {
    document.getElementById('schematic-embed').innerHTML =
      '<p style="color:#4ec9b0;padding:24px;font-family:monospace">' +
      'Viewer not available yet \u2014 no WASM release has been published.<br><br>' +
      'Run locally: <code>zig build -Dbackend=web run_local</code> \u2192 http://localhost:8080' +
      '</p>';
  }
})();
</script>

---

## Opening a schematic

| Action | Shortcut |
|--------|----------|
| Switch tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Zoom in/out | scroll wheel |
| Pan | middle-click drag |
| Select all | `Ctrl+A` |
| Fit to view | `F` |
| Toggle symbol/schematic | `E` |

## Running this locally

```bash
git clone https://github.com/UWASIC/Schemify.git
cd Schemify
zig build -Dbackend=web run_local   # → http://localhost:8080
```

Or open a specific project:

```bash
zig build run -- --open examples/cmos_inv
```
