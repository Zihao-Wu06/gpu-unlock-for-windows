<#
GPU Unlock installer core  (GeForce RTX 40 / Windows preboot unlock)
Every action the GUI offers is implemented here, so it can also be run from a console:
  core.ps1 check | download | assets | install | trial | enable | disable | status | update | reenroll | uninstall | logs
Options:  -Mode partition|usb   -Drive E:   -TargetVolume H   -Cache <dir>   -DryRun   -Json   -Yes   -NoEnable   -NoPause   -Lang en|zh   -AcceptExperimental
EXPERIMENTAL software. It changes the firmware boot order and (partition mode) shrinks a volume. Read README.txt first.
#>
param(
    [Parameter(Position = 0)][ValidateSet('check', 'download', 'assets', 'install', 'enable', 'disable', 'status', 'update', 'reenroll', 'uninstall', 'logs', 'version', 'candidates', 'trial')][string]$Action = 'status',
    [ValidateSet('partition', 'usb')][string]$Mode = 'partition',
    [string]$Drive = '',
    [string]$TargetVolume = '',
    [string]$Cache = '',
    [switch]$DryRun,
    [switch]$Json,
    [switch]$Yes,
    [switch]$NoEnable,
    [switch]$NoPause,
    [switch]$AcceptExperimental,
    [ValidateSet('', 'en', 'zh')][string]$Lang = ''
)
$ErrorActionPreference = 'Stop'
# message language: -Lang, else the saved choice (HKCU:\Software\GPU-Unlock Lang), else the Windows display language
if (-not $Lang) {
    try { $savedLang = (Get-ItemProperty -Path 'HKCU:\Software\GPU-Unlock' -ErrorAction Stop).Lang; if ($savedLang -eq 'en' -or $savedLang -eq 'zh') { $Lang = $savedLang } } catch { }
    if (-not $Lang) { if ((Get-Culture).Name -like 'zh*' -or (Get-UICulture).Name -like 'zh*') { $Lang = 'zh' } else { $Lang = 'en' } }
}
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { }
$Root = $PSScriptRoot
$Payload = Join-Path $Root 'payload'
$Manifest = Get-Content -LiteralPath (Join-Path $Payload 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$EntryName = $Manifest.entryName
$PartLabel = $Manifest.partition.label
$PartBytes = [int64]$Manifest.partition.sizeMiB * 1MB
$ShrinkBytes = [int64]$Manifest.partition.shrinkMiB * 1MB
$RegPath = 'HKLM:\SOFTWARE\GPU-Unlock'
$DataDir = Join-Path $env:ProgramData 'GPU-Unlock'
if (-not $Cache) { $Cache = Join-Path $DataDir 'cache' }
$LogFile = Join-Path $DataDir 'installer.log'

# ------------------------------------------------------------------------------------------ helpers
function Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }; Add-Content -LiteralPath $LogFile -Value ((Get-Date).ToString('s') + ' ' + $line) -Encoding UTF8 } catch { }
}
function Fail([string]$Message) { Log $Message 'ERROR'; throw $Message }
function L([string]$En, [string]$Zh) { if ($Lang -eq 'zh') { return $Zh }; return $En }
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Emit-Json($Object) { Write-Host ('@@JSON@@' + ($Object | ConvertTo-Json -Depth 6 -Compress)) }
function Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }
function Get-Reg([string]$Name) { try { (Get-ItemProperty -Path $RegPath -ErrorAction Stop).$Name } catch { $null } }
function Set-Reg([string]$Name, $Value) { if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }; Set-ItemProperty -Path $RegPath -Name $Name -Value $Value }

function Get-EntryGuid {
    $g = Get-Reg 'EntryGuid'
    if ($g) { return $g }
    $raw = (bcdedit /enum all) -join "`n"
    foreach ($block in ($raw -split '(?m)^\s*$')) {
        if ($block.Contains($EntryName)) {
            $m = [regex]::Match($block, '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
            if ($m.Success) { return $m.Value }
        }
    }
    return $null
}
function Get-DisplayOrder {
    $order = @(); $capture = $false
    foreach ($line in (bcdedit /enum '{fwbootmgr}')) {
        if ($line -match '^\s*displayorder\s+(\{.+\})\s*$') { $order += $Matches[1]; $capture = $true; continue }
        if ($capture -and $line -match '^\s+(\{.+\})\s*$') { $order += $Matches[1]; continue }
        $capture = $false
    }
    return $order
}
function Get-InstallVolume {
    $vp = Get-Reg 'VolumePath'
    if ($vp) { $v = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $vp } | Select-Object -First 1; if ($v) { return $v } }
    $v = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $PartLabel -and $_.FileSystem -eq 'FAT32' })
    if ($v.Count -eq 1) { return $v[0] }
    return $null
}
function Test-Files($Volume) {
    if (-not $Volume) { return $false }
    $efi = Join-Path $Volume.Path 'EFI\GPUUNLOCK\gpuunlock.efi'
    $gsp = Join-Path $Volume.Path 'GPU-UNLOCK\ASSETS\gsp_ga10x.bin'
    return ((Test-Path -LiteralPath $efi) -and (Test-Path -LiteralPath $gsp) -and -not (Test-Path -LiteralPath (Join-Path $Volume.Path 'EFI\Microsoft')))
}
function Get-FreeLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($c in 'Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') { if ($used -notcontains $c) { return $c } }
    Fail (L 'No free drive letter available.' '没有可用的盘符。')
}

