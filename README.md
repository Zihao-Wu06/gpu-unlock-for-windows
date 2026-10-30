# GPU Unlock for GeForce RTX 40 on Windows

[中文说明](README.zh-CN.md)

A one-click Windows installer that turns on the full-rate **FP32-accumulate tensor-core path** of GeForce RTX 40-series cards at every start, before Windows loads the NVIDIA driver. It comes with a small GUI and an on/off switch.

> **Experimental. Only the RTX 4090 has been tested.** The other RTX 40-series cards are supported but untested (see [Supported cards](#supported-cards)). At every start it changes the firmware boot order and writes GPU registers. Read [Risks](#risks) first. Use at your own risk.

![Main window](docs/images/main-en.png)

## What you get

Matrix-math throughput on the one card tested (**RTX 4090** 24 GB, 450 W limit, PyTorch, single runs). Other cards have not been measured:

| Test | Locked (TFLOPS) | Unlocked | Change |
|---|---|---|---|
| TF32 4096³ | 83.7 | ≈130 | **+55 %** (about 2× per clock) |
| FP16, FP32 accumulate, 4096³ | 159.3 | ≈214 | **+35 %** |
| FP16, FP32 accumulate, 8192³ | 152.9 | ≈168 | +10 % |
| BF16, FP32 accumulate, 8192³ | 156.5 | ≈178 | +14 % |
| FP16 with FP16 accumulate, FP32 CUDA cores | — | — | no change |

- Numeric results are bit-identical before and after.
- The card stays at its power limit, so clocks drop and you do not get the theoretical 2×.
- Games, DLSS, ray tracing, INT8 and token-by-token LLM decoding do not benefit. Real applications (training, ComfyUI, LLM prefill) have not been measured.

## How it works

1. **Install.** The installer creates a hidden 300 MiB FAT32 partition with no drive letter, or uses a FAT32 USB drive you choose. It copies a small UEFI program there and adds a firmware boot entry, `GPU Unlock (auto)`, ahead of Windows.
2. **Firmware.** The NVIDIA firmware inputs (about 330 MB) are **downloaded and unpacked on your own PC**, with every file checked against a pinned SHA-256. This repository contains no NVIDIA firmware.
3. **Every start.** The UEFI program checks that this is the expected card in a cold state. It then lets the card's signed firmware apply the setting, resets the card, hands the display back and starts Windows. The screen goes black briefly. If a check fails *before* the card's display driver is released, nothing is written and Windows starts normally. If one fails *after* that point, the program stops and asks you to power off (see [Risks](#risks)).
4. **First start.** The program reads the card's identity read-only and saves it as `PROFILE.TXT`. On the tested card it then unlocks in the same start; other cards follow the careful path described under [Supported cards](#supported-cards).
5. **Volatile.** The setting is lost at power-off and restart, so it is applied again at every start. The switch decides whether the *next* start unlocks, because the unlock has to happen before the NVIDIA driver loads.

## Supported cards

Made for **GeForce RTX 40-series** cards: RTX 4090, 4080, 4080 SUPER, 4070 Ti SUPER, 4070 Ti, 4070 SUPER and 4070 (standard memory sizes, one card per PC). **Only the RTX 4090 has been tested.**

On every card other than the RTX 4090 the program is more careful (all of it can be undone from the window):

1. **Read only.** After installing, the first start only reads the card and saves its profile. Nothing is written to the card.
2. **One trial.** You click **Try unlock once**. The next start tries a single unlock. The permission is used up *before* the attempt, so if the screen stays black, nothing repeats.
3. **Automatic only after it worked.** **Turn on auto-unlock** only appears after a trial was verified on your PC. Until then the switch only keeps the boot program on (it reads the card and waits); you can switch it off at any time, which also cancels a pending trial.

Not supported: RTX 4090 D, 48 GB modded cards, laptop GPUs, RTX 4060 series, 30- and 50-series, more than one supported card in a PC. The installer refuses these cards, and it warns when another display adapter is present (the boot program itself refuses to run unless the screen is on the supported card).

If you try another card, please [open an issue](../../issues/new/choose) with the result, successful or not.

## Requirements

The installer's **Check system** button checks each of these and refuses to install if one fails.

| | |
|---|---|
| GPU | Exactly one supported card (see above), with its standard memory size (24 GB for the 4090, 16 GB for the 4080 family and 4070 Ti SUPER, 12 GB for the 4070 Ti, 4070 SUPER and 4070) |
| OS | Windows 10 / 11, 64-bit |
| Boot | UEFI (not Legacy/CSM) |
| Secure Boot | **Off** (the boot program is unsigned) |
| BitLocker / Device Encryption | **Off** (changing the boot path would trigger recovery) |
| Display | Connected to the supported card only |
| Space | An NTFS volume on a GPT disk that can shrink by 304 MiB, or a FAT32 USB drive with 150 MB free; about 400 MB for the downloads (the check wants at least 1 GB free on the drive that holds the cache) |

**Not supported:** 48 GB modded cards, RTX 4090 D, laptop GPUs, multi-GPU, Secure Boot on.

## Tested vs untested

| Verified on the test PC | Not verified |
|---|---|
| Windows 11 Pro 24H2 (26100), driver 610.88 | Windows 10, Home and Server editions |
| The trial flow (read only, wait, one trial, confirm), forced onto the 4090 with a `trial_required=1` profile key | **Every card other than the 4090.** The chip table and the VRAM and chip-id checks for AD103 and AD104 are written from upstream documentation and were never run on such a card |
| ASUS ROG STRIX Z790-H (BIOS 3107), i7-14700KF, ASUS RTX 4090 | Other boards and other 4090 brands; some firmware ignores or resets boot-order changes made from Windows |
| Install, uninstall (the volume is restored to its exact size), switch on/off, re-enroll | USB-drive mode, rollback after a failed install |
| First-start enrollment plus unlock, unlock after cold boot and restart, more than 10 successful unlocks | Behaviour after sleep (S3; the unlock is expected to be lost), with Fast Startup on, after Windows or BIOS updates |
| Download, size and SHA-256 checks against a pre-filled cache and a local TLS 1.3 test server | A real online download on a fresh PC (archive.cachyos.org needs TLS 1.3, which Windows 10 may lack; then copy the file into the cache by hand) |
| UI at 100 %, and simulated 125 % and 150 % scaling | User names or paths with non-ASCII characters |

**Reports from other machines are very welcome.** Please open an issue with your board, BIOS version, GPU brand, Windows version and the boot log (button **Boot log**; the `FINAL` line matters most).

## Install

1. Turn **Secure Boot off** in the BIOS, and **BitLocker / Device Encryption off** in Windows. Back up important data.
2. Download the release zip (or clone this repository), open `installer\` and double-click **`GPU-Unlock-Installer.cmd`**. Accept the administrator prompt.
3. Click **Check system**. Every item must say *Pass*; a *Warning* is advisory (an experimental card always shows one).
4. Click **Install…**, choose the internal partition (recommended) or a USB drive, tick the risk box (and, for an experimental card, the extra box), and click **Install**.
5. Restart when asked. On an experimental card, click **Try unlock once** and restart again; after a successful trial click **Turn on auto-unlock**.

The interface is entirely English or entirely Chinese. Switch with **中文 / English** at the top right.

Command line (administrator PowerShell, inside `installer\`):

```powershell
powershell -ExecutionPolicy Bypass -File core.ps1 check
powershell -ExecutionPolicy Bypass -File core.ps1 install -Mode partition -TargetVolume D -DryRun
powershell -ExecutionPolicy Bypass -File core.ps1 trial        # experimental cards: arm one trial unlock
powershell -ExecutionPolicy Bypass -File core.ps1 enable | disable | status | logs | reenroll | uninstall
powershell -ExecutionPolicy Bypass -File core.ps1 install -AcceptExperimental   # needed for an experimental card
```

`-DryRun` prints the plan without changing anything. `-Lang en|zh` picks the output language.

## Daily use

- **Switch.** The *Auto-unlock at start-up* switch turns the unlock on or off from the next start.
- **Status.** The big card shows whether *this* start is unlocked. Every restart clears the unlock, and the next start applies it again if the switch is on.
- **Skip once.** To skip the unlock for one start, open the firmware boot menu (F8 on ASUS, often F11 or F12 elsewhere) and choose *Windows Boot Manager*.
- **Try unlock once** (experimental cards only). Arms one trial for the next start. After a trial worked, the same button becomes **Turn on auto-unlock**.
- **Re-enroll card.** Use this after a GPU swap, a BIOS update or a change to board settings. It also resets the trial state.
- **Uninstall.** This removes the boot entry and the partition, and gives the space back.

To check the speed yourself, run `python tools/bench_gemm.py <label>` (needs PyTorch with CUDA) and compare a locked and an unlocked start. TF32 shows the clearest difference.

The full Chinese manual is in [docs/MANUAL-zh.md](docs/MANUAL-zh.md). It covers troubleshooting, where the files live and manual removal with `bcdedit`.

## Risks

- **Black screen.** The boot program writes GPU registers at every start, with nobody watching. If the transaction fails midway, the program halts and asks you to power off, so the PC can hang on a black screen. Hold the power button, then use the boot menu to start *Windows Boot Manager* and turn the switch off. On an experimental card this can happen during the one trial; the trial permission is already used up, so nothing repeats.
- **Other cards are untested.** For every card except the RTX 4090 the settings come from upstream documentation, not from this project's tests. A wrong value is meant to make the program stop before writing (the card must match its chip id, memory size and cold-state registers), but this has not been exercised on those cards.
- **Fast Startup.** With Fast Startup on, *Shut down* resumes a saved Windows session instead of starting fresh. That was not tested, and it can clash with files the boot program changes. **Check system** warns about it; turn it off or always use *Restart*.
- **Disk changes.** Partition mode shrinks one of your volumes. Back up first.
- **Unsigned code.** The scripts and the EFI program are unsigned, so antivirus or SmartScreen may warn. You can build the EFI yourself and compare hashes; see [efi/README.md](efi/README.md).
- **Legal.** This is not legal advice. NVIDIA's driver and firmware terms, anti-circumvention laws (for example 17 U.S.C. §1201) and export-control rules may apply where you live. Decide for yourself whether you may use this.

## Repository layout

| Path | Contents |
|---|---|
| `installer/` | `GPU-Unlock-Installer.cmd`, `gui.ps1` (WinForms GUI), `core.ps1` (all actions), `payload/` (the prebuilt `gpuunlock.efi`, the hash manifest and the local firmware tools) |
| `efi/` | Complete source of `gpuunlock.efi`, its build script, and the patch against upstream |
| `.github/` | Issue templates, including a report form for other cards |
| `tools/bench_gemm.py` | A/B benchmark |
| `docs/` | Chinese manual and screenshots |

## Credits and license

This builds on public research and code: [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock), [TOTORONG/AD103_win_unlocker](https://huggingface.co/TOTORONG/AD103_win_unlocker) and [brandonjank/gpu-unlock-ada](https://github.com/brandonjank/gpu-unlock-ada), among others. See [NOTICE.md](NOTICE.md).

Licensed under **GPL-2.0-only** ([LICENSE](LICENSE)). Third-party parts keep their own notices. This project is not affiliated with or endorsed by NVIDIA. NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation and are used here only to say which hardware this works with.
