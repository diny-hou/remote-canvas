# RemoteCanvas Host for Windows

This is the Tauri 2 shell for pairing, security status, and host configuration.
The privileged desktop-capture and input services will remain native Rust/C++
components and be called from Tauri commands; they must not run inside the web
view.

## Build an installer on Windows 11

Open PowerShell in this directory and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\bootstrap-windows.ps1
```

Restart PowerShell after the prerequisite installer completes, then run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-installer.ps1
```

The installer is written to:

```text
src-tauri\target\release\bundle\nsis\RemoteCanvas Host_0.1.0_x64-setup.exe
```

The installed application is per-user and does not require administrator
privileges. Building prerequisites may request administrator privileges because
Microsoft C++ Build Tools are installed system-wide.

For the shortest build-and-install flow, run the following script as the current
Windows user. The first run installs prerequisites and may ask for elevation. If
it asks for a PowerShell restart, run the same command again afterwards.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-on-this-pc.ps1
```

## Current boundary

The UI, Tauri command bridge, pairing-code generation, installer configuration,
and Windows build automation are implemented. DXGI capture, input injection,
WebRTC, device-key storage, and the background Windows service are not yet wired;
the app clearly reports that state instead of presenting mock security as live.
