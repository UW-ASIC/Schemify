---
id: gen/06
title: Add tests to engine crate
status: ready-for-agent
priority: medium
labels: [testing, engine]
---

# Engine crate tests

## Problem

Zero tests for CLI dispatch and plugin_cli subcommand handling. Argument parsing, file I/O error paths, plugin launch sequences untested.

## Acceptance criteria

- [ ] CLI arg parsing tests (clap subcommands)
- [ ] `import-spice` subcommand integration test
- [ ] Error path tests (missing file, bad format)
- [ ] Plugin CLI subcommand tests
