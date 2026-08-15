# RemoteCanvas Host for Windows

The Tauri 2 host now runs the native Rust remote service as well as the pairing
and status UI.

## Runtime behavior

- Listens on TCP port `47831` on all interfaces.
- Prefers an active Tailscale IPv4 address for the endpoint shown in the UI.
- Persists a random 192-bit key in
  `%APPDATA%\RemoteCanvas\access-token.txt`.
- Streams the primary display as JPEG over an authenticated WebSocket.
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
src-tauri\target\release\bundle\nsis\RemoteCanvas Host_0.2.0_x64-setup.exe
```

For a combined build/install attempt, use:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-on-this-pc.ps1
```

## Network security

For internet access, install Tailscale on both endpoints and keep RemoteCanvas
behind that WireGuard network. RemoteCanvas does not operate a signaling,
media, or file server. Plain LAN HTTP/WebSocket is provided for development and
trusted private networks only; it is not safe on an untrusted Wi-Fi network.

## MVP limitations

Capture is JPEG at roughly 8 fps rather than hardware-encoded video. The host
does not yet run as a Windows service and cannot control UAC/secure desktop.
Audio, clipboard, multi-monitor selection, QR pairing, per-device credentials,
and device revocation are not yet implemented.
