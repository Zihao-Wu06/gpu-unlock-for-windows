<#
GPU Unlock - front end (WinForms, Windows PowerShell 5.1, no extra software needed).
All real work is done by core.ps1; this window only starts it and shows what it prints.
The interface is entirely English or entirely Chinese; the switch at the top right changes it and the choice is saved per user.
-Snapshot/-SnapshotCheck/-SnapshotDialog render the window to PNG files and exit (used to check the layout without a screen).
#>
param([string]$Lang = '', [string]$Snapshot = '', [switch]$SnapshotCheck, [string]$SnapshotDialog = '', [double]$ForceScale = 0, [string]$SnapshotStatus = '', [switch]$SnapshotExperimental)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Core = Join-Path $Root 'core.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Snapshot) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# crisp text on scaled (125%/150%) screens instead of a blurry stretched bitmap
try { Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'; [void][Win32.Dpi]::SetProcessDPIAware() } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()
# Layout is written for 96 DPI and scaled by hand to the screen's DPI (fonts in points already follow the DPI).
# WinForms auto-scaling did not move the controls when they are added in code, so text overflowed on 150% screens.
# -ForceScale imitates a scaled screen for layout snapshots taken at 96 DPI (it also enlarges the fonts).
$script:sf = 1.0; $script:fontMul = 1.0
if ($ForceScale -gt 0) { $script:sf = $ForceScale; $script:fontMul = $ForceScale }
else { try { $gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:sf = $gfx.DpiX / 96.0; $gfx.Dispose() } catch { } }
$Manifest = Get-Content -LiteralPath (Join-Path $Root 'payload\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# ------------------------------------------------------------------------------------------ language
$PrefPath = 'HKCU:\Software\GPU-Unlock'
$script:lang = $Lang
if ($script:lang -notin 'en', 'zh') { try { $script:lang = (Get-ItemProperty -Path $PrefPath -ErrorAction Stop).Lang } catch { } }
if ($script:lang -notin 'en', 'zh') { $script:lang = $(if ((Get-UICulture).Name -like 'zh*' -or (Get-Culture).Name -like 'zh*') { 'zh' } else { 'en' }) }

$Text = @{
    en = @{
        appName = 'GPU Unlock'; title = 'RTX 40 Series Compute Unlock'; subtitle = 'Windows pre-boot unlock  ·  v{0}'
        heroLoading = 'Reading status…'; statusFail = 'Could not read the status'
        heroUnlocked = 'Unlocked for this session'; heroFailed = 'The unlock failed this time'; heroLocked = 'Not unlocked right now'
        heroPending = 'Installed — restart to unlock'; heroNotInstalled = 'Not installed'
        notInstalledSub = 'Click “Check system” to see whether this PC is suitable, then “Install…”.'
        swOn = 'Auto-unlock is on: every start unlocks the card before Windows loads.'
        swOff = 'Auto-unlock is off: the PC starts normally, without unlocking.'
        swNotFirst = 'The boot entry exists but is not first in the boot order; switch it on again.'
        runThis = 'Unlocked at {0}.'; runFailed = 'The boot program ran at {0} but stopped at stage “{1}”. See the boot log.'
        runEarlier = 'Last run {0} was in an earlier start; every restart clears the unlock.'
        noRun = 'No boot log yet.'; restartHint = ' Restart to unlock.'
        tglLabel = 'Auto-unlock at start-up'; tglOn = 'On'; tglOff = 'Off'; tglNotFirst = 'Not first'; tglNA = 'Not installed'; applies = 'changes apply at the next start'
        tInstall = 'Installation'; vInstalled = 'Installed · {0}'; modePart = 'partition'; modeUsb = 'USB drive'; vNotInstalled = 'Not installed'
        tFiles = 'Boot files'; vComplete = 'Complete'; vIncomplete = 'Missing'
        tProfile = 'Card profile'; vEnrolled = 'Enrolled'; vNotEnrolled = 'At next start'; tVersion = 'Version'
        bCheck = 'Check system'; bInstall = 'Install…'; bReenroll = 'Re-enroll card'; bLogs = 'Boot log'; bUninstall = 'Uninstall'
        tabLog = 'Activity'; tabCheck = 'System check'; busy = 'Working'
        cStatus = 'Status'; cName = 'Check'; cDetail = 'Details'; sOk = 'Pass'; sWarn = 'Warning'; sFail = 'Fail'
        checkSummary = 'Check finished: {0} passed, {1} warnings, {2} failed.'
        footer = 'Experimental software: it changes the firmware boot order and writes GPU registers at every start. Tested on one card only; every other card is experimental. Use at your own risk.'
        ready = 'Ready. Click “Check system” to see whether this PC is suitable.'; langChanged = 'Language: English'
        bootLogNote = 'Raw log of the boot program (technical output, English only):'
        readingDisks = 'Reading the disk list; the install window opens in a few seconds…'
        msgOn = "Auto-unlock is on. It takes effect at the next start; this session is unchanged.`r`n`r`nRestart now?"
        msgOff = "Auto-unlock is off. From the next start the card is no longer unlocked; this session stays as it is until you restart.`r`n`r`nRestart now?"
        reenrollQ = "Delete the saved card profile? The next start reads the card again and saves a new one.`r`n`r`nUse this after changing the GPU, updating the BIOS or changing board settings."
        uninstallQ = "Remove the boot entry and the program files?`r`n`r`nIn partition mode the small partition is deleted and its space goes back to the volume it came from."
        installedQ = "Installed. Restart now?`r`n`r`nThe first start reads the card, then unlocks it in the same start."
        installFailed = 'The install did not finish; a rollback was attempted. See Activity for details.'
        dlgTitle = 'Install'; dlgHead = 'Where should the program and firmware files live?'
        optPart = 'A small partition on an internal disk (recommended)'
        optPartNote = 'Shrinks the chosen volume by 304 MiB and creates a 300 MiB FAT32 partition with no drive letter. Whether it can shrink is checked before anything changes.'
        optUsb = 'A FAT32 USB drive (no partition changes)'
        optUsbNote = 'Nothing is formatted. Keep it plugged in; without it the PC simply starts Windows.'
        steps = "Install will:`r`n1.  Download about 330 MB of NVIDIA firmware inputs and verify their hashes (unpacked on this PC only, never shipped with this tool).`r`n2.  Prepare the location chosen above.`r`n3.  Add a firmware boot entry.`r`nAt the first restart the card is read, then unlocked in the same start."
        stepsExp = "Install will:`r`n1.  Download about 330 MB of NVIDIA firmware inputs and verify their hashes (unpacked on this PC only, never shipped with this tool).`r`n2.  Prepare the location chosen above.`r`n3.  Add a firmware boot entry.`r`nThe first restart only reads the card; nothing is written to it."
        chkEnable = 'Turn auto-unlock on after installing'; chkRisk = 'I understand this is experimental and use it at my own risk'
        bGo = 'Install'; bCancel = 'Cancel'
        bTrial = 'Try unlock once'; tCard = 'Graphics card'; tCardExp = 'Graphics card · experimental'
        heroExpRestart = 'Installed — restart to read the card'; subExpRestart = 'Experimental card: the first start only reads it. Nothing is written to the card.'
        heroExpReady = 'Card read — not unlocked yet'; subExpReady = 'Experimental card: try ONE unlock to see whether it works on this PC. It is never repeated by itself.'
        heroExpArmed = 'Trial armed'; subExpArmed = 'The next start tries ONE unlock. If the screen stays black: hold the power button, start again, pick “Windows Boot Manager” in the boot menu, then turn the switch off.'
        heroExpOk = 'Trial worked this start'; subExpOk = 'Use the card for a while (a game or a benchmark). If everything is fine, click “Turn on auto-unlock”.'
        heroExpOkEarlier = 'Trial worked earlier — not unlocked now'; subExpOkEarlier = 'Click “Turn on auto-unlock” to unlock at every start.'
        heroExpFail = 'The trial did not unlock the card'; subExpFail = 'It stopped at stage “{0}”. Nothing keeps running. See the boot log; you can try once more.'
        tglWaiting = 'On · not unlocking yet'; bConfirm = 'Turn on auto-unlock'
        heroExpOff = 'Boot program is off — the card has not been read'; subExpOff = 'Turn the switch on, then restart once so the boot program can read the card.'
        msgOnExp = "The boot program is on. This experimental card is only read and waits; nothing is unlocked until a trial worked.`r`n`r`nRestart now?"
        trialQ = "Arm ONE trial unlock?`r`n`r`nAt the next start the card is unlocked once. If the screen stays black, hold the power button until the PC is off, start it again, pick 'Windows Boot Manager' in the boot menu, and turn the switch off.`r`n`r`nContinue?"
        trialDoneQ = "Trial armed. The next start tries ONE unlock.`r`n`r`nRestart now?"
        installedQExp = "Installed. Restart now?`r`n`r`nThe first start only reads the card and saves its profile. After that, click 「Try unlock once」."
        expNote = "{0} is an EXPERIMENTAL card: this project has not tested it. The first start only reads the card. An unlock is tried only after you arm one trial, and automatic unlock stays off until a trial has worked."
        chkEnableExp = 'Read the card at the next start (nothing is unlocked yet)'; chkExp = 'I understand this card has not been tested by this project'
        partItem = '{0}:   ·   {1} GB free'; sysSuffix = '   ·   system drive'; recSuffix = '   ·   recommended'; usbItem = '{0}:   {1}   ·   {2} MB free'; noneFound = 'None found'
    }
    zh = @{
        appName = 'GPU 解锁'; title = 'RTX 40 系算力解锁'; subtitle = 'Windows 开机前解锁  ·  v{0}'
        heroLoading = '正在读取状态…'; statusFail = '无法读取状态'
        heroUnlocked = '本次开机已解锁'; heroFailed = '本次开机解锁失败'; heroLocked = '当前未解锁'
        heroPending = '已安装，重启后解锁'; heroNotInstalled = '尚未安装'
        notInstalledSub = '先点“检查系统”确认这台电脑是否适用，再点“安装…”。'
        swOn = '自动解锁已开启：每次开机都会在 Windows 加载前解锁显卡。'
        swOff = '自动解锁已关闭：电脑正常启动，不再解锁。'
        swNotFirst = '启动项存在，但不在启动顺序第一位；请重新打开开关。'
        runThis = '解锁于 {0}。'; runFailed = '开机程序于 {0} 运行，但停在“{1}”阶段。详见开机日志。'
        runEarlier = '最近一次运行（{0}）属于更早的开机；每次重启都会清除解锁。'
        noRun = '还没有开机日志。'; restartHint = '重启即可解锁。'
        tglLabel = '开机自动解锁'; tglOn = '已开启'; tglOff = '已关闭'; tglNotFirst = '不在第一位'; tglNA = '未安装'; applies = '改动下次开机生效'
        tInstall = '安装状态'; vInstalled = '已安装 · {0}'; modePart = '硬盘分区'; modeUsb = 'U 盘'; vNotInstalled = '未安装'
        tFiles = '开机程序文件'; vComplete = '完整'; vIncomplete = '缺失'
        tProfile = '显卡信息'; vEnrolled = '已登记'; vNotEnrolled = '下次开机登记'; tVersion = '版本'
        bCheck = '检查系统'; bInstall = '安装…'; bReenroll = '重新登记显卡'; bLogs = '开机日志'; bUninstall = '卸载'
        tabLog = '运行记录'; tabCheck = '系统检查'; busy = '正在处理'
        cStatus = '状态'; cName = '检查项'; cDetail = '详情'; sOk = '通过'; sWarn = '注意'; sFail = '未通过'
        checkSummary = '检查完成：{0} 项通过，{1} 项注意，{2} 项未通过。'
        footer = '实验性软件：会修改固件启动顺序，并在每次开机时写显卡寄存器。只在一块显卡上测试过，其他显卡都是实验性支持，风险自负。'
        ready = '准备就绪。点击“检查系统”，看看这台电脑是否适用。'; langChanged = '语言：中文'
        bootLogNote = '开机程序的原始日志（技术输出，只有英文）：'
        readingDisks = '正在读取磁盘列表，几秒后打开安装窗口…'
        msgOn = "已开启自动解锁。下次开机生效，当前这次开机不变。`r`n`r`n现在重启吗？"
        msgOff = "已关闭自动解锁。下次开机起不再解锁；当前这次开机保持现状，直到重启。`r`n`r`n现在重启吗？"
        reenrollQ = "删除已保存的显卡信息？下次开机会重新读取并保存。`r`n`r`n适用于更换显卡、升级 BIOS 或改动主板设置之后。"
        uninstallQ = "删除启动项和程序文件？`r`n`r`n硬盘分区模式下会删除那个小分区，并把空间还给原来的卷。"
        installedQ = "安装完成。现在重启吗？`r`n`r`n第一次开机会先读取显卡信息，然后在同一次开机里解锁。"
        installFailed = '安装没有完成，已尝试回滚。详情见“运行记录”。'
        dlgTitle = '安装'; dlgHead = '程序和固件文件放在哪里？'
        optPart = '内部硬盘上的小分区（推荐）'
        optPartNote = '把所选卷缩小 304 MiB，新建一个 300 MiB、没有盘符的 FAT32 分区。改动前会先检查能否缩小，不行就停止。'
        optUsb = 'FAT32 格式的 U 盘（不改分区）'
        optUsbNote = '不会格式化。需要一直插着；拔掉后电脑直接正常启动 Windows。'
        steps = "安装会：`r`n1.  下载约 330 MB 的 NVIDIA 固件包并核对哈希（只在本机提取，不随本工具分发）。`r`n2.  准备上面选择的位置。`r`n3.  添加一个固件启动项。`r`n重启后第一次开机会先读取显卡信息，然后在同一次开机里解锁。"
        stepsExp = "安装会：`r`n1.  下载约 330 MB 的 NVIDIA 固件包并核对哈希（只在本机提取，不随本工具分发）。`r`n2.  准备上面选择的位置。`r`n3.  添加一个固件启动项。`r`n重启后第一次开机只读取显卡信息，不会向显卡写入任何内容。"
        chkEnable = '安装后立即开启自动解锁'; chkRisk = '我了解这是实验性软件，风险自负'
        bGo = '开始安装'; bCancel = '取消'
        bTrial = '试解锁一次'; tCard = '显卡'; tCardExp = '显卡 · 实验性'
        heroExpRestart = '已安装，重启后读取显卡'; subExpRestart = '实验性显卡：第一次开机只读取显卡信息，不会向显卡写入任何内容。'
        heroExpReady = '已读取显卡，尚未解锁'; subExpReady = '实验性显卡：先试解锁一次，看看在这台电脑上是否有效。它不会自己重复。'
        heroExpArmed = '已开启试解锁'; subExpArmed = '下次开机会尝试解锁一次。如果屏幕一直黑屏：长按电源键关机，再开机，在启动菜单里选“Windows Boot Manager”，进系统后把开关关掉。'
        heroExpOk = '本次开机试解锁成功'; subExpOk = '先用一段时间（玩游戏或跑个测试），一切正常再点“开启自动解锁”。'
        heroExpOkEarlier = '之前试解锁成功，当前未解锁'; subExpOkEarlier = '点“开启自动解锁”后，每次开机都会解锁。'
        heroExpFail = '试解锁没有成功'; subExpFail = '停在了“{0}”阶段，没有任何东西在继续运行。详见开机日志，可以再试一次。'
        tglWaiting = '已开启 · 暂不解锁'; bConfirm = '开启自动解锁'
        heroExpOff = '开机程序已关闭，尚未读取显卡'; subExpOff = '请先打开开关，再重启一次，让开机程序读取显卡信息。'
        msgOnExp = "已开启开机程序。这张实验性显卡只会被读取并等待，在试解锁成功之前不会解锁。`r`n`r`n现在重启吗？"
        trialQ = "开启一次试解锁？`r`n`r`n下次开机会解锁一次。如果屏幕一直黑屏，请长按电源键直到关机，再开机，在启动菜单里选'Windows Boot Manager'，并把开关关掉。`r`n`r`n继续吗？"
        trialDoneQ = "已开启试解锁。下次开机会尝试解锁一次。`r`n`r`n现在重启吗？"
        installedQExp = "安装完成。现在重启吗？`r`n`r`n第一次开机只会读取显卡信息并保存。之后再点「试解锁一次」。"
        expNote = "{0} 是实验性支持的显卡：本项目没有测试过它。第一次开机只读取显卡信息；只有你手动开启一次试解锁后才会尝试解锁，试解锁成功之前自动解锁保持关闭。"
        chkEnableExp = '下次开机读取显卡信息（暂不解锁）'; chkExp = '我了解本项目没有测试过这张显卡'
        partItem = '{0}:   ·   可用 {1} GB'; sysSuffix = '   ·   系统盘'; recSuffix = '   ·   推荐'; usbItem = '{0}:   {1}   ·   可用 {2} MB'; noneFound = '未找到'
    }
}
function T([string]$Key) { return $Text[$script:lang][$Key] }

# ------------------------------------------------------------------------------------------ look
function C([string]$Hex) { return [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$Pal = @{
    Bg = (C '#F3F4F6'); Card = (C '#FFFFFF'); Line = (C '#E5E7EB'); Ink = (C '#111827'); Muted = (C '#6B7280')
    Head = (C '#111827'); HeadMuted = (C '#9CA3AF'); HeadLine = (C '#374151'); Accent = (C '#22C55E')
    Ok = (C '#16A34A'); OkInk = (C '#15803D'); Bad = (C '#DC2626'); BadInk = (C '#B91C1C'); Warn = (C '#D97706'); Idle = (C '#9CA3AF')
    Console = (C '#0D1117'); ConsoleInk = (C '#C9D1D9'); Primary = (C '#111827'); PrimaryHover = (C '#1F2937'); Disabled = (C '#D1D5DB')
    BtnLine = (C '#D1D5DB'); Hover = (C '#F9FAFB'); DangerLine = (C '#FCA5A5'); DangerHover = (C '#FEF2F2'); Soft = (C '#F9FAFB'); FootInk = (C '#92400E')
}
$script:fonts = New-Object System.Collections.ArrayList
function UiFamily { if ($script:lang -eq 'zh') { return 'Microsoft YaHei UI' }; return 'Segoe UI' }
function F([single]$Size, [string]$Style = 'Regular') { return New-Object System.Drawing.Font((UiFamily), ([single]($Size * $script:fontMul)), ([System.Drawing.FontStyle]$Style)) }
function Set-Font($Ctl, [single]$Size, [string]$Style = 'Regular') { [void]$script:fonts.Add(@($Ctl, $Size, $Style)); $Ctl.Font = F $Size $Style }
function Apply-Fonts { foreach ($x in $script:fonts) { $x[0].Font = F $x[1] $x[2] } }
function Fit-Tile($Lbl, [string]$Text, [single]$Max = 11, [single]$Min = 8) {
    # long card names (e.g. "RTX 4070 Ti SUPER (AD102)") must stay on one line: shrink the font until the text fits
    $Lbl.Text = $Text; $sz = $Max
    $tracked = @($script:fonts | Where-Object { [object]::ReferenceEquals($_[0], $Lbl) }) | Select-Object -First 1
    while ($true) {
        $Lbl.Font = F $sz 'Bold'
        if ($sz -le $Min -or [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Lbl.Font).Width -le $Lbl.Width) { break }
        $sz -= 0.5
    }
    if ($tracked) { $tracked[1] = [single]$sz }
}

function New-Lbl($Parent, $X, $Y, $W, $H, [single]$Size = 9, [string]$Style = 'Regular', $Color = $null, [switch]$NoTrack) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = $(if ($Color) { $Color } else { $Pal.Ink })
    if ($NoTrack) { $l.Font = F $Size $Style } else { Set-Font $l $Size $Style }
    $Parent.Controls.Add($l); return $l
}
function New-Btn($Parent, $X, $Y, $W, $H, [string]$Kind = 'secondary', [switch]$NoTrack) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.Tag = $Kind
    switch ($Kind) {
        'primary' { $b.BackColor = $Pal.Primary; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $Pal.PrimaryHover; $b.FlatAppearance.MouseDownBackColor = $Pal.Ink }
        'danger' { $b.BackColor = $Pal.Card; $b.ForeColor = $Pal.BadInk; $b.FlatAppearance.BorderColor = $Pal.DangerLine; $b.FlatAppearance.MouseOverBackColor = $Pal.DangerHover }
        default { $b.BackColor = $Pal.Card; $b.ForeColor = $Pal.Ink; $b.FlatAppearance.BorderColor = $Pal.BtnLine; $b.FlatAppearance.MouseOverBackColor = $Pal.Hover }
    }
    if ($NoTrack) { $b.Font = F 9.5 } else { Set-Font $b 9.5 }
    $Parent.Controls.Add($b); return $b
}
function Set-BtnEnabled($B, [bool]$On) {
    $B.Enabled = $On
    if ($B.Tag -eq 'primary') { $B.BackColor = $(if ($On) { $Pal.Primary } else { $Pal.Disabled }) }
}
function New-Card($Parent, $X, $Y, $W, $H, $Fill = $null) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y); $p.Size = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $(if ($Fill) { $Fill } else { $Pal.Card })
    $p.Add_Paint({ param($s, $e) $pen = New-Object System.Drawing.Pen($Pal.Line); $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $pen.Dispose() })
    $Parent.Controls.Add($p); return $p
}

