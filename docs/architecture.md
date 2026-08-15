# Architecture

## Implemented 0.2 data path

```text
iPhone / iPad                       Windows PC
-----------------                   ------------------------
SwiftUI live canvas  <--- JPEG ---- Axum WebSocket :47831
touch/text/scroll    ---- JSON ---> screenshots + enigo
native file browser <--- HTTP ----> allowlisted user folders
Keychain + Face ID                  192-bit persisted key
          \________ Tailscale WireGuard tunnel ________/
```

The Windows UI is Tauri, but capture and input run in Rust rather than the web
view. Every WebSocket and file request requires the same high-entropy key. The
key travels in an Authorization header, not the URL. iOS stores paired records
in a ThisDeviceOnly Keychain item and requests owner authentication before a
session opens.

Tailscale supplies authenticated device membership, NAT traversal, and
transport encryption. RemoteCanvas itself has no hosted control or data plane.
Tailscale can use its encrypted DERP infrastructure when peers cannot establish
a direct path, so the connection is not guaranteed to be physically P2P in all
network conditions.

## Adaptive presentation

The native iOS file browser is the first semantic mobile view: folders and
files become touch-sized rows, and media opens through Quick Look. The general
Windows application surface currently remains a scaled pixel stream with
phone-sized controls for input, right-click, scrolling, and switching display
mode.

Future semantic reconstruction would add a Windows UI Automation channel and
map known controls into native SwiftUI components. It must always retain the
pixel-stream fallback because games, canvases, video, and custom-rendered apps
cannot be reliably reconstructed.

## Next production architecture

- Replace JPEG frames with hardware H.264/HEVC and adaptive bitrate.
- Give every client its own public/private identity and revocation record.
- Use a short-lived pairing ceremony instead of revealing the persistent host
  key.
- Add replay-resistant session handshakes and key rotation.
- Run capture in a least-privilege Windows service with explicit consent and
  auditable session events.
- Add UI Automation metadata, clipboard policy, audio, and multi-monitor
  selection as independently permissioned channels.
