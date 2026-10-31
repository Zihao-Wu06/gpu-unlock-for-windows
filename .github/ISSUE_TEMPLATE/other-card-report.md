---
name: Result on another card / 其他显卡的结果
about: You tried an experimental card (4080, 4080 SUPER, 4070 Ti SUPER, 4070 Ti, 4070 SUPER, 4070). Successful or not, please report.
title: "[card report] <card name> - <worked / failed at stage ...>"
labels: card-report
---

Thank you for trying an experimental card. Whatever happened, it helps. Please do not attach ROM dumps or NVIDIA firmware files.

**Card and PC**
- Card (brand, model, VRAM): 
- PCI ID (Device Manager > Details > Hardware Ids, e.g. `PCI\VEN_10DE&DEV_2705`, or `DEV_2689` for the AD102 4070 Ti SUPER): 
- Board and BIOS version: 
- Windows version and NVIDIA driver version: 
- Other GPUs or an iGPU in the PC? 

**What happened** (tick what applies)
- [ ] Check system passed (paste any warnings)
- [ ] First start only read the card (profile `Enrolled` in the window)
- [ ] Trial start: unlocked (`Trial worked this start`)
- [ ] Trial start: stopped at stage `____` (paste the `FINAL` line from **Boot log**)
- [ ] Screen stayed black and I had to power off
- [ ] Auto-unlock turned on and works at every start

**Speed check** (optional, `python tools/bench_gemm.py locked` and `... unlocked`, paste the numbers)

**Boot log** (button **Boot log**, or `core.ps1 logs`): paste the lines that start with `profile:`, `chip:`, `cold state:`, `TRIAL RUN`, `POST-GOP` and `FINAL`.

---

**使用说明（中文）**：请填上面的显卡、主板、BIOS、系统和驱动版本，勾选发生了什么，并把"开机日志"里以 `profile:`、`chip:`、`cold state:`、`TRIAL RUN`、`POST-GOP`、`FINAL` 开头的几行贴上来。不要上传显卡 ROM 或 NVIDIA 固件文件。
