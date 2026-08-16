use serde::Deserialize;
use std::{fs, io::Write, path::PathBuf};

const REPO: &str = "diny-hou/remote-canvas";

#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub status: &'static str,
    pub current_version: String,
    pub latest_version: String,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    assets: Vec<GithubAsset>,
}

#[derive(Deserialize)]
struct GithubAsset {
    id: u64,
    name: String,
}

pub async fn check_latest(current_version: &str) -> Result<UpdateStatus, String> {
    let release = fetch_latest().await?;
    Ok(status_from(current_version, &release.tag_name, false))
}

pub async fn install_latest(current_version: &str) -> Result<UpdateStatus, String> {
    let release = fetch_latest().await?;
    let latest = normalize_version(&release.tag_name);
    if version_tuple(&latest) <= version_tuple(current_version) {
        return Ok(status_from(current_version, &latest, false));
    }

    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == "RemoteCanvasHost-setup.exe")
        .or_else(|| {
            release
                .assets
                .iter()
                .find(|asset| asset.name.ends_with("-setup.exe") || asset.name.ends_with(".exe"))
        })
        .ok_or_else(|| "Latest release has no Windows installer".to_string())?;

    let client = github_client()?;
    let bytes = client
        .get(format!(
            "https://api.github.com/repos/{REPO}/releases/assets/{}",
            asset.id
        ))
        .header("Accept", "application/octet-stream")
        .send()
        .await
        .map_err(|error| error.to_string())?
        .error_for_status()
        .map_err(|error| map_github_error(error, "installer"))?
        .bytes()
        .await
        .map_err(|error| error.to_string())?;

    let installer = temp_dir().join("RemoteCanvas-update.exe");
    let mut file = fs::File::create(&installer).map_err(|error| error.to_string())?;
    file.write_all(&bytes).map_err(|error| error.to_string())?;
    drop(file);

    launch_installer_and_relaunch(&installer)?;
    Ok(status_from(current_version, &latest, true))
}

async fn fetch_latest() -> Result<GithubRelease, String> {
    github_client()?
        .get(format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| error.to_string())?
        .error_for_status()
        .map_err(|error| map_github_error(error, "release list"))?
        .json::<GithubRelease>()
        .await
        .map_err(|error| error.to_string())
}

fn github_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent("RemoteCanvas-Host")
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .map_err(|error| error.to_string())
}

fn status_from(current: &str, latest: &str, installing: bool) -> UpdateStatus {
    let latest = normalize_version(latest);
    let status = if installing {
        "installing"
    } else if version_tuple(&latest) > version_tuple(current) {
        "available"
    } else {
        "upToDate"
    };
    UpdateStatus {
        status,
        current_version: current.to_string(),
        latest_version: latest,
    }
}

fn normalize_version(version: &str) -> String {
    version.trim().trim_start_matches('v').to_string()
}

fn map_github_error(error: reqwest::Error, what: &str) -> String {
    if error.status() == Some(reqwest::StatusCode::NOT_FOUND) {
        format!("Could not find the {what}. The GitHub repository must be public.")
    } else {
        error.to_string()
    }
}

fn version_tuple(version: &str) -> (u64, u64, u64) {
    let mut parts = version.split('.');
    let major = parts.next().and_then(|part| part.parse().ok()).unwrap_or(0);
    let minor = parts.next().and_then(|part| part.parse().ok()).unwrap_or(0);
    let patch = parts.next().and_then(|part| part.parse().ok()).unwrap_or(0);
    (major, minor, patch)
}

fn temp_dir() -> PathBuf {
    std::env::temp_dir()
}

fn launch_installer_and_relaunch(installer: &std::path::Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;

        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let local_app = std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("RemoteCanvas Host");
        let current = std::env::current_exe().unwrap_or_else(|_| {
            local_app.join("RemoteCanvas Host.exe")
        });
        let script = temp_dir().join("RemoteCanvas-update.cmd");
        let contents = format!(
            "@echo off\r\n\
             timeout /t 3 /nobreak >nul\r\n\
             start /wait \"\" \"{installer}\" /S\r\n\
             if exist \"{current}\" (\r\n\
             start \"\" \"{current}\"\r\n\
             ) else if exist \"%LOCALAPPDATA%\\RemoteCanvas Host\\RemoteCanvas Host.exe\" (\r\n\
             start \"\" \"%LOCALAPPDATA%\\RemoteCanvas Host\\RemoteCanvas Host.exe\"\r\n\
             ) else if exist \"%LOCALAPPDATA%\\RemoteCanvas Host\\remote-canvas-host.exe\" (\r\n\
             start \"\" \"%LOCALAPPDATA%\\RemoteCanvas Host\\remote-canvas-host.exe\"\r\n\
             )\r\n\
             del \"%~f0\"\r\n",
            installer = installer.display(),
            current = current.display()
        );
        fs::write(&script, contents).map_err(|error| error.to_string())?;
        std::process::Command::new("cmd")
            .args(["/C", "call", &script.display().to_string()])
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
            .spawn()
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = installer;
        Err("Updates install on Windows only".into())
    }
}
