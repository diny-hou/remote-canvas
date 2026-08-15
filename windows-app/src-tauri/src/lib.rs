mod remote_host;

use qrcode::{render::svg, QrCode};
use remote_host::{RemoteHostState, PAIRING_TTL_SECONDS};
use serde::Serialize;

const UPDATE_URL: &str = "https://github.com/diny-hou/remote-canvas/releases/latest";

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
    host_name: String,
    endpoint: String,
    pairing_code: String,
    qr_svg: String,
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
fn begin_pairing(state: tauri::State<'_, RemoteHostState>) -> Result<PairingResponse, String> {
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".into());
    let endpoint = (*state.endpoint).clone();
    let pairing_code = state.begin_pairing();
    let payload = serde_json::json!({
        "version": 1,
        "name": host_name,
        "endpoint": endpoint,
        "code": pairing_code,
    })
    .to_string();
    let qr_code = QrCode::new(payload.as_bytes()).map_err(|error| error.to_string())?;
    let qr_svg = qr_code
        .render::<svg::Color>()
        .min_dimensions(248, 248)
        .dark_color(svg::Color("#07101a"))
        .light_color(svg::Color("#ffffff"))
        .build();

    Ok(PairingResponse {
        host_name,
        endpoint,
        pairing_code,
        qr_svg,
        expires_in_seconds: PAIRING_TTL_SECONDS,
    })
}

#[tauri::command]
fn open_update_page() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", UPDATE_URL])
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("更新ページを開けませんでした: {error}"))
    }

    #[cfg(not(target_os = "windows"))]
    {
        Err(format!("Windows版の更新ページ: {UPDATE_URL}"))
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
        .invoke_handler(tauri::generate_handler![
            host_status,
            begin_pairing,
            open_update_page
        ])
        .run(tauri::generate_context!())
        .expect("failed to run RemoteCanvas host");
}
