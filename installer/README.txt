GPU Unlock for GeForce RTX 40 (Windows)  -  EXPERIMENTAL
====================================================
Double-click  GPU-Unlock-Installer.cmd  (Windows asks for administrator rights).
The window is in English or Chinese; switch with "中文 / English" at the top right.

What it does
  - Turns on the full-rate FP32-accumulate tensor-core path of ONE GeForce RTX 40-series card
    for FP16/BF16/TF32 matrix math. Games, FP16-accumulate, INT8 and FP32 CUDA-core speed do not change.
  - It is NOT a driver and NOT a VBIOS flash. A small UEFI program runs before Windows at every start, applies the setting,
    and then starts Windows. The setting is lost at power-off/restart, so it is applied again at every start.
  - GEMM gains on the tested card: about +10 % to +55 % (TF32 about 2x per clock). The power limit still applies.

What the installer changes on your PC
  - Adds a firmware boot entry "GPU Unlock (auto)" at the TOP of the boot order (the switch removes/adds it).
  - Partition mode: shrinks one volume by 304 MiB and creates a 300 MiB FAT32 partition (no drive letter) for the program
    and ~85 MB of firmware files. USB mode: copies the files to a FAT32 drive you choose (nothing is formatted).
  - Downloads ~330 MB of NVIDIA firmware inputs (hash-checked) and unpacks them on your PC. Nothing from NVIDIA is shipped here.

Requirements: Windows 10/11 x64, UEFI boot, Secure Boot OFF, BitLocker/Device Encryption OFF, exactly one supported card,
monitor on that card. Supported: RTX 4090, 4080, 4080 SUPER, 4070 Ti SUPER (AD103 or AD102), 4070 Ti, 4070 SUPER, 4070. Only the RTX 4090 has been tested; on the
others the first start only reads the card, an unlock needs one armed trial, and automatic only after it worked.
Not supported: 48 GB modded cards, 4090 D, laptops, other series, multi-GPU, Secure Boot on.
Only the RTX 4090 has been tested. See README.md / README.zh-CN.md in the repository for what is and is not tested.

Use at your own risk. If a start ever hangs on a black screen: hold the power button, then at the next start open the firmware
boot menu (F8 on ASUS, often F11/F12 elsewhere) and pick "Windows Boot Manager" (this also skips the unlock for that start).
There is no countdown: when the switch is ON the unlock runs at every start. Turn it OFF with the switch in the window.
Uninstall: open the window and click Uninstall (removes the entry, deletes the partition, gives the space back).

Source and license: GPL-2.0-only. Full source of gpuunlock.efi is in the repository's efi/ folder; see NOTICE.md.
Not affiliated with or endorsed by NVIDIA. Driver/firmware terms, anti-circumvention and export-control rules may apply:
decide for yourself (this is not legal advice).
