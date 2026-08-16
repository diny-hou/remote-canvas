use serde::Deserialize;
use std::{fs, io::Write, path::PathBuf};

const REPO: &str = "diny-hou/remote-canvas";

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub status: &'static str,
    pub version: String,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    assets: Vec<GithubAsset>,
}

#[derive(Deserialize)]
struct GithubAsset {
    name: String,
    browser_download_url: String,
}

pub async fn install_latest(current_version: &str) -> Result<UpdateStatus, String> {
    let client = reqwest::Client::builder()
        .user_agent("RemoteCanvas-Host")
        .build()
        .map_err(|error| error.to_string())?;
    let release = client
        .get(format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| error.to_string())?
        .error_for_status()
        .map_err(|error| error.to_string())?
        .json::<GithubRelease>()
        .await
        .map_err(|error| error.to_string())?;

    let latest = release.tag_name.trim().trim_start_matches('v').to_string();
    if version_tuple(&latest) <= version_tuple(current_version) {
        return Ok(UpdateStatus {
            status: "upToDate",
            version: latest,
        });
    }

    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name.ends_with("-setup.exe") || asset.name.ends_with(".exe"))
        .ok_or_else(|| "Latest release has no Windows installer".to_string())?;

    let bytes = client
        .get(&asset.browser_download_url)
        .send()
        .await
        .map_err(|error| error.to_string())?
        .error_for_status()
        .map_err(|error| error.to_string())?
        .bytes()
        .await
        .map_err(|error| error.to_string())?;

    let installer = temp_dir().join("RemoteCanvas-update.exe");
    let mut file = fs::File::create(&installer).map_err(|error| error.to_string())?;
    file.write_all(&bytes).map_err(|error| error.to_string())?;
    drop(file);

    launch_installer_and_relaunch(&installer)?;
    Ok(UpdateStatus {
        status: "installing",
        version: latest,
    })
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
        let app = std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("RemoteCanvas Host")
            .join("RemoteCanvas Host.exe");
        let script = temp_dir().join("RemoteCanvas-update.cmd");
        let contents = format!(
            "@echo off\r\ntimeout /t 2 /nobreak >nul\r\nstart /wait \"\" \"{}\" /S\r\nstart \"\" \"{}\"\r\ndel \"%~f0\"\r\n",
            installer.display(),
            app.display()
        );
        fs::write(&script, contents).map_err(|error| error.to_string())?;
        std::process::Command::new("cmd")
            .args(["/C", &script.display().to_string()])
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
