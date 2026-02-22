Set-StrictMode -Version Latest

function NowUtc() { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Log([string]$msg) {
  Write-Host ("[{0}] {1}" -f (NowUtc), $msg)
}

function RunExe {
  param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath,

    # Mandatory, but you can still pass -1 explicitly to mean "no timeout"
    [Parameter(Mandatory=$true)]
    [int]$TimeoutSeconds,

    [Parameter(Mandatory=$true)]
    [string[]]$ArgumentList
  )

  if (-not $ArgumentList -or $ArgumentList.Count -eq 0) {
    throw "RunExe called with empty -ArgumentList for: $FilePath"
  }

  # Minimal quoting to avoid obvious breakage when args contain spaces.
  # (Still 'boring': no clever binding, just safe string construction.)
  function QuoteArg([string]$s) {
    if ($null -eq $s) { return "" }
    $t = $s.ToString()
    if ($t -match '[\s"]') {
      # Escape embedded quotes for CreateProcess-style parsing
      $t = $t -replace '"','\"'
      return '"' + $t + '"'
    }
    return $t
  }

  $argLine = (($ArgumentList | ForEach-Object { QuoteArg $_ }) -join " ")

  if ($TimeoutSeconds -gt 0) {
    Log "RunExe: $FilePath $argLine (timeout ${TimeoutSeconds}s)"
  } else {
    Log "RunExe: $FilePath $argLine"
  }

  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = $FilePath
  $pinfo.Arguments = $argLine
  $pinfo.RedirectStandardOutput = $true
  $pinfo.RedirectStandardError  = $true
  $pinfo.UseShellExecute = $false
  $pinfo.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $pinfo

  try { [void]$p.Start() }
  catch { throw "RunExe failed to start: $FilePath $argLine`n$($_.Exception.Message)" }

  $stdoutLines = New-Object System.Collections.Generic.List[string]
  $stderrLines = New-Object System.Collections.Generic.List[string]

  $stdoutTask = [System.Threading.Tasks.Task]::Run([Action]{
    try {
      while (-not $p.StandardOutput.EndOfStream) {
        $line = $p.StandardOutput.ReadLine()
        if ($null -ne $line) { $stdoutLines.Add($line) | Out-Null }
      }
    } catch {}
  })

  $stderrTask = [System.Threading.Tasks.Task]::Run([Action]{
    try {
      while (-not $p.StandardError.EndOfStream) {
        $line = $p.StandardError.ReadLine()
        if ($null -ne $line) { $stderrLines.Add($line) | Out-Null }
      }
    } catch {}
  })

  $exited =
    if ($TimeoutSeconds -gt 0) { $p.WaitForExit($TimeoutSeconds * 1000) }
    else { $p.WaitForExit(); $true }

  if (-not $exited) {
    Log "RunExe: timeout reached; terminating PID $($p.Id)..."
    try {
      try { [void]$p.CloseMainWindow() } catch {}
      Start-Sleep -Milliseconds 500
      if (-not $p.HasExited) { $p.Kill() }
    } catch {}
    try { $p.WaitForExit() } catch {}
    try { [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask), 2000) } catch {}

    $stdout = ($stdoutLines -join "`n").TrimEnd()
    $stderr = ($stderrLines -join "`n").TrimEnd()
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }

    throw "Command timed out after ${TimeoutSeconds}s: $FilePath $argLine"
  }

  try { [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask), 5000) } catch {}

  $exit = $p.ExitCode
  $stdout = ($stdoutLines -join "`n").TrimEnd()
  $stderr = ($stderrLines -join "`n").TrimEnd()

  if ($stdout) { Write-Host $stdout }
  if ($stderr) { Write-Host $stderr }

  if ($exit -ne 0) {
    #------------------debugging-----------------------
    Log ("RunExe nonzero exit. PWD: " + (Get-Location).Path)
    Log ("RunExe FilePath: " + $FilePath)
    Log ("RunExe ArgLine: " + $argLine)

    Log ("ENV DOTNET_ROOT: " + $env:DOTNET_ROOT)
    Log ("ENV DOTNET_CLI_HOME: " + $env:DOTNET_CLI_HOME)
    Log ("ENV MSBuildSDKsPath: " + $env:MSBuildSDKsPath)
    Log ("ENV NUGET_PACKAGES: " + $env:NUGET_PACKAGES)
    Log ("ENV USERPROFILE: " + $env:USERPROFILE)
    Log ("ENV PATH(head): " + (($env:PATH -split ';' | Select-Object -First 8) -join ';'))
    #--------------------------------------------------
    
    throw "Command failed ($exit): $FilePath $argLine"
  }

  return $stdout
}

function RequireCommand([string]$pathOrName) {
  $cmd = Get-Command $pathOrName -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required command not found: $pathOrName" }
  Log ("Found {0} at {1}" -f $pathOrName, $cmd.Source)
}

# ---------------- MAIN ----------------

Log "=== CLEAN REBUILD START ==="

$DotnetExe = "dotnet.exe"

$SolutionPath   = ".\src\Infra.sln"

$DoNotTimeout = -1

# Preflight Require Commands
RequireCommand $DotnetExe

# Optional rebuild
Log "Building solution..."
Log ("Calling RunExe 11")
$typeval = $DoNotTimeout.GetType().FullName
Log ("type of DonotTimeout is $typeval")
Log ("value of DonotTimout is $DoNotTimeout")
#-------------------------------- diagnostic code -------------------
Log ("PWD: " + (Get-Location).Path)
Log ("PSScriptRoot: " + $PSScriptRoot)

$dotnetCmd = Get-Command $DotnetExe -ErrorAction Stop
Log ("dotnet Source: " + $dotnetCmd.Source)
Log ("dotnet PathType: " + $dotnetCmd.CommandType)

$solutionResolved = Resolve-Path $SolutionPath -ErrorAction Stop
Log ("Solution resolved: " + $solutionResolved.Path)

# Optional: show dotnet runtime identity (fast, stable)
& $dotnetCmd.Source --info
Log ("dotnet --info exit: " + $LASTEXITCODE)
#--------------------------------------------------------------------

#-------------------- A/B Test --------------------------------------
Log "Build A: direct invocation (& dotnet build ...) starting ---------------------"
& $dotnetCmd.Source build $solutionResolved.Path -v minimal
Log ("Build A exit: " + $LASTEXITCODE)
Log ("Build A ended------------------------")

Log "Build B: via RunExe starting ****************"
#RunExe -FilePath $dotnetCmd.Source -TimeoutSeconds -1 -ArgumentList @("build", $solutionResolved.Path, "-v", "minimal")
RunExe -FilePath $dotnetCmd.Source -TimeoutSeconds -1 -ArgumentList @("build", $solutionResolved.Path)
LOG "Build B ended ****************"
#--------------------------------------------------------------------

RunExe -FilePath $DotnetExe -TimeoutSeconds -1 -ArgumentList @("build", $SolutionPath)

Log "=== CLEAN REBUILD COMPLETE ==="
