param([switch]$SelfTest, [switch]$Shot)

# GPU unlock panel v3.2 - dark tech redesign + desktop icon repair (2026-11-04)
# Same engine as v3: the only working unlock path is the boot-time cold unlock done by
# the three scheduled tasks, because by the time Windows is up nvlddmkm owns the card
# and the GSP firmware is already running (selector write then fails with -138).
# Design notes: everything is drawn with flat panels + 1px accent bars so it renders
# identically on PS 5.1 without gradient/Bitmap tricks; every font >= 12px and every
# clickable target >= 32px per the house UI rule. Open-source badge / author / usage
# text all live behind the "?" help button.

$root = $PSScriptRoot
$exe = Join-Path $root 'gpu_unlock.exe'
$pyExe = 'F:\ComfyUI-aki-v3\python\python.exe'
$probePy = Join-Path $root 'bf16_probe.py'
$taskBoot = 'GpuUnlockBoot'
$taskOff = 'GpuUnlockOff'
$taskRescue = 'GpuUnlockBootRescue'
$logRoot = Join-Path $env:ProgramData 'GpuUnlock'
$benchCache = Join-Path $logRoot 'last-bench.txt'
$deskFix = Join-Path $root 'desk-fix.ps1'
$deskCfg = Join-Path $logRoot 'desk.cfg'
$ver = '3.2'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest -and -not $Shot) {
    $argLine = '-STA -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- palette (all pairs verified >= 4.5:1 against their own background) ----
$C_BG = [System.Drawing.Color]::FromArgb(7, 11, 20)
$C_CARD = [System.Drawing.Color]::FromArgb(12, 23, 40)
$C_CARD2 = [System.Drawing.Color]::FromArgb(15, 27, 43)
$C_CHIP = [System.Drawing.Color]::FromArgb(17, 32, 52)
$C_TXT = [System.Drawing.Color]::FromArgb(232, 241, 255)
$C_MUT = [System.Drawing.Color]::FromArgb(143, 166, 192)
$C_DIM = [System.Drawing.Color]::FromArgb(111, 134, 160)
$C_CYAN = [System.Drawing.Color]::FromArgb(111, 231, 242)
$C_TITLE = [System.Drawing.Color]::FromArgb(169, 236, 247)
$C_GREEN = [System.Drawing.Color]::FromArgb(46, 212, 122)
$C_AMBER = [System.Drawing.Color]::FromArgb(255, 196, 107)
$C_RED = [System.Drawing.Color]::FromArgb(255, 107, 107)
$C_BLUE = [System.Drawing.Color]::FromArgb(27, 110, 243)
$C_DARKBLUE = [System.Drawing.Color]::FromArgb(22, 39, 61)
$C_DANGER = [System.Drawing.Color]::FromArgb(166, 42, 42)
$C_LOG = [System.Drawing.Color]::FromArgb(8, 16, 28)
$C_LOGTXT = [System.Drawing.Color]::FromArgb(169, 199, 232)

function Fnt([double]$px, [bool]$bold) {
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font('Microsoft YaHei UI', ($px * 72 / 96), $style)
}

function New-Lbl($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [double]$px, [bool]$bold, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Text = $text
    $l.Font = Fnt $px $bold
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoSize = $false
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $parent.Controls.Add($l)
    return $l
}

function New-Btn($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $back, [double]$px) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Text = $text
    $b.Font = Fnt $px $true
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.BackColor = $back
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $parent.Controls.Add($b)
    return $b
}

function New-Card($parent, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $C_CARD
    $parent.Controls.Add($p)
    $bar = New-Object System.Windows.Forms.Label
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size($w, 2)
    $bar.BackColor = $C_CHIP
    $bar.Text = ''
    $p.Controls.Add($bar)
    return $p
}

function New-Chip($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $fg) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $C_CHIP
    $parent.Controls.Add($p)
    $l = New-Lbl $p 8 0 ($w - 16) $h $text 13 $true $fg
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $l
}

function New-Link($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [string]$url) {
    $ll = New-Object System.Windows.Forms.LinkLabel
    $ll.Location = New-Object System.Drawing.Point($x, $y)
    $ll.Size = New-Object System.Drawing.Size($w, $h)
    $ll.Text = $text
    $ll.Font = Fnt 12 $false
    $ll.BackColor = [System.Drawing.Color]::Transparent
    $ll.LinkColor = $C_CYAN
    $ll.ActiveLinkColor = $C_AMBER
    $ll.VisitedLinkColor = $C_CYAN
    $ll.LinkBehavior = [System.Windows.Forms.LinkBehavior]::AlwaysUnderline
    $ll.Tag = $url
    $ll.Add_LinkClicked({ param($sender, $e) if ($sender.Tag) { Start-Process -FilePath ([string]$sender.Tag) } })
    $parent.Controls.Add($ll)
    return $ll
}

function Get-RegVal([string]$out, [string]$name) {
    $pat = '(?im)^.{0,90}?\b' + $name + '\b\s*(?:\(\+0x[0-9a-fA-F]+\))?\s*=\s*(?:0x)?([0-9a-fA-F]{1,8})\b'
    $m = [regex]::Matches($out, $pat)
    if ($m.Count -eq 0) { return '' }
    $hex = $m[$m.Count - 1].Groups[1].Value.ToLower().PadLeft(8, '0')
    return ('0x' + $hex)
}

