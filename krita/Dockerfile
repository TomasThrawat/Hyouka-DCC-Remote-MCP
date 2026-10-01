FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DISPLAY=:99 \
    QT_X11_NO_MITSHM=1 \
    XDG_CONFIG_HOME=/root/.config

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl python3 python3-pip xvfb dbus-x11 \
    krita \
    libxcb-xinerama0 libxcb-cursor0 libxcb-keysyms1 libxcb-render-util0 \
    libxcb-shape0 libxcb-randr0 libxcb-image0 libxcb-util1 \
    libxkbcommon-x11-0 libgl1 libglu1-mesa libegl1 \
    fonts-dejavu && \
    rm -rf /var/lib/apt/lists/*

ARG KRITA_MCP_REF=5019f58852176aeeb11805126360ff749cd70dce

RUN python3 -m pip install --break-system-packages --no-cache-dir \
    "fastmcp>=2,<4" "httpx>=0.27,<1" \
    "aiohttp>=3.11,<4" "PyJWT[crypto]>=2.9,<3"

RUN mkdir -p /root/.local/share/krita/pykrita/kritamcp /root/.config && \
    curl -fL --retry 5 --retry-all-errors \
      "https://raw.githubusercontent.com/nanayax3/krita-mcp/${KRITA_MCP_REF}/krita-plugin/kritamcp/__init__.py" \
      -o /root/.local/share/krita/pykrita/kritamcp/__init__.py && \
    curl -fL --retry 5 --retry-all-errors \
      "https://raw.githubusercontent.com/nanayax3/krita-mcp/${KRITA_MCP_REF}/krita-plugin/kritamcp.desktop" \
      -o /root/.local/share/krita/pykrita/kritamcp.desktop && \
    printf "[python]\nenable_kritamcp=true\n" > /root/.config/kritarc

COPY auth_proxy.py /app/auth_proxy.py
COPY krita/entrypoint.py /app/entrypoint.py

RUN chmod +x /app/entrypoint.py

EXPOSE 10000

ENTRYPOINT ["/app/entrypoint.py"]