# ------------------------------------------------------------------------------------------ cards and per-card state
function Find-Gpus {
    # supported cards present in this PC (manifest table: PCI device id, name, tier verified|experimental, VRAM range)
    $found = @()
    foreach ($v in @(Get-CimInstance Win32_VideoController)) {
        if ($v.PNPDeviceID -match 'VEN_10DE&DEV_([0-9A-F]{4})') {
            $id = $Matches[1].ToLower()
            $g = @($Manifest.supported.gpus | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            if ($g) { $found += [pscustomobject]@{ Gpu = $g; Pnp = [string]$v.PNPDeviceID } }
        }
    }
    return $found
}
function Get-GpuInfo {
    $det = @(Find-Gpus)
    if ($det.Count -eq 1) { return [pscustomobject]@{ id = $det[0].Gpu.id; name = [string]$det[0].Gpu.name; tier = [string]$det[0].Gpu.tier } }
    $id = Get-Reg 'GpuId'
    if ($id) { return [pscustomobject]@{ id = [string]$id; name = [string](Get-Reg 'GpuName'); tier = [string](Get-Reg 'GpuTier') } }
    return $null
}
function Get-VolFile($Vol, [string]$Name) { return (Join-Path $Vol.Path ('GPU-UNLOCK\' + $Name)) }
function Write-VolFile($Vol, [string]$Name, [string]$Text) { [System.IO.File]::WriteAllText((Get-VolFile $Vol $Name), $Text, (New-Object System.Text.ASCIIEncoding)) }
function Remove-VolFile($Vol, [string]$Name) { $f = Get-VolFile $Vol $Name; if (Test-Path -LiteralPath $f) { [System.IO.File]::Delete($f); return $true }; return $false }
function Sync-VolumeToDisk($Vol) { try { fsutil volume dismount ($Vol.Path.TrimEnd('\')) | Out-Null } catch { } }   # the boot program reads these files at the next start
function Get-ProfileInfo($Vol) {
    $f = Get-VolFile $Vol 'PROFILE.TXT'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $f -Encoding ASCII)) { if ($line -match '^\s*([a-z0-9_]+)\s*=\s*(\S+)\s*$') { $h[$Matches[1]] = $Matches[2] } }
    return $h
}
function ConvertTo-ProfileNumber([string]$Text) {
    # same number forms as the boot program's profile parser: decimal, or 0x-prefixed hex
    if ($Text -match '^0[xX]([0-9a-fA-F]{1,8})$') { return [Convert]::ToUInt32($Matches[1], 16) }
    if ($Text -match '^[0-9]{1,9}$') { return [uint32]$Text }
    return $null
}
function Remove-BootEntry([string]$Guid) {
    # removes the firmware boot entry and proves it is gone; a failed delete must not be silently ignored
    $ErrorActionPreference = 'Continue'
    if ((Get-DisplayOrder) -contains $Guid) { bcdedit /set '{fwbootmgr}' displayorder $Guid /remove | Out-Null }
    bcdedit /delete $Guid | Out-Null
    $code = $LASTEXITCODE
    # "bcdedit /enum {guid}" exits 0 even for an entry that does not exist, so look for the guid in the full listing instead
    if (((bcdedit /enum all | Out-String).ToLower()).Contains($Guid.ToLower())) { Fail (L "could not delete the boot entry $Guid (bcdedit exit code $code)" "无法删除启动项 $Guid (bcdedit 退出码 $code)") }
}
function Release-InstallVolume {
    # leave the letterless volume dismounted after every action that touched it: it cannot go stale under a hibernated
    # Windows session (Fast Startup), and the boot program reads data that was really written
    if ($Action -in 'status', 'logs', 'enable', 'disable', 'trial', 'reenroll', 'update' -and -not $DryRun) {
        try { $dv = Get-InstallVolume; if ($dv) { Sync-VolumeToDisk $dv } } catch { }
    }
}
function Get-CardTier($Vol) {
    # 'verified' only for a card in the verified tier whose profile does not force the trial flow
    $g = Get-GpuInfo
    if (-not $g -or $g.tier -ne 'verified') { return 'experimental' }
    $p = $(if ($Vol) { Get-ProfileInfo $Vol } else { $null })
    if ($p -and $p.ContainsKey('trial_required')) {
        $tr = ConvertTo-ProfileNumber $p['trial_required']
        if ($null -eq $tr -or $tr -ne 0) { return 'experimental' }   # any value the boot program could read as "on" (or cannot read) means the stricter flow
    }
    return 'verified'
}
function Test-RunThisBoot([datetime]$When) {
    # A run belongs to this boot when it happened after the midpoint between the previous Windows start and this one (the unlock
    # runs seconds before Windows starts). A fixed look-back window wrongly counted the previous boot's run after a quick restart.
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $this = ($When -ge $boot.AddSeconds(-90))
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } -MaxEvents 2 -ErrorAction Stop)
        if ($ev.Count -ge 2) { $mid = $ev[1].TimeCreated.AddSeconds(($ev[0].TimeCreated - $ev[1].TimeCreated).TotalSeconds / 2); $this = ($When -gt $mid) }
    } catch { }
    return $this
}
function Get-TrialInfo($Vol) {
    # state of the trial flow for an experimental card: armed (one trial queued), auto (confirmed), and the newest trial report
    $dir = Join-Path $Vol.Path 'GPU-UNLOCK'
    $t = [pscustomobject]@{ armed = (Test-Path -LiteralPath (Join-Path $dir 'ARMED.TXT')); auto = (Test-Path -LiteralPath (Join-Path $dir 'AUTO.TXT')); result = 'none'; time = $null; stage = ''; thisBoot = $false }
    $reports = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'RUN*' } | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'REPORT.TXT') -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending)
    # only a trial that ran after the current profile was written counts: re-enrolling (a new card, a new BIOS) starts over
    $pf = Get-Item -LiteralPath (Join-Path $dir 'PROFILE.TXT') -ErrorAction SilentlyContinue
    if ($pf) { $reports = @($reports | Where-Object { $_.LastWriteTime -gt $pf.LastWriteTime }) } else { $reports = @() }   # no profile: nothing counts
    foreach ($r in $reports) {
        $lines = @(Get-Content -LiteralPath $r.FullName -Encoding ASCII)
        if (@($lines | Where-Object { $_ -match '^TRIAL RUN:' }).Count -eq 0) { continue }
        $final = [string]($lines | Where-Object { $_ -match '^FINAL ' } | Select-Object -Last 1)
        $ok = (@($lines | Where-Object { $_ -match 'POST-GOP register_unlock_verified=1' }).Count -gt 0) -and ($final -match 'status=0 stage=post-unlock-handoff attempted=1')
        $t.result = $(if ($ok) { 'verified' } else { 'failed' })
        $t.time = $r.LastWriteTime.ToString('s'); $t.stage = $(if ($final -match 'stage=(\S+)') { $Matches[1] } else { '' })
        $t.thisBoot = (Test-RunThisBoot $r.LastWriteTime)
        break
    }
    return $t
}
function Set-EntryFirst([string]$Guid) {
    $order = Get-DisplayOrder
    if ($order.Count -gt 0 -and $order[0] -eq $Guid) { return $false }
    if ($order -contains $Guid) { bcdedit /set '{fwbootmgr}' displayorder $Guid /remove | Out-Null }
    bcdedit /set '{fwbootmgr}' displayorder $Guid /addfirst | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail (L 'bcdedit failed' 'bcdedit 执行失败') }
    return $true
}

