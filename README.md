# RemoteCanvas

RemoteCanvas is an iPhone/iPad-first remote client for a Windows PC. Version
0.4 is a working MVP: the Windows host captures its primary display, streams
JPEG frames to iOS, accepts pointer/text/scroll input, and exposes selected user
folders through an authenticated file API.

## What works in 0.3

- Live Windows screen viewing on iPhone and iPad.
- Tap, pointer movement, right-click, scrolling, and text entry.
- Native iOS browsing of Desktop, Documents, Downloads, Pictures, and Videos.
- Download and Quick Look preview of supported images, videos, audio, PDFs, and
  documents.
- Upload from the iOS Files picker without overwriting an existing file.
- TLS with a host certificate pinned during pairing, per-device keys, DPAPI
  storage on Windows, replay-protected requests, and Face ID before connect.
- QR pairing or a five-minute, six-digit one-time code. Device keys are never
  shown or typed by the user.
- At home the iPhone uses the LAN first for lower latency and a higher frame
  rate. Away from home it falls back to Tailscale. RemoteCanvas itself needs no
  hosted server.

## Connect a Windows PC

1. Install Tailscale on Windows and iPhone/iPad and sign both into the same
   tailnet.
2. Install and open **RemoteCanvas Host** on Windows. Allow its Windows Firewall
   prompt for the network profiles you intend to use.
3. Select **Add device**. When Tailscale is running, RemoteCanvas prefers its
   `100.64.0.0/10` address.
4. On iPhone/iPad, tap **+** and scan the QR code. Manual setup uses
   the displayed endpoint and six-digit code; the code expires after five
   minutes and locks after five failed attempts.
5. Approve Face ID/Touch ID/device passcode, then connect.

Both LAN and Tailscale endpoints are `https://…:47831`. After **Rotate keys**
on Windows, phones must pair again.

## Build iOS

```sh
xcodebuild \
  -project ios/RemoteCanvas.xcodeproj \
  -scheme RemoteCanvas \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Open `ios/RemoteCanvas.xcodeproj` in Xcode for a signed physical-device build.

## Build Windows

See `windows-app/README.md`. GitHub Actions also produces the NSIS installer
artifact through `.github/workflows/build-windows.yml`.

## Current limitations

This is not yet a production substitute for Splashtop or Windows App. The
screen stream is approximately 8 JPEG frames per second, carries no audio, and
supports only the primary monitor. UAC/secure-desktop interaction, clipboard,
per-client key revocation, H.264/HEVC, and semantic reconstruction
of arbitrary Windows application UI remain future work. The phone-friendly
file browser is native today; arbitrary app UIs are still operated through the
pixel stream.
