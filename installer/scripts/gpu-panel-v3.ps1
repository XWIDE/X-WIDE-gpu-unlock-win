param([switch]$SelfTest, [switch]$Shot)

# GPU unlock panel v3 - the boot-time (cold) unlock front end.
# Step 5 of the old panel could never work: by the time Windows is up nvlddmkm owns
# the card and the GSP firmware is already running, so the selector write is refused
# (-138). The only working path is to unlock before the driver binds, which is what
# the three scheduled tasks below automate.

$root = $PSScriptRoot
$exe = Join-Path $root 'gpu_unlock.exe'
$pyExe = 'F:\ComfyUI-aki-v3\python\python.exe'
$probePy = Join-Path $root 'bf16_probe.py'
$taskBoot = 'GpuUnlockBoot'
$taskOff = 'GpuUnlockOff'
$taskRescue = 'GpuUnlockBootRescue'
$logRoot = Join-Path $env:ProgramData 'GpuUnlock'

# Reading the selectors needs the unlock driver, which needs an elevated process.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest -and -not $Shot) {
	$argLine = '-STA -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
	Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
	return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$C_TEXT = [System.Drawing.Color]::FromArgb(26, 26, 26)
$C_MUTED = [System.Drawing.Color]::FromArgb(85, 85, 85)
$C_OK = [System.Drawing.Color]::FromArgb(27, 126, 60)
$C_BAD = [System.Drawing.Color]::FromArgb(179, 38, 30)
$C_BLUE = [System.Drawing.Color]::FromArgb(26, 95, 180)
$C_GRAY = [System.Drawing.Color]::FromArgb(107, 107, 107)
$C_AMBER = [System.Drawing.Color]::FromArgb(138, 90, 0)

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
	$parent.Controls.Add($l)
	return $l
}

function New-Btn($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $back) {
	$b = New-Object System.Windows.Forms.Button
	$b.Location = New-Object System.Drawing.Point($x, $y)
	$b.Size = New-Object System.Drawing.Size($w, $h)
	$b.Text = $text
	$b.Font = Fnt 15 $true
	$b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
	$b.BackColor = $back
	$b.ForeColor = [System.Drawing.Color]::White
	$b.FlatAppearance.BorderSize = 0
	$b.Cursor = [System.Windows.Forms.Cursors]::Hand
	$parent.Controls.Add($b)
	return $b
}

function Get-RegVal([string]$out, [string]$name) {
	$pat = '(?im)^.{0,90}?\b' + $name + '\b\s*(?:\(\+0x[0-9a-fA-F]+\))?\s*=\s*(?:0x)?([0-9a-fA-F]{1,8})\b'
	$m = [regex]::Matches($out, $pat)
	if ($m.Count -eq 0) { return '' }
	$hex = $m[$m.Count - 1].Groups[1].Value.ToLower().PadLeft(8, '0')
	return ('0x' + $hex)
}

# One place decides what the panel claims, so the UI can be judged without hardware.
function Format-Status([string]$ss0, [string]$ss1) {
	if (-not $ss0) { return @{ text = '状态未知 · 读不到显卡寄存器'; color = $C_AMBER; unlocked = $false; known = $false } }
	if ($ss0 -eq '0x88888888' -and $ss1 -eq '0x00000008') {
		return @{ text = '已解锁 · 半速张量核已打开'; color = $C_OK; unlocked = $true; known = $true }
	}
	return @{ text = '未解锁 · 关机再开机可自动解锁'; color = $C_BAD; unlocked = $false; known = $true }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GPU 解锁面板 v3 · 开机自动挡'
$form.ClientSize = New-Object System.Drawing.Size(1000, 700)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = [System.Drawing.Color]::White
$form.Font = Fnt 15 $false

$lblHero = New-Lbl $form 16 16 968 46 '正在读取显卡状态…' 22 $true $C_MUTED
$lblSub = New-Lbl $form 16 66 968 24 '驱动版本读取中' 13 $false $C_MUTED

$box = New-Object System.Windows.Forms.Panel
$box.Location = New-Object System.Drawing.Point(16, 100)
$box.Size = New-Object System.Drawing.Size(968, 118)
$box.BackColor = [System.Drawing.Color]::FromArgb(247, 247, 247)
$box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($box)
$lblBoxT = New-Lbl $box 14 10 940 24 '开机自动挡：关机会禁用显卡，开机在驱动绑定前解锁' 15 $true $C_TEXT
$lblBox1 = New-Lbl $box 14 40 940 22 '任务状态读取中' 13 $false $C_MUTED
$lblBox2 = New-Lbl $box 14 66 940 40 '解锁值保存在易失寄存器里，断电即失效，所以每次开机都要重新写一次。' 13 $false $C_MUTED

$btnUnlock = New-Btn $form 16 232 300 46 '一键解锁（会重启一次）' $C_BLUE
$btnMeasure = New-Btn $form 332 232 260 46 '测一下当前算力' $C_GRAY
$btnRestore = New-Btn $form 608 232 376 46 '恢复原样（关掉自动挡）' $C_BAD

$lblLogT = New-Lbl $form 16 296 400 24 '运行记录' 14 $true $C_TEXT
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 324)
$txtLog.Size = New-Object System.Drawing.Size(968, 300)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.Font = New-Object System.Drawing.Font('Consolas', (13 * 72 / 96))
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.ForeColor = $C_TEXT
$form.Controls.Add($txtLog)

