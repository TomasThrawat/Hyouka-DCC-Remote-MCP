#!/usr/bin/env bash
set -euo pipefail

LOG="$RUNNER_TEMP/dcc-runtime.log"
exec > >(tee -a "$LOG") 2>&1

dump_runtime_logs() {
  echo "=== Blender runtime log ==="
  if [ -f "$RUNNER_TEMP/blender.log" ]; then tail -n 200 "$RUNNER_TEMP/blender.log"; fi
  echo "=== Krita runtime log ==="
  if [ -f "$RUNNER_TEMP/krita.log" ]; then tail -n 200 "$RUNNER_TEMP/krita.log"; fi
  echo "=== Blender tunnel log ==="
  if [ -f "$RUNNER_TEMP/blender-tunnel.log" ]; then tail -n 200 "$RUNNER_TEMP/blender-tunnel.log"; fi
  echo "=== Krita tunnel log ==="
  if [ -f "$RUNNER_TEMP/krita-tunnel.log" ]; then tail -n 200 "$RUNNER_TEMP/krita-tunnel.log"; fi
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then dump_runtime_logs; fi' EXIT

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
  "fastmcp>=2,<4" "httpx>=0.27,<1" "aiohttp>=3.11,<4" "PyJWT[crypto]>=2.9,<3" "dcc-mcp-krita==0.3.0"

mkdir -p "$RUNNER_TEMP/dcc-python"
"$RUNNER_TEMP/dcc-venv/bin/python" -m pip install \
  --target "$RUNNER_TEMP/dcc-python" "dcc-mcp-blender==0.2.9"

mkdir -p "$RUNNER_TEMP/blender"
curl -fL --retry 5 --retry-all-errors \
  "https://download.blender.org/release/Blender5.2/blender-5.2.2-linux-x64.tar.xz" \
  -o "$RUNNER_TEMP/blender.tar.xz"
tar -xJf "$RUNNER_TEMP/blender.tar.xz" -C "$RUNNER_TEMP/blender" --strip-components=1
"$RUNNER_TEMP/blender/blender" --version

echo "== Install official DCC MCP Krita adapter =="
"$RUNNER_TEMP/dcc-venv/bin/python" - <<'PY'
import json
import urllib.request

def inspect(url, label, minimum):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {},
    }).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as response:
        text = response.read().decode("utf-8", "replace")
    tools = None
    for line in text.splitlines():
        if line.startswith("data: "):
            try:
                obj = json.loads(line[6:])
                if obj.get("result", {}).get("tools") is not None:
                    tools = obj["result"]["tools"]
            except json.JSONDecodeError:
                pass
    if tools is None:
        raise RuntimeError(f"{label}: no tools payload returned")
    names = sorted(t.get("name", "") for t in tools)
    print(f"{label}_TOOLS={len(names)}", flush=True)
    print(f"{label}_TOOL_NAMES_SAMPLE=" + str(names[:25]), flush=True)
    assert len(names) >= minimum, f"{label} count {len(names)} < {minimum}"

inspect("http://127.0.0.1:10002/mcp", "BLENDER", 200)
inspect("http://127.0.0.1:10003/mcp", "KRITA", 16)
PY

start_tunnel() {
  local name="$1"
  local port="$2"
  local log="$RUNNER_TEMP/$name-tunnel.log"
  rm -f "$log"
  ssh     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o LogLevel=ERROR     -o ExitOnForwardFailure=yes     -o ServerAliveInterval=20     -o ServerAliveCountMax=3     -R 80:127.0.0.1:$port     nokey@localhost.run >"$log" 2>&1 &
  echo $! >"$RUNNER_TEMP/$name-tunnel.pid"
}

get_tunnel_url() {
  local name="$1"
  local log="$RUNNER_TEMP/$name-tunnel.log"
  grep -Eo 'https://[A-Za-z0-9.-]+\.lhr\.life' "$log" | tail -1 || true
}

probe_public() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 \
    -X POST "$url/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' || true
}

publish_manifests() {
  local blender_url="$1"
  local krita_url="$2"
  export BLENDER_MCP_URL="$blender_url"
  export KRITA_MCP_URL="$krita_url"

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

  BLENDER_FILE_B64="$(base64 -w0 runtime/blender-endpoint.json)"
  BLENDER_SHA="$(gh api "repos/TomasThrawat/Hyouka-DCC-Remote-MCP/contents/runtime/blender-endpoint.json?ref=main" --jq '.sha')"
  gh api --method PUT "repos/TomasThrawat/Hyouka-DCC-Remote-MCP/contents/runtime/blender-endpoint.json" \
    -f message="chore: refresh live Blender MCP endpoint [skip ci]" \
    -f content="$BLENDER_FILE_B64" \
    -f branch="main" \
    -f sha="$BLENDER_SHA"

  KRITA_FILE_B64="$(base64 -w0 runtime/krita-endpoint.json)"
  KRITA_SHA="$(gh api "repos/TomasThrawat/Hyouka-DCC-Remote-MCP/contents/runtime/krita-endpoint.json?ref=main" --jq '.sha')"
  gh api --method PUT "repos/TomasThrawat/Hyouka-DCC-Remote-MCP/contents/runtime/krita-endpoint.json" \
    -f message="chore: refresh live Krita MCP endpoint [skip ci]" \
    -f content="$KRITA_FILE_B64" \
    -f branch="main" \
    -f sha="$KRITA_SHA"
}

