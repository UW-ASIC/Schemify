# Handoff: Implement Plugin Distribution System

## Context

Read `docs/PLAN-plugin-distribution.md` for the full spec. All design decisions are final — do not re-litigate. This is an implementation session.

Read `CLAUDE.md` and memory files for project conventions (ADR-002 handler boundary, core vs state, caveman mode, data-oriented design).

## Existing Code

The plugin system already has working foundations:

- **Transport:** `crates/plugins/src/transport/` — subprocess + WASM transports, `PluginTransport` trait
- **Manager:** `crates/plugins/src/manager.rs` — discovery, lifecycle state machine, `PluginSlot`, `tick()` drain loop
- **Manifest:** `crates/plugins/src/manifest.rs` — `plugin.toml` parsing (needs new fields: `id`, `api_version`, `[sandbox]`, `[events]`)
- **Capability:** `crates/plugins/src/capability.rs` — negotiation logic, `HostCapabilities` already has `api_version`
- **Host:** `crates/plugins/src/host.rs` — JSON-RPC request/notification handling, `HostAction` enum
- **JSON-RPC:** `crates/plugins/src/jsonrpc.rs` — protocol encoding/decoding
- **Handler state:** `crates/handler/src/state.rs` — `PluginUiState`, `MarketplaceState`, `PluginPanel`, `PluginLoadState` already declared
- **Config:** `crates/io/src/config.rs` — `[plugins] enabled/disabled` already parsed
- **Display:** `crates/display/src/plugin_panels.rs` — panel rendering (stub)
- **Core types:** `crates/core/src/plugin_types.rs` — `SlotId`, `PanelRegistration`, `OverlayLayer`

Handler does NOT yet depend on `schemify-plugins` crate. Plugin manager is not instantiated at runtime.

## Implementation Order

Follow phases in the plan. Each phase should compile and pass tests before moving to the next.

### Phase 1: Core Install Pipeline

1. Add `id` field validation to manifest parsing (`[a-z0-9][a-z0-9-]*[a-z0-9]`, 3-64 chars)
2. Add `dirs` crate to `crates/io/Cargo.toml`. Implement `fn global_plugins_dir() -> PathBuf` and `fn cache_dir() -> PathBuf` using platform-native paths
3. Implement `PluginAction` enum and `ActionResult` enum in handler (see plan Section 17)
4. Implement `plugin-lock.toml` read/write in `crates/io/` — `LockFile { installed: Vec<LockEntry> }` with serde
5. Implement install logic in handler: `fn install_actions(source: &str, version: Option<&str>) -> Result<Vec<PluginAction>>` — returns action plan, no IO
6. Implement uninstall logic: `fn uninstall_preview(id: &str) -> UninstallPlan` and `fn uninstall_actions(id: &str) -> Vec<PluginAction>`
7. Implement `fn list_installed() -> Vec<InstalledPlugin>` reading lock file + scanning both dirs
8. Add `schemify plugin install/uninstall/list` CLI subcommands that execute the action plans
9. Global + project-local scan with precedence (project-local wins on name collision)

### Phase 2: Registry

1. Create `registry.db` schema (see plan Section 3 SQL)
2. Implement `fn fetch_registry_actions() -> Vec<PluginAction>` — produces download action for registry.db
3. Implement `RegistryCache` in handler state — holds DB path, last fetch timestamp, stale flag
4. Implement `fn search_registry(query: &str) -> Vec<RegistryEntry>` — FTS5 query against cached DB
5. Implement `fn resolve_version(id: &str, version: Option<&str>) -> Result<ResolvedVersion>` — semver resolution from DB
6. Add `schemify plugin search` CLI subcommand
7. Cache TTL: 24h, `--refresh` flag forces re-fetch

### Phase 3: Security

