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

  $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
  $pinfo.FileName = $FilePath
  $pinfo.Arguments = $argLine
  $pinfo.RedirectStandardOutput = $true
  $pinfo.RedirectStandardError  = $true
  $pinfo.UseShellExecute = $false
  $pinfo.CreateNoWindow = $true
  $pinfo.WorkingDirectory = (Get-Location).Path

  $p = [System.Diagnostics.Process]::new()  
  $p.StartInfo = $pinfo

  try { [void]$p.Start() }
  catch { throw "RunExe failed to start: $FilePath $argLine`n$($_.Exception.Message)" }

  # Read streams asynchronously (avoids ReadLine() deadlocks and avoids PS runspace/event-handler crashes)
  $stdoutTask = $p.StandardOutput.ReadToEndAsync()
  $stderrTask = $p.StandardError.ReadToEndAsync()

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

    $stdout = ""
    $stderr = ""
    try { if ($stdoutTask.Status -eq 'RanToCompletion') { $stdout = $stdoutTask.Result } } catch {}
    try { if ($stderrTask.Status -eq 'RanToCompletion') { $stderr = $stderrTask.Result } } catch {}

    $stdout = ($stdout ?? "").TrimEnd()
    $stderr = ($stderr ?? "").TrimEnd()
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }

    throw "Command timed out after ${TimeoutSeconds}s: $FilePath $argLine"
  }

  # Ensure async reads flush after process exit
  try { $p.WaitForExit() } catch {}
  try { [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask), 5000) } catch {}

  $exit = $p.ExitCode

  $stdout = ""
  $stderr = ""
  try { if ($stdoutTask.Status -eq 'RanToCompletion') { $stdout = $stdoutTask.Result } } catch {}
  try { if ($stderrTask.Status -eq 'RanToCompletion') { $stderr = $stderrTask.Result } } catch {}

  $stdout = ($stdout ?? "").TrimEnd()
  $stderr = ($stderr ?? "").TrimEnd()

  if ($stdout) { Write-Host $stdout }
  if ($stderr) { Write-Host $stderr }

  if ($exit -ne 0) {
    #throw "Command failed ($exit): $FilePath $argLine"
    #------------- Begin Expanded throw ---------------
    # Include captured output so callers can pattern-match on it
    $msg = "Command failed ($exit): $FilePath $argLine"

    if ($stderr) {
      $msg += "`n--- STDERR ---`n$stderr"
    }

    if ($stdout) {
      $msg += "`n--- STDOUT ---`n$stdout"
    }

    throw $msg
  }
    #------------- End Expanded throw   ---------------

  return $stdout
}

function SanitizeToJson {
  param(
    [Parameter(Mandatory=$true)] [string]$Text
  )

  if ($null -eq $Text) { return $null }

  $s = $Text.TrimStart()
  if ($s.Length -eq 0) { return $s }

  # Find first JSON object/array start
  $idxObj = $s.IndexOf('{')
  $idxArr = $s.IndexOf('[')

  $idx =
    if ($idxObj -ge 0 -and $idxArr -ge 0) { [Math]::Min($idxObj, $idxArr) }
    elseif ($idxObj -ge 0) { $idxObj }
    elseif ($idxArr -ge 0) { $idxArr }
    else { -1 }

  if ($idx -lt 0) { return $s }

  if ($idx -gt 0) { $s = $s.Substring($idx) }

  return $s.Trim()
}

function EnsureScalarString {
  param(
    [Parameter(Mandatory=$true)]
    $Value,

    [Parameter(Mandatory=$true)]
    [string]$Context
  )

  if ($null -eq $Value) { return $null }

  if ($Value -is [System.Array]) {
    Log ("WARNING: {0}: expected scalar string but got array ({1} items). Using last element. Likely pipeline output contamination (e.g., Log writing to success pipeline)." -f $Context, $Value.Count)
    if ($Value.Count -eq 0) { return $null }
    return [string]$Value[-1]
  }

  return [string]$Value
}

