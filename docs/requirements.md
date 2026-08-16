# RemoteCanvas requirements

Status: working MVP 0.4

## Implemented

- iOS/iPadOS 17+ client and Windows 11 host.
- One active client viewing the primary Windows display.
- Pointer movement, primary/secondary click, scroll, and text input.
- Native iOS file browsing, download/preview, and non-overwriting upload for
  five allowlisted Windows user folders.
- Tailscale-first remote connectivity without a RemoteCanvas-operated server.
- TLS with certificate pinning, per-device keys, DPAPI host storage, replay
  protection, session logs, LAN-first routing, and owner authentication before
  connection.
- Responsive compact and regular-width layouts.
- QR pairing and a five-minute, six-digit fallback code with attempt limiting.
- In-app update links and tagged private GitHub releases for Windows installers.

## Required before production use

- Per-device asymmetric identity, one-time pairing, revocation, key rotation,
  replay protection, and a security audit.
- Hardware video encoding, adaptive bitrate, congestion control, and reconnect.
- Explicit Windows session consent and local security event logging.
- Background-service lifecycle, production code signing, unattended updates,
  and recovery.
- Automated protocol, authorization, file-boundary, and end-to-end tests.

## Deferred product features

- Audio, clipboard, multi-monitor, UAC/secure desktop, gaming optimization.
- Automatic endpoint discovery without scanning.
- UI Automation-based semantic reconstruction of supported apps.
- App Store/TestFlight distribution and Windows installer signing.