function Format-Status([string]$ss0, [string]$ss1) {
    if (-not $ss0) { return @{ text = '状态未知 · 读不到显卡寄存器'; color = $C_AMBER; unlocked = $false; known = $false } }
    if ($ss0 -eq '0x88888888' -and $ss1 -eq '0x00000008') {
        return @{ text = '已解锁 · 半速张量核已打开'; color = $C_GREEN; unlocked = $true; known = $true }
    }
    return @{ text = '未解锁 · 关机再开机可自动解锁'; color = $C_RED; unlocked = $false; known = $true }
}

# ---------------- help content (open-source badge + author + usage) ----------------
$script:helpSections = @(
    @{ h = '怎么用（三步）'; b = "1. 首次：点「一键解锁」。面板会禁用显卡并重启一次。`r`n2. 开机时在后台上解开锁，1 分钟内显示自动恢复成 3840x2160。`r`n3. 以后只要正常关机再开机就会自动解锁，不用点任何按钮。" },
    @{ h = '怎么确认真的解锁了'; b = "点「测一下当前算力」：BF16 约 116 TFLOP 以上＝已解锁；约 56 TFLOP＝未解锁。也可以看顶部大字：绿色「已解锁」就是生效了。" },
    @{ h = '想关掉（恢复原样）'; b = "点「恢复原样（关掉自动挡）」：会启用显卡并停用三个计划任务（不删除），解锁值在下次重启、断电后自然失效。想再开回来，点「一键解锁」重新走一次即可。" },
    @{ h = '开源徽标 · 许可证'; b = "本项目是 Zagitta/gpu-unlock（Linux 内核模块，GPL-2.0）的 Windows 移植 + 开机调度层。`r`n许可证：GPL-2.0。固件资产由 NVIDIA 开源内核模块源码现场抽取，不随包分发。" },
    @{ h = '作者 / 反馈'; b = "作者：X-WIDE（B 站、GitHub、邮箱见本页最下方「出处与致谢」，可直接点开）`r`n出问题把日志发作者：C:\ProgramData\GpuUnlock\boot-unlock-*.log（开机解锁）与 disable-at-shutdown.log（关机禁用）。" },
    @{ h = '已知限制'; b = "只在 GA102（3090 Ti / 3090 / 3080 Ti / 3080 / A6000）真机验证过；40 系上游标记实验性，50 系不支持。开机后约 30-60 秒显示是基础分辨率，恢复后正常。测试模式水印无法去除（关掉测试签名会让驱动加载不了）。" }
)
$script:helpTitle = 'GPU-UNLOCK · 使用说明与开源信息'

# footer credits shown at the very bottom of the help page (clickable links included)
$script:creditLines = @(
    '本包：GPU-UNLOCK · Windows 开机自动挡 v3.2 · 2026-11-04 · 许可证 GPL-2.0',
    '最源头：Zagitta/gpu-unlock（Linux 内核模块，整套解锁技术的原始出处，GPL-2.0）',
    'Windows 分支版：windows-GPU-UNLOCK（EFI 预启动解锁路线，与本包同一技术脉络）',
    '作者：X-WIDE · xiupk@sina.com.cn'
)
$script:creditLinks = @(
    @{ t = 'https://github.com/Zagitta/gpu-unlock'; u = 'https://github.com/Zagitta/gpu-unlock' },
    @{ t = 'https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK'; u = 'https://github.com/windows-GPU-UNLOCK/Windows-GPU-UNLOCK' }
)
# author's own addresses - each one clickable (B 站 / GitHub / 邮箱)
$script:authorLinks = @(
    @{ t = 'B 站：space.bilibili.com/374064919'; u = 'https://space.bilibili.com/374064919' },
    @{ t = 'GitHub：github.com/XWIDE'; u = 'https://github.com/XWIDE' },
    @{ t = '写信：xiupk@sina.com.cn'; u = 'mailto:xiupk@sina.com.cn' }
)

# ---------------- main window ----------------
$W = 1020
$H = 740
$form = New-Object System.Windows.Forms.Form
$form.Text = ('GPU 解锁面板 v' + $ver + ' · 开机自动挡')
$form.ClientSize = New-Object System.Drawing.Size($W, $H)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $C_BG
$form.Font = Fnt 13 $false

$lblTitle = New-Lbl $form 18 12 700 46 'GPU-UNLOCK' 30 $true $C_TITLE
$lblSub = New-Lbl $form 20 58 760 22 ('// INSTALL EDITION · Windows 开机自动挡 · v' + $ver) 13 $false $C_CYAN
$btnHelp = New-Btn $form 962 16 40 40 '?' $C_CHIP 18
$btnHelp.ForeColor = $C_CYAN
$btnHelp.FlatAppearance.BorderSize = 1
$btnHelp.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(58, 92, 130)