function AwsJson(
  [Parameter(Mandatory=$true)] [int]$timeoutSeconds,
  [Parameter(Mandatory=$true)] [string[]]$awsArgs) {
  
  # Contract: awsArgs must be explicit tokens (string[]), no alternate calling conventions.
  if (-not $awsArgs -or $awsArgs.Count -eq 0) {
    throw "AwsJson called with no aws arguments (empty command)."
  }

  # If someone passes a single 'aws ...' string, reject it explicitly.
  if ($awsArgs.Count -eq 1 -and ($awsArgs[0] -match '\s')) {
    throw "AwsJson contract violation: awsArgs must be explicit tokens (string[]). Do not pass a single space-delimited command string."
  }

  $parts = @($awsArgs | Where-Object { $_ -and $_.Trim().Length -gt 0 })

  if ($parts.Count -eq 0) {
    throw "AwsJson called with no aws arguments after trimming."
  }
  Log ("aws {0} --profile {1} --output json" -f ($parts -join " "), $Profile)

  # Build final argument list safely (tokenized)
  $finalArgs = @()
  $finalArgs += $parts
  $finalArgs += @("--profile",$Profile,"--output","json")

  Log ("Calling RunExe 1")
  $stdoutRaw = RunExe -FilePath $AwsExe -TimeoutSeconds $timeoutSeconds -ArgumentList $finalArgs
  $stdout = EnsureScalarString -Value $stdoutRaw -Context "AwsJson/RunExe stdout"
  if (-not $stdout) { return $null }

  $jsonText = SanitizeToJson $stdout

  try {
    return ($jsonText | ConvertFrom-Json)
  }
  catch {
    throw @"
AwsJson failed to parse JSON.
Command: aws $($parts -join ' ')
Raw output:
$stdout

Sanitized output:
$jsonText
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
    #$errText = ($_ | Out-String)

    #------- Start diagnostic code to diagnose match failure
    $e = $_

    # Show exactly what we are about to regex-test
    $errText = ($e | Out-String -Width 4000)

    Log "---- BEGIN catch diagnostic ----"
    Log ("ErrorRecord.Type: {0}" -f ($e.GetType().FullName))
    Log ("Exception.Type:  {0}" -f ($e.Exception.GetType().FullName))
    Log ("Exception.Message: {0}" -f ($e.Exception.Message))

    # Full exception text (includes stack + inner exception text when present)
    Log "Exception.ToString():"
    Log ($e.Exception.ToString())

    # Full ErrorRecord text (what your match currently uses)
    Log "ErrorRecord (Out-String):"
    Log $errText

    $match = ($errText -match "HostedZoneNotEmptyException")
    Log ("Regex match HostedZoneNotEmptyException? {0}" -f $match)
    Log "---- END catch diagnostic ----"
    # ------ End diagnotic code to diagnose match faiure

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

function GetHostedZoneId([string]$domain) {
  # Find the public hosted zone for the domain (exact match on name with trailing dot)
  #$zones = AwsJson "route53 list-hosted-zones"
  try {
    $zones = AwsJson -TimeoutSeconds 3600 -awsArgs @(
      "route53",
      "list-hosted-zones"
    )
  }
  catch {
    Write-Host "ERROR calling AwsJson" -ForegroundColor Red

    $err = $_

    Write-Host "---- Message ----"
    Write-Host $err.Exception.Message

    Write-Host "---- ScriptStackTrace ----"
    Write-Host $err.ScriptStackTrace

    Write-Host "---- InvocationInfo ----"
    $err.InvocationInfo | Format-List * | Out-String | Write-Host

    throw  # rethrow so your script still fails
  }

  $wanted = ($domain.TrimEnd(".") + ".").ToLowerInvariant()

  $zone = $zones.HostedZones | Where-Object { $_.Name.ToLowerInvariant() -eq $wanted } | Select-Object -First 1
  if (-not $zone) { throw "Hosted zone not found for $domain. Check ThinkingCitizen-Dns deploy." }

  # Id looks like /hostedzone/Z123...
  return ($zone.Id -replace "^/hostedzone/","")
}

function GetNsFromHostedZone([string]$zoneId, [string]$domain) {
  #$rrs = AwsJson "route53 list-resource-record-sets --hosted-zone-id $zoneId"
  $rrs = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "route53",
    "list-resource-record-sets",
    "--hosted-zone-id", $zoneId
  )
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
    RunExe -FilePath $AwsExe -timeoutSeconds 3600 -ArgumentList @(
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
  #$list = AwsJson "acm list-certificates --region $DomainsRegion"
  $list = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "acm", 
    "list-certificates",
    "--region", $DomainsRegion
  )

  # ACM list is regional; cert is in us-east-1 (DomainsRegion). Filter by exact domain or wildcard as needed.
  $wanted = $domain.ToLowerInvariant()
  $cand = $list.CertificateSummaryList |
    Where-Object { $_.DomainName -and $_.DomainName.ToLowerInvariant() -eq $wanted } |
    Select-Object -First 1

  if (-not $cand) { return $null }
  return $cand.CertificateArn
}

function GetCertStatus([string]$arn) {
  #$desc = AwsJson "acm describe-certificate --region $DomainsRegion --certificate-arn $arn"
  $desc = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "acm", "describe-certificate",
    "--certificate-arn", $arn,
    "--region", $DomainsRegion
  )

  return $desc.Certificate.Status
}

