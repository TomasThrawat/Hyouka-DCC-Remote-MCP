#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
import sys
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

    krita_env = os.environ.copy()
    pyqt_paths = [
        "/usr/lib/python3/dist-packages",
        "/usr/lib/x86_64-linux-gnu/python3/dist-packages",
    ]
    existing = [path for path in pyqt_paths if os.path.isdir(path)]
    old_pythonpath = krita_env.get("PYTHONPATH")
    if old_pythonpath:
        existing.append(old_pythonpath)
    if existing:
        krita_env["PYTHONPATH"] = os.pathsep.join(existing)

    krita = subprocess.Popen(
        ["krita", "--nosplash"],
        env=krita_env,
    )

    proxy_env = os.environ.copy()
    proxy_env["PORT"] = str(public_port)
    proxy_env["UPSTREAM_URL"] = f"http://127.0.0.1:{inner_port}"
    proxy_python = os.environ.get("DCC_PROXY_PYTHON", sys.executable)
    proxy = subprocess.Popen(
        [proxy_python, os.path.join(os.path.dirname(__file__), "..", "auth_proxy.py")],
        env=proxy_env,
    )

    try:
        from dcc_mcp_krita.server import start_server, stop_server

        server = start_server(port=inner_port)
        print(f"KRITA_MCP_URL=http://127.0.0.1:{public_port}/mcp", flush=True)
        print(f"KRITA_TOTAL_SKILLS={len(server.list_skills())}", flush=True)
        print("KRITA_LOADED_SKILLS=NOT_EXPOSED_BY_ADAPTER", flush=True)

        while krita.poll() is None:
            time.sleep(2)
        raise RuntimeError(f"Krita exited with code {krita.returncode}")
    finally:
        try:
            stop_server()
        except Exception:
            pass
        for process in (proxy, krita, xvfb):
            try:
                process.terminate()
                process.wait(timeout=5)
            except Exception:
                try:
                    process.kill()
                except Exception:
                    pass


if __name__ == "__main__":
    main()
