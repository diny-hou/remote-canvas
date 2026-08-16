const elements = {
  serviceState: document.querySelector("#service-state"),
  hostName: document.querySelector("#host-name"),
  endpoint: document.querySelector("#endpoint"),
  pairButton: document.querySelector("#pair-button"),
  updateButton: document.querySelector("#update-button"),
  rotateButton: document.querySelector("#rotate-button"),
  pairingCard: document.querySelector("#pairing-card"),
  pairingQr: document.querySelector("#pairing-qr"),
  pairingCode: document.querySelector("#pairing-code"),
  pairingEndpoint: document.querySelector("#pairing-endpoint"),
  pairingExpiry: document.querySelector("#pairing-expiry"),
  closePairing: document.querySelector("#close-pairing"),
  error: document.querySelector("#error-message")
};

const invoke = window.__TAURI__?.core?.invoke;

function showError(message) {
  elements.error.textContent = message;
  elements.error.classList.remove("hidden");
}

function clearError() {
  elements.error.classList.add("hidden");
}

async function loadStatus() {
  if (!invoke) {
    showError("Host backend is unavailable.");
    return;
  }

  try {
    const status = await invoke("host_status");
    elements.serviceState.textContent = status.serviceState;
    elements.hostName.textContent = status.hostName;
    elements.endpoint.textContent = status.tailscaleEndpoint
      ? `${status.lanEndpoint}\n${status.tailscaleEndpoint}`
      : status.lanEndpoint;
  } catch (error) {
    showError(String(error));
  }
}

elements.pairButton.addEventListener("click", async () => {
  clearError();
  try {
    const response = await invoke("begin_pairing");
    elements.pairingEndpoint.textContent = response.endpoint;
    elements.pairingCode.textContent = response.pairingCode;
    elements.pairingQr.innerHTML = response.qrSvg;
    elements.pairingExpiry.textContent = `${Math.round(response.expiresInSeconds / 60)} min`;
    elements.pairingCard.classList.remove("hidden");
  } catch (error) {
    showError(String(error));
  }
});

elements.updateButton.addEventListener("click", async () => {
  clearError();
  elements.updateButton.disabled = true;
  elements.updateButton.textContent = "Checking…";
  try {
    const result = await invoke("install_update");
    if (result.status === "upToDate") {
      elements.updateButton.textContent = "Up to date";
    } else {
      elements.updateButton.textContent = "Installing…";
    }
  } catch (error) {
    elements.updateButton.textContent = "Update";
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
    elements.pairingCard.classList.add("hidden");
    await loadStatus();
  } catch (error) {
    showError(String(error));
  }
});

elements.closePairing.addEventListener("click", () => {
  elements.pairingCard.classList.add("hidden");
});

loadStatus();
setInterval(loadStatus, 2000);
