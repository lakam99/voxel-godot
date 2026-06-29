param(
    [Parameter(Mandatory = $true)]
    [string]$ReportPath,
    [Parameter(Mandatory = $true)]
    [string]$RunnerId,
    [ValidateSet("unit", "contract", "synthetic", "static_audit", "integration", "acceptance_visual")]
    [string]$EvidenceLevel = "unit",
    [string[]]$AcceptanceClaims = @(),
    [string[]]$RequiredScreenshots = @(),
    [string]$ScreenshotDir = "",
    [string]$RegistryPath = "",
    [switch]$RequireForbiddenCallSelfScan,
    [switch]$RequireVisualProof
)

$ErrorActionPreference = "Stop"

function Get-PropValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

function To-StringArray($Value) {
    $items = @()
    if ($null -eq $Value) {
        return $items
    }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $text = [string]$item
                foreach ($part in ($text -split ';')) {
                    if ($part -ne "") {
                        $items += $part
                    }
                }
            }
        }
        return $items
    }
    foreach ($part in (([string]$Value) -split ';')) {
        if ($part -ne "") {
            $items += $part
        }
    }
    return $items
}

function Value-Count($Value) {
    if ($null -eq $Value) {
        return 0
    }
    if ($Value -is [System.Array]) {
        return $Value.Count
    }
    return 1
}

function Set-Prop($Object, [string]$Name, $Value) {
    $Object | Add-Member -Force -NotePropertyName $Name -NotePropertyValue $Value
}

function Same-StringSet([string[]]$A, [string[]]$B) {
    $aSorted = @($A | Sort-Object)
    $bSorted = @($B | Sort-Object)
    if ($aSorted.Count -ne $bSorted.Count) {
        return $false
    }
    for ($i = 0; $i -lt $aSorted.Count; $i += 1) {
        if ($aSorted[$i] -ne $bSorted[$i]) {
            return $false
        }
    }
    return $true
}

function Write-StampedReport($Report, [string[]]$Errors) {
    $expectedClaims = @(To-StringArray $AcceptanceClaims)
    $required = @(To-StringArray $RequiredScreenshots)
    Set-Prop $Report "evidenceLevel" $EvidenceLevel
    Set-Prop $Report "acceptanceClaims" $expectedClaims
    Set-Prop $Report "testIntegrity" ([pscustomobject]@{
        registryId = $RunnerId
        registryPath = $RegistryPath
        evidenceLevel = $EvidenceLevel
        liveGameplayAcceptance = $expectedClaims.Count -gt 0
        requiredScreenshots = $required
        validationStatus = if ($Errors.Count -eq 0) { "passed" } else { "failed" }
        validationErrors = $Errors
        stampedUtc = (Get-Date).ToUniversalTime().ToString("o")
    })
    $Report | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $ReportPath
}

$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
if ($ScreenshotDir -ne "") {
    $ScreenshotDir = [System.IO.Path]::GetFullPath($ScreenshotDir)
}
if ($RegistryPath -ne "") {
    $RegistryPath = [System.IO.Path]::GetFullPath($RegistryPath)
}

if (-not (Test-Path -LiteralPath $ReportPath)) {
    Write-Error "Evidence report missing for $RunnerId`: $ReportPath"
    exit 1
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$errors = @()
$expectedClaims = @(To-StringArray $AcceptanceClaims)
$requiredScreenshots = @(To-StringArray $RequiredScreenshots)
$existingEvidenceLevel = [string](Get-PropValue $report "evidenceLevel")
$existingClaims = @(To-StringArray (Get-PropValue $report "acceptanceClaims"))

if ($existingEvidenceLevel -ne "" -and $existingEvidenceLevel -ne $EvidenceLevel) {
    $errors += "report evidenceLevel '$existingEvidenceLevel' does not match registry evidenceLevel '$EvidenceLevel'"
}

if ($existingClaims.Count -gt 0 -and -not (Same-StringSet $existingClaims $expectedClaims)) {
    $errors += "report acceptanceClaims '$($existingClaims -join ',')' do not match registry acceptanceClaims '$($expectedClaims -join ',')'"
}

if ($expectedClaims.Count -gt 0 -and $EvidenceLevel -ne "acceptance_visual") {
    $errors += "acceptanceClaims are only allowed for acceptance_visual runners"
}

if ($expectedClaims.Count -gt 0 -or $RequireForbiddenCallSelfScan) {
    $scan = Get-PropValue $report "forbiddenCallSelfScan"
    $scanStatus = [string](Get-PropValue $scan "status")
    if ($scanStatus -ne "passed") {
        $errors += "acceptance report must include forbiddenCallSelfScan.status == passed"
    }
}

if ($EvidenceLevel -eq "acceptance_visual" -or $RequireVisualProof) {
    if ($expectedClaims.Count -eq 0) {
        $errors += "acceptance_visual runner must declare at least one acceptance claim"
    }
    if ($requiredScreenshots.Count -eq 0) {
        $errors += "acceptance_visual runner must declare required screenshots"
    }
    foreach ($fileName in $requiredScreenshots) {
        $candidate = if ([System.IO.Path]::IsPathRooted($fileName)) { $fileName } else { Join-Path $ScreenshotDir $fileName }
        if ($ScreenshotDir -eq "" -and -not [System.IO.Path]::IsPathRooted($fileName)) {
            $errors += "required screenshot '$fileName' is relative but no ScreenshotDir was provided"
            continue
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            $errors += "required screenshot missing: $candidate"
        }
    }

    $captureCount = (Value-Count (Get-PropValue $report "captures")) + (Value-Count (Get-PropValue $report "visualCaptures"))
    if ($captureCount -le 0) {
        $errors += "acceptance_visual report must include captures or visualCaptures"
    }

    $timelineCount = (Value-Count (Get-PropValue $report "timeline")) +
        (Value-Count (Get-PropValue $report "timelineTail")) +
        (Value-Count (Get-PropValue $report "miraTimeline")) +
        (Value-Count (Get-PropValue $report "doorStateTimeline"))
    if ($timelineCount -le 0) {
        $errors += "acceptance_visual report must include timeline proof"
    }
}

Write-StampedReport $report $errors

if ($errors.Count -gt 0) {
    Write-Error "Evidence validation failed for $RunnerId`: $($errors -join '; ')"
    exit 1
}

[pscustomobject]@{
    runnerId = $RunnerId
    reportPath = $ReportPath
    evidenceLevel = $EvidenceLevel
    acceptanceClaims = $expectedClaims
    status = "passed"
} | ConvertTo-Json -Depth 6
