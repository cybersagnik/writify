#requires -Version 5.1
<#
Writify v1.0.0 - shell-native PoC & writeup capture tool (Windows/PowerShell)

Architecture
------------
The workspace is the single Git repository.
.writify/ is kept local via .gitignore.
Git tracks only:
  README.md
  screenshots/
  artifacts/

Key behavior
------------
- Win+Shift+S (Snipping Tool) auto-captures screenshots into screenshots/poc-N.png
  via clipboard detection in the background daemon.
- Daemon screenshots are NOT auto-included in README.
  Attach explicitly to insert at the correct timeline position:
      writify attach screenshots\poc-1.png "caption"
- Build renders the solve log as an ordered timeline.
- Attachments are inserted exactly where they were attached.
- Paths in README are normalized to forward slashes for GitHub rendering.

Usage:
    .\writify.ps1 <command> [args]
    writify <command> [args]   (after 'writify init')
#>

param(
    [Parameter(Position = 0)] [string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]]$Rest = @()
)

# ---------------------------------------------------------------------
# Constants / paths
# ---------------------------------------------------------------------

$WritifyVersion   = "1.0.0"

$WritifyDir       = ".writify"
$ConfigFile       = Join-Path $WritifyDir "config.json"
$SolveLog         = Join-Path $WritifyDir "solve_log.txt"
$CounterFile      = Join-Path $WritifyDir "poc_counter.txt"
$DaemonPidFile    = Join-Path $WritifyDir "daemon.pid"
$TriggerFile      = Join-Path $WritifyDir "capture.trigger"
$LastBuildFile    = Join-Path $WritifyDir "last_build.txt"

$ScreenshotsDir   = "screenshots"
$ArtifactsDir     = "artifacts"

$DefaultNoteTypes = @("observation", "finding", "command", "result", "dead_end")

# ---------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------

function Get-Ts {
    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Write-Ok($Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Err($Message) {
    Write-Host "ERR $Message" -ForegroundColor Red
}

function Write-Info($Message) {
    Write-Host "->  $Message" -ForegroundColor Cyan
}

function Is-Image($Path) {
    return ($Path -match '\.(png|jpg|jpeg|gif|bmp|webp)$')
}

function Normalize-RepoPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return ($Path -replace '\\', '/')
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)] [string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-AuthorName($Config) {
    if ($Config -and $Config.AUTHOR) { return $Config.AUTHOR }
    $name = git config --get user.name 2>$null
    if ($name) { return $name }
    $name = git config --global --get user.name 2>$null
    if ($name) { return $name }
    return ""
}

function Guess-Lang($Path) {
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".py"   { "python"     }
        ".ps1"  { "powershell" }
        ".js"   { "javascript" }
        ".ts"   { "typescript" }
        ".go"   { "go"         }
        ".c"    { "c"          }
        ".cpp"  { "cpp"        }
        ".h"    { "c"          }
        ".java" { "java"       }
        ".sh"   { "bash"       }
        ".rb"   { "ruby"       }
        ".php"  { "php"        }
        ".rs"   { "rust"       }
        default { ""           }
    }
}

function Require-Workspace {
    if (-not (Test-Path $WritifyDir)) {
        Write-Err "Not a writify workspace. Run '.\writify.ps1 start <name>' first."
        exit 1
    }
}

function Read-Config {
    if (Test-Path $ConfigFile) {
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 8 | Set-Content $ConfigFile
}

function Ensure-WorkspaceFiles {
    Ensure-Directory $WritifyDir
    if (-not (Test-Path $SolveLog))   { New-Item -ItemType File -Path $SolveLog   -Force | Out-Null }
    if (-not (Test-Path $CounterFile)) { Set-Content $CounterFile "0" }
}

function Get-NextPocPath {
    if (-not (Test-Path $CounterFile)) { Set-Content $CounterFile "0" }
    $n = 0
    try { $n = [int](Get-Content $CounterFile -ErrorAction SilentlyContinue) } catch { $n = 0 }
    $n++
    Set-Content $CounterFile $n
    $rel = "$ScreenshotsDir\poc-$n.png"
    return [pscustomobject]@{
        Number       = $n
        RelativePath = $rel
        FullPath     = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $rel))
    }
}

function Save-ClipboardImageToFile {
    param([Parameter(Mandatory = $true)] [string]$OutFile)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $false }
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $img) { return $false }
        $outDir = Split-Path $OutFile -Parent
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $bmp = New-Object System.Drawing.Bitmap $img
        $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $true
    }
    catch { return $false }
}

