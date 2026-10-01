#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl python3 python3-pip xz-utils \
  libx11-6 libxrender1 libxi6 libxfixes3 libxxf86vm1 libxkbcommon0 \
  libgl1 libglu1-mesa libsm6 libice6 libdbus-1-3 \
  xvfb dbus-x11 krita python3-pyqt5 x11-xkb-utils xkeyboard-config \
  libxcb-xinerama0 libxcb-cursor0 libxcb-keysyms1 libxcb-render-util0 \
  libxcb-shape0 libxcb-randr0 libxcb-image0 libxcb-util1 \
  libxkbcommon-x11-0 libegl1 fonts-dejavu

sudo rm -rf /var/lib/apt/lists/*

python3 - <<'PY'
import PyQt5
print("PYQT5_READY=" + getattr(PyQt5, "__file__", "<unknown>"))
PY

mkdir -p "$HOME/.local/share/krita/pykrita/kritamcp" "$HOME/.config" "$HOME/dcc-python"

python3 -m pip install --break-system-packages --user --upgrade \
  "fastmcp>=2,<4" "httpx>=0.27,<1" \
  "aiohttp>=3.11,<4" "PyJWT[crypto]>=2.9,<3"

if [ ! -x "$HOME/blender/blender" ]; then
  mkdir -p "$HOME/blender"
  curl -fL --retry 5 --retry-all-errors \
    "https://download.blender.org/release/Blender5.2/blender-5.2.2-linux-x64.tar.xz" \
    -o /tmp/blender.tar.xz
  tar -xJf /tmp/blender.tar.xz -C "$HOME/blender" --strip-components=1
  rm -f /tmp/blender.tar.xz
fi

python3 -m pip install --break-system-packages --user --upgrade \
  --target "$HOME/dcc-python" "dcc-mcp-blender==0.2.9"

REF="5019f58852176aeeb11805126360ff749cd70dce"
curl -fL --retry 5 --retry-all-errors \
  "https://raw.githubusercontent.com/nanayax3/krita-mcp/$REF/krita-plugin/kritamcp/__init__.py" \
  -o "$HOME/.local/share/krita/pykrita/kritamcp/__init__.py"
curl -fL --retry 5 --retry-all-errors \
  "https://raw.githubusercontent.com/nanayax3/krita-mcp/$REF/krita-plugin/kritamcp.desktop" \
  -o "$HOME/.local/share/krita/pykrita/kritamcp.desktop"

cat > "$HOME/.config/kritarc" <<'EOF'
[python]
enable_kritamcp=true
EOF

echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

echo "DCC runtime dependencies prepared."