# ------------------------------------------------------------------------------------------ window
$form = New-Object System.Windows.Forms.Form
$form.AutoScaleMode = 'None'
$form.ClientSize = New-Object System.Drawing.Size(900, 650)
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'; $form.BackColor = $Pal.Bg
Set-Font $form 9

# header band
$head = New-Object System.Windows.Forms.Panel
$head.Location = New-Object System.Drawing.Point(0, 0); $head.Size = New-Object System.Drawing.Size(900, 64); $head.BackColor = $Pal.Head
$form.Controls.Add($head)
$lblTitle = New-Lbl $head 22 9 600 30 15 'Bold' ([System.Drawing.Color]::White)
$lblSub = New-Lbl $head 24 40 600 18 8.5 'Regular' $Pal.HeadMuted
$seg = New-Object System.Windows.Forms.Panel
$seg.Location = New-Object System.Drawing.Point(762, 18); $seg.Size = New-Object System.Drawing.Size(114, 28); $seg.BackColor = $Pal.HeadLine
$head.Controls.Add($seg)
$segZh = New-Lbl $seg 2 2 55 24 9 'Regular' -NoTrack; $segZh.Text = '中文'
$segEn = New-Lbl $seg 57 2 55 24 9 'Regular' -NoTrack; $segEn.Text = 'English'
foreach ($l in $segZh, $segEn) { $l.TextAlign = 'MiddleCenter'; $l.Cursor = [System.Windows.Forms.Cursors]::Hand }
$segZh.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', ([single](9 * $script:fontMul))); $segEn.Font = New-Object System.Drawing.Font('Segoe UI', ([single](9 * $script:fontMul)))
$strip = New-Object System.Windows.Forms.Panel
$strip.Location = New-Object System.Drawing.Point(0, 64); $strip.Size = New-Object System.Drawing.Size(900, 3); $strip.BackColor = $Pal.Accent
$form.Controls.Add($strip)

