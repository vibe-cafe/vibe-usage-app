#!/bin/bash
# vibe-usage statusline wrapper — installed to ~/.vibe-usage/ by Vibe Usage.app.
#
# Claude Code pipes a JSON status payload (including `rate_limits`) to its
# configured statusLine command on every render. This wrapper:
#   1. captures that stdin once,
#   2. atomically writes the rate-limit slice to ~/.vibe-usage/claude-rate-limits.json
#      (skipping the write when rate_limits is absent/null so we never clobber
#      a good snapshot with an API-model session that has no limits),
#   3. re-feeds the IDENTICAL stdin to the user's original statusLine command
#      (stored verbatim in the sidecar) so their existing HUD is unaffected.
#
# This file is generated/owned by Vibe Usage. Edits will be overwritten on the
# next install/repair.

set -euo pipefail

VIBE_DIR="${HOME}/.vibe-usage"
OUT="${VIBE_DIR}/claude-rate-limits.json"
SIDECAR="${VIBE_DIR}/statusline-original"

# Read the whole payload once; we need it twice (capture + forward).
payload="$(cat)"

# --- 1. Capture rate_limits (best-effort; never block the statusline) ---------
# Prefer the runtime Vibe Usage already requires (bun, then node) for robust JSON
# parsing. Fall back to a pure-shell presence check so capture still works on a
# machine where neither is on PATH at statusline-spawn time.
emit() {
  # $1 = parsed JSON object string to write atomically
  local tmp
  tmp="$(mktemp "${VIBE_DIR}/.claude-rate-limits.XXXXXX")" || return 0
  printf '%s' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

mkdir -p "$VIBE_DIR" 2>/dev/null || true

JS='
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
  try {
    const o = JSON.parse(raw);
    const rl = o && o.rate_limits;
    if (!rl || (rl.five_hour == null && rl.seven_day == null)) { process.exit(2); }
    const out = {
      five_hour: rl.five_hour ?? null,
      seven_day: rl.seven_day ?? null,
      model_id: (o.model && o.model.id) || null,
      captured_at: Math.floor(Date.now() / 1000),
    };
    process.stdout.write(JSON.stringify(out));
    process.exit(0);
  } catch (e) { process.exit(3); }
});
'

RUNTIME=""
if command -v bun >/dev/null 2>&1; then
  RUNTIME="bun"
elif command -v node >/dev/null 2>&1; then
  RUNTIME="node"
fi

if [ -n "$RUNTIME" ]; then
  if parsed="$(printf '%s' "$payload" | "$RUNTIME" -e "$JS" 2>/dev/null)"; then
    [ -n "$parsed" ] && emit "$parsed"
  fi
  # exit codes 2/3 (no rate_limits / parse error) → intentionally skip the write
fi

# --- 2. Forward identical stdin to the user's original statusLine command -----
# The sidecar holds the user's prior statusLine.command verbatim. Running it via
# `sh -c` avoids re-quoting a deeply nested command inside settings.json.
if [ -s "$SIDECAR" ]; then
  ORIGINAL="$(cat "$SIDECAR")"
  printf '%s' "$payload" | exec sh -c "$ORIGINAL"
fi

# No original command (user had no statusline before). Emit nothing.
exit 0