function Get-ClipboardImageSignature {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $img) { return $null }
        $bmp   = New-Object System.Drawing.Bitmap $img
        $ms    = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $sha   = [System.Security.Cryptography.SHA256]::Create()
        $hash  = $sha.ComputeHash($bytes)
        $sig   = [System.BitConverter]::ToString($hash) -replace '-', ''
        $bmp.Dispose(); $ms.Dispose(); $sha.Dispose()
        return $sig
    }
    catch { return $null }
}

function Take-Screenshot {
    param([Parameter(Mandatory = $true)] [string]$OutFile)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $resolved  = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutFile))
        $outputDir = Split-Path $resolved -Parent
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp    = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $g      = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bmp.Save($resolved, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $true
    }
    catch {
        Write-Err "Screenshot failed: $_"
        return $false
    }
}

# ---------------------------------------------------------------------
# Remote helpers
# ---------------------------------------------------------------------

function Ensure-Remote {
    $cfg       = Read-Config
    $hasRemote = $false
    try { git remote get-url origin | Out-Null; $hasRemote = $true } catch { $hasRemote = $false }

    if (-not $hasRemote) {
        $remote = $null
        if ($cfg -and $cfg.REMOTE) { $remote = $cfg.REMOTE }
        if (-not $remote) { $remote = Read-Host "No remote configured. Git remote URL to push to" }
        if (-not $remote) { Write-Err "No remote provided - cannot push."; exit 1 }
        git remote add origin $remote
        if ($cfg) { $cfg.REMOTE = $remote; Save-Config $cfg }
    }
}

function Commit-And-Push {
    param([Parameter(Mandatory = $true)] [string]$CommitMessage)

    git add -A | Out-Null
    git commit -q -m $CommitMessage 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Info "Nothing new to commit." }

    $branch = git branch --show-current
    if (-not $branch) { $branch = "main"; git branch -M main }

    git push -u origin $branch
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Push failed. Check remote/credentials and try again."
        exit 1
    }
}

# ---------------------------------------------------------------------
# Timeline event parsing
# ---------------------------------------------------------------------

function Convert-NoteTypeToHeading {
    param([Parameter(Mandatory = $true)] [string]$Type)
    switch ($Type) {
        "observation" { return "Observations" }
        "finding"     { return "Findings"     }
        "command"     { return "Commands"     }
        "dead_end"    { return "Dead Ends"    }
        "result"      { return "Results"      }
        default {
            $normalized = $Type -replace '[_\-]+', ' '
            if ([string]::IsNullOrWhiteSpace($normalized)) { return "Notes" }
            $words = $normalized -split '\s+' | Where-Object { $_ }
            $title = foreach ($w in $words) {
                if ($w.Length -gt 1) { $w.Substring(0,1).ToUpper() + $w.Substring(1) } else { $w.ToUpper() }
            }
            return ($title -join ' ')
        }
    }
}

function Parse-SolveLogEvents {
    if (-not (Test-Path $SolveLog)) { return @() }
    $events = New-Object System.Collections.Generic.List[object]

    foreach ($line in Get-Content $SolveLog) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|', 5
        if ($parts.Count -lt 2) { continue }

        $timestamp = $parts[0]
        $eventType = $parts[1]

        switch ($eventType) {
            "note" {
                if ($parts.Count -lt 4) { continue }
                $events.Add([pscustomobject]@{
                    Timestamp = $timestamp
                    EventType = "note"
                    NoteType  = $parts[2]
                    Text      = $parts[3]
                    Path      = $null
                    Kind      = $null
                    Caption   = $null
                })
            }
            "attach" {
                if ($parts.Count -lt 4) { continue }
                $caption = if ($parts.Count -ge 5) { $parts[4] } else { "" }
                $events.Add([pscustomobject]@{
                    Timestamp = $timestamp
                    EventType = "attach"
                    NoteType  = $null
                    Text      = $null
                    Path      = $parts[2]
                    Kind      = $parts[3]
                    Caption   = $caption
                })
            }
            default {
                # screenshot / revision_request / unknown events are not rendered
            }
        }
    }

    return $events
}

