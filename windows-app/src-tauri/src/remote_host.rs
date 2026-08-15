use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        DefaultBodyLimit, Query, State,
    },
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use rand::{rngs::OsRng, Rng, RngCore};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub const HOST_PORT: u16 = 47_831;
const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;
pub const PAIRING_TTL_SECONDS: u64 = 5 * 60;
const MAX_PAIRING_ATTEMPTS: u8 = 5;

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
pub struct RemoteHostState {
    pub access_token: Arc<String>,
    pub endpoint: Arc<String>,
    pairing: Arc<Mutex<PairingSession>>,
}

impl RemoteHostState {
    pub fn load() -> Self {
        let access_token = load_or_create_token();
        let address = local_ip_address::list_afinet_netifas()
            .ok()
            .and_then(|interfaces| {
                interfaces
                    .into_iter()
                    .map(|(_, address)| address)
                    .find(is_tailscale_address)
            })
            .or_else(|| local_ip_address::local_ip().ok())
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "127.0.0.1".into());

        Self {
            access_token: Arc::new(access_token),
            endpoint: Arc::new(format!("http://{address}:{HOST_PORT}")),
            pairing: Arc::new(Mutex::new(PairingSession::inactive())),
        }
    }

    pub fn begin_pairing(&self) -> String {
        let code = format!("{:06}", OsRng.gen_range(0..1_000_000_u32));
        let mut pairing = self
            .pairing
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        pairing.code = Some(code.clone());
        pairing.expires_at = Instant::now() + Duration::from_secs(PAIRING_TTL_SECONDS);
        pairing.failed_attempts = 0;
        code
    }

    fn redeem_pairing_code(&self, provided: &str) -> Option<String> {
        let mut pairing = self
            .pairing
            .lock()
            .unwrap_or_else(|error| error.into_inner());

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
        Some((*self.access_token).clone())
    }
}

fn is_tailscale_address(address: &std::net::IpAddr) -> bool {
    match address {
        std::net::IpAddr::V4(address) => {
            let octets = address.octets();
            octets[0] == 100 && (64..=127).contains(&octets[1])
        }
        std::net::IpAddr::V6(_) => false,
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
}

#[derive(Deserialize)]
struct PairingRequest {
    code: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingCredentials {
    access_token: String,
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
        let app = Router::new()
            .route("/health", get(health))
            .route("/api/pair", post(pair_device))
            .route("/ws", get(websocket_upgrade))
            .route("/api/files", get(list_files))
            .route("/api/file", get(download_file).put(upload_file))
            .layer(DefaultBodyLimit::max(MAX_FILE_BYTES as usize))
            .with_state(state);

        let listener = match tokio::net::TcpListener::bind(("0.0.0.0", HOST_PORT)).await {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("RemoteCanvas host could not bind port {HOST_PORT}: {error}");
                return;
            }
        };

        if let Err(error) = axum::serve(listener, app).await {
            eprintln!("RemoteCanvas host stopped: {error}");
        }
    });
}

async fn pair_device(
    State(state): State<RemoteHostState>,
    Json(request): Json<PairingRequest>,
) -> Response {
    match state.redeem_pairing_code(&request.code) {
        Some(access_token) => Json(PairingCredentials { access_token }).into_response(),
        None => (StatusCode::UNAUTHORIZED, "コードが無効または期限切れです").into_response(),
    }
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        protocol: "remote-canvas/1",
    })
}

