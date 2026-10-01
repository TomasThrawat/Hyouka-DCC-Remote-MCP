from __future__ import annotations

import os
import subprocess
import sys

for candidate in [
    os.environ.get("DCC_PYTHON_PATH"),
    "/opt/dcc-python",
    "/home/user/dcc-python",
]:
    if candidate and candidate not in sys.path:
        sys.path.insert(0, candidate)

from dcc_mcp_core.host import BlockingDispatcher
from dcc_mcp_blender.host import BlenderHost
from dcc_mcp_blender.server import BlenderMcpServer


def main() -> None:
    public_port = int(os.environ.get("PORT", "10000"))
    inner_port = int(os.environ.get("DCC_MCP_INNER_PORT", "10002"))

    dispatcher = BlockingDispatcher()
    server = BlenderMcpServer(port=inner_port, dispatcher=dispatcher)

    server._config.host = "127.0.0.1"
    server.register_builtin_actions(include_bundled=True)
    server.start()
    discovered = server.list_skills()
    for skill in discovered:
        name = skill.get("name")
        if name and not server.is_skill_loaded(name):
            if not server.load_skill(name):
                raise RuntimeError(f"Failed to load Blender skill: {name}")
    print(f"BLENDER_SKILLS={len(discovered)}", flush=True)
    print(f"BLENDER_LOADED_SKILLS={server.loaded_skill_count()}", flush=True)
    if server.loaded_skill_count() < len([s for s in discovered if s.get("name")]):
        raise RuntimeError("Not all discovered Blender skills were loaded")

    proxy_env = os.environ.copy()
    proxy_env["PORT"] = str(public_port)
    proxy_env["UPSTREAM_URL"] = f"http://127.0.0.1:{inner_port}"
    proxy_path = os.environ.get("DCC_PYTHON_PATH", "/opt/dcc-python")
    proxy_env["PYTHONPATH"] = proxy_path + os.pathsep + proxy_env.get("PYTHONPATH", "")

    proxy_python = os.environ.get("DCC_PROXY_PYTHON", "python3")
    proxy = subprocess.Popen(
        [proxy_python, os.path.join(os.path.dirname(__file__), "..", "auth_proxy.py")],
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
