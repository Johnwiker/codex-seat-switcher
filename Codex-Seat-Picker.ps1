# Seat Picker  -  dark grey + blue design (compact rows, per-seat actions, drag to reorder)
# Switch = quit Codex -> sync project layout to all seats -> plant the chosen seat's
# workspace id + access token (the refresh token is never replaced) -> reopen Codex.
param([switch]$NoLaunch, [string]$PreviewPng, [string]$PreviewDialog, [switch]$Demo)  # -Demo: made-up seats, for screenshots

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -Namespace SeatPicker -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'

$Title   = 'Seat Picker'
$Dir     = $PSScriptRoot
$Tool    = Join-Path $Dir 'codex_seat_sync.py'
$Config  = Join-Path $Dir 'seats.json'
$Log     = Join-Path $Dir 'launcher.log'
$OwlPng  = Join-Path $Dir 'assets\seat-icon.png'
$OwlIco  = Join-Path $Dir 'assets\seat-icon.ico'
# Python: set SEAT_PICKER_PYTHON to a python.exe to override; otherwise the first python on PATH
$Python  = $env:SEAT_PICKER_PYTHON
if (-not $Python) { $pyCmd = Get-Command python -ErrorAction SilentlyContinue; $Python = if ($pyCmd) { $pyCmd.Source } else { 'python' } }
$AppId   = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
$Dot = [char]0x00B7; $Dash = [char]0x2014

function Write-Log($msg) { Add-Content -Path $Log -Value ("{0}  {1}" -f (Get-Date -Format s), $msg) -Encoding UTF8 }
trap { Write-Log "ERROR: $($_ | Out-String)"; if (-not $PreviewPng) { [System.Windows.Forms.MessageBox]::Show("Picker error:`n`n$_", $Title) | Out-Null }; exit 3 }
Write-Log 'Picker started'

# ---------------- design tokens ----------------
function Hex($bh) { [System.Drawing.ColorTranslator]::FromHtml($bh) }
$Pal = @{
    Bg = Hex '#1E1E20'; Card = Hex '#262629'; CardHover = Hex '#2B2B2F'; Border = Hex '#3A3A3F'; BorderHover = Hex '#4A4A52'
    ActiveBg = Hex '#232A38'; ActiveBorder = Hex '#3B78E7'; Group = Hex '#2B2B2E'; GroupSel = Hex '#1E1E20'; Tile = Hex '#232326'
    Text = Hex '#F4F4F5'; Muted = Hex '#A1A1AA'; Faint = Hex '#71717A'; Ghost = Hex '#4A4A52'
    Blue = Hex '#3B82F6'; BlueFill = Hex '#3478F6'; BlueHover = Hex '#4C8BFA'; BlueTint = Hex '#1E2C47'; BlueTintText = Hex '#5B8DEF'
    Green = Hex '#3DD68C'; Amber = Hex '#FFB224'; Red = Hex '#F05B5B'; Orange = Hex '#FF7A1A'; OrangeHover = Hex '#FF8F3D'
}
$fams = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object Name
function Pick($want, $fallback) { if ($fams -contains $want) { $want } else { $fallback } }
function Font($family, $size, $style = 'Regular') { New-Object System.Drawing.Font($family, [single]$size, [System.Drawing.FontStyle]$style) }
$HeadF  = Pick 'Segoe UI Variable Display Semib' 'Segoe UI Semibold'
$TextF  = Pick 'Segoe UI Variable Text' 'Segoe UI'
$TextSB = Pick 'Segoe UI Variable Text Semibold' 'Segoe UI Semibold'
$IconF  = Pick 'Segoe Fluent Icons' 'Segoe MDL2 Assets'
$Typ = @{
    Title = Font $HeadF 20; Name = Font $TextSB 13.5; Sub = Font $TextF 11.5; Stat = Font $TextF 12; StatB = Font $TextSB 12
    Body = Font $TextF 11; Small = Font $TextF 10; Button = Font $TextSB 11; Chip = Font $TextF 12; Time = Font $TextF 11
    Icon = Font $IconF 13; IconSmall = Font $IconF 10.5; IconBig = Font $IconF 16; Initial = Font $HeadF 13; ChipText = Font $TextF 10; Line3 = Font $TextF 11; Line3B = Font $TextSB 11
}
$Glyph = @{ Play = [string][char]0xE768; Edit = [string][char]0xE70F; Calendar = [string][char]0xE787; Refresh = [string][char]0xE72C
        Sync = [string][char]0xE895; Clock = [string][char]0xE823; Check = [string][char]0xE73E; Folder = [string][char]0xE838
        History = [string][char]0xE81C; Chevron = [string][char]0xE70D; Reset = [string][char]0xE777 }

