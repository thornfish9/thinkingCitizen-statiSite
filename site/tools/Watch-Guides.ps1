# Watch-Guides.ps1  
# Watches: site\writing\guides\*.docx
# Writes:  site\content\guides\<slug>.md
# Logs:    every event + conversion status/errors
# Provides: Start/Stop functions to avoid zombie handlers and keep code maintainable.

Set-StrictMode -Version Latest

# ------------------------------
# Configuration / state
# ------------------------------
$script:TC_SourcePrefix  = 'TC.Guides'
$script:TC_Watcher       = $null
$script:TC_Subscriptions = @()

function Get-TCGuidePaths {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ScriptRoot = $PSScriptRoot
    )

    # ScriptRoot is the directory containing this .ps1
    # SiteRoot is parent folder of that directory (matches your original logic)
    $siteRoot   = Split-Path $ScriptRoot -Parent
    $writingDir = Join-Path $siteRoot 'writing\guides'
    $outDir     = Join-Path $siteRoot 'content\guides'

    [PSCustomObject]@{
        SiteRoot   = $siteRoot
        WritingDir = $writingDir
        OutDir     = $outDir
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Write-TCLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter()] [ConsoleColor] $Color = [ConsoleColor]::Gray
    )

    $ts = (Get-Date).ToString("s")
    $line = "[{0}] {1}" -f $ts, $Message

    # Console
    Write-Host $line -ForegroundColor $Color

    # File (best-effort). Set by Start-TCGuideWatcher.
    try {
        if ($script:TC_LogPath -and (Test-Path -LiteralPath (Split-Path $script:TC_LogPath -Parent))) {
            $line | Out-File -FilePath $script:TC_LogPath -Append -Encoding UTF8
        }
    } catch { }
}
  
function Remove-TCGuideSubscriptions {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $SourcePrefix = $script:TC_SourcePrefix
    )

    # Unregister any prior subscriptions from this watcher in *this session*
    Get-EventSubscriber |
        Where-Object { $_.SourceIdentifier -like "$SourcePrefix.*" } |
        ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }

    Remove-Event -SourceIdentifier "$SourcePrefix.*" -ErrorAction SilentlyContinue

    $script:TC_Subscriptions = @()
}

function ConvertTo-TCSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    $slug = $Text.ToLowerInvariant()
    $slug = $slug -replace "[^a-z0-9\s-]", ""
    $slug = $slug -replace "\s+", "-"
    $slug = $slug -replace "-{2,}", "-"
    $slug = $slug.Trim("-")
    return $slug
}

function Wait-TCFileReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter()] [int] $TimeoutMs = 5000,
        [Parameter()] [int] $PollMs = 150
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        try {
            # Try opening read-only with sharing. If writer still has an exclusive lock, this throws.
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $fs.Dispose()
            return $true
        }
        catch {
            Start-Sleep -Milliseconds $PollMs
        }
    }

    return $false
}

function Convert-GuideDocxToMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DocxPath,
        [Parameter(Mandatory)] [string] $OutDir
    )

    if (-not (Test-Path -LiteralPath $DocxPath)) {
        Write-TCLog "  skip: path no longer exists" DarkYellow
        return
    }

    if ([IO.Path]::GetExtension($DocxPath).ToLowerInvariant() -ne '.docx') {
        Write-TCLog "  skip: not a .docx" DarkYellow
        return
    }

    if (-not (Wait-TCFileReady -Path $DocxPath -TimeoutMs 6000)) {
        Write-TCLog "  skip: file not ready (still locked?)" DarkYellow
        return
    }

    $item = Get-Item -LiteralPath $DocxPath
    $base = [IO.Path]::GetFileNameWithoutExtension($item.Name)

    $slug = ConvertTo-TCSlug -Text $base
    $outFile = Join-Path $OutDir "$slug.md"

    $tmp = [IO.Path]::GetTempFileName()

    Write-TCLog "  pandoc: converting -> $outFile" Cyan

    & pandoc $DocxPath -t gfm --wrap=none -o $tmp
    if ($LASTEXITCODE -ne 0) {
        Write-TCLog "  ERROR: pandoc exited with code $LASTEXITCODE" Red
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return
    }

    $frontMatter = New-TCFrontMatter -Title $base -Date $item.LastWriteTime -Draft $true

    $body  = Get-Content $tmp -Raw
    $final = $frontMatter + "`r`n" + ($body.TrimStart())

    Set-Content -Path $outFile -Value $final -Encoding UTF8
    Remove-Item $tmp -ErrorAction SilentlyContinue

    Write-TCLog "  OK: wrote $outFile" Green
}

function New-TCGuideWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WritingDir,
        [Parameter()] [string] $Filter = '*.docx',
        [Parameter()] [switch] $IncludeSubdirectories
    )

    $fsw = New-Object System.IO.FileSystemWatcher
    $fsw.Path = $WritingDir
    $fsw.Filter = $Filter
    $fsw.IncludeSubdirectories = [bool]$IncludeSubdirectories

    # Add a bit more signal and reduce silent failure risk
    $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size, CreationTime'

    # Word and some copy operations can generate bursts; bump buffer to reduce overflow.
    # (If overflow happens, we’ll now see it via the Error event handler.)
    try { $fsw.InternalBufferSize = 65536 } catch { }

    return $fsw
}

