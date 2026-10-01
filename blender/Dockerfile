FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DCC_MCP_GATEWAY_PORT=0 \
    DCC_MCP_INSTANCE_TYPE=standalone

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl python3 python3-pip xz-utils \
    libx11-6 libxrender1 libxi6 libxfixes3 libxxf86vm1 libxkbcommon0 \
    libgl1 libglu1-mesa libsm6 libice6 libdbus-1-3 && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fL --retry 5 --retry-all-errors \
    "https://download.blender.org/release/Blender5.2/blender-5.2.2-linux-x64.tar.xz" \
    -o /tmp/blender.tar.xz && \
    mkdir -p /opt/blender && \
    tar -xJf /tmp/blender.tar.xz -C /opt/blender && \
    rm /tmp/blender.tar.xz

RUN mkdir -p /opt/dcc-python && \
    python3 -m pip install --break-system-packages --no-cache-dir \
      --target /opt/dcc-python "dcc-mcp-blender==0.2.9"

COPY blender/entrypoint.py /app/entrypoint.py

EXPOSE 10000

ENTRYPOINT ["/opt/blender/blender-5.2.2-linux-x64/blender", "--background", "--python", "/app/entrypoint.py"]
