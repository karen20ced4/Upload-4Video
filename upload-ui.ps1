# upload-ui-improved.ps1 (v3.2) - Modern UI with Progress Bar Real-Time
# - GroupBox sections with color coding
# - Light/Dark theme toggle
# - Professional layout similar to reference image
# - Enhanced visual feedback
# - Upload delay feature to prevent server overload
# - Real-time progress bar with percentage and file count
# - Read stdout/stderr/upload.log as UTF-8
# - RichTextBox uses Consolas by default for box-drawing and switches to Segoe UI Emoji when a line contains emoji

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO

$version = 'v3.2'

# ===== COLOR SCHEMES =====
$script:themes = @{
    Light = @{
        FormBack = [System.Drawing.Color]::FromArgb(210, 210, 205)
        PanelBack = [System.Drawing.Color]::FromArgb(220, 220, 220)
        TextFore = [System.Drawing.Color]::Black
        GroupBoxFore = [System.Drawing.Color]::Black
        LogBack = [System.Drawing.Color]::FromArgb(70, 70, 65)
        LogFore = [System.Drawing.Color]::Black
        
        ConfigHeader = [System.Drawing.Color]::FromArgb(63, 81, 181)    # Blue
        FoldersHeader = [System.Drawing.Color]::FromArgb(76, 175, 80)   # Green
        ControlHeader = [System.Drawing.Color]::FromArgb(255, 152, 0)   # Orange
        ProgressHeader = [System.Drawing.Color]::FromArgb(0, 150, 136)  # Cyan
        
        BtnStart = [System.Drawing.Color]::FromArgb(144, 238, 144)      # LightGreen
        BtnExit = [System.Drawing.Color]::FromArgb(255, 182, 193)       # LightPink
        BtnDry = [System.Drawing.Color]::FromArgb(255, 215, 0)          # Gold
        BtnNormal = [System.Drawing.Color]::FromArgb(200, 200, 200)     # LightGray
    }
    Dark = @{
        FormBack = [System.Drawing.Color]::FromArgb(45, 45, 48)
        PanelBack = [System.Drawing.Color]::FromArgb(30, 30, 30)
        TextFore = [System.Drawing.Color]::FromArgb(220, 220, 220)
        GroupBoxFore = [System.Drawing.Color]::White
        LogBack = [System.Drawing.Color]::FromArgb(15, 15, 15)
        LogFore = [System.Drawing.Color]::LightGray
        
        ConfigHeader = [System.Drawing.Color]::FromArgb(63, 81, 181)
        FoldersHeader = [System.Drawing.Color]::FromArgb(76, 175, 80)
        ControlHeader = [System.Drawing.Color]::FromArgb(255, 152, 0)
        ProgressHeader = [System.Drawing.Color]::FromArgb(0, 150, 136)
        
        BtnStart = [System.Drawing.Color]::FromArgb(100, 200, 100)
        BtnExit = [System.Drawing.Color]::FromArgb(220, 100, 120)
        BtnDry = [System.Drawing.Color]::FromArgb(220, 180, 0)
        BtnNormal = [System.Drawing.Color]::FromArgb(70, 70, 70)
    }
}

$script:currentTheme = 'Light'

# Runner state holder
$script:runner = @{
    Proc         = $null
    StdOutPath   = $null
    StdErrPath   = $null
    TailTimer    = $null
    LastOutLen   = 0
    LastErrLen   = 0
    OldLog       = ""
}

# ===== UTILITY FUNCTIONS =====
function Protect-PasswordToEncryptedString { 
    param([string]$plain) 
    if ([string]::IsNullOrEmpty($plain)) { return "" }
    (ConvertTo-SecureString $plain -AsPlainText -Force) | ConvertFrom-SecureString 
}

function Unprotect-EncryptedStringToPassword {
    param([string]$encrypted)
    if ([string]::IsNullOrEmpty($encrypted)) { return "" }
    try { 
        $sec = $encrypted | ConvertTo-SecureString
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) } 
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } 
    }
    catch { "" }
}

# ===== LOG WRITER with smart font selection =====
# This replaces the previous Write-LogUI and handles both box-drawing characters
# and emoji: default font = Consolas (for ASCII/box drawing), switches to
# Segoe UI Emoji for lines containing emoji.
function Write-LogUI {
    param($text, $color = $null)

    if ($null -eq $color) { $color = $script:themes[$script:currentTheme].LogFore }

    # Detect box-drawing characters (Unicode range U+2500 - U+257F)
    $hasBoxDrawing = [regex]::IsMatch($text, '[\u2500-\u257F]')

    # Detect emojis/symbols used in the app (add more if needed)
    $emojiPattern = '✓|⚠|🌐|📹|ℹ|✗|⏱️|🚀|📊|🎉|🔍|💾|🗑️|▶|❌'
    $hasEmoji = $false
    try { $hasEmoji = ($text -match $emojiPattern) } catch { $hasEmoji = $false }

    if ($hasBoxDrawing) {
        $fontName = "Consolas"
    } elseif ($hasEmoji) {
        $fontName = "Segoe UI Emoji"
    } else {
        # Use Segoe UI for general UI-friendly rendering (better than Consolas for text)
        $fontName = "Segoe UI"
    }

    # Ensure UI thread access and set selection font appropriately
    if ($script:form -and $script:form.InvokeRequired) {
        $script:form.BeginInvoke([action]{
            $rt = $script:rtLog
            try {
                $selFont = New-Object System.Drawing.Font($fontName, 11)
            } catch {
                $selFont = New-Object System.Drawing.Font("Segoe UI", 11)
            }
            $rt.SelectionStart = $rt.TextLength
            $rt.SelectionLength = 0
            $rt.SelectionColor = $color
            $rt.SelectionFont = $selFont
            $rt.AppendText($text + "`r`n")
            $rt.ScrollToCaret()
        })
    } else {
        $rt = $script:rtLog
        try {
            $selFont = New-Object System.Drawing.Font($fontName, 11)
        } catch {
            $selFont = New-Object System.Drawing.Font("Segoe UI", 11)
        }
        $rt.SelectionStart = $rt.TextLength
        $rt.SelectionLength = 0
        $rt.SelectionColor = $color
        $rt.SelectionFont = $selFont
        $rt.AppendText($text + "`r`n")
        $rt.ScrollToCaret()
    }
}