# ------------------------------------------------------------------------------------------ system check
$script:ShrinkCache = @{}
function Get-ShrinkCandidates([int]$Max = 3, [string]$Only = '', [switch]$Quick) {
    # Get-PartitionSupportedSize is slow (seconds to a minute per large volume), so volumes are screened with cheap checks
    # first, ordered by preference, and only analysed until $Max usable ones are found. Results are cached for this run.
    $sysLetter = $env:SystemDrive.TrimEnd(':')
    $sysDisk = (Get-Partition -DriveLetter $sysLetter -ErrorAction SilentlyContinue).DiskNumber
    $pre = @()
    foreach ($v in (Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' -and $_.DriveLetter })) {
        if ($Only -and [string]$v.DriveLetter -ne $Only) { continue }
        if ($v.SizeRemaining -lt 2GB) { continue }
        try {
            $p = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop
            $d = Get-Disk -Number $p.DiskNumber
            if ($d.PartitionStyle -ne 'GPT' -or $d.BusType -eq 'USB') { continue }
            $bl = $null; try { $bl = (Get-BitLockerVolume -MountPoint ($v.DriveLetter + ':') -ErrorAction Stop).ProtectionStatus } catch { }
            if ($bl -eq 'On' -or $bl -eq 1) { continue }
            $isSys = ($v.DriveLetter -eq $sysLetter)
            $pre += [pscustomobject]@{ Letter = [string]$v.DriveLetter; DiskNumber = $p.DiskNumber; SystemDisk = ($p.DiskNumber -eq $sysDisk); IsSystem = $isSys; FreeGB = [math]::Round($v.SizeRemaining / 1GB, 1); Size = $p.Size
                Order = $(if ($p.DiskNumber -eq $sysDisk -and -not $isSys) { 0 } elseif (-not $isSys) { 1 } else { 2 }) }
        } catch { }
    }
    $ordered = @($pre | Sort-Object Order, @{ Expression = 'FreeGB'; Descending = $true })
    if ($Quick) { return @($ordered | ForEach-Object { [pscustomobject]@{ Letter = $_.Letter; DiskNumber = $_.DiskNumber; SystemDisk = $_.SystemDisk; IsSystem = $_.IsSystem; ShrinkableGB = $null; FreeGB = $_.FreeGB } }) }
    $out = @()
    foreach ($c in $ordered) {
        if ($out.Count -ge $Max) { break }
        if (-not $script:ShrinkCache.ContainsKey($c.Letter)) {
            Log (L "analysing $($c.Letter): to see how much it can shrink (can take up to a minute on a big volume)..." "正在分析 $($c.Letter): 卷能缩小多少 (大卷可能要一分钟)...")
            try { $sup = Get-PartitionSupportedSize -DriveLetter $c.Letter -ErrorAction Stop; $script:ShrinkCache[$c.Letter] = ($c.Size - $sup.SizeMin) } catch { $script:ShrinkCache[$c.Letter] = -1 }
        }
        $room = $script:ShrinkCache[$c.Letter]
        if ($room -ge ($ShrinkBytes + 64MB)) { $out += [pscustomobject]@{ Letter = $c.Letter; DiskNumber = $c.DiskNumber; SystemDisk = $c.SystemDisk; IsSystem = $c.IsSystem; ShrinkableGB = [math]::Round($room / 1GB, 1); FreeGB = $c.FreeGB } }
    }
    return @($out)
}

function Invoke-Check {
    $r = New-Object System.Collections.ArrayList
    function Add([string]$Name, [string]$Status, [string]$Detail) { [void]$r.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail }) }
    Add (L 'Administrator' '管理员') $(if (Test-Admin) { 'ok' } else { 'fail' }) $(if (Test-Admin) { L 'running elevated' '已以管理员身份运行' } else { L 'run as administrator' '请以管理员身份运行' })
    $os = Get-CimInstance Win32_OperatingSystem
    $okOs = ([Environment]::Is64BitOperatingSystem -and [version]$os.Version -ge [version]'10.0')
    Add 'Windows 10/11 x64' $(if ($okOs) { 'ok' } else { 'fail' }) "$($os.Caption) $($os.Version)"
    $uefi = $false; try { bcdedit /enum '{fwbootmgr}' | Out-Null; $uefi = ($LASTEXITCODE -eq 0) } catch { }
    Add (L 'UEFI boot' 'UEFI 启动') $(if ($uefi) { 'ok' } else { 'fail' }) $(if ($uefi) { L 'firmware boot manager available' '固件启动管理器可用' } else { L 'Legacy/CSM boot detected; UEFI required' '检测到 Legacy/CSM 启动, 需要 UEFI 启动' })
    $sb = $null; try { $sb = Confirm-SecureBootUEFI } catch { }
    if ($sb -eq $false) { Add (L 'Secure Boot off' 'Secure Boot 已关闭') 'ok' (L 'Secure Boot is disabled (the program is unsigned)' 'Secure Boot 已关闭 (本程序未签名)') }
    elseif ($sb -eq $true) { Add (L 'Secure Boot off' 'Secure Boot 已关闭') 'fail' (L 'Secure Boot is ON: the unsigned EFI cannot start. Turn it off in the BIOS first' 'Secure Boot 已开启, 未签名的开机程序无法启动。请先在 BIOS 里关闭 Secure Boot') }
    else { Add (L 'Secure Boot off' 'Secure Boot 已关闭') 'warn' (L 'could not read Secure Boot state' '无法读取 Secure Boot 状态') }
    $fastStart = $false
    try {
        $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        $he = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled
        $fastStart = ($hb -eq 1 -and $he -eq 1)
    } catch { }
    if ($fastStart) { Add (L 'Fast Startup' '快速启动') 'warn' (L 'Fast Startup is ON: "Shut down" resumes a saved Windows session instead of starting fresh. This tool was not tested with that, and it can clash with files the boot program changes. Turn it off (Control Panel > Power Options > Choose what the power buttons do) or always use Restart.' '快速启动已开启: “关机”会恢复上次保存的 Windows 会话, 而不是全新启动。本工具没有在这种情况下测试过, 而且它可能和开机程序修改的文件冲突。请关闭快速启动 (控制面板 > 电源选项 > 选择电源按钮的功能), 或者一律用“重启”。') }
    else { Add (L 'Fast Startup' '快速启动') 'ok' (L 'off: every start is a fresh start' '已关闭: 每次开机都是全新启动') }
    $det = @(Find-Gpus)
    $detPnp = @($det | ForEach-Object { $_.Pnp })
    $others = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match '^PCI' -and $detPnp -notcontains [string]$_.PNPDeviceID })
    $gpu = $null
    if ($det.Count -eq 1) {
        $gpu = $det[0].Gpu
        $gd = "PCI 10de:$($gpu.id) $($gpu.name) " + [regex]::Match($det[0].Pnp, 'SUBSYS_[0-9A-F]{8}').Value
        if ($gpu.tier -eq 'verified') { Add (L 'Graphics card' '显卡') 'ok' $gd }
        else { Add (L 'Graphics card' '显卡') 'warn' ($gd + (L ' - EXPERIMENTAL: not tested by this project. Install reads the card first; an unlock is only tried after you arm one trial.' ' - 实验性: 本项目没有测试过这张卡。安装后先只读取显卡信息, 你手动开启一次试解锁后才会尝试解锁。')) }
    }
    elseif ($det.Count -gt 1) { Add (L 'Graphics card' '显卡') 'fail' (L 'more than one supported card: not supported' '检测到多块支持的显卡, 不支持') }
    else { Add (L 'Graphics card' '显卡') 'fail' (L 'no supported GeForce RTX 40 card found (see the README for the list of models)' '没有找到支持的 GeForce RTX 40 显卡 (支持的型号见 README)') }
    $mem = $null; try { $mem = [int](& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1) } catch { }
    if ($gpu) {
        if ($mem) { if ($mem -ge $gpu.vram_mib_min -and $mem -le $gpu.vram_mib_max) { Add (L 'Memory size' '显存容量') 'ok' "$mem MiB" } else { Add (L 'Memory size' '显存容量') 'fail' (L "$mem MiB does not match this model (expected $($gpu.vram_mib_min)-$($gpu.vram_mib_max) MiB); modded or non-standard cards are not supported" "$mem MiB 与该型号不符 (应为 $($gpu.vram_mib_min)-$($gpu.vram_mib_max) MiB); 不支持改版或非标准显存的显卡") } }
        else { Add (L 'Memory size' '显存容量') 'warn' (L 'nvidia-smi not available; VRAM size will be checked again by the boot program' 'nvidia-smi 不可用, 显存容量会由开机程序再次检查') }
    }
    if ($others.Count -gt 0) { $od = (($others | ForEach-Object { $_.Name }) -join ', ') + (L ' - connect the monitor to the supported card only' ' - 请只把显示器接到受支持的显卡上'); Add (L 'Other display adapters' '其他显示适配器') 'warn' $od } else { Add (L 'Other display adapters' '其他显示适配器') 'ok' (L 'none' '无') }
    $blState = 'unknown'; try { $blState = (Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus.ToString() } catch { }
    if ($blState -eq 'On') { Add (L 'BitLocker off' 'BitLocker 已关闭') 'fail' (L 'BitLocker protection is ON for the system drive: changing the boot path would trigger recovery. Turn it off first' '系统盘已开启 BitLocker 保护, 更改启动路径会触发恢复。请先关闭 BitLocker') }
    elseif ($blState -eq 'Off') { Add (L 'BitLocker off' 'BitLocker 已关闭') 'ok' (L 'system drive is not protected' '系统盘未受保护') }
    else { Add (L 'BitLocker off' 'BitLocker 已关闭') 'warn' (L 'could not read BitLocker state' '无法读取 BitLocker 状态') }
    if ($Mode -eq 'partition') {
        $c = @(Get-ShrinkCandidates -Max 1)
        if ($c.Count -gt 0) { $cd = (L 'candidates: ' '候选: ') + (($c | ForEach-Object { L "$($_.Letter): $($_.ShrinkableGB) GB shrinkable" "$($_.Letter): 可缩小 $($_.ShrinkableGB) GB" }) -join '; ') + (L "; will use $($c[0].Letter): ($($ShrinkBytes / 1MB) MiB)" "; 将使用 $($c[0].Letter): ($($ShrinkBytes / 1MB) MiB)"); Add (L 'Room for a small partition' '有空间划出小分区') 'ok' $cd }
        else { Add (L 'Room for a small partition' '有空间划出小分区') 'fail' (L 'no GPT, non-BitLocker NTFS volume can give up 304 MiB; use USB mode instead' '没有可以让出 304 MiB 的 GPT 非 BitLocker NTFS 卷, 请改用 U 盘模式') }
    } else {
        $u = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'FAT32' -and $_.DriveLetter -ne $env:SystemDrive.TrimEnd(':') -and $_.SizeRemaining -gt 150MB })
        if ($u.Count -gt 0) { $ud = (($u | ForEach-Object { L "$($_.DriveLetter): $([math]::Round($_.SizeRemaining/1MB)) MB free" "$($_.DriveLetter): 剩余 $([math]::Round($_.SizeRemaining/1MB)) MB" }) -join '; '); Add (L 'FAT32 drive for USB mode' 'U 盘模式用的 FAT32 盘') 'ok' $ud } else { Add (L 'FAT32 drive for USB mode' 'U 盘模式用的 FAT32 盘') 'fail' (L 'no FAT32 volume with 150 MB free' '没有剩余 150 MB 以上的 FAT32 卷') }
    }
    $cached = $true; foreach ($i in $Manifest.inputs) { if (-not (Test-Path -LiteralPath (Join-Path $Cache $i.file))) { $cached = $false } }
    if ($cached) { Add (L 'Downloads' '下载') 'ok' (L "all inputs already in $Cache" "所需文件都已在 $Cache 中") }
    else {
        $net = $true
        try {
            $tasks = @('download.nvidia.com', 'archive.cachyos.org', 'www.python.org' | ForEach-Object { [System.Net.Dns]::GetHostAddressesAsync($_) })
            [void][System.Threading.Tasks.Task]::WaitAll($tasks, 4000)
            foreach ($t in $tasks) { if (-not $t.IsCompleted -or $t.IsFaulted) { $net = $false } }
        } catch { $net = $false }
        $free = (Get-PSDrive -Name ($Cache.Substring(0, 1)) -ErrorAction SilentlyContinue).Free
        if ($net) { Add (L 'Downloads' '下载') 'ok' (L 'download hosts resolve; about 330 MB will be downloaded' '下载地址可以解析, 将下载约 330 MB') } else { Add (L 'Downloads' '下载') 'warn' (L 'cannot resolve the download hosts: copy the three files to the cache folder by hand ( -Cache )' '无法解析下载地址: 请手动把三个文件复制到缓存文件夹 ( -Cache )') }
        if ($free -and $free -lt 1GB) { Add (L 'Disk space for downloads' '下载所需磁盘空间') 'fail' (L "only $([math]::Round($free/1MB)) MB free on the cache drive" "缓存所在磁盘只剩 $([math]::Round($free/1MB)) MB") }
    }
    $guid = Get-EntryGuid
    Add (L 'Existing installation' '已有安装') 'ok' $(if ($guid) { L "boot entry $guid" "启动项 $guid" } else { L 'none' '无' })
    if ($Json) { Emit-Json $r } else { foreach ($x in $r) { Log ('{0,-30} {1,-5} {2}' -f $x.name, $x.status.ToUpper(), $x.detail) $(if ($x.status -eq 'fail') { 'ERROR' } elseif ($x.status -eq 'warn') { 'WARN' } else { 'INFO' }) } }
    return @($r | Where-Object { $_.status -eq 'fail' }).Count
}