function Render-AttachmentLines {
    param([Parameter(Mandatory = $true)] [pscustomobject]$Event)

    $lines   = New-Object System.Collections.Generic.List[string]
    $path    = Normalize-RepoPath $Event.Path
    $kind    = $Event.Kind
    $caption = $Event.Caption

    if ($kind -eq "image") {
        $alt = if ([string]::IsNullOrWhiteSpace($caption)) { "attachment" } else { $caption }
        $lines.Add("![$alt]($path)")
        return $lines
    }

    if (-not [string]::IsNullOrWhiteSpace($caption)) {
        $lines.Add("**$caption**")
        $lines.Add("")
    }

    $lang = Guess-Lang $path
    $lines.Add('```' + $lang)
    if (Test-Path $Event.Path) {
        foreach ($fileLine in Get-Content $Event.Path) { $lines.Add($fileLine) }
    } else {
        $lines.Add("# Missing attachment: $path")
    }
    $lines.Add('```')
    return $lines
}

# ---------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------

function Start-Daemon {
    if (Test-Path $DaemonPidFile) {
        $existing = Get-Content $DaemonPidFile -ErrorAction SilentlyContinue
        if ($existing -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
            Write-Info "Capture daemon already running (PID $existing)."
            return
        }
    }

    if (Test-Path $TriggerFile) {
        Clear-Content $TriggerFile -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType File -Path $TriggerFile -Force | Out-Null
    }

    $daemonScript = @'
param($TriggerFile, $CounterFile, $SolveLogPath)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-Ts { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Get-NextPocPath {
    param($CounterFile)
    if (-not (Test-Path $CounterFile)) { Set-Content $CounterFile "0" }
    $n = 0
    try { $n = [int](Get-Content $CounterFile -ErrorAction SilentlyContinue) } catch { $n = 0 }
    $n++
    Set-Content $CounterFile $n
    return [pscustomobject]@{
        RelativePath = "screenshots\poc-$n.png"
        FullPath     = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path "screenshots\poc-$n.png"))
    }
}

function Save-ClipboardImage {
    param([string]$OutFile)
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $false }
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $img) { return $false }
        $dir = Split-Path $OutFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp = New-Object System.Drawing.Bitmap $img
        $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $true
    } catch { return $false }
}

function Get-ClipboardSig {
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return $null }
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $img) { return $null }
        $bmp   = New-Object System.Drawing.Bitmap $img
        $ms    = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $sha   = [System.Security.Cryptography.SHA256]::Create()
        $sig   = [System.BitConverter]::ToString($sha.ComputeHash($ms.ToArray())) -replace '-', ''
        $bmp.Dispose(); $ms.Dispose(); $sha.Dispose()
        return $sig
    } catch { return $null }
}

$lastSig = $null

while ($true) {
    # Primary: Win+Shift+S clipboard detection
    try {
        $sig = Get-ClipboardSig
        if ($sig -and $sig -ne $lastSig) {
            $next = Get-NextPocPath -CounterFile $CounterFile
            if (Save-ClipboardImage -OutFile $next.FullPath) {
                Add-Content $SolveLogPath "$(Get-Ts)|screenshot|$($next.RelativePath)"
                $lastSig = $sig
            }
        }
    } catch {}

    # Fallback: manual trigger from 'writify capture'
    try {
        $trigger = Get-Item $TriggerFile -ErrorAction SilentlyContinue
        if ($trigger -and $trigger.Length -gt 0) {
            Clear-Content $TriggerFile -ErrorAction SilentlyContinue
            $next  = Get-NextPocPath -CounterFile $CounterFile
            $saved = Save-ClipboardImage -OutFile $next.FullPath
            if (-not $saved) {
                try {
                    $dir    = Split-Path $next.FullPath -Parent
                    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
                    $bmp    = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
                    $g      = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
                    $bmp.Save($next.FullPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $g.Dispose(); $bmp.Dispose()
                    $saved = $true
                } catch { $saved = $false }
            }
            if ($saved) {
                Add-Content $SolveLogPath "$(Get-Ts)|screenshot|$($next.RelativePath)"
                $sig = Get-ClipboardSig
                if ($sig) { $lastSig = $sig }
            }
        }
    } catch {}

    Start-Sleep -Milliseconds 700
}
'@

    $daemonPath = Join-Path $WritifyDir "daemon_loop.ps1"
    Set-Content $daemonPath $daemonScript

    $proc = Start-Process powershell -ArgumentList @(
        "-NoProfile", "-STA", "-WindowStyle", "Hidden",
        "-File", $daemonPath, $TriggerFile, $CounterFile, $SolveLog
    ) -PassThru -WindowStyle Hidden

    Set-Content $DaemonPidFile $proc.Id
    Write-Ok "Capture daemon started (PID $($proc.Id))."
    Write-Info "Primary: Win+Shift+S clipboard detection.  Fallback: writify capture."
}

