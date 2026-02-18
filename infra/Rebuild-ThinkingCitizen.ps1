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

function Run([string]$cmd) {
  Log $cmd
  & powershell -NoProfile -Command $cmd
  if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $cmd" }
}

function AwsJson([string]$args) {
  $cmd = "aws $args --profile $Profile --output json"
  Log $cmd
  $out = & aws @($args.Split(" ")) --profile $Profile --output json
  if ($LASTEXITCODE -ne 0) { throw "aws failed ($LASTEXITCODE): aws $args" }
  return ($out | ConvertFrom-Json)
}

function TryDestroyStack([string]$stackName) {
  try {
    Run "cdk destroy $stackName --profile $Profile --force"
  } catch {
    Log "Destroy of $stackName returned an error (may not exist). Continuing. Details: $($_.Exception.Message)"
  }
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
    Run "aws route53domains update-domain-nameservers --region $DomainsRegion --domain-name $domain --cli-input-json file://`"$tmp`" --profile $Profile"
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
  $expected = @($expectedNs | ForEach-Object { $_.ToLowerInvariant().TrimEnd(".") } | Sort-Object)
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)

  Log "Waiting for public DNS delegation to match hosted zone NS (timeout ${timeoutSeconds}s)"
  Log ("Expected NS: " + ($expected -join ", "))

  while ((Get-Date) -lt $deadline) {
    $allOk = $true
    foreach ($r in $Resolvers) {
      $got = @(NslookupNs $domain $r | ForEach-Object { $_.ToLowerInvariant().TrimEnd(".") } | Sort-Object)
      if ($got.Count -eq 0) {
        Log "Resolver $r: no NS answer yet"
        $allOk = $false
        continue
      }

      if (-not (@($got) -ceq @($expected))) {
        Log ("Resolver {0}: mismatch. Got: {1}" -f $r, ($got -join ", "))
        $allOk = $false
      } else {
        Log ("Resolver {0}: OK" -f $r)
      }
    }

    if ($allOk) {
      Log "Delegation verified on all resolvers."
      return
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

# ---------------- MAIN ----------------

Log "=== CLEAN REBUILD START ==="
Log "Profile: $Profile"
Log "Domain:  $DomainName"

# Preflight identity
Run "aws sts get-caller-identity --profile $Profile"

# Phase 1: destroy stacks (reverse order)
Log "Destroying stacks (reverse dependency order)..."
TryDestroyStack $SiteStack
TryDestroyStack $CertStack
TryDestroyStack $DnsStack

# Phase 2: clear local CDK state
Log "Clearing local CDK state..."
DeleteIfExists (Join-Path $PSScriptRoot "cdk.context.json")
DeleteIfExists (Join-Path $PSScriptRoot "cdk.out")

# Optional rebuild (kept simple; you can remove if you prefer)
Log "Building solution..."
Run "dotnet build"

# Phase 3: deploy DNS
Log "Deploying DNS stack..."
Run "cdk deploy $DnsStack --profile $Profile --require-approval never"

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
Run "cdk deploy $CertStack --profile $Profile --require-approval never"

WaitForCertIssued $DomainName $AcmWaitSeconds

# Phase 8: deploy site
Log "Deploying Site stack..."
Run "cdk deploy $SiteStack --profile $Profile --require-approval never"

# Phase 9: basic verify
Log "Basic verify: public NS"
foreach ($r in $Resolvers) {
  $got = NslookupNs $DomainName $r
  Log ("Resolver {0} NS: {1}" -f $r, (($got | Sort-Object) -join ", "))
}

Log "=== CLEAN REBUILD COMPLETE ==="
