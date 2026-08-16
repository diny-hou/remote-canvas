const elements = {
  homeView: document.querySelector("#home-view"),
  serviceState: document.querySelector("#service-state"),
  hostName: document.querySelector("#host-name"),
  hostMeta: document.querySelector("#host-meta"),
  endpoint: document.querySelector("#endpoint"),
  pairButton: document.querySelector("#pair-button"),
  copyButton: document.querySelector("#copy-button"),
  copyLabel: document.querySelector("#copy-label"),
  appVersion: document.querySelector("#app-version"),
  updateButton: document.querySelector("#update-button"),
  updateLabel: document.querySelector("#update-label"),
  updateSub: document.querySelector("#update-sub"),
  rotateButton: document.querySelector("#rotate-button"),
  pairingCard: document.querySelector("#pairing-card"),
  pairingQr: document.querySelector("#pairing-qr"),
  pairingCode: document.querySelector("#pairing-code"),
  pairingEndpoint: document.querySelector("#pairing-endpoint"),
  pairingExpiry: document.querySelector("#pairing-expiry"),
  closePairing: document.querySelector("#close-pairing"),
  error: document.querySelector("#error-message"),
  winMin: document.querySelector("#win-min"),
  winClose: document.querySelector("#win-close")
};

const invoke = window.__TAURI__?.core?.invoke;
let pairingTimer = 0;
let copyReset = 0;

function currentWindow() {
  const api = window.__TAURI__?.window;
  if (!api) {
    return null;
  }
  if (typeof api.getCurrentWindow === "function") {
    return api.getCurrentWindow();
  }
  if (typeof api.getCurrent === "function") {
    return api.getCurrent();
  }
  return api.appWindow ?? null;
}

function showError(message) {
  elements.error.textContent = message;
  elements.error.classList.remove("hidden");
}

function clearError() {
  elements.error.classList.add("hidden");
}

