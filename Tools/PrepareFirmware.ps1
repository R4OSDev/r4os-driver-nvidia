# Explicit host-side provisioning. Never downloads, runs an installer or edits
# a firmware binary. The same PS7 transaction is used on Windows and Linux.
param(
    [Parameter(Mandatory)][string]$Inspector,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$moduleRoot=Split-Path -Parent $PSScriptRoot
$lockPath=Join-Path $moduleRoot 'src/firmware-lock.json'
$pin=Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
if($pin.schema -ne 1){throw 'Unsupported NVIDIA firmware lock schema.'}
$source=[IO.Path]::GetFullPath($SourceDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
$scratch=[IO.Path]::GetFullPath($ScratchDirectory)
$inspectorPath=[IO.Path]::GetFullPath($Inspector)
$artifacts=@($pin.license)+@($pin.firmware)
function Test-Artifact([string]$Path,$Artifact) {
    $file=Get-Item -LiteralPath $Path
    if($file.PSIsContainer -or $file.Length -ne $Artifact.bytes -or
       (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Artifact.sha256){
        throw "Firmware package size/hash mismatch: $Path"
    }
}
foreach($artifact in $artifacts){
    foreach($name in @($artifact.file,$artifact.resource)){
        if([string]::IsNullOrEmpty($name) -or $name.Length -gt 63 -or
           $name -match '[^\x21-\x7e]|[\\/:]' -or $name -in @('.','..')){throw 'Invalid artifact name in lock.'}
    }
    Test-Artifact (Join-Path $source $artifact.file) $artifact
}
if(!(Test-Path -LiteralPath $inspectorPath -PathType Leaf)){throw 'Firmware inspector is missing.'}
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$stage=Join-Path $scratch ('nvidia-firmware-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage)|Out-Null
try {
    foreach($artifact in $artifacts){
        $target=Join-Path $stage $artifact.resource
        Copy-Item -LiteralPath (Join-Path $source $artifact.file) -Destination $target
        Test-Artifact $target $artifact
    }
    $reports=@()
    for($index=0;$index -lt $pin.firmware.Count;$index++){
        $firmware=$pin.firmware[$index]
        $family=@($pin.families|Where-Object {$_.artifact -eq $index})[0].name
        $reportName=$firmware.resource+'.json'
        & $inspectorPath (Join-Path $stage $firmware.resource) $family (Join-Path $stage $reportName)
        if($LASTEXITCODE -ne 0){throw "Firmware inspector failed: $($firmware.file)"}
        $report=Get-Content -Raw -LiteralPath (Join-Path $stage $reportName)|ConvertFrom-Json
        if(!$report.hash_verified -or $report.rm_version -cne $pin.rm_version -or
           $report.resource -cne $firmware.resource -or $report.sha256 -cne $firmware.sha256 -or
           $report.bytes -ne $firmware.bytes -or $report.native_initialization_authorized -or
           $report.hardware_verified -or $report.signature_cryptographically_verified){
            throw 'Inspector and package lock disagree.'
        }
        $reports+=,$reportName
    }
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $stage 'firmware-lock.json')
    $receipt=[ordered]@{
        schema=1; rm_version=$pin.rm_version; source_commit=$pin.source_commit
        resources=@($artifacts|ForEach-Object {$_.resource}); reports=$reports
        binary_modifications=$false; downloads=$false; native_initialization_authorized=$false
        installation='prepared-only; runtime R4D resource binding is not yet implemented'
    }
    [IO.File]::WriteAllText((Join-Path $stage 'package.json'),($receipt|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
    # Compare a complete prepared tree on rerun. Never repair an existing,
    # different package in place or leave it paired with new success reports.
    if(Test-Path -LiteralPath $output){
        $expected=@(Get-ChildItem -LiteralPath $stage -File|Sort-Object Name)
        $actual=@(Get-ChildItem -LiteralPath $output -Force)
        if($actual.Count -ne $expected.Count){throw 'Existing firmware package differs; choose a new output directory.'}
        foreach($file in $expected){
            $other=Join-Path $output $file.Name
            if(!(Test-Path -LiteralPath $other -PathType Leaf) -or
               (Get-FileHash -LiteralPath $other).Hash -cne (Get-FileHash -LiteralPath $file.FullName).Hash){
                throw "Existing firmware package differs: $other"
            }
        }
        Write-Host "NVIDIA firmware package unchanged and verified: $output"
    } else {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $output))|Out-Null
        # Directory.Move is atomic on one filesystem. A cross-volume target
        # fails before publication; put ScratchDirectory in that volume's Temp.
        [IO.Directory]::Move($stage,$output)
        Write-Host "NVIDIA firmware package prepared: $output"
    }
} finally {
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
}
