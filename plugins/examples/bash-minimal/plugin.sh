#!/usr/bin/env bash
# Minimal SchemifyRS plugin in bash.
# Reads JSON-RPC from stdin, writes to stdout, logs to stderr.

send() { echo "$1"; }
log() { echo "[bash-minimal] $1" >&2; }

log "started"
send '{"jsonrpc":"2.0","method":"host/log","params":{"level":"info","message":"bash plugin alive"}}'
send '{"jsonrpc":"2.0","method":"host/set_status","params":{"message":"Bash plugin loaded"}}'

while IFS= read -r line; do
    method=$(echo "$line" | grep -o '"method":"[^"]*"' | cut -d'"' -f4)
    case "$method" in
    lifecycle/initialize)
        log "initialized"
        ;;
    lifecycle/shutdown)
        log "shutting down"
        exit 0
        ;;
    *)
        log "received: $method"
        ;;
    esac
done