start_tunnel blender 10000
start_tunnel krita 10001

wait_for_public_ready() {
  local name="$1"
  local port="$2"
  local pid_file="$RUNNER_TEMP/$name-tunnel.pid"

  local failures=0
  for _ in $(seq 1 60); do
    local url
    local status
    url="$(get_tunnel_url "$name")"
    if [ -n "$url" ]; then
      status="$(probe_public "$url")"
      echo "$(echo "$name" | tr '[:lower:]' '[:upper:]')_PUBLIC_PROBE_STATUS=$status" >&2
      if [ "$status" = "401" ]; then
        printf '%s' "$url"
        return 0
      fi
      failures=$((failures + 1))
    else
      failures=$((failures + 1))
    fi

    if ! kill -0 "$(cat "$pid_file")" 2>/dev/null || [ "$failures" -ge 5 ]; then
      echo "$(echo "$name" | tr '[:lower:]' '[:upper:]')_TUNNEL_RESTART_DURING_BOOT failures=$failures" >&2
      kill "$(cat "$pid_file")" 2>/dev/null || true
      start_tunnel "$name" "$port"
      failures=0
    fi
    sleep 2
  done

  echo "$(echo "$name" | tr '[:lower:]' '[:upper:]')_PUBLIC_PROBE_FAILED" >&2
  return 1
}

B="$(wait_for_public_ready blender 10000)"
K="$(wait_for_public_ready krita 10001)"

test -n "$B"
test -n "$K"

B_STATUS="$(probe_public "$B")"
K_STATUS="$(probe_public "$K")"
echo "BLENDER_PUBLIC_PROBE_STATUS_FINAL=$B_STATUS"
echo "KRITA_PUBLIC_PROBE_STATUS_FINAL=$K_STATUS"

test "$B_STATUS" = "401"
test "$K_STATUS" = "401"

publish_manifests "$B/mcp" "$K/mcp"

echo "=== DCC RUNTIME READY ==="
echo "BLENDER_MCP_URL=$B/mcp"
echo "KRITA_MCP_URL=$K/mcp"

while true; do
  blender_ok=1
  krita_ok=1

  B_STATUS="$(probe_public "$B")"
  K_STATUS="$(probe_public "$K")"

  if [ "$B_STATUS" != "401" ]; then
    blender_ok=0
  fi
  if [ "$K_STATUS" != "401" ]; then
    krita_ok=0
  fi

  if [ "$blender_ok" -eq 0 ] || ! kill -0 "$(cat "$RUNNER_TEMP/blender-tunnel.pid")" 2>/dev/null; then
    echo "BLENDER_TUNNEL_RESTART status=$B_STATUS"
    kill "$(cat "$RUNNER_TEMP/blender-tunnel.pid")" 2>/dev/null || true
    start_tunnel blender 10000
    for _ in $(seq 1 60); do
      B="$(get_tunnel_url blender)"
      [ -n "$B" ] && [ "$(probe_public "$B")" = "401" ] && break
      sleep 2
    done
  fi

  if [ "$krita_ok" -eq 0 ] || ! kill -0 "$(cat "$RUNNER_TEMP/krita-tunnel.pid")" 2>/dev/null; then
    echo "KRITA_TUNNEL_RESTART status=$K_STATUS"
    kill "$(cat "$RUNNER_TEMP/krita-tunnel.pid")" 2>/dev/null || true
    start_tunnel krita 10001
    for _ in $(seq 1 60); do
      K="$(get_tunnel_url krita)"
      [ -n "$K" ] && [ "$(probe_public "$K")" = "401" ] && break
      sleep 2
    done
  fi

  if [ "$(probe_public "$B")" = "401" ] && [ "$(probe_public "$K")" = "401" ]; then
    if [ "$B" != "${LAST_B:-}" ] || [ "$K" != "${LAST_K:-}" ]; then
      publish_manifests "$B/mcp" "$K/mcp"
      LAST_B="$B"
      LAST_K="$K"
      echo "LIVE_ENDPOINTS_REFRESHED"
    fi
  else
    echo "PUBLIC_PROBE_NOT_READY blender=$(probe_public "$B") krita=$(probe_public "$K")"
  fi

  kill -0 "$(cat "$RUNNER_TEMP/blender.pid")" 2>/dev/null || exit 1
  kill -0 "$(cat "$RUNNER_TEMP/krita.pid")" 2>/dev/null || exit 1
  sleep 30
done