$chipA = New-Chip $form 18 86 190 28 '⚡ Ampere 30 系' $C_CYAN
$chipB = New-Chip $form 216 86 170 28 'GA102 已实测' $C_GREEN
$chipC = New-Chip $form 394 86 170 28 '算力 ×2.07' $C_AMBER

$cardHero = New-Card $form 18 128 984 92
$barHero = $cardHero.Controls[0]
$lblHero = New-Lbl $cardHero 24 10 720 40 '正在读显卡状态…' 26 $true $C_MUT
$lblDetail = New-Lbl $cardHero 24 56 540 20 '显卡 · 驱动 · 分辨率读取中' 12 $false $C_DIM
$lblSs0 = New-Lbl $cardHero 576 54 196 22 'SS0 未读到' 12 $true $C_MUT
$lblSs1 = New-Lbl $cardHero 780 54 180 22 'SS1 未读到' 12 $true $C_MUT

$cardCalc = New-Card $form 18 232 486 150
$lblCalcT = New-Lbl $cardCalc 16 10 300 22 '算力复测 · COMPUTE RE-TEST' 13 $true $C_CYAN
$lblRatio = New-Lbl $cardCalc 300 8 170 24 '性能提升 —' 13 $true $C_GREEN
$lblRatio.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblBfT = New-Lbl $cardCalc 16 40 120 20 'BF16' 12 $false $C_MUT
$lblBf = New-Lbl $cardCalc 16 60 220 40 '—' 26 $true $C_TXT
$lblBfU = New-Lbl $cardCalc 16 102 220 18 'TFLOPS · 解锁后实测' 12 $false $C_DIM
$lblFpT = New-Lbl $cardCalc 250 40 120 20 'FP16' 12 $false $C_MUT
$lblFp = New-Lbl $cardCalc 250 60 220 40 '—' 26 $true $C_TXT
$lblFpU = New-Lbl $cardCalc 250 102 220 18 'TFLOPS · 解锁后实测' 12 $false $C_DIM
$lblBase = New-Lbl $cardCalc 16 124 300 18 '未解锁基线 56.33 TFLOPS' 12 $false $C_MUT

$cardTask = New-Card $form 516 232 486 150
$lblTaskT = New-Lbl $cardTask 16 10 320 22 '开机自动挡 · 任务状态' 13 $true $C_CYAN
$lblTaskBadge = New-Lbl $cardTask 330 8 140 24 '读取中' 13 $true $C_MUT
$lblTaskBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblT1 = New-Lbl $cardTask 16 42 454 20 '● 开机解锁任务 · 读取中' 12 $false $C_MUT
$lblT2 = New-Lbl $cardTask 16 68 454 20 '● 关机禁用任务 · 读取中' 12 $false $C_MUT
$lblT3 = New-Lbl $cardTask 16 94 454 20 '● 兜底任务（开机动后 5 分钟）· 读取中' 12 $false $C_MUT
$lblT4 = New-Lbl $cardTask 16 122 454 18 '解锁值存在易失寄存器，断电即失效' 12 $false $C_DIM

$btnUnlock = New-Btn $form 18 396 300 48 '一键解锁（会重启一次）' $C_BLUE 16
$btnMeasure = New-Btn $form 330 396 250 48 '测一下当前算力' $C_DARKBLUE 16
$btnRestore = New-Btn $form 592 396 410 48 '恢复原样（关掉自动挡）' $C_DANGER 16

$btnDesk = New-Btn $form 18 452 300 40 '桌面修复（图标大小）' $C_CHIP 14
$btnIconDown = New-Btn $form 330 452 120 40 '图标 小 −' $C_CHIP 14
$btnIconUp = New-Btn $form 462 452 120 40 '图标 大 +' $C_CHIP 14
$lblIconSize = New-Lbl $form 592 458 410 28 '当前图标 64 px（点上面按钮调整）' 13 $false $C_MUT

$lblLogT = New-Lbl $form 18 500 400 22 '运行记录' 13 $true $C_TXT
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 524)
$txtLog.Size = New-Object System.Drawing.Size(984, 132)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtLog.Font = New-Object System.Drawing.Font('Consolas', (12 * 72 / 96))
$txtLog.BackColor = $C_LOG
$txtLog.ForeColor = $C_LOGTXT
$form.Controls.Add($txtLog)

$lblNote = New-Lbl $form 18 666 984 46 '失败兜底：解锁前后都会把显卡重新启用，另有开机后 5 分钟触发的补救任务。日志目录 C:\ProgramData\GpuUnlock\' 12 $false $C_DIM