# ---------------- drawing helpers ----------------
function RoundPath([single]$x, [single]$y, [single]$bw, [single]$bh, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($r * 2, [Math]::Min($bw, $bh))
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $bw - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $bw - $d, $y + $bh - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $bh - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function Smooth($g) { $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit' }
function Fill-Round($g, $color, $x, $y, $bw, $bh, $r) { $p = RoundPath $x $y $bw $bh $r; $b = New-Object System.Drawing.SolidBrush($color); $g.FillPath($b, $p); $b.Dispose(); $p.Dispose() }
function Stroke-Round($g, $color, $width, $x, $y, $bw, $bh, $r) { $p = RoundPath $x $y $bw $bh $r; $pen = New-Object System.Drawing.Pen($color, $width); $g.DrawPath($pen, $p); $pen.Dispose(); $p.Dispose() }
function Draw-Text($g, $text, $font, $color, [single]$x, [single]$y, $align = 'Near') {
    $b = New-Object System.Drawing.SolidBrush($color)
    if ($align -eq 'Far') { $x = $x - $g.MeasureString($text, $font).Width }
    $g.DrawString($text, $font, $b, $x, $y); $b.Dispose()
    return [single]$g.MeasureString($text, $font).Width
}
function Draw-Clipped($g, $text, $font, $color, [single]$x, [single]$y, [single]$maxW) {
    $sf = New-Object System.Drawing.StringFormat; $sf.Trimming = 'EllipsisCharacter'; $sf.FormatFlags = 'NoWrap'
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($text, $font, $b, (New-Object System.Drawing.RectangleF($x, $y, $maxW, ($font.GetHeight($g) + 4))), $sf); $b.Dispose()
}
function Draw-Centered($g, $text, $font, $color, $rect) {
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $rf = New-Object System.Drawing.RectangleF([single]$rect.X, [single]$rect.Y, [single]$rect.Width, [single]$rect.Height)
    $b = New-Object System.Drawing.SolidBrush($color); $g.DrawString($text, $font, $b, $rf, $sf); $b.Dispose()
}
function Load-Image($path) {   # load without locking the file
    if (-not (Test-Path $path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))
}

# ---------------- controls ----------------
function New-Text($text, $x, $y, $font, $color, $bw = 0, $bh = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.UseMnemonic = $false; $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Location = New-Object System.Drawing.Point($x, $y)
    if ($bw -gt 0) { $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($bw, $bh) } else { $l.AutoSize = $true }
    return $l
}
# kinds: primary (blue), tint (blue-tinted "Switch"), ghost (grey), icon (glyph only), orange (round accent), disabled
$BtnPaint = {
    $g = $_.Graphics; Smooth $g; $st = $this.Tag; $r = $this.ClientRectangle
    $bw = $r.Width - 1; $bh = $r.Height - 1
    switch ($st.kind) {
        'primary'  { Fill-Round $g $(if ($st.hover) { $Pal.BlueHover } else { $Pal.BlueFill }) 0 0 $bw $bh 9; Draw-Centered $g $st.text $Typ.Button ([System.Drawing.Color]::White) $r }
        'tint'     { Fill-Round $g $(if ($st.hover) { Hex '#27426E' } else { $Pal.BlueTint }) 0 0 $bw $bh 9
                     $iw = $g.MeasureString($Glyph.Play, $Typ.IconSmall).Width; $tw = $g.MeasureString($st.text, $Typ.Button).Width
                     $x0 = [single](($r.Width - $iw - $tw - 2) / 2)
                     $b = New-Object System.Drawing.SolidBrush($Pal.BlueTintText)
                     $g.DrawString($Glyph.Play, $Typ.IconSmall, $b, $x0, [single](($r.Height - 13) / 2)); $g.DrawString($st.text, $Typ.Button, $b, ($x0 + $iw), [single](($r.Height - 18) / 2)); $b.Dispose() }
        'disabled' { Fill-Round $g (Hex '#26262A') 0 0 $bw $bh 9; Draw-Centered $g $st.text $Typ.Button $Pal.Faint $r }
        'orange'   { $pad = 8   # soft glow ring, then the round button, all inside this control
                     foreach ($i in 0..($pad - 1)) { $gb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(9, 255, 122, 26)); $g.FillEllipse($gb, $i, ($i + 3), ($bw - 2 * $i), ($bh - 2 * $i)); $gb.Dispose() }
                     $b = New-Object System.Drawing.SolidBrush($(if ($st.hover) { $Pal.OrangeHover } else { $Pal.Orange })); $g.FillEllipse($b, $pad, $pad, ($bw - 2 * $pad), ($bh - 2 * $pad)); $b.Dispose()
                     Draw-Centered $g $st.text $Typ.IconBig ([System.Drawing.Color]::White) $r }
        'icon'     { if ($st.hover) { Fill-Round $g (Hex '#34343A') 0 0 $bw $bh 8 }
                     $ic = if ($st.hover) { $Pal.Text } elseif ($st.bright) { $Pal.Muted } else { $Pal.Ghost }
                     Draw-Centered $g $st.text $Typ.Icon $ic $r }
        default    { Fill-Round $g $(if ($st.hover) { Hex '#323237' } else { $Pal.Group }) 0 0 $bw $bh 9; Stroke-Round $g $Pal.Border 1 0.5 0.5 ($bw - 0.5) ($bh - 0.5) 9
                     Draw-Centered $g $st.text $Typ.Button $Pal.Text $r }
    }
}
function New-Btn($text, $x, $y, $bw, $bh, $kind = 'ghost', $onClick = $null, $tip = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($bw, $bh)
    $l.BackColor = [System.Drawing.Color]::Transparent; $l.Text = ''
    if ($kind -ne 'disabled') { $l.Cursor = [System.Windows.Forms.Cursors]::Hand }
    $l.Tag = @{ text = $text; kind = $kind; hover = $false; data = $null }
    $l.Add_Paint($BtnPaint)
    $l.Add_MouseEnter({ $this.Tag.hover = $true; $this.Invalidate() })
    $l.Add_MouseLeave({ $this.Tag.hover = $false; $this.Invalidate() })
    if ($onClick -and $kind -ne 'disabled') { $l.Add_Click($onClick) }
    if ($tip) { $Tips.SetToolTip($l, $tip) }
    return $l
}
function Set-DarkTitle($form) { try { $v = 1; [void][SeatPicker.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { } }
function New-Dialog($text, $bw, $bh) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $text; $f.ClientSize = New-Object System.Drawing.Size($bw, $bh); $f.BackColor = $Pal.Bg; $f.ForeColor = $Pal.Text
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
    $f.KeyPreview = $true; $f.Font = $Typ.Body
    if (Test-Path $OwlIco) { $f.Icon = New-Object System.Drawing.Icon($OwlIco) }
    $f.Add_HandleCreated({ Set-DarkTitle $this })
    return $f
}
function Close-With($ctl, $result) { $script:dlgResult = $result; $ctl.FindForm().Close() }
$Tips = New-Object System.Windows.Forms.ToolTip

# Themed message. Returns 'OK', 'Cancel', 'Yes' or 'No'.
function Show($text, $buttons = 'OK', $icon = 'Information', $okLabel = $null) {
    # returns 'OK' / 'Cancel' / 'Yes' / 'No'; $okLabel only changes the first button's caption
    $f = New-Dialog $Title 460 10
    $tone = switch ($icon) { 'Warning' { $Pal.Amber } 'Error' { $Pal.Red } 'Question' { $Pal.Blue } default { $Pal.Green } }
    $mark = New-Object System.Windows.Forms.Label -Property @{ Location = '22,22'; Size = New-Object System.Drawing.Size(4, 22); BackColor = $tone }
    $lbl = New-Text $text 38 20 $Typ.Body $Pal.Text
    $lbl.MaximumSize = New-Object System.Drawing.Size(398, 0)
    $f.Controls.AddRange(@($mark, $lbl)); $f.PerformLayout()
    $mark.Height = [Math]::Max(22, $lbl.Height)
    $y = [Math]::Max(60, $lbl.Bottom + 24)
    $labels = switch ($buttons) { 'OKCancel' { @('OK', 'Cancel') } 'YesNo' { @('Yes', 'No') } default { @('OK') } }
    $script:dlgResult = $labels[-1]
    $x = 460 - 22
    for ($i = $labels.Count - 1; $i -ge 0; $i--) {
        $x -= 100
        $kind = if ($i -eq 0) { 'primary' } else { 'ghost' }
        $caption = if ($i -eq 0 -and $okLabel) { $okLabel } else { $labels[$i] }
        $bw2 = [Math]::Max(92, [System.Windows.Forms.TextRenderer]::MeasureText($caption, $Typ.Button).Width + 34)
        if ($bw2 -gt 92) { $x -= ($bw2 - 92) }
        $btn = New-Btn $caption $x $y $bw2 34 $kind { Close-With $this $this.Tag.result }
        $btn.Tag.result = $labels[$i]
        $f.Controls.Add($btn)
    }
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { Close-With $this.Controls[0] $labels[0] } elseif ($_.KeyCode -eq 'Escape') { Close-With $this.Controls[0] $labels[-1] } })
    $f.ClientSize = New-Object System.Drawing.Size(460, ($y + 54))
    $f.Add_Shown({ $this.Activate() })
    if ($PreviewDialog -eq 'confirm') { Save-Preview $f $PreviewPng; exit 0 }
    [void]$f.ShowDialog()
    return $script:dlgResult
}

