# Architecture

## Components

1. **RemoteCanvas iOS client**
   - SwiftUI application shell and adaptive interaction layer.
   - Metal/VideoToolbox renderer in the production implementation.
   - Secure device identity, pairing UX, and session control.
2. **RemoteCanvas Windows host**
   - Tauri 2 user-facing configuration and pairing shell.
   - Native Rust/C++ capture process plus a least-privilege background service.
   - DXGI Desktop Duplication capture and Media Foundation encoding.
   - UI Automation semantic adapter and `SendInput` input adapter.
3. **Connection plane**
   - WebRTC ICE/STUN for direct connectivity.
   - Authenticated signaling for offers and candidates.
   - Optional TURN fallback; media remains end-to-end encrypted.

## Trust model

Pairing is the trust root. Each endpoint creates a device identity and pins the
other endpoint's public identity. Every session authenticates a transcript that
includes the protocol version, both device IDs, both ephemeral session values,
and the transport fingerprint. This prevents a signaling service from replacing
transport identities.

The prototype deliberately keeps transport behind a service boundary. Mock
frames and state can be replaced without moving session rules into SwiftUI.

## Adaptive display pipeline

The mobile workspace combines three sources in priority order:

1. UI Automation elements converted into native touch-sized controls.
2. Window metadata used to focus and arrange a single application.
3. Encoded pixels for custom-drawn or otherwise uninterpretable content.

The desktop view always remains available, ensuring compatibility when semantic
metadata is incomplete.

## Why Tauri is only the Windows shell

Tauri is appropriate for host settings, pairing, device revocation, diagnostics,
and installer generation. Desktop capture, input injection, device-key access,
and service lifecycle must stay in native Rust/C++ components. Keeping these
privileged operations outside the webview makes the security boundary smaller
and permits the capture service to run even when the settings window is closed.