# We expect to drop this function in favor of GetLatestCertArnFromCertStackOutput below
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

function GetLatestCertArnFromCertStackOutput {
  param(
    [Parameter(Mandatory=$true)]
    [string]$CertStackName,

    # Optional: if you pass this, we’ll sanity-check the cert covers the domain.
    [Parameter(Mandatory=$false)]
    [string]$DomainName = $null
  )

  $certRegion = "us-east-1"
  $outputKey  = "CertificateArn"

  Log "Retrieving latest certArn from CloudFormation outputs: stack=$CertStackName region=$certRegion key=$outputKey"

  $stackJson = AwsJson -TimeoutSeconds 60 -awsArgs @(
    "cloudformation", "describe-stacks",
    "--region", $certRegion,
    "--stack-name", $CertStackName
  )

  if (-not $stackJson -or -not $stackJson.Stacks -or $stackJson.Stacks.Count -lt 1) {
    throw "describe-stacks returned no stacks for $CertStackName in $certRegion"
  }

  $outputs = $stackJson.Stacks[0].Outputs
  if (-not $outputs) {
    throw "Stack $CertStackName in $certRegion has no Outputs (expected $outputKey)."
  }

  $certArn = $outputs |
    Where-Object { $_.OutputKey -eq $outputKey } |
    Select-Object -ExpandProperty OutputValue

  if (-not $certArn) {
    throw "Could not find OutputKey '$outputKey' in stack $CertStackName outputs (region $certRegion)."
  }

  # Optional sanity checks against ACM (same region)
  $certDesc = AwsJson -TimeoutSeconds 60 -awsArgs @(
    "acm", "describe-certificate",
    "--region", $certRegion,
    "--certificate-arn", $certArn
  )

  $status = $certDesc.Certificate.Status
  Log "ACM cert status: $status ($certArn)"

  if ($status -eq "FAILED" -or $status -eq "REVOKED") {
    throw "Certificate is in terminal failure state: $status ($certArn)"
  }

  if ($DomainName) {
    $domainOk =
      ($certDesc.Certificate.DomainName -eq $DomainName) -or
      ($certDesc.Certificate.SubjectAlternativeNames -contains $DomainName)

    if (-not $domainOk) {
      throw "Certificate from stack output does not appear to cover domain '$DomainName' (certArn=$certArn)."
    }
  }

  Log "certArn retrieved from stack output: $certArn"
  return $certArn
}

function RequireCommand([string]$pathOrName) {
  $cmd = Get-Command $pathOrName -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required command not found: $pathOrName" }
  Log ("Found {0} at {1}" -f $pathOrName, $cmd.Source)
}