# ---------------- config (seat names + typed-in resets) ----------------
function Load-Config {
    $cfg = @{}
    if (Test-Path $Config) {
        try {
            $raw = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                $resets = @()
                foreach ($r in @($p.Value.resets)) { if ($r) { $resets += @{ type = [string]$r.type; expires = [string]$r.expires } } }
                $ord = if ($null -ne $p.Value.order) { [int]$p.Value.order } else { 999 }
                $cfg[$p.Name] = @{ name = [string]$p.Value.name; resets = $resets; order = $ord }
            }
        } catch { Write-Log "Could not read seats.json: $_" }
    }
    return $cfg
}
function Save-Config($cfg) {
    $obj = [ordered]@{}
    foreach ($k in $cfg.Keys) { $obj[$k] = [ordered]@{ name = $cfg[$k].name; order = [int]$cfg[$k].order; resets = @($cfg[$k].resets | ForEach-Object { [ordered]@{ type = $_.type; expires = $_.expires } }) } }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $Config -Encoding UTF8
}
function Get-Entry($cfg, $acc) {
    if (-not $cfg.ContainsKey($acc)) { $cfg[$acc] = @{ name = ''; resets = @(); order = 999 } }
    return $cfg[$acc]
}

# ---------------- seat data ----------------
function Get-Seats {
    $json = & $Python -I $Tool seats 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not read Codex seats:`n$json" }
    $arr = $json | ConvertFrom-Json      # PS 5.1 returns the whole array as one object
    return ($arr | ForEach-Object { $_ })  # so unroll it into separate seats
}
function Seat-Name($seat, $cfg) {
    $e = Get-Entry $cfg $seat.account
    if ($e.name) { return $e.name }
    return 'Seat ' + $seat.account.Substring(0, 8)
}
function Short-Span([TimeSpan]$t) {
    if ($t.TotalMinutes -lt 1) { return '0m' }
    if ($t.TotalDays -ge 1) { return '{0}d{1}h' -f [int][Math]::Floor($t.TotalDays), $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0}h{1}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    return '{0}m' -f $t.Minutes
}
function Ago([DateTime]$when) {
    $t = (Get-Date) - $when
    if ($t.TotalMinutes -lt 2) { return 'just now' }
    if ($t.TotalHours -lt 1) { return ('{0} min ago' -f [int]$t.TotalMinutes) }
    if ($t.TotalDays -lt 1) { return ('{0} h ago' -f [int]$t.TotalHours) }
    return ('{0} d ago' -f [int]$t.TotalDays)
}
function Valid-Resets($entry) {
    @($entry.resets | Where-Object { $_.expires -and ([DateTime]$_.expires) -gt (Get-Date) } | Sort-Object { [DateTime]$_.expires })
}
function Seat-View($s, $cfg) {
    # everything a row needs, as plain values
    $e = Get-Entry $cfg $s.account; $u = $s.usage
    $v = @{ name = (Seat-Name $s $cfg); active = [bool]$s.active }
    $plan = if ($u -and $u.plan) { (Get-Culture).TextInfo.ToTitleCase([string]$u.plan) } else { $null }
    $mode = if ($s.active) { 'In use' } elseif (-not $s.slot) { 'Manual once' } else { 'Auto switch' }
    if ($s.slot -and -not $s.active -and $s.slot.access_expires -and [DateTimeOffset]::FromUnixTimeSeconds([long]$s.slot.access_expires).LocalDateTime -lt (Get-Date)) { $mode = 'Renews on next switch' }
    $list = @(Valid-Resets $e)
    $v.resets = $list                          # shown as chips under the row
    $v.sub = (@($plan, $mode) | Where-Object { $_ }) -join "  $Dot  "
    $v.resetSoon = $false
    if ($u) {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$u.resets_at).LocalDateTime
        if ($reset -lt (Get-Date)) { $v.pct = 0; $v.left = 'reset' } else { $v.pct = [double]$u.used_percent; $v.left = Short-Span ($reset - (Get-Date)) }
        $v.seen = Ago (([DateTime]$u.seen).ToLocalTime())
        $v.flag = if ($u.limit_reached) { 'limit reached' } elseif ($u.spend_cap) { 'spend cap' } else { $null }
    } else { $v.pct = $null; $v.seen = 'no usage yet' }
    $v.pctColor = if ($null -eq $v.pct) { $Pal.Faint } elseif ($v.pct -ge 90) { $Pal.Red } elseif ($v.pct -ge 70) { $Pal.Amber } else { $Pal.Green }
    $v.tip = "$($v.name)`n$($v.sub)`n$($s.projects) projects" + $(if ($u) { "`nWeekly Codex usage: $($v.pct)% used" } else { '' })
    return $v
}

# ---------------- dialogs ----------------
function Ask-Text($prompt, $default) {
    $f = New-Dialog 'Rename seat' 420 158
    $l = New-Text $prompt 22 18 $Typ.Body $Pal.Text
    $t = New-Object System.Windows.Forms.TextBox -Property @{ Text = $default; Location = '22,46'; Width = 376; Font = (Font $TextF 11)
        BackColor = $Pal.Card; ForeColor = $Pal.Text; BorderStyle = 'FixedSingle' }
    $script:dlgResult = 'Cancel'
    $ok = New-Btn 'Save' 214 102 88 34 'primary' { Close-With $this 'OK' }
    $cn = New-Btn 'Cancel' 310 102 88 34 'ghost' { Close-With $this 'Cancel' }
    $f.Controls.AddRange(@($l, $t, $ok, $cn))
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Close-With $this.Controls[0] 'OK' } elseif ($_.KeyCode -eq 'Escape') { Close-With $this.Controls[0] 'Cancel' } })
    [void]$f.ShowDialog()
    if ($script:dlgResult -eq 'OK') { return $t.Text.Trim() }
    return $null
}