# ---------------- behaviour ----------------
function Log([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $m
    $txtLog.AppendText($line + "`r`n")
    return $line
}

function Apply-Bench([double]$bf, [double]$fp) {
    $lblBf.Text = ('{0:N2}' -f $bf)
    $lblBf.ForeColor = $C_TXT
    $lblFp.Text = ('{0:N2}' -f $fp)
    $lblFp.ForeColor = $C_TXT
    $lblRatio.Text = ('性能提升 {0}×' -f [math]::Round($bf / 56.33, 2))
}

function Load-BenchCache {
    if (-not (Test-Path $benchCache)) { return $false }
    try {
        $v = (Get-Content -LiteralPath $benchCache -Raw).Trim() -split '\|'
        if ($v.Count -ge 2) { Apply-Bench ([double]$v[0]) ([double]$v[1]); return $true }
    } catch { }
    return $false
}

function Get-TaskReady([string]$name) {
    try {
        $q = & schtasks.exe /query /tn $name /fo LIST 2>&1
        return [bool](($q -join ' ') -match '就绪|Ready|Running')
    } catch { return $false }
}

function Invoke-Cmd([string]$file, [string[]]$cmdArgs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $file @cmdArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $code = -1
    }
    $sw.Stop()
    return @{ out = $out; code = $code; sec = [int]$sw.Elapsed.TotalSeconds }
}

function Get-Probe {
    if (-not (Test-Path $exe)) { return @{ out = ''; code = -1 } }
    return (Invoke-Cmd $exe @('real', '--probe'))
}

function Get-Detail {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpu) { return ($gpu.Name + ' · 驱动 ' + $gpu.DriverVersion + ' · ' + $gpu.CurrentHorizontalResolution + 'x' + $gpu.CurrentVerticalResolution) }
    return '显卡信息读取失败'
}

function Update-Hero([string]$ss0, [string]$ss1) {
    $st = Format-Status $ss0 $ss1
    $lblHero.Text = $st.text
    $lblHero.ForeColor = $st.color
    $barHero.BackColor = $st.color
    $s0t = '未读到'
    if ($ss0) { $s0t = $ss0 }
    $s1t = '未读到'
    if ($ss1) { $s1t = $ss1 }
    $lblSs0.Text = ('SS0 ' + $s0t)
    $lblSs1.Text = ('SS1 ' + $s1t)
    $lblSs0.ForeColor = $C_MUT
    $lblSs1.ForeColor = $C_MUT
    return $st
}

function Update-Tasks {
    $b = Get-TaskReady $taskBoot
    $o = Get-TaskReady $taskOff
    $r = Get-TaskReady $taskRescue
    $on = ($b -and $o)
    $t1t = '缺失'; if ($b) { $t1t = '就绪' }
    $t2t = '缺失'; if ($o) { $t2t = '就绪' }
    $t3t = '缺失'; if ($r) { $t3t = '就绪' }
    $lblT1.Text = '● 开机解锁任务 · ' + $t1t
    $lblT2.Text = '● 关机禁用任务 · ' + $t2t
    $lblT3.Text = '● 兜底任务（开机后 5 分钟）· ' + $t3t
    $lblT1.ForeColor = if ($b) { $C_GREEN } else { $C_AMBER }
    $lblT2.ForeColor = if ($o) { $C_GREEN } else { $C_AMBER }
    $lblT3.ForeColor = if ($r) { $C_GREEN } else { $C_AMBER }
    $lblTaskBadge.Text = if ($on) { '自动挡已开启' } else { '自动挡未开启' }
    $lblTaskBadge.ForeColor = if ($on) { $C_GREEN } else { $C_AMBER }
    return $on
}

function Read-State([bool]$quiet) {
    $r = Get-Probe
    $ss0 = Get-RegVal $r.out 'SS0'
    $ss1 = Get-RegVal $r.out 'SS1'
    $st = Update-Hero $ss0 $ss1
    $lblDetail.Text = Get-Detail
    if (-not $quiet) {
        if ($r.out.Trim() -eq '') { Log '探针一行都没打印（解锁驱动可能没起来），状态未知' }
        else { Log ('读数 SS0=' + $ss0 + ' SS1=' + $ss1) }
    }
    return @{ ss0 = $ss0; ss1 = $ss1; state = $st }
}

