const elements = {
  version: document.querySelector("#version"),
  serviceState: document.querySelector("#service-state"),
  hostName: document.querySelector("#host-name"),
  pairedDevices: document.querySelector("#paired-devices"),
  transport: document.querySelector("#transport"),
  pairButton: document.querySelector("#pair-button"),
  pairingCard: document.querySelector("#pairing-card"),
  pairingCode: document.querySelector("#pairing-code"),
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
    elements.pairedDevices.textContent = `${status.pairedDevices}台`;
    elements.transport.textContent = status.transport;
  } catch (error) {
    showError(String(error));
  }
}

elements.pairButton.addEventListener("click", async () => {
  try {
    const response = await invoke("begin_pairing");
    elements.pairingCode.textContent = response.code;
    elements.pairingCard.classList.remove("hidden");
  } catch (error) {
    showError(String(error));
  }
});

elements.closePairing.addEventListener("click", () => {
  elements.pairingCard.classList.add("hidden");
});

loadStatus();