# ---------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------

function Cmd-Init {
    Write-Host ("Writify v{0} - global setup" -f $WritifyVersion)

    $selfPath = $MyInvocation.MyCommand.Path
    if (-not $selfPath) { $selfPath = $PSCommandPath }

    $installDir = Join-Path $HOME "bin"
    Ensure-Directory $installDir

    $global:WritifyInstallPath = Join-Path $installDir "writify.ps1"
    Copy-Item $selfPath $global:WritifyInstallPath -Force
    Write-Ok ("Copied to {0}\writify.ps1" -f $installDir)

    function global:writify { & $global:WritifyInstallPath @args }

    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

    $funcDef = "function writify { & `"$global:WritifyInstallPath`" @args }"
    if (-not (Select-String -Path $PROFILE -Pattern 'function writify' -Quiet -ErrorAction SilentlyContinue)) {
        Add-Content -Path $PROFILE -Value $funcDef
        Write-Ok "Added 'writify' to `$PROFILE. Available in this session now."
    } else {
        Write-Info "'writify' already present in `$PROFILE."
    }

    $gname  = Read-Host "Default git author name (blank to skip)"
    $gemail = Read-Host "Default git author email (blank to skip)"
    if ($gname)  { git config --global user.name "$gname" }
    if ($gemail) { git config --global user.email "$gemail" }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git not found in PATH. Install from https://git-scm.com"
    } else {
        Write-Ok "git detected."
    }

    Write-Ok "Writify ready. Run: writify start <workspace-name>"
}

function Cmd-Start {
    param([string]$Name)

    if (-not $Name) { Write-Err "Usage: writify start <name>"; exit 1 }
    if (Test-Path $Name) { Write-Err "Directory '$Name' already exists."; exit 1 }

    New-Item -ItemType Directory -Path $Name | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Name $ScreenshotsDir) | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Name $ArtifactsDir)   | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Name $WritifyDir)      | Out-Null

    Push-Location $Name
    try {
        git init -q

        $description   = Read-Host "Short description of this workspace"
        $defaultAuthor = git config user.name 2>$null
        $author        = Read-Host "Author name [$defaultAuthor]"
        if (-not $author) { $author = $defaultAuthor }
        $remote        = Read-Host "Git remote URL (blank to configure later)"

        $cfg = [ordered]@{
            NAME        = $Name
            DESCRIPTION = $description
            AUTHOR      = $author
            REMOTE      = $remote
            CREATED     = Get-Ts
        }
        Save-Config $cfg
        Ensure-WorkspaceFiles

        # .gitignore: track only README.md, screenshots/, artifacts/
        @(
            "*"
            "!.gitignore"
            "!README.md"
            "!screenshots/"
            "!screenshots/**"
            "!artifacts/"
            "!artifacts/**"
        ) | Set-Content ".gitignore"

        @("# $Name", "", "_Writeup not yet built - run writify build._") | Set-Content "README.md"

        git add -A | Out-Null
        git commit -q -m "writify: initialize workspace ($Name)" | Out-Null

        if ($remote) {
            git remote add origin $remote
            Write-Ok "Remote 'origin' set to $remote"
        }

        Write-Ok "Workspace '$Name' created."
        Start-Daemon
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "cd $Name"
    Write-Host "Then: writify note / writify capture / writify attach / writify build / writify push"
}

function Cmd-Note {
    param([string]$Type, [string[]]$TextParts)

    Require-Workspace

    if (-not $Type -or -not $TextParts -or $TextParts.Count -eq 0) {
        Write-Err "Usage: writify note <type> <text>"
        exit 1
    }

    $normalizedType = $Type.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($normalizedType)) {
        Write-Err "Note type cannot be empty."
        exit 1
    }

    $text = ($TextParts -join " ").Trim()
    Add-Content $SolveLog ("{0}|note|{1}|{2}" -f (Get-Ts), $normalizedType, $text)
    Write-Ok "Added note [$normalizedType]"
}

