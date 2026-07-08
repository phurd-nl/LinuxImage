#!/usr/bin/env python3
"""Ubuntu first-boot LUKS setup wizard — password box + automated pipeline."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path  # noqa: F401 — used in do_POST
from typing import Any
from urllib.parse import urlparse

# Allow importing setup_engine from same directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
import setup_engine as engine  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"
HOST = os.environ.get("WIZARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("WIZARD_PORT", "8765"))

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
}


def _json(handler: BaseHTTPRequestHandler, data: Any, status: int = 200) -> None:
    body = json.dumps(data, indent=2).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _err(handler: BaseHTTPRequestHandler, status: int, msg: str) -> None:
    _json(handler, {"detail": msg}, status)


class Handler(BaseHTTPRequestHandler):
    server_version = "LinuxEncryptionWizard/2.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def _body(self) -> dict[str, Any]:
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n).decode()) if n else {}

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        try:
            if path == "/api/health":
                return _json(self, {"status": "ok"})
            if path == "/api/detect":
                return _json(self, engine.detect())
            if path == "/api/setup/status":
                return _json(self, engine.get_status())
            if path == "/":
                return self._file(STATIC_DIR / "index.html")
            if path.startswith("/static/"):
                rel = path[len("/static/"):]
                target = (STATIC_DIR / rel).resolve()
                if not str(target).startswith(str(STATIC_DIR.resolve())):
                    return _err(self, 403, "Forbidden")
                return self._file(target)
            _err(self, 404, "Not found")
        except Exception as exc:
            _err(self, 500, str(exc))

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = self._body()
            if path == "/api/system/reboot":
                subprocess.run(["systemctl", "reboot"], check=False)
                return _json(self, {"status": "rebooting"})
            if path == "/api/setup/start":
                pw = body.get("password", "")
                if not pw:
                    return _err(self, 400, "Password required")
                return _json(self, engine.start_setup(pw))
            if path == "/api/setup/continue":
                return _json(self, engine.continue_setup())
            if path == "/api/dismiss":
                try:
                    user = engine.detect().get("username", "")
                    if user and Path("/usr/local/bin/linux-encryption-wizard-dismiss").is_file():
                        subprocess.run(
                            ["runuser", "-u", user, "--", "/usr/local/bin/linux-encryption-wizard-dismiss"],
                            check=False, capture_output=True,
                        )
                except Exception:
                    pass
                return _json(self, {"status": "ok"})
            _err(self, 404, "Not found")
        except RuntimeError as exc:
            _err(self, 400, str(exc))
        except Exception as exc:
            _err(self, 500, str(exc))

    def _file(self, path: Path) -> None:
        if not path.is_file():
            return _err(self, 404, "Not found")
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", MIME.get(path.suffix.lower(), "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    if os.geteuid() != 0:
        print("WARNING: wizard should run as root for disk operations", file=sys.stderr)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Ubuntu encryption wizard on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()