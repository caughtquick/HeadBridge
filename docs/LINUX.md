# HeadBridge on Linux

HeadBridge on Linux brings native Bluetooth headphone control for Bowers & Wilkins RPC and Sony MDR V1 devices to Linux desktop systems without changing or breaking the macOS application.

---

## Architecture Overview

HeadBridge follows a clean layered architecture separating protocol codecs and provider state machines from platform-specific Bluetooth and audio subsystems.

```
┌─────────────────────────────────────────────────────────────┐
│                       Shared Core                           │
│  • BWRPC & MessagePack Encoders/Decoders                   │
│  • Sony MDR V1 Framing, Checksums & Packet State Machines   │
│  • Provider State, Capabilities & Restore Profiles          │
│  • PlatformAbstractions (Combine Shim, Paths, Interfaces)   │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
┌──────────────▼──────────────┐ ┌──────────────▼──────────────┐
│        macOS Layer          │ │         Linux Layer         │
│  • CoreBluetooth GATT       │ │  • BlueZ GATT & D-Bus       │
│  • IOBluetooth RFCOMM       │ │  • Linux RFCOMM Sockets     │
│  • Core Audio Output/Volume │ │  • PipeWire / pactl Audio   │
│  • SwiftUI Menu-Bar App     │ │  • HeadBridge Linux CLI     │
│  • Sparkle Auto-Updates     │ │  • XDG Config Persistence   │
└─────────────────────────────┘ └─────────────────────────────┘
```

### Shared / Core Layer
- Pure Swift implementation of Bowers & Wilkins RPC (`BWRPC.swift`, `BWRPCatalog.swift`, `MessagePack.swift`).
- Pure Swift framing and codecs for Sony MDR V1 (`SonyMDRFraming.swift`, `SonyMDRPacket.swift`, `SonyV1Client.swift`).
- Platform-neutral Combine compatibility shim providing `ObservableObject`, `@Published`, `ObservableObjectPublisher`, and `AnyPublisher` on non-Apple platforms.
- Fully isolated by dependency injection in `BowersWilkinsProvider` and `SonyMDRProvider`.

### Linux Implementation Layer
- **BlueZ GATT Transport (`LinuxBowersWilkinsTransport.swift`)**:
  - Interacts with BlueZ via system D-Bus (`busctl`).
  - Resolves Bowers & Wilkins RPC characteristics:
    - Request: `ada50ce9-67b8-4a97-9d8e-37e1d083156c`
    - Response: `cb909093-3559-4b0c-9a7f-3f1773122fdc`
    - Notification: `df55d475-9a32-457a-9e20-38cf14e853fb`
  - Subscribes to real-time notification streams via D-Bus properties change monitoring.
- **Linux RFCOMM Transport (`LinuxSonyRFCOMMTransport.swift`)**:
  - Native Linux Bluetooth RFCOMM sockets using `AF_BLUETOOTH` (family 31) and `BTPROTO_RFCOMM` (protocol 3).
  - Non-blocking I/O with `DispatchSourceRead` and generation-based disconnect tracking.
- **PipeWire Audio Integration (`LinuxPipeWireAudio.swift`)**:
  - Discovers audio sinks, default output routes, and real-time volume using PipeWire and PulseAudio interfaces (`pactl` / `wpctl`).
  - Listens for audio route transitions and sink events via `pactl subscribe`.
- **XDG Configuration & Profiles (`LinuxSettings.swift`)**:
  - Complies with XDG Base Directory Specifications:
    - Settings & profiles: `$XDG_CONFIG_HOME/headbridge/settings.json` (defaults to `~/.config/headbridge/settings.json`).
    - Device data: `$XDG_DATA_HOME/headbridge/` (defaults to `~/.local/share/headbridge/`).
    - Runtime files: `$XDG_RUNTIME_DIR/headbridge/`.

---

## Requirements

- **Linux Kernel**: 5.10 or newer with Bluetooth enabled.
- **Bluetooth Subsystem**: BlueZ 5.50 or newer with `bluetooth.service` running.
- **Audio Subsystem**: PipeWire with WirePlumber or PulseAudio compatibility layer (`pactl`).
- **Swift**: Swift 6.0+ toolchain (required for building from source).

---

## Building & Installation

### Quick Install (One-Liner)
Run the automated installation script, which compiles the release binary, installs it to `~/.local/bin/headbridge`, and enables the user systemd service:

```bash
./Scripts/install-linux.sh
```

### Manual Installation

1. **Build release binary:**
   ```bash
   swift build -c release
   ```