# ------------------------------------------------------------------------------------------ downloads and firmware
function Invoke-Download {
    if (-not (Test-Path -LiteralPath $Cache)) { New-Item -ItemType Directory -Path $Cache -Force | Out-Null }
    foreach ($i in $Manifest.inputs) {
        $dest = Join-Path $Cache $i.file
        if (Test-Path -LiteralPath $dest) {
            if ((Get-Item -LiteralPath $dest).Length -eq $i.size -and (Sha256 $dest) -eq $i.sha256) { Log (L "cached and verified: $($i.file)" "已有缓存且校验通过: $($i.file)"); continue }
            Log (L "cached copy of $($i.file) does not match; downloading again" "$($i.file) 的缓存副本不匹配, 重新下载") 'WARN'; Remove-Item -LiteralPath $dest -Force
        }
        Log ((L 'downloading {0} ({1:N0} MB) from {2}' '正在下载 {0} ({1:N0} MB), 来源 {2}') -f $i.file, ($i.size / 1MB), $i.url)
        if ($DryRun) { continue }
        $part = $dest + '.part'
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        $wc = New-Object System.Net.WebClient
        try {
            $task = $wc.DownloadFileTaskAsync([Uri]$i.url, $part)
            $lastPct = -1
            while (-not $task.IsCompleted) {
                Start-Sleep -Seconds 2
                if (Test-Path -LiteralPath $part) { $pct = [int](100 * (Get-Item -LiteralPath $part).Length / $i.size); if ($pct -ge $lastPct + 10) { Log ("  {0}%" -f $pct); $lastPct = $pct } }
            }
            $task.GetAwaiter().GetResult()
        } finally { $wc.Dispose() }
        $got = (Get-Item -LiteralPath $part).Length
        if ($got -ne $i.size) { Remove-Item -LiteralPath $part -Force; Fail (L "$($i.file): size $got, expected $($i.size)" "$($i.file): 大小为 $got, 应为 $($i.size)") }
        $h = Sha256 $part
        if ($h -ne $i.sha256) { Remove-Item -LiteralPath $part -Force; Fail (L "$($i.file): SHA-256 mismatch ($h)" "$($i.file): SHA-256 不匹配 ($h)") }
        Move-Item -LiteralPath $part -Destination $dest -Force
        Log (L "verified $($i.file) sha256=$h" "已校验 $($i.file) sha256=$h")
    }
}
function Invoke-Assets([string]$Staging) {
    # Unpack NVIDIA's firmware locally with the bundled scripts. Nothing from NVIDIA is shipped with this tool.
    if ($DryRun) { Log (L "dry run: would unpack the firmware into $Staging" "试运行: 将把固件解包到 $Staging"); return }
    foreach ($i in $Manifest.inputs) { if (-not (Test-Path -LiteralPath (Join-Path $Cache $i.file))) { Fail (L "missing input $($i.file); run 'download' (or copy it into $Cache)" "缺少文件 $($i.file); 请先运行 'download' (或把它复制到 $Cache)") } }
    foreach ($i in $Manifest.inputs) { $p = Join-Path $Cache $i.file; if ((Sha256 $p) -ne $i.sha256) { Fail (L "$($i.file) does not match its pinned SHA-256" "$($i.file) 与固定的 SHA-256 不一致") } }
    $py = Join-Path $DataDir 'py'
    if (-not (Test-Path -LiteralPath (Join-Path $py 'python.exe'))) {
        Log (L 'unpacking the embeddable Python used for the firmware step' '正在解包固件步骤所用的内嵌 Python')
        if ($DryRun) { return }
        if (Test-Path -LiteralPath $py) { Remove-Item -Recurse -Force -LiteralPath $py }
        Expand-Archive -LiteralPath (Join-Path $Cache 'python-3.14.0-embed-amd64.zip') -DestinationPath $py -Force
    }
    $assets = Join-Path $Staging 'GPU-UNLOCK\ASSETS'
    Log (L "generating firmware files in $assets (this reads the 300 MB package and takes about a minute)" "正在 $assets 中生成固件文件 (需要读取 300 MB 的安装包, 约一分钟)")
    if ($DryRun) { return }
    if (Test-Path -LiteralPath $Staging) { Remove-Item -Recurse -Force -LiteralPath $Staging }
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    $script = Join-Path $Payload 'tools\windows\prepare_assets.py'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & (Join-Path $py 'python.exe') -I $script $assets --cache $Cache --offline 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $out | ForEach-Object { Log ('  ' + $_) }
    if ($code -ne 0) { Fail (L 'firmware generation failed' '固件生成失败') }
    foreach ($a in $Manifest.assets) {
        $p = Join-Path $assets $a.file
        if (-not (Test-Path -LiteralPath $p)) { Fail (L "generated set is missing $($a.file)" "生成的文件集中缺少 $($a.file)") }
        if ((Get-Item -LiteralPath $p).Length -ne $a.size -or (Sha256 $p) -ne $a.sha256) { Fail (L "$($a.file) does not match its pinned SHA-256" "$($a.file) 与固定的 SHA-256 不一致") }
        Log (L "verified $($a.file)" "已校验 $($a.file)")
    }
}

