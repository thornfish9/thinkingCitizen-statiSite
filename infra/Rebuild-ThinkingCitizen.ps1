param(
  [string]$Profile     = "citizen-deploy",
  [string]$DomainName  = "thethinkingcitizen.com",
  [string]$DnsStack    = "ThinkingCitizen-Dns",
  [string]$CertStack   = "ThinkingCitizen-Cert",
  [string]$SiteStack   = "ThinkingCitizen-Site",

  # Route53Domains is effectively us-east-1 scoped for API access
  [string]$DomainsRegion = "us-east-1",

  # Public resolvers used for delegation propagation checks
  [string[]]$Resolvers = @("1.1.1.1","8.8.8.8"),

  # Polling / timeouts
  [int]$DnsWaitSeconds = 1800,   # 30 min
  [int]$AcmWaitSeconds = 3600    # 60 min
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    throw "Command failed ($exit): $FilePath $argLine"
  }

  return $stdout
}

function AwsJson(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$awsArgs,
  [int]$timeoutSeconds = 3600
) {

  # Back-compat token handling
  $parts =
    if (-not $awsArgs -or $awsArgs.Count -eq 0) {
      @()
    }
    elseif ($awsArgs.Count -eq 1) {
      @($awsArgs[0] -split '\s+' | Where-Object { $_ -and $_.Trim().Length -gt 0 })
    }
    else {
      @($awsArgs | Where-Object { $_ -and $_.Trim().Length -gt 0 })
    }

  if ($parts.Count -eq 0) {
    throw "AwsJson called with no aws arguments (empty command)."
  }

  Log ("aws {0} --profile {1} --output json" -f ($parts -join " "), $Profile)

  # Build final argument list safely
  $finalArgs = @()
  $finalArgs += $parts
  $finalArgs += @("--profile",$Profile,"--output","json")

  Log ("Calling RunExe 1")
  $stdout = RunExe -FilePath $AwsExe -TimeoutSeconds $timeoutSeconds -ArgumentList $finalArgs

  if (-not $stdout) { return $null }

  try {
    return ($stdout | ConvertFrom-Json)
  }
  catch {
    throw @"
AwsJson failed to parse JSON.
Command: aws $($parts -join ' ')
Raw output:
$stdout
"@
  }
}

function StackExists([string]$stackName, [string]$region) {
  $res = & aws cloudformation describe-stacks --region $region --stack-name $stackName --profile $Profile --output json 2>$null
  return ($LASTEXITCODE -eq 0)
}

function DestroyStackStrict([string]$stackName, [string]$region) {
  if (-not (StackExists $stackName $region)) {
    Log "Destroy skipped: $stackName not found in $region."
    return
  }

  Log ("Calling RunExe 2")
  RunExe -FilePath $CdkExe -TimeoutSeconds 3600 -ArgumentList @("destroy", $stackName, "--profile", $Profile, "--force")
  
  Log ("Calling RunExe 3")
  RunExe -FilePath $AwsExe -TimeoutSeconds 3600 -ArgumentList @("cloudformation","wait","stack-delete-complete",
                 "--region",$region,
                 "--stack-name",$stackName,
                 "--profile",$Profile)
  Log "Deleted: $stackName ($region)"
}

function DestroyDnsStackWithZoneCleanup([string]$stackName, [string]$region, [string]$domain) {
  Log "DestroyDnsStackWithZoneCleanup starting for: $stackName in $region."

  if (-not (StackExists $stackName $region)) {
    Log "Destroy skipped: $stackName not found in $region."
    return
  }

  try {
    Log ("Calling RunExe 4")
    RunExe -FilePath $CdkExe -TimeoutSeconds 3600 -ArgumentList @("destroy", $stackName, "--profile", $Profile, "--force")
  } catch {

    # Match against the full error record text (RunExe now includes stdout/stderr in the thrown exception).
    $errText = ($_ | Out-String)

    if ($errText -match "HostedZoneNotEmptyException") {
      Log "DNS destroy failed due to HostedZoneNotEmptyException. Cleaning hosted zone records..."

      $zoneId = GetHostedZoneIdFromStack $stackName $region
      Log "Hosted zone id (from stack): $zoneId"

      Log ("TEMP DEBUG deleting non-required recordsets in zone: {0}" -f $zoneId)
      DeleteNonRequiredRecordSets $zoneId $domain

      Log "Retrying DNS stack deletion via CloudFormation delete-stack..."
      Log ("Calling RunExe 5")
      RunExe -FilePath $AwsExe -timeoutSeconds 3600 -ArgumentList @(
        "cloudformation","delete-stack",
        "--region",$region,
        "--stack-name",$stackName,
        "--profile",$Profile
      )

      Log ("Calling RunExe 6")
      RunExe -FilePath $AwsExe -timeoutSeconds 3600 -ArgumentList @(
        "cloudformation","wait","stack-delete-complete",
        "--region",$region,
        "--stack-name",$stackName,
        "--profile",$Profile
      )

      Log "Deleted: $stackName ($region)"
      return
    }

    throw
  }

  Log ("Calling RunExe 7")
  RunExe -FilePath $AwsExe -timeoutSeconds 3600 -ArgumentList @(
    "cloudformation","wait","stack-delete-complete",
    "--region",$region,
    "--stack-name",$stackName,
    "--profile",$Profile
  )
  Log "Deleted: $stackName ($region)"
}