2. **Install to user PATH:**
   ```bash
   mkdir -p ~/.local/bin
   install -m 755 .build/release/headbridge ~/.local/bin/headbridge
   ```
   *(Or system-wide: `sudo install -m 755 .build/release/headbridge /usr/local/bin/headbridge`)*

3. **Enable systemd user daemon (recommended):**
   ```bash
   mkdir -p ~/.config/systemd/user
   cat > ~/.config/systemd/user/headbridge.service <<EOF
   [Unit]
   Description=HeadBridge Bluetooth Headphone Daemon
   After=bluetooth.target pipewire.service wireplumber.service

   [Service]
   ExecStart=%h/.local/bin/headbridge daemon
   Restart=on-failure
   RestartSec=3

   [Install]
   WantedBy=default.target
   EOF

   systemctl --user daemon-reload
   systemctl --user enable --now headbridge.service
   ```

---

## Command Line Interface (`headbridge`)

The Linux CLI provides complete control over supported headphones, status reporting, and scriptable JSON output:

```
USAGE:
    headbridge [COMMAND] [OPTIONS]

COMMANDS:
    status                      Show status of connected headphone (default)
    devices                     List paired Bowers & Wilkins and Sony devices
    connect [address|name]      Connect to headphone
    disconnect                  Disconnect active headphone session
    anc [off|anc|ambient]       Get or set Active Noise Cancellation mode
    ambient-level [0-20]        Get or set Sony ambient sound level
    eq [bass <n>] [treble <n>]  Get or set tone / EQ controls (-60 to +60)
    volume [get|set <0-100>]    Get or set audio output volume
    battery                     Show battery percentage and charging status
    restore [status|on|off]     Configure restore-on-connect profile
    monitor, daemon             Run persistent daemon monitoring connections
    diag                        Print system and diagnostic state
    help                        Show this help message

OPTIONS:
    --json                      Format output as JSON
```

### Examples

#### Status Overview
```bash
headbridge status
```
Output:
```text
=== HeadBridge Status ===
Device:        Abhijit’s Px7 S2e
Vendor:        Bowers & Wilkins
State:         Connected
Battery:       85%
ANC Mode:      Noise Cancellation
Tone / EQ:     Bass: 0, Treble: 0
Audio Output:  Abhijit’s Px7 S2e (Volume: 80%)
```

#### JSON Output (For Waybar / Polybar / Scripts)
```bash
headbridge status --json
```
Output:
```json
{
  "audioSink": "bluez_output.EC_66_D1_BE_1D_80.1",
  "batteryPercent": 85,
  "connected": true,
  "connectionState": "Connected",
  "deviceName": "Abhijit’s Px7 S2e",
  "isCharging": false,
  "noiseMode": 1,
  "providerID": "bowers-wilkins",
  "vendor": "Bowers & Wilkins",
  "volume": 0.8
}
```

#### Switch Active Noise Cancellation
```bash
headbridge anc anc        # Enable noise cancellation
headbridge anc ambient    # Enable pass-through / ambient
headbridge anc off        # Disable ANC
```

#### Adjust Equalizer / Tone
```bash
headbridge eq bass 10 treble -5
```

---

## Waybar Integration

Add a custom module to your Waybar configuration (`~/.config/waybar/config`):

```json
"custom/headbridge": {
    "format": "🎧 {text}",
    "return-type": "json",
    "exec": "headbridge status --json",
    "interval": 10,
    "on-click": "headbridge anc",
    "tooltip": true
}
```

---

## Systemd User Service

To run HeadBridge daemon in the background to automatically sync volume and restore settings on connect:

Create `~/.config/systemd/user/headbridge.service`:

```ini
[Unit]
Description=HeadBridge Bluetooth Headphone Daemon
After=bluetooth.target pipewire.service wireplumber.service

[Service]
ExecStart=%h/.local/bin/headbridge daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

Enable and start the service:
```bash
systemctl --user daemon-reload
systemctl --user enable --now headbridge.service
```

---

## Containerized & Development Environments (Distrobox / Toolbox)

When developing or running inside a containerized environment (e.g. Distrobox or Toolbox on Fedora Silverblue / Atomic desktops):
- The released application uses standard Linux system binaries (`busctl`, `bluetoothctl`, `pactl`, `wpctl`) and system sockets.
- The command runner automatically searches your PATH and only falls back to `distrobox-host-exec` during containerized development when host tools are not directly installed in the container image.
- Build, formatting, and unit tests execute container-locally.
