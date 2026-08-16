mod remote_host;
mod updater;

use qrcode::{render::svg, QrCode};
use remote_host::{discover_endpoints, RemoteHostState, PAIRING_TTL_SECONDS};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostStatus {
    version: &'static str,
    service_state: String,
    host_name: String,
    endpoint: String,
    lan_endpoint: String,
    tailscale_endpoint: Option<String>,
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

fn host_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".into())
}

#[tauri::command]
fn host_status(state: tauri::State<'_, RemoteHostState>) -> HostStatus {
    let endpoints = discover_endpoints();
    HostStatus {
        version: env!("CARGO_PKG_VERSION"),
        service_state: state.service_state(),
        host_name: host_name(),
        endpoint: endpoints.lan.clone(),
        lan_endpoint: endpoints.lan,
        tailscale_endpoint: endpoints.tailscale,
    }
}

#[tauri::command]
fn begin_pairing(state: tauri::State<'_, RemoteHostState>) -> Result<PairingResponse, String> {
    let host_name = host_name();
    let endpoints = discover_endpoints();
    let pairing_code = state.begin_pairing();
    let payload = serde_json::json!({
        "version": 2,
        "name": host_name,
        "code": pairing_code,
        "certSha256": state.cert_sha256(),
        "endpoint": endpoints.lan,
        "endpoints": endpoints.all(),
    })
    .to_string();
    let qr_code = QrCode::new(payload.as_bytes()).map_err(|error| error.to_string())?;
    let qr_svg = qr_code
        .render::<svg::Color>()
        .min_dimensions(248, 248)
        .dark_color(svg::Color("#111111"))
        .light_color(svg::Color("#ffffff"))
        .build();

    Ok(PairingResponse {
        host_name,
        endpoint: endpoints.lan,
        pairing_code,
        qr_svg,
        expires_in_seconds: PAIRING_TTL_SECONDS,
    })
}

#[tauri::command]
async fn rotate_keys(state: tauri::State<'_, RemoteHostState>) -> Result<(), String> {
    state.rotate_keys().await
}

#[tauri::command]
async fn install_update(app: tauri::AppHandle) -> Result<updater::UpdateStatus, String> {
    let result = updater::install_latest(env!("CARGO_PKG_VERSION")).await?;
    if result.status == "installing" {
        app.exit(0);
    }
    Ok(result)
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
            rotate_keys,
            install_update
        ])
        .run(tauri::generate_context!())
        .expect("failed to run RemoteCanvas host");
}
