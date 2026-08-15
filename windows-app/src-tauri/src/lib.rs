mod remote_host;

use remote_host::RemoteHostState;
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostStatus {
    version: &'static str,
    service_state: &'static str,
    host_name: String,
    access_key_configured: bool,
    transport: &'static str,
    endpoint: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingResponse {
    endpoint: String,
    access_token: String,
    expires_in_seconds: u64,
}

#[tauri::command]
fn host_status(state: tauri::State<'_, RemoteHostState>) -> HostStatus {
    HostStatus {
        version: env!("CARGO_PKG_VERSION"),
        service_state: "配信中",
        host_name: std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".into()),
        access_key_configured: true,
        transport: "Tailscale / LAN・認証付きストリーム",
        endpoint: (*state.endpoint).clone(),
    }
}

#[tauri::command]
fn begin_pairing(state: tauri::State<'_, RemoteHostState>) -> PairingResponse {
    PairingResponse {
        endpoint: (*state.endpoint).clone(),
        access_token: (*state.access_token).clone(),
        expires_in_seconds: 0,
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let host_state = RemoteHostState::load();
    let server_state = host_state.clone();

    tauri::Builder::default()
        .manage(host_state)
        .setup(move |_| {
            remote_host::start(server_state.clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![host_status, begin_pairing])
        .run(tauri::generate_context!())
        .expect("failed to run RemoteCanvas host");
}