function Cmd-Attach {
    param([string]$File, [string[]]$CaptionParts)

    Require-Workspace

    if (-not $File)            { Write-Err "Usage: writify attach <file> [caption]"; exit 1 }
    if (-not (Test-Path $File)) { Write-Err "File not found: $File"; exit 1 }

    $caption  = if ($CaptionParts) { ($CaptionParts -join " ").Trim() } else { "" }
    $leaf     = Split-Path $File -Leaf
    $destDir  = if (Is-Image $File) { $ScreenshotsDir } else { $ArtifactsDir }
    $destRel  = Join-Path $destDir $leaf
    $kind     = if (Is-Image $File) { "image" } else { "file" }

    Copy-Item $File $destRel -Force
    Add-Content $SolveLog ("{0}|attach|{1}|{2}|{3}" -f (Get-Ts), $destRel, $kind, $caption)
    Write-Ok "Attached $destRel"
}

function Cmd-Capture {
    Require-Workspace

    $running = $false
    if (Test-Path $DaemonPidFile) {
        $procId = Get-Content $DaemonPidFile
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { $running = $true }
    }

    if ($running) {
        Set-Content $TriggerFile "1"
        Start-Sleep -Milliseconds 1500
        $n = Get-Content $CounterFile
        Write-Ok "Captured screenshots\poc-$n.png"
        return
    }

    $next  = Get-NextPocPath
    $saved = Save-ClipboardImageToFile -OutFile $next.FullPath

    if (-not $saved) {
        if (Take-Screenshot -OutFile $next.RelativePath) { $saved = $true }
    }

    if ($saved) {
        Add-Content $SolveLog ("{0}|screenshot|{1}" -f (Get-Ts), $next.RelativePath)
        Write-Ok "Captured $($next.RelativePath) (daemon not running)"
    } else {
        Write-Err "Could not capture screenshot."
    }
}

function Cmd-Stop {
    Require-Workspace
    if (Test-Path $DaemonPidFile) {
        $procId = Get-Content $DaemonPidFile
        Stop-Process -Id $procId -ErrorAction SilentlyContinue
        Remove-Item $DaemonPidFile -ErrorAction SilentlyContinue
        Write-Ok "Capture daemon stopped."
    } else {
        Write-Info "No daemon running."
    }
}

function Cmd-Build {
    Require-Workspace

    $cfg    = Read-Config
    $author = Get-AuthorName $cfg
    $events = Parse-SolveLogEvents

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("# $($cfg.NAME)")
    $lines.Add("")
    if ($author) { $lines.Add("**Author:** $author  ") }
    $lines.Add("**Date:** $(Get-Date -Format yyyy-MM-dd)  ")
    $lines.Add("")

    if ($cfg.DESCRIPTION) {
        $lines.Add("## Overview")
        $lines.Add("")
        $lines.Add($cfg.DESCRIPTION)
        $lines.Add("")
    }

    $currentNoteType = $null

    foreach ($event in $events) {
        switch ($event.EventType) {
            "note" {
                if ($event.NoteType -ne $currentNoteType) {
                    $currentNoteType = $event.NoteType
                    $lines.Add("## $(Convert-NoteTypeToHeading $currentNoteType)")
                    $lines.Add("")
                }
                if ($event.NoteType -eq "command") {
                    $lines.Add('```powershell')
                    $lines.Add($event.Text)
                    $lines.Add('```')
                } elseif ($event.NoteType -eq "dead_end") {
                    $lines.Add("- ~~$($event.Text)~~")
                } else {
                    $lines.Add("- $($event.Text)")
                }
                $lines.Add("")
            }
            "attach" {
                $attachLines = Render-AttachmentLines -Event $event
                foreach ($l in $attachLines) { $lines.Add($l) }
                $lines.Add("")
            }
        }
    }

    $lines.Add("---")
    $lines.Add("_Generated by Writify v$WritifyVersion - $(Get-Ts)_")

    $lines -join "`n" | Set-Content "README.md"
    Get-Ts | Set-Content $LastBuildFile
    Write-Ok "README.md built."
}