1. Add SHA256 verification step to install action chain — compare downloaded tarball hash against registry.db entry
2. Integrate cosign verification as a `PluginAction::VerifyCosign` step. CLI executes via `cosign verify-blob` subprocess call
3. Add `--offline` flag: skips cosign, keeps SHA256, prints warning
4. Reject on any verification failure. No partial installs.

### Phase 4: Sandbox

1. Define `PluginSandbox` trait and `SandboxPolicy` struct in `crates/plugins/src/sandbox/mod.rs`
2. Parse `[sandbox]` section from `plugin.toml` into `SandboxPolicy`
3. Implement Linux sandbox: `sandbox/linux.rs` — landlock (fs restrictions) + seccomp (syscall filter)
4. Implement macOS sandbox: `sandbox/macos.rs` — `sandbox-exec` with generated seatbelt profile
5. Implement Windows sandbox: `sandbox/windows.rs` — restricted tokens + job objects
6. Fallback: warn user "no OS sandbox available", proceed with protocol-only gating
7. Apply sandbox before subprocess spawn in transport layer
8. Variable expansion in sandbox paths: `$PLUGIN_DIR`, `$PROJECT_DIR`

### Phase 5: Update & Lifecycle

1. On app launch: handler compares `plugin-lock.toml` against `registry.db`, produces `Vec<PluginUpdate>`
2. Add `updates_available` field to handler state
3. Implement `fn update_actions(id: &str) -> Vec<PluginAction>` and `fn update_all_actions() -> Vec<PluginAction>`
4. Add `schemify plugin update` / `--all` CLI subcommands
5. Add extended lifecycle events to JSON-RPC protocol: `project_opened`, `project_closed`, `schematic_changed`, `pre_save`, `post_save`, `plugin_updated`, `suspend`, `resume`
6. Parse `[events] listen` from manifest, store subscriptions per plugin in manager
7. Only send subscribed events. `initialize` and `shutdown` always sent.

### Phase 6: Authoring Toolkit

1. `schemify plugin new <id> --runtime subprocess` — scaffold plugin dir with `plugin.toml`, entry point template, `.github/workflows/release.yml` (with cosign signing step), README
2. `schemify plugin dev ./path/` — load from path, bypass registry, hot-reload on file change, stream JSON-RPC to stderr
3. `schemify plugin validate ./path/` — check schema, api_version compat, sandbox policy, dry-run transport spawn
4. `schemify plugin package ./path/` — create flat tarball, compute + print SHA256

### Phase 7: Publishing

1. `schemify plugin publish github:user/repo` — handler produces `RegistryEntry` via `publish_prepare()`, CLI handles GitHub API (needs `GITHUB_TOKEN` or `gh` auth)
2. CLI: create branch, commit TOML to `plugins/{id}.toml`, open PR to `schemify-registry`

### Phase 8: Marketplace GUI

1. Add marketplace panel to egui display: search bar, installed list, available list
2. Plugin detail view: name, author, description, version, runtime, api_version
3. README display (lazy fetch from GitHub, cached in `{cache_dir}/readmes/`)
4. Install/Remove/Update buttons dispatch handler actions
5. Update badge when `updates_available` non-empty

### Phase 9: Ratings

1. Add `discussion`, `rating_up`, `rating_down` fields to registry DB + entry format
2. Display ratings in marketplace GUI (`23+ / 2-`)
3. Link to GitHub Discussion from detail view
4. Registry CI: scrape GitHub Discussion reactions, bake counts into DB

## Key Constraints

- **Handler never does IO.** Handler produces `Vec<PluginAction>`, CLI/GUI executes and reports `ActionResult` back. This is non-negotiable.
- **No inter-plugin dependencies.** Plugins are self-contained.
- **Fail fast.** Any verification failure aborts the operation. No `--skip-verify`.
- **Caller retries transient errors** (network, DNS) 3x with backoff. Handler only sees final success/failure.
- **Keep existing plugin system working.** Don't break transport, manager, capability negotiation, or host action handling.
- Follow ADR conventions: core = types only, handler = opaque state + dispatch, string interning on receipt.
