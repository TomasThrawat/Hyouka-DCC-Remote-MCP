#!/usr/bin/env python3

from __future__ import annotations

import os
import socket
import subprocess
import threading
import time


def wait_for_krita(url: str, timeout_seconds: int = 90) -> None:
    import urllib.request

    deadline = time.time() + timeout_seconds
    last_error = "not started"

    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url + "/health", timeout=3) as response:
                if 200 <= response.status < 500:
                    return
        except Exception as exc:
            last_error = str(exc)
        time.sleep(2)

    raise RuntimeError(f"Krita plugin did not become ready: {last_error}")


def wait_for_port(port: int, timeout_seconds: int = 60) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2):
                return
        except OSError:
            time.sleep(1)
    raise RuntimeError(f"Krita MCP HTTP server did not bind port {port}")


def main() -> None:
    public_port = int(os.environ.get("PORT", "10000"))
    inner_port = int(os.environ.get("DCC_MCP_INNER_PORT", "10001"))
    krita_url = "http://127.0.0.1:5678"
    proxy = None

    xvfb = subprocess.Popen([
        "Xvfb", ":99", "-screen", "0", "1920x1080x24", "-kb",
        "-ac", "+extension", "GLX", "+render", "-noreset"
    ])

    krita = subprocess.Popen(["krita", "--nosplash"])

    try:
        wait_for_krita(krita_url, timeout_seconds=90)

        from fastmcp import FastMCP
        import httpx

        mcp = FastMCP("krita-mcp-remote")

        def send_command(action: str, params: dict | None = None, timeout: float = 30.0) -> dict:
            try:
                response = httpx.post(
                    krita_url,
                    json={"action": action, "params": params or {}},
                    timeout=timeout,
                )
                return response.json()
            except Exception as exc:
                return {"error": str(exc)}

        @mcp.tool()
        def krita_health() -> str:
            try:
                response = httpx.get(krita_url + "/health", timeout=5)
                return str(response.json())
            except Exception as exc:
                return f"error: {exc}"

        @mcp.tool()
        def krita_new_canvas(width: int = 800, height: int = 600, name: str = "New Canvas", background: str = "#1a1a2e") -> str:
            return str(send_command("new_canvas", {
                "width": width,
                "height": height,
                "name": name,
                "background": background,
            }))

        @mcp.tool()
        def krita_set_color(color: str) -> str:
            return str(send_command("set_color", {"color": color}))

        @mcp.tool()
        def krita_set_brush(preset: str | None = None, size: int | None = None, opacity: float | None = None) -> str:
            params: dict = {}
            if preset:
                params["preset"] = preset
            if size is not None:
                params["size"] = size
            if opacity is not None:
                params["opacity"] = opacity
            return str(send_command("set_brush", params))

        @mcp.tool()
        def krita_stroke(points: list[list[int]], pressure: float = 1.0) -> str:
            if len(points) < 2:
                return "error: need at least 2 points"
            return str(send_command("stroke", {"points": points, "pressure": pressure}))

        @mcp.tool()
        def krita_fill(x: int, y: int, radius: int = 50) -> str:
            return str(send_command("fill", {"x": x, "y": y, "radius": radius}))

        @mcp.tool()
        def krita_draw_shape(shape: str, x: int, y: int, width: int = 100, height: int = 100, fill: bool = True, stroke: bool = False, x2: int | None = None, y2: int | None = None) -> str:
            params = {"shape": shape, "x": x, "y": y, "width": width, "height": height, "fill": fill, "stroke": stroke}
            if x2 is not None:
                params["x2"] = x2
            if y2 is not None:
                params["y2"] = y2
            return str(send_command("draw_shape", params))

        @mcp.tool()
        def krita_get_canvas(filename: str = "canvas.png") -> str:
            return str(send_command("get_canvas", {"filename": filename}, timeout=120))

        @mcp.tool()
        def krita_undo() -> str:
            return str(send_command("undo"))

        @mcp.tool()
        def krita_redo() -> str:
            return str(send_command("redo"))

        @mcp.tool()
        def krita_clear(color: str = "#1a1a2e") -> str:
            return str(send_command("clear", {"color": color}))

        @mcp.tool()
        def krita_save(path: str) -> str:
            return str(send_command("save", {"path": path}, timeout=120))

        @mcp.tool()
        def krita_get_color_at(x: int, y: int) -> str:
            return str(send_command("get_color_at", {"x": x, "y": y}))

        @mcp.tool()
        def krita_list_brushes(filter: str = "", limit: int = 20) -> str:
            return str(send_command("list_brushes", {"filter": filter, "limit": limit}))

        @mcp.tool()
        def krita_open_file(path: str) -> str:
            return str(send_command("open_file", {"path": path}, timeout=30))

        errors: list[BaseException] = []

        def run_server() -> None:
            try:
                mcp.run(transport="http", host="127.0.0.1", port=inner_port)
            except BaseException as exc:
                errors.append(exc)

        thread = threading.Thread(target=run_server, daemon=True)
        thread.start()
        wait_for_port(inner_port, timeout_seconds=60)

        proxy_env = os.environ.copy()
        proxy_env["PORT"] = str(public_port)
        proxy_env["UPSTREAM_URL"] = f"http://127.0.0.1:{inner_port}"
        proxy_python = os.environ.get("DCC_PROXY_PYTHON", "python3")

        proxy = subprocess.Popen(
            [proxy_python, os.path.join(os.path.dirname(__file__), "..", "auth_proxy.py")],
            env=proxy_env,
        )

        print(f"KRITA_MCP_URL=http://127.0.0.1:{public_port}/mcp", flush=True)

        while thread.is_alive():
            if errors:
                raise RuntimeError(str(errors[0]))
            if krita.poll() is not None:
                raise RuntimeError(f"Krita exited with code {krita.returncode}")
            time.sleep(2)
    finally:
        if proxy is not None:
            proxy.terminate()
            try:
                proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy.kill()
        try:
            krita.terminate()
        except Exception:
            pass
        try:
            xvfb.terminate()
        except Exception:
            pass


if __name__ == "__main__":
    main()
