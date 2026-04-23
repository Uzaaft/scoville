# scoville

A Zig library that bridges VMware's guest-host clipboard with Wayland compositors.

## Problem

VMware's open-vm-tools clipboard integration (`vmtoolsd -n vmusr`) depends on X11. On Wayland-native NixOS guests, copy-paste between host and guest is broken or requires XWayland workarounds.

Scoville replaces the clipboard component of open-vm-tools with a native Wayland implementation, communicating directly with the VMware hypervisor through the backdoor I/O port and RPCI protocol.

## Architecture

```
┌─────────────┐       ┌───────────┐       ┌──────────────────┐
│ VMware Host  │◄─────►│  Scoville │◄─────►│ Wayland Compositor│
│  Clipboard   │ RPCI  │  (bridge) │  wl_  │  (sway, hyprland, │
│              │ 0x5658│           │ data  │   niri, etc.)     │
└─────────────┘       └───────────┘       └──────────────────┘
```

- **VMware backdoor** (port 0x5658): Low-level guest↔hypervisor communication
- **GuestRPC/RPCI**: Clipboard data exchange commands
- **Wayland protocols**: `wl_data_device_manager`, `wl_data_source`, `wl_data_offer`, `zwp_primary_selection`

## Building

```sh
nix develop     # enter dev shell
zig build       # build the library
zig build test  # run tests
zig build fmt   # format source
```

## NixOS Integration

The flake provides a NixOS module for VMware guest configuration:

```nix
{
  inputs.scoville.url = "github:polymath-as/scoville";

  outputs = { self, nixpkgs, scoville, ... }: {
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      modules = [
        scoville.nixosModules.default
        {
          services.scoville.enable = true;
        }
      ];
    };
  };
}
```

## License

TBD
