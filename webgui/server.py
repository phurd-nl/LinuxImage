#!/usr/bin/env python3
"""Ubuntu first-boot LUKS setup wizard — password box + automated pipeline."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# Allow importing setup_engine from same directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
import setup_engine as engine  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"
HOST = os.environ.get("WIZARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("WIZARD_PORT", "8765"))

# Body / brute-force limits (loopback still deserves basic abuse protection)
MAX_BODY = 8192
START_FAIL_WINDOW_S = 300
START_FAIL_MAX = 5

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
}

_rate_lock = threading.Lock()
_start_failures: list[float] = []


def _json(handler: BaseHTTPRequestHandler, data: Any, status: int = 200) -> None:
    body = json.dumps(data, indent=2).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    # Browser clients only need same-origin; refuse being framed by other pages.
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("X-Frame-Options", "DENY")
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def _err(handler: BaseHTTPRequestHandler, status: int, msg: str) -> None:
    _json(handler, {"detail": msg}, status)


def _client_is_loopback(handler: BaseHTTPRequestHandler) -> bool:
    client = handler.client_address[0] if handler.client_address else ""
    return client in ("127.0.0.1", "::1", "localhost", "::ffff:127.0.0.1")


def _origin_ok(handler: BaseHTTPRequestHandler) -> bool:
    """Block cross-site POSTs from a browser on the same machine.

    Missing Origin/Referer is allowed (curl/admin tooling on loopback).
    When either header is present it must target this wizard.
    """
    allowed = (
        f"http://127.0.0.1:{PORT}",
        f"http://localhost:{PORT}",
        f"http://[::1]:{PORT}",
    )
    origin = (handler.headers.get("Origin") or "").strip()
    referer = (handler.headers.get("Referer") or "").strip()
    if origin:
        return any(origin == a or origin.startswith(a + "/") for a in allowed)
    if referer:
        return any(referer == a or referer.startswith(a + "/") for a in allowed)
    return True


def _start_rate_ok() -> bool:
    now = time.time()
    with _rate_lock:
        global _start_failures
        _start_failures = [t for t in _start_failures if now - t < START_FAIL_WINDOW_S]
        return len(_start_failures) < START_FAIL_MAX


def _start_rate_fail() -> None:
    with _rate_lock:
        _start_failures.append(time.time())


class Handler(BaseHTTPRequestHandler):
    server_version = "LinuxEncryptionWizard/2.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def _body(self) -> dict[str, Any]:
        raw_len = self.headers.get("Content-Length", "0")
        try:
            n = int(raw_len)
        except ValueError as exc:
            raise ValueError("Invalid Content-Length") from exc
        if n < 0 or n > MAX_BODY:
            raise ValueError(f"Request body too large (max {MAX_BODY} bytes)")
        if n == 0:
            return {}
        raw = self.rfile.read(n)
        if not raw:
            return {}
        return json.loads(raw.decode())

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        try:
            if not _client_is_loopback(self):
                return _err(self, 403, "Local requests only")
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
            if not _client_is_loopback(self):
                return _err(self, 403, "Local requests only")
            if not _origin_ok(self):
                return _err(self, 403, "Cross-origin request denied")

            body = self._body()
            if path == "/api/system/reboot":
                # Allow reboot only while setup is mid-flight or complete.
                st = engine.get_status()
                phase = (st.get("progress") or {}).get("phase") or ""
                hw_phase = (st.get("hardware") or {}).get("phase") or ""
                if not (
                    st.get("running")
                    or st.get("complete")
                    or phase in ("reboot", "partition", "encrypt", "verify", "harden", "purge")
                    or hw_phase in ("needs_reboot", "needs_harden", "needs_purge", "complete")
                ):
                    return _err(self, 403, "Reboot not allowed until setup has started")
                subprocess.run(["systemctl", "reboot"], check=False)
                return _json(self, {"status": "rebooting"})
            if path == "/api/setup/start":
                if not _start_rate_ok():
                    return _err(
                        self,
                        429,
                        f"Too many failed attempts — wait up to {START_FAIL_WINDOW_S // 60} minutes",
                    )
                pw = body.get("password", "")
                if not pw or not isinstance(pw, str):
                    return _err(self, 400, "Password required")
                if len(pw) > 2048:
                    return _err(self, 400, "Password too long")
                try:
                    result = engine.start_setup(pw)
                except RuntimeError as exc:
                    msg = str(exc)
                    if "Password incorrect" in msg or "password" in msg.lower():
                        _start_rate_fail()
                    raise
                return _json(self, result)
            if path == "/api/setup/continue":
                return _json(self, engine.continue_setup())
            if path == "/api/dismiss":
                if not engine.is_complete():
                    return _err(self, 403, "Cannot dismiss until encryption setup is complete")
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
        except ValueError as exc:
            _err(self, 400, str(exc))
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
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    if os.geteuid() != 0:
        print("WARNING: wizard should run as root for disk operations", file=sys.stderr)
    # Refuse non-loopback binds unless explicitly overridden (fleet debug only).
    if HOST not in ("127.0.0.1", "::1", "localhost") and os.environ.get("WIZARD_ALLOW_NONLOCAL") != "1":
        print(
            f"ABORT: WIZARD_HOST={HOST!r} is not loopback. "
            "Set WIZARD_ALLOW_NONLOCAL=1 only if you accept remote exposure.",
            file=sys.stderr,
        )
        sys.exit(1)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Ubuntu encryption wizard on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
