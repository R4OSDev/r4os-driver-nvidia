param(
    [Parameter(Mandatory)][string]$HeaderRoot,
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$SourceCatalogPath
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
