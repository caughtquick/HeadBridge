# HeadBridge

<p align="center">
  <img src="assets/branding/headbridge-icon.png" width="128" alt="HeadBridge app icon">
</p>

HeadBridge is a dedicated Bluetooth headphone controller and background daemon for Linux. It provides CLI controls, Waybar/Polybar JSON integration, and PipeWire volume synchronization with independently implemented providers for Bowers & Wilkins RPC devices and Sony MDR V1 headphones.

[![CI](https://github.com/herenickname/HeadBridge/actions/workflows/ci.yml/badge.svg)](https://github.com/herenickname/HeadBridge/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/herenickname/HeadBridge?display_name=tag)](https://github.com/herenickname/HeadBridge/releases/latest)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Features

- **CLI Controls**: Instant noise cancellation toggling (ANC, Ambient/Pass-Through, Off), ambient sound level, equalizer adjustments, and connection management.
- **Waybar / Polybar Integration**: Fast `--json` status output reporting battery percentage, active codec, connection state, and listening mode.
- **Background Daemon (`headbridge daemon`)**: Lightweight IPC daemon maintaining persistent connection monitoring, automatic reconnects, and two-way volume synchronization with PipeWire/WirePlumber.
- **Pluggable Architecture**: Modular `HeadphoneProvider` and transport protocol design allowing device family support to be added or removed cleanly without touching core application logic.

## Install

Run the Linux installation script, which compiles the release binary and symlinks both the executable (`~/.local/bin/headbridge`) and user systemd service (`~/.config/systemd/user/headbridge.service`) directly from this repository:

```shell
./Scripts/install-linux.sh
```

To uninstall cleanly at any time:

```shell
./Scripts/uninstall-linux.sh
```

## CLI Quick Reference

```shell
headbridge status                      # Show status of connected headphones
headbridge status --json               # JSON output for Waybar, Polybar, or scripts
headbridge devices                     # List recognized paired Bluetooth devices
headbridge connect [address|name]      # Connect to headphones
headbridge disconnect                  # Disconnect active session
headbridge anc [off|anc|ambient]       # Get or set Active Noise Cancellation mode
headbridge ambient-level [0-20]        # Get or set Sony ambient level
headbridge eq [bass <n>] [treble <n>]  # Get or set EQ tone controls (-60 to +60)
headbridge battery                     # Show battery percentage and charging state
headbridge daemon [start|status|stop]  # Manage background connection daemon
```

For complete documentation including desktop status bar integrations, see [`docs/LINUX.md`](docs/LINUX.md).

## Compatibility

| Provider family | Hardware validation | Status |
| --- | --- | --- |
| Apple Accessory Protocol (AAP) | AirPods Pro (1st & 2nd gen), AirPods Max, AirPods (1st-4th gen) | Full support (ANC, Adaptive, Transparency, Case & Pod battery, Ear detection) |
| Apple Accessory Protocol (AAP) | Beats Fit Pro, Studio Pro, Studio Buds+, Solo 4 | Full support (ANC, Transparency, Battery) |
| Bowers & Wilkins RPC | Px7 S3, firmware `3.17.4.17` | Validated |
| Bowers & Wilkins RPC | Original Px8, RPC software `0(20.0.2.0)` | Validated on hardware |
| Bowers & Wilkins RPC | Px7 S2 / Px7 S2e | Validated on hardware |
| Sony MDR V1 | WH-1000XM3 | Validated on hardware |
| Other Sony MDR V1 models | WH-1000XM4, etc. | Experimental common controls |
| Sony MDR V2 / Link2 | Service generation detected | Not supported yet |

## Architecture: Adding or Removing Device Support

HeadBridge decouples device-specific wire protocols, transports, and application routing:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        headbridge CLI / Daemon                         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                            HeadphoneManager                            │
└───────────┬───────────────────────┬────────────────────────┬───────────┘
            │                       │                        │
┌───────────▼────────────┐ ┌────────▼───────────┐ ┌──────────▼───────────┐
│  BowersWilkinsProvider │ │  SonyMDRProvider   │ │AppleAccessoryProvider│
└───────────┬────────────┘ └────────┬───────────┘ └──────────┬───────────┘
            │                       │                        │
┌───────────▼────────────┐ ┌────────▼───────────┐ ┌──────────▼───────────┐
│ LinuxBWRPC (BlueZ GATT)│ │LinuxSony (RFCOMM)  │ │ LinuxAAP (L2CAP 4097)│
└────────────────────────┘ └────────────────────┘ └──────────────────────┘
```

Every headphone family conforms to `HeadphoneProvider` in `Sources/HeadBridge/Core/HeadphoneProvider.swift`:
1. **Device Matching**: `recognizesBluetoothDevice(named:)` and `matches(audioDevice:)`.
2. **Transport Ownership**: Owns exactly one platform transport session (e.g. `LinuxAppleAccessoryTransport`, `LinuxBowersWilkinsTransport`, `LinuxSonyRFCOMMTransport`).
3. **Capability Advertising**: Runtime `HeadphoneCapabilities` (`.battery`, `.noiseControl`, `.equalizer`, `.wearSensor`, `.spatialAudio`).
4. **State Dispatching**: Publishes connection, battery, codec, and noise mode state.

To add or remove a device provider:
- Implement or remove the vendor wire protocol and transport.
- Implement or remove the `HeadphoneProvider` conformance.
- Register or unregister the provider instance in `HeadphoneManager` in `LinuxApp.swift`.

## Third-Party Notices & Attribution

HeadBridge adapts Apple Accessory Protocol (AAP) framing and model capability mappings from [podctl](https://github.com/Rockykln/podctl) under the MIT License (Copyright (c) 2026 pods contributors). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for full notices and license texts.

## License

HeadBridge is available under the [MIT License](LICENSE).
