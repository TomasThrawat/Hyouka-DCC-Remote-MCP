#!/usr/bin/env bash
set -euo pipefail

LOG="$RUNNER_TEMP/dcc-runtime.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== DCC RUNTIME START ==="
python3 --version
uname -a

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git python3-venv python3-pip xz-utils openssh-client \
  xvfb dbus-x11 krita python3-pyqt5 x11-xkb-utils \
  libx11-6 libxrender1 libxi6 libxfixes3 libxxf86vm1 libxkbcommon0 \
  libgl1 libglu1-mesa libsm6 libice6 libdbus-1-3 \
  libxcb-xinerama0 libxcb-cursor0 libxcb-keysyms1 libxcb-render-util0 \
  libxcb-shape0 libxcb-randr0 libxcb-image0 libxcb-util1 \
  libxkbcommon-x11-0 libegl1 fonts-dejavu
sudo rm -rf /var/lib/apt/lists/*

python3 - <<'PY'
import PyQt5
print("PYQT5_READY=" + getattr(PyQt5, "__file__", "<unknown>"))
PY

python3 -m venv "$RUNNER_TEMP/dcc-venv"
"$RUNNER_TEMP/dcc-venv/bin/pip" install --upgrade pip
"$RUNNER_TEMP/dcc-venv/bin/pip" install \
  "fastmcp>=2,<4" "httpx>=0.27,<1" "aiohttp>=3.11,<4" "PyJWT[crypto]>=2.9,<3"

mkdir -p "$RUNNER_TEMP/dcc-python"
"$RUNNER_TEMP/dcc-venv/bin/python" -m pip install \
  --target "$RUNNER_TEMP/dcc-python" "dcc-mcp-blender==0.2.9"

mkdir -p "$RUNNER_TEMP/blender"
curl -fL --retry 5 --retry-all-errors \
  "https://download.blender.org/release/Blender5.2/blender-5.2.2-linux-x64.tar.xz" \
  -o "$RUNNER_TEMP/blender.tar.xz"
tar -xJf "$RUNNER_TEMP/blender.tar.xz" -C "$RUNNER_TEMP/blender" --strip-components=1
"$RUNNER_TEMP/blender/blender" --version

REF="5019f58852176aeeb11805126360ff749cd70dce"
mkdir -p "$HOME/.local/share/krita/pykrita/kritamcp" "$HOME/.config"
curl -fL --retry 5 --retry-all-errors \
  "https://raw.githubusercontent.com/nanayax3/krita-mcp/$REF/krita-plugin/kritamcp/__init__.py" \
  -o "$HOME/.local/share/krita/pykrita/kritamcp/__init__.py"
curl -fL --retry 5 --retry-all-errors \
  "https://raw.githubusercontent.com/nanayax3/krita-mcp/$REF/krita-plugin/kritamcp.desktop" \
  -o "$HOME/.local/share/krita/pykrita/kritamcp.desktop"
printf "[python]\nenable_kritamcp=true\n" > "$HOME/.config/kritarc"

PYVER="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
export DCC_PYTHON_PATH="$RUNNER_TEMP/dcc-python"
export DCC_PROXY_PYTHON="$RUNNER_TEMP/dcc-venv/bin/python"
export PYTHONPATH="$RUNNER_TEMP/dcc-venv/lib/python\${PYVER}/site-packages:/usr/lib/python3/dist-packages:/usr/local/lib/python3/dist-packages\${PYTHONPATH:+:\$PYTHONPATH}"
echo "PYTHON_ENV=$PYVER"
"$RUNNER_TEMP/dcc-venv/bin/python" -c 'import fastmcp, httpx; print("FASTMCP_READY=" + fastmcp.__version__)'

export PORT=10000
export DCC_MCP_INNER_PORT=10002
"$RUNNER_TEMP/blender/blender" --background --python "$GITHUB_WORKSPACE/blender/entrypoint.py" \
  > "$RUNNER_TEMP/blender.log" 2>&1 &
echo $! > "$RUNNER_TEMP/blender.pid"

for _ in $(seq 1 120); do
  grep -q 'MCP_URL=' "$RUNNER_TEMP/blender.log" && break
  kill -0 "$(cat "$RUNNER_TEMP/blender.pid")" 2>/dev/null || { cat "$RUNNER_TEMP/blender.log"; exit 1; }
  sleep 1
done
grep -q 'MCP_URL=' "$RUNNER_TEMP/blender.log"

export DISPLAY=:99
export PORT=10001
export DCC_MCP_INNER_PORT=10003

"$RUNNER_TEMP/dcc-venv/bin/python" "$GITHUB_WORKSPACE/krita/entrypoint.py" \
  > "$RUNNER_TEMP/krita.log" 2>&1 &
echo $! > "$RUNNER_TEMP/krita.pid"

for _ in $(seq 1 180); do
  grep -q 'KRITA_MCP_URL=' "$RUNNER_TEMP/krita.log" && break
  kill -0 "$(cat "$RUNNER_TEMP/krita.pid")" 2>/dev/null || { cat "$RUNNER_TEMP/krita.log"; exit 1; }
  sleep 1
done
grep -q 'KRITA_MCP_URL=' "$RUNNER_TEMP/krita.log"

"$RUNNER_TEMP/dcc-venv/bin/python" - <<'PY'
import asyncio
from fastmcp import Client

async def main():
    async with Client("http://127.0.0.1:10002/mcp") as c:
        tools = await c.list_tools()
        print("BLENDER_TOOLS=" + str(len(tools)))
        assert tools
    async with Client("http://127.0.0.1:10003/mcp") as c:
        tools = await c.list_tools()
        print("KRITA_TOOLS=" + str(len(tools)))
        assert tools

asyncio.run(main())
PY

start_tunnel() {
  local name="$1"
  local port="$2"
  local log="$RUNNER_TEMP/$name-tunnel.log"
  ssh -T -N \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R 80:localhost:$port \
    nokey@localhost.run > "$log" 2>&1 &
  echo $! > "$RUNNER_TEMP/$name-tunnel.pid"
}

start_tunnel blender 10000
start_tunnel krita 10001

for _ in $(seq 1 90); do
  B="$(grep -Eo 'https://[A-Za-z0-9.-]+' "$RUNNER_TEMP/blender-tunnel.log" | head -1 || true)"
  K="$(grep -Eo 'https://[A-Za-z0-9.-]+' "$RUNNER_TEMP/krita-tunnel.log" | head -1 || true)"
  [ -n "$B" ] && [ -n "$K" ] && break
  kill -0 "$(cat "$RUNNER_TEMP/blender-tunnel.pid")" 2>/dev/null || { cat "$RUNNER_TEMP/blender-tunnel.log"; exit 1; }
  kill -0 "$(cat "$RUNNER_TEMP/krita-tunnel.pid")" 2>/dev/null || { cat "$RUNNER_TEMP/krita-tunnel.log"; exit 1; }
  sleep 2
done

test -n "$B"
test -n "$K"

export BLENDER_MCP_URL="$B/mcp"
export KRITA_MCP_URL="$K/mcp"

S1="$(curl -sS -o "$RUNNER_TEMP/blender-unauth.txt" -w '%{http_code}' \
  -X POST "$BLENDER_MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' || true)"
S2="$(curl -sS -o "$RUNNER_TEMP/krita-unauth.txt" -w '%{http_code}' \
  -X POST "$KRITA_MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' || true)"
test "$S1" = "401"
test "$S2" = "401"

python3 - <<'PY'
import datetime as dt
import json
import os
from pathlib import Path

now = dt.datetime.now(dt.timezone.utc)
expires = now + dt.timedelta(hours=5)

for provider in ("blender", "krita"):
    Path("runtime/" + provider + "-endpoint.json").write_text(
        json.dumps({
            "url": os.environ[provider.upper() + "_MCP_URL"],
            "updatedAt": now.isoformat(),
            "expiresAt": expires.isoformat(),
            "provider": provider + "-mcp",
        }, indent=2) + "\n",
        encoding="utf-8",
    )
PY

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add runtime/blender-endpoint.json runtime/krita-endpoint.json
git commit -m "chore: publish live DCC endpoint URLs [skip ci]" || true
git push origin HEAD:main

echo "=== DCC RUNTIME READY ==="
echo "BLENDER_MCP_URL=$BLENDER_MCP_URL"
echo "KRITA_MCP_URL=$KRITA_MCP_URL"

while true; do
  kill -0 "$(cat "$RUNNER_TEMP/blender.pid")" 2>/dev/null || exit 1
  kill -0 "$(cat "$RUNNER_TEMP/krita.pid")" 2>/dev/null || exit 1
  kill -0 "$(cat "$RUNNER_TEMP/blender-tunnel.pid")" 2>/dev/null || exit 1
  kill -0 "$(cat "$RUNNER_TEMP/krita-tunnel.pid")" 2>/dev/null || exit 1
  sleep 30
done