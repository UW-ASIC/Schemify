# Plugin Distribution Plan

> Decisions made via design interview, 2026-05-20.
> Scope: plugin registry, discovery, install, update, security, marketplace.

## Table of Contents

- [1. Overview](#1-overview)
- [2. Architecture Principles](#2-architecture-principles)
- [3. Registry](#3-registry)
- [4. Package Format](#4-package-format)
- [5. Plugin Naming & Versioning](#5-plugin-naming--versioning)
- [6. CLI Commands](#6-cli-commands)
- [7. Install & Uninstall Flow](#7-install--uninstall-flow)
- [8. Update Mechanism](#8-update-mechanism)
- [9. Security](#9-security)
- [10. Sandbox](#10-sandbox)
- [11. Marketplace GUI](#11-marketplace-gui)
- [12. Ratings & Reviews](#12-ratings--reviews)
- [13. Offline Support](#13-offline-support)
- [14. Plugin Authoring Toolkit](#14-plugin-authoring-toolkit)
- [15. Publishing Workflow](#15-publishing-workflow)
- [16. Lifecycle Events](#16-lifecycle-events)
- [17. Handler Boundary](#17-handler-boundary)
- [18. Error Handling](#18-error-handling)
- [19. File Layout](#19-file-layout)
- [20. Manifest Extensions](#20-manifest-extensions)
- [21. Implementation Phases](#21-implementation-phases)

---

## 1. Overview

Plugin distribution for SchemifyRS targets a developer community at scale (100+ plugins).
Distribution uses GitHub Releases as the transport, a curated Git registry repo
as the source of truth, and a SQLite database published as a release artifact for
client-side querying. Security is enforced via SHA256 hashes, cosign (sigstore)
keyless signatures, and OS-level sandboxing.

## 2. Architecture Principles

- **Handler = brain, caller = hands.** Handler produces an action plan
  (`Vec<PluginAction>`), never performs IO. CLI/GUI execute IO steps and report
  results back to handler. (Aligns with ADR-002.)
- **No inter-plugin dependencies.** Each plugin is fully self-contained.
- **Platform-native paths** via the `dirs` crate. Works on Linux, macOS, Windows.
- **Install locations:** global (platform data dir) + project-local (`./plugins/`).
  Project-local takes precedence on name collision.

## 3. Registry

### Structure

A dedicated `schemify-registry` GitHub repository. Plugin authors submit PRs to
add or update their plugin metadata.

```
schemify-registry/
  plugins/
    pdk-switcher.toml
    generator.toml
    spice-export.toml
  schema.sql
  .github/workflows/
    validate.yml        # PR validation
    build-registry.yml  # builds SQLite DB, attaches to GitHub Release
```

### Registry Entry Format

```toml
[plugin]
id = "pdk-switcher"
name = "PDK Switcher"
description = "Switch between PDK configurations"
source = "github:user/pdk-switcher"
api_version = 1
tags = ["pdk", "config"]
discussion = "https://github.com/org/schemify-registry/discussions/42"

[[versions]]
version = "1.2.0"
sha256 = "abc123def456..."
cosign_identity = "github:user/pdk-switcher"

[[versions]]
version = "1.1.0"
sha256 = "789xyz..."
cosign_identity = "github:user/pdk-switcher"
```

### SQLite Artifact

Registry CI builds a `registry.db` from all plugin TOML files and attaches it
as a GitHub Release artifact. Clients download this single file (~100KB at
1000 plugins) for local querying.

Schema:

```sql
CREATE TABLE plugins (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT,
    source      TEXT NOT NULL,
    api_version INTEGER NOT NULL,
    tags        TEXT,  -- comma-separated
    discussion  TEXT,
    rating_up   INTEGER DEFAULT 0,
    rating_down INTEGER DEFAULT 0
);

CREATE TABLE versions (
    plugin_id       TEXT NOT NULL REFERENCES plugins(id),
    version         TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    cosign_identity TEXT NOT NULL,
    PRIMARY KEY (plugin_id, version)
);

CREATE VIRTUAL TABLE plugins_fts USING fts5(id, name, description, tags);
```

### Registry CI Validation (on PR)

1. Parse submitted TOML against schema.
2. Verify GitHub source repo exists.
3. Verify semver-tagged release exists.
4. Download tarball, verify cosign signature.
5. Compute SHA256, store in entry.
6. Validate `plugin.toml` inside tarball (api_version, id match).
7. Rebuild `registry.db`, attach to new GitHub Release.

### Caching

- Client stores `registry.db` at `{data_dir}/schemify/cache/registry.db`.
- TTL: 24 hours. Auto-refresh on `schemify plugin search` if stale.
- `schemify plugin search --refresh` forces re-fetch.
- Offline: use stale cache, warn user.

## 4. Package Format

Flat tarball. `plugin.toml` at archive root.

```
schemify-plugin-{id}-{version}.tar.gz
  plugin.toml
  entry_point.py    (or .wasm, or binary)
  lib/
  assets/
  README.md
```

- Naming convention: `schemify-plugin-{id}-{version}.tar.gz`
- Attached to GitHub Release tagged `v{version}`.
- Author creates with `schemify plugin package`.

## 5. Plugin Naming & Versioning

### Naming

Two fields in `plugin.toml`:

```toml
[plugin]
id = "pdk-switcher"      # machine name
name = "PDK Switcher"    # display name
```

`id` rules:
- Lowercase alphanumeric + hyphens: `[a-z0-9][a-z0-9-]*[a-z0-9]`
- 3-64 characters
- No leading/trailing hyphens
- Unique across registry (first-come-first-served)
- Used as directory name on disk

### Versioning

- Semver enforced. GitHub Release tag must be `v{semver}`.
- `plugin.toml` `version` field must match release tag.
- `schemify plugin install github:user/repo` installs latest semver release.
- `schemify plugin install github:user/repo@1.2.0` installs exact version.
- Semver ranges (`^1.0`, `>=1.2`) deferred to future version.

### API Compatibility

Integer `api_version` in `plugin.toml`. Host supports a range `[min_api..=current_api]`.
Plugin refused to load if outside range, with clear error message.

```toml
[plugin]
api_version = 1
```

## 6. CLI Commands

```
schemify plugin install github:user/repo            # latest version
schemify plugin install github:user/repo@1.2.0      # exact version
schemify plugin install --from-file ./tarball.tar.gz # offline install
schemify plugin uninstall <id>
schemify plugin update <id>
schemify plugin update --all
schemify plugin list                                 # installed plugins
schemify plugin search <query>
schemify plugin search --refresh                     # force registry refresh

# Authoring
schemify plugin new <id> --runtime subprocess        # scaffold
schemify plugin dev ./path/                          # live reload + debug
schemify plugin validate ./path/                     # pre-publish checks
schemify plugin package ./path/                      # create tarball
schemify plugin publish github:user/repo             # open registry PR
```

- `install`/`search`/`publish` use `github:` prefix (extensible to `oci:`, `file:` later).
- `uninstall`/`update` use plugin `id`.
- Default install target = global. `--project` flag for project-local.

## 7. Install & Uninstall Flow

### Install

```
1. Resolve version (latest or exact) via registry.db
2. Download tarball from GitHub Release
3. Verify SHA256 against registry.db         -> reject on mismatch
4. Verify cosign signature against identity   -> reject on mismatch
5. Extract to temp dir
6. Validate plugin.toml schema + api_version  -> reject if incompatible
7. Move to target plugins dir
8. Update plugin-lock.toml
9. Notify user of success
```

Reject at any step. No partial installs. Temp dir cleaned on failure.

### Uninstall

Full cleanup with confirmation:

```
$ schemify plugin uninstall pdk-switcher

Will remove:
  Plugin dir:  ~/.local/share/schemify/plugins/pdk-switcher/
  Lock entry:  pdk-switcher@1.2.0
  Plugin data: 2.3 KB stored state

Proceed? [y/N]
```

- Send `lifecycle/shutdown` if running.
- Delete plugin directory.
- Remove from `plugin-lock.toml`.
- Remove plugin data blob from `AppState.plugin_data`.
- `--keep-data` flag preserves state blob for reinstall.

## 8. Update Mechanism

Check on launch + prompt user.

1. App startup: handler compares `plugin-lock.toml` versions against cached `registry.db`.
2. If `registry.db` stale (>24h): background fetch new DB.
3. If updates available: handler sets `updates_available: Vec<PluginUpdate>` in state.
4. GUI: badge on plugin panel. CLI: shown on `schemify plugin list`.
5. User confirms update. Full install flow (download, verify, extract, replace).
6. Lock file updated after success.

```rust
struct PluginUpdate {
    id: String,
    current: Version,
    available: Version,
    breaking: bool,  // api_version changed
}
```

Breaking api_version changes get a separate, prominent warning.

## 9. Security

### Install-Time Verification

Full chain, every install:

1. **SHA256 hash** - registry.db stores hash per version. Verified after download.
2. **Cosign (sigstore)** - keyless signing tied to GitHub Actions OIDC identity.
   Author's release CI signs tarball. Verification checks signature + identity.
3. **Registry CI re-verification** - on PR submission, CI independently downloads
   tarball, verifies cosign signature, computes SHA256, validates metadata.

### Runtime Security

4. **WASM plugins** - sandboxed by wasmtime. Capability negotiation limits host API.
5. **Subprocess plugins** - OS-level sandbox + protocol-level capability gating.

### Rejection Policy

Any verification failure = hard reject. No `--skip-verify` flag.
Exception: `--offline` skips cosign (not SHA256) with explicit warning.

## 10. Sandbox

Hybrid: OS-level sandbox + protocol-level capability gating. Graceful degradation
on platforms without sandbox support.

### Abstraction

```rust
trait PluginSandbox {
    fn apply(config: &SandboxPolicy) -> Result<(), SandboxError>;
}

struct SandboxPolicy {
    allow_network: bool,
    allowed_paths: Vec<(PathBuf, Permission)>,  // read/write/none
    max_memory_mb: u32,
    max_cpu_seconds: u32,
}
```

### Platform Implementations

| Platform | Filesystem      | Syscalls     | Resources         |
|----------|-----------------|--------------|-------------------|
| Linux    | Landlock        | seccomp      | cgroups / rlimits |
| macOS    | sandbox-exec    | seatbelt     | rlimits           |
| Windows  | Restricted tokens | Job objects | Job objects       |

### Fallback

If no sandbox available on platform: warn user, proceed with protocol-only gating.
Never silently run unsandboxed.

### Manifest Declaration

Plugins declare required permissions:

```toml
[sandbox]
network = false
paths = [
    { path = "$PLUGIN_DIR", access = "read" },
    { path = "$PROJECT_DIR", access = "read" },
]
```

Host enforces declared permissions via sandbox. Plugin cannot exceed declared scope.

## 11. Marketplace GUI

Full in-app marketplace panel for browsing, installing, updating, and removing plugins.

```
+-- Plugins ------------------------------------+
| [Search: ________] [Refresh]                  |
|                                               |
| Installed (3)                                 |
|  pdk-switcher  1.2.0  [Update]               |
|  generator     0.5.1  [Remove]               |
|  linter        2.0.0                          |
|                                               |
| Available (12)                                |
|  spice-export  1.0.0  23+ 2-  [Install]      |
|  netlist-diff  0.3.0  15+ 0-  [Install]      |
|  ...                                          |
|                                               |
| --- pdk-switcher ---                          |
| by: user | api: v1 | subprocess               |
| Switch between PDK configurations             |
| [README]                                      |
| Rating: 23+ / 2-                              |
| [View Discussion]                             |
+-----------------------------------------------+
```

### Handler Functions

```rust
fn search_registry(query: &str) -> Vec<RegistryEntry>
fn plugin_detail(id: &str) -> Option<PluginDetail>
fn install_actions(id: &str, version: Option<&str>) -> Result<Vec<PluginAction>>
fn uninstall_preview(id: &str) -> Result<UninstallPlan>
fn update_actions(id: &str) -> Result<Vec<PluginAction>>
```

GUI and CLI both consume these. Handler produces actions, caller executes.

README fetched lazily from GitHub on plugin selection, cached locally.

## 12. Ratings & Reviews

GitHub Discussions as backend. Zero infrastructure.

### Setup

- Each plugin gets a Discussion thread in `schemify-registry` repo.
- `discussion` URL stored in registry entry.
- Users rate via GitHub reactions: thumbs-up = positive, thumbs-down = negative.
- Reviews = Discussion replies (threaded, markdown, editable).

### Aggregation

- Registry CI scrapes reaction counts periodically.
- Counts baked into `registry.db` as `rating_up` / `rating_down`.
- Stale by hours — acceptable for ratings.

### Display

- Marketplace GUI shows `23+ / 2-` next to each plugin.
- Detail view links to Discussion thread for full reviews.

## 13. Offline Support

Pre-seeding for air-gapped environments (common in semiconductor labs).

```
$ schemify plugin install --from-file ./pdk-switcher-1.2.0.tar.gz --offline

Warning: Offline mode - signature verification skipped.
SHA256 verified against cached registry.
Installed pdk-switcher@1.2.0
```

- Cached `registry.db` works offline for search/browse.
- `--from-file` installs from local tarball.
- SHA256 always verified if registry.db cached.
- Cosign verification skipped with `--offline` flag + explicit warning.
- No `--skip-verify` flag. Hash check never skippable.

## 14. Plugin Authoring Toolkit

### `schemify plugin new`

```
$ schemify plugin new my-plugin --runtime subprocess
```

Scaffolds:
- `plugin.toml` with id, name, version, runtime, api_version, sandbox defaults
- Entry point template (Python / Rust / JS based on runtime)
- `.github/workflows/release.yml` with cosign signing step
- `README.md` template

### `schemify plugin dev`

```
$ schemify plugin dev ./my-plugin/
```

- Loads plugin from arbitrary local path, bypasses registry.
- Hot-reloads on file change.
- Streams JSON-RPC messages to stderr for debugging.
- No sandbox enforcement (dev mode).

### `schemify plugin validate`

```
$ schemify plugin validate ./my-plugin/
```

Checks:
- `plugin.toml` schema validity
- `api_version` compatibility with current host
- Sandbox policy coherence
- Dry-run transport spawn (can the entry point start?)
- Entry point exists and is executable

### `schemify plugin package`

```
$ schemify plugin package ./my-plugin/
```

- Creates `schemify-plugin-{id}-{version}.tar.gz`
- Computes and prints SHA256.
- Validates contents before packaging.
- Ready to attach to GitHub Release.

## 15. Publishing Workflow

CLI-assisted PR to registry repo, with manual fallback.

```
$ schemify plugin publish github:user/pdk-switcher

Verifying release exists...        v1.2.0
Verifying cosign signature...      ok
Computing SHA256...                abc123...
Checking api_version compat...     api v1

Registry entry:
  id: pdk-switcher
  name: PDK Switcher
  version: 1.2.0
  source: github:user/pdk-switcher
  sha256: abc123...
  api_version: 1

Open PR to schemify-registry? [y/N]
```

- Requires `GITHUB_TOKEN` env var or `gh` CLI auth.
- Creates branch, commits TOML, opens PR via GitHub API.
- Registry CI validates independently on PR.
- Manual PR always available as fallback.

### Handler Boundary

Handler owns: `fn publish_prepare(source: &str) -> Result<RegistryEntry>`
(pure validation + metadata gathering).

CLI owns: GitHub API interaction (auth, branch, commit, PR creation).

## 16. Lifecycle Events

Extended lifecycle. Plugins opt-in via manifest.

### Events

```
lifecycle/initialize          # existing - plugin started
lifecycle/shutdown            # existing - plugin stopping
lifecycle/project_opened      # project dir, config
lifecycle/project_closed
lifecycle/schematic_changed   # active schematic switched
lifecycle/pre_save            # chance to flush state
lifecycle/post_save
lifecycle/plugin_updated      # new version running after update
lifecycle/suspend             # app going to background
lifecycle/resume
```

### Opt-In

```toml
[events]
listen = ["project_opened", "pre_save", "schematic_changed"]
```

Only subscribed events sent to plugin. Handler tracks subscriptions per plugin.
`lifecycle/initialize` and `lifecycle/shutdown` always sent (not opt-in).

## 17. Handler Boundary

Handler produces action plans. Never performs IO.

```rust
enum PluginAction {
    FetchRegistryDb { url: String },
    DownloadTarball { url: String, expected_sha: String },
    VerifyCosign { tarball_path: PathBuf, identity: String },
    Extract { tarball_path: PathBuf, dest: PathBuf },
    UpdateLock { entry: LockEntry },
    RemoveDir { path: PathBuf },
    RemovePluginData { id: String },
    SendLifecycle { plugin_id: String, event: String },
    Notify { message: String },
}

enum ActionResult {
    Success { action_id: usize, data: Option<Vec<u8>> },
    Failed { action_id: usize, error: ActionError },
}
```

Caller (CLI/GUI) executes actions sequentially, reports results back:

```rust
handler.report_action_result(action_id, result);
```

## 18. Error Handling

Caller retries transient failures. Handler sees only final result.

### Transient (caller retries 3x with backoff)

- Network timeout
- DNS resolution failure
- HTTP 5xx responses

### Non-Transient (immediate fail to handler)

- SHA256 mismatch
- Cosign signature invalid
- Corrupt tarball
- Disk full / permission denied
- api_version incompatible

Handler receives `ActionResult::Failed`, updates state, emits cleanup actions
(e.g., remove temp dir).

## 19. File Layout

### Global (platform-native via `dirs` crate)

```
{dirs::data_dir()}/schemify/
  plugins/                    # installed plugins
    pdk-switcher/
      plugin.toml
      ...
  cache/
    registry.db               # cached registry
    readmes/                  # cached plugin READMEs
      pdk-switcher.md

{dirs::config_dir()}/schemify/
  plugin-lock.toml            # installed versions + hashes
```

### Project-Local

```
./plugins/                    # project-scoped plugins (overrides global)
  my-dev-plugin/
    plugin.toml
    ...
./Config.toml                 # [plugins] enabled/disabled
```

### Lock File Format

```toml
[[installed]]
id = "pdk-switcher"
version = "1.2.0"
source = "github:user/pdk-switcher"
sha256 = "abc123..."
location = "global"           # or "project"
```

## 20. Manifest Extensions

Full `plugin.toml` with all new fields:

```toml
[plugin]
id = "pdk-switcher"
name = "PDK Switcher"
version = "1.0.0"
description = "Switch between PDK configurations"
entry = "plugin.py"
runtime = "subprocess"        # subprocess | wasm | native
api_version = 1

[capabilities]
panels = true
commands = true
overlays = false
theme = false

[sandbox]
network = false
paths = [
    { path = "$PLUGIN_DIR", access = "read" },
    { path = "$PROJECT_DIR", access = "read" },
]

[events]
listen = ["project_opened", "pre_save", "schematic_changed"]

[[panels.panel]]
name = "PDK Config"
slot = "RightSidebar"
priority = 10

[[commands.command]]
name = "switch_pdk"
description = "Switch active PDK"
keybind = "Ctrl+Shift+P"
```

## 21. Implementation Phases

### Phase 1: Core Install Pipeline

- Plugin naming validation (`id` rules)
- `dirs` crate integration for platform-native paths
- `schemify plugin install github:user/repo` (download + extract)
- `schemify plugin uninstall <id>` with confirmation
- `schemify plugin list`
- `plugin-lock.toml` read/write
- Global + project-local scan with precedence
- Handler `PluginAction` / `ActionResult` pattern

### Phase 2: Registry

- Create `schemify-registry` repo with schema
- Registry CI: validate PR, build SQLite DB, publish as release
- `registry.db` download + caching (24h TTL)
- `schemify plugin search <query>` with FTS
- Version resolution (latest + exact)

### Phase 3: Security

- SHA256 verification on install
- Cosign signature verification on install
- Registry CI cosign verification on PR
- `--offline` flag (skip cosign, keep SHA256)

### Phase 4: Sandbox

- `PluginSandbox` trait + `SandboxPolicy` struct
- Linux impl: landlock + seccomp
- macOS impl: sandbox-exec / seatbelt
- Windows impl: restricted tokens + job objects
- Fallback: warn + protocol-only gating
- `[sandbox]` manifest section enforcement

### Phase 5: Update & Lifecycle

- Update check on launch
- `schemify plugin update` / `--all`
- `PluginUpdate` state + GUI badge
- Extended lifecycle events (`project_opened`, `pre_save`, etc.)
- Event opt-in via `[events]` manifest section

### Phase 6: Authoring Toolkit

- `schemify plugin new` scaffolding (templates per runtime)
- `schemify plugin dev` live reload + JSON-RPC debug log
- `schemify plugin validate` pre-publish checks
- `schemify plugin package` tarball creation

### Phase 7: Publishing

- `schemify plugin publish` CLI (metadata gather + GitHub PR)
- `GITHUB_TOKEN` / `gh` CLI auth integration

### Phase 8: Marketplace GUI

- Marketplace panel in egui (search, browse, install, remove, update)
- Plugin detail view with README (lazy-fetched, cached)
- Ratings display (`rating_up` / `rating_down` from registry.db)
- Link to GitHub Discussion for reviews

### Phase 9: Ratings

- GitHub Discussions setup in registry repo
- `discussion` URL field in registry entries
- Registry CI scrapes reaction counts into DB
- Marketplace GUI displays ratings + links to discussion

---

## Decision Log

| #  | Topic                      | Decision                                                    |
|----|----------------------------|-------------------------------------------------------------|
| 1  | Plugin authors             | Developer community                                         |
| 2  | Scale target               | 100+ plugins ecosystem                                      |
| 3  | Registry backend           | GitHub Releases (tarballs)                                  |
| 4  | Package format             | Flat tarball, plugin.toml at root                           |
| 5  | Install location           | Global + project-local, project wins                        |
| 6  | Global path                | Platform-native via `dirs` crate                            |
| 7  | Naming                     | `id` (machine, validated) + `name` (display, freeform)      |
| 8  | Version resolution         | Semver from GitHub Release tags                             |
| 9  | API compatibility          | Integer `api_version` in manifest                           |
| 10 | CLI namespace              | `schemify plugin {subcommand}`                              |
| 11 | Discovery                  | Curated registry repo, PR-based submissions                 |
| 12 | Registry format            | Git repo + SQLite artifact on GitHub Release                |
| 13 | Security                   | SHA256 + cosign + OS sandbox + protocol gating              |
| 14 | Subprocess sandbox         | Hybrid: landlock/seccomp/seatbelt + graceful degradation    |
| 15 | Updates                    | Check on launch, prompt user, never auto-install            |
| 16 | Inter-plugin dependencies  | None. Plugins fully self-contained.                         |
| 17 | Uninstall                  | Full cleanup with confirmation + `--keep-data` flag         |
| 18 | Offline support            | `--from-file` + `--offline` (skip cosign, keep SHA256)      |
| 19 | Authoring toolkit          | new / dev / validate / package commands                     |
| 20 | Publishing                 | CLI-assisted PR + manual fallback                           |
| 21 | Handler boundary           | Handler = action plan producer, caller = IO executor        |
| 22 | Error handling             | Caller retries transient, handler sees final result         |
| 23 | Marketplace GUI            | Full in-app marketplace with search + detail view           |
| 24 | Ratings backend            | GitHub Discussions reactions, scraped into registry.db      |
| 25 | Lifecycle events           | Extended (project/schematic/save), opt-in via manifest      |