function Edit-Resets($entry, $seatName) {
    $f = New-Dialog "Usage resets $Dash $seatName" 520 356
    $h1 = New-Text 'Usage resets' 22 16 (Font $HeadF 13) $Pal.Text
    $h2 = New-Text ("Copy them from Codex: Settings > Usage & billing > Usage limit resets.`nUse the expiry time exactly as Codex shows it (Pacific time, same as this PC).") 22 44 $Typ.Small $Pal.Muted 476 36
    $lb = New-Object System.Windows.Forms.ListBox -Property @{ Location = '22,88'; Size = New-Object System.Drawing.Size(476, 112); Font = $Typ.Body
        BackColor = $Pal.Card; ForeColor = $Pal.Text; BorderStyle = 'FixedSingle'; IntegralHeight = $false }
    $work = New-Object System.Collections.ArrayList
    foreach ($r in $entry.resets) { [void]$work.Add(@{ type = $r.type; expires = $r.expires }) }
    $refresh = { $lb.Items.Clear(); foreach ($r in $work) { [void]$lb.Items.Add(("  {0}   {1}   expires {2:ddd d MMM yyyy, HH:mm}" -f $r.type, $Dot, [DateTime]$r.expires)) } }
    & $refresh
    $typeBox = New-Object System.Windows.Forms.ComboBox -Property @{ Location = '22,214'; Width = 128; DropDownStyle = 'DropDownList'; Font = $Typ.Body
        FlatStyle = 'Flat'; BackColor = $Pal.Card; ForeColor = $Pal.Text }
    [void]$typeBox.Items.AddRange(@('Full reset', '5-hour reset', 'Weekly reset')); $typeBox.SelectedIndex = 0
    $dt = New-Object System.Windows.Forms.DateTimePicker -Property @{ Location = '158,214'; Width = 168; Format = 'Custom'; CustomFormat = 'yyyy-MM-dd   HH:mm'; Font = $Typ.Body }
    $dt.Value = (Get-Date).Date.AddDays(7).AddHours(12)
    $add = New-Btn 'Add' 336 211 76 32 'ghost' { [void]$work.Add(@{ type = $typeBox.SelectedItem; expires = $dt.Value.ToString('s') }); & $refresh }
    $rem = New-Btn 'Remove' 420 211 78 32 'ghost' { if ($lb.SelectedIndex -ge 0) { $work.RemoveAt($lb.SelectedIndex); & $refresh } }
    $note = New-Text 'Remove a reset after you use it. Expired resets disappear on their own.' 22 258 $Typ.Small $Pal.Faint 476 20
    $script:dlgResult = 'Cancel'
    $ok = New-Btn 'Save' 314 300 88 36 'primary' { Close-With $this 'OK' }
    $cn = New-Btn 'Cancel' 410 300 88 36 'ghost' { Close-With $this 'Cancel' }
    $f.Controls.AddRange(@($h1, $h2, $lb, $typeBox, $dt, $add, $rem, $note, $ok, $cn))
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { Close-With $this.Controls[0] 'Cancel' } })
    if ($PreviewDialog -eq 'resets') { Save-Preview $f $PreviewPng; exit 0 }   # draw inside this function, same scope as real use
    [void]$f.ShowDialog()
    if ($script:dlgResult -eq 'OK') { $entry.resets = @($work | ForEach-Object { $_ }); return $true }
    return $false
}

# ---------------- Codex control (ends Codex only when you choose "Quit Codex for me") ----------------
function Get-CodexProcs { Get-Process | Where-Object { $_.Name -eq 'codex' -or ($_.Path -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*') } }

function Ask-QuitCodex {
    # returns 'force', 'manual' or 'cancel'
    $f = New-Dialog 'Codex is still running' 500 226
    $bh = New-Text 'Codex is still running in the tray' 22 16 (Font $HeadF 13) $Pal.Text
    $s = New-Text 'It has to be fully closed before seats can be switched.' 22 46 $Typ.Small $Pal.Muted
    $a1 = New-Text 'Quit Codex for me' 22 78 (Font $TextSB 10) $Pal.Text
    $a1b = New-Text 'Ends Codex now. A Codex task that is still running stops.' 22 98 $Typ.Small $Pal.Muted
    $a2 = New-Text 'I quit it myself' 22 124 (Font $TextSB 10) $Pal.Text
    $a2b = New-Text 'Right-click the Codex icon in the tray (taskbar ^) > Quit, then choose this.' 22 144 $Typ.Small $Pal.Muted
    $script:dlgResult = 'cancel'
    $bF = New-Btn 'Quit Codex for me' 22 176 156 36 'primary' { Close-With $this 'force' }
    $bM = New-Btn 'I quit it myself' 186 176 140 36 'ghost' { Close-With $this 'manual' }
    $bC = New-Btn 'Cancel' 390 176 88 36 'ghost' { Close-With $this 'cancel' }
    $f.Controls.AddRange(@($bh, $s, $a1, $a1b, $a2, $a2b, $bF, $bM, $bC))
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { Close-With $this.Controls[0] 'cancel' } })
    if ($PreviewDialog -eq 'quit') { Save-Preview $f $PreviewPng; exit 0 }
    $f.Add_Shown({ $this.Activate() })
    [void]$f.ShowDialog()
    return $script:dlgResult
}

function Close-Codex {
    if (-not (Get-CodexProcs)) { return $true }
    Get-CodexProcs | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [void]$_.CloseMainWindow() }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-CodexProcs) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    while (Get-CodexProcs) {
        $choice = Ask-QuitCodex
        if ($choice -eq 'cancel') { return $false }
        if ($choice -eq 'force') {
            Write-Log ("Ending Codex processes: " + ((Get-CodexProcs | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', '))
            Get-CodexProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-CodexProcs) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            Start-Sleep -Seconds 1   # let Windows release file handles before the sync reads Codex's files
        } else {
            Start-Sleep -Seconds 2
        }
    }
    return $true
}
function Open-Codex {
    if ($NoLaunch) { return }
    foreach ($try in 1..2) {
        Start-Process explorer.exe $AppId
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) { if (Get-CodexProcs) { Write-Log "Codex opened (try $try)"; return }; Start-Sleep -Milliseconds 500 }
    }
    Write-Log 'Codex did not start'
    Show 'Codex did not open. Open it from the Start menu.' 'OK' 'Warning' | Out-Null
}
function Run-Sync {
    $out = & $Python -I $Tool sync --from active 2>&1 | Out-String; $code = $LASTEXITCODE
    Write-Log "sync exit=$code`n$out"
    if ($code -eq 2 -and $out -match 'WARNING') {
        if ((Show "The sync stopped to check with you:`n`n$out`nApply it anyway? A backup is saved first." 'YesNo' 'Warning') -eq 'Yes') {
            $out = & $Python -I $Tool sync --from active --yes 2>&1 | Out-String; $code = $LASTEXITCODE
            Write-Log "sync --yes exit=$code`n$out"
        } else { return 'declined' }
    }
    if ($code -ne 0) { Show "The sync did not run:`n`n$out`nNothing was changed." 'OK' 'Error' | Out-Null; return 'failed' }
    return 'ok'
}
function Run-Switch($account) {
    # returns 'switched', 'already', 'noslot' or 'failed'
    $out = & $Python -I $Tool switch --to $account 2>&1 | Out-String; $code = $LASTEXITCODE
    Write-Log "switch exit=$code $out"
    if ($code -eq 4) { return 'noslot' }
    if ($code -ne 0) { Show "The automatic switch did not run:`n`n$out`nYour login was not changed." 'OK' 'Error' | Out-Null; return 'failed' }
    if ($out -match 'ALREADY') { return 'already' }
    return 'switched'
}

