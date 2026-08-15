const elements = {
  version: document.querySelector("#version"),
  serviceState: document.querySelector("#service-state"),
  hostName: document.querySelector("#host-name"),
  accessKeyStatus: document.querySelector("#access-key-status"),
  transport: document.querySelector("#transport"),
  endpoint: document.querySelector("#endpoint"),
  updateButton: document.querySelector("#update-button"),
  pairButton: document.querySelector("#pair-button"),
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

async function loadStatus() {
  if (!invoke) {
    showError("Tauriバックエンドを読み込めませんでした。");
    return;
  }

  try {
    const status = await invoke("host_status");
    elements.version.textContent = status.version;
    elements.serviceState.textContent = status.serviceState;
    elements.hostName.textContent = status.hostName;
    elements.accessKeyStatus.textContent = status.accessKeyConfigured ? "設定済み" : "未設定";
    elements.transport.textContent = status.transport;
    elements.endpoint.textContent = status.endpoint;
  } catch (error) {
    showError(String(error));
  }
}

elements.pairButton.addEventListener("click", async () => {
  try {
    const response = await invoke("begin_pairing");
    elements.pairingEndpoint.textContent = response.endpoint;
    elements.pairingCode.textContent = response.pairingCode;
    elements.pairingQr.innerHTML = response.qrSvg;
    elements.pairingExpiry.textContent = `${Math.round(response.expiresInSeconds / 60)}分`;
    elements.pairingCard.classList.remove("hidden");
  } catch (error) {
    showError(String(error));
  }
});

elements.updateButton.addEventListener("click", async () => {
  try {
    await invoke("open_update_page");
  } catch (error) {
    showError(String(error));
  }
});

elements.closePairing.addEventListener("click", () => {
  elements.pairingCard.classList.add("hidden");
});

loadStatus();
