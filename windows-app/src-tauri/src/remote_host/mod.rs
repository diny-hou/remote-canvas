mod store;

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, DefaultBodyLimit, Query, State,
    },
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_server::tls_rustls::RustlsConfig;
use rand::{rngs::OsRng, Rng};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use store::{append_session_log, now_unix, DeviceRecord, PersistedState};

pub const HOST_PORT: u16 = 47_831;
const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;
pub const PAIRING_TTL_SECONDS: u64 = 5 * 60;
const MAX_PAIRING_ATTEMPTS: u8 = 5;
const REPLAY_WINDOW_SECS: i64 = 90;

struct PairingSession {
    code: Option<String>,
    expires_at: Instant,
    failed_attempts: u8,
}

impl PairingSession {
    fn inactive() -> Self {
        Self {
            code: None,
            expires_at: Instant::now(),
            failed_attempts: 0,
        }
    }
}

#[derive(Clone)]
struct ActiveSession {
    device_name: String,
    via: String,
}

struct HostInner {
    persisted: PersistedState,
    replay: HashMap<String, Instant>,
    active: Option<ActiveSession>,
    persist: bool,
}

#[derive(Clone)]
pub struct RemoteHostState {
    pairing: Arc<Mutex<PairingSession>>,
    inner: Arc<Mutex<HostInner>>,
    tls: Arc<Mutex<Option<RustlsConfig>>>,
}

#[derive(Clone)]
pub struct HostEndpoints {
    pub lan: String,
    pub tailscale: Option<String>,
    candidates: Vec<String>,
}

impl HostEndpoints {
    pub fn all(&self) -> Vec<String> {
        self.candidates.clone()
    }
}

impl RemoteHostState {
    pub fn load() -> Self {
        Self {
            pairing: Arc::new(Mutex::new(PairingSession::inactive())),
            inner: Arc::new(Mutex::new(HostInner {
                persisted: PersistedState::load_or_create(),
                replay: HashMap::new(),
                active: None,
                persist: true,
            })),
            tls: Arc::new(Mutex::new(None)),
        }
    }

    pub fn begin_pairing(&self) -> String {
        let code = format!("{:06}", OsRng.gen_range(0..1_000_000_u32));
        let mut pairing = lock(&self.pairing);
        pairing.code = Some(code.clone());
        pairing.expires_at = Instant::now() + Duration::from_secs(PAIRING_TTL_SECONDS);
        pairing.failed_attempts = 0;
        code
    }

    pub fn cert_sha256(&self) -> String {
        lock(&self.inner).persisted.cert_sha256.clone()
    }

    pub fn device_count(&self) -> usize {
        lock(&self.inner).persisted.devices.len()
    }

    pub fn service_state(&self) -> String {
        match &lock(&self.inner).active {
            Some(session) => format!("Connected · {} · {}", session.device_name, session.via),
            None => "Live".into(),
        }
    }

    pub fn active_session(&self) -> Option<(String, String)> {
        lock(&self.inner)
            .active
            .as_ref()
            .map(|session| (session.device_name.clone(), session.via.clone()))
    }

    pub async fn rotate_keys(&self) -> Result<(), String> {
        {
            let mut inner = lock(&self.inner);
            inner.persisted.rotate_identity();
            inner.replay.clear();
            inner.active = None;
        }
        lock(&self.pairing).code = None;
        self.reload_tls().await
    }

    fn redeem_pairing_code(&self, provided: &str, client_name: &str) -> Option<DeviceRecord> {
        let mut pairing = lock(&self.pairing);
        if pairing.code.is_none()
            || Instant::now() > pairing.expires_at
            || pairing.failed_attempts >= MAX_PAIRING_ATTEMPTS
        {
            pairing.code = None;
            return None;
        }

        let matches = pairing
            .code
            .as_deref()
            .map(|expected| constant_time_equal(provided.trim().as_bytes(), expected.as_bytes()))
            .unwrap_or(false);
        if !matches {
            pairing.failed_attempts = pairing.failed_attempts.saturating_add(1);
            if pairing.failed_attempts >= MAX_PAIRING_ATTEMPTS {
                pairing.code = None;
            }
            return None;
        }

        pairing.code = None;
        drop(pairing);
        let mut inner = lock(&self.inner);
        let device = inner.persisted.issue_device(client_name);
        if inner.persist {
            inner.persisted.save();
        }
        Some(device)
    }