function Start-TCGuideWatcher {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ScriptRoot = $PSScriptRoot,
        [Parameter()] [switch] $IncludeSubdirectories
    )

    $paths = Get-TCGuidePaths -ScriptRoot $ScriptRoot

    Write-TCLog ("At start, WritingDir = {0}" -f $paths.WritingDir)
    Write-TCLog ("At start, OutDir     = {0}" -f $paths.OutDir)

    Ensure-Directory -Path $paths.WritingDir
    Ensure-Directory -Path $paths.OutDir

    # Pending queue file (event action only appends paths here)
    $script:TC_PendingPath = Join-Path $paths.OutDir '_pending-paths.txt'

    # Processor stop flag
    $script:TC_StopRequested = $false

    # Prevent zombies within the session
    Remove-TCGuideSubscriptions -SourcePrefix $script:TC_SourcePrefix

    # Dispose prior watcher if we have one
    if ($script:TC_Watcher -ne $null) {
        try { $script:TC_Watcher.EnableRaisingEvents = $false } catch { }
        try { $script:TC_Watcher.Dispose() } catch { }
        $script:TC_Watcher = $null
    }

    $script:TC_Watcher = New-TCGuideWatcher -WritingDir $paths.WritingDir -IncludeSubdirectories:$IncludeSubdirectories

    # Baked event action: append full path to pending file (no functions, no closures)
    $pendingLit = [string]$script:TC_PendingPath
    $actionText = @"
param()
try {
  `$p = `$Event.SourceEventArgs.FullPath
  if (`$p) {
    [System.IO.File]::AppendAllText('$pendingLit', `$p + "`r`n")
  }
} catch { }
"@
    $enqueueAction = [scriptblock]::Create($actionText)

    $script:TC_Subscriptions = @(
        (Register-ObjectEvent -InputObject $script:TC_Watcher -EventName Changed -SourceIdentifier "$($script:TC_SourcePrefix).Changed" -Action $enqueueAction),
        (Register-ObjectEvent -InputObject $script:TC_Watcher -EventName Created -SourceIdentifier "$($script:TC_SourcePrefix).Created" -Action $enqueueAction),
        (Register-ObjectEvent -InputObject $script:TC_Watcher -EventName Renamed -SourceIdentifier "$($script:TC_SourcePrefix).Renamed" -Action $enqueueAction)
    )

    $script:TC_Watcher.EnableRaisingEvents = $true

    Write-TCLog "Watching writing/guides -> content/guides" Cyan
    Write-TCLog ("WritingDir: {0}" -f $paths.WritingDir) Cyan
    Write-TCLog ("OutDir:     {0}" -f $paths.OutDir) Cyan
    Write-TCLog ("Pending:    {0}" -f $script:TC_PendingPath) DarkGray
    Write-TCLog "Press Ctrl+C to stop (or call Stop-TCGuideWatcher)" Yellow
}

function Stop-TCGuideWatcher {
    [CmdletBinding()]
    param()

    # Signal the main-runspace processor loop to exit
    $script:TC_StopRequested = $true

    Remove-TCGuideSubscriptions -SourcePrefix $script:TC_SourcePrefix

    if ($script:TC_Watcher -ne $null) {
        try { $script:TC_Watcher.EnableRaisingEvents = $false } catch { }
        try { $script:TC_Watcher.Dispose() } catch { }
        $script:TC_Watcher = $null
    }

    Write-TCLog "Watcher stopped." DarkYellow
}

function Run-TCGuideProcessorLoop {
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ScriptRoot = $PSScriptRoot,
        [Parameter()] [int] $PollMs = 250,
        [Parameter()] [int] $DebounceMs = 800
    )

    $paths = Get-TCGuidePaths -ScriptRoot $ScriptRoot
    $pending = $script:TC_PendingPath

    if (-not $pending) {
        throw "Pending path not initialized. Start-TCGuideWatcher must be called first."
    }

    # Debounce table in main runspace (stable)
    $lastRunByPath = @{}

    Write-TCLog "Processor loop running (main runspace)." DarkGray

    while (-not $script:TC_StopRequested) {
        try {
            if (Test-Path -LiteralPath $pending) {
                $lines = Get-Content -LiteralPath $pending -ErrorAction SilentlyContinue
                if ($lines -and $lines.Count -gt 0) {
                    # Clear the pending file quickly so new events can append
                    Set-Content -LiteralPath $pending -Value '' -Encoding UTF8

                    foreach ($fullPath in ($lines | Where-Object { $_ } | Select-Object -Unique)) {
                        $now = [DateTime]::UtcNow

                        if ($lastRunByPath.ContainsKey($fullPath)) {
                            $deltaMs = ($now - $lastRunByPath[$fullPath]).TotalMilliseconds
                            if ($deltaMs -lt $DebounceMs) {
                                continue
                            }
                        }
                        $lastRunByPath[$fullPath] = $now

                        Write-TCLog ("DETECTED: Changed  {0}" -f (Split-Path $fullPath -Leaf)) DarkCyan
                        Convert-GuideDocxToMarkdown -DocxPath $fullPath -OutDir $paths.OutDir
                    }
                }
            }
        }
        catch {
            Write-TCLog "  ERROR: processor loop exception:" Red
            Write-TCLog ("  " + $_.Exception.Message) Red
        }

        Start-Sleep -Milliseconds $PollMs
    }
}

function New-TCFrontMatter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [DateTime] $Date,
        [Parameter()] [bool] $Draft = $true
    )

    $safeTitle = $Title.Replace('"','')
    $dateText  = $Date.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $draftText = if ($Draft) { 'true' } else { 'false' }

@"
---
title: "$safeTitle"
date: $dateText
draft: $draftText
---
"@
}


# ------------------------------
# Script entry point (keeps your drop-in behavior)
# ------------------------------
Start-TCGuideWatcher
Run-TCGuideProcessorLoop