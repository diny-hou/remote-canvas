# RemoteCanvas requirements

Status: working MVP 0.2

## Implemented

- iOS/iPadOS 17+ client and Windows 11 host.
- One active client viewing the primary Windows display.
- Pointer movement, primary/secondary click, scroll, and text input.
- Native iOS file browsing, download/preview, and non-overwriting upload for
  five allowlisted Windows user folders.
- Tailscale-first remote connectivity without a RemoteCanvas-operated server.
- Random 192-bit access key, Authorization-header authentication, ThisDeviceOnly
  Keychain storage, and owner authentication before connection.
- Responsive compact and regular-width layouts.

## Required before production use

- Per-device asymmetric identity, one-time pairing, revocation, key rotation,
  replay protection, and a security audit.
- Hardware video encoding, adaptive bitrate, congestion control, and reconnect.
- Explicit Windows session consent and local security event logging.
- Background-service lifecycle, code signing, automatic updates, and recovery.
- Automated protocol, authorization, file-boundary, and end-to-end tests.

## Deferred product features

- Audio, clipboard, multi-monitor, UAC/secure desktop, gaming optimization.
- QR pairing and automatic endpoint discovery.
- UI Automation-based semantic reconstruction of supported apps.
- App Store/TestFlight distribution and Windows installer signing.