function Apply-Theme {
    param([string]$themeName)
    
    $script:currentTheme = $themeName
    $t = $script:themes[$themeName]
    
    # Form
    $script:form.BackColor = $t.FormBack
    
    # All labels
    foreach ($ctrl in $script:form.Controls) {
        if ($ctrl -is [System.Windows.Forms.Label]) {
            $ctrl.ForeColor = $t.TextFore
        }
        if ($ctrl -is [System.Windows.Forms.TextBox]) {
            $ctrl.BackColor = $t.PanelBack
            $ctrl.ForeColor = $t.TextFore
        }
        if ($ctrl -is [System.Windows.Forms.CheckBox]) {
            $ctrl.ForeColor = $t.TextFore
        }
    }
    
    # GroupBoxes with colored headers
    $script:grpConfig.BackColor = $t.PanelBack
    $script:grpConfig.ForeColor = $t.GroupBoxFore
    $script:grpFolders.BackColor = $t.PanelBack
    $script:grpFolders.ForeColor = $t.GroupBoxFore
    $script:grpControl.BackColor = $t.PanelBack
    $script:grpControl.ForeColor = $t.GroupBoxFore
    $script:grpProgress.BackColor = $t.PanelBack
    $script:grpProgress.ForeColor = $t.GroupBoxFore
    
    # Buttons
    $script:btnStart.BackColor = $t.BtnStart
    $script:btnExit.BackColor = $t.BtnExit
    $script:btnDryRun.BackColor = $t.BtnDry
    $script:btnSave.BackColor = $t.BtnNormal
    $script:btnClear.BackColor = $t.BtnNormal
    
    # Log
    $script:rtLog.BackColor = $t.LogBack
    $script:rtLog.ForeColor = $t.LogFore
    
    # Status Label
    $script:lblStatus.ForeColor = $t.TextFore
    
    # Progress Bar (keep color)
    $script:progressBar.ForeColor = [System.Drawing.Color]::Green
    
    # Update all textboxes in GroupBoxes
    foreach ($grp in @($script:grpConfig, $script:grpFolders, $script:grpControl)) {
        foreach ($ctrl in $grp.Controls) {
            if ($ctrl -is [System.Windows.Forms.TextBox]) {
                $ctrl.BackColor = $t.PanelBack
                $ctrl.ForeColor = $t.TextFore
            }
            if ($ctrl -is [System.Windows.Forms.Label]) {
                $ctrl.ForeColor = $t.TextFore
            }
            if ($ctrl -is [System.Windows.Forms.CheckBox]) {
                $ctrl.ForeColor = $t.TextFore
            }
        }
    }
    
    $script:form.Refresh()
}

