param(
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$LicensePath,
    [Parameter(Mandatory)][string]$Ga10xPath,
    [Parameter(Mandatory)][string]$Tu10xPath,
    [Parameter(Mandatory)][string]$BootImagePath,
    [Parameter(Mandatory)][string]$BootDescriptorPath,
    [Parameter(Mandatory)][string]$BootLicensePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'FirmwarePackage.ps1')
$pin=Get-Content -Raw -LiteralPath $LockPath|ConvertFrom-Json
if($pin.schema -ne 1 -or $pin.firmware.Count -ne 2){throw 'Unsupported firmware package schema.'}
Test-NvidiaFirmwareArtifact $LicensePath $pin.license
Test-NvidiaFirmwareArtifact $Ga10xPath $pin.firmware[0]
Test-NvidiaFirmwareArtifact $Tu10xPath $pin.firmware[1]
Test-NvidiaFirmwareArtifact $BootImagePath $pin.boot.image
Test-NvidiaFirmwareArtifact $BootDescriptorPath $pin.boot.descriptor
Test-NvidiaFirmwareArtifact $BootLicensePath $pin.boot.license
Write-Host "NVIDIA module package: pinned $($pin.rm_version), original GSP and boot files with complete licenses verified."
