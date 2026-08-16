# RemoteCanvas Host for Windows

The Tauri 2 host now runs the native Rust remote service as well as the pairing
and status UI.

## Runtime behavior

- Listens on HTTPS port `47831` on all interfaces.
- Advertises the LAN address first and Tailscale when it is present.
- Persists the TLS key and per-device tokens in a DPAPI-protected
  `%APPDATA%\RemoteCanvas\host-state.bin`.
- Exchanges a five-minute, six-digit pairing code for a device-specific key;
  the code is single-use and locks after five failed attempts.
- Streams the primary display as JPEG over an authenticated WebSocket. LAN
  clients get a higher frame rate than Tailscale clients.
- **Update** downloads the latest GitHub release installer and applies it
  silently. **Rotate keys** revokes every phone and replaces the certificate.
- Accepts pointer, click, scroll, and Unicode text input.
- Allows authenticated file access only below the current user's Desktop,
  Documents, Downloads, Pictures, and Videos directories.
- Refuses uploads that would overwrite an existing file and limits request
  bodies to 512 MiB.

The process must remain running while a remote session is active. Windows may
show a Firewall prompt the first time; only enable profiles you trust.

## Build an installer on Windows 11

Open PowerShell in this directory and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\bootstrap-windows.ps1
```

Restart PowerShell if requested, then run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-installer.ps1
```

The installer is written to:

```text
src-tauri\target\release\bundle\nsis\RemoteCanvas Host_0.4.1_x64-setup.exe
```

For a combined build/install attempt, use:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-on-this-pc.ps1
```

## Network security

At home, keep both devices on the same Wi-Fi. RemoteCanvas prefers that LAN
path automatically. For internet access, install Tailscale on both endpoints.
TLS and certificate pinning cover the LAN path; Tailscale still adds its own
WireGuard tunnel when you are away.

## MVP limitations

Capture is JPEG at roughly 8 fps rather than hardware-encoded video. The host
does not yet run as a Windows service and cannot control UAC/secure desktop.
Audio, clipboard, multi-monitor selection, per-device credential rotation,
and device revocation are not yet implemented.