function DeleteIfExists([string]$path) {
  if (Test-Path $path) {
    Log "Deleting $path"
    Remove-Item -Force -Recurse $path
  } else {
    Log "Not present (ok): $path"
  }
}

function GetHostedZoneId([string]$domain) {
  # Find the public hosted zone for the domain (exact match on name with trailing dot)
  $zones = AwsJson "route53 list-hosted-zones"
  $wanted = ($domain.TrimEnd(".") + ".").ToLowerInvariant()

  $zone = $zones.HostedZones | Where-Object { $_.Name.ToLowerInvariant() -eq $wanted } | Select-Object -First 1
  if (-not $zone) { throw "Hosted zone not found for $domain. Check ThinkingCitizen-Dns deploy." }

  # Id looks like /hostedzone/Z123...
  return ($zone.Id -replace "^/hostedzone/","")
}

function GetNsFromHostedZone([string]$zoneId, [string]$domain) {
  $rrs = AwsJson "route53 list-resource-record-sets --hosted-zone-id $zoneId"
  $wanted = ($domain.TrimEnd(".") + ".").ToLowerInvariant()

  $ns = $rrs.ResourceRecordSets |
    Where-Object { $_.Type -eq "NS" -and $_.Name.ToLowerInvariant() -eq $wanted } |
    Select-Object -First 1

  if (-not $ns) { throw "NS record not found in hosted zone for $domain." }

  # Return array of ns server strings without trailing dots
  return @($ns.ResourceRecords | ForEach-Object { ($_.Value.ToString().TrimEnd(".")) })
}

function UpdateRegistrarNameservers([string]$domain, [string[]]$nsServers) {
  # Route53Domains expects list of objects: [{Name:"ns-..."}, ...]
  $payload = @{ Nameservers = @() }
  foreach ($ns in $nsServers) { $payload.Nameservers += @{ Name = $ns } }

  $tmp = Join-Path $env:TEMP ("r53domains-ns-" + [Guid]::NewGuid().ToString("N") + ".json")
  ($payload | ConvertTo-Json -Depth 5) | Out-File -Encoding utf8 $tmp

  try {
    Log ("Calling RunExe 8")
    RunExe -FileList $AwsExe -timeoutSeconds 3600 -ArgumentList @(
      "route53domains","update-domain-nameservers",
      "--region",$DomainsRegion,
      "--domain-name",$domain,
      "--cli-input-json","file://$tmp",
      "--profile",$Profile
    )
  } finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  }
}

function NslookupNs([string]$domain, [string]$resolver) {
  $out = & nslookup -type=ns $domain $resolver 2>$null
  if ($LASTEXITCODE -ne 0) { return @() }

  # Parse "nameserver = xxx"
  $servers = @()
  foreach ($line in $out) {
    if ($line -match "nameserver\s*=\s*(\S+)") {
      $servers += $Matches[1].Trim().TrimEnd(".")
    }
  }
  return $servers
}

