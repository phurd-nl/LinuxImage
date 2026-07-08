"""First-boot setup engine — hardware detection, password verify, orchestration."""
from __future__ import annotations

import json
import os
import secrets
import subprocess
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(os.environ.get("LINUX_ENCRYPTION_REPO", Path(__file__).resolve().parent.parent))
SCRIPTS = REPO_ROOT / "scripts"
CONFIG_PATH = SCRIPTS / "config.sh"
STATE_DIR = Path(os.environ.get("LINUX_ENCRYPTION_STATE", "/var/lib/linux-encryption-setup"))
PROGRESS_FILE = STATE_DIR / "orchestrate.progress"
JOB_FILE = STATE_DIR / "orchestrate.job.json"
ANSIBLE_API_URL = os.environ.get("ANSIBLE_API_URL", "").rstrip("/")

_lock = threading.Lock()
_proc: subprocess.Popen[str] | None = None


def _run(
    cmd: list[str],
    *,
    timeout: int | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=merged,
        cwd=str(REPO_ROOT),
        input=input,
    )


def detect() -> dict[str, Any]:
    proc = _run(["bash", str(SCRIPTS / "detect-hardware.sh")], timeout=30)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "detect-hardware.sh failed").strip()
        raise RuntimeError(err)
    data = json.loads(proc.stdout)
    if data.get("error"):
        raise RuntimeError(data["error"])
    return data


def apply_config(hw: dict[str, Any]) -> None:
    text = CONFIG_PATH.read_text()
    for key, bash_key in [("disk", "DISK"), ("partnum", "PARTNUM"), ("username", "USERNAME"), ("mapper", "MAPPER")]:
        val = str(hw[key])
        import re
        text, n = re.subn(
            rf"^({bash_key}=\$\{{{bash_key}:-)[^}}]+(\}}.*)$",
            rf"\g<1>{val}\2",
            text,
            count=1,
            flags=re.M,
        )
        if n != 1:
            raise RuntimeError(f"Could not update {bash_key} in config.sh")
    CONFIG_PATH.write_text(text)


def verify_login_password(username: str, password: str) -> bool:
    proc = _run(
        ["bash", str(SCRIPTS / "verify-login-password.sh"), username],
        input=password,
        timeout=15,
    )
    if proc.returncode == 2:
        raise RuntimeError("pamtester not installed — apt install pamtester")
    return proc.returncode == 0