function Confirm([string]$question, [string]$detail) {
    $r = [System.Windows.Forms.MessageBox]::Show($form, ($detail + "`r`n`r`n" + $question), 'GPU 解锁面板', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-Adapter {
    return (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1)
}

function New-HelpForm {
    $hf = New-Object System.Windows.Forms.Form
    $hf.Text = $script:helpTitle
    $hf.ClientSize = New-Object System.Drawing.Size(700, 700)
    $hf.StartPosition = 'CenterParent'
    $hf.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $hf.MaximizeBox = $false
    $hf.MinimizeBox = $false
    $hf.BackColor = $C_BG
    $hf.Font = Fnt 13 $false

    # absolute layout: Dock=Fill + a sibling Bottom button proved unreliable on PS 5.1
    $sp = New-Object System.Windows.Forms.Panel
    $sp.Location = New-Object System.Drawing.Point(0, 0)
    $sp.Size = New-Object System.Drawing.Size(700, 632)
    $sp.AutoScroll = $true
    $sp.BackColor = $C_BG
    $hf.Controls.Add($sp)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '知道了'
    $btn.Location = New-Object System.Drawing.Point(0, 632)
    $btn.Size = New-Object System.Drawing.Size(700, 56)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.BackColor = $C_BLUE
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = Fnt 16 $true
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $hf.Controls.Add($btn)
    $btn.BringToFront()

    $g = $sp.CreateGraphics()
    $y = 14
    $t = New-Lbl $sp 20 $y 640 34 $script:helpTitle 18 $true $C_TITLE
    $y += 42
    $tb = New-Lbl $sp 20 $y 640 22 ('v' + $ver + ' · 开源 GPL-2.0 · GA102 真机验证') 12 $false $C_CYAN
    $y += 34
    foreach ($s in $script:helpSections) {
        $hd = New-Lbl $sp 20 $y 640 24 ('▍' + $s.h) 14 $true $C_CYAN
        $y += 28
        $body = $s.b -replace '`r`n', ' '
        $sz = $g.MeasureString($s.b, (Fnt 12 $false), 640)
        $bh = [int][math]::Ceiling($sz.Height) + 8
        $bd = New-Lbl $sp 20 $y 640 $bh $s.b 12 $false $C_MUT
        $y += $bh + 12
    }
    # ---- footer credits (same shape as the house credit block: name/version/date, source, links, contact) ----
    $y += 10
    $ln = New-Object System.Windows.Forms.Label
    $ln.Location = New-Object System.Drawing.Point(20, $y)
    $ln.Size = New-Object System.Drawing.Size(640, 2)
    $ln.BackColor = $C_CHIP
    $ln.Text = ''
    $sp.Controls.Add($ln)
    $y += 14
    $fh = New-Lbl $sp 20 $y 640 24 '▍出处与致谢' 14 $true $C_CYAN
    $y += 30
    $c0 = New-Lbl $sp 20 $y 640 20 $script:creditLines[0] 12 $true $C_TXT
    $y += 22
    $c1 = New-Lbl $sp 20 $y 640 20 $script:creditLines[1] 12 $false $C_MUT
    $y += 22
    $l1 = New-Link $sp 34 $y 620 20 $script:creditLinks[0].t $script:creditLinks[0].u
    $y += 22
    $c2 = New-Lbl $sp 20 $y 640 20 $script:creditLines[2] 12 $false $C_MUT
    $y += 22
    $l2 = New-Link $sp 34 $y 620 20 $script:creditLinks[1].t $script:creditLinks[1].u
    $y += 26
    $c3 = New-Lbl $sp 20 $y 640 20 $script:creditLines[3] 12 $true $C_CYAN
    $y += 24
    $al1 = New-Link $sp 34 $y 300 20 $script:authorLinks[0].t $script:authorLinks[0].u
    $al2 = New-Link $sp 340 $y 300 20 $script:authorLinks[1].t $script:authorLinks[1].u
    $y += 22
    $al3 = New-Link $sp 34 $y 300 20 $script:authorLinks[2].t $script:authorLinks[2].u
    $y += 26
    $c4 = New-Lbl $sp 20 $y 640 20 '固件资产不随包分发，由 NVIDIA 开源内核模块源码现场抽取；上游许可证 GPL-2.0 / NVIDIA 生成源文件 MIT。' 12 $false $C_DIM
    $y += 22
    $g.Dispose()
    $sp.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($y + 10))
    $sp.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)

    $script:helpForm = $hf
    $script:helpPanel = $sp
    $btn.Add_Click({ $script:helpForm.Close() })
    return $hf
}

function Show-Help {
    $hf = New-HelpForm
    [void]$hf.ShowDialog($form)
    $hf.Dispose()
}

$btnHelp.Add_Click({ Show-Help })

$btnUnlock.Add_Click({
    $ok = Confirm '现在就执行吗？' ('将禁用显卡并重启一次（约 1-2 分钟）。开机后会自动解锁，再自动把显示恢复成 3840x2160。')
    if (-not $ok) { Log '已取消'; return }
    $g = Get-Adapter
    if (-not $g) { Log '找不到 PCI 显卡，未执行'; return }
    Log ('禁用显卡 ' + $g.InstanceId)
    try {
        Disable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop
        Log '已发送禁用命令'
    } catch {
        Log ('禁用失败：' + $_.Exception.Message)
        return
    }
    Start-Sleep -Seconds 2
    $g2 = Get-PnpDevice -InstanceId $g.InstanceId -ErrorAction SilentlyContinue
    $st2 = if ($g2) { $g2.Status } else { 'missing' }
    Log ('禁用后状态=' + $st2)
    Log '10 秒后重启，开机时自动解锁'
    & shutdown.exe /r /t 10 /f /c 'gpu unlock: cold boot'
})