function Cmd-Push {
    Require-Workspace

    # Auto-rebuild if solve log is newer than last build
    $needBuild = (-not (Test-Path $LastBuildFile))
    if (-not $needBuild -and (Test-Path $SolveLog)) {
        $needBuild = (Get-Item $SolveLog).LastWriteTime -gt (Get-Item $LastBuildFile).LastWriteTime
    }
    if ($needBuild) {
        Write-Info "Changes detected since last build - rebuilding..."
        Cmd-Build
    }

    # Revision loop
    while ($true) {
        Write-Host ""
        Write-Host "--------- README.md preview ---------"
        Get-Content "README.md" -TotalCount 80
        Write-Host "--------------------------------------"
        Write-Host ""

        $ans = Read-Host "Needs revision before pushing? [y/N]"
        if ($ans -notmatch '^[yY]') { break }

        $note = Read-Host "What should be changed?"
        Add-Content $SolveLog ('{0}|revision_request|{1}' -f (Get-Ts), $note)

        $target = Read-Host "Edited README directly, or underlying data (solve_log/config)? [readme/data]"
        $editor = $env:EDITOR

        if (-not $editor) {
            Write-Host "No `$env:EDITOR set. Edit the files manually then press Enter."
            if ($target -eq "data") {
                Write-Host "Files: $SolveLog  or  $ConfigFile"
            } else {
                Write-Host "File: README.md"
            }
            Read-Host "Press Enter when done..."
        } else {
            if ($target -eq "data") { & $editor $SolveLog $ConfigFile } else { & $editor "README.md" }
        }

        if ($target -eq "data") {
            Write-Info "Rebuilding from updated data..."
            Cmd-Build
        } else {
            Write-Info "Keeping direct README edits as-is."
        }
    }

    # Commit and push
    Ensure-Remote
    $cfg  = Read-Config
    $name = if ($cfg) { $cfg.NAME } else { "workspace" }
    Commit-And-Push -CommitMessage ("writeup: {0} {1}" -f $name, (Get-Date -Format yyyy-MM-dd))
    Write-Ok "Pushed."

    $remoteUrl = git remote get-url origin 2>$null
    if ($remoteUrl) {
        Write-Info "Repo: $($remoteUrl -replace '\.git$', '')"
    }
}

function Cmd-Pull {
    Require-Workspace
    git pull
}

function Cmd-Status {
    Require-Workspace
    git status
}

function Cmd-Log {
    Require-Workspace
    if (Test-Path $SolveLog) { Get-Content $SolveLog }
}

# ---------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------

switch ($Command) {
    'init'    { Cmd-Init }
    'start'   { Cmd-Start -Name $Rest[0] }
    'capture' { Cmd-Capture }
    'note' {
        $type = if ($Rest.Length -ge 1) { $Rest[0] } else { $null }
        $text = if ($Rest.Length -ge 2) { $Rest[1..($Rest.Length - 1)] } else { @() }
        Cmd-Note -Type $type -TextParts $text
    }
    'attach' {
        $file    = if ($Rest.Length -ge 1) { $Rest[0] } else { $null }
        $caption = if ($Rest.Length -ge 2) { $Rest[1..($Rest.Length - 1)] } else { @() }
        Cmd-Attach -File $file -CaptionParts $caption
    }
    'build'  { Cmd-Build }
    'push'   { Cmd-Push }
    'pull'   { Cmd-Pull }
    'status' { Cmd-Status }
    'log'    { Cmd-Log }
    'stop'   { Cmd-Stop }
    default {
        @(
            "Writify v$WritifyVersion"
            ""
            "Usage: writify <command> [args]"
            ""
            "Commands:"
            "  init                       Global setup, installs 'writify' command"
            "  start <name>               Create workspace, git init, start capture daemon"
            "  capture                    Full-screen capture fallback -> screenshots\poc-N.png"
            "  note <type> <text>         Append timestamped note (any type string accepted)"
            "  attach <file> [caption]    Attach file/image at current timeline position"
            "  build                      Generate README.md from ordered notes + attachments"
            "  push                       Preview -> revision loop -> commit -> git push"
            "  pull                       git pull"
            "  status                     git status"
            "  log                        Print raw solve log"
            "  stop                       Stop background capture daemon"
            ""
            "Default note types: $($DefaultNoteTypes -join ', ')"
            "Custom note types are also accepted freely."
            ""
            "Screenshot workflow:"
            "  Win+Shift+S  -> snip region -> daemon detects clipboard -> saves poc-N.png"
            "  writify capture -> fallback full-screen grab (daemon optional)"
            ""
            "To include a screenshot in the writeup:"
            "  writify attach screenshots\poc-1.png My caption"
            ""
            "Git tracks only:  README.md  screenshots/  artifacts/"
            ".writify/ is local only (gitignored)."
        ) -join [Environment]::NewLine | Write-Host
    }
}