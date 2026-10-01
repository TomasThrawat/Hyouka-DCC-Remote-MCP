from __future__ import annotations

import os
import sys

sys.path.insert(0, "/opt/dcc-python")

from dcc_mcp_core.host import BlockingDispatcher
from dcc_mcp_blender.host import BlenderHost
from dcc_mcp_blender.server import BlenderMcpServer


def main() -> None:
    port = int(os.environ.get("PORT", "10000"))
    dispatcher = BlockingDispatcher()
    server = BlenderMcpServer(port=port, dispatcher=dispatcher)

    # Verified dcc-mcp-core HTTP config defaults to loopback.
    server._config.host = "0.0.0.0"

    server.register_builtin_actions(include_bundled=True)
    server.start()
    server.discover_skills()

    print(f"MCP_URL=http://0.0.0.0:{server.port}/mcp", flush=True)

    try:
        BlenderHost(dispatcher).run_headless()
    finally:
        server.stop()


if __name__ == "__main__":
    main()