function WaitForDelegation([string]$domain, [string[]]$expectedNs, [int]$timeoutSeconds) {
  $expected = @(
    $expectedNs |
      ForEach-Object { $_.ToString().ToLowerInvariant().Trim() } |
      ForEach-Object { $_.TrimEnd(".") } |
      Sort-Object
  )
  $expectedKey = ($expected -join "|")

  $deadline = (Get-Date).AddSeconds($timeoutSeconds)

  Log "Waiting for public DNS delegation to match hosted zone NS (timeout ${timeoutSeconds}s)"
  Log ("Expected NS: " + ($expected -join ", "))

  while ((Get-Date) -lt $deadline) {

    # 1) Authoritative: registrar must match expected
    $registrarOk = $false
    try {
      $reg = GetRegistrarNameservers $domain
      $regKey = ($reg -join "|")
      if ($regKey -eq $expectedKey) {
        $registrarOk = $true
        Log ("Registrar NS: OK ({0})" -f ($reg -join ", "))
      } else {
        Log ("Registrar NS: mismatch. Got: {0}" -f ($reg -join ", "))
      }
    } catch {
      Log ("Registrar NS lookup failed (will retry): " + (($_ | Out-String).Trim()))
    }

    if (-not $registrarOk) {
      Start-Sleep -Seconds 15
      continue
    }

    # 2) Public resolvers: proceed as soon as any resolver matches once
    foreach ($r in $Resolvers) {
      $got = @(
        NslookupNs $domain $r |
          ForEach-Object { $_.ToString().ToLowerInvariant().Trim() } |
          ForEach-Object { $_.TrimEnd(".") } |
          Sort-Object
      )

      if ($got.Count -eq 0) {
        Log "Resolver $($r): no NS answer yet"
        continue
      }

      $gotKey = ($got -join "|")
      if ($gotKey -eq $expectedKey) {
        Log ("Resolver {0}: OK (delegation visible)" -f $r)
        Log "Delegation verified (registrar OK + at least one public resolver OK)."
        return
      } else {
        Log ("Resolver {0}: mismatch. Got: {1}" -f $r, ($got -join ", "))
      }
    }

    Start-Sleep -Seconds 15
  }

  throw "Timed out waiting for DNS delegation to match on public resolvers."
}

function GetCertArnForDomain([string]$domain) {
  $list = AwsJson "acm list-certificates --region $DomainsRegion"
  # ACM list is regional; cert is in us-east-1 (DomainsRegion). Filter by exact domain or wildcard as needed.
  $wanted = $domain.ToLowerInvariant()
  $cand = $list.CertificateSummaryList |
    Where-Object { $_.DomainName -and $_.DomainName.ToLowerInvariant() -eq $wanted } |
    Select-Object -First 1

  if (-not $cand) { return $null }
  return $cand.CertificateArn
}

function GetCertStatus([string]$arn) {
  $desc = AwsJson "acm describe-certificate --region $DomainsRegion --certificate-arn $arn"
  return $desc.Certificate.Status
}

function WaitForCertIssued([string]$domain, [int]$timeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  Log "Waiting for ACM cert to be ISSUED for $domain (timeout ${timeoutSeconds}s)"

  while ((Get-Date) -lt $deadline) {
    $arn = GetCertArnForDomain $domain
    if (-not $arn) {
      Log "ACM: cert not listed yet. Sleeping..."
      Start-Sleep -Seconds 10
      continue
    }

    $status = GetCertStatus $arn
    Log "ACM: $status ($arn)"

    if ($status -eq "ISSUED") { return }
    if ($status -eq "FAILED" -or $status -eq "REVOKED") {
      throw "Certificate entered terminal failure state: $status"
    }

    Start-Sleep -Seconds 15
  }

  throw "Timed out waiting for ACM cert to be ISSUED."
}

function RequireCommand([string]$pathOrName) {
  $cmd = Get-Command $pathOrName -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required command not found: $pathOrName" }
  Log ("Found {0} at {1}" -f $pathOrName, $cmd.Source)
}

function ListRecordSets([string]$zoneId) {
  $rrs = AwsJson "route53 list-resource-record-sets --hosted-zone-id $zoneId"
  return @($rrs.ResourceRecordSets)
}
function DeleteNonRequiredRecordSets([string]$zoneId, [string]$domain) {
  Log "Entering DeleteNonRequiredRecordSets for zoneId: $zoneId, and domain: $domain"
  $wanted = ($domain.TrimEnd(".") + ".").ToLowerInvariant()
  $sets = ListRecordSets $zoneId

  $toDelete = @()

  foreach ($s in $sets) {
    $name = $s.Name.ToLowerInvariant()
    $type = $s.Type

    Log "Examining set with name: $name and type: $type"
    # Keep only apex NS + SOA
    $isApex = ($name -eq $wanted)
    $isRequired = $isApex -and ($type -eq "NS" -or $type -eq "SOA")

    if (-not $isRequired) {
      $toDelete += @{
        Action = "DELETE"
        ResourceRecordSet = $s
      }
    }
  }

  if ($toDelete.Count -eq 0) {
    Log "Hosted zone already contains only required records (NS/SOA)."
    return
  }

  Log ("Deleting {0} record sets from hosted zone {1}..." -f $toDelete.Count, $zoneId)

  $payload = @{ Changes = $toDelete }
  $tmp = Join-Path $env:TEMP ("r53-delete-" + [Guid]::NewGuid().ToString("N") + ".json")
  ($payload | ConvertTo-Json -Depth 20) | Out-File -Encoding utf8 $tmp

  try {
    Log ("Calling RunExe 9")
    RunExe -FileList $AwsExe -timeoutSeconds 3600 -ArgumentList @(
      "route53","change-resource-record-sets",
      "--hosted-zone-id",$zoneId,
      "--change-batch","file://$tmp",
      "--profile",$Profile
    )
  } finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  }
}