$btnMeasure.Add_Click({
    $txtLog.AppendText("`r`n")
    if (-not (Test-Path $probePy)) { Log ('缺少测速脚本：' + $probePy); return }
    Log '正在测 BF16/FP16 算力（约 10 秒）…'
    $r = Invoke-Cmd $pyExe @($probePy)
    foreach ($ln in ($r.out -split "`r?`n")) {
        if ($ln -match 'BF16|FP16|device:') { Log ('  ' + $ln.Trim()) }
    }
    $mb = [regex]::Match($r.out, 'BF16\s+n=\d+\s+[\d.]+\s*ms\s+([\d.]+)\s+TFLOPS')
    $mf = [regex]::Match($r.out, 'FP16\s+n=\d+\s+[\d.]+\s*ms\s+([\d.]+)\s+TFLOPS')
    if ($mb.Success) {
        $tbv = [double]$mb.Groups[1].Value
        $lblBf.Text = ('{0:N2}' -f $tbv)
        $lblBf.ForeColor = $C_TXT
        if ($mf.Success) {
            $tfv = [double]$mf.Groups[1].Value
            $lblFp.Text = ('{0:N2}' -f $tfv)
            $lblFp.ForeColor = $C_TXT
        }
        $ratio = [math]::Round($tbv / 56.33, 2)
        $lblRatio.Text = ('性能提升 {0}×' -f $ratio)
        Log ('结论：BF16 ' + $tbv + ' TFLOPS（未解锁基线 56.33 的 ' + $ratio + ' 倍）')
        try {
            $tfKeep = 0.0
            if ($mf.Success) { $tfKeep = [double]$mf.Groups[1].Value }
            $null = New-Item -ItemType Directory -Path $logRoot -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText($benchCache, ('{0}|{1}' -f $tbv, $tfKeep))
        } catch { }
    } else {
        Log '没解析到读数，请把上方日志发给作者'
    }
})

$btnRestore.Add_Click({
    $ok = Confirm '确定恢复原样吗？' ('将启用显卡，并停用三个计划任务（不会删除）。解锁值会在下次重启后失效。')
    if (-not $ok) { Log '已取消'; return }
    $g = Get-Adapter
    if ($g) {
        try {
            Enable-PnpDevice -InstanceId $g.InstanceId -Confirm:$false -ErrorAction Stop
            Log '已启用显卡'
        } catch { Log ('启用失败：' + $_.Exception.Message) }
    }
    foreach ($t in @($taskBoot, $taskOff, $taskRescue)) {
        $o = & schtasks.exe /change /tn $t /disable 2>&1
        Log ('停用 ' + $t + ' → ' + (($o -join ' ').Trim()))
    }
    Update-Tasks | Out-Null
})

# ---------------- desktop icon repair ----------------
function Get-DeskSize {
    $s = 64
    if (Test-Path -LiteralPath $deskCfg) {
        foreach ($l in (Get-Content -LiteralPath $deskCfg -Encoding UTF8)) {
            if ($l -match '^\s*IconSize\s*=\s*(\d+)\s*$') { $s = [int]$matches[1] }
        }
    } else {
        $k = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $v = (Get-ItemProperty -Path $k -Name IconSize -ErrorAction SilentlyContinue).IconSize
        if ($null -ne $v) { $s = [int]$v }
    }
    return $s
}

function Update-DeskLabel {
    $s = Get-DeskSize
    $lblIconSize.Text = ('当前图标 ' + $s + ' px（点上面按钮调整）')
    $lblIconSize.ForeColor = $C_MUT
}

function Invoke-DeskFix([int]$size) {
    if (-not (Test-Path -LiteralPath $deskFix)) {
        Log ('缺少桌面修复脚本：' + $deskFix)
        return $false
    }
    Log ('桌面修复：图标 ' + $size + ' px，必要时会重启一次资源管理器（任务栏闪一下）')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $dargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $deskFix + '"'), '-IconSize', $size.ToString(), '-NoPause')
    if ($isAdmin) { $dargs += '-Stop360' }
    $env:GU_NO_PAUSE = '1'
    $r = Invoke-Cmd $ps $dargs
    foreach ($ln in ($r.out -split "`r?`n")) {
        if ($ln -match '=== desk-fix|before:|after:|restarting|stopped:|still missing|cannot stop') { Log ('  ' + $ln.Trim()) }
    }
    Update-DeskLabel
    if ($r.out -match 'ok=True') { Log '桌面修复完成' } else { Log '桌面修复未完全成功，日志：C:\ProgramData\GpuUnlock\desk-fix.log' }
    return ($r.out -match 'ok=True')
}

$btnDesk.Add_Click({
    $s = Get-DeskSize
    Log '手动执行桌面修复（图标层缺失才会重启资源管理器）'
    Invoke-DeskFix $s | Out-Null
})

$btnIconDown.Add_Click({
    $s = Get-DeskSize
    $n = $s - 16
    if ($n -lt 32) { $n = 32 }
    Invoke-DeskFix $n | Out-Null
})

$btnIconUp.Add_Click({
    $s = Get-DeskSize
    $n = $s + 16
    if ($n -gt 128) { $n = 128 }
    Invoke-DeskFix $n | Out-Null
})

$form.Add_Shown({
    Read-State $false | Out-Null
    Update-Tasks | Out-Null
    if (Load-BenchCache) { Log '已载入上次算力读数（点「测一下当前算力」可刷新）' }
    Update-DeskLabel
    Log ('显示：' + (Get-Detail))
    Log ('面板版本 ' + $ver + ' · 深色版 · 解锁路径：开机冷启动（--cold）')
})

function Get-AllControls($c) {
    foreach ($x in $c.Controls) {
        $x
        Get-AllControls $x
    }
}