# ------------------------------------------------------------------------------------------ install
function Put-File([string]$Source, [string]$Dest) {
    # .NET calls on purpose: New-Item and Copy-Item reject \\?\Volume{guid}\ paths, which is how the small partition is reached (it has no drive letter)
    [void][System.IO.Directory]::CreateDirectory($Dest.Substring(0, $Dest.LastIndexOf('\')))
    [System.IO.File]::Copy($Source, $Dest, $true)
}
function Get-NtVolumeName($Volume) {
    # \\?\Volume{guid}\ -> \Device\HarddiskVolumeN, the name bcdedit accepts for a volume without a drive letter
    if (-not ('Win32.Dos' -as [type])) {
        Add-Type -Namespace Win32 -Name Dos -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint QueryDosDevice(string lpDeviceName, System.Text.StringBuilder lpTargetPath, uint ucchMax);'
    }
    $name = ($Volume.Path -replace '^\\\\\?\\', '').TrimEnd('\')
    $sb = New-Object System.Text.StringBuilder 520
    if ([Win32.Dos]::QueryDosDevice($name, $sb, 520) -eq 0) { return $null }
    $nt = $sb.ToString().Split([char]0)[0]
    if ($nt -match '^\\Device\\HarddiskVolume\d+$') { return $nt }
    return $null
}
function Remove-AutoLetter($Partition) {
    # a drive letter makes Explorer open the volume and pop up "cannot access E: / parameter is incorrect" while it is formatted and dismounted
    $q = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction SilentlyContinue
    if ($q -and $q.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $q.DiskNumber -PartitionNumber $q.PartitionNumber -AccessPath ($q.DriveLetter + ':\') -ErrorAction SilentlyContinue }
}
function Invoke-Install {
    if (-not (Test-Admin)) { Fail (L 'administrator rights are required' '需要管理员权限') }
    if (Get-EntryGuid) { Fail (L 'a GPU Unlock boot entry already exists; uninstall it first' '已存在 GPU Unlock 启动项, 请先卸载') }
    $fails = Invoke-Check
    if ($fails -gt 0) { Fail (L "$fails check(s) failed; nothing was changed" "$fails 项检查未通过, 未做任何更改") }
    $gpuNow = Get-GpuInfo
    if ($gpuNow -and $gpuNow.tier -ne 'verified' -and -not $AcceptExperimental) {
        Fail (L "$($gpuNow.name) is an EXPERIMENTAL card: this project has not tested it. Read the README, then install with -AcceptExperimental (the window asks for it). Nothing was changed." "$($gpuNow.name) 是实验性支持的显卡: 本项目没有测试过它。请先阅读 README, 再加 -AcceptExperimental 安装 (窗口里会让你确认)。未做任何更改。")
    }
    if ((Sha256 (Join-Path $Payload $Manifest.efi.file)) -ne $Manifest.efi.sha256) { Fail (L 'payload EFI does not match the manifest' '程序包中的开机程序与清单不一致') }
    $staging = Join-Path $DataDir 'staging'
    Invoke-Download
    Invoke-Assets $staging
    $efiSrc = Join-Path $Payload $Manifest.efi.file
    $state = @{ Mode = $Mode }
    if ($gpuNow) { $state.GpuId = $gpuNow.id; $state.GpuName = $gpuNow.name; $state.GpuTier = $gpuNow.tier }
    $tmpLetter = $null      # only set for a USB drive, or for the fallback when the letterless boot entry cannot be made
    $np = $null
    $dst = $null
    $bcdDevice = $null
    try {
        if ($Mode -eq 'partition') {
            $pick = $null
            if ($TargetVolume) { $want = $TargetVolume.TrimEnd(':').ToUpper(); $pick = @(Get-ShrinkCandidates -Max 1 -Only $want) | Select-Object -First 1; if (-not $pick) { Fail (L "volume $TargetVolume cannot be shrunk safely" "卷 $TargetVolume 无法安全缩小") } }
            else { $pick = @(Get-ShrinkCandidates -Max 1) | Select-Object -First 1 }
            if (-not $pick) { Fail (L 'no volume can be shrunk' '没有可以缩小的卷') }
            $p = Get-Partition -DriveLetter $pick.Letter
            $disk = Get-Disk -Number $p.DiskNumber
            Log ((L "PLAN: shrink {0}: by {1} MiB, create a {2} MiB FAT32 partition '{3}' (no drive letter) on disk {4} ({5}), copy the program and firmware, add boot entry '{6}'" "计划: 将卷 {0}: 缩小 {1} MiB, 在磁盘 {4} ({5}) 上新建 {2} MiB 的 FAT32 分区 '{3}' (不分配盘符), 复制开机程序和固件, 添加启动项 '{6}'") -f $pick.Letter, ($ShrinkBytes / 1MB), ($PartBytes / 1MB), $PartLabel, $disk.Number, $disk.FriendlyName, $EntryName)
            if ($DryRun) { Log (L 'dry run: nothing changed' '试运行: 未做任何更改'); return }
            $next = Get-Partition -DiskNumber $p.DiskNumber | Where-Object { $_.Offset -gt $p.Offset } | Sort-Object Offset | Select-Object -First 1
            $newSize = $p.Size - $ShrinkBytes
            $sup = Get-PartitionSupportedSize -DriveLetter $pick.Letter
            if ($newSize -lt $sup.SizeMin) { Fail (L 'volume cannot shrink that much' '卷无法缩小这么多') }
            Resize-Partition -DriveLetter $pick.Letter -Size $newSize
            $state.ShrunkGuid = (Get-Partition -DriveLetter $pick.Letter).Guid
            $state.ShrunkOriginalSize = $p.Size
            $p2 = Get-Partition -DriveLetter $pick.Letter
            $gap = $p2.Offset + $p2.Size
            if ($next -and ($next.Offset - $gap) -lt $PartBytes) { Fail (L 'the freed space is too small' '腾出的空间太小') }
            $np = New-Partition -DiskNumber $p.DiskNumber -Offset $gap -Size $PartBytes
            $state.PartitionGuid = $np.Guid
            $state.DiskNumber = $np.DiskNumber
            $state.PartitionNumber = $np.PartitionNumber
            # never give this partition a drive letter: flag it first, then drop any letter that was handed out meanwhile
            Set-Partition -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber -NoDefaultDriveLetter $true
            Remove-AutoLetter $np
            Format-Volume -Partition $np -FileSystem FAT32 -NewFileSystemLabel $PartLabel -Confirm:$false | Out-Null
            Remove-AutoLetter $np
            Log (L "created partition $($np.PartitionNumber) on disk $($np.DiskNumber)" "已创建分区 $($np.PartitionNumber) (磁盘 $($np.DiskNumber))")
            $vol = $null
            for ($i = 0; $i -lt 10 -and -not ($vol -and $vol.Path); $i++) { $vol = Get-Volume -Partition (Get-Partition -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber) -ErrorAction SilentlyContinue; if (-not ($vol -and $vol.Path)) { Start-Sleep -Milliseconds 500 } }
            if (-not ($vol -and $vol.Path)) { Fail (L 'the new partition did not come up as a volume' '新分区没有作为卷出现') }
            if ($vol.FileSystem -ne 'FAT32') { Fail (L 'the new partition is not FAT32' '新分区不是 FAT32') }
            $dst = $vol.Path
        } else {
            if (-not $Drive) { Fail (L 'USB mode needs -Drive' 'U 盘模式需要指定 -Drive') }
            $tmpLetter = $Drive.TrimEnd(':').ToUpper()
            $v = Get-Volume -DriveLetter $tmpLetter
            if ($v.FileSystem -ne 'FAT32' -or $tmpLetter -eq $env:SystemDrive.TrimEnd(':')) { Fail (L 'the drive must be a FAT32 volume that is not the system drive' '该盘必须是 FAT32 卷, 且不能是系统盘') }
            if (Test-Path -LiteralPath ($tmpLetter + ':\EFI\Microsoft')) { Fail (L 'that volume looks like a Windows boot partition; refusing' '该卷看起来是 Windows 启动分区, 已拒绝操作') }
            Log (L "PLAN: copy the program and firmware to ${tmpLetter}: (FAT32, nothing is formatted), add boot entry '$EntryName'. The drive must stay plugged in; without it the PC simply boots Windows." "计划: 把开机程序和固件复制到 ${tmpLetter}: (FAT32, 不会格式化), 添加启动项 '$EntryName'。U 盘必须一直插着, 拔掉后电脑会直接启动 Windows。")
            if ($DryRun) { Log (L 'dry run: nothing changed' '试运行: 未做任何更改'); return }
            $state.PartitionGuid = $null
            $state.KeepLetter = $true
            $dst = $tmpLetter + ':\'
        }
        Put-File $efiSrc ($dst + 'EFI\GPUUNLOCK\gpuunlock.efi')
        foreach ($a in $Manifest.assets) { Put-File (Join-Path $staging ('GPU-UNLOCK\ASSETS\' + $a.file)) ($dst + 'GPU-UNLOCK\ASSETS\' + $a.file) }
        $lic = Join-Path $staging 'GPU-UNLOCK\ASSETS\NVIDIA-LICENSE'
        if (Test-Path -LiteralPath $lic) { Put-File $lic ($dst + 'GPU-UNLOCK\ASSETS\NVIDIA-LICENSE') }
        Put-File (Join-Path $Payload 'LICENSE-GPL-2.0.txt') ($dst + 'GPU-UNLOCK\LICENSE-GPL-2.0.txt')
        fsutil volume dismount ($dst.TrimEnd('\')) | Out-Null
        Start-Sleep -Seconds 2
        if ((Sha256 ($dst + 'EFI\GPUUNLOCK\gpuunlock.efi')) -ne $Manifest.efi.sha256) { Fail (L 'EFI on the target does not verify' '目标盘上的开机程序校验失败') }
        foreach ($a in $Manifest.assets) { if ((Sha256 ($dst + 'GPU-UNLOCK\ASSETS\' + $a.file)) -ne $a.sha256) { Fail (L "$($a.file) on the target does not verify" "目标盘上的 $($a.file) 校验失败") } }
        Log (L 'all files verified on the target volume (re-read after dismount)' '目标卷上的所有文件均已校验 (卸载后重新读取)')
        if ($Mode -eq 'partition') { $vol = Get-Volume -Partition (Get-Partition -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber) } else { $vol = Get-Volume -DriveLetter $tmpLetter }
        $state.VolumePath = $vol.Path
        # how the boot entry names the volume: a USB drive by its letter, the letterless partition by its NT device name
        if ($Mode -eq 'partition') {
            $nt = Get-NtVolumeName $vol
            if ($nt) { $bcdDevice = 'partition=' + $nt; Log (L "boot entry will point at $nt (no drive letter needed)" "启动项将指向 $nt (不需要盘符)") }
            else {
                $tmpLetter = Get-FreeLetter
                Log (L "could not read the NT device name; using the temporary letter ${tmpLetter}: for the boot entry" "无法读取 NT 设备名; 启动项改用临时盘符 ${tmpLetter}:") 'WARN'
                Add-PartitionAccessPath -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber -AccessPath ($tmpLetter + ':\')
                $bcdDevice = 'partition=' + $tmpLetter + ':'
            }
        } else { $bcdDevice = 'partition=' + $tmpLetter + ':' }
        # boot entry (added to the firmware list but NOT yet first)
        $out = bcdedit /copy '{bootmgr}' /d $EntryName
        $m = [regex]::Match(($out | Out-String), '\{[0-9a-fA-F-]{36}\}')
        if (-not $m.Success) { Fail (L 'could not create the firmware boot entry' '无法创建固件启动项') }
        $guid = $m.Value
        $state.EntryGuid = $guid
        bcdedit /set $guid path '\EFI\GPUUNLOCK\gpuunlock.efi' | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail (L 'bcdedit could not set the boot program path' 'bcdedit 无法设置开机程序的路径') }
        bcdedit /set $guid device $bcdDevice | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail (L 'bcdedit could not point the entry at the target volume' 'bcdedit 无法把启动项指向目标卷') }
        foreach ($k in $state.Keys) { if ($null -ne $state[$k]) { Set-Reg $k ([string]$state[$k]) } }
        Set-Reg 'Version' $Manifest.version
        Set-Reg 'EfiSha256' $Manifest.efi.sha256
        Set-Reg 'InstalledAt' (Get-Date).ToString('s')
        Log (L "boot entry $guid created" "已创建启动项 $guid")
    } catch {
        Log (L "install failed: $($_.Exception.Message) - rolling back" "安装失败: $($_.Exception.Message) - 正在回滚") 'ERROR'
        Invoke-Rollback $state $(if ($Mode -eq 'partition') { $tmpLetter } else { $null })
        throw
    } finally {
        if ($np -and $Mode -eq 'partition' -and -not $DryRun) { try { Remove-AutoLetter $np } catch { } }
    }
    if ($DryRun) { return }
    $expCard = ((Get-CardTier (Get-InstallVolume)) -eq 'experimental')
    if (-not $NoEnable) {
        if ($expCard) {
            # the boot entry must run once so the card can be read; for an experimental card that first run writes nothing to the card
            [void](Set-EntryFirst (Get-EntryGuid))
            Log (L 'ON (experimental card): the next start only READS the card; nothing is unlocked until you arm a trial.' '已开启 (实验性显卡): 下次开机只会读取显卡信息, 在你手动开启试解锁之前不会解锁。')
        } else { Invoke-Enable }
    } else { Log (L 'installed but left OFF; use the switch to turn it on' '已安装但保持关闭; 请用开关把它开启') }
    if ($expCard) { Log (L 'DONE. Restart the PC: the first start only reads the card and saves its profile. Then arm ONE trial unlock (Try unlock once) and restart again.' '完成。请重启电脑: 第一次开机只读取显卡信息并保存。之后点“试解锁一次”, 再重启一次进行试解锁。') }
    else { Log (L 'DONE. Restart the PC: the first start reads the card and saves its profile, then unlocks in the same boot.' '完成。请重启电脑: 第一次开机会先读取显卡信息并保存, 然后在同一次开机里解锁。') }
}
function Invoke-Rollback($State, $TmpLetter) {
    try {
        if ($State.EntryGuid) { Remove-BootEntry $State.EntryGuid }
        if ($State.PartitionGuid -and $Mode -eq 'partition') {
            $np = Get-Partition | Where-Object { $_.Guid -eq $State.PartitionGuid } | Select-Object -First 1
            if ($np) { if ($TmpLetter) { try { Remove-PartitionAccessPath -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber -AccessPath ($TmpLetter + ':\') } catch { } }; Remove-Partition -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber -Confirm:$false }
        }
        if ($State.ShrunkGuid) {
            $sp = Get-Partition | Where-Object { $_.Guid -eq $State.ShrunkGuid } | Select-Object -First 1
            if ($sp) { $max = (Get-PartitionSupportedSize -DiskNumber $sp.DiskNumber -PartitionNumber $sp.PartitionNumber).SizeMax; Resize-Partition -DiskNumber $sp.DiskNumber -PartitionNumber $sp.PartitionNumber -Size $max }
        }
        if (Test-Path $RegPath) { Remove-Item -Path $RegPath -Recurse -Force }
        Log (L 'rollback finished' '回滚完成') 'WARN'
    } catch { Log (L "rollback incomplete: $($_.Exception.Message). Check Disk Management and 'bcdedit /enum firmware'." "回滚未完成: $($_.Exception.Message)。请检查磁盘管理和 'bcdedit /enum firmware'。") 'ERROR' }
}

# ------------------------------------------------------------------------------------------ switch and settings
function Invoke-Enable {
    $guid = Get-EntryGuid; if (-not $guid) { Fail (L 'not installed' '未安装') }
    $vol = Get-InstallVolume
    if (-not (Test-Files $vol)) { Fail (L 'the program files are missing or unsafe; refusing to turn it on' '程序文件缺失或不安全, 已拒绝开启') }
    $waiting = $false
    if ((Get-CardTier $vol) -eq 'experimental') {
        # an experimental card is only switched to automatic after one trial unlock was verified on this very PC;
        # without that, "on" only puts the boot entry back so the card can be read and a trial can run (it waits otherwise)
        $t = Get-TrialInfo $vol
        if (-not $t.auto) {
            if ($t.result -eq 'verified') {
                if ($DryRun) { Log (L 'dry run: would confirm auto-unlock for this card' '试运行: 将为这张卡确认自动解锁'); return }
                Write-VolFile $vol 'AUTO.TXT' "auto=1`r`n"
                [void](Remove-VolFile $vol 'ARMED.TXT')
                Sync-VolumeToDisk $vol
                Log (L 'auto-unlock confirmed for this card (a trial unlock was verified)' '已为这张卡确认自动解锁 (试解锁已验证成功)')
            } else { $waiting = $true }
        }
    }
    $order = Get-DisplayOrder
    if ($order.Count -gt 0 -and $order[0] -eq $guid) { Log $(if ($waiting) { L 'already ON (waiting: this experimental card is only read until a trial worked)' '已经开启 (等待中: 在试解锁成功之前, 这张实验性显卡只会被读取)' } else { L 'already ON' '已经是开启状态' }); return }
    if ($DryRun) { Log (L 'dry run: would put the boot entry first' '试运行: 将把启动项放到最前面'); return }
    [void](Set-EntryFirst $guid)
    if ($waiting) { Log (L 'ON (waiting): the boot program runs at every start, but this experimental card is only read until a trial unlock worked. Use "Try unlock once".' '已开启 (等待中): 开机程序每次开机都会运行, 但在试解锁成功之前, 这张实验性显卡只会被读取。请用“试解锁一次”。') }
    else { Log (L 'ON: from the next start the card is unlocked automatically.' '已开启: 下次开机起自动解锁。') }
}
function Invoke-Trial {
    if (-not (Test-Admin)) { Fail (L 'administrator rights are required' '需要管理员权限') }
    $guid = Get-EntryGuid; if (-not $guid) { Fail (L 'not installed' '未安装') }
    $vol = Get-InstallVolume
    if (-not (Test-Files $vol)) { Fail (L 'the program files are missing or unsafe; refusing to arm a trial' '程序文件缺失或不安全, 已拒绝开启试解锁') }
    if ((Get-CardTier $vol) -ne 'experimental') { Fail (L 'this card is in the verified tier; no trial is needed (use the switch)' '这张卡属于已验证级别, 不需要试解锁 (直接用开关)') }
    if (-not (Test-Path -LiteralPath (Get-VolFile $vol 'PROFILE.TXT'))) {
        if (-not $DryRun) { [void](Set-EntryFirst $guid) }   # the boot program has to run once to read the card
        Fail (L 'the card has not been read yet: the boot entry is on; restart once so the boot program can read the card, then try again' '还没有读取过这张显卡: 启动项已开启, 请先重启一次, 让开机程序读取显卡信息, 然后再试')
    }
    if ($DryRun) { Log (L 'dry run: would arm ONE trial unlock for the next start' '试运行: 将为下次开机开启一次试解锁'); return }
    Write-VolFile $vol 'ARMED.TXT' "armed=1`r`n"
    Sync-VolumeToDisk $vol
    [void](Set-EntryFirst $guid)
    Log (L 'Trial armed: the next start tries ONE unlock. If the screen stays black, hold the power button until the PC is off, start it again, pick "Windows Boot Manager" in the firmware boot menu, then turn the switch off.' '已开启试解锁: 下次开机会尝试解锁一次。如果屏幕一直黑屏, 请长按电源键关机, 再开机, 在固件启动菜单里选 “Windows Boot Manager”, 进系统后把开关关掉。')
}
function Invoke-Disable {
    $guid = Get-EntryGuid; if (-not $guid) { Log (L 'not installed' '未安装'); return }
    $vol = Get-InstallVolume
    if ($vol -and -not $DryRun -and (Test-Files $vol) -and (Get-CardTier $vol) -eq 'experimental') { if (Remove-VolFile $vol 'ARMED.TXT') { Sync-VolumeToDisk $vol; Log (L 'the pending trial was cancelled' '已取消待执行的试解锁') } }
    $order = Get-DisplayOrder
    if (-not ($order -contains $guid)) { Log (L 'already OFF' '已经是关闭状态'); return }
    if ($DryRun) { Log (L 'dry run: would take the boot entry out of the order' '试运行: 将把启动项从启动顺序中移除'); return }
    bcdedit /set '{fwbootmgr}' displayorder $guid /remove | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail (L 'bcdedit failed' 'bcdedit 执行失败') }
    Log (L 'OFF: from the next start there is no unlock and no wait. The files stay installed.' '已关闭: 下次开机起不再解锁, 也没有等待。程序文件仍保留在原处。')
}
function Invoke-Update {
    if (-not (Test-Admin)) { Fail (L 'administrator rights are required' '需要管理员权限') }
    $guid = Get-EntryGuid; if (-not $guid) { Fail (L 'not installed' '未安装') }
    $vol = Get-InstallVolume; if (-not (Test-Files $vol)) { Fail (L 'installed files not found' '找不到已安装的文件') }
    $src = Join-Path $Payload $Manifest.efi.file
    if ((Sha256 $src) -ne $Manifest.efi.sha256) { Fail (L 'payload EFI does not match the manifest' '程序包中的开机程序与清单不一致') }
    $dst = Join-Path $vol.Path 'EFI\GPUUNLOCK\gpuunlock.efi'
    $cur = Sha256 $dst
    if ($cur -eq $Manifest.efi.sha256) { if (-not $DryRun) { Set-Reg 'EfiSha256' $Manifest.efi.sha256; Set-Reg 'Version' $Manifest.version }; Log (L 'the boot program is already up to date' '开机程序已是最新版本'); return }
    Log ((L 'updating the boot program {0} -> {1}' '正在更新开机程序 {0} -> {1}') -f $cur.Substring(0, 12), $Manifest.efi.sha256.Substring(0, 12))
    if ($DryRun) { Log (L 'dry run: nothing changed' '试运行: 未做任何更改'); return }
    $bak = $dst + '.old'
    # .NET file calls: Copy-Item and Remove-Item do not work on the letterless \\?\Volume{guid}\ path
    [System.IO.File]::Copy($dst, $bak, $true)
    try {
        [System.IO.File]::Copy($src, $dst, $true)
        if ((Sha256 $dst) -ne $Manifest.efi.sha256) { throw (L 'the new file does not verify' '新文件校验失败') }
    } catch { [System.IO.File]::Copy($bak, $dst, $true); [System.IO.File]::Delete($bak); Sync-VolumeToDisk $vol; Fail (L "update failed ($($_.Exception.Message)); the previous program was restored" "更新失败 ($($_.Exception.Message)), 已恢复为原来的程序") }
    [System.IO.File]::Delete($bak)
    [void](Remove-VolFile $vol 'CONFIG.TXT')
    Sync-VolumeToDisk $vol
    if ((Sha256 $dst) -ne $Manifest.efi.sha256) { Fail (L 'the new boot program does not verify after the volume was re-read' '重新读取分区后, 新的开机程序校验失败') }
    Set-Reg 'EfiSha256' $Manifest.efi.sha256
    Set-Reg 'Version' $Manifest.version
    Log (L 'updated. The saved card profile is kept.' '已更新, 已保存的显卡信息保留。')
}
function Invoke-Reenroll {
    $vol = Get-InstallVolume; if (-not (Test-Files $vol)) { Fail (L 'installation not found' '找不到已安装的内容') }
    if ($DryRun) { Log (L 'dry run: would delete the saved card profile and any trial state' '试运行: 将删除已保存的显卡信息和试解锁状态'); return }
    $removed = @()
    foreach ($n in 'PROFILE.TXT', 'AUTO.TXT', 'ARMED.TXT') { if (Remove-VolFile $vol $n) { $removed += $n } }   # a new card starts again from the read-only step, even if the profile was already deleted by hand
    Sync-VolumeToDisk $vol
    if ($removed.Count -eq 0) { Log (L 'nothing to remove: there is no saved profile or trial state' '没有可删除的内容: 没有已保存的显卡信息或试解锁状态'); return }
    Log (L 'profile and trial state removed: the next start reads the card again and saves a new profile' '显卡信息和试解锁状态已删除: 下次开机会重新读取显卡并重新登记')
}

function Get-LastRun($Volume) {
    if (-not $Volume) { return $null }
    $dir = Join-Path $Volume.Path 'GPU-UNLOCK'
    $latest = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'RUN*' } | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'REPORT.TXT') -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $lines = Get-Content -LiteralPath $latest.FullName -Encoding ASCII
    $thisBoot = (Test-RunThisBoot $latest.LastWriteTime)
    $verified = @($lines | Where-Object { $_ -match 'POST-GOP register_unlock_verified=1' }).Count -gt 0
    $enrolled = @($lines | Where-Object { $_ -match '^ENROLLED:' }).Count -gt 0
    $final = ($lines | Where-Object { $_ -match '^FINAL ' } | Select-Object -Last 1)
    $stage = if ($final -match 'stage=(\S+)') { $Matches[1] } else { '' }
    return [pscustomobject]@{ time = $latest.LastWriteTime.ToString('s'); thisBoot = $thisBoot; unlocked = $verified; enrolled = $enrolled; final = [string]$final; stage = $stage; path = $latest.FullName }
}
function Invoke-Status {
    $guid = Get-EntryGuid; $vol = Get-InstallVolume
    $order = Get-DisplayOrder
    $pos = if ($guid) { [array]::IndexOf($order, $guid) } else { -2 }
    $profile = $false
    if ($vol) { $profile = Test-Path -LiteralPath (Join-Path $vol.Path 'GPU-UNLOCK\PROFILE.TXT') }
    $last = Get-LastRun $vol
    $gpuInfo = Get-GpuInfo
    $tier = $(if ($vol) { Get-CardTier $vol } else { $(if ($gpuInfo -and $gpuInfo.tier -eq 'verified') { 'verified' } else { 'experimental' }) })
    $trial = $(if ($vol -and $tier -eq 'experimental') { Get-TrialInfo $vol } else { $null })
    $s = [pscustomobject]@{
        installed = [bool]$guid; switch = $(if (-not $guid) { 'none' } elseif ($pos -eq 0) { 'on' } elseif ($pos -gt 0) { 'on-not-first' } else { 'off' })
        entry = $guid; volumeFound = [bool]$vol; filesOk = (Test-Files $vol); mode = (Get-Reg 'Mode'); version = (Get-Reg 'Version')
        enrolled = $profile; lastRun = $last; gpu = $gpuInfo; tier = $tier; experimental = ($tier -eq 'experimental'); trial = $trial; freeMB = $(if ($vol) { [math]::Round($vol.SizeRemaining / 1MB) } else { $null })
    }
    if ($Json) { Emit-Json $s; return }
    Log ((L 'installed: {0}   switch: {1}   files: {2}   mode: {3}' '已安装: {0}   开关: {1}   文件: {2}   模式: {3}') -f $s.installed, $s.switch, $s.filesOk, $s.mode)
    Log ((L 'profile enrolled: {0}' '显卡信息已登记: {0}') -f $s.enrolled)
    if ($gpuInfo) { Log ((L 'card: {0} (tier: {1})' '显卡: {0} (级别: {1})') -f $gpuInfo.name, $tier) }
    if ($trial) { Log ((L 'trial: armed={0}  auto-unlock confirmed={1}  last trial={2}' '试解锁: 已开启={0}  已确认自动解锁={1}  最近一次试解锁={2}') -f $trial.armed, $trial.auto, $trial.result) }
    if ($last) {
        if ($last.thisBoot) { Log ((L 'last run {0} (this boot): {1}' '上次运行 {0} (本次开机): {1}') -f $last.time, $(if ($last.unlocked) { L 'UNLOCKED' '已解锁' } else { (L 'not unlocked - ' '未解锁 - ') + $last.final })) }
        else { Log ((L 'last run {0} was an earlier boot; the unlock did not run this boot, so the card is locked now' '上次运行 {0} 是更早的一次开机; 本次开机没有运行解锁, 所以显卡现在是锁定的') -f $last.time) }
    } else { Log (L 'no boot log yet' '还没有开机日志') }
}
function Invoke-Candidates {
    $usb = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'FAT32' -and $_.DriveLetter -ne $env:SystemDrive.TrimEnd(':') -and $_.SizeRemaining -gt 150MB } | ForEach-Object { [pscustomobject]@{ Letter = [string]$_.DriveLetter; Label = $_.FileSystemLabel; FreeMB = [math]::Round($_.SizeRemaining / 1MB); Type = [string]$_.DriveType } })
    Emit-Json ([pscustomobject]@{ partition = @(Get-ShrinkCandidates -Quick); usb = $usb; gpu = (Get-GpuInfo) })
}
function Invoke-Logs {
    $vol = Get-InstallVolume; $last = Get-LastRun $vol
    if (-not $last) { Log (L 'no log' '没有日志'); return }
    Log (L "log: $($last.path)" "日志: $($last.path)")
    Get-Content -LiteralPath $last.path -Encoding ASCII | ForEach-Object { Write-Host $_ }
}

function Invoke-Uninstall {
    if (-not (Test-Admin)) { Fail (L 'administrator rights are required' '需要管理员权限') }
    $guid = Get-EntryGuid
    $mode = Get-Reg 'Mode'
    $vol = Get-InstallVolume
    Log ((L 'PLAN: remove the boot entry {0}; mode={1}; {2}' '计划: 删除启动项 {0}; 模式={1}; {2}') -f $guid, $mode, $(if ($mode -eq 'partition') { L 'delete the small partition and give the space back to the volume it came from' '删除小分区, 把空间还给原来的卷' } else { L 'delete the program folders from the drive (the drive itself is untouched)' '删除 U 盘上的程序文件夹 (U 盘本身不动)' }))
    if ($DryRun) { Log (L 'dry run: nothing changed' '试运行: 未做任何更改'); return }
    if ($guid) {
        Remove-BootEntry $guid
        Log (L 'boot entry removed' '启动项已删除')
    }
    if ($mode -eq 'partition') {
        $pg = Get-Reg 'PartitionGuid'; $sg = Get-Reg 'ShrunkGuid'
        $np = if ($pg) { Get-Partition | Where-Object { $_.Guid -eq $pg } | Select-Object -First 1 } else { $null }
        if ($np) {
            $v = $np | Get-Volume
            if ($v.FileSystemLabel -ne $PartLabel -or [math]::Abs($np.Size - $PartBytes) -gt 8MB) { Fail (L 'the partition does not look like ours; not deleting it' '该分区看起来不是本工具创建的, 不会删除') }
            Remove-Partition -DiskNumber $np.DiskNumber -PartitionNumber $np.PartitionNumber -Confirm:$false
            Log (L 'partition deleted' '分区已删除')
        } else { Log (L 'partition not found (already gone)' '找不到分区 (已不存在)') 'WARN' }
        $sp = if ($sg) { Get-Partition | Where-Object { $_.Guid -eq $sg } | Select-Object -First 1 } else { $null }
        if ($sp) { $max = (Get-PartitionSupportedSize -DiskNumber $sp.DiskNumber -PartitionNumber $sp.PartitionNumber).SizeMax; Resize-Partition -DiskNumber $sp.DiskNumber -PartitionNumber $sp.PartitionNumber -Size $max; Log (L 'the shrunk volume was extended back' '被缩小的卷已扩回原大小') }
    } elseif ($vol) {
        foreach ($d in 'EFI\GPUUNLOCK', 'GPU-UNLOCK') { $p = Join-Path $vol.Path $d; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
        Log (L 'program folders removed from the drive' '已删除 U 盘上的程序文件夹')
    }
    if (Test-Path $RegPath) { Remove-Item -Path $RegPath -Recurse -Force }
    Log (L 'uninstalled.' '已卸载。')
}

# ------------------------------------------------------------------------------------------ dispatch
try {
    switch ($Action) {
        'version' { Log "$($Manifest.product) $($Manifest.version)" }
        'check' { $f = Invoke-Check; if ($f -gt 0) { exit 2 } }
        'download' { Invoke-Download }
        'assets' { Invoke-Assets (Join-Path $DataDir 'staging') }
        'install' { Invoke-Install }
        'enable' { Invoke-Enable }
        'disable' { Invoke-Disable }
        'status' { Invoke-Status }
        'update' { Invoke-Update }
        'reenroll' { Invoke-Reenroll }
        'trial' { Invoke-Trial }
        'uninstall' { Invoke-Uninstall }
        'logs' { Invoke-Logs }
        'candidates' { Invoke-Candidates }
    }
    Release-InstallVolume
} catch {
    Log $_.Exception.Message 'ERROR'
    Release-InstallVolume
    if (-not $NoPause -and $Host.Name -eq 'ConsoleHost') { [void](Read-Host (L 'Press Enter to close' '按回车键关闭')) }
    exit 1
}
if (-not $NoPause -and $Host.Name -eq 'ConsoleHost' -and -not $Json) { [void](Read-Host (L 'Press Enter to close' '按回车键关闭')) }
