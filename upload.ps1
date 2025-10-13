# upload.ps1 v1.6
# - Consolidated fixes and robust normalization/debug
# - HttpClient multipart upload (pwsh & Windows PowerShell)
# - Single-line DEBUG_RESULT entries to avoid duplicate FAILED blocks
# - Robust targets normalization and success detection
# - Upload delay feature to prevent server overload with FFMPEG processes
# - Fixed domain name in summary (removed protocol from log entries)
# - Real-time progress reporting for UI progress bar
# - Ensure UTF-8 stdout encoding so UI reads emojis/symbols correctly
# - Marker final: UPLOAD_PS1_DONE

param(
    [switch]$UseAI,
    [switch]$DeleteOnSuccess
)

Set-StrictMode -Version Latest

# Ensure stdout and redirection use UTF-8 (important for emoji/symbols)
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # ignore on platforms where this might fail
}

# TLS pentru HTTPS
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Decrypt-Password {
    param([string]$encrypted)
    if ([string]::IsNullOrEmpty($encrypted)) { return "" }
    try {
        $secure = ConvertTo-SecureString $encrypted
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { "" }
}

# --- Load config ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir 'config.json'
if (-not (Test-Path $configPath)) { Write-Output "Nu am găsit config.json în $scriptDir. Creează config.json din UI sau manual."; exit 1 }
try { $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output "Eroare la parsarea config.json: $_"; exit 1 }

# Shared creds
$GlobalUser = if ($cfg.PSObject.Properties.Name -contains 'user') { $cfg.user } else { "" }
$GlobalPass = if ($cfg.PSObject.Properties.Name -contains 'passEncrypted') { Decrypt-Password $cfg.passEncrypted } else { "" }
if ([string]::IsNullOrEmpty($GlobalPass) -and $cfg.PSObject.Properties.Name -contains 'pass') { $GlobalPass = $cfg.pass }
$GlobalCategory = if ($cfg.PSObject.Properties.Name -contains 'categories_id' -and $cfg.categories_id -ne $null) { [int]$cfg.categories_id } else { 0 }

# Upload Delay
$UploadDelay = if ($cfg.PSObject.Properties.Name -contains 'UploadDelay' -and $cfg.UploadDelay -ne $null) { [int]$cfg.UploadDelay } else { 0 }
if ($UploadDelay -gt 0) {
    Write-Output "⏱️  Upload delay configured: $UploadDelay seconds between uploads"
}

# OpenAI (optional)
$OpenAIKey = if ($cfg.OpenAI -and $cfg.OpenAI.apiKey) { $cfg.OpenAI.apiKey } else { $null }

# DeleteOnSuccess default
if ($PSBoundParameters.ContainsKey('DeleteOnSuccess')) {
    $deleteOnSuccess = $true
} else {
    $deleteOnSuccess = $true
    if ($null -ne $cfg.DeleteOnSuccess) { $deleteOnSuccess = [bool]$cfg.DeleteOnSuccess }
}

# Unified log
$logFile = Join-Path $scriptDir "upload.log"
if (-not (Test-Path $logFile)) { "" | Out-File -FilePath $logFile -Encoding UTF8 }

function Write-LogEntry {
    param(
        [string]$Domain,
        [string]$VideoId,
        [string]$FileName,
        [bool]$Success,
        [string]$ServerResponse = ""
    )
    $timestamp = Get-Date -Format "dd MMM - HH:mm:ss 'sec'"
    $statusText = if ($Success) { "Upload Succes" } else { "FAILED" }
    
    # Clean domain - remove protocol and trailing slash for better readability
    $cleanDomain = $Domain -replace '^https?://', '' -replace '/$', ''
    
    $lines = @(
        "$cleanDomain >> Video ID = $VideoId",
        "[$timestamp]  file = `"$FileName`"",
        "[Status] : $statusText"
    )
    if (-not $Success -and $ServerResponse) { $lines += "ServerResponse: $ServerResponse" }
    $lines += "-------------------------------------------------------------------"
    $lines += "======================================="
    $lines += ""
    $lines -join "`r`n" | Out-File -FilePath $logFile -Encoding UTF8 -Append
}

# Targets (normalize as array and validate)
if (-not $cfg.targets) {
    Write-Output "Config invalid: nu există targets în config.json"
    exit 1
}

$targets = @()
foreach ($t in $cfg.targets) {
    if ($null -eq $t) { continue }
    $rawBase = if ($t.PSObject.Properties.Name -contains 'baseUrl' -and $t.baseUrl) { $t.baseUrl } else { $null }
    if ([string]::IsNullOrWhiteSpace($rawBase)) { continue }
    $base = $rawBase.TrimEnd('/')
    $user = if ($t.PSObject.Properties.Name -contains 'user' -and $t.user) { $t.user } else { $GlobalUser }
    $pass = if ($t.PSObject.Properties.Name -contains 'pass' -and $t.pass) { $t.pass } else { $GlobalPass }
    $cat  = if ($t.PSObject.Properties.Name -contains 'categories_id' -and $t.categories_id -ne $null) { [int]$t.categories_id } else { $GlobalCategory }
    $targets += [PSCustomObject]@{ baseUrl = $base; user = $user; pass = $pass; categories_id = $cat }
}

if ($targets.Count -eq 0) {
    Write-Output "Config invalid: nu există targets valide în config.json"
    exit 1
}

$targetCount = [int]$targets.Count

# Flags
$useAI = $false
if ($PSBoundParameters.ContainsKey('UseAI')) { if ($OpenAIKey) { $useAI = $true } else { Write-Output "UseAI cerut dar lipsește OpenAI.apiKey în config.json; UseAI ignorat." } }

function Get-TitleFromAI {
    param([string]$fileName)
    if (-not $OpenAIKey) { return $null }
    $prompt = "Generează un titlu scurt (maxim 8 cuvinte) pentru un videoclip bazat pe numele fișierului: `"$fileName`". Fii concis și descriptiv."
    $body = @{ model = "gpt-3.5-turbo"; messages = @(@{ role = "user"; content = $prompt }); max_tokens = 30; temperature = 0.6 } | ConvertTo-Json -Depth 10
    try {
        $hdr = @{ Authorization = "Bearer $OpenAIKey"; "Content-Type" = "application/json" }
        $resp = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $hdr -Body $body -ErrorAction Stop
        $resp.choices[0].message.content.Trim()
    } catch { Write-Output "Generare titlu AI eșuată: $_"; $null }
}

# Robust Upload function using HttpClient (works in pwsh & Windows PowerShell)
function Upload-FileToTarget {
    param(
        [string]$FilePath,
        [psobject]$Target,
        [string]$Title,
        [string]$Description
    )

    $base = $Target.baseUrl.TrimEnd('/')
    $user = $Target.user
    $pass = $Target.pass
    $categoryId = if ($Target.categories_id) { [int]$Target.categories_id } else { 0 }
    $uploadUrl = "$base/plugin/MobileManager/upload.php?user=$([System.Uri]::EscapeDataString($user))&pass=$([System.Uri]::EscapeDataString($pass))"

    try {
        Add-Type -AssemblyName "System.Net.Http" -ErrorAction SilentlyContinue | Out-Null

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [System.TimeSpan]::FromSeconds(180)

        $multipart = New-Object System.Net.Http.MultipartFormDataContent

        if ($null -ne $Title) {
            $contentTitle = New-Object System.Net.Http.StringContent($Title)
            $multipart.Add($contentTitle, "title")
        }
        if ($null -ne $Description) {
            $contentDesc = New-Object System.Net.Http.StringContent($Description)
            $multipart.Add($contentDesc, "description")
        }
        if ($categoryId -gt 0) {
            $contentCat = New-Object System.Net.Http.StringContent([string]$categoryId)
            $multipart.Add($contentCat, "categories_id")
        }

        try { $fileStream = [System.IO.File]::OpenRead($FilePath) } catch { return @{ success = $false; response = "Cannot open file: $FilePath"; httpStatus = 0 } }
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
        try {
            $mime = "application/octet-stream"
            if ($fileName -match '\.mp4$') { $mime = "video/mp4" }
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mime)
        } catch {}
        $multipart.Add($fileContent, "upl", $fileName)

        $uri = [System.Uri]::new($uploadUrl)
        try {
            $task = $client.PostAsync($uri, $multipart)
            $task.Wait()
            $resp = $task.Result
        } catch {
            try { $fileStream.Dispose() } catch {}
            return @{ success = $false; response = $_.Exception.Message; httpStatus = 0 }
        }

        try {
            $readTask = $resp.Content.ReadAsStringAsync()
            $readTask.Wait()
            $body = $readTask.Result
        } catch {
            try { $fileStream.Dispose() } catch {}
            return @{ success = $false; response = $_.Exception.Message; httpStatus = $resp.StatusCode.Value__ }
        }

        try { $fileStream.Dispose() } catch {}

        $httpStatus = 0
        try { $httpStatus = [int]$resp.StatusCode.Value__ } catch {}

        $isJson = $false
        if ($body -and $body.ToString().Trim().Length -gt 0) {
            $trim = $body.ToString().TrimStart()
            if ($trim.StartsWith('{') -or $trim.StartsWith('[')) { $isJson = $true }
        }

        if (-not $isJson) {
            Write-LogEntry -Domain $base -VideoId "" -FileName $fileName -Success $false -ServerResponse ("Non-JSON response: " + ($body -replace '\r?\n',' '))
            return @{ success = $false; response = $body; httpStatus = $httpStatus }
        }

        try {
            $json = $body | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-LogEntry -Domain $base -VideoId "" -FileName $fileName -Success $false -ServerResponse ("Invalid JSON response: " + ($body -replace '\r?\n',' '))
            return @{ success = $false; response = $body; httpStatus = $httpStatus }
        }

        if ($json -and ($json.PSObject.Properties.Name -contains 'error') -and ($json.error -eq $false) -and ($json.PSObject.Properties.Name -contains 'videos_id') -and $json.videos_id) {
            return @{ success = $true; response = $json; httpStatus = $httpStatus }
        } else {
            return @{ success = $false; response = $json; httpStatus = $httpStatus }
        }
    } catch {
        $err = $_.Exception.Message
        Write-LogEntry -Domain $base -VideoId "" -FileName (Split-Path -Leaf $FilePath) -Success $false -ServerResponse ("Exception: " + $err)
        return @{ success = $false; response = $err; httpStatus = 0 }
    } finally {
        try { if ($multipart -ne $null) { $multipart.Dispose() } } catch {}
        try { if ($client -ne $null) { $client.Dispose() } } catch {}
        try { if ($handler -ne $null) { $handler.Dispose() } } catch {}
    }
}

# Files
$SourceDir = $cfg.SourceDir
try { $SourceDir = (Resolve-Path -Path $SourceDir).ProviderPath } catch { Write-Output "SourceDir invalid: $SourceDir"; exit 1 }
$files = Get-ChildItem -Path $SourceDir -Filter *.mp4 -File | Sort-Object Name
if ($files.Count -eq 0) { Write-Output "Nu am găsit fișiere .mp4 în $SourceDir"; Write-Output "UPLOAD_PS1_DONE"; exit 0 }

# ===== PROGRESS REPORTING: Report total files =====
Write-Output "[PROGRESS_TOTAL]$($files.Count)"

# Main upload loop
for ($i = 0; $i -lt $files.Count; $i++) {
    $file = $files[$i]
    $target = $targets[$i % $targetCount]
    
    # ===== PROGRESS REPORTING: Report current file =====
    Write-Output "[PROGRESS_CURRENT]$($i + 1)"

    $title = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($useAI) { $aiTitle = Get-TitleFromAI -fileName $title; if ($aiTitle) { $title = $aiTitle } }

    Write-Output "Uploading '$($file.Name)' to $($target.baseUrl) ..."
    $res = Upload-FileToTarget -FilePath $file.FullName -Target $target -Title $title -Description ""

    # --- Build compact debug representation but write as single-line DEBUG marker (no FAILED block)
    try {
        if ($null -eq $res) { $debugDump = "NULL" }
        elseif ($res -is [string]) { $debugDump = $res }
        else { try { $debugDump = $res | ConvertTo-Json -Depth 8 -ErrorAction Stop } catch { $debugDump = ($res | Out-String).Trim() } }
    } catch { $debugDump = "ERROR_DUMPING_RESULT: " + $_.Exception.Message }
    $dbgLine = ("[DEBUG_RESULT] {0} | file={1}" -f ($debugDump -replace '\r?\n',' '), $file.Name)
    $dbgLine | Out-File -FilePath $logFile -Encoding UTF8 -Append

    # Try to convert string JSON to object
    if ($res -is [string]) {
        try {
            $maybeObj = $res | ConvertFrom-Json -ErrorAction Stop
            if ($maybeObj) { $res = $maybeObj }
        } catch {}
    }

    # If array, pick the last meaningful object
    if ($res -is [System.Array]) {
        $res = $res | Where-Object { $_ -is [hashtable] -or $_ -is [pscustomobject] } | Select-Object -Last 1
    }

    # Robust detection of 'success'
    $hasSuccess = $false
    try {
        if ($res -is [System.Collections.Hashtable]) {
            $hasSuccess = $res.ContainsKey('success')
        } elseif ($res -is [pscustomobject]) {
            $hasSuccess = $res.PSObject.Properties.Name -contains 'success'
        } elseif ($res -ne $null) {
            $hasSuccess = $res.PSObject.Properties.Name -contains 'success'
        }
    } catch { $hasSuccess = $false }

    if (-not $hasSuccess) {
        Write-LogEntry -Domain $target.baseUrl -VideoId "" -FileName $file.Name -Success $false -ServerResponse ("No result object after normalization. See [DEBUG_RESULT] above.")
        Write-Output "Eroare: rezultat invalid pentru $($file.Name)"
        continue
    }

    $serverMsg = ""
    if (-not $res.success) {
        if ($null -ne $res.response) {
            if ($res.response -is [string]) { $serverMsg = $res.response }
            else { try { $serverMsg = ($res.response | ConvertTo-Json -Depth 10) -replace '\r?\n',' ' } catch { $serverMsg = "$($res.response)" } }
        }
    }

    $videosId = ""
    try {
        if ($res.success -and $res.response.PSObject.Properties.Name -contains 'videos_id' -and $res.response.videos_id) {
            $videosId = $res.response.videos_id
        }
    } catch {}

    Write-LogEntry -Domain $target.baseUrl -VideoId $videosId -FileName $file.Name -Success $res.success -ServerResponse $serverMsg

    if ($res.success) {
        Write-Output "Upload reușit la $($target.baseUrl). videos_id: $videosId"
        
        # ===== PROGRESS REPORTING: Report successful upload =====
        Write-Output "[PROGRESS_SUCCESS]$($i + 1)|$($files.Count)"
        
        if ($deleteOnSuccess) {
            try { Remove-Item -LiteralPath $file.FullName -Force; Write-Output "Fișierul local $($file.Name) a fost șters după upload." } catch { Write-Output "Nu s-a putut șterge fișierul: $_" }
        }
    } else {
        Write-Output "Upload eșuat pentru $($file.Name) -> $($target.baseUrl). Răspuns:"
        if ($serverMsg) { Write-Output $serverMsg }
        $failedDir = Join-Path $SourceDir "failed"
        if (-not (Test-Path $failedDir)) { New-Item -ItemType Directory -Path $failedDir | Out-Null }
        try { Move-Item -LiteralPath $file.FullName -Destination (Join-Path $failedDir $file.Name) -Force; Write-Output "Fișier mutat în failed/." } catch { Write-Output "Nu s-a putut muta fișierul în failed/: $_" }
    }
    
    # ===== UPLOAD DELAY =====
    # Apply delay between uploads to prevent server FFMPEG overload
    if ($UploadDelay -gt 0 -and $i -lt ($files.Count - 1)) {
        Write-Output "⏱️  Waiting $UploadDelay seconds before next upload (to prevent server overload)..."
        Start-Sleep -Seconds $UploadDelay
    }
}

Write-Output "UPLOAD_PS1_DONE"
Write-Output "Batch upload terminat. Vezi log: $logFile"