# hero card: what state the card is in right now, and the switch
$hero = New-Card $form 24 84 852 114
$dot = New-Object System.Windows.Forms.Panel
$dot.Location = New-Object System.Drawing.Point(24, 24); $dot.Size = New-Object System.Drawing.Size(14, 14); $dot.BackColor = $Pal.Card
$hero.Controls.Add($dot)
$script:dotColor = $Pal.Idle
$dot.Add_Paint({ param($s, $e) $e.Graphics.SmoothingMode = 'AntiAlias'; $br = New-Object System.Drawing.SolidBrush($script:dotColor); $e.Graphics.FillEllipse($br, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1); $br.Dispose() })
$lblHero = New-Lbl $hero 46 12 540 34 15 'Bold'
$lblHeroSub = New-Lbl $hero 48 50 462 60 9 'Regular' $Pal.Muted
$lblTgl = New-Lbl $hero 560 20 200 30 10 'Bold'; $lblTgl.TextAlign = 'MiddleRight'
$tgl = New-Object System.Windows.Forms.Panel
$tgl.Location = New-Object System.Drawing.Point(772, 21); $tgl.Size = New-Object System.Drawing.Size(56, 28); $tgl.BackColor = $Pal.Card
$hero.Controls.Add($tgl)
$lblTglNote = New-Lbl $hero 520 56 308 36 8.5 'Regular' $Pal.Muted; $lblTglNote.TextAlign = 'MiddleRight'
$script:tglOn = $false; $script:tglEnabled = $false
$tgl.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $w = [single]($s.ClientSize.Width - 1); $h = [single]($s.ClientSize.Height - 1)
    $col = $(if (-not $script:tglEnabled) { $Pal.Line } elseif ($script:tglOn) { $Pal.Ok } else { $Pal.Disabled })
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc([single]0, [single]0, $h, $h, [single]90, [single]180)
    $path.AddArc([single]($w - $h), [single]0, $h, $h, [single]270, [single]180)
    $path.CloseFigure()
    $br = New-Object System.Drawing.SolidBrush($col); $g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
    $k = [single]($h - 6); $kx = $(if ($script:tglOn) { [single]($w - $h + 3) } else { [single]3 })
    $kb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White); $g.FillEllipse($kb, $kx, [single]3, $k, $k); $kb.Dispose()
})

