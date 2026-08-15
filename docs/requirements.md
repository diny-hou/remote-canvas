# RemoteCanvas product requirements

Status: initial implementation baseline

## Product promise

RemoteCanvas lets an owner securely operate a registered Windows PC from an
iPhone or iPad. A phone-first workspace is the default; an exact desktop view is
always available as a fallback.

## Version 1 scope

### Supported platforms

- iOS and iPadOS 17 or later.
- Windows 11 host. Windows 10 compatibility is not guaranteed in version 1.
- One active iOS/iPadOS client per Windows host.

### Pairing and trust

- Pairing starts locally with a single-use QR or human-readable code.
- Both devices retain pinned, device-specific public identities.
- The Windows host accepts session requests only from its local allowlist.
- The iOS private identity must be non-exportable and gated by device-owner
  authentication in the production transport.
- Revocation is possible locally from the Windows host and from the paired
  device list.

### Session behavior

- Direct peer-to-peer transport is preferred.
- Signaling carries connection metadata only; it never receives screen content
  or session plaintext.
- An encrypted relay is an explicit fallback when direct NAT traversal fails.
- Video adapts up to 1080p at 30 fps for the initial release.
- Touch, pointer, scrolling, text entry, and common modifier keys are supported.
- Clipboard, audio, file transfer, multi-monitor, UAC/secure desktop, and gaming
  optimization are deferred.

### Adaptive display

- Mobile workspace is the default on compact-width devices.
- Desktop view preserves original pixels and supports pan/zoom.
- The mobile workspace presents one task at a time, touch-sized targets, and a
  compact app switcher.
- UI Automation-based semantic reconstruction is progressive enhancement. If a
  target app cannot be interpreted, the client falls back to the video surface.
- iPad uses the same session with additional space for device/app navigation and
  pointer-oriented controls.

## Security invariants

- No password-only remote access.
- No SMS recovery path.
- Session setup is mutually authenticated against the identities pinned during
  pairing.
- A signaling or relay compromise must not expose screen or input plaintext.
- Clipboard and future file-transfer capabilities remain disabled by default.
- Security-relevant events are recorded locally on the host without recording
  screen contents or typed text.

## Open product decisions

- Unattended access versus local approval for each session.
- Public App Store distribution versus private/TestFlight use.
- Whether a managed relay is acceptable when direct P2P is impossible.
- Priority Windows applications for semantic mobile reconstruction.