$lblNote = New-Lbl $form 16 636 968 44 '失败兜底：解锁前后都会把显卡重新启用，另有一个 5 分钟后触发的补救任务。' 12 $false $C_MUTED

function Log([string]$m) {
	$line = (Get-Date -Format 'HH:mm:ss') + '  ' + $m
	$txtLog.AppendText($line + "`r`n")
	return $line
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
	if ($gpu) { return ($gpu.Name + ' · ' + $gpu.DriverVersion + ' · ' + $gpu.CurrentHorizontalResolution + 'x' + $gpu.CurrentVerticalResolution) }
	return '显卡信息读取失败'
}

function Update-Hero([string]$ss0, [string]$ss1) {
	$st = Format-Status $ss0 $ss1
	$lblHero.Text = $st.text
	$lblHero.ForeColor = $st.color
	return $st
}

function Update-Box {
	$b = Get-TaskReady $taskBoot
	$o = Get-TaskReady $taskOff
	$r = Get-TaskReady $taskRescue
	$on = ($b -and $o)
	$t1 = if ($on) { '已开启' } else { '未开启或被禁用' }
	$t2 = if ($b) { '就绪' } else { '缺失' }
	$t3 = if ($o) { '就绪' } else { '缺失' }
	$t4 = if ($r) { '就绪' } else { '缺失' }
	$lblBox1.Text = ('自动挡：' + $t1 + '　·　开机解锁任务 ' + $t2 + '　·　关机禁用任务 ' + $t3 + '　·　兜底任务 ' + $t4)
	$lblBox1.ForeColor = if ($on) { $C_OK } else { $C_AMBER }
	return $on
}

function Read-State([bool]$quiet) {
	$r = Get-Probe
	$ss0 = Get-RegVal $r.out 'SS0'
	$ss1 = Get-RegVal $r.out 'SS1'
	$st = Update-Hero $ss0 $ss1
	if (-not $quiet) {
		if ($r.out.Trim() -eq '') { Log '探针一行都没打印（解锁驱动可能没起来），状态未知' }
		else { Log ('读数 SS0=' + $ss0 + ' SS1=' + $ss1) }
	}
	$s0t = if ($ss0) { $ss0 } else { '未读到' }
	$s1t = if ($ss1) { $ss1 } else { '未读到' }
	$lblSub.Text = (Get-Detail) + '　·　SS0=' + $s0t + '　·　SS1=' + $s1t
	return @{ ss0 = $ss0; ss1 = $ss1; state = $st }
}

function Confirm([string]$question, [string]$detail) {
	$r = [System.Windows.Forms.MessageBox]::Show($form, ($detail + "`r`n`r`n" + $question), 'GPU 解锁面板', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
	return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-Adapter {
	return (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } | Select-Object -First 1)
}

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
	$m = [regex]::Match($r.out, 'BF16\s+n=\d+\s+[\d.]+\s*ms\s+([\d.]+)\s+TFLOPS')
	if ($m.Success) {
		$t = [double]$m.Groups[1].Value
		$ratio = [math]::Round($t / 56.33, 2)
		Log ('结论：BF16 ' + $t + ' TFLOPS（未解锁基线 56.3 的 ' + $ratio + ' 倍）')
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
	Update-Box | Out-Null
})

$form.Add_Shown({
	Read-State $false | Out-Null
	Update-Box | Out-Null
	Log ('显示：' + (Get-Detail))
})

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
	Note '控件数量' ($form.Controls.Count -ge 6) ('控件=' + $form.Controls.Count)
	foreach ($b in @($btnUnlock, $btnMeasure, $btnRestore)) {
		Note ('按钮在位 ' + $b.Text) ([bool]($b.Visible -and $b.Height -ge 32)) ('h=' + $b.Height)
	}
	$badF = 0
	foreach ($c in $form.Controls) {
		if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.Button]) {
			$px = [math]::Round($c.Font.SizeInPoints * 96 / 72, 1)
			if ($px -lt 12) { $badF++ }
		}
	}
	Note '字号不小于 12px' ($badF -eq 0) ('违规=' + $badF)

	$clip = 0
	$g0 = $form.CreateGraphics()
	foreach ($c in $form.Controls) {
		if ($c -is [System.Windows.Forms.Label] -and $c.Text.Length -gt 0) {
			$need = $g0.MeasureString($c.Text, $c.Font, [int]$c.Width)
			if ($need.Height -gt ($c.Height + 2)) {
				$clip++
				Write-Output ('  clip: ' + $c.Text.Substring(0, [math]::Min(16, $c.Text.Length)) + ' need=' + [int]$need.Height + ' have=' + $c.Height)
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
	$src = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
	Note '任务名在位' ([bool](($src -match 'GpuUnlockOff') -and ($src -match 'GpuUnlockBoot'))) 'boot+off+rescue'
	Note 'exe 存在' (Test-Path $exe) $exe
	Note '测速脚本存在' (Test-Path $probePy) 'bf16_probe.py'
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
		$form.Close()
	})
}

[void]$form.ShowDialog()
