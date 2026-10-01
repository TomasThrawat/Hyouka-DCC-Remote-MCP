#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/.hyouka-dcc"
mkdir -p "$LOG_DIR" "$LOG_DIR/pids"

BLENDER_LOG="$LOG_DIR/blender.log"
KRITA_LOG="$LOG_DIR/krita.log"

stop_pid() {
  local file="$1"
  if [ -f "$file" ]; then
    local pid
    pid="$(cat "$file" || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$file"
  fi
}

stop_pid "$LOG_DIR/pids/blender"
stop_pid "$LOG_DIR/pids/krita"

export PATH="$HOME/.local/bin:$PATH"
export DCC_PYTHON_PATH="$HOME/dcc-python"

export PORT=10000
export DCC_MCP_INNER_PORT=10002
nohup "$HOME/blender/blender" \
  --background --python "$ROOT/blender/entrypoint.py" \
  > "$BLENDER_LOG" 2>&1 &
BLENDER_PID=$!
echo "$BLENDER_PID" > "$LOG_DIR/pids/blender"

for _ in $(seq 1 120); do
  grep -q 'MCP_URL=' "$BLENDER_LOG" && break
  kill -0 "$BLENDER_PID" 2>/dev/null || { tail -200 "$BLENDER_LOG"; exit 1; }
  sleep 2
done
grep -q 'MCP_URL=' "$BLENDER_LOG"

export PORT=10001
export DCC_MCP_INNER_PORT=10003
nohup python3 "$ROOT/krita/entrypoint.py" \
  > "$KRITA_LOG" 2>&1 &
KRITA_PID=$!
echo "$KRITA_PID" > "$LOG_DIR/pids/krita"

for _ in $(seq 1 150); do
  grep -q 'KRITA_MCP_URL=' "$KRITA_LOG" && break
  kill -0 "$KRITA_PID" 2>/dev/null || { tail -200 "$KRITA_LOG"; exit 1; }
  sleep 2
done
grep -q 'KRITA_MCP_URL=' "$KRITA_LOG"

if command -v gh >/dev/null 2>&1; then
  gh codespace ports visibility 10000:public 10001:public -c "$CODESPACE_NAME" || true
fi

BLENDER_URL="https://$CODESPACE_NAME-10000.app.github.dev/mcp"
KRITA_URL="https://$CODESPACE_NAME-10001.app.github.dev/mcp"

python3 - "$ROOT" "$BLENDER_URL" "$KRITA_URL" <<'PY'
import datetime as dt
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
blender_url = sys.argv[2]
krita_url = sys.argv[3]
now = dt.datetime.now(dt.timezone.utc)
expires = now + dt.timedelta(hours=4)

for provider, value in (("blender", blender_url), ("krita", krita_url)):
    path = root / "runtime" / (provider + "-endpoint.json")
    payload = {
        "url": value,
        "updatedAt": now.isoformat(),
        "expiresAt": expires.isoformat(),
        "provider": provider + "-mcp",
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

subprocess.run(["git", "config", "user.name", "github-actions[bot]"], cwd=root, check=False)
subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], cwd=root, check=False)
subprocess.run(["git", "add", "runtime/blender-endpoint.json", "runtime/krita-endpoint.json"], cwd=root, check=False)
subprocess.run(["git", "commit", "-m", "chore: publish live Codespace DCC endpoints [skip ci]"], cwd=root, check=False)

for _ in range(6):
    subprocess.run(["git", "fetch", "origin", "main"], cwd=root, check=False)
    subprocess.run(["git", "rebase", "origin/main"], cwd=root, check=False)
    result = subprocess.run(["git", "push", "origin", "HEAD:main"], cwd=root, check=False)
    if result.returncode == 0:
        break
PY

cat > "$LOG_DIR/status.txt" <<EOF
BLENDER_MCP_URL=$BLENDER_URL
KRITA_MCP_URL=$KRITA_URL
CODESPACE_NAME=$CODESPACE_NAME
EOF

echo "BLENDER_MCP_URL=$BLENDER_URL"
echo "KRITA_MCP_URL=$KRITA_URL"

wait