# ===== CONFIG FUNCTIONS =====
function Save-Config {
    param($path)
    $targets = @()
    foreach ($d in ($txtDomains.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { 
        $targets += @{ baseUrl = $d } 
    }
    $cfgObj = @{
        SourceDir = $txtSourceDir.Text
        OpenAI = @{ apiKey = $txtOpenAI.Text }
        DeleteOnSuccess = $chkDelete.Checked
        user = $txtUser.Text
        passEncrypted = Protect-PasswordToEncryptedString -plain $txtPass.Text
        categories_id = if ($txtCategory.Text -match '^\d+$') { [int]$txtCategory.Text } else { 0 }
        UploadDelay = if ($txtDelay.Text -match '^\d+$') { [int]$txtDelay.Text } else { 0 }
        targets = $targets
        DarkTheme = ($script:currentTheme -eq 'Dark')
    }
    try { 
        ($cfgObj | ConvertTo-Json -Depth 10) | Out-File -FilePath $path -Encoding UTF8
        Write-LogUI "✓ Config saved to $path" ([System.Drawing.Color]::LightGreen)
        $true 
    }
    catch { 
        Write-LogUI "✗ ERROR saving config: $_" ([System.Drawing.Color]::OrangeRed)
        $false 
    }
}

function Load-Config {
    param($path)
    if (-not (Test-Path $path)) { return $false }
    try { 
        $cfg = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json 
    } catch { 
        Write-LogUI "✗ ERROR reading config.json: $_" ([System.Drawing.Color]::OrangeRed)
        return $false 
    }
    
    if ($cfg.SourceDir) { $txtSourceDir.Text = $cfg.SourceDir }
    if ($cfg.OpenAI -and $cfg.OpenAI.apiKey) { $txtOpenAI.Text = $cfg.OpenAI.apiKey }
    if ($null -ne $cfg.DeleteOnSuccess) { $chkDelete.Checked = [bool]$cfg.DeleteOnSuccess }
    if ($cfg.user) { $txtUser.Text = $cfg.user }
    if ($cfg.passEncrypted) { $txtPass.Text = (Unprotect-EncryptedStringToPassword -encrypted $cfg.passEncrypted) }
    if ($cfg.categories_id -ne $null) { $txtCategory.Text = $cfg.categories_id.ToString() }
    if ($cfg.UploadDelay -ne $null) { $txtDelay.Text = $cfg.UploadDelay.ToString() }
    if ($cfg.targets) { $txtDomains.Lines = @($cfg.targets | ForEach-Object { $_.baseUrl } | Where-Object { $_ }) }
    
    # Load theme preference
    if ($null -ne $cfg.DarkTheme -and $cfg.DarkTheme) {
        $script:currentTheme = 'Dark'
        $chkDarkTheme.Checked = $true
    }
    
    Write-LogUI "✓ Config loaded from $path" ([System.Drawing.Color]::LightGreen)
    $true
}

function Test-DomainCredentials {
    param([string]$baseUrl,[string]$user,[string]$pass)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $u = $baseUrl.TrimEnd('/') + "/plugin/MobileManager/upload.php?user=$([System.Uri]::EscapeDataString($user))&pass=$([System.Uri]::EscapeDataString($pass))"
    try {
        $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -Method GET -TimeoutSec 15 -ErrorAction Stop
        $status = $resp.StatusCode.Value__
        $body = $resp.Content
        try { 
            $j = $body | ConvertFrom-Json -ErrorAction Stop
            $msg = ($j | ConvertTo-Json -Depth 5) -replace '\r?\n',' ' 
        }
        catch { 
            $msg = if ($body.Length -gt 500) { $body.Substring(0,500) + "..." } else { $body } 
        }
        @{ ok = $true; status = $status; response = $msg }
    } catch { 
        @{ ok = $false; error = $_.Exception.Message } 
    }
}

function Do-DryRun {
    $cfgPath = Join-Path $scriptDir 'config.json'
    if (-not (Save-Config -path $cfgPath)) { return }
    
    Write-LogUI "`n"
    Write-LogUI "═══════════════════════════════════════" ([System.Drawing.Color]::Cyan)
    Write-LogUI "🔍 DRY RUN STARTED" ([System.Drawing.Color]::Yellow)
    Write-LogUI "═══════════════════════════════════════" ([System.Drawing.Color]::Cyan)
    
    $src = $txtSourceDir.Text
    if (-not (Test-Path $src)) { 
        Write-LogUI "✗ SourceDir not found: $src" ([System.Drawing.Color]::OrangeRed) 
    }
    else {
        try {
            $files = Get-ChildItem -Path $src -Filter *.mp4 -File -ErrorAction Stop | Sort-Object Name
            Write-LogUI "✓ Found $($files.Count) .mp4 file(s) in:" ([System.Drawing.Color]::LightGreen)
            Write-LogUI "  $src" ([System.Drawing.Color]::Gray)
            foreach ($f in $files) { 
                Write-LogUI "  📹 $($f.Name)" ([System.Drawing.Color]::Cyan)
            }
        } catch { 
            Write-LogUI "✗ Error listing files in ${src}: $_" ([System.Drawing.Color]::OrangeRed) 
        }
    }
    
    $user=$txtUser.Text
    $pass=$txtPass.Text
    if ([string]::IsNullOrEmpty($user) -or [string]::IsNullOrEmpty($pass)) { 
        Write-LogUI "⚠ Warning: user or password is empty." ([System.Drawing.Color]::Orange) 
    }
    
    # Display delay info
    $delay = if ($txtDelay.Text -match '^\d+$') { [int]$txtDelay.Text } else { 0 }
    if ($delay -gt 0) {
        Write-LogUI "⏱️  Upload delay configured: $delay seconds between uploads" ([System.Drawing.Color]::Cyan)
    } else {
        Write-LogUI "⏱️  No upload delay configured (uploads will be continuous)" ([System.Drawing.Color]::Gray)
    }
    
    $domains = $txtDomains.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($domains.Count -eq 0) { 
        Write-LogUI "⚠ No domains configured to test." ([System.Drawing.Color]::Orange) 
    }
    else {
        Write-LogUI "`n🌐 Testing domain connections..." ([System.Drawing.Color]::Cyan)
        foreach ($d in $domains) {
            Write-LogUI "  → Testing: $d" ([System.Drawing.Color]::LightBlue)
            $r = Test-DomainCredentials -baseUrl $d -user $user -pass $pass
            if ($r.ok) { 
                Write-LogUI "    ✓ HTTPS $($r.status) - Connection OK" ([System.Drawing.Color]::LightGreen) 
            }
            else { 
                Write-LogUI "    ✗ Connection failed: $($r.error)" ([System.Drawing.Color]::OrangeRed) 
            }
        }
    }
    
    try { 
        $btnStart.Enabled = (Test-Path $src) -and ((Get-ChildItem -Path $src -Filter *.mp4 -File -ErrorAction SilentlyContinue).Count -gt 0) 
    } catch {}
    
    Write-LogUI "═══════════════════════════════════════" ([System.Drawing.Color]::Cyan)
    Write-LogUI "✓ DRY RUN COMPLETED" ([System.Drawing.Color]::LightGreen)
    Write-LogUI "═══════════════════════════════════════`n" ([System.Drawing.Color]::Cyan)
}

function Stop-Runner {
    try { 
        if ($script:runner.TailTimer) { 
            $script:runner.TailTimer.Stop()
            $script:runner.TailTimer.Dispose() 
        } 
    } catch {}
    try { 
        if ($script:runner.Proc -and -not $script:runner.Proc.HasExited) { 
            $script:runner.Proc.Kill() 
        } 
    } catch {}
    
    $script:runner.Proc = $null
    $script:runner.StdOutPath = $null
    $script:runner.StdErrPath = $null
    $script:runner.TailTimer = $null
    $script:runner.LastOutLen = 0
    $script:runner.LastErrLen = 0
    $script:runner.OldLog = ""
}

function Start-UploadProcess {
    param([bool]$useAI = $false, [bool]$dryRun = $false)

    Stop-Runner

    # Update status
    $script:lblStatus.Text = "Starting..."
    $script:lblStatus.ForeColor = [System.Drawing.Color]::Orange
    $script:progressBar.Value = 0

    $cfgPath = Join-Path $scriptDir 'config.json'
    if (-not (Save-Config -path $cfgPath)) { return }

    # Baseline for delta
    $uploadLogLocal = Join-Path $scriptDir 'upload.log'
    try {
        $script:runner.OldLog = ""
        if (Test-Path $uploadLogLocal) { 
            $script:runner.OldLog = Get-Content -Path $uploadLogLocal -Raw -Encoding UTF8 -ErrorAction SilentlyContinue 
        }
        if ($null -eq $script:runner.OldLog) { $script:runner.OldLog = "" }
    } catch { $script:runner.OldLog = "" }

    # Choose PowerShell executable
    $psExe = "powershell.exe"
    (Get-Command pwsh -ErrorAction SilentlyContinue -OutVariable temp) | Out-Null
    if ($temp) { $psExe = "pwsh" }

    $uploadScript = Join-Path $scriptDir 'upload.ps1'
    if (-not (Test-Path $uploadScript)) { 
        Write-LogUI "✗ upload.ps1 not found in $scriptDir" ([System.Drawing.Color]::OrangeRed)
        $script:lblStatus.Text = "Error: Script not found"
        $script:lblStatus.ForeColor = [System.Drawing.Color]::Red
        return 
    }

    $argList = @()
    if ($useAI) { $argList += '-UseAI' }
    if ($chkDelete.Checked) { $argList += '-DeleteOnSuccess' }
    if ($dryRun) { $argList += '-WhatIf' }
    
    $argsForPs = @('-NoProfile')
    if ($psExe -match 'powershell') { $argsForPs += @('-ExecutionPolicy','Bypass') }
    $argsForPs += @('-File', "`"$uploadScript`"")
    if ($argList.Count -gt 0) { $argsForPs += $argList }

    # Temp files
    $ts = (Get-Date -Format yyyyMMdd_HHmmss)
    $script:runner.StdOutPath = Join-Path $scriptDir "upload_ps1_out_$ts.log"
    $script:runner.StdErrPath = Join-Path $scriptDir "upload_ps1_err_$ts.log"
	
    Write-LogUI "`n"
    Write-LogUI "╔════════════════════════════════════════════════╗" ([System.Drawing.Color]::Yellow)
    Write-LogUI "║            🚀 UPLOAD PROCESS STARTED            ║" ([System.Drawing.Color]::Yellow)
    Write-LogUI "╚════════════════════════════════════════════════╝" ([System.Drawing.Color]::Yellow)
    
    # Display delay info
    $delay = if ($txtDelay.Text -match '^\d+$') { [int]$txtDelay.Text } else { 0 }
    if ($delay -gt 0) {
        Write-LogUI "⏱️  Upload delay: $delay seconds between uploads" ([System.Drawing.Color]::Cyan)
    }
    Write-LogUI ""

    try {
        $script:runner.Proc = Start-Process -FilePath $psExe -ArgumentList $argsForPs -WorkingDirectory $scriptDir `
            -RedirectStandardOutput $script:runner.StdOutPath -RedirectStandardError $script:runner.StdErrPath `
            -PassThru -WindowStyle Hidden
    } catch { 
        Write-LogUI "✗ Failed to start process: $_" ([System.Drawing.Color]::OrangeRed)
        $script:lblStatus.Text = "Failed to start"
        $script:lblStatus.ForeColor = [System.Drawing.Color]::Red
        Stop-Runner
        return 
    }

    Write-LogUI "📡 Monitoring output...`n" ([System.Drawing.Color]::Cyan)
    
    $script:lblStatus.Text = "Running..."
    $script:lblStatus.ForeColor = [System.Drawing.Color]::LimeGreen
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    
    try { 
        $btnStart.Enabled = $false
        $btnDryRun.Enabled = $false
    } catch {}
    
    $script:runner.LastOutLen = 0
    $script:runner.LastErrLen = 0

    if ([string]::IsNullOrWhiteSpace($script:runner.StdOutPath) -or [string]::IsNullOrWhiteSpace($script:runner.StdErrPath)) {
        Write-LogUI "✗ Internal error: tail paths not set." ([System.Drawing.Color]::OrangeRed)
        return
    }

    $script:runner.TailTimer = New-Object System.Windows.Forms.Timer
    $script:runner.TailTimer.Interval = 700
    $pollCount = 0
    
    # ===== PROGRESS TRACKING VARIABLES =====
    $script:totalFiles = 0
    $script:currentFile = 0

    $script:runner.TailTimer.Add_Tick({
        try {
            $pollCount++

            # ===== READ STDOUT WITH PROGRESS PARSING =====
            if ($script:runner.StdOutPath -and (Test-Path $script:runner.StdOutPath)) {
                $outContent = Get-Content -Path $script:runner.StdOutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($null -ne $outContent -and $outContent.Length -gt $script:runner.LastOutLen) {
                    $new = $outContent.Substring($script:runner.LastOutLen)
                    foreach ($ln in ($new -split '\r?\n')) { 
                        if ($ln.Trim()) { 
                            # ===== PARSE PROGRESS MARKERS =====
                            if ($ln -match '^\[PROGRESS_TOTAL\](\d+)$') {
                                $script:totalFiles = [int]$matches[1]
                                $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                                $script:progressBar.Maximum = $script:totalFiles
                                $script:progressBar.Value = 0
                                Write-LogUI "📊 Total files to upload: $($script:totalFiles)" ([System.Drawing.Color]::Cyan)
                            }
                            elseif ($ln -match '^\[PROGRESS_CURRENT\](\d+)$') {
                                $script:currentFile = [int]$matches[1]
                                if ($script:totalFiles -gt 0) {
                                    # Ensure value within range
                                    if ($script:currentFile -gt $script:progressBar.Maximum) { $script:progressBar.Maximum = $script:currentFile }
                                    $script:progressBar.Value = [math]::Min($script:currentFile, $script:progressBar.Maximum)
                                    $percent = [math]::Round(($script:currentFile / $script:totalFiles) * 100)
                                    $script:lblStatus.Text = "Uploading... ($script:currentFile/$script:totalFiles - $percent%)"
                                    $script:lblStatus.ForeColor = [System.Drawing.Color]::Orange
                                }
                            }
                            elseif ($ln -match '^\[PROGRESS_SUCCESS\](\d+)\|(\d+)$') {
                                $current = [int]$matches[1]
                                $total = [int]$matches[2]
                                if ($total -gt 0) {
                                    if ($script:progressBar.Maximum -ne $total) { $script:progressBar.Maximum = $total }
                                    $script:progressBar.Value = [math]::Min($current, $script:progressBar.Maximum)
                                    $percent = [math]::Round(($current / $total) * 100)
                                    $script:lblStatus.Text = "Uploaded $current/$total files ($percent%)"
                                    $script:lblStatus.ForeColor = [System.Drawing.Color]::LimeGreen
                                }
                            }
                            else {
                                # Normal log output (skip progress markers from display)
                                Write-LogUI $ln
                            }
                        } 
                    }
                    $script:runner.LastOutLen = $outContent.Length
                }
            }
            
            # Read stderr
            if ($script:runner.StdErrPath -and (Test-Path $script:runner.StdErrPath)) {
                $errContent = Get-Content -Path $script:runner.StdErrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($null -ne $errContent -and $errContent.Length -gt $script:runner.LastErrLen) {
                    $newE = $errContent.Substring($script:runner.LastErrLen)
                    foreach ($ln in ($newE -split '\r?\n')) { 
                        if ($ln.Trim()) { 
                            Write-LogUI ("⚠ ERR: " + $ln) ([System.Drawing.Color]::OrangeRed) 
                        } 
                    }
                    $script:runner.LastErrLen = $errContent.Length
                }
            }

            # Check if process exited
            $state = "Running"
            try { 
                if ($script:runner.Proc -and $script:runner.Proc.HasExited) { 
                    $state = "Exited" 
                } 
            } catch {}

            if ($state -eq "Exited") {
                # Final read
                if ($script:runner.StdOutPath -and (Test-Path $script:runner.StdOutPath)) {
                    $outContent = Get-Content -Path $script:runner.StdOutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($null -ne $outContent -and $outContent.Length -gt $script:runner.LastOutLen) {
                        $new = $outContent.Substring($script:runner.LastOutLen)
                        foreach ($ln in ($new -split '\r?\n')) { 
                            if ($ln.Trim() -and $ln -notmatch '^\[PROGRESS_') { 
                                Write-LogUI $ln 
                            } 
                        }
                        $script:runner.LastOutLen = $outContent.Length
                    }
                }

                $exit = $null
                try { $exit = $script:runner.Proc.ExitCode } catch {}
                #Write-LogUI "`n"
                Write-LogUI "╔════════════════════════════════════════════════╗" ([System.Drawing.Color]::Cyan)
                Write-LogUI "║         ✓ PROCESS COMPLETED                    ║" ([System.Drawing.Color]::Cyan)
                Write-LogUI "╚════════════════════════════════════════════════╝" ([System.Drawing.Color]::Cyan)
                Write-LogUI "Exit Code: $exit" ([System.Drawing.Color]::Gray)

                # Build summary
                try {
                    $uploadLogLocal2 = Join-Path $scriptDir 'upload.log'
                    $newLog = ""
                    if (Test-Path $uploadLogLocal2) { 
                        $newLog = Get-Content -Path $uploadLogLocal2 -Raw -Encoding UTF8 -ErrorAction SilentlyContinue 
                    }
                    if ($null -eq $newLog) { $newLog = "" }
                    
                    $delta = ""
                    if ($newLog.Length -gt $script:runner.OldLog.Length) { 
                        $delta = $newLog.Substring($script:runner.OldLog.Length) 
                    }
                    elseif ($newLog.Length -lt $script:runner.OldLog.Length) { 
                        $delta = $newLog 
                    }
					
                    if ($delta.Trim()) {
                        $blocks = $delta -split "={3,}"
                        $summary = @{}
                        $total = 0
                        
                        foreach ($b in $blocks) {
                            $blk = $b.Trim()
                            if ([string]::IsNullOrWhiteSpace($blk)) { continue }
                            
                            # Split by lines and remove empty ones
                            $lines = $blk -split '\r?\n' | Where-Object { $_.Trim() -ne "" }
                            if ($lines.Count -lt 3) { continue }
                            
                            # Find the domain line (format: "domain >> Video ID = 123")
                            $domLine = $lines | Where-Object { $_ -match '>>\s*Video\s+ID\s*=' } | Select-Object -First 1
                            if (-not $domLine) { continue }
                            
                            # Find file line - EXCLUDE [DEBUG_RESULT] lines
                            $fileLine = $lines | Where-Object { 
                                $_ -match 'file\s*=' -and $_ -notmatch '^\[DEBUG_RESULT\]' 
                            } | Select-Object -First 1
                            
                            $statusLine = $lines | Where-Object { $_ -match '^\[Status\]' } | Select-Object -First 1
                            
                            if (-not $fileLine -or -not $statusLine) { continue }
                            if ($statusLine -notmatch 'Upload Succes') { continue }
                            
                            $domain = "unknown"
                            if ($domLine -match '^([^>]+?)\s*>>\s*Video\s+ID\s*=') { 
                                $domain = $matches[1].Trim() 
                            }
                            
                            $filename = "unknown"
                            if ($fileLine -match '\[\d+\s+\w+\s+-\s+[\d:]+\s+sec\]\s+file\s*=\s*"([^"]+)"') {
                                # Match the format: [14 Oct - 01:26:54 sec]  file = "test.mp4"
                                $filename = $matches[1]
                            } elseif ($fileLine -match 'file\s*=\s*"([^"]+)"') {
                                # Fallback: just match file = "filename"
                                $filename = $matches[1]
                            }
                            
                            if (-not $summary.ContainsKey($domain)) { 
                                $summary[$domain] = @() 
                            }
                            $summary[$domain] += $filename
                            $total++
                        }
                        
                        if ($summary.Count -gt 0) {
                            #Write-LogUI "`n"
                            Write-LogUI "╔════════════════════════════════════════════════╗" ([System.Drawing.Color]::LightGreen)
                            Write-LogUI "║             📊 UPLOAD SUMMARY                   ║" ([System.Drawing.Color]::LightGreen)
                            Write-LogUI "╚════════════════════════════════════════════════╝" ([System.Drawing.Color]::LightGreen)
                            
                            foreach ($k in $summary.Keys) { 
                                $list = $summary[$k]
                                Write-LogUI "`n🌐 $k" ([System.Drawing.Color]::Cyan)
                                Write-LogUI "   ✓ $($list.Count) videos uploaded" ([System.Drawing.Color]::LightGreen)
                                foreach ($fn in $list) { 
                                    Write-LogUI "        📹 $fn" ([System.Drawing.Color]::Gray)
                                }
                            }
                            #Write-LogUI "`n"
                            Write-LogUI "════════════════════════════════════════════════" ([System.Drawing.Color]::LightGreen)
                            Write-LogUI "🎉 Total videos uploaded: $total" ([System.Drawing.Color]::LightGreen)
                            Write-LogUI "════════════════════════════════════════════════`n" ([System.Drawing.Color]::LightGreen)
                            
                            $script:lblStatus.Text = "Completed - $total videos uploaded"
                            $script:lblStatus.ForeColor = [System.Drawing.Color]::LimeGreen
                        } else { 
                            Write-LogUI "ℹ No successful uploads found in log." ([System.Drawing.Color]::LightYellow)
                            $script:lblStatus.Text = "Completed - No uploads"
                            $script:lblStatus.ForeColor = [System.Drawing.Color]::Orange
                        }
                    } else { 
                        Write-LogUI "ℹ No new log entries." ([System.Drawing.Color]::LightYellow) 
                        $script:lblStatus.Text = "Completed"
                        $script:lblStatus.ForeColor = [System.Drawing.Color]::Gray
                    }
                } catch { 
                    Write-LogUI "⚠ Error computing summary: $_" ([System.Drawing.Color]::OrangeRed) 
                }

                # Cleanup
                try { 
                    $script:runner.TailTimer.Stop()
                    $script:runner.TailTimer.Dispose() 
                } catch {}
                
                try {
                    if ($script:runner.StdOutPath -and (Test-Path $script:runner.StdOutPath)) { 
                        Remove-Item $script:runner.StdOutPath -Force -ErrorAction SilentlyContinue 
                    }
                    if ($script:runner.StdErrPath -and (Test-Path $script:runner.StdErrPath)) { 
                        Remove-Item $script:runner.StdErrPath -Force -ErrorAction SilentlyContinue 
                    }
                } catch {}

                # Reset progress bar
                $script:progressBar.Value = $script:progressBar.Maximum

                # Re-enable buttons
                try {
                    $src = $txtSourceDir.Text
                    $btnStart.Enabled = (Test-Path $src) -and ((Get-ChildItem -Path $src -Filter *.mp4 -File -ErrorAction SilentlyContinue).Count -gt 0)
                    $btnDryRun.Enabled = $true
                } catch { 
                    $btnStart.Enabled = $true
                    $btnDryRun.Enabled = $true 
                }

                # Reset runner
                $script:runner.Proc = $null
                $script:runner.StdOutPath = $null
                $script:runner.StdErrPath = $null
                $script:runner.TailTimer = $null
                $script:runner.LastOutLen = 0
                $script:runner.LastErrLen = 0
                $script:runner.OldLog = ""
                $script:totalFiles = 0
                $script:currentFile = 0
            }
        } catch { 
            Write-LogUI "⚠ Tail/poll error: $_" ([System.Drawing.Color]::OrangeRed) 
        }
    })

    try { 
        $script:runner.TailTimer.Start() 
    } catch { 
        Write-LogUI "✗ Failed to start tail timer: $_" ([System.Drawing.Color]::OrangeRed)
        Stop-Runner
        try { 
            $btnStart.Enabled = $true
            $btnDryRun.Enabled = $true 
        } catch {} 
    }
}

# ===== UI CREATION =====
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$form = New-Object System.Windows.Forms.Form
$form.Text = "AVideo Uploader - $version"
$form.Size = New-Object System.Drawing.Size(980, 920)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $true

$baseFontName = "Segoe UI"
$baseFontSize = 12
$titleFontSize = 14
$headerFontSize = 13

# ===== TITLE =====
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(15, 10)
$lblTitle.Size = New-Object System.Drawing.Size(600, 28)
$lblTitle.Font = New-Object System.Drawing.Font($baseFontName, $titleFontSize, [System.Drawing.FontStyle]::Bold)
$lblTitle.Text = "AVideo Uploader"
$form.Controls.Add($lblTitle)

# Version label
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Location = New-Object System.Drawing.Point(910, 865)
$lblVersion.Size = New-Object System.Drawing.Size(60, 18)
$lblVersion.Font = New-Object System.Drawing.Font($baseFontName, 8.5)
$lblVersion.Text = $version
$lblVersion.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblVersion)

# Dark Theme Toggle
$chkDarkTheme = New-Object System.Windows.Forms.CheckBox
$chkDarkTheme.Location = New-Object System.Drawing.Point(820, 12)
$chkDarkTheme.Size = New-Object System.Drawing.Size(130, 24)
$chkDarkTheme.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$chkDarkTheme.Text = "🌙 Dark Theme"
$chkDarkTheme.Add_CheckedChanged({
    if ($chkDarkTheme.Checked) {
        Apply-Theme -themeName 'Dark'
    } else {
        Apply-Theme -themeName 'Light'
    }
})
$form.Controls.Add($chkDarkTheme)

# ===== CONFIGURATION GROUP =====
$grpConfig = New-Object System.Windows.Forms.GroupBox
$grpConfig.Location = New-Object System.Drawing.Point(15, 45)
$grpConfig.Size = New-Object System.Drawing.Size(940, 120)
$grpConfig.Text = "  Configuration  "
$grpConfig.Font = New-Object System.Drawing.Font($baseFontName, $headerFontSize, [System.Drawing.FontStyle]::Bold)
$grpConfig.ForeColor = [System.Drawing.Color]::FromArgb(63, 81, 181)
$form.Controls.Add($grpConfig)

# SourceDir
$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Location = New-Object System.Drawing.Point(15, 28)
$lblSource.Size = New-Object System.Drawing.Size(90, 22)
$lblSource.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblSource.Text = "Source Folder:"
$grpConfig.Controls.Add($lblSource)

$txtSourceDir = New-Object System.Windows.Forms.TextBox
$txtSourceDir.Location = New-Object System.Drawing.Point(115, 26)
$txtSourceDir.Size = New-Object System.Drawing.Size(650, 24)
$txtSourceDir.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtSourceDir.Text = (Join-Path $scriptDir 'to_upload')
$grpConfig.Controls.Add($txtSourceDir)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Location = New-Object System.Drawing.Point(775, 24)
$btnBrowse.Size = New-Object System.Drawing.Size(145, 28)
$btnBrowse.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$btnBrowse.Text = "Browse..."
$btnBrowse.Add_Click({ 
    $fd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fd.SelectedPath = $txtSourceDir.Text
    if ($fd.ShowDialog() -eq "OK") { 
        $txtSourceDir.Text = $fd.SelectedPath 
    } 
})
$grpConfig.Controls.Add($btnBrowse)

# OpenAI Key
$lblOpenAI = New-Object System.Windows.Forms.Label
$lblOpenAI.Location = New-Object System.Drawing.Point(15, 65)
$lblOpenAI.Size = New-Object System.Drawing.Size(90, 22)
$lblOpenAI.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblOpenAI.Text = "OpenAI Key:"
$grpConfig.Controls.Add($lblOpenAI)

$txtOpenAI = New-Object System.Windows.Forms.TextBox
$txtOpenAI.Location = New-Object System.Drawing.Point(115, 63)
$txtOpenAI.Size = New-Object System.Drawing.Size(490, 24)
$txtOpenAI.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtOpenAI.UseSystemPasswordChar = $true
$grpConfig.Controls.Add($txtOpenAI)

$chkAI = New-Object System.Windows.Forms.CheckBox
$chkAI.Location = New-Object System.Drawing.Point(620, 63)
$chkAI.Size = New-Object System.Drawing.Size(150, 24)
$chkAI.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$chkAI.Text = "Enable AI Titles"
$grpConfig.Controls.Add($chkAI)

$chkDelete = New-Object System.Windows.Forms.CheckBox
$chkDelete.Location = New-Object System.Drawing.Point(775, 63)
$chkDelete.Size = New-Object System.Drawing.Size(150, 24)
$chkDelete.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$chkDelete.Text = "Delete on Success"
$chkDelete.Checked = $true
$grpConfig.Controls.Add($chkDelete)

# ===== FOLDERS GROUP (Domains + Credentials) =====
$grpFolders = New-Object System.Windows.Forms.GroupBox
$grpFolders.Location = New-Object System.Drawing.Point(15, 175)
$grpFolders.Size = New-Object System.Drawing.Size(940, 210)
$grpFolders.Text = "  Upload Targets  "
$grpFolders.Font = New-Object System.Drawing.Font($baseFontName, $headerFontSize, [System.Drawing.FontStyle]::Bold)
$grpFolders.ForeColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
$form.Controls.Add($grpFolders)

# Domains
$lblDomains = New-Object System.Windows.Forms.Label
$lblDomains.Location = New-Object System.Drawing.Point(15, 28)
$lblDomains.Size = New-Object System.Drawing.Size(90, 22)
$lblDomains.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblDomains.Text = "Domains:"
$grpFolders.Controls.Add($lblDomains)

$txtDomains = New-Object System.Windows.Forms.TextBox
$txtDomains.Location = New-Object System.Drawing.Point(115, 26)
$txtDomains.Size = New-Object System.Drawing.Size(805, 90)
$txtDomains.Multiline = $true
$txtDomains.ScrollBars = "Vertical"
$txtDomains.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtDomains.Text = "https://example.com"
$grpFolders.Controls.Add($txtDomains)

# User
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Location = New-Object System.Drawing.Point(15, 130)
$lblUser.Size = New-Object System.Drawing.Size(90, 22)
$lblUser.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblUser.Text = "Username:"
$grpFolders.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(115, 128)
$txtUser.Size = New-Object System.Drawing.Size(230, 24)
$txtUser.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtUser.Text = "admin"
$grpFolders.Controls.Add($txtUser)

# Password
$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Location = New-Object System.Drawing.Point(370, 130)
$lblPass.Size = New-Object System.Drawing.Size(80, 22)
$lblPass.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblPass.Text = "Password:"
$grpFolders.Controls.Add($lblPass)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(460, 128)
$txtPass.Size = New-Object System.Drawing.Size(230, 24)
$txtPass.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtPass.UseSystemPasswordChar = $true
$grpFolders.Controls.Add($txtPass)

# Category ID
$lblCategory = New-Object System.Windows.Forms.Label
$lblCategory.Location = New-Object System.Drawing.Point(15, 168)
$lblCategory.Size = New-Object System.Drawing.Size(100, 22)
$lblCategory.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblCategory.Text = "Category ID:"
$grpFolders.Controls.Add($lblCategory)

$txtCategory = New-Object System.Windows.Forms.TextBox
$txtCategory.Location = New-Object System.Drawing.Point(115, 166)
$txtCategory.Size = New-Object System.Drawing.Size(100, 24)
$txtCategory.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtCategory.Text = "0"
$grpFolders.Controls.Add($txtCategory)

# ===== UPLOAD DELAY =====
$lblDelay = New-Object System.Windows.Forms.Label
$lblDelay.Location = New-Object System.Drawing.Point(370, 168)
$lblDelay.Size = New-Object System.Drawing.Size(120, 22)
$lblDelay.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblDelay.Text = "Upload Delay:"
$grpFolders.Controls.Add($lblDelay)

$txtDelay = New-Object System.Windows.Forms.TextBox
$txtDelay.Location = New-Object System.Drawing.Point(490, 166)
$txtDelay.Size = New-Object System.Drawing.Size(80, 24)
$txtDelay.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$txtDelay.Text = "0"
$grpFolders.Controls.Add($txtDelay)

$lblDelaySec = New-Object System.Windows.Forms.Label
$lblDelaySec.Location = New-Object System.Drawing.Point(575, 168)
$lblDelaySec.Size = New-Object System.Drawing.Size(40, 22)
$lblDelaySec.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$lblDelaySec.Text = "sec"
$grpFolders.Controls.Add($lblDelaySec)

# ===== CONTROL PANEL GROUP =====
$grpControl = New-Object System.Windows.Forms.GroupBox
$grpControl.Location = New-Object System.Drawing.Point(15, 395)
$grpControl.Size = New-Object System.Drawing.Size(940, 90)
$grpControl.Text = "  Control Panel  "
$grpControl.Font = New-Object System.Drawing.Font($baseFontName, $headerFontSize, [System.Drawing.FontStyle]::Bold)
$grpControl.ForeColor = [System.Drawing.Color]::FromArgb(255, 152, 0)
$form.Controls.Add($grpControl)

# Buttons row
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Location = New-Object System.Drawing.Point(40, 35)
$btnStart.Size = New-Object System.Drawing.Size(160, 38)
$btnStart.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize, [System.Drawing.FontStyle]::Bold)
$btnStart.Text = "▶ Start Upload"
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(144, 238, 144)
$btnStart.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnStart.Add_Click({ 
    Start-UploadProcess -useAI:$chkAI.Checked -dryRun:$false 
})
$grpControl.Controls.Add($btnStart)

$btnDryRun = New-Object System.Windows.Forms.Button
$btnDryRun.Location = New-Object System.Drawing.Point(220, 35)
$btnDryRun.Size = New-Object System.Drawing.Size(150, 38)
$btnDryRun.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$btnDryRun.Text = "🔍 Dry Run"
$btnDryRun.BackColor = [System.Drawing.Color]::FromArgb(255, 215, 0)
$btnDryRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDryRun.Add_Click({ Do-DryRun })
$grpControl.Controls.Add($btnDryRun)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Location = New-Object System.Drawing.Point(390, 35)
$btnSave.Size = New-Object System.Drawing.Size(150, 38)
$btnSave.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$btnSave.Text = "💾 Save Config"
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSave.Add_Click({ 
    Save-Config -path (Join-Path $scriptDir 'config.json') 
})
$grpControl.Controls.Add($btnSave)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Location = New-Object System.Drawing.Point(560, 35)
$btnClear.Size = New-Object System.Drawing.Size(150, 38)
$btnClear.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize)
$btnClear.Text = "🗑️ Clear Log"
$btnClear.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$btnClear.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClear.Add_Click({ $script:rtLog.Clear() })
$grpControl.Controls.Add($btnClear)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Location = New-Object System.Drawing.Point(730, 35)
$btnExit.Size = New-Object System.Drawing.Size(150, 38)
$btnExit.Font = New-Object System.Drawing.Font($baseFontName, $baseFontSize, [System.Drawing.FontStyle]::Bold)
$btnExit.Text = "❌ EXIT"
$btnExit.BackColor = [System.Drawing.Color]::FromArgb(255, 182, 193)
$btnExit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnExit.Add_Click({ 
    Stop-Runner
    try { $form.Close() } catch {} 
})
$grpControl.Controls.Add($btnExit)