# ---------------- previews (test aid) ----------------
function Save-Preview($form, $path) {
    $form.Opacity = 0; $form.ShowInTaskbar = $false; $form.TopMost = $false; $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bmp.Save($path); $form.Close()
}
if ($PreviewPng -and $PreviewDialog) {
    if ($PreviewDialog -eq 'confirm') { Show "Switch to Northwind Labs?`n`nCodex will be closed and reopened. A Codex task that is still running stops." 'OKCancel' 'Question' 'Switch' }
    $dlg = if ($PreviewDialog -eq 'quit') { Ask-QuitCodex } else { Edit-Resets @{ resets = @(@{ type = 'Full reset'; expires = (Get-Date).AddDays(22).ToString('s') }) } 'Acme Studio' }
    Save-Preview $dlg $PreviewPng; exit 0
}

# ---------------- main window ----------------
$cfg = Load-Config
if ($Demo) {
    # made-up seats for screenshots: nothing is read from or written to Codex or seats.json
    $Config = Join-Path $env:TEMP 'seat-picker-demo.json'
    function Get-Seats {
        $now = [DateTimeOffset]::Now
        $mk = { param($acc, $active, $used, $resetDays, $seenH, $slot)
            [pscustomobject]@{ account = $acc; active = $active; projects = 14
                usage = $(if ($null -ne $used) { [pscustomobject]@{ used_percent = $used; resets_at = $now.AddDays($resetDays).ToUnixTimeSeconds()
                    seen = $now.AddHours(-$seenH).UtcDateTime.ToString('o'); plan = 'team'; credits = $null; limit_reached = $null; spend_cap = $null } } else { $null })
                slot = $(if ($slot) { [pscustomobject]@{ access_expires = $now.AddDays(6).ToUnixTimeSeconds() } } else { $null }) } }
        & $mk 'aaaaaaaa-0000-0000-0000-000000000001' $true 34 4.3 0.1 $true
        & $mk 'bbbbbbbb-0000-0000-0000-000000000002' $false 92 0.9 20 $true
        & $mk 'cccccccc-0000-0000-0000-000000000003' $false $null 0 0 $false
    }
    $cfg = @{
        'aaaaaaaa-0000-0000-0000-000000000001' = @{ name = 'Acme Studio'; order = 0; resets = @(@{ type = 'Full reset'; expires = (Get-Date).AddDays(12).ToString('s') }) }
        'bbbbbbbb-0000-0000-0000-000000000002' = @{ name = 'Northwind Labs'; order = 1; resets = @(@{ type = 'Full reset'; expires = (Get-Date).AddDays(2).ToString('s') }; @{ type = '5-hour reset'; expires = (Get-Date).AddDays(20).ToString('s') }) }
        'cccccccc-0000-0000-0000-000000000003' = @{ name = 'Personal'; order = 2; resets = @() }
    }
}
$script:seatList = @(Get-Seats)
$W = 870

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title; $form.BackColor = $Pal.Bg; $form.ForeColor = $Pal.Text; $form.Font = $Typ.Body
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false; $form.StartPosition = 'CenterScreen'; $form.TopMost = $true; $form.KeyPreview = $true
if (Test-Path $OwlIco) { $form.Icon = New-Object System.Drawing.Icon($OwlIco) }
$form.Add_HandleCreated({ Set-DarkTitle $this })

# ---- header: app icon + blue title + project chip ....... tool group + orange sync button
$appIcon = New-Object System.Windows.Forms.PictureBox -Property @{ Location = '28,30'; Size = New-Object System.Drawing.Size(30, 30); SizeMode = 'Zoom'; BackColor = [System.Drawing.Color]::Transparent }
$appIcon.Image = Load-Image $OwlPng
$titleLbl = New-Text $Title 64 28 $Typ.Title $Pal.Blue
$chip = New-Object System.Windows.Forms.Label -Property @{ Location = '0,26'; Size = New-Object System.Drawing.Size(260, 38); BackColor = [System.Drawing.Color]::Transparent }
$chip.Tag = @{ text = ''; color = $Pal.Muted }
$chip.Add_Paint({
    $g = $_.Graphics; Smooth $g; $st = $this.Tag
    $tw = Draw-Text $g $Glyph.Folder $Typ.Icon $Pal.Muted 4 10
    $w2 = Draw-Text $g $st.text $Typ.Chip $st.color (8 + $tw) 8
})
$Tips.SetToolTip($chip, 'Projects are copied to every seat when you switch')

