/**
 * Ubuntu first-boot LUKS password box — one password, fully automated setup.
 */
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const panels = {
    secureboot: $("panel-secureboot"),
    password: $("panel-password"),
    progress: $("panel-progress"),
    reboot: $("panel-reboot"),
    done: $("panel-done"),
  };

  let pollTimer = null;
  let unlocked = false;
  let continuing = false;

  function showPanel(name) {
    Object.entries(panels).forEach(([k, el]) => el.classList.toggle("hidden", k !== name));
  }

  function setError(msg) {
    const el = $("error-msg");
    if (!msg) { el.classList.add("hidden"); el.textContent = ""; return; }
    el.textContent = msg;
    el.classList.remove("hidden");
  }

  function lockUI() {
    if (unlocked) return;
    window.addEventListener("beforeunload", (e) => { e.preventDefault(); e.returnValue = ""; });
    document.addEventListener("keydown", (e) => {
      if (unlocked) return;
      if (["Escape", "F11", "F12"].includes(e.key) ||
          (e.altKey && e.key === "F4") || (e.ctrlKey && ["w", "q"].includes(e.key.toLowerCase()))) {
        e.preventDefault(); e.stopPropagation();
      }
    });
    history.pushState(null, "", location.href);
    window.addEventListener("popstate", () => { if (!unlocked) history.pushState(null, "", location.href); });
  }

  async function api(path, opts = {}) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
      ...opts,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || res.statusText);
    return data;
  }

  function updateMachineInfo(hw, status) {
    const free = hw.free_mb ? ` · ${Math.round(hw.free_mb / 1024)} GB free` : "";
    const preview = status && status.needs_root ? " · UI preview (encrypt requires root deploy)" : "";
    $("machine-info").textContent =
      `${hw.hostname || "laptop"} · ${hw.disk || "?"} · ${hw.luks_dev || "?"} · ${hw.username || "?"}${free}${preview}`;
  }

  async function maybeContinue(hw, status) {
    if (continuing || status.running) return;
    if (!["needs_harden", "needs_purge"].includes(hw.phase)) return;
    continuing = true;
    showPanel("progress");
    $("status-text").textContent = "Resuming setup after reboot…";
    try {
      const r = await api("/api/setup/continue", { method: "POST" });
      if (r.status === "reboot_required") {
        showPanel("reboot");
      } else {
        startPoll();
      }
    } catch (e) {
      $("status-text").textContent = e.message;
      $("detail-text").textContent = "If this persists, check /var/log/luks-wizard-orchestrate.log";
    } finally {
      continuing = false;
    }
  }

  async function refresh() {
    const status = await api("/api/setup/status");
    const hw = status.hardware;
    updateMachineInfo(hw, status);

    if (status.complete) {
      unlocked = true;
      showPanel("done");
      stopPoll();
      return;
    }

    if (status.needs_root) {
      showPanel("password");
      setError("");
      $("btn-start").disabled = false;
      return;
    }

    if (hw.phase === "error") {
      showPanel("password");
      setError((hw.blockers || []).join(" ") || "Detection failed");
      return;
    }

    const prog = status.progress || {};
    const progPhase = prog.phase || "idle";

    // Secure Boot required only for fresh install
    if (!hw.secure_boot && ["needs_partition", "needs_encrypt", "needs_encrypt_hooks"].includes(hw.phase)) {
      showPanel("secureboot");
      return;
    }

    if (hw.phase === "needs_reboot" || progPhase === "reboot") {
      showPanel("reboot");
      return;
    }

    if (status.running || ["partition", "encrypt", "verify", "harden", "purge"].includes(progPhase)) {
      showPanel("progress");
      $("progress-bar").style.width = (prog.pct || 0) + "%";
      $("status-text").textContent = prog.message || "Working…";
      $("detail-text").textContent = "";
      if (status.log_tail) {
        const log = $("log-output");
        log.textContent = status.log_tail;
        log.classList.remove("hidden");
      }
      return;
    }

    if (progPhase === "error") {
      showPanel("progress");
      $("status-text").textContent = prog.message || "Setup failed";
      $("detail-text").textContent = "See /var/log/luks-wizard-orchestrate.log";
      if (status.log_tail) {
        $("log-output").textContent = status.log_tail;
        $("log-output").classList.remove("hidden");
      }
      stopPoll();
      return;
    }

    if (["needs_harden", "needs_purge"].includes(hw.phase)) {
      await maybeContinue(hw, status);
      return;
    }

    showPanel("password");
  }

  function startPoll() {
    stopPoll();
    pollTimer = setInterval(() => refresh().catch(console.error), 2000);
  }

  function stopPoll() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }

  $("panel-password").addEventListener("submit", async (e) => {
    e.preventDefault();
    setError("");
    const pw = $("password").value;
    if (pw.length < 1) return setError("Enter your Ubuntu login password");
    const btn = $("btn-start");
    btn.disabled = true;
    btn.textContent = "Starting…";
    try {
      showPanel("progress");
      $("status-text").textContent = "Detecting disk and verifying password…";
      await api("/api/setup/start", { method: "POST", body: JSON.stringify({ password: pw }) });
      $("password").value = "";
      startPoll();
    } catch (err) {
      showPanel("password");
      setError(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = "Encrypt now";
    }
  });

  $("btn-recheck-sb").addEventListener("click", () => {
    setError("");
    refresh().catch((e) => setError(e.message));
  });

  $("btn-reboot").addEventListener("click", async () => {
    $("btn-reboot").disabled = true;
    $("btn-reboot").textContent = "Restarting…";
    try { await api("/api/system/reboot", { method: "POST" }); } catch { /* ok */ }
  });

  $("btn-close").addEventListener("click", async () => {
    unlocked = true;
    await api("/api/dismiss", { method: "POST" }).catch(() => {});
    window.close();
  });

  lockUI();
  refresh().then(() => startPoll()).catch((e) => {
    $("subtitle").textContent = "Setup service unavailable.";
    setError(e.message + " — run: sudo bash scripts/install-setup-wizard.sh");
  });
})();