# ===== PROGRESS GROUP =====
$grpProgress = New-Object System.Windows.Forms.GroupBox
$grpProgress.Location = New-Object System.Drawing.Point(15, 495)
$grpProgress.Size = New-Object System.Drawing.Size(940, 80)
$grpProgress.Text = "  Progress  "
$grpProgress.Font = New-Object System.Drawing.Font($baseFontName, $headerFontSize, [System.Drawing.FontStyle]::Bold)
$grpProgress.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 136)
$form.Controls.Add($grpProgress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 30)
$lblStatus.Size = New-Object System.Drawing.Size(300, 24)
$lblStatus.Font = New-Object System.Drawing.Font($baseFontName, 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.Text = "Ready..."
$lblStatus.ForeColor = [System.Drawing.Color]::Gray
$grpProgress.Controls.Add($lblStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(340, 30)
$progressBar.Size = New-Object System.Drawing.Size(570, 24)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progressBar.Value = 0
$grpProgress.Controls.Add($progressBar)

# ===== LOG TAB =====
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(15, 585)
$tabControl.Size = New-Object System.Drawing.Size(940, 270)
$tabControl.Name = "tabControl"
$form.Controls.Add($tabControl)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = "📋 Output Log"
$tabLog.Name = "tabLog"
$tabControl.Controls.Add($tabLog)

$rtLog = New-Object System.Windows.Forms.RichTextBox
$rtLog.Name = "rtLog"
$rtLog.Dock = "Fill"
$rtLog.ReadOnly = $true
$rtLog.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$rtLog.ForeColor = [System.Drawing.Color]::Black
# Default to monospaced font so box-drawing characters render correctly
try {
    $rtLog.Font = New-Object System.Drawing.Font("Consolas", 11)
} catch {
    $rtLog.Font = New-Object System.Drawing.Font("Segoe UI", 11)
}
$tabLog.Controls.Add($rtLog)

# ===== FORM EVENT HANDLERS =====
$form.Add_FormClosing({ Stop-Runner })

# Store global references
$script:form = $form
$script:txtSourceDir = $txtSourceDir
$script:txtDomains = $txtDomains
$script:txtUser = $txtUser
$script:txtPass = $txtPass
$script:txtCategory = $txtCategory
$script:txtDelay = $txtDelay
$script:txtOpenAI = $txtOpenAI
$script:chkAI = $chkAI
$script:chkDelete = $chkDelete
$script:chkDarkTheme = $chkDarkTheme
$script:btnStart = $btnStart
$script:btnDryRun = $btnDryRun
$script:btnSave = $btnSave
$script:btnClear = $btnClear
$script:btnExit = $btnExit
$script:rtLog = $rtLog
$script:lblStatus = $lblStatus
$script:progressBar = $progressBar
$script:grpConfig = $grpConfig
$script:grpFolders = $grpFolders
$script:grpControl = $grpControl
$script:grpProgress = $grpProgress

# ===== INITIALIZATION =====
Write-LogUI "╔════════════════════════════════════════════════╗" ([System.Drawing.Color]::Cyan)
Write-LogUI "║     AVideo Uploader $version - Initialized         ║" ([System.Drawing.Color]::Cyan)
Write-LogUI "╚════════════════════════════════════════════════╝" ([System.Drawing.Color]::Cyan)
Write-LogUI ""

$configPath = Join-Path $scriptDir 'config.json'
if (Test-Path $configPath) { 
    Load-Config -path $configPath
    Apply-Theme -themeName $script:currentTheme
} else { 
    Write-LogUI "ℹ No config.json found. Please configure settings and click Save Config." ([System.Drawing.Color]::LightYellow)
    Apply-Theme -themeName 'Light'
}

try {
    $src = $txtSourceDir.Text
    $btnStart.Enabled = (Test-Path $src) -and ((Get-ChildItem -Path $src -Filter *.mp4 -File -ErrorAction SilentlyContinue).Count -gt 0)
} catch {}

[void]$form.ShowDialog()