function ListRecordSets([string]$zoneId) {
  #$rrs = AwsJson "route53 list-resource-record-sets --hosted-zone-id $zoneId"
  $rrs = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "route53",
    "list-resource-record-sets",
    "--hosted-zone-id", $zoneId
  )

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
    RunExe -FilePath $AwsExe -timeoutSeconds 3600 -ArgumentList @(
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
  #$res = AwsJson cloudformation list-stack-resources --region $region --stack-name $stackName
  $res = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "cloudformation", "list-stack-resources",
    "--region", $region,
    "--stack-name", $stackName
  )

  $hz = $res.StackResourceSummaries | Where-Object { $_.ResourceType -eq "AWS::Route53::HostedZone" } | Select-Object -First 1
  if (-not $hz -or -not $hz.PhysicalResourceId) {
    throw "HostedZone physical id not found in stack resources for $stackName ($region)."
  }
  return $hz.PhysicalResourceId
}

function GetRegistrarNameservers([string]$domain) {
  #$d = AwsJson route53domains get-domain-detail --region $DomainsRegion --domain-name $domain
  $d = AwsJson -TimeoutSeconds 3600 -awsArgs @(
    "route53domains",
    "get-domain-detail",
    "--region", $DomainsRegion,
    "--domain-name", $domain
  )

  return @($d.Nameservers | ForEach-Object { $_.Name.ToString().ToLowerInvariant().Trim().TrimEnd(".") } | Sort-Object)
}

function DeleteIfExists([string]$path) {
  if (Test-Path $path) {
    Log "Deleting $path"
    Remove-Item -Force -Recurse $path
  } else {
    Log "Not present (ok): $path"
  }
}

function Get-CertArnFromCertStack {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CertStackName
    )

    Log "Retrieving certArn from CertStack outputs (us-east-1)..."

    $certStackJson = AwsJson -TimeoutSeconds 60 -awsArgs @(
        "cloudformation", "describe-stacks",
        "--region", "us-east-1",
        "--stack-name", $CertStackName
    )

    $certArn = $certStackJson.Stacks[0].Outputs |
        Where-Object { $_.OutputKey -eq "CertificateArn" } |
        Select-Object -ExpandProperty OutputValue

    if (-not $certArn) {
        throw "Could not find CertificateArn output in stack $CertStackName (us-east-1)"
    }

    Log "certArn retrieved: $certArn"
    return $certArn
}

# ---------------- MAIN ----------------

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

# Rebuild CDK app
Log "Building solution..."
RunExe $DotnetExe @( "build", $SolutionPath) -timeoutSeconds $DoNotTimeout

#Phas 0: get certArn
#temporarily commented out because staccks manually deleted in aws console
#$certArn = Get-CertArnFromCertStack -CertStackName $CertStack

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

# we expect to drop this. Trying out the replacement immediately  below
#WaitForCertIssued $DomainName $AcmWaitSeconds

Log "Awaiting Cert stack..."
$certArn = GetLatestCertArnFromCertStackOutput -CertStackName $CertStack -DomainName $DomainName
Log "Cert stack completed. certArn = $certArn"

# Phase 8: deploy site
Log "Deploying Site stack..."
Log ("Calling RunExe 14")
# this is the old line before passing the certArn in a -c in the context
#RunExe -FilePath $CdkExe -timeoutSeconds 3600 -ArgumentList @("deploy", $SiteStack, "--profile", $Profile, "--require-approval", "never")
RunExe -FilePath $CdkExe -TimeoutSeconds 3600 -ArgumentList @("deploy", $SiteStack, "--profile", $Profile, "--require-approval", "never", "-c", "certArn=$certArn")

# Phase 9: basic verify
Log "Basic verify: public NS"
foreach ($r in $Resolvers) {
  $got = NslookupNs $DomainName $r
  Log ("Resolver {0} NS: {1}" -f $r, (($got | Sort-Object) -join ", "))
}

Log "=== CLEAN REBUILD COMPLETE ==="