    fn check_replay(&self, headers: &HeaderMap) -> Result<(), StatusCode> {
        let timestamp = headers
            .get("x-rc-ts")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<i64>().ok())
            .ok_or(StatusCode::UNAUTHORIZED)?;
        let nonce = headers
            .get("x-rc-nonce")
            .and_then(|value| value.to_str().ok())
            .ok_or(StatusCode::UNAUTHORIZED)?;
        if nonce.len() < 16 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        if ((now_unix() as i64) - timestamp).abs() > REPLAY_WINDOW_SECS {
            return Err(StatusCode::UNAUTHORIZED);
        }

        let mut inner = lock(&self.inner);
        inner
            .replay
            .retain(|_, seen| seen.elapsed() < Duration::from_secs(120));
        if inner.replay.contains_key(nonce) {
            return Err(StatusCode::UNAUTHORIZED);
        }
        inner.replay.insert(nonce.to_string(), Instant::now());
        Ok(())
    }

    fn device_from_bearer(&self, headers: &HeaderMap) -> Option<DeviceRecord> {
        let token = headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))?;
        let inner = lock(&self.inner);
        let mut found = None;
        for device in &inner.persisted.devices {
            if constant_time_equal(device.token.as_bytes(), token.as_bytes()) {
                found = Some(device.clone());
            }
        }
        found
    }

    fn mark_connected(&self, device: &DeviceRecord, via: &str) {
        let mut inner = lock(&self.inner);
        inner.persisted.touch_device(&device.id);
        if inner.persist {
            inner.persisted.save();
        }
        inner.active = Some(ActiveSession {
            device_name: device.name.clone(),
            via: via.to_string(),
        });
    }

    fn mark_disconnected(&self) {
        lock(&self.inner).active = None;
        #[cfg(target_os = "windows")]
        release_mouse_buttons();
    }

    fn tls_pem(&self) -> (Vec<u8>, Vec<u8>) {
        let inner = lock(&self.inner);
        (
            inner.persisted.cert_pem.as_bytes().to_vec(),
            inner.persisted.key_pem.as_bytes().to_vec(),
        )
    }

    async fn reload_tls(&self) -> Result<(), String> {
        let (cert, key) = self.tls_pem();
        let tls = { lock(&self.tls).clone() };
        if let Some(tls) = tls {
            tls.reload_from_pem(cert, key)
                .await
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

pub fn discover_endpoints() -> HostEndpoints {
    let interfaces = local_ip_address::list_afinet_netifas().unwrap_or_default();
    let mut lan_ips = Vec::new();
    let mut tailscale = None;

    for (name, address) in &interfaces {
        if is_tailscale_address(address) {
            tailscale = Some(*address);
            continue;
        }
        if is_usable_lan(address) && !is_virtual_interface(name) {
            lan_ips.push(*address);
        }
    }

    lan_ips.sort_by_key(lan_priority);
    lan_ips.dedup();

    let lan = lan_ips
        .first()
        .copied()
        .or(tailscale)
        .or_else(|| {
            local_ip_address::local_ip()
                .ok()
                .filter(|address| is_usable_lan(address))
        })
        .unwrap_or_else(|| IpAddr::from([127, 0, 0, 1]));

    let mut candidates = lan_ips.into_iter().map(https_endpoint).collect::<Vec<_>>();
    if let Some(address) = tailscale {
        let endpoint = https_endpoint(address);
        if !candidates.contains(&endpoint) {
            candidates.push(endpoint);
        }
    }
    if candidates.is_empty() {
        candidates.push(https_endpoint(lan));
    }

    HostEndpoints {
        lan: https_endpoint(lan),
        tailscale: tailscale.map(https_endpoint),
        candidates,
    }
}

fn https_endpoint(address: IpAddr) -> String {
    match address {
        IpAddr::V6(ip) => format!("https://[{ip}]:{HOST_PORT}"),
        IpAddr::V4(ip) => format!("https://{ip}:{HOST_PORT}"),
    }
}

fn is_tailscale_address(address: &IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => {
            let octets = address.octets();
            octets[0] == 100 && (64..=127).contains(&octets[1])
        }
        IpAddr::V6(_) => false,
    }
}

fn is_private_lan(address: &IpAddr) -> bool {
    is_usable_lan(address) || matches!(address, IpAddr::V4(ip) if ip.is_loopback())
}

fn is_usable_lan(address: &IpAddr) -> bool {
    match address {
        IpAddr::V4(address) if !address.is_loopback() && !address.is_link_local() => {
            let octets = address.octets();
            octets[0] == 10
                || (octets[0] == 172 && (16..=31).contains(&octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        _ => false,
    }
}

fn is_virtual_interface(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    if (name.contains("wi-fi") || name.contains("wifi") || name.contains("wlan") || name.contains("ethernet"))
        && !name.contains("vethernet")
        && !name.contains("wsl")
    {
        return false;
    }
    [
        "loopback",
        "wsl",
        "vethernet",
        "virtualbox",
        "vmware",
        "hyper-v",
        "docker",
        "vbox",
        "bluetooth",
        "vmnet",
        "tap-windows",
        "npcap",
    ]
    .iter()
    .any(|marker| name.contains(marker))
}

fn lan_priority(address: &IpAddr) -> u8 {
    match address {
        IpAddr::V4(address) => {
            let octets = address.octets();
            if octets[0] == 192 && octets[1] == 168 {
                0
            } else if octets[0] == 10 {
                1
            } else {
                2
            }
        }
        IpAddr::V6(_) => 9,
    }
}

#[derive(Clone, Copy)]
struct StreamQuality {
    interval_ms: u64,
    jpeg_quality: u8,
    max_width: u32,
}

const LAN_QUALITY: StreamQuality = StreamQuality {
    interval_ms: 33,
    jpeg_quality: 58,
    max_width: 1280,
};

const REMOTE_QUALITY: StreamQuality = StreamQuality {
    interval_ms: 50,
    jpeg_quality: 48,
    max_width: 960,
};

fn stream_quality(headers: &HeaderMap, addr: SocketAddr) -> (StreamQuality, &'static str) {
    if let Some(path) = headers.get("x-rc-path").and_then(|value| value.to_str().ok()) {
        if path.eq_ignore_ascii_case("lan") {
            return (LAN_QUALITY, "lan");
        }
        if path.eq_ignore_ascii_case("tailscale") {
            return (REMOTE_QUALITY, "tailscale");
        }
    }
    if is_private_lan(&addr.ip()) {
        (LAN_QUALITY, "lan")
    } else {
        (REMOTE_QUALITY, "tailscale")
    }
}

#[derive(Deserialize)]
struct PathQuery {
    #[serde(default)]
    path: String,
    #[serde(default)]
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileEntry {
    name: String,
    path: String,
    is_directory: bool,
    size: u64,
    modified_unix_seconds: u64,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    protocol: &'static str,
    endpoints: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingRequest {
    code: String,
    #[serde(default)]
    client_name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingCredentials {
    access_token: String,
    device_id: String,
    cert_sha256: String,
    endpoints: Vec<String>,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientCommand {
    Pointer {
        x: f64,
        y: f64,
        action: String,
        #[serde(default)]
        delta: f64,
    },
    Text {
        text: String,
    },
}

pub fn start(state: RemoteHostState) {
    tauri::async_runtime::spawn(async move {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        open_firewall_port();
        let (cert_pem, key_pem) = state.tls_pem();
        let tls = match RustlsConfig::from_pem(cert_pem, key_pem).await {
            Ok(tls) => tls,
            Err(error) => {
                eprintln!("RemoteCanvas host could not load TLS: {error}");
                return;
            }
        };
        *lock(&state.tls) = Some(tls.clone());

        let app = Router::new()
            .route("/health", get(health))
            .route("/api/pair", post(pair_device))
            .route("/ws", get(websocket_upgrade))
            .route("/api/files", get(list_files))
            .route("/api/file", get(download_file).put(upload_file))
            .layer(DefaultBodyLimit::max(MAX_FILE_BYTES as usize))
            .with_state(state);

        let addr = SocketAddr::from(([0, 0, 0, 0], HOST_PORT));
        if let Err(error) = axum_server::bind_rustls(addr, tls)
            .serve(app.into_make_service_with_connect_info::<SocketAddr>())
            .await
        {
            eprintln!("RemoteCanvas host stopped: {error}");
        }
    });
}

fn open_firewall_port() {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let _ = std::process::Command::new("netsh")
            .args([
                "advfirewall",
                "firewall",
                "add",
                "rule",
                "name=RemoteCanvas",
                "dir=in",
                "action=allow",
                "protocol=TCP",
                "localport=47831",
                "profile=any",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }
}

async fn pair_device(
    State(state): State<RemoteHostState>,
    Json(request): Json<PairingRequest>,
) -> Response {
    match state.redeem_pairing_code(&request.code, &request.client_name) {
        Some(device) => Json(PairingCredentials {
            access_token: device.token,
            device_id: device.id,
            cert_sha256: state.cert_sha256(),
            endpoints: discover_endpoints().all(),
        })
        .into_response(),
        None => (StatusCode::UNAUTHORIZED, "Invalid or expired code").into_response(),
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        protocol: "remote-canvas/1",
        endpoints: discover_endpoints().all(),
    })
}

async fn websocket_upgrade(
    State(state): State<RemoteHostState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let device = match authorize(&headers, &state) {
        Ok(device) => device,
        Err(status) => return status.into_response(),
    };
    let (quality, via) = stream_quality(&headers, addr);
    state.mark_connected(&device, via);
    append_session_log(&format!(
        "{} connected {} {} {via}",
        now_unix(),
        device.name,
        addr
    ));
    notify_connected(&device.name, via);
    let disconnect_state = state.clone();
    ws.on_upgrade(move |socket| async move {
        handle_websocket(socket, quality).await;
        disconnect_state.mark_disconnected();
    })
}

async fn handle_websocket(mut socket: WebSocket, quality: StreamQuality) {
    let (frame_tx, mut frame_rx) = tokio::sync::watch::channel(Vec::<u8>::new());
    tokio::spawn(async move {
        let mut frame_timer = tokio::time::interval(Duration::from_millis(quality.interval_ms));
        frame_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            frame_timer.tick().await;
            let captured = tokio::task::spawn_blocking(move || {
                capture_primary_display(quality.max_width, quality.jpeg_quality)
            })
            .await;
            match captured {
                Ok(Ok(jpeg)) if !jpeg.is_empty() => {
                    if frame_tx.send(jpeg).is_err() {
                        break;
                    }
                }
                Ok(Err(_)) | Err(_) => {}
                Ok(Ok(_)) => {}
            }
        }
    });

    let mut ping_timer = tokio::time::interval(Duration::from_secs(5));
    ping_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            changed = frame_rx.changed() => {
                if changed.is_err() {
                    break;
                }
                let jpeg = frame_rx.borrow().clone();
                if jpeg.is_empty() {
                    continue;
                }
                if socket.send(Message::Binary(jpeg.into())).await.is_err() {
                    break;
                }
            }
            _ = ping_timer.tick() => {
                if socket.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(command) = serde_json::from_str::<ClientCommand>(&text) {
                            apply_input(command);
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
        }
    }
}

async fn list_files(
    State(state): State<RemoteHostState>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
) -> Response {
    if authorize(&headers, &state).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    match tokio::task::spawn_blocking(move || read_directory(query.path)).await {
        Ok(Ok(entries)) => Json(entries).into_response(),
        Ok(Err(error)) => (StatusCode::BAD_REQUEST, error).into_response(),
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
    }
}

async fn download_file(
    State(state): State<RemoteHostState>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
) -> Response {
    if authorize(&headers, &state).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    let path = match allowed_existing_path(&query.path) {
        Ok(path) if path.is_file() => path,
        _ => return (StatusCode::NOT_FOUND, "File not found").into_response(),
    };
    if path
        .metadata()
        .map(|metadata| metadata.len())
        .unwrap_or(u64::MAX)
        > MAX_FILE_BYTES
    {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            "Files larger than 512 MiB are not supported",
        )
            .into_response();
    }

    match tokio::fs::read(&path).await {
        Ok(bytes) => {
            let file_name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("download.bin");
            Response::builder()
                .header(header::CONTENT_TYPE, "application/octet-stream")
                .header(
                    header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{}\"", file_name.replace('"', "")),
                )
                .body(Body::from(bytes))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
    }
}

async fn upload_file(
    State(state): State<RemoteHostState>,
    headers: HeaderMap,
    Query(query): Query<PathQuery>,
    body: axum::body::Bytes,
) -> Response {
    if authorize(&headers, &state).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    let Some(file_name) = Path::new(&query.name).file_name() else {
        return (StatusCode::BAD_REQUEST, "Invalid file name").into_response();
    };
    let directory = match allowed_existing_path(&query.path) {
        Ok(path) if path.is_dir() => path,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "Upload destination is not an allowed directory",
            )
                .into_response()
        }
    };
    let destination = directory.join(file_name);

    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create_new(true);
    match options.open(&destination).await {
        Ok(mut file) => {
            use tokio::io::AsyncWriteExt;
            match file.write_all(&body).await {
                Ok(()) => StatusCode::CREATED.into_response(),
                Err(error) => {
                    (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response()
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            (StatusCode::CONFLICT, "A file with that name already exists").into_response()
        }
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
    }
}

fn authorize(headers: &HeaderMap, state: &RemoteHostState) -> Result<DeviceRecord, StatusCode> {
    state.check_replay(headers)?;
    state
        .device_from_bearer(headers)
        .ok_or(StatusCode::UNAUTHORIZED)
}

fn read_directory(path: String) -> Result<Vec<FileEntry>, String> {
    if path.trim().is_empty() {
        return Ok(default_locations());
    }

    let allowed_path = allowed_existing_path(&path)?;
    if !allowed_path.is_dir() {
        return Err("The requested path is not a directory".into());
    }

    let mut entries = std::fs::read_dir(&allowed_path)
        .map_err(|error| format!("Cannot open {path}: {error}"))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            let modified_unix_seconds = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs())
                .unwrap_or(0);

            Some(FileEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                path: entry.path().to_string_lossy().into_owned(),
                is_directory: metadata.is_dir(),
                size: if metadata.is_file() {
                    metadata.len()
                } else {
                    0
                },
                modified_unix_seconds,
            })
        })
        .collect::<Vec<_>>();

    entries.sort_by(|left, right| {
        right
            .is_directory
            .cmp(&left.is_directory)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });
    Ok(entries)
}

fn default_locations() -> Vec<FileEntry> {
    let mut entries = Vec::new();
    if let Some(home) = user_home() {
        entries.push(FileEntry {
            name: "Home".into(),
            path: home.to_string_lossy().into_owned(),
            is_directory: true,
            size: 0,
            modified_unix_seconds: 0,
        });
    }
    entries.extend(available_drives().into_iter().map(|path| FileEntry {
        name: drive_label(&path),
        path: path.to_string_lossy().into_owned(),
        is_directory: true,
        size: 0,
        modified_unix_seconds: 0,
    }));
    entries
}

fn user_home() -> Option<PathBuf> {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .ok()
        .map(PathBuf::from)
        .filter(|path| path.exists())
}

fn available_drives() -> Vec<PathBuf> {
    #[cfg(windows)]
    {
        (b'A'..=b'Z')
            .filter_map(|letter| {
                let root = PathBuf::from(format!("{}:\\", letter as char));
                root.exists().then_some(root)
            })
            .collect()
    }
    #[cfg(not(windows))]
    {
        vec![PathBuf::from("/")]
    }
}

fn drive_label(path: &Path) -> String {
    let label = path.to_string_lossy().trim_end_matches(['\\', '/']).to_string();
    if label.is_empty() {
        path.to_string_lossy().into_owned()
    } else {
        label
    }
}

fn strip_extended_prefix(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    text.strip_prefix(r"\\?\")
        .map(PathBuf::from)
        .unwrap_or(path)
}

fn is_allowed_location(path: &Path) -> bool {
    let text = strip_extended_prefix(path.to_path_buf());
    let text = text.to_string_lossy();
    #[cfg(windows)]
    {
        let mut chars = text.chars();
        matches!(chars.next(), Some(letter) if letter.is_ascii_alphabetic()) && chars.next() == Some(':')
    }
    #[cfg(not(windows))]
    {
        text.starts_with('/')
    }
}

fn allowed_existing_path(raw_path: &str) -> Result<PathBuf, String> {
    let requested = PathBuf::from(raw_path)
        .canonicalize()
        .map_err(|error| format!("Cannot open requested path: {error}"))?;
    if is_allowed_location(&requested) {
        Ok(requested)
    } else {
        Err("That location is not on a local drive".into())
    }
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn lock<T>(value: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|error| error.into_inner())
}

fn notify_connected(name: &str, via: &str) {
    #[cfg(target_os = "windows")]
    {
        let body = format!("{name} connected · {via}").replace('\'', "''");
        let script = format!(
            "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); $n = $t.GetElementsByTagName('text'); $n.Item(0).AppendChild($t.CreateTextNode('RemoteCanvas')) | Out-Null; $n.Item(1).AppendChild($t.CreateTextNode('{body}')) | Out-Null; [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('RemoteCanvas').Show([Windows.UI.Notifications.ToastNotification]::new($t))"
        );
        let _ = std::process::Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script])
            .spawn();
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (name, via);
    }
}

#[cfg(target_os = "windows")]
fn capture_primary_display(max_width: u32, jpeg_quality: u8) -> Result<Vec<u8>, String> {
    use image::{codecs::jpeg::JpegEncoder, DynamicImage, ImageBuffer, Rgba};

    let screen = primary_screen()?;
    let captured = screen.capture().map_err(|error| error.to_string())?;
    let width = captured.width();
    let height = captured.height();
    let buffer = ImageBuffer::<Rgba<u8>, _>::from_raw(width, height, captured.into_raw())
        .ok_or_else(|| "Invalid capture buffer".to_string())?;
    let mut image = DynamicImage::ImageRgba8(buffer);
    if image.width() > max_width {
        let scaled_height = (image.height() as f64 * f64::from(max_width) / image.width() as f64) as u32;
        image = image.resize(
            max_width,
            scaled_height.max(1),
            image::imageops::FilterType::Triangle,
        );
    }

    let mut bytes = Vec::with_capacity(256 * 1024);
    JpegEncoder::new_with_quality(&mut bytes, jpeg_quality)
        .encode_image(&image)
        .map_err(|error| error.to_string())?;
    Ok(bytes)
}

#[cfg(target_os = "windows")]
fn primary_screen() -> Result<screenshots::Screen, String> {
    let screens = screenshots::Screen::all().map_err(|error| error.to_string())?;
    screens
        .iter()
        .find(|screen| screen.display_info.is_primary)
        .copied()
        .or_else(|| screens.first().copied())
        .ok_or_else(|| "No display found".to_string())
}

#[cfg(not(target_os = "windows"))]
fn capture_primary_display(_max_width: u32, _jpeg_quality: u8) -> Result<Vec<u8>, String> {
    Err("Screen capture is available in the Windows build".into())
}

#[cfg(target_os = "windows")]
fn apply_input(command: ClientCommand) {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN,
        MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL,
    };

    match command {
        ClientCommand::Pointer {
            x,
            y,
            action,
            delta,
        } => {
            let (px, py) = screen_point(x, y);
            match action.as_str() {
                "move" => send_mouse(px, py, 0, 0),
                "primary_down" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTDOWN, 0);
                }
                "primary_up" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTUP, 0);
                }
                "primary_click" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTDOWN, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTUP, 0);
                }
                "secondary_click" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_RIGHTDOWN, 0);
                    send_mouse(px, py, MOUSEEVENTF_RIGHTUP, 0);
                }
                "double_click" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTDOWN, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTUP, 0);
                    std::thread::sleep(Duration::from_millis(50));
                    send_mouse(px, py, MOUSEEVENTF_LEFTDOWN, 0);
                    send_mouse(px, py, MOUSEEVENTF_LEFTUP, 0);
                }
                "scroll" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_WHEEL, delta.round() as i32 * 120);
                }
                "scroll_horizontal" => {
                    send_mouse(px, py, 0, 0);
                    send_mouse(px, py, MOUSEEVENTF_HWHEEL, delta.round() as i32 * 120);
                }
                _ => send_mouse(px, py, 0, 0),
            }
        }
        ClientCommand::Text { text } => type_text(&text),
    }
}

