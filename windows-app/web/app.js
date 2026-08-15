const elements = {
  version: document.querySelector("#version"),
  serviceState: document.querySelector("#service-state"),
  hostName: document.querySelector("#host-name"),
  accessKeyStatus: document.querySelector("#access-key-status"),
  transport: document.querySelector("#transport"),
  endpoint: document.querySelector("#endpoint"),
  pairButton: document.querySelector("#pair-button"),
  pairingCard: document.querySelector("#pairing-card"),
  pairingEndpoint: document.querySelector("#pairing-endpoint"),
  pairingToken: document.querySelector("#pairing-token"),
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
    elements.pairingToken.textContent = response.accessToken;
    elements.pairingCard.classList.remove("hidden");
  } catch (error) {
    showError(String(error));
  }
});

elements.closePairing.addEventListener("click", () => {
  elements.pairingCard.classList.add("hidden");
});

loadStatus();