# four facts
$tileT = @(); $tileV = @()
for ($i = 0; $i -lt 4; $i++) {
    $tc = New-Card $form (24 + $i * 216) 210 204 64
    $tileT += New-Lbl $tc 14 9 180 18 8.5 'Regular' $Pal.Muted
    $tileV += New-Lbl $tc 14 29 184 28 11 'Bold'
}

# actions
$btnCheck = New-Btn $form 24 288 132 36
$btnInstall = New-Btn $form 166 288 132 36 'primary'
$btnReenroll = New-Btn $form 308 288 150 36
$btnLogs = New-Btn $form 468 288 132 36
$btnTrial = New-Btn $form 610 288 146 36
$btnTrial.Visible = $false
$btnUninstall = New-Btn $form 766 288 110 36 'danger'

# tabs: activity log / system check
$tabLog = New-Lbl $form 24 338 100 22 10 'Bold'; $tabLog.AutoSize = $true
$tabCheck = New-Lbl $form 140 338 100 22 10 'Bold'; $tabCheck.AutoSize = $true
foreach ($l in $tabLog, $tabCheck) { $l.Cursor = [System.Windows.Forms.Cursors]::Hand }
$tabLine = New-Object System.Windows.Forms.Panel
$tabLine.Size = New-Object System.Drawing.Size(60, 2); $tabLine.BackColor = $Pal.Ink; $tabLine.Location = New-Object System.Drawing.Point(24, 362)
$form.Controls.Add($tabLine)
$lblBusy = New-Lbl $form 576 338 300 22 9 'Regular' $Pal.Warn; $lblBusy.TextAlign = 'MiddleRight'; $lblBusy.Visible = $false

$content = New-Object System.Windows.Forms.Panel
$content.Location = New-Object System.Drawing.Point(24, 368); $content.Size = New-Object System.Drawing.Size(852, 236); $content.Padding = New-Object System.Windows.Forms.Padding(1); $content.BackColor = $Pal.Console
$form.Controls.Add($content)
$logWrap = New-Object System.Windows.Forms.Panel
$logWrap.Dock = 'Fill'; $logWrap.BackColor = $Pal.Console; $logWrap.Padding = New-Object System.Windows.Forms.Padding(12, 10, 4, 10)
$content.Controls.Add($logWrap)
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $true; $log.BorderStyle = 'None'; $log.Dock = 'Fill'
$log.BackColor = $Pal.Console; $log.ForeColor = $Pal.ConsoleInk
$logWrap.Controls.Add($log)
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.BorderStyle = 'None'; $list.HeaderStyle = 'Nonclickable'; $list.Dock = 'Fill'; $list.BackColor = $Pal.Card; $list.Visible = $false
Set-Font $list 9
[void]$list.Columns.Add('', 110); [void]$list.Columns.Add('', 230); [void]$list.Columns.Add('', 480)
$content.Controls.Add($list)

$lblFoot = New-Lbl $form 24 612 852 32 8.5 'Regular' $Pal.FootInk
$lblFoot.BackColor = $Pal.Bg

