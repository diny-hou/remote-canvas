# RemoteCanvas

RemoteCanvas is an iPhone/iPad-first remote workspace for a paired Windows PC.
The product goal is not to shrink a desktop onto a phone, but to offer two
complementary views:

- **Mobile workspace** — touch-sized controls and a focused, single-app layout.
- **Desktop view** — the original Windows desktop with pan, zoom, and trackpad input.

This repository contains the first vertical prototype:

- `ios/` — a buildable SwiftUI application with pairing, device management, and
  an interactive mock remote session.
- `windows-host/` — a dependency-free C++ capture/service skeleton.
- `windows-app/` — the Tauri 2 Windows settings and pairing shell, with NSIS
  installer scripts and a Windows CI build.
- `shared/protocol/` — versioned wire-message examples shared by both clients.
- `docs/` — product requirements and architecture decisions.

## Build the iOS prototype

```sh
xcodebuild \
  -project ios/RemoteCanvas.xcodeproj \
  -scheme RemoteCanvas \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Open `ios/RemoteCanvas.xcodeproj` in Xcode to run it on an iPhone or iPad
Simulator. The bundled demo PC lets the complete prototype flow run without a
Windows machine.

## Build the host skeleton

```sh
cmake -S windows-host -B work/windows-host-build
cmake --build work/windows-host-build
work/windows-host-build/remote_canvas_host --demo
```

The current host validates configuration and exposes the intended capture,
transport, and device-registry seams. Desktop capture and WebRTC are the next
implementation milestone. If CMake is unavailable, the same skeleton can be
checked directly with a C++20 compiler:

```sh
clang++ -std=c++20 -Wall -Wextra -Wpedantic \
  -I windows-host/include \
  windows-host/src/main.cpp windows-host/src/host.cpp \
  -o remote_canvas_host
./remote_canvas_host --demo
```

See `windows-app/README.md` to create `RemoteCanvas Host_x64-setup.exe` on a
Windows 11 machine.