#[cfg(target_os = "windows")]
fn screen_point(x: f64, y: f64) -> (i32, i32) {
    let display = primary_screen().ok().map(|screen| screen.display_info);
    let (origin_x, origin_y, width, height) = display
        .map(|display| (display.x, display.y, display.width, display.height))
        .unwrap_or((0, 0, 1920, 1080));
    (
        origin_x + (x.clamp(0.0, 1.0) * width as f64) as i32,
        origin_y + (y.clamp(0.0, 1.0) * height as f64) as i32,
    )
}

#[cfg(target_os = "windows")]
fn release_mouse_buttons() {
    use windows_sys::Win32::Foundation::POINT;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTUP,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;

    let mut point = POINT { x: 0, y: 0 };
    unsafe {
        let _ = GetCursorPos(&mut point);
    }
    send_mouse(point.x, point.y, MOUSEEVENTF_LEFTUP, 0);
    send_mouse(point.x, point.y, MOUSEEVENTF_RIGHTUP, 0);
}

#[cfg(target_os = "windows")]
fn send_mouse(px: i32, py: i32, extra_flags: u32, mouse_data: i32) {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEINPUT, MOUSEEVENTF_ABSOLUTE,
        MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
        SM_YVIRTUALSCREEN,
    };

    let vx = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let vy = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    let vw = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) }.max(1);
    let vh = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) }.max(1);
    let abs_x = ((i64::from(px - vx) * 65535) / i64::from(vw)) as i32;
    let abs_y = ((i64::from(py - vy) * 65535) / i64::from(vh)) as i32;
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: abs_x,
                dy: abs_y,
                mouseData: mouse_data as u32,
                dwFlags: MOUSEEVENTF_ABSOLUTE
                    | MOUSEEVENTF_MOVE
                    | MOUSEEVENTF_VIRTUALDESK
                    | extra_flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(1, &input, std::mem::size_of::<INPUT>() as i32);
    }
}