async fn websocket_upgrade(
    State(state): State<RemoteHostState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if !authorized(&headers, &state) {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    ws.on_upgrade(handle_websocket)
}

async fn handle_websocket(mut socket: WebSocket) {
    let mut frame_timer = tokio::time::interval(Duration::from_millis(125));
    frame_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = frame_timer.tick() => {
                let frame = tokio::task::spawn_blocking(capture_primary_display).await;
                if let Ok(Ok(jpeg)) = frame {
                    if socket.send(Message::Binary(jpeg.into())).await.is_err() {
                        break;
                    }
                }
            }
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(command) = serde_json::from_str::<ClientCommand>(&text) {
                            let _ = tokio::task::spawn_blocking(move || apply_input(command)).await;
                        }
                    }
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
    if !authorized(&headers, &state) {
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
    if !authorized(&headers, &state) {
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
    if !authorized(&headers, &state) {
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
    allowed_roots()
        .into_iter()
        .map(|path| FileEntry {
            name: path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("Folder")
                .to_string(),
            path: path.to_string_lossy().into_owned(),
            is_directory: true,
            size: 0,
            modified_unix_seconds: 0,
        })
        .collect()
}

fn allowed_roots() -> Vec<PathBuf> {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    let names = ["Desktop", "Documents", "Downloads", "Pictures", "Videos"];

    names
        .into_iter()
        .map(|name| home.join(name))
        .filter(|path| path.exists())
        .filter_map(|path| path.canonicalize().ok())
        .collect()
}

fn allowed_existing_path(raw_path: &str) -> Result<PathBuf, String> {
    let requested = PathBuf::from(raw_path)
        .canonicalize()
        .map_err(|error| format!("Cannot open requested path: {error}"))?;
    if allowed_roots()
        .iter()
        .any(|root| requested.starts_with(root))
    {
        Ok(requested)
    } else {
        Err("Access is limited to Desktop, Documents, Downloads, Pictures, and Videos".into())
    }
}

fn authorized(headers: &HeaderMap, state: &RemoteHostState) -> bool {
    let expected = format!("Bearer {}", state.access_token);
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(|value| constant_time_equal(value.as_bytes(), expected.as_bytes()))
        .unwrap_or(false)
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

fn token_path() -> PathBuf {
    let base = std::env::var("APPDATA")
        .or_else(|_| std::env::var("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("RemoteCanvas").join("access-token.txt")
}

fn load_or_create_token() -> String {
    let path = token_path();
    if let Ok(token) = std::fs::read_to_string(&path) {
        let token = token.trim();
        if token.len() >= 32 {
            return token.to_string();
        }
    }

    let mut random = [0_u8; 24];
    OsRng.fill_bytes(&mut random);
    let token = random
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();

    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, &token);
    token
}

#[cfg(target_os = "windows")]
fn capture_primary_display() -> Result<Vec<u8>, String> {
    use image::{codecs::jpeg::JpegEncoder, DynamicImage, ImageBuffer, Rgba};

    let screen = primary_screen()?;
    let captured = screen.capture().map_err(|error| error.to_string())?;
    let width = captured.width();
    let height = captured.height();
    let buffer = ImageBuffer::<Rgba<u8>, _>::from_raw(width, height, captured.into_raw())
        .ok_or_else(|| "Invalid capture buffer".to_string())?;
    let mut image = DynamicImage::ImageRgba8(buffer);
    if image.width() > 1440 {
        let scaled_height = (image.height() as f64 * 1440.0 / image.width() as f64) as u32;
        image = image.resize(
            1440,
            scaled_height.max(1),
            image::imageops::FilterType::Triangle,
        );
    }

    let mut bytes = Vec::with_capacity(256 * 1024);
    JpegEncoder::new_with_quality(&mut bytes, 70)
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
fn capture_primary_display() -> Result<Vec<u8>, String> {
    Err("Screen capture is available in the Windows build".into())
}

#[cfg(target_os = "windows")]
fn apply_input(command: ClientCommand) {
    use enigo::{Axis, Button, Coordinate, Direction, Enigo, Keyboard, Mouse, Settings};

    let Ok(mut enigo) = Enigo::new(&Settings::default()) else {
        return;
    };
    match command {
        ClientCommand::Pointer {
            x,
            y,
            action,
            delta,
        } => {
            let display = primary_screen().ok().map(|screen| screen.display_info);
            let (origin_x, origin_y, width, height) = display
                .map(|display| (display.x, display.y, display.width, display.height))
                .unwrap_or((0, 0, 1920, 1080));
            let absolute_x = origin_x + (x.clamp(0.0, 1.0) * width as f64) as i32;
            let absolute_y = origin_y + (y.clamp(0.0, 1.0) * height as f64) as i32;
            let _ = enigo.move_mouse(absolute_x, absolute_y, Coordinate::Abs);
            match action.as_str() {
                "primary_click" => {
                    let _ = enigo.button(Button::Left, Direction::Click);
                }
                "secondary_click" => {
                    let _ = enigo.button(Button::Right, Direction::Click);
                }
                "scroll" => {
                    let _ = enigo.scroll(delta.round() as i32, Axis::Vertical);
                }
                _ => {}
            }
        }
        ClientCommand::Text { text } => {
            let _ = enigo.text(&text);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{constant_time_equal, is_tailscale_address, PairingSession, RemoteHostState};
    use std::{
        net::{IpAddr, Ipv4Addr},
        sync::{Arc, Mutex},
    };

    fn state() -> RemoteHostState {
        RemoteHostState {
            access_token: Arc::new("persistent-secret-token-for-tests".into()),
            endpoint: Arc::new("http://100.64.0.1:47831".into()),
            pairing: Arc::new(Mutex::new(PairingSession::inactive())),
        }
    }

    #[test]
    fn recognizes_tailscale_ipv4_range() {
        assert!(is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(
            100, 64, 0, 1
        ))));
        assert!(is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(
            100, 127, 255, 254
        ))));
        assert!(!is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(
            100, 128, 0, 1
        ))));
        assert!(!is_tailscale_address(&IpAddr::V4(Ipv4Addr::new(
            192, 168, 1, 10
        ))));
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
        assert_eq!(
            state.redeem_pairing_code(&code).as_deref(),
            Some("persistent-secret-token-for-tests")
        );
        assert!(state.redeem_pairing_code(&code).is_none());
    }

    #[test]
    fn pairing_code_locks_after_five_failures() {
        let state = state();
        let code = state.begin_pairing();
        let wrong_code = if code == "000000" { "000001" } else { "000000" };
        for _ in 0..5 {
            assert!(state.redeem_pairing_code(wrong_code).is_none());
        }
        assert!(state.redeem_pairing_code(&code).is_none());
    }
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