$group = New-Object System.Windows.Forms.Panel -Property @{ Size = New-Object System.Drawing.Size(150, 46); BackColor = $Pal.Bg }
$group.Location = New-Object System.Drawing.Point(($W - 28 - 46 - 14 - 150), 22)
$group.Add_Paint({ Smooth $_.Graphics; Fill-Round $_.Graphics $Pal.Group 0 0 ($this.Width - 1) ($this.Height - 1) 14 })
$bRefresh = New-Btn $Glyph.Refresh 7 5 44 36 'icon' { $script:seatList = @(Get-Seats); Fill-Cards } 'Refresh seats and usage (F5)'
$bFolder = New-Btn $Glyph.Folder 53 5 44 36 'icon' { Start-Process explorer.exe $Dir } 'Open the Seat Picker folder (backups, saved logins)'
$bLog = New-Btn $Glyph.History 99 5 44 36 'icon' { Start-Process notepad.exe $Log } 'Show the switch history'
foreach ($b in @($bRefresh, $bFolder, $bLog)) { $b.Tag.bright = $true; $group.Controls.Add($b) }
$bSync = New-Btn $Glyph.Sync ($W - 28 - 54) 14 62 62 'orange' { $cur = $script:seatList | Where-Object active | Select-Object -First 1; if ($cur) { Invoke-Go $cur } } 'Sync projects to all seats now'

$cardsHost = New-Object System.Windows.Forms.Panel -Property @{ Location = '28,96'; BackColor = $Pal.Bg }
$note = New-Text "Switching changes only the workspace ID and access token. A backup is saved before every switch." 30 0 $Typ.Small $Pal.Faint ($W - 60) 20

# ---- seat rows
$CardH = 98; $CardGap = 12
$CardPaint = {
    $g = $_.Graphics; Smooth $g; $st = $this.Tag; $v = $st.view; $r = $this.ClientRectangle
    $bg = if ($v.active) { $Pal.ActiveBg } elseif ($st.hover) { $Pal.CardHover } else { $Pal.Card }
    $bd = if ($v.active) { $Pal.ActiveBorder } elseif ($st.hover) { $Pal.BorderHover } else { $Pal.Border }
    if ($st.dragging) { $bd = $Pal.Blue }
    Fill-Round $g $bg 1 1 ($r.Width - 3) ($r.Height - 3) 14
    Stroke-Round $g $bd 1.3 1 1 ($r.Width - 3) ($r.Height - 3) 14
    # drag handle: 2 x 3 dots
    $db = New-Object System.Drawing.SolidBrush($(if ($st.handleHover) { $Pal.Muted } else { $Pal.Faint }))
    foreach ($row in 0..2) { foreach ($col in 0..1) { $g.FillEllipse($db, (22 + $col * 7), (40 + $row * 8), 4, 4) } }
    $db.Dispose()
    # seat tile
    Fill-Round $g $Pal.Tile 48 29 40 40 11
    Stroke-Round $g $Pal.Border 1 48 29 40 40 11
    Draw-Centered $g $v.initial $Typ.Initial $v.tint (New-Object System.Drawing.RectangleF(48, 29, 40, 40))
    # line 1: name (cut with ... if too long), line 2: plan + mode, line 3: usage
    Draw-Clipped $g $v.name $Typ.Name $Pal.Text 102 12 $st.textW
    Draw-Clipped $g $v.sub $Typ.Sub $Pal.Muted 103 41 $st.textW
    $x = [single]103; $y = [single]67
    if ($null -ne $v.pct) {
        $x += Draw-Text $g '7d:' $Typ.Line3 $Pal.Muted $x $y
        $x += Draw-Text $g (' {0:0}%' -f $v.pct) $Typ.Line3B $v.pctColor $x $y
        $x += 8
        $x += Draw-Text $g $Glyph.Clock $Typ.IconSmall $Pal.Muted $x ($y + 3)
        $x += Draw-Text $g $v.left $Typ.Line3 $Pal.Muted $x $y
        if ($v.flag) { $x += Draw-Text $g "  $Dot  $($v.flag)" $Typ.Line3 $Pal.Red $x $y }
        [void](Draw-Text $g "  $Dot  seen $($v.seen)" $Typ.Line3 $Pal.Faint $x $y)
    } else {
        $x += Draw-Text $g '7d:' $Typ.Line3 $Pal.Muted $x $y
        [void](Draw-Text $g " $Dash  $Dot  $($v.seen)" $Typ.Line3 $Pal.Faint $x $y)
    }
    # resets column divider + placeholder
    $dx = [single]$st.dividerX
    $dp = New-Object System.Drawing.Pen($Pal.Border, 1); $g.DrawLine($dp, $dx, 18, $dx, ($r.Height - 18)); $dp.Dispose()
    if (-not $v.resets.Count) { [void](Draw-Text $g 'No resets' $Typ.ChipText $Pal.Ghost ($dx + 16) 37) }
    if ($v.active) { [void](Draw-Text $g 'In use' $Typ.Button $Pal.Ghost ($st.switchX + 14) 37) }
}
# ---- compact reset lines in the right column: "(reset) Full . 30 Nov 12:24   21d  | (check)"
$ResetW = 226; $ResetH = 30; $CheckW = 32
$ChipPaint = {
    $g = $_.Graphics; Smooth $g; $st = $this.Tag; $r = $this.ClientRectangle
    if ($st.more) {   # "+2 more" link line
        $c2 = if ($st.hover) { $Pal.Text } else { $Pal.Muted }
        [void](Draw-Text $g $st.label $Typ.ChipText $c2 10 5); return
    }
    $soon = $st.daysLeft -lt 3
    Fill-Round $g (Hex '#2B2720') 0.5 0.5 ($r.Width - 1.5) ($r.Height - 1.5) 9
    Stroke-Round $g $(if ($soon) { $Pal.Amber } else { Hex '#463D2E' }) 1 0.5 0.5 ($r.Width - 1.5) ($r.Height - 1.5) 9
    $ux = [single]($r.Width - $CheckW)
    if ($st.hoverUsed) {
        $clip = New-Object System.Drawing.Region((RoundPath 0.5 0.5 ($r.Width - 1.5) ($r.Height - 1.5) 9))
        $clip.Intersect((New-Object System.Drawing.RectangleF($ux, 0, $CheckW, $r.Height)))
        $hb = New-Object System.Drawing.SolidBrush((Hex '#1F3A2C')); $g.FillRegion($hb, $clip); $hb.Dispose(); $clip.Dispose()
    }
    $x = [single]9
    $x += Draw-Text $g $Glyph.Reset $Typ.IconSmall $Pal.Amber $x 8
    $x += 4
    $x += Draw-Text $g $st.label $Typ.ChipText $Pal.Text $x 5
    [void](Draw-Text $g $st.left $Typ.ChipText $(if ($soon) { $Pal.Amber } else { $Pal.Muted }) ($ux - 6) 5 'Far')
    $pen = New-Object System.Drawing.Pen((Hex '#463D2E'), 1); $g.DrawLine($pen, $ux, 6, $ux, ($r.Height - 6)); $pen.Dispose()
    Draw-Centered $g $Glyph.Check $Typ.IconSmall $(if ($st.hoverUsed) { $Pal.Green } else { $Pal.Muted }) (New-Object System.Drawing.RectangleF($ux, 0, $CheckW, $r.Height))
}
function New-ResetChip($seat, $reset, $x, $y) {
    $exp = [DateTime]$reset.expires
    $span = $exp - (Get-Date)
    $leftTxt = if ($span.TotalDays -ge 1) { '{0}d' -f [int][Math]::Floor($span.TotalDays) } else { '{0}h' -f [int][Math]::Ceiling($span.TotalHours) }
    $short = $reset.type -replace ' reset$', ''
    $c = New-Object System.Windows.Forms.Label
    $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($ResetW, $ResetH)
    $c.BackColor = [System.Drawing.Color]::Transparent; $c.Text = ''
    $c.Tag = @{ reset = $reset; label = ('{0} {1} {2:d MMM HH:mm}' -f $short, $Dot, $exp); left = $leftTxt; daysLeft = $span.TotalDays; hoverUsed = $false; owner = $seat; more = $false }
    $c.Add_Paint($ChipPaint)
    $c.Add_MouseMove({ $u = $_.X -ge ($this.Width - $CheckW); if ($u -ne $this.Tag.hoverUsed) { $this.Tag.hoverUsed = $u; $this.Invalidate() }
        $this.Cursor = if ($u) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default } })
    $c.Add_MouseLeave({ $this.Tag.hoverUsed = $false; $this.Invalidate() })
    $c.Add_MouseClick({ if ($_.X -ge ($this.Width - $CheckW)) { Use-Reset $this.Tag.owner $this.Tag.reset } })
    $Tips.SetToolTip($c, ("{0}, expires {1:ddd d MMM yyyy, HH:mm}`nClick the check mark after you have used it in Codex; it is then removed." -f $reset.type, $exp))
    return $c
}
function New-MoreLink($seat, $count, $x, $y) {
    $c = New-Object System.Windows.Forms.Label
    $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($ResetW, $ResetH)
    $c.BackColor = [System.Drawing.Color]::Transparent; $c.Text = ''; $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    $c.Tag = @{ more = $true; hover = $false; owner = $seat; label = "+$count more resets $([char]0x203A)" }
    $c.Add_Paint($ChipPaint)
    $c.Add_MouseEnter({ $this.Tag.hover = $true; $this.Invalidate() }); $c.Add_MouseLeave({ $this.Tag.hover = $false; $this.Invalidate() })
    $c.Add_Click({ $s2 = $this.Tag.owner; if (Edit-Resets (Get-Entry $cfg $s2.account) (Seat-Name $s2 $cfg)) { Save-Config $cfg; Fill-Cards } })
    return $c
}
function Use-Reset($seat, $reset) {
    $name = Seat-Name $seat $cfg
    $msg = "Mark this reset as used?`n`n{0}, expires {1:ddd d MMM, HH:mm}`nSeat: {2}`n`nIt will be removed from the list." -f $reset.type, ([DateTime]$reset.expires), $name
    if ((Show $msg 'OKCancel' 'Question') -ne 'OK') { return }
    $e = Get-Entry $cfg $seat.account
    $done = $false
    $e.resets = @($e.resets | Where-Object { if (-not $done -and $_.type -eq $reset.type -and $_.expires -eq $reset.expires) { $done = $true; $false } else { $true } })
    Save-Config $cfg
    Write-Log "Reset marked used: $($reset.type) exp $($reset.expires) on '$name'"
    Fill-Cards
}

