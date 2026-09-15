param(
    [Parameter(Mandatory)][string]$HeaderRoot,
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$SourceCatalogPath,
    [Parameter(Mandatory)][string]$DscCatalogPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($HeaderRoot)
$origin=Get-Content -Raw -LiteralPath (Join-Path $root 'ORIGIN.json')|ConvertFrom-Json
$pin=Get-Content -Raw -LiteralPath $LockPath|ConvertFrom-Json
$catalog=Get-Content -Raw -LiteralPath $SourceCatalogPath|ConvertFrom-Json
if($origin.schema -ne 1 -or $pin.schema -ne 1 -or $catalog.schema -ne 1 -or
    $origin.source_commit -cne $pin.source_commit -or $origin.source_commit -cne $catalog.source_commit -or
    $origin.source_catalog_sha256 -cne $catalog.catalog_sha256 -or $origin.headers -ne $origin.files.Count){throw 'Native header origin and firmware source pin disagree'}
$expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$null=$expected.Add('ORIGIN.json')
$bytes=0L
foreach($entry in @($origin.files)+@($origin.copying,$origin.license)){
    $relative=[string]$entry.path
    if($relative -notmatch '^[A-Za-z0-9_./-]+$' -or $relative.StartsWith('/') -or
        @($relative.Split('/')|Where-Object {$_ -in @('','.', '..')}).Count -or !$expected.Add($relative)){throw 'Invalid native header catalog path'}
    $path=Join-Path $root $relative
    $file=Get-Item -LiteralPath $path
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw "Pinned NVIDIA header/license differs: $relative"}
    if($relative.StartsWith('src/')){$bytes+=$file.Length}
}
if($bytes -ne $origin.bytes){throw 'Native header byte count differs'}
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Force){
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Native header package contains a link'}
    if(!$file.PSIsContainer){
        $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
        if(!$expected.Remove($relative)){throw "Uncatalogued native header input: $relative"}
    }
}
if($expected.Count){throw 'Native header package is incomplete'}
Write-Host "NVIDIA native headers: $($origin.headers) original MIT headers, $bytes bytes, source pin and full licenses verified."
$dsc=Get-Content -Raw -LiteralPath $DscCatalogPath|ConvertFrom-Json
$owner=[IO.Path]::GetFullPath('..',$PSScriptRoot)
if($dsc.schema -ne 1 -or $dsc.source_commit -cne $pin.source_commit -or $dsc.unmodified -ne $true){throw 'DSC original source pin differs'}
$dscExpected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($entry in $dsc.files){
    $relative=[string]$entry.path
    if($relative -notmatch '^src/dsc/Original/[A-Za-z0-9_./-]+$' -or
        @($relative.Split('/')|Where-Object {$_ -in @('','.', '..')}).Count -or !$dscExpected.Add($relative) -or
        $entry.license -cne 'MIT'){throw 'Invalid DSC original source entry'}
    $path=Join-Path $owner $relative
    $file=Get-Item -LiteralPath $path
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $entry.bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw "Original DSC source differs: $relative"}
}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $owner 'src/dsc/Original') -Recurse -Force){
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'DSC sources contain a link'}
    if(!$file.PSIsContainer -and !$dscExpected.Remove([IO.Path]::GetRelativePath($owner,$file.FullName).Replace('\','/'))){throw 'Uncatalogued DSC original source'}
}
if($dscExpected.Count){throw 'DSC original sources incomplete'}
Write-Host "NVIDIA DSC: $($dsc.files.Count) unmodified MIT source/header files verified."
