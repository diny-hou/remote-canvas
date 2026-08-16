use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
    pub token: String,
    pub created_unix: u64,
    pub last_seen_unix: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PersistedState {
    pub cert_pem: String,
    pub key_pem: String,
    pub cert_sha256: String,
    pub devices: Vec<DeviceRecord>,
    pub key_version: u32,
}

impl PersistedState {
    pub fn load_or_create() -> Self {
        let path = state_path();
        if let Ok(bytes) = fs::read(&path) {
            if let Ok(decoded) = unprotect(&bytes) {
                if let Ok(state) = serde_json::from_slice::<PersistedState>(&decoded) {
                    if !state.cert_pem.is_empty() && !state.key_pem.is_empty() {
                        retire_legacy_token();
                        return state;
                    }
                }
            }
        }

        let mut state = generate_identity();
        state.key_version = 1;
        state.save();
        retire_legacy_token();
        state
    }

    pub fn save(&self) {
        let path = state_path();
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec(self) {
            if let Ok(protected) = protect(&json) {
                let _ = fs::write(path, protected);
            }
        }
    }

    pub fn rotate_identity(&mut self) {
        let devices_cleared = generate_identity();
        self.cert_pem = devices_cleared.cert_pem;
        self.key_pem = devices_cleared.key_pem;
        self.cert_sha256 = devices_cleared.cert_sha256;
        self.devices.clear();
        self.key_version = self.key_version.saturating_add(1);
        self.save();
    }

    pub fn issue_device(&mut self, name: &str) -> DeviceRecord {
        let mut random = [0_u8; 24];
        OsRng.fill_bytes(&mut random);
        let record = DeviceRecord {
            id: uuid_v4(),
            name: if name.trim().is_empty() {
                "iPhone".into()
            } else {
                name.trim().to_string()
            },
            token: to_hex(&random),
            created_unix: now_unix(),
            last_seen_unix: now_unix(),
        };
        self.devices.push(record.clone());
        record
    }

    pub fn touch_device(&mut self, id: &str) {
        if let Some(device) = self.devices.iter_mut().find(|device| device.id == id) {
            device.last_seen_unix = now_unix();
        }
    }
}

pub fn data_dir() -> PathBuf {
    std::env::var("APPDATA")
        .or_else(|_| std::env::var("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("RemoteCanvas")
}

fn state_path() -> PathBuf {
    data_dir().join("host-state.bin")
}

fn legacy_token_path() -> PathBuf {
    data_dir().join("access-token.txt")
}

fn retire_legacy_token() {
    let path = legacy_token_path();
    if path.exists() {
        let _ = fs::remove_file(path);
    }
}

fn generate_identity() -> PersistedState {
    let key_pair = rcgen::KeyPair::generate().expect("generate host TLS key");
    let mut params = rcgen::CertificateParams::new(vec![
        "localhost".into(),
        "remotecanvas.host".into(),
    ])
    .expect("tls certificate params");
    let mut distinguished_name = rcgen::DistinguishedName::new();
    distinguished_name.push(rcgen::DnType::CommonName, "RemoteCanvas Host");
    params.distinguished_name = distinguished_name;
    let cert = params.self_signed(&key_pair).expect("self-signed host certificate");
    let cert_der = cert.der();
    PersistedState {
        cert_pem: cert.pem(),
        key_pem: key_pair.serialize_pem(),
        cert_sha256: sha256_hex(cert_der.as_ref()),
        devices: Vec::new(),
        key_version: 1,
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    to_hex(&Sha256::digest(bytes))
}

pub fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn uuid_v4() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

#[cfg(target_os = "windows")]
fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
    dpapi(data, true)
}

#[cfg(target_os = "windows")]
fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
    dpapi(data, false)
}

#[cfg(target_os = "windows")]
fn dpapi(data: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB},
    };

    let mut input = CRYPT_INTEGER_BLOB {
        cbData: data.len() as u32,
        pbData: data.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let status = unsafe {
        if encrypt {
            CryptProtectData(
                &mut input,
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &mut input,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                &mut output,
            )
        }
    };
    if status == 0 {
        return Err("DPAPI operation failed".into());
    }
    let bytes =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(output.pbData as _);
    }
    Ok(bytes)
}

#[cfg(not(target_os = "windows"))]
fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
    Ok(data.to_vec())
}

#[cfg(not(target_os = "windows"))]
fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
    Ok(data.to_vec())
}

pub fn append_session_log(line: &str) {
    let path = data_dir().join("sessions.log");
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write;
        let _ = writeln!(file, "{line}");
    }
}

