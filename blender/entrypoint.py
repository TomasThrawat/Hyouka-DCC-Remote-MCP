from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, "/opt/dcc-python")

from dcc_mcp_core.host import BlockingDispatcher
from dcc_mcp_blender.host import BlenderHost
from dcc_mcp_blender.server import BlenderMcpServer


def main() -> None:
    public_port = int(os.environ.get("PORT", "10000"))
    inner_port = int(os.environ.get("DCC_MCP_INNER_PORT", "10001"))

    dispatcher = BlockingDispatcher()
    server = BlenderMcpServer(port=inner_port, dispatcher=dispatcher)

    # Keep Blender MCP private inside the runner; the OIDC proxy is the only public hop.
    server._config.host = "127.0.0.1"

    server.register_builtin_actions(include_bundled=True)
    server.start()
    server.discover_skills()

    proxy_env = os.environ.copy()
    proxy_env["PORT"] = str(public_port)
    proxy_env["UPSTREAM_URL"] = f"http://127.0.0.1:{inner_port}"
    proxy = subprocess.Popen(
        [sys.executable, "/app/auth_proxy.py"],
        env=proxy_env,
    )

    print(f"MCP_URL=http://127.0.0.1:{public_port}/mcp", flush=True)

    try:
        BlenderHost(dispatcher).run_headless()
    finally:
        proxy.terminate()
        try:
            proxy.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proxy.kill()
        server.stop()


if __name__ == "__main__":
    main()