# ---------------- self test ----------------
if ($SelfTest) {
    $script:fail = 0
    function Note([string]$name, [bool]$ok, [string]$extra) {
        $tag = 'FAIL'
        if ($ok) { $tag = 'PASS' }
        if (-not $ok) { $script:fail++ }
        Write-Output ('{0} {1} {2}' -f $tag, $name, $extra)
    }
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(30, 20)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.Application]::DoEvents()

    Note '窗口可见' ([bool]$form.Visible) ('Visible=' + $form.Visible)
    $all = @(Get-AllControls $form)
    Note '控件数量' ($all.Count -ge 25) ('控件=' + $all.Count)
    Note '深色主题生效' ($form.BackColor -eq $C_BG) ('bg=' + $form.BackColor.Name)
    foreach ($b in @($btnUnlock, $btnMeasure, $btnRestore, $btnHelp)) {
        Note ('按钮在位 ' + $b.Text) ([bool]($b.Visible -and $b.Height -ge 32)) ('h=' + $b.Height + ' w=' + $b.Width)
    }
    Note '帮助按钮命中区' (($btnHelp.Width -ge 32) -and ($btnHelp.Height -ge 32)) ('w=' + $btnHelp.Width + ' h=' + $btnHelp.Height)
    Note '帮助按钮真在窗体上' ([bool]($form.Controls.Contains($btnHelp))) 'Contains=True'

    $badF = 0
    foreach ($c in $all) {
        if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.Button]) {
            $px = [math]::Round($c.Font.SizeInPoints * 96 / 72, 1)
            if ($px -lt 12) {
                $badF++
                Write-Output ('  small font: ' + $px + 'px  ' + $c.Text)
            }
        }
    }
    Note '字号不小于 12px' ($badF -eq 0) ('违规=' + $badF)

    $clip = 0
    $g0 = $form.CreateGraphics()
    foreach ($c in $all) {
        if ($c -is [System.Windows.Forms.Label] -and $c.Text.Length -gt 0 -and $c.Width -gt 20) {
            $need = $g0.MeasureString($c.Text, $c.Font, [int]$c.Width)
            if ($need.Height -gt ($c.Height + 2)) {
                $clip++
                Write-Output ('  clip: ' + $c.Text.Substring(0, [math]::Min(18, $c.Text.Length)) + ' need=' + [int]$need.Height + ' have=' + $c.Height)
            }
        }
    }
    $g0.Dispose()
    Note '文字不裁切' ($clip -eq 0) ('裁切=' + $clip)

    $s1 = Format-Status '0x88888888' '0x00000008'
    $s2 = Format-Status '0x04745146' '0x00000007'
    $s3 = Format-Status '' ''
    Note '判定器认已解锁' ([bool]($s1.unlocked -and $s1.known)) $s1.text
    Note '判定器认未解锁' ([bool]((-not $s2.unlocked) -and $s2.known)) $s2.text
    Note '判定器认未知' (-not $s3.known) $s3.text
    $v0 = Get-RegVal ("SS0          (+0x82381c) = 88888888`r`n") 'SS0'
    $v1 = Get-RegVal ("SS1          (+0x823820) = 00000008`r`n") 'SS1'
    Note '读数解析 SS0' ($v0 -eq '0x88888888') ('got ' + $v0)
    Note '读数解析 SS1' ($v1 -eq '0x00000008') ('got ' + $v1)

    $ht = ($script:helpSections | ForEach-Object { $_.h + ' ' + $_.b }) -join ' '
    Note '帮助含使用说明' ([bool](($ht -match '一键解锁') -and ($ht -match '关机再开机'))) 'steps'
    Note '帮助含算力判据' ([bool](($ht -match '116') -and ($ht -match '56'))) 'bf16 rule'
    Note '帮助含开源徽标' ([bool](($ht -match 'gpu-unlock') -and ($ht -match 'GPL-2\.0'))) 'oss badge'
    Note '帮助含作者信息' ([bool]($ht -match '作者')) 'author'
    Note '帮助含已知限制' ([bool]($ht -match '已知限制')) 'limits'
    $hc = ($script:creditLines -join ' ') + ' ' + (($script:creditLinks | ForEach-Object { $_.t + ' ' + $_.u }) -join ' ') + ' ' + (($script:authorLinks | ForEach-Object { $_.t + ' ' + $_.u }) -join ' ')
    Note '致谢含最源头链接' ([bool]($hc -match 'Zagitta/gpu-unlock' -and $hc -match 'github\.com/Zagitta/gpu-unlock')) 'root source'
    Note '致谢含 Windows 分支版' ([bool]($hc -match 'windows-GPU-UNLOCK' -and $hc -match 'github\.com/windows-GPU-UNLOCK')) 'windows port'
    Note '致谢含作者联系方式' ([bool](($hc -match 'X-WIDE') -and ($hc -match 'xiupk@sina\.com\.cn'))) 'contact'
    Note '致谢含 B 站与 GitHub 地址' ([bool](($hc -match 'space\.bilibili\.com/374064919') -and ($hc -match 'github\.com/XWIDE'))) 'author urls'
    Note '致谢含版本与日期' ([bool](($hc -match ('v' + [regex]::Escape($ver))) -and ($hc -match '2026-11-04'))) 'ver+date'
    try {
        $hf = New-HelpForm
        $hAll = @(Get-AllControls $hf)
        $hLbl = @($hAll | Where-Object { $_ -is [System.Windows.Forms.Label] })
        $hLnk = @($hAll | Where-Object { $_ -is [System.Windows.Forms.LinkLabel] })
        $hBad = 0
        foreach ($c in $hAll) {
            if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.Button] -or $c -is [System.Windows.Forms.LinkLabel]) {
                if (($c.Font.SizeInPoints * 96 / 72) -lt 12) { $hBad++ }
            }
        }
        $badUrl = @($hLnk | Where-Object { -not ($_.Tag -match '^(https?://|mailto:)') })
        Note '帮助面板元素就位' ([bool](($hAll.Count -ge 14) -and ($hLbl.Count -ge 12))) ('控件=' + $hAll.Count + ' 标签=' + $hLbl.Count)
        Note '帮助底部可点击链接' (($hLnk.Count -ge 5) -and ($badUrl.Count -eq 0)) ('链接=' + $hLnk.Count + ' 坏链接=' + $badUrl.Count)
        Note '作者三个地址可点' ([bool](($hLnk | Where-Object { $_.Tag -eq 'https://space.bilibili.com/374064919' }) -and ($hLnk | Where-Object { $_.Tag -eq 'https://github.com/XWIDE' }) -and ($hLnk | Where-Object { $_.Tag -eq 'mailto:xiupk@sina.com.cn' }))) 'bili+github+mail'
        Note '帮助面板字号达标' ($hBad -eq 0) ('违规=' + $hBad)
        $hf.Dispose()
    } catch {
        Note '帮助面板元素就位' $false $_.Exception.Message
    }

    $src = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    Note '任务名在位' ([bool](($src -match 'GpuUnlockOff') -and ($src -match 'GpuUnlockBoot'))) 'boot+off+rescue'
    Note 'exe 存在' (Test-Path $exe) $exe
    Note '测速脚本存在' (Test-Path $probePy) 'bf16_probe.py'
    Note '桌面修复脚本存在' (Test-Path -LiteralPath $deskFix) 'desk-fix.ps1'
    Note '桌面三按钮命中区' (($btnDesk.Height -ge 32) -and ($btnIconUp.Height -ge 32) -and ($btnIconDown.Height -ge 32)) ('h=' + $btnDesk.Height)
    $allD = @(Get-AllControls $form)
    Note '桌面三按钮真在窗体上' ([bool](($allD -contains $btnDesk) -and ($allD -contains $btnIconUp) -and ($allD -contains $btnIconDown))) 'Contains=True'
    $dSize = Get-DeskSize
    Note '图标尺寸读数合理' (($dSize -ge 32) -and ($dSize -le 128)) ('size=' + $dSize)
    $tn = @([regex]::Matches($src, '\[System\.Windows\.Forms\.[A-Za-z]+\]') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $badT = 0
    foreach ($t in $tn) {
        try { $null = Invoke-Expression ($t + '.FullName') } catch { $badT++; Write-Output ('  type missing: ' + $t) }
    }
    Note 'WinForms 类型全可解析' ($badT -eq 0) ('扫到 ' + $tn.Count + ' 个')

    Write-Output ('SELFTEST 结论 FAIL=' + $script:fail)
    $form.Close()
    return
}