function New-Card($s) {
    $v = Seat-View $s $cfg
    $tints = @($Pal.Green, $Pal.Blue, (Hex '#BF8CFF'), $Pal.Orange, (Hex '#5AC8FA'))
    $v.tint = $tints[[Math]::Abs($s.account.GetHashCode()) % $tints.Count]
    $v.initial = ($v.name.Trim() + '?').Substring(0, 1).ToUpper()
    $v.left = if ($v.left) { $v.left } else { '' }
    $card = New-Object System.Windows.Forms.Panel -Property @{ Size = New-Object System.Drawing.Size(($W - 56), $CardH); BackColor = $Pal.Bg }
    $card.Tag = @{ seat = $s; view = $v; hover = $false; dragging = $false; handleHover = $false }
    # resets: compact lines in the right column (max 2 lines; a 3rd+ becomes "+N more")
    $rx = $card.Width - $ResetW - 18
    $n = $v.resets.Count
    if ($n -eq 1) { $card.Controls.Add((New-ResetChip $s $v.resets[0] $rx 34)) }
    elseif ($n -eq 2) { $card.Controls.Add((New-ResetChip $s $v.resets[0] $rx 16)); $card.Controls.Add((New-ResetChip $s $v.resets[1] $rx 52)) }
    elseif ($n -gt 2) { $card.Controls.Add((New-ResetChip $s $v.resets[0] $rx 16)); $card.Controls.Add((New-MoreLink $s ($n - 1) $rx 52)) }
    $calX = $rx - 26 - 38; $editX = $calX - 40; $x0 = $editX - 8 - 84
    $card.Tag.switchX = $x0; $card.Tag.dividerX = $rx - 13; $card.Tag.textW = $x0 - 14 - 102
    if (-not $s.active) {
        $sw = New-Btn 'Switch' $x0 30 84 38 'tint' { Invoke-Go $this.Parent.Tag.seat } "Switch Codex to $($v.name)"
        $card.Controls.Add($sw)
    }
    $ed = New-Btn $Glyph.Edit $editX 30 38 38 'icon' {
        $s2 = $this.Parent.Tag.seat
        $n = Ask-Text 'Name for this seat (for example Personal or Company A):' (Get-Entry $cfg $s2.account).name
        if ($null -ne $n) { (Get-Entry $cfg $s2.account).name = $n; Save-Config $cfg; Fill-Cards } } 'Rename seat'
    $rs = New-Btn $Glyph.Calendar $calX 30 38 38 'icon' {
        $s2 = $this.Parent.Tag.seat
        if (Edit-Resets (Get-Entry $cfg $s2.account) (Seat-Name $s2 $cfg)) { Save-Config $cfg; Fill-Cards } } 'Usage resets'
    $card.Controls.AddRange(@($ed, $rs))
    $Tips.SetToolTip($card, $v.tip)
    $card.Add_Paint($CardPaint)
    $card.Add_MouseEnter({ $this.Tag.hover = $true; foreach ($c2 in $this.Controls) { $c2.Tag.bright = $true; $c2.Invalidate() }; $this.Invalidate() })
    $card.Add_MouseLeave({ if (-not $this.ClientRectangle.Contains($this.PointToClient([System.Windows.Forms.Cursor]::Position))) {
        $this.Tag.hover = $false; $this.Tag.handleHover = $false; foreach ($c2 in $this.Controls) { $c2.Tag.bright = $false; $c2.Invalidate() }; $this.Invalidate() } })
    $card.Add_DoubleClick({ if (-not $this.Tag.seat.active) { Invoke-Go $this.Tag.seat } })
    # drag to reorder, from the dot handle
    $card.Add_MouseMove({
        $onHandle = $_.X -lt 40
        if ($onHandle -ne $this.Tag.handleHover) { $this.Tag.handleHover = $onHandle; $this.Invalidate() }
        $this.Cursor = if ($onHandle -or $this.Tag.dragging) { [System.Windows.Forms.Cursors]::SizeNS } else { [System.Windows.Forms.Cursors]::Default }
        if ($this.Tag.dragging) {
            $y = $cardsHost.PointToClient([System.Windows.Forms.Cursor]::Position).Y - $this.Tag.grabY
            $this.Top = [Math]::Max(0, [Math]::Min($cardsHost.Height - $this.Height, $y)); $this.BringToFront()
        }
    })
    $card.Add_MouseDown({ if ($_.X -lt 40 -and $_.Button -eq 'Left') { $this.Tag.dragging = $true; $this.Tag.grabY = $_.Y; $this.Invalidate() } })
    $card.Add_MouseUp({
        if (-not $this.Tag.dragging) { return }
        $this.Tag.dragging = $false
        $ordered = @($cardsHost.Controls | Sort-Object Top)
        for ($i = 0; $i -lt $ordered.Count; $i++) { (Get-Entry $cfg $ordered[$i].Tag.seat.account).order = $i }
        Save-Config $cfg
        Layout-Cards; $this.Invalidate()
    })
    return $card
}
function Layout-Cards {
    $ordered = @($cardsHost.Controls | Sort-Object { (Get-Entry $cfg $_.Tag.seat.account).order }, { $_.Top })
    $top = 0
    foreach ($cd in $ordered) { $cd.Location = New-Object System.Drawing.Point(0, $top); $top += $cd.Height + $CardGap }
}