def _store_recovery_passphrase(hostname: str, phrase: str) -> Path:
    """Persist recovery passphrase root-only. Without this (or Ansible), the
    offline floor is lost after tmpfs shred and the machine can be locked out."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(STATE_DIR, 0o700)
    except OSError:
        pass
    path = STATE_DIR / "recovery-passphrase"
    # Atomic write: temp in same dir then rename; mode 0400 root:root.
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        f"# LUKS recovery passphrase for {hostname}\n"
        f"# Store offline, then: shred -u {path}\n"
        f"{phrase}\n",
        encoding="utf-8",
    )
    os.chmod(tmp, 0o400)
    tmp.replace(path)
    os.chmod(path, 0o400)
    return path


def fetch_recovery_passphrase(hostname: str) -> str:
    if ANSIBLE_API_URL:
        url = f"{ANSIBLE_API_URL}/api/v1/machines/{hostname}/luks-recovery-passphrase"
        payload = json.dumps({"hostname": hostname}).encode()
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        phrase = data.get("passphrase")
        if not phrase:
            raise RuntimeError("Ansible API returned no passphrase")
        # Still mirror locally so offline recovery works if Ansible is unreachable later.
        _store_recovery_passphrase(hostname, phrase)
        return phrase
    # No Ansible: generate cryptographically strong phrase and keep a root-only copy.
    phrase = secrets.token_urlsafe(48)
    push_url = os.environ.get("ANSIBLE_PUSH_URL", "").rstrip("/")
    if push_url:
        payload = json.dumps({"hostname": hostname, "passphrase": phrase}).encode()
        req = urllib.request.Request(
            f"{push_url}/api/v1/machines/{hostname}/luks-recovery-passphrase",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="PUT",
        )
        try:
            with urllib.request.urlopen(req, timeout=30):
                pass
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Failed to register recovery passphrase with Ansible: {exc.reason}") from exc
    path = _store_recovery_passphrase(hostname, phrase)
    # Never log the phrase; path only (for admin collection / fleet imaging).
    print(f"recovery passphrase stored root-only at {path}", flush=True)
    return phrase


def read_progress() -> dict[str, Any]:
    if PROGRESS_FILE.exists():
        try:
            return json.loads(PROGRESS_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"phase": "idle", "message": "Waiting to start", "pct": 0}


def is_running() -> bool:
    global _proc
    with _lock:
        if _proc is not None and _proc.poll() is None:
            return True
    if JOB_FILE.exists():
        try:
            job = json.loads(JOB_FILE.read_text())
            pid = job.get("pid")
            if pid and Path(f"/proc/{pid}").exists():
                return True
        except (json.JSONDecodeError, OSError):
            pass
    return False


def _mark_complete() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not (STATE_DIR / "completed_at").exists():
        from datetime import datetime, timezone
        (STATE_DIR / "completed_at").write_text(datetime.now(timezone.utc).isoformat() + "\n")


def is_complete() -> bool:
    if (STATE_DIR / "completed_at").exists() or (STATE_DIR / "purge_done").exists():
        return True
    p = read_progress()
    if p.get("phase") == "done":
        _mark_complete()
        return True
    try:
        if detect().get("phase") == "complete":
            _mark_complete()
            return True
    except Exception:
        pass
    return False


def _write_pw_files(login: str, recovery: str) -> tuple[Path, Path]:
    tmp = Path("/dev/shm") / f"wizard-pw-{secrets.token_hex(8)}"
    tmp.mkdir(mode=0o700)
    login_f = tmp / "login"
    recovery_f = tmp / "recovery"
    login_f.write_bytes(login.encode())
    recovery_f.write_bytes(recovery.encode())
    login_f.chmod(0o600)
    recovery_f.chmod(0o600)
    return login_f, recovery_f


def _launch_orchestrator(*, login: str | None = None, recovery: str | None = None) -> None:
    global _proc
    env = os.environ.copy()
    env["LINUX_ENCRYPTION_REPO"] = str(REPO_ROOT)
    env["LINUX_ENCRYPTION_STATE"] = str(STATE_DIR)
    if login is not None and recovery is not None:
        login_f, recovery_f = _write_pw_files(login, recovery)
        env["WIZARD_LOGIN_PW_FILE"] = str(login_f)
        env["WIZARD_RECOVERY_PW_FILE"] = str(recovery_f)

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with _lock:
        _proc = subprocess.Popen(
            ["bash", str(SCRIPTS / "orchestrate-firstboot.sh")],
            env=env,
            cwd=str(REPO_ROOT),
            start_new_session=True,
        )
        JOB_FILE.write_text(json.dumps({"pid": _proc.pid, "started": True}) + "\n")

    def _wait() -> None:
        global _proc
        assert _proc is not None
        _proc.wait()
        with _lock:
            _proc = None

    threading.Thread(target=_wait, daemon=True).start()


def start_setup(password: str) -> dict[str, Any]:
    if is_running():
        raise RuntimeError("Setup already running")
    if is_complete():
        return {"status": "complete", "message": "Setup already finished"}

    hw = detect()
    if not hw.get("tpm"):
        raise RuntimeError("This machine has no TPM 2.0 — encryption setup cannot proceed")
    if not hw.get("ready"):
        raise RuntimeError("; ".join(hw.get("blockers") or ["Machine not ready for setup"]))
    if not verify_login_password(hw["username"], password):
        raise RuntimeError("Password incorrect — enter your Ubuntu login password")

    apply_config(hw)
    recovery = fetch_recovery_passphrase(hw.get("hostname", "unknown"))
    _launch_orchestrator(login=password, recovery=recovery)
    return {"status": "started", "phase": hw.get("phase"), "disk": hw.get("disk"), "luks_dev": hw.get("luks_dev")}


def continue_setup() -> dict[str, Any]:
    if is_running():
        raise RuntimeError("Setup already running")
    if is_complete():
        return {"status": "complete"}

    hw = detect()
    apply_config(hw)
    phase = hw.get("phase", "")
    if phase == "complete":
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        if not (STATE_DIR / "completed_at").exists():
            (STATE_DIR / "completed_at").write_text(hw.get("hostname", "done") + "\n")
        return {"status": "complete"}
    if phase == "needs_reboot":
        return {"status": "reboot_required", "message": "Restart the laptop to continue"}
    if phase in ("needs_partition", "needs_encrypt", "needs_encrypt_hooks"):
        raise RuntimeError("Enter your login password to continue")
    if not hw.get("ready"):
        raise RuntimeError("; ".join(hw.get("blockers") or ["Not ready to continue"]))

    _launch_orchestrator()
    return {"status": "continued", "phase": phase}


def get_status() -> dict[str, Any]:
    """Full status payload; never raises — safe for the UI poll loop."""
    try:
        hw = detect()
    except Exception as exc:
        hw = {
            "phase": "error",
            "ready": False,
            "blockers": [str(exc)],
            "hostname": _run(["hostname"]).stdout.strip(),
        }
    recovery_path = STATE_DIR / "recovery-passphrase"
    return {
        "complete": is_complete(),
        "running": is_running(),
        "progress": read_progress(),
        "hardware": hw,
        "log_tail": tail_log(30),
        "needs_root": os.geteuid() != 0,
        # Path only — never the secret. Admin must collect offline then shred.
        "recovery_stored": recovery_path.is_file(),
        "recovery_path": str(recovery_path) if recovery_path.is_file() else None,
    }


def tail_log(lines: int = 40) -> str:
    log = Path("/var/log/luks-wizard-orchestrate.log")
    if not log.exists():
        return ""
    content = log.read_text(errors="replace").splitlines()
    return "\n".join(content[-lines:])