# Watch-Guides.ps1 (drop-in for Windows PowerShell 5.1)
# Watches: site\writing\guides\*.docx
# Writes:  site\content\guides\<slug>.md
# Logs:    every event + conversion status/errors
# Prevents zombie handlers by unregistering prior TC.* subscriptions in this session.

$SiteRoot   = Split-Path $PSScriptRoot -Parent
$WritingDir = Join-Path $SiteRoot "writing\guides"
$OutDir     = Join-Path $SiteRoot "content\guides"

Write-Host ("At code start, WritingDir = $WritingDir")
Write-Host ("At code start, OutDir = $OutDir")

New-Item -ItemType Directory -Force -Path $WritingDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir     | Out-Null

# ----- Clean up prior subscriptions from this watcher (prevents zombies) -----
Get-EventSubscriber |
  Where-Object { $_.SourceIdentifier -like "TC.Guides.*" } |
  ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }

Remove-Event -SourceIdentifier "TC.Guides.*" -ErrorAction SilentlyContinue

# ----- Action (uses closure: variables captured from this scope) -----
$convertAction = {
  try {
$SiteRoot   = Split-Path $PSScriptRoot -Parent
$WritingDir = Join-Path $SiteRoot "writing\guides"
$OutDir     = Join-Path $SiteRoot "content\guides"

    $changeType = $Event.SourceEventArgs.ChangeType
    $fullPath   = $Event.SourceEventArgs.FullPath

    Write-Host ("EVENT: {0,-8} {1}" -f $changeType, $fullPath) -ForegroundColor Yellow

    Start-Sleep -Milliseconds 400

    if (-not (Test-Path $fullPath)) {
      Write-Host "  skip: path no longer exists" -ForegroundColor DarkYellow
      return
    }

    if ([IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne ".docx") {
      Write-Host "  skip: not a .docx" -ForegroundColor DarkYellow
      return
    }

    $item = Get-Item $fullPath
    $base = [IO.Path]::GetFileNameWithoutExtension($item.Name)

    # Slugify inline
    $slug = $base.ToLowerInvariant()
    $slug = $slug -replace "[^a-z0-9\s-]", ""
    $slug = $slug -replace "\s+", "-"
    $slug = $slug -replace "-{2,}", "-"
    $slug = $slug.Trim("-")

    $outFile = Join-Path $OutDir "$slug.md"

    $title = $base.Replace('"','')
    $date  = $item.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:sszzz")

    $tmp = [IO.Path]::GetTempFileName()

    Write-Host "  pandoc: converting -> $outFile" -ForegroundColor Cyan

    & pandoc $fullPath -t gfm --wrap=none -o $tmp
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  ERROR: pandoc exited with code $LASTEXITCODE" -ForegroundColor Red
      Remove-Item $tmp -ErrorAction SilentlyContinue
      return
    }

    $frontMatter = @"
---
title: "$title"
date: $date
draft: true
---
"@

    $body  = Get-Content $tmp -Raw
    $final = $frontMatter + "`r`n" + ($body.TrimStart())

    Set-Content -Path $outFile -Value $final -Encoding UTF8
    Remove-Item $tmp -ErrorAction SilentlyContinue

    Write-Host "  OK: wrote $outFile" -ForegroundColor Green
  }
  catch {
    Write-Host "  ERROR: watcher action threw exception:" -ForegroundColor Red
    Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "At line: $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host "Script: $($_.InvocationInfo.ScriptName)"
    Write-Host "Line text: $($_.InvocationInfo.Line)"
    try {
      $logPath = Join-Path $OutDir "_watcher-errors.txt"
      ("[{0}] {1}`r`n{2}`r`n" -f (Get-Date).ToString("s"), $_.Exception.Message, $_.ScriptStackTrace) |
        Out-File -FilePath $logPath -Append -Encoding UTF8
    } catch { }
  }
}.GetNewClosure()

# ----- Watcher setup -----
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $WritingDir
$fsw.Filter = "*.docx"
$fsw.IncludeSubdirectories = $false
$fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'

Register-ObjectEvent -InputObject $fsw -EventName Changed -SourceIdentifier "TC.Guides.Changed" -Action $convertAction | Out-Null
Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier "TC.Guides.Created" -Action $convertAction | Out-Null
Register-ObjectEvent -InputObject $fsw -EventName Renamed -SourceIdentifier "TC.Guides.Renamed" -Action $convertAction | Out-Null

$fsw.EnableRaisingEvents = $true

Write-Host "Watching writing/guides -> content/guides" -ForegroundColor Cyan
Write-Host ("WritingDir: " + $WritingDir) -ForegroundColor Cyan
Write-Host ("OutDir:     " + $OutDir) -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow

while ($true) { Start-Sleep -Seconds 1 }