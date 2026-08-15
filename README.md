# RemoteCanvas

RemoteCanvas is an iPhone/iPad-first remote client for a Windows PC. Version
0.3 is a working MVP: the Windows host captures its primary display, streams
JPEG frames to iOS, accepts pointer/text/scroll input, and exposes selected user
folders through an authenticated file API.

## What works in 0.3

- Live Windows screen viewing on iPhone and iPad.
- Tap, pointer movement, right-click, scrolling, and text entry.
- Native iOS browsing of Desktop, Documents, Downloads, Pictures, and Videos.
- Download and Quick Look preview of supported images, videos, audio, PDFs, and
  documents.
- Upload from the iOS Files picker without overwriting an existing file.
- 192-bit random host access key, Bearer authentication, iOS Keychain storage,
  and Face ID/Touch ID/device-passcode approval before connection.
- QR pairing or a five-minute, six-digit one-time code. The 192-bit key is never
  shown or typed by the user.
- Remote access through Tailscale. RemoteCanvas itself needs no hosted server;
  Tailscale normally connects peers directly with WireGuard and may use its own
  encrypted relay when direct NAT traversal is impossible.

## Connect a Windows PC

1. Install Tailscale on Windows and iPhone/iPad and sign both into the same
   tailnet.
2. Install and open **RemoteCanvas Host** on Windows. Allow its Windows Firewall
   prompt for the network profiles you intend to use.
3. Select **端末を追加**. When Tailscale is running, RemoteCanvas prefers its
   `100.64.0.0/10` address.
4. On iPhone/iPad, choose **PCを追加** and scan the QR code. Manual setup uses
   the displayed endpoint and six-digit code; the code expires after five
   minutes and locks after five failed attempts.
5. Approve Face ID/Touch ID/device passcode, then connect.

An `http://100.x.x.x:47831` endpoint is still encrypted by the surrounding
Tailscale WireGuard tunnel. A normal LAN `http://192.168.x.x:47831` endpoint is
not transport-encrypted by RemoteCanvas and should only be used on a trusted
private network.

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