# ------------------------------------------------------------------------------------------ text, tabs, state
$script:tab = 'log'
$script:status = $null
$script:statusLoaded = $false
$script:busy = $false
function Show-Tab([string]$Which) {
    $script:tab = $Which
    $logWrap.Visible = ($Which -eq 'log'); $list.Visible = ($Which -eq 'check')
    $content.BackColor = $(if ($Which -eq 'log') { $Pal.Console } else { $Pal.Line })
    $tabLog.ForeColor = $(if ($Which -eq 'log') { $Pal.Ink } else { $Pal.Muted })
    $tabCheck.ForeColor = $(if ($Which -eq 'check') { $Pal.Ink } else { $Pal.Muted })
    $act = $(if ($Which -eq 'log') { $tabLog } else { $tabCheck })
    $tabLine.Location = New-Object System.Drawing.Point($act.Left, ($act.Bottom + 2)); $tabLine.Width = $act.Width
}
function Apply-Texts {
    $log.Font = $(if ($script:lang -eq 'zh') { New-Object System.Drawing.Font('Microsoft YaHei UI', ([single](9 * $script:fontMul))) } else { New-Object System.Drawing.Font('Consolas', ([single](9.5 * $script:fontMul))) })
    $form.Text = (T 'appName') + ' - ' + (T 'title')
    $lblTitle.Text = T 'title'; $lblSub.Text = (T 'subtitle') -f $Manifest.version
    $segZh.BackColor = $(if ($script:lang -eq 'zh') { $Pal.Card } else { $Pal.HeadLine }); $segZh.ForeColor = $(if ($script:lang -eq 'zh') { $Pal.Ink } else { $Pal.HeadMuted })
    $segEn.BackColor = $(if ($script:lang -eq 'en') { $Pal.Card } else { $Pal.HeadLine }); $segEn.ForeColor = $(if ($script:lang -eq 'en') { $Pal.Ink } else { $Pal.HeadMuted })
    $lblTgl.Text = T 'tglLabel'
    $tileT[0].Text = T 'tInstall'; $tileT[1].Text = T 'tFiles'; $tileT[2].Text = T 'tProfile'; $tileT[3].Text = T 'tCard'
    $btnCheck.Text = T 'bCheck'; $btnInstall.Text = T 'bInstall'; $btnReenroll.Text = T 'bReenroll'; $btnLogs.Text = T 'bLogs'; $btnTrial.Text = T 'bTrial'; $btnUninstall.Text = T 'bUninstall'
    $tabLog.Text = T 'tabLog'; $tabCheck.Text = T 'tabCheck'
    $tabCheck.Left = $tabLog.Right + [int](22 * $script:sf)
    $list.Columns[0].Text = T 'cStatus'; $list.Columns[1].Text = T 'cName'; $list.Columns[2].Text = T 'cDetail'
    $lblFoot.Text = T 'footer'
    Show-Tab $script:tab
}
function Fmt-Time([string]$t) { if ($t) { return $t.Replace('T', ' ') }; return '' }
function Set-Hero([string]$State, [string]$Title, [string]$Sub) {
    $script:dotColor = switch ($State) { 'ok' { $Pal.Ok } 'bad' { $Pal.Bad } 'warn' { $Pal.Warn } default { $Pal.Idle } }
    $lblHero.ForeColor = switch ($State) { 'ok' { $Pal.OkInk } 'bad' { $Pal.BadInk } default { $Pal.Ink } }
    $lblHero.Text = $Title; $lblHeroSub.Text = $Sub
    $dot.Invalidate()
}
function Apply-Enabled {
    $idle = -not $script:busy
    $inst = [bool]($script:status -and $script:status.installed)
    Set-BtnEnabled $btnCheck $idle
    Set-BtnEnabled $btnInstall ($idle -and $script:statusLoaded -and -not $inst)
    Set-BtnEnabled $btnReenroll ($idle -and $inst)
    Set-BtnEnabled $btnLogs ($idle -and $inst)
    Set-BtnEnabled $btnUninstall ($idle -and $inst)
    $st = $script:status
    $trialOk = [bool]($inst -and $st.experimental -and $st.enrolled -and $st.trial -and -not $st.trial.armed -and -not $st.trial.auto)
    $script:confirmMode = [bool]($trialOk -and $st.trial.result -eq 'verified')   # a verified trial: the button now confirms automatic unlock
    $btnTrial.Text = $(if ($script:confirmMode) { T 'bConfirm' } else { T 'bTrial' })
    $btnTrial.Visible = [bool]($inst -and $st.experimental)
    Set-BtnEnabled $btnTrial ($idle -and $trialOk)
    $script:tglEnabled = ($idle -and $inst)
    $tgl.Cursor = $(if ($script:tglEnabled) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default })
    $tgl.Invalidate()
}
function Render-Status {
    $s = $script:status
    if (-not $script:statusLoaded) { Set-Hero 'idle' (T 'heroLoading') '' }
    elseif (-not $s) { Set-Hero 'bad' (T 'statusFail') '' }
    elseif (-not $s.installed) { Set-Hero 'idle' (T 'heroNotInstalled') (T 'notInstalledSub') }
    elseif ($s.experimental -and -not ($s.trial -and $s.trial.auto)) {
        $t = $s.trial
        if (-not $s.enrolled -and $s.switch -ne 'on') { Set-Hero 'warn' (T 'heroExpOff') (T 'subExpOff') }
        elseif (-not $s.enrolled) { Set-Hero 'warn' (T 'heroExpRestart') (T 'subExpRestart') }
        elseif ($t.armed) { Set-Hero 'warn' (T 'heroExpArmed') (T 'subExpArmed') }
        elseif ($t.result -eq 'verified' -and $t.thisBoot) { Set-Hero 'ok' (T 'heroExpOk') (T 'subExpOk') }
        elseif ($t.result -eq 'verified') { Set-Hero 'idle' (T 'heroExpOkEarlier') (T 'subExpOkEarlier') }
        elseif ($t.result -eq 'failed') { Set-Hero 'bad' (T 'heroExpFail') ((T 'subExpFail') -f $t.stage) }
        else { Set-Hero 'idle' (T 'heroExpReady') (T 'subExpReady') }
    }
    else {
        $sw = switch ($s.switch) { 'on' { T 'swOn' } 'off' { T 'swOff' } 'on-not-first' { T 'swNotFirst' } default { '' } }
        $lr = $s.lastRun
        $hint = $(if ($s.switch -eq 'on') { T 'restartHint' } else { '' })
        if (-not $lr) { if ($s.switch -eq 'on') { Set-Hero 'warn' (T 'heroPending') ($sw + "`r`n" + (T 'noRun')) } else { Set-Hero 'idle' (T 'heroLocked') ($sw + "`r`n" + (T 'noRun')) } }
        elseif ($lr.thisBoot -and $lr.unlocked) { Set-Hero 'ok' (T 'heroUnlocked') ($sw + "`r`n" + ((T 'runThis') -f (Fmt-Time $lr.time))) }
        elseif ($lr.thisBoot) { Set-Hero 'bad' (T 'heroFailed') ($sw + "`r`n" + ((T 'runFailed') -f (Fmt-Time $lr.time), $lr.stage)) }
        else { Set-Hero 'idle' (T 'heroLocked') ($sw + "`r`n" + ((T 'runEarlier') -f (Fmt-Time $lr.time)) + $hint) }
    }
    $expPending = [bool]($s -and $s.installed -and $s.experimental -and -not ($s.trial -and $s.trial.auto))
    $script:tglOn = [bool]($s -and $s.switch -eq 'on')   # the switch is the boot entry, so it can always be turned off
    $state = $(if (-not ($s -and $s.installed)) { T 'tglNA' } elseif ($expPending -and $s.switch -eq 'on') { T 'tglWaiting' } elseif ($s.switch -eq 'on') { T 'tglOn' } elseif ($s.switch -eq 'on-not-first') { T 'tglNotFirst' } else { T 'tglOff' })
    $lblTglNote.Text = $state + "`r`n" + (T 'applies')
    if ($s -and $s.installed) {
        $tileV[0].Text = (T 'vInstalled') -f $(if ($s.mode -eq 'usb') { T 'modeUsb' } else { T 'modePart' }); $tileV[0].ForeColor = $Pal.Ink
        $tileV[1].Text = $(if ($s.filesOk) { T 'vComplete' } else { T 'vIncomplete' }); $tileV[1].ForeColor = $(if ($s.filesOk) { $Pal.Ink } else { $Pal.BadInk })
        $tileV[2].Text = $(if ($s.enrolled) { T 'vEnrolled' } else { T 'vNotEnrolled' }); $tileV[2].ForeColor = $Pal.Ink
    } else {
        $tileV[0].Text = $(if ($s) { T 'vNotInstalled' } else { '—' }); $tileV[0].ForeColor = $Pal.Muted
        $tileV[1].Text = '—'; $tileV[2].Text = '—'; $tileV[1].ForeColor = $Pal.Muted; $tileV[2].ForeColor = $Pal.Muted
    }
    $tileT[3].Text = $(if ($s -and $s.experimental) { T 'tCardExp' } else { T 'tCard' })
    Fit-Tile $tileV[3] $(if ($s -and $s.gpu -and $s.gpu.name) { ([string]$s.gpu.name) -replace '^GeForce ', '' } else { '—' })
    Apply-Enabled
}

