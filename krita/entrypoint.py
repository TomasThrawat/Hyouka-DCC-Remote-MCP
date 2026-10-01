#!/usr/bin/env python3

from __future__ import annotations

import asyncio
import os
import subprocess
import time


def main() -> None:
    public_port = int(os.environ.get("PORT", "10001"))
    inner_port = int(os.environ.get("DCC_MCP_INNER_PORT", "10003"))

    os.environ.setdefault("DCC_MCP_KRITA_BRIDGE_PORT", "3848")
    os.environ.setdefault("DCC_MCP_KRITA_ALLOWED_ROOTS", os.getcwd())

    display = os.environ.get("DISPLAY", ":99")
    os.environ["DISPLAY"] = display

    xvfb = subprocess.Popen([
        "Xvfb", display, "-screen", "0", "1920x1080x24",
        "-ac", "+extension", "GLX", "+render", "-noreset"
    ])
    time.sleep(2)
    if xvfb.poll() is not None:
        raise RuntimeError(f"Xvfb exited with code {xvfb.returncode}")

    krita = subprocess.Popen(["krita", "--nosplash"])

    try:
        from dcc_mcp_krita.server import start_server, stop_server

        server = start_server(port=inner_port)

        async def wait_for_mcp():
            from fastmcp import Client
            last_error = None
            for _ in range(60):
                try:
                    async with Client(f"http://127.0.0.1:{inner_port}/mcp") as client:
                        tools = await asyncio.wait_for(client.list_tools(), timeout=10)
                    if len(tools) >= 16:
                        return len(tools)
                    last_error = RuntimeError(
                        f"Krita MCP exposed only {len(tools)} tools"
                    )
                except Exception as exc:
                    last_error = exc
                await asyncio.sleep(1)
            raise RuntimeError(f"Krita MCP readiness failed: {last_error}")

        tool_count = asyncio.run(wait_for_mcp())
        print(f"KRITA_MCP_URL=http://127.0.0.1:{public_port}/mcp", flush=True)
        print(f"KRITA_TOTAL_SKILLS={len(server.list_skills())}", flush=True)
        print(
            f"KRITA_LOADED_SKILLS={len(server.list_skills(status='loaded'))}",
            flush=True,
        )
        print(f"KRITA_TOOLS={tool_count}", flush=True)

        while krita.poll() is None:
            time.sleep(2)
        raise RuntimeError(f"Krita exited with code {krita.returncode}")
    finally:
        try:
            from dcc_mcp_krita.server import stop_server
            stop_server()
        except Exception:
            pass
        try:
            krita.terminate()
            krita.wait(timeout=5)
        except Exception:
            try:
                krita.kill()
            except Exception:
                pass
        try:
            xvfb.terminate()
            xvfb.wait(timeout=5)
        except Exception:
            try:
                xvfb.kill()
            except Exception:
                pass


if __name__ == "__main__":
    main()
