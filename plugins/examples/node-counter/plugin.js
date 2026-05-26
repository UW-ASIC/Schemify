#!/usr/bin/env node
/**
 * SchemifyRS plugin in Node.js.
 *
 * Demonstrates:
 * - Reading JSON-RPC from stdin line-by-line
 * - Maintaining internal state (edit counter)
 * - Registering commands
 * - Dispatching schematic commands back to the host
 * - Setting the status bar
 */

const readline = require("readline");

// --- JSON-RPC helpers ---

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function notify(method, params) {
  const msg = { jsonrpc: "2.0", method };
  if (params !== undefined) msg.params = params;
  send(msg);
}

function log(message, level = "info") {
  notify("host/log", { level, message });
}

function setStatus(message) {
  notify("host/set_status", { message });
}

// --- Plugin state ---

let editCount = 0;

function updateStatus() {
  setStatus(`Edits: ${editCount}`);
}

// --- Message handling ---

function handleMessage(msg) {
  const { method, params, id, result, error } = msg;

  // Response to our request (if we ever make one)
  if (method === undefined && id !== undefined) {
    return;
  }

  switch (method) {
    case "lifecycle/initialize":
      log("node-counter initialized");
      // Register our reset command
      notify("commands/register", {
        name: "counter_reset",
        description: "Reset the edit counter",
      });
      updateStatus();
      break;

    case "lifecycle/shutdown":
      log(`final count: ${editCount}`);
      process.exit(0);
      break;

    case "state/schematic_changed":
      editCount++;
      updateStatus();
      if (editCount % 10 === 0) {
        log(`milestone: ${editCount} edits`);
      }
      break;

    default:
      if (method) log(`unhandled: ${method}`);
  }
}

// --- Main loop ---

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;
  try {
    handleMessage(JSON.parse(line));
  } catch (e) {
    log(`parse error: ${e.message}`, "warn");
  }
});

rl.on("close", () => process.exit(0));
