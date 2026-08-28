<#
.SYNOPSIS
    Tiny graphical wrapper for hello-kitty.ps1 (no console needed).

.DESCRIPTION
    A small pink WinForms window with buttons that drive the main script:
      * Apply Hello Kitty  (hello-kitty.ps1 apply)
      * Restore my theme   (hello-kitty.ps1 restore)
      * Toggle             (hello-kitty.ps1 toggle)
      * Save .theme        (hello-kitty.ps1 savetheme) - saves the current theme
      * Refresh status     (hello-kitty.ps1 status)

    Launch it by double-clicking hello-kitty.bat, or directly:
        powershell -NoProfile -Sta -ExecutionPolicy Bypass -File hello-kitty-gui.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MainScript   = Join-Path $ScriptDir 'hello-kitty.ps1'
$Busy         = $false

# ----------------------------------------------------------------------------
# Pink palette (kept in the script too; mirrored here for the widgets only)
# ----------------------------------------------------------------------------
$Pink    = [System.Drawing.Color]::FromArgb(255, 46, 109)
$PinkLt  = [System.Drawing.Color]::FromArgb(255, 228, 240)
$PinkBg  = [System.Drawing.Color]::FromArgb(255, 240, 245)
$Gray    = [System.Drawing.Color]::FromArgb(110, 110, 110)

# ----------------------------------------------------------------------------
# Widgets
# ----------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Hello Kitty theme'
$form.ClientSize = New-Object System.Drawing.Size(430, 500)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Hello Kitty'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $Pink
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 16)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'lots of hello kitty magic was needed to make this work :p'
$lblSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSub.ForeColor = $Gray
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(22, 58)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = 'Mode: ...'
$lblMode.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblMode.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$lblMode.AutoSize = $true
$lblMode.Location = New-Object System.Drawing.Point(22, 84)

function New-PinkButton([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($W, 34)
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.BackColor = $Pink
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = 'Hand'
    $b.UseVisualStyleBackColor = $false
    return $b
}

$btnApply   = New-PinkButton 'Apply Hello Kitty' 20 118 124
$btnRestore = New-PinkButton 'Restore mine'      152 118 110
$btnToggle  = New-PinkButton 'Toggle'             270 118 140

$btnSave    = New-PinkButton 'Save current .theme' 20 158 220
$btnRefresh = New-PinkButton 'Refresh status'       252 158 158

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.BackColor = $PinkBg
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(50, 40, 45)
$txtLog.BorderStyle = 'FixedSingle'
$txtLog.Location = New-Object System.Drawing.Point(20, 202)
$txtLog.Size = New-Object System.Drawing.Size(390, 276)

$form.Controls.AddRange(@($lblTitle, $lblSub, $lblMode, $btnApply, $btnRestore, $btnToggle,
                           $btnSave, $btnRefresh, $txtLog))

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Append-Log([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return }
    $txtLog.AppendText($Line + [Environment]::NewLine)
}

function Set-Busy([bool]$Value) {
    $script:Busy = $Value
    foreach ($c in @($btnApply, $btnRestore, $btnToggle, $btnSave, $btnRefresh)) {
        $c.Enabled = -not $Value
    }
}

function Invoke-HKCommand([string]$Command) {
    if ($script:Busy) { return }
    Set-Busy $true
    $lblMode.Text = "Working on: $Command ..."
    $lblMode.ForeColor = $Pink
    Append-Log ''
    Append-Log "> hello-kitty.ps1 $Command"

    $combined = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # -Sta is required by the native theme-API COM calls in hello-kitty.ps1
        $psi.Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$MainScript`" $Command"

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        # IMPORTANT: read the child output with pure .NET tasks ONLY. Attaching
        # scriptblock handlers to OutputDataReceived / ErrorDataReceived makes
        # PowerShell execute them on the background reader thread, which has no
        # runspace context - the process dies with PSInvalidOperation
        # (ScriptBlock.GetContextFromTLS), WER "PowerShell" event, exit code 2.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        # keep the UI pumping messages while the child runs
        while (-not $p.HasExited -or -not $outTask.IsCompleted -or -not $errTask.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60
        }
        $p.WaitForExit()
        try { $combined = $outTask.Result + $errTask.Result } catch { $combined = $_.Exception.Message }
    } catch {
        $combined = "ERR: $($_.Exception.Message)"
    }
    foreach ($line in ($combined -split "`r?`n")) { Append-Log $line }

    $mode = 'unknown'
    $state = Join-Path $env:LOCALAPPDATA 'hello-kitty\state.json'
    if (Test-Path $state) {
        try { $mode = (Get-Content $state -Raw | ConvertFrom-Json).mode } catch { }
    }
    if ($Command -eq 'status') {
        $cur = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($cur) { $lblMode.Text = "Mode: live theme -> $(Split-Path $cur -Leaf)" }
        else { $lblMode.Text = 'Mode: see log below' }
    } else {
        $lblMode.Text = "Mode: $mode"
    }
    $lblMode.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    Set-Busy $false
}

$btnApply.Add_Click({ Invoke-HKCommand 'apply' })
$btnRestore.Add_Click({ Invoke-HKCommand 'restore' })
$btnToggle.Add_Click({ Invoke-HKCommand 'toggle' })
$btnSave.Add_Click({ Invoke-HKCommand 'savetheme' })
$btnRefresh.Add_Click({ Invoke-HKCommand 'status' })

$form.Add_Shown({
    $form.Activate()
    # kick off an initial status read in the background so the window shows instantly
    $form.BeginInvoke([Action]{ Invoke-HKCommand 'status' }) | Out-Null
})

[System.Windows.Forms.Application]::Run($form)
