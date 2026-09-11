# Explicit offline provisioning of the existing production boot artifacts and
# complete source notices. Shared PowerShell 7 flow for Windows and Linux.
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$BootstrapDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [string]$OutputDirectory,
    [ValidateSet('gsp','booter')][string]$Component='gsp'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$owner=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'FirmwarePackage.ps1')
$lockPath=Join-Path $owner 'src/firmware-lock.json'
$pin=Get-Content -Raw $lockPath|ConvertFrom-Json
$sourcePin=Get-Content -Raw (Join-Path $PSScriptRoot 'Rm/Sources.json')|ConvertFrom-Json
if($pin.schema -ne 1 -or $pin.source_commit -cne $sourcePin.source_commit -or $pin.boot.notices.Count -ne 12){throw 'Boot/source pin mismatch'}
if($Component -eq 'booter' -and ($pin.booters.Count -ne 2 -or $pin.booter_license.notices.Count -ne 5)){throw 'Booter/source pin mismatch'}
$artifacts=@($pin.boot.image,$pin.boot.descriptor)
$notices=$pin.boot.notices
$licenseArtifact=$pin.boot.license
$licenseHeading="NVIDIA 570.144 GSP boot, WPR metadata, layout and initialization source notices`n`n"
$folder='BootFirmware'
if($Component -eq 'booter'){
    $artifacts=@(foreach($booter in $pin.booters){foreach($field in @('image','header','signatures','patch_location','patch_signature','patch_metadata','signature_count')){$booter.$field}})
    $notices=$pin.booter_license.notices
    $licenseArtifact=$pin.booter_license.artifact
    $licenseHeading="NVIDIA 570.144 GA102 Booter Load/Unload and source notices`n`n"
    $folder='BooterFirmware'
}
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Join-Path $owner $folder}
foreach($path in @($SourceDirectory,$BootstrapDirectory,$ScratchDirectory,$OutputDirectory)){
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Provisioning paths must be absolute'}
}
$source=[IO.Path]::GetFullPath($SourceDirectory)
$bootstrap=[IO.Path]::GetFullPath($BootstrapDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
$scratch=[IO.Path]::GetFullPath($ScratchDirectory)
function Within([string]$Parent,[string]$Child){
    $relative=[IO.Path]::GetRelativePath($Parent,$Child).Replace('\','/')
    return $relative -eq '.' -or (!$relative.StartsWith('../',[StringComparison]::Ordinal) -and ![IO.Path]::IsPathRooted($relative))
}
foreach($pair in @(@($source,$output),@($source,$scratch),@($bootstrap,$output),@($bootstrap,$scratch),@($output,$scratch),@($scratch,$output))){
    if(Within $pair[0] $pair[1]){throw 'Input, output and scratch paths must be separate'}
}
$metadata=Get-Content -Raw (Join-Path $bootstrap 'bootstrap.json')|ConvertFrom-Json
if($metadata.source_commit -cne $pin.source_commit -or $metadata.source_catalog_sha256 -cne $sourcePin.catalog_sha256){throw 'Original bootstrap export pin mismatch'}
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$stage=Join-Path $scratch ('nvidia-boot-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
try {
    foreach($artifact in $artifacts){
        $original=Join-Path $bootstrap ('artifacts/'+$artifact.file)
        Test-NvidiaFirmwareArtifact $original $artifact
        $target=Join-Path $stage $artifact.resource
        Copy-Item -LiteralPath $original -Destination $target
        Test-NvidiaFirmwareArtifact $target $artifact
    }
    $license=$licenseHeading
    foreach($notice in $notices){
        if([IO.Path]::IsPathRooted($notice.path) -or $notice.path.Contains('../') -or $notice.path.Contains('\')){throw 'Invalid notice path'}
        $sourceFile=Get-Item -Force -LiteralPath (Join-Path $source $notice.path)
        if($sourceFile.PSIsContainer -or $sourceFile.Length -ne $notice.bytes -or $notice.bytes -gt 4MB){throw 'Unexpected notice source size'}
        $bytes=[IO.File]::ReadAllBytes($sourceFile.FullName)
        if($bytes.Length -ne $notice.bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $notice.sha256){throw "Source notice hash mismatch: $($notice.path)"}
        $original=$utf8.GetString($bytes)
        if($notice.path -ceq 'COPYING'){$text=$original}else{
            $text=[regex]::Match($original,'\A/\*[\s\S]*?\*/').Value
            if(!$text.Contains('SPDX-License-Identifier: MIT')){throw 'Complete original MIT notice missing'}
        }
        $license+='Source: '+$notice.path+"`n"+$text+"`n`n"
    }
    $licensePath=Join-Path $stage $licenseArtifact.resource
    [IO.File]::WriteAllText($licensePath,$license,$utf8)
    Test-NvidiaFirmwareArtifact $licensePath $licenseArtifact
    [ordered]@{schema=1;source_commit=$pin.source_commit;rm_version=$pin.rm_version;source_catalog_sha256=$sourcePin.catalog_sha256;resources=@($artifacts)+@($licenseArtifact);notices=$notices;binary_modifications=$false;decoder_repeated=$false;gpu_executed=$false}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $stage 'package.json') -Encoding utf8NoBOM
    if(Test-Path -LiteralPath $output){
        $expected=@(Get-ChildItem -LiteralPath $stage -File)
        $actual=@(Get-ChildItem -LiteralPath $output -Force)
        if($actual.Count -ne $expected.Count){throw 'Existing boot package differs; choose a new output'}
        foreach($file in $expected){
            $target=Join-Path $output $file.Name
            if(!(Test-Path $target -PathType Leaf) -or (Get-FileHash $target).Hash -cne (Get-FileHash $file.FullName).Hash){throw 'Existing boot package differs; choose a new output'}
        }
    }else{
        [IO.Directory]::CreateDirectory((Split-Path -Parent $output))|Out-Null
        [IO.Directory]::Move($stage,$output)
    }
    Write-Host "NVIDIA $Component package: $($artifacts.Count) production artifacts and $($notices.Count) complete notices verified at $output"
}finally{
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
}