#[cfg(target_os = "windows")]
fn type_text(text: &str) {
    use enigo::{Enigo, Keyboard, Settings};
    let Ok(mut enigo) = Enigo::new(&Settings::default()) else {
        return;
    };
    let _ = enigo.text(text);
}

#[cfg(not(target_os = "windows"))]
fn apply_input(command: ClientCommand) {
    match command {
        ClientCommand::Pointer {
            x,
            y,
            action,
            delta,
        } => {
            let _ = (x, y, action, delta);
        }
        ClientCommand::Text { text } => {
            let _ = text;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        constant_time_equal, is_allowed_location, is_private_lan, is_tailscale_address,
        is_usable_lan, is_virtual_interface, HostInner, PairingSession, RemoteHostState,
    };
    use crate::remote_host::store::PersistedState;
    use axum::http::HeaderMap;
    use std::{
        collections::HashMap,
        net::{IpAddr, Ipv4Addr},
        sync::{Arc, Mutex},
    };

    fn state() -> RemoteHostState {
        RemoteHostState {
            pairing: Arc::new(Mutex::new(PairingSession::inactive())),
            inner: Arc::new(Mutex::new(HostInner {
                persisted: PersistedState {
                    cert_pem: String::new(),
                    key_pem: String::new(),
                    cert_sha256: "ab".into(),
                    devices: Vec::new(),
                    key_version: 1,
                },
                replay: HashMap::new(),
                active: None,
                persist: false,
            })),
            tls: Arc::new(Mutex::new(None)),
        }
    }

    #[test]
    fn recognizes_tailscale_ipv4_range() {
        assert!(is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))));
        assert!(is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(
            100, 127, 255, 254
        ))));
        assert!(!is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(100, 128, 0, 1))));
        assert!(!is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10))));
        assert!(is_private_lan(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10))));
        assert!(is_usable_lan(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10))));
        assert!(!is_usable_lan(&IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))));
        assert!(is_virtual_interface("vEthernet (WSL)"));
        assert!(!is_virtual_interface("Wi-Fi"));
    }

    #[test]
    fn compares_access_keys_without_early_byte_exit() {
        assert!(constant_time_equal(b"same-key", b"same-key"));
        assert!(!constant_time_equal(b"same-key", b"same-kex"));
        assert!(!constant_time_equal(b"short", b"longer"));
    }

    #[test]
    fn pairing_code_is_six_digits_and_single_use() {
        let state = state();
        let code = state.begin_pairing();
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|byte| byte.is_ascii_digit()));
        let first = state.redeem_pairing_code(&code, "iPhone").unwrap();
        assert_eq!(first.token.len(), 48);
        assert!(state.redeem_pairing_code(&code, "iPhone").is_none());
    }

    #[test]
    fn pairing_code_locks_after_five_failures() {
        let state = state();
        let code = state.begin_pairing();
        let wrong_code = if code == "000000" { "000001" } else { "000000" };
        for _ in 0..5 {
            assert!(state.redeem_pairing_code(wrong_code, "iPhone").is_none());
        }
        assert!(state.redeem_pairing_code(&code, "iPhone").is_none());
    }

    #[test]
    fn replay_nonce_is_rejected() {
        let state = state();
        let mut headers = HeaderMap::new();
        headers.insert("x-rc-ts", now_header());
        headers.insert("x-rc-nonce", "0123456789abcdef0123456789abcdef".parse().unwrap());
        assert!(state.check_replay(&headers).is_ok());
        assert!(state.check_replay(&headers).is_err());
    }

    #[test]
    fn classifies_local_drive_paths() {
        #[cfg(windows)]
        {
            assert!(is_allowed_location(std::path::Path::new(r"C:\Users")));
            assert!(is_allowed_location(std::path::Path::new(r"\\?\D:\data")));
            assert!(!is_allowed_location(std::path::Path::new(r"\\server\share")));
        }
        #[cfg(not(windows))]
        {
            assert!(is_allowed_location(std::path::Path::new("/Users")));
            assert!(!is_allowed_location(std::path::Path::new("relative")));
        }
    }

    fn now_header() -> axum::http::HeaderValue {
        crate::remote_host::store::now_unix()
            .to_string()
            .parse()
            .unwrap()
    }
}