function Append-Log([string]$Line) {
    if ($Line) { $log.AppendText($Line); $log.SelectionStart = $log.TextLength; $log.ScrollToCaret() }
}
function Set-Busy([bool]$Busy) {
    $script:busy = $Busy
    $lblBusy.Visible = $Busy; $lblBusy.Text = '●  ' + (T 'busy')
    Apply-Enabled
}

# ------------------------------------------------------------------------------------------ run core.ps1 in a hidden process; its output goes to a file that a timer reads
$work = Join-Path $env:TEMP ('gpuunlock-gui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$script:proc = $null
$script:outFile = $null
$script:errFile = $null
$script:readPos = 0
$script:onDone = $null
$script:allText = ''
$script:spin = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
function Read-New {
    if (-not $script:outFile -or -not (Test-Path -LiteralPath $script:outFile)) { return }
    $fs = [System.IO.File]::Open($script:outFile, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt $script:readPos) {
            $fs.Seek($script:readPos, 'Begin') | Out-Null
            $buf = New-Object byte[] ($fs.Length - $script:readPos)
            [void]$fs.Read($buf, 0, $buf.Length)
            $script:readPos = $fs.Length
            $chunk = [System.Text.Encoding]::UTF8.GetString($buf)
            $script:allText += $chunk
            $show = ($chunk -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('@@JSON@@') }) -join "`r`n"
            if ($show) { Append-Log ($show + "`r`n") }
        }
    } finally { $fs.Close() }
}
$timer.Add_Tick({
    Read-New
    $script:spin = ($script:spin + 1) % 4
    $lblBusy.Text = '●  ' + (T 'busy') + ('.' * $script:spin)
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop(); Read-New
        try { if ($script:errFile -and (Test-Path -LiteralPath $script:errFile)) { $err = (Get-Content -LiteralPath $script:errFile -Raw -ErrorAction SilentlyContinue); if ($err -and $err.Trim()) { Append-Log ($err.Trim() + "`r`n") } } } catch { }
        $code = $script:proc.ExitCode
        if ($null -eq $code) { $code = $(if ($script:allText -match '\[ERROR\]') { 1 } else { 0 }) }
        $cb = $script:onDone; $script:onDone = $null; $script:proc = $null
        Set-Busy $false
        if ($cb) { & $cb $code $script:allText }
    }
})
function Run-Core([string]$CoreArgs, [scriptblock]$Done) {
    $script:outFile = Join-Path $work ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $script:readPos = 0; $script:allText = ''; $script:onDone = $Done
    Set-Busy $true
    $script:errFile = $script:outFile + '.err'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Core + '" ' + $CoreArgs + ' -Lang ' + $script:lang + ' -NoPause'
    $script:proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
    $null = $script:proc.Handle   # without this, ExitCode comes back empty and every success looks like a failure
    $timer.Start()
}
function Get-Json([string]$Raw) {
    $m = [regex]::Matches($Raw, '@@JSON@@(.+)')
    if ($m.Count -eq 0) { return $null }
    try { return ($m[$m.Count - 1].Groups[1].Value | ConvertFrom-Json) } catch { return $null }
}
function Refresh-Status {
    if ($SnapshotStatus) { $script:status = (Get-Content -LiteralPath $SnapshotStatus -Raw -Encoding UTF8 | ConvertFrom-Json); $script:statusLoaded = $true; Render-Status; return }   # layout snapshots only
    Run-Core 'status -Json' { param($code, $raw) $script:status = Get-Json $raw; $script:statusLoaded = $true; Render-Status }
}
function Ask([string]$Key, [string]$Icon = 'Question') { return [System.Windows.Forms.MessageBox]::Show((T $Key), (T 'appName'), 'YesNo', $Icon) }
function Restart-Soon { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 10 /c "GPU Unlock: restarting"' -WindowStyle Hidden }

# ------------------------------------------------------------------------------------------ language switch
function Set-Lang([string]$L) {
    if ($L -eq $script:lang) { return }
    $script:lang = $L
    try { if (-not (Test-Path $PrefPath)) { New-Item -Path $PrefPath -Force | Out-Null }; Set-ItemProperty -Path $PrefPath -Name 'Lang' -Value $L } catch { }
    $form.SuspendLayout()
    Apply-Fonts; Apply-Texts; Render-Status
    $list.Items.Clear()   # check results came from core.ps1 in the other language; run the check again to refresh them
    $form.ResumeLayout()
    Append-Log ((T 'langChanged') + "`r`n")
}
$segZh.Add_Click({ Set-Lang 'zh' })
$segEn.Add_Click({ Set-Lang 'en' })
$tabLog.Add_Click({ Show-Tab 'log' })
$tabCheck.Add_Click({ Show-Tab 'check' })

# ------------------------------------------------------------------------------------------ actions
$tgl.Add_Click({
    if (-not $script:tglEnabled) { return }
    $script:turnOn = -not $script:tglOn
    $st = $script:status
    $script:turnOnWaiting = [bool]($script:turnOn -and $st -and $st.experimental -and -not ($st.trial -and ($st.trial.auto -or $st.trial.result -eq 'verified')))
    Show-Tab 'log'; $log.Clear()
    Run-Core $(if ($script:turnOn) { 'enable' } else { 'disable' }) {
        param($c, $raw)
        Refresh-Status
        if ($c -eq 0) { if ((Ask $(if ($script:turnOnWaiting) { 'msgOnExp' } elseif ($script:turnOn) { 'msgOn' } else { 'msgOff' })) -eq 'Yes') { Restart-Soon } }
    }
})
$btnCheck.Add_Click({
    $list.Items.Clear(); Show-Tab 'check'
    Run-Core 'check -Json' {
        param($c, $raw)
        $r = Get-Json $raw
        if ($r) {
            $n = @{ ok = 0; warn = 0; fail = 0 }
            foreach ($x in @($r)) {
                $st = [string]$x.status; if (-not $n.ContainsKey($st)) { $st = 'fail' }; $n[$st]++
                $it = New-Object System.Windows.Forms.ListViewItem(('●  ' + $(switch ($st) { 'ok' { T 'sOk' } 'warn' { T 'sWarn' } default { T 'sFail' } })))
                $it.UseItemStyleForSubItems = $false
                $it.ForeColor = $(switch ($st) { 'ok' { $Pal.Ok } 'warn' { $Pal.Warn } default { $Pal.Bad } })
                $s1 = $it.SubItems.Add([string]$x.name); $s1.ForeColor = $Pal.Ink
                $s2 = $it.SubItems.Add([string]$x.detail); $s2.ForeColor = $Pal.Muted
                [void]$list.Items.Add($it)
            }
            Append-Log (((T 'checkSummary') -f $n.ok, $n.warn, $n.fail) + "`r`n")
        }
        Refresh-Status
    }
})
$btnTrial.Add_Click({
    if ($script:confirmMode) {
        Show-Tab 'log'; $log.Clear()
        Run-Core 'enable' { param($c, $raw) Refresh-Status; if ($c -eq 0) { if ((Ask 'msgOn') -eq 'Yes') { Restart-Soon } } }
        return
    }
    if ((Ask 'trialQ' 'Warning') -ne 'Yes') { return }
    Show-Tab 'log'; $log.Clear()
    Run-Core 'trial' { param($c, $raw) Refresh-Status; if ($c -eq 0) { if ((Ask 'trialDoneQ') -eq 'Yes') { Restart-Soon } } }
})
$btnLogs.Add_Click({ Show-Tab 'log'; $log.Clear(); Append-Log ((T 'bootLogNote') + "`r`n"); Run-Core 'logs' { param($c, $raw) } })
$btnReenroll.Add_Click({ if ((Ask 'reenrollQ') -eq 'Yes') { Show-Tab 'log'; $log.Clear(); Run-Core 'reenroll' { param($c, $raw) Refresh-Status } } })
$btnUninstall.Add_Click({ if ((Ask 'uninstallQ' 'Warning') -eq 'Yes') { Show-Tab 'log'; $log.Clear(); Run-Core 'uninstall' { param($c, $raw) Refresh-Status } } })

# ------------------------------------------------------------------------------------------ install dialog
function New-InstallDialog($Cand) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.AutoScaleMode = 'None'
    $dlg.Text = T 'dlgTitle'; $dlg.ClientSize = New-Object System.Drawing.Size(620, 486); $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.BackColor = $Pal.Card; $dlg.Font = F 9
    $exp = [bool]($Cand -and $Cand.gpu -and $Cand.gpu.tier -ne 'verified')
    $dx = $(if ($exp) { 64 } else { 0 })   # extra height for the experimental-card notice
    $hd = New-Lbl $dlg 22 16 576 30 13 'Bold' -NoTrack; $hd.Text = T 'dlgHead'
    $rP = New-Object System.Windows.Forms.RadioButton; $rP.Location = New-Object System.Drawing.Point(24, 58); $rP.Size = New-Object System.Drawing.Size(572, 24); $rP.Font = F 10 'Bold'; $rP.Text = T 'optPart'; $rP.Checked = $true
    $cP = New-Object System.Windows.Forms.ComboBox; $cP.DropDownStyle = 'DropDownList'; $cP.Location = New-Object System.Drawing.Point(46, 86); $cP.Size = New-Object System.Drawing.Size(550, 26); $cP.Font = F 9.5
    $nP = New-Lbl $dlg 46 116 550 40 8.5 'Regular' $Pal.Muted -NoTrack; $nP.Text = T 'optPartNote'
    $rU = New-Object System.Windows.Forms.RadioButton; $rU.Location = New-Object System.Drawing.Point(24, 164); $rU.Size = New-Object System.Drawing.Size(572, 24); $rU.Font = F 10 'Bold'; $rU.Text = T 'optUsb'
    $cU = New-Object System.Windows.Forms.ComboBox; $cU.DropDownStyle = 'DropDownList'; $cU.Location = New-Object System.Drawing.Point(46, 192); $cU.Size = New-Object System.Drawing.Size(550, 26); $cU.Font = F 9.5; $cU.Enabled = $false
    $nU = New-Lbl $dlg 46 222 550 22 8.5 'Regular' $Pal.Muted -NoTrack; $nU.Text = T 'optUsbNote'
    $box = New-Card $dlg 24 254 572 (120 + $dx) $Pal.Soft
    $st = New-Lbl $box 14 10 546 (104 + $dx) 9 'Regular' $Pal.Ink -NoTrack; $st.Text = T 'steps'
    if ($exp) { $st.Text = (T 'stepsExp') + "`r`n`r`n" + ((T 'expNote') -f $Cand.gpu.name) }
    $chkEnable = New-Object System.Windows.Forms.CheckBox; $chkEnable.Location = New-Object System.Drawing.Point(24, (386 + $dx)); $chkEnable.Size = New-Object System.Drawing.Size(572, 22); $chkEnable.Font = F 9; $chkEnable.Text = $(if ($exp) { T 'chkEnableExp' } else { T 'chkEnable' }); $chkEnable.Checked = $true
    $chkRisk = New-Object System.Windows.Forms.CheckBox; $chkRisk.Location = New-Object System.Drawing.Point(24, (410 + $dx)); $chkRisk.Size = New-Object System.Drawing.Size(572, 22); $chkRisk.Font = F 9 'Bold'; $chkRisk.Text = T 'chkRisk'
    $chkExp = New-Object System.Windows.Forms.CheckBox; $chkExp.Location = New-Object System.Drawing.Point(24, (434 + $dx)); $chkExp.Size = New-Object System.Drawing.Size(572, 22); $chkExp.Font = F 9 'Bold'; $chkExp.Text = T 'chkExp'
    $ok = New-Btn $dlg 372 (440 + $dx + $(if ($exp) { 28 } else { 0 })) 116 34 'primary' -NoTrack; $ok.Text = T 'bGo'; $ok.DialogResult = 'OK'
    $cancel = New-Btn $dlg 496 (440 + $dx + $(if ($exp) { 28 } else { 0 })) 100 34 -NoTrack; $cancel.Text = T 'bCancel'; $cancel.DialogResult = 'Cancel'
    Set-BtnEnabled $ok $false
    $pLetters = New-Object System.Collections.ArrayList; $uLetters = New-Object System.Collections.ArrayList
    if ($Cand) {
        $first = $true
        foreach ($x in @($Cand.partition)) { [void]$cP.Items.Add((((T 'partItem') -f $x.Letter, $x.FreeGB) + $(if ($x.IsSystem) { T 'sysSuffix' } else { '' }) + $(if ($first) { T 'recSuffix' } else { '' }))); [void]$pLetters.Add([string]$x.Letter); $first = $false }
        foreach ($x in @($Cand.usb)) { [void]$cU.Items.Add(((T 'usbItem') -f $x.Letter, $x.Label, $x.FreeMB)); [void]$uLetters.Add([string]$x.Letter) }
    }
    if ($cP.Items.Count -gt 0) { $cP.SelectedIndex = 0 } else { [void]$cP.Items.Add((T 'noneFound')); $cP.SelectedIndex = 0; $rP.Enabled = $false; $cP.Enabled = $false; $rU.Checked = $true }
    if ($cU.Items.Count -gt 0) { $cU.SelectedIndex = 0; $cU.Enabled = $rU.Checked } else { [void]$cU.Items.Add((T 'noneFound')); $cU.SelectedIndex = 0; $rU.Enabled = $false; $cU.Enabled = $false }
    # these handlers fire after this function has returned, so they carry their own copies of the controls
    $okOn = $Pal.Primary; $okOff = $Pal.Disabled
    $rP.Add_CheckedChanged({ $cP.Enabled = $rP.Checked; $cU.Enabled = -not $rP.Checked }.GetNewClosure())
    $refresh = { $go = $chkRisk.Checked -and (-not $exp -or $chkExp.Checked) -and ($rP.Enabled -or $rU.Enabled); $ok.Enabled = $go; $ok.BackColor = $(if ($go) { $okOn } else { $okOff }) }.GetNewClosure()
    $chkRisk.Add_CheckedChanged($refresh); $chkExp.Add_CheckedChanged($refresh)
    foreach ($ctl in $rP, $cP, $rU, $cU, $chkEnable, $chkRisk) { $dlg.Controls.Add($ctl) }
    if ($exp) { $dlg.Controls.Add($chkExp) }
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Scale((New-Object System.Drawing.SizeF([single]$script:sf, [single]$script:sf))); $dlg.ClientSize = New-Object System.Drawing.Size([int](620 * $script:sf), [int]((486 + $dx + $(if ($exp) { 28 } else { 0 })) * $script:sf))
    return @{ Form = $dlg; Exp = $exp; rP = $rP; cP = $cP; rU = $rU; cU = $cU; Enable = $chkEnable; PL = $pLetters; UL = $uLetters }
}
$btnInstall.Add_Click({
    Show-Tab 'log'; $log.Clear(); Append-Log ((T 'readingDisks') + "`r`n")
    Run-Core 'candidates -Json' {
        param($c, $raw)
        $d = New-InstallDialog (Get-Json $raw)
        $answer = $d.Form.ShowDialog($form)
        if ($answer -eq 'OK') {
            $argsText = 'install'
            if ($d.rP.Checked) { $argsText += ' -Mode partition -TargetVolume ' + $d.PL[$d.cP.SelectedIndex] }
            else { $argsText += ' -Mode usb -Drive ' + $d.UL[$d.cU.SelectedIndex] + ':' }
            if (-not $d.Enable.Checked) { $argsText += ' -NoEnable' }
            if ($d.Exp) { $argsText += ' -AcceptExperimental' }
            $script:expInstall = $d.Exp
            $d.Form.Dispose()
            $log.Clear()
            Run-Core $argsText {
                param($code, $raw2)
                Refresh-Status
                if ($code -eq 0) { if ((Ask $(if ($script:expInstall) { 'installedQExp' } else { 'installedQ' }) 'Information') -eq 'Yes') { Restart-Soon } }
                else { [System.Windows.Forms.MessageBox]::Show((T 'installFailed'), (T 'appName'), 'OK', 'Error') | Out-Null }
            }
        } else { $d.Form.Dispose(); Refresh-Status }
    }
})

