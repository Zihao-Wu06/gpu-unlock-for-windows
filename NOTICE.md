# Notices

This project is licensed under **GPL-2.0-only** (see `LICENSE`). It is not affiliated with or endorsed by NVIDIA.

## Code this project derives from

| Part | Origin | License |
|---|---|---|
| `efi/windows/` (UEFI program and its build script) | [brandonjank/gpu-unlock-ada](https://github.com/brandonjank/gpu-unlock-ada), commit `26cea8ede6735155c7333dc637db46166d6ede82`, with this project's changes in `efi/patches/generic-mode.patch` | GPL-2.0-only |
| Upstream of the above | [TOTORONG/AD103_win_unlocker](https://huggingface.co/TOTORONG/AD103_win_unlocker), revision `51df9c17ec89eb8486df52cc9079dde4bd1f9974` | GPL-2.0-only |
| `efi/windows/uefi/vendor/` (the firmware transaction) | [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock), revision `0ebdb1c6308b6a2072be5bf04513472942541956`, as adapted by the projects above | see `efi/windows/THIRD_PARTY_NOTICES.md` |
| `efi/windows/uefi/edk2/` (declaration headers only; no EDK2 binaries are linked) | TianoCore EDK2, revision `c1415771ac592ad8509351c46cd3cda4f38d7d52` | BSD-2-Clause-Patent |
| Preserved notices | `efi/windows/uefi/LICENSES/` (EDK2, NVIDIA MIT, NVIDIA driver, CMP 40HX MIT) | as stated in each file |
| `installer/payload/tools/firmware/` and `installer/payload/tools/windows/prepare_assets.py` (local firmware extraction and generation) | brandonjank/gpu-unlock-ada `firmware/` and `windows/prepare_assets.py`, same commit, unmodified | GPL-2.0-only; provenance in `installer/payload/tools/firmware/NOTICE.md` |
| `installer/` scripts, `tools/`, docs | this project | GPL-2.0-only |

Full provenance of the UEFI code is in `efi/windows/THIRD_PARTY_NOTICES.md`. Per-file copyright headers are preserved.

## What is downloaded at install time and never distributed here

The installer downloads these files on the user's PC, checks each against the SHA-256 pinned in `installer/payload/manifest.json`, and unpacks them locally into `C:\ProgramData\GPU-Unlock\`. None of them, and nothing generated from them, is part of this repository or its releases.

| File | Source | Terms |
|---|---|---|
| `NVIDIA-kernel-module-source-610.43.03.tar.xz` | download.nvidia.com | NVIDIA open GPU kernel modules (MIT / GPL-2.0 dual license) |
| `nvidia-utils-610.43.03-1-x86_64.pkg.tar.zst` | archive.archlinux.org (repackaged NVIDIA Linux driver) | NVIDIA driver license; contains the GSP firmware |
| `python-3.14.0-embed-amd64.zip` | python.org | PSF License; only used to run the extraction scripts |

The generated firmware files (`booter_load_ad102.bin`, `v67-ad102-610.43.03-four-plm.bin`, `gsp_ga10x.bin`, `gsp_boot_ad102.bin`, `gsp_boot_desc_ad102.bin`) and any ROM, PROM or capture dumps of a user's card must not be committed. `.gitignore` excludes them.

## Trademarks

NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation. They are used only to identify compatible hardware.