function displayHost(url) {
  return String(url ?? "").replace(/^https?:\/\//, "");
}

function showHome() {
  window.clearInterval(pairingTimer);
  elements.pairingCard.classList.add("hidden");
  elements.homeView.classList.remove("hidden");
}

function showPairing() {
  elements.homeView.classList.add("hidden");
  elements.pairingCard.classList.remove("hidden");
}

function startCountdown(seconds) {
  const endsAt = Date.now() + seconds * 1000;
  const tick = () => {
    const left = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
    const minutes = Math.floor(left / 60);
    const remainder = String(left % 60).padStart(2, "0");
    elements.pairingExpiry.textContent = `${minutes}:${remainder}`;
    if (left === 0) {
      showHome();
    }
  };
  window.clearInterval(pairingTimer);
  tick();
  pairingTimer = window.setInterval(tick, 1000);
}

async function copyText(value) {
  const text = String(value ?? "").trim();
  if (!text || text === "—" || text === "…") {
    return false;
  }
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

function flashCopied() {
  elements.copyLabel.textContent = "Copied";
  window.clearTimeout(copyReset);
  copyReset = window.setTimeout(() => {
    elements.copyLabel.textContent = "Copy address";
  }, 1400);
}

async function loadStatus() {
  if (!invoke) {
    showError("Host backend is unavailable.");
    return;
  }

  try {
    const status = await invoke("host_status");
    elements.hostName.textContent = status.hostName;
    const lines = [displayHost(status.lanEndpoint)];
    if (status.tailscaleEndpoint) {
      lines.push(displayHost(status.tailscaleEndpoint));
    }
    elements.endpoint.textContent = lines[0] ?? "—";
    elements.endpoint.title = lines.join("\n");
    elements.endpoint.dataset.copy = [status.lanEndpoint, status.tailscaleEndpoint]
      .filter(Boolean)
      .join("\n");

    const devices = Number(status.deviceCount ?? 0);
    const path = status.tailscaleEndpoint ? "LAN + Tailscale" : "LAN";
    const deviceLabel = devices === 1 ? "1 device" : `${devices} devices`;
    elements.appVersion.textContent = status.version;
    elements.hostMeta.textContent = `${path} · ${deviceLabel}`;
    if (!elements.updateSub.dataset.ready) {
      elements.updateSub.textContent = `This PC ${status.version}`;
    }

    if (status.sessionDevice) {
      elements.serviceState.textContent = status.sessionDevice;
      elements.serviceState.dataset.state = "busy";
      elements.serviceState.title = status.sessionVia
        ? `Connected · ${status.sessionVia}`
        : "Connected";
    } else {
      elements.serviceState.textContent = "Live";
      elements.serviceState.dataset.state = "live";
      elements.serviceState.title = "Ready";
    }
  } catch (error) {
    showError(String(error));
  }
}

async function copyAddress() {
  const copied = await copyText(
    elements.endpoint.dataset.copy || elements.endpoint.textContent
  );
  if (copied) {
    flashCopied();
  }
}

elements.winMin.addEventListener("click", () => currentWindow()?.minimize());
elements.winClose.addEventListener("click", () => currentWindow()?.close());
elements.endpoint.addEventListener("click", copyAddress);
elements.copyButton.addEventListener("click", copyAddress);

elements.pairingCode.addEventListener("click", () => {
  copyText(elements.pairingCode.textContent);
});

elements.pairButton.addEventListener("click", async () => {
  clearError();
  try {
    const response = await invoke("begin_pairing");
    elements.pairingEndpoint.textContent = displayHost(response.endpoint);
    elements.pairingCode.textContent = response.pairingCode;
    elements.pairingQr.innerHTML = response.qrSvg;
    startCountdown(response.expiresInSeconds);
    showPairing();
  } catch (error) {
    showError(String(error));
  }
});

function showUpdateStatus(result) {
  const current = result.currentVersion || elements.appVersion.textContent || "—";
  const latest = result.latestVersion || "—";
  elements.updateSub.dataset.ready = "1";
  elements.updateButton.dataset.available = result.status === "available" ? "1" : "0";
  if (result.status === "available") {
    elements.updateLabel.textContent = `Install ${latest}`;
    elements.updateSub.textContent = `This PC ${current}`;
  } else if (result.status === "installing") {
    elements.updateLabel.textContent = `Installing ${latest}`;
    elements.updateSub.textContent = `This PC ${current}`;
  } else if (current !== latest) {
    elements.updateLabel.textContent = "Up to date";
    elements.updateSub.textContent = `This PC ${current} · GitHub ${latest}`;
  } else {
    elements.updateLabel.textContent = "Up to date";
    elements.updateSub.textContent = `This PC ${current}`;
  }
}

async function refreshUpdateStatus() {
  if (!invoke) {
    return;
  }
  try {
    showUpdateStatus(await invoke("check_update"));
  } catch (error) {
    elements.updateLabel.textContent = "Update";
    elements.updateSub.textContent = "Could not check GitHub";
    elements.updateSub.dataset.ready = "1";
  }
}

elements.updateButton.addEventListener("click", async () => {
  clearError();
  elements.updateButton.disabled = true;
  elements.updateLabel.textContent = "Checking…";
  try {
    const check = await invoke("check_update");
    if (check.status !== "available") {
      showUpdateStatus(check);
      return;
    }
    elements.updateLabel.textContent = `Installing ${check.latestVersion}…`;
    const result = await invoke("install_update");
    showUpdateStatus(result);
  } catch (error) {
    elements.updateLabel.textContent = "Update";
    showError(String(error));
  } finally {
    elements.updateButton.disabled = false;
  }
});

elements.rotateButton.addEventListener("click", async () => {
  if (!window.confirm("Revoke every phone and issue a new certificate?")) {
    return;
  }
  clearError();
  try {
    await invoke("rotate_keys");
    showHome();
    await loadStatus();
  } catch (error) {
    showError(String(error));
  }
});

elements.closePairing.addEventListener("click", () => {
  showHome();
});

document.addEventListener(
  "wheel",
  (event) => {
    event.preventDefault();
  },
  { passive: false }
);

loadStatus();
refreshUpdateStatus();
setInterval(loadStatus, 2000);