# ------------------------------------------------------------------------------------------ start
$form.Scale((New-Object System.Drawing.SizeF([single]$script:sf, [single]$script:sf)))
$form.ClientSize = New-Object System.Drawing.Size([int](900 * $script:sf), [int](650 * $script:sf))
Apply-Texts
Render-Status
$form.Add_Shown({
    $list.Columns[0].Width = [int](110 * $script:sf); $list.Columns[1].Width = [int](230 * $script:sf)
    $list.Columns[2].Width = [int]($content.ClientSize.Width - $list.Columns[0].Width - $list.Columns[1].Width - 24 * $script:sf)
    $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = New-Object System.Drawing.Size(1, [int](26 * $script:sf)); $list.SmallImageList = $il
    Apply-Texts
    Append-Log ((T 'ready') + "`r`n")
    Refresh-Status
})
$form.Add_FormClosing({ try { $timer.Stop() } catch { }; try { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue } catch { } })

if ($Snapshot) {
    function Save-Shot($Win, [string]$Path) {
        # the snapshot desktop can be smaller than the scaled window, so the client area is composed control by control
        $w = [int](($Win.Controls | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum + 24 * $script:sf)
        $h = [int](($Win.Controls | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum + 16 * $script:sf)
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear($Win.BackColor); $g.Dispose()
        for ($i = $Win.Controls.Count - 1; $i -ge 0; $i--) { $c = $Win.Controls[$i]; if ($c.Visible) { $c.DrawToBitmap($bmp, $c.Bounds) } }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    }
    $script:snapStage = 0
    $snapTimer = New-Object System.Windows.Forms.Timer; $snapTimer.Interval = 600
    $snapTimer.Add_Tick({
        if ($script:busy) { return }
        switch ($script:snapStage) {
            0 { if ($script:statusLoaded) { $script:snapStage = 1 } }
            1 { Save-Shot $form $Snapshot; $script:snapStage = 2; if ($SnapshotCheck) { $btnCheck.PerformClick() } }
            2 {
                if ($SnapshotCheck) { Save-Shot $form ($Snapshot -replace '\.png$', '-check.png') }
                $script:snapStage = 3
                if ($SnapshotDialog) { Run-Core 'candidates -Json' { param($c, $raw) try { $cj = Get-Json $raw; if ($SnapshotExperimental) { $cj.gpu = [pscustomobject]@{ id = '2705'; name = 'GeForce RTX 4070 Ti SUPER'; tier = 'experimental' } }; $d = New-InstallDialog $cj; $d.Form.Show(); [System.Windows.Forms.Application]::DoEvents(); Save-Shot $d.Form $SnapshotDialog; Set-Content -LiteralPath ($SnapshotDialog + '.txt') -Encoding UTF8 -Value ('partition: ' + $d.cP.Text + ' | usb: ' + $d.cU.Text + ' | letters: ' + ($d.PL -join ',')); $d.Form.Close() } catch { Set-Content -LiteralPath ($SnapshotDialog + '.err') -Value ($_ | Out-String) } } }
            }
            3 { Set-Lang $(if ($script:lang -eq 'zh') { 'en' } else { 'zh' }); [System.Windows.Forms.Application]::DoEvents(); Save-Shot $form ($Snapshot -replace '\.png$', '-switched.png'); $snapTimer.Stop(); $form.Close() }
        }
    })
    $snapTimer.Start()
}
if ($Snapshot) { [System.Windows.Forms.Application]::Run($form) } else { [void]$form.ShowDialog() }   # a modal window is refused in a non-interactive session
