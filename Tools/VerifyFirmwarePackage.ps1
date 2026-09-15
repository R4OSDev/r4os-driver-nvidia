param(
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$LicensePath,
    [Parameter(Mandatory)][string]$Ga10xPath,
    [Parameter(Mandatory)][string]$Tu10xPath,
    [Parameter(Mandatory)][string]$BootImagePath,
    [Parameter(Mandatory)][string]$BootDescriptorPath,
    [Parameter(Mandatory)][string]$BootLicensePath,
    [Parameter(Mandatory)][string]$BooterDirectory,
    [Parameter(Mandatory)][string]$GenerationDirectory
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
if($pin.booters.Count -ne 2 -or $pin.booter_license.notices.Count -ne 5){throw 'Unsupported Booter package schema'}
foreach($booter in $pin.booters){
    foreach($field in @('image','header','signatures','patch_location','patch_signature','patch_metadata','signature_count')){
        $artifact=$booter.$field
        Test-NvidiaFirmwareArtifact (Join-Path $BooterDirectory $artifact.resource) $artifact
    }
}
Test-NvidiaFirmwareArtifact (Join-Path $BooterDirectory $pin.booter_license.artifact.resource) $pin.booter_license.artifact
foreach($profile in $pin.boot_generations){
    if($profile.name -cnotmatch '^(ad102|tu102|tu116)$'){throw 'Unsupported boot generation'}
    $directory=Join-Path $GenerationDirectory $profile.name
    foreach($artifact in @($profile.boot.image,$profile.boot.descriptor,$profile.boot.license)){
        Test-NvidiaFirmwareArtifact (Join-Path $directory ('gsp/'+$artifact.resource)) $artifact
    }
    foreach($booter in $profile.booters){
        foreach($field in @('image','header','signatures','patch_location','patch_signature','patch_metadata','signature_count')){
            $artifact=$booter.$field
            Test-NvidiaFirmwareArtifact (Join-Path $directory ('booter/'+$artifact.resource)) $artifact
        }
    }
    Test-NvidiaFirmwareArtifact (Join-Path $directory ('booter/'+$profile.booter_license.artifact.resource)) $profile.booter_license.artifact
}
& (Join-Path $PSScriptRoot 'PrepareBootPacks.ps1') -LockPath $LockPath -GenerationDirectory $GenerationDirectory
Write-Host "NVIDIA module package: pinned $($pin.rm_version), original GSP/boot/Booter files with complete licenses verified."