if ($Shot) {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(60, 60)
    $form.Add_Shown({
        Start-Sleep -Milliseconds 1500
        [System.Windows.Forms.Application]::DoEvents()
        $w = $form.ClientSize.Width
        $h = $form.ClientSize.Height
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
        $outDir = Join-Path $root '_shots'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $p = Join-Path $outDir 'panel_v3.png'
        $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Output ('SHOT ' + $p)

        $hf = New-HelpForm
        $hf.StartPosition = 'Manual'
        $hf.Location = New-Object System.Drawing.Point(0, 0)
        $hf.Show()
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:helpPanel) { $script:helpPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0) }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        $b2 = New-Object System.Drawing.Bitmap($hf.ClientSize.Width, $hf.ClientSize.Height)
        $hf.DrawToBitmap($b2, (New-Object System.Drawing.Rectangle(0, 0, $hf.ClientSize.Width, $hf.ClientSize.Height)))
        $p2 = Join-Path $outDir 'panel_v3_help.png'
        $b2.Save($p2, [System.Drawing.Imaging.ImageFormat]::Png)
        $b2.Dispose()
        Write-Output ('SHOT ' + $p2)
        if ($script:helpPanel) { $script:helpPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, 9999) }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.Application]::DoEvents()
        $b3 = New-Object System.Drawing.Bitmap($hf.ClientSize.Width, $hf.ClientSize.Height)
        $hf.DrawToBitmap($b3, (New-Object System.Drawing.Rectangle(0, 0, $hf.ClientSize.Width, $hf.ClientSize.Height)))
        $p3 = Join-Path $outDir 'panel_v3_help_foot.png'
        $b3.Save($p3, [System.Drawing.Imaging.ImageFormat]::Png)
        $b3.Dispose()
        Write-Output ('SHOT ' + $p3)
        $hf.Close()
        $form.Close()
    })
}

[void]$form.ShowDialog()
