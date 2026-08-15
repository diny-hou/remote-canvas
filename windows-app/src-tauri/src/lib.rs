use serde::Serialize;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostStatus {
    version: &'static str,
    service_state: &'static str,
    host_name: String,
    paired_devices: usize,
    transport: &'static str,
}

#[derive(Serialize)]
struct PairingResponse {
    code: String,
    expires_in_seconds: u64,
}

#[tauri::command]
fn host_status() -> HostStatus {
    HostStatus {
        version: env!("CARGO_PKG_VERSION"),
        service_state: "準備完了",
        host_name: std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".into()),
        paired_devices: 0,
        transport: "WebRTCバックエンド準備中",
    }
}

#[tauri::command]
fn begin_pairing() -> PairingResponse {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let value = (seconds ^ (std::process::id() as u64 * 7919)) % 1_000_000;

    PairingResponse {
        code: format!("{value:06}"),
        expires_in_seconds: 300,
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![host_status, begin_pairing])
        .run(tauri::generate_context!())
        .expect("failed to run RemoteCanvas host");
}
