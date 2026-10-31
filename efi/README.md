# Boot program (`gpuunlock.efi`) – source and build

This directory is the complete corresponding source of `installer/payload/gpuunlock.efi`.

- `windows/` is a subset of [brandonjank/gpu-unlock-ada](https://github.com/brandonjank/gpu-unlock-ada) at commit `26cea8ede6735155c7333dc637db46166d6ede82`. It holds `build.py`, `THIRD_PARTY_NOTICES.md` and `uefi/`, with this project's changes already applied.
- `patches/generic-mode.patch` is the same changes as a diff against that commit (`git diff` of the upstream tree). It touches `windows/build.py`, `uefi/app.c`, `uefi/app_io.c`, `uefi/app_io.h` and `uefi/handoff.inc`, and adds `uefi/board_profile_generic.h`. The changes:
  - a `generic` build mode that enrolls the card at its first start (`PROFILE.TXT`) instead of compiling one board's identity into the binary;
  - a **chip table** in `app.c` (`Chips[]`): PCI id, BOOT0 chipset id, memory range and tier for each accepted card. The RTX 4090 is `verified`; the other cards (4080, 4080 SUPER, 4070 Ti SUPER in its AD103 version `2705` and its AD102 version `2689`, 4070 Ti, 4070 SUPER, 4070) are not;
  - a **trial flow** for every card that is not `verified` (or whose profile has `trial_required=1`): the first start only reads the card; an unlock needs `\GPU-UNLOCK\ARMED.TXT` (consumed *before* the attempt) or `\GPU-UNLOCK\AUTO.TXT` (written by the Windows installer after a verified trial);
  - profile version 2 (`pci_id`, `chip`, optional `trial_required`); version 1 files (4090 only) are still read;
  - an automatic mode (`GU_AUTO`) with no countdown, which continues to the next boot entry (Windows) when a check fails;
  - a ring of eight boot logs, `RUN00` to `RUN07`;
  - removal of the exact SS1 selector pin (only the "disabled" condition is required);
  - a refusal to run from a volume that contains `\EFI\Microsoft`;
  - enrollment removes a stale `AUTO.TXT`/`ARMED.TXT` before it writes a new profile, so trial state never carries over to a new profile, and it refuses an implausible PCI subsystem id (the same rule the profile reader applies);
  - after the display is handed back, the PCI command check ignores the I/O Space bit (bit 0), because a platform GOP driver may switch it on again; every other bit must still match and bus mastering must stay off (from pull request #6, reported on an RTX 4080);
  - `-ffile-prefix-map` in `build.py`, so the binary does not contain the build path.

## Build

Requirements: Linux or WSL, Python 3, and [Zig 0.15.2](https://ziglang.org/download/) (the build uses `zig cc` for the `x86_64-uefi` target).

```sh
cd efi
python3 windows/build.py generic --zig /path/to/zig-0.15.2/zig --output /tmp/gpuunlock-build
sha256sum /tmp/gpuunlock-build/EFI/BOOT/BOOTX64.EFI
```

The output `EFI/BOOT/BOOTX64.EFI` is the file the installer ships as `gpuunlock.efi`. `build-result.json` next to it records the compiler version and the SHA-256 of every source file.

## Reproducing the shipped binary byte for byte

The shipped `gpuunlock.efi` has SHA-256 `1bf857dfa34a660a0254d75004fb298b6d282d9fbab89e0cf035485258c9765a` (94720 bytes), built with Zig 0.15.2 from this tree. Because the build strips the source path (`-ffile-prefix-map`), the hash does not depend on where the tree sits. It was rebuilt from a fresh copy of this directory at two different paths on 2026-10-31 and matched both times.

(The previous 0.3.0 builds, `2d39b939…b04a` and before it `722d137d…3ac4`, differ only by the AD102 4070 Ti SUPER table entry and by the handoff change above. The earlier 0.2.0 binary, `5fa4ded5…ee69`, embedded the build path and could only be reproduced at one fixed location.)

If you use your own build, replace `installer/payload/gpuunlock.efi` and update `efi.size` and `efi.sha256` in `installer/payload/manifest.json`. The installer refuses an EFI file that does not match the manifest.

## License

GPL-2.0-only (`LICENSE`). Third-party notices are in `windows/THIRD_PARTY_NOTICES.md` and `windows/uefi/LICENSES/`.
