param(
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$LicensePath,
    [Parameter(Mandatory)][string]$Ga10xPath,
    [Parameter(Mandatory)][string]$Tu10xPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'FirmwarePackage.ps1')
$pin=Get-Content -Raw -LiteralPath $LockPath|ConvertFrom-Json
if($pin.schema -ne 1 -or $pin.firmware.Count -ne 2){throw 'Unsupported firmware package schema.'}
Test-NvidiaFirmwareArtifact $LicensePath $pin.license
Test-NvidiaFirmwareArtifact $Ga10xPath $pin.firmware[0]
Test-NvidiaFirmwareArtifact $Tu10xPath $pin.firmware[1]
Write-Host "NVIDIA module package: pinned $($pin.rm_version), both original GSP files and complete license verified."