function Fill-Cards {
    $cardsHost.Controls.Clear()
    $list = @($script:seatList | Sort-Object { (Get-Entry $cfg $_.account).order })
    foreach ($s in $list) { $cardsHost.Controls.Add((New-Card $s)) }
    $total = 0; foreach ($cd in $cardsHost.Controls) { $total += $cd.Height + $CardGap }
    $cardsHost.Size = New-Object System.Drawing.Size(($W - 56), [Math]::Max(10, $total - $CardGap))
    Layout-Cards
    $projCounts = @($script:seatList | ForEach-Object { $_.projects } | Select-Object -Unique)
    if ($projCounts.Count -eq 1) { $chip.Tag.text = "$($projCounts[0]) projects in sync"; $chip.Tag.color = $Pal.Muted }
    else { $chip.Tag.text = 'Projects differ between seats'; $chip.Tag.color = $Pal.Amber }
    $chip.Invalidate()
    $note.Top = $cardsHost.Bottom + 18
    $form.ClientSize = New-Object System.Drawing.Size($W, ($note.Bottom + 22))
}

function Stop-Codex {
    # ends Codex completely (window and tray); only called after the user confirmed
    # if Codex started only seconds ago, let it finish starting first: killing it mid-start
    # can leave its state file without a current seat
    $started = Get-CodexProcs | ForEach-Object { try { $_.StartTime } catch { $null } } | Where-Object { $_ } | Sort-Object | Select-Object -First 1
    if ($started) { $wait = 12 - ((Get-Date) - $started).TotalSeconds; if ($wait -gt 0) { Write-Log ("Codex just started; waiting {0:N0} s before closing it" -f $wait); Start-Sleep -Milliseconds ([int]($wait * 1000)) } }
    Get-CodexProcs | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [void]$_.CloseMainWindow() }
    Start-Sleep -Milliseconds 800
    if (Get-CodexProcs) {
        Write-Log ("Ending Codex processes: " + ((Get-CodexProcs | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', '))
        Get-CodexProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-CodexProcs) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
    Start-Sleep -Seconds 1   # let Windows release file handles before the sync reads Codex's files
    return -not (Get-CodexProcs)
}

function Invoke-Go($s) {
    $name = Seat-Name $s $cfg
    # one confirmation, and only when Codex is running (closing it stops a running task)
    if (Get-CodexProcs) {
        $first = if ($s.active) { "Sync projects to all seats?" } else { "Switch to ${name}?" }
        $msg = "$first`n`nCodex will be closed and reopened. A Codex task that is still running stops."
        if (-not $s.active -and -not $s.slot) { $msg += "`n`nThis seat has no saved login yet, so after Codex reopens, choose ${name} in Codex's workspace menu once." }
        $okText = if ($s.active) { 'Sync now' } else { 'Switch' }
        if ((Show $msg 'OKCancel' 'Question' $okText) -ne 'OK') { return }
    }
    $form.Hide()
    if (-not (Stop-Codex)) { Show 'Codex could not be closed. Nothing was changed.' 'OK' 'Error' | Out-Null; $form.Show(); return }
    $res = Run-Sync
    $sw = Run-Switch $s.account     # also saves the current seat's login for next time
    Write-Log "Switch to '$name' -> sync $res, switch $sw"
    Open-Codex
    if ($sw -eq 'noslot' -or $sw -eq 'failed') {
        Start-Sleep -Seconds 3
        Show ("One last step: in Codex, open the workspace menu and choose ${name}.`n`nNext time Seat Picker switches there automatically.") 'OK' 'Information' | Out-Null
    }
    $form.Close()
}

$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } elseif ($_.KeyCode -eq 'F5') { $script:seatList = @(Get-Seats); Fill-Cards } })
$form.Controls.AddRange(@($appIcon, $titleLbl, $chip, $group, $bSync, $cardsHost, $note))
$chip.Left = $titleLbl.Left + $titleLbl.PreferredWidth + 22
Fill-Cards
if ($PreviewPng) { Save-Preview $form $PreviewPng; exit 0 }
$form.Add_Shown({ $form.Activate(); $form.TopMost = $false })
[void]$form.ShowDialog()