function GetHostedZoneIdFromStack([string]$stackName, [string]$region) {
  $res = AwsJson cloudformation list-stack-resources --region $region --stack-name $stackName
  $hz = $res.StackResourceSummaries | Where-Object { $_.ResourceType -eq "AWS::Route53::HostedZone" } | Select-Object -First 1
  if (-not $hz -or -not $hz.PhysicalResourceId) {
    throw "HostedZone physical id not found in stack resources for $stackName ($region)."
  }
  return $hz.PhysicalResourceId
}

function GetRegistrarNameservers([string]$domain) {
  $d = AwsJson route53domains get-domain-detail --region $DomainsRegion --domain-name $domain
  return @($d.Nameservers | ForEach-Object { $_.Name.ToString().ToLowerInvariant().Trim().TrimEnd(".") } | Sort-Object)
}


# ---------------- MAIN ----------------

Log "=== CLEAN REBUILD START ==="
Log "Profile: $Profile"
Log "Domain:  $DomainName"

$CdkExe    = "$env:APPDATA\npm\cdk.cmd"
$AwsExe    = "aws.exe"
$DotnetExe = "dotnet.exe"

$DnsStackRegion = "us-west-2"
$CertStackRegion = "us-east-1"
$SiteStackRegion = "us-west-2"
$SolutionPath   = ".\src\Infra.sln"

$DoNotTimeout = -1

# Preflight Require Commands
RequireCommand $CdkExe
RequireCommand $AwsExe
RequireCommand $DotnetExe

# Preflight identity
Log "Getting caller identity..."
Log ("Calling RunExe 10")
RunExe -FilePath $AwsExe -TimeoutSeconds 3600 -ArgumentList @("sts", "get-caller-identity", "--profile", $Profile)

# Optional rebuild
Log "Building solution..."
Log ("Calling RunExe 11")
$typeval = $DoNotTimeout.GetType().FullName
Log ("type of DonotTimeout is $typeval")
Log ("value of DonotTimout is $DoNotTimeout")
RunExe -FilePath $DotnetExe -TimeoutSeconds -1 -ArgumentList @("build", $SolutionPath)

# Phase 1: destroy stacks (reverse order)
Log "Destroying stacks (reverse dependency order)..."
DestroyStackStrict $SiteStack $SiteStackRegion
DestroyStackStrict $CertStack $CertStackRegion
DestroyDnsStackWithZoneCleanup  $DnsStack  $DnsStackRegion $DomainName

# Phase 2: clear local CDK state
Log "Clearing local CDK state..."
DeleteIfExists (Join-Path $PSScriptRoot "cdk.context.json")
DeleteIfExists (Join-Path $PSScriptRoot "cdk.out")

# Phase 3: deploy DNS
Log "Deploying DNS stack..."
Log ("Calling RunExe 12")
RunExe -FilePath $CdkExe -timeoutSeconds 3600 -ArgumentList @("deploy", $DnsStack, "--profile", $Profile, "--require-approval", "never")

# Phase 4: read hosted zone + NS
$zoneId = GetHostedZoneId $DomainName
Log "Hosted zone id: $zoneId"

$ns = GetNsFromHostedZone $zoneId $DomainName
Log ("Hosted zone NS: " + ($ns -join ", "))

# Phase 5: update registrar delegation (Route53Domains)
Log "Updating registrar nameservers to match hosted zone..."
UpdateRegistrarNameservers $DomainName $ns

# Phase 6: wait for public delegation
WaitForDelegation $DomainName $ns $DnsWaitSeconds

# Phase 7: deploy cert + wait issued
Log "Deploying Cert stack..."
Log ("Calling RunExe 13")
RunExe -FilePath $CdkExe -timeoutSeconds 3600 -ArgumentList @("deploy", $CertStack, "--profile", $Profile, "--require-approval", "never")

WaitForCertIssued $DomainName $AcmWaitSeconds

# Phase 8: deploy site
Log "Deploying Site stack..."
Log ("Calling RunExe 14")
RunExe -FilePath $CdkExe -timeoutSeconds 3600 -ArgumentList @("deploy", $SiteStack, "--profile", $Profile, "--require-approval", "never")

# Phase 9: basic verify
Log "Basic verify: public NS"
foreach ($r in $Resolvers) {
  $got = NslookupNs $DomainName $r
  Log ("Resolver {0} NS: {1}" -f $r, (($got | Sort-Object) -join ", "))
}

Log "=== CLEAN REBUILD COMPLETE ==="
