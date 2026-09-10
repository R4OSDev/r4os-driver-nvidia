# Offline, CPU-only export of pinned original bindata. No target firmware or
# module is installed. Keep the complete verified snapshot and failed runs.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$owner=Split-Path -Parent $PSScriptRoot
$utf8=[Text.UTF8Encoding]::new($false)
$pin=Get-Content -Raw (Join-Path $PSScriptRoot 'Rm/Sources.json')|ConvertFrom-Json
$firmware=Get-Content -Raw (Join-Path $owner 'src/firmware-lock.json')|ConvertFrom-Json
if($pin.schema -ne 1 -or $firmware.schema -ne 1 -or $pin.source_commit -cne $firmware.source_commit){throw 'Source/firmware pin mismatch'}
foreach($path in @($Compiler,$SourceDirectory,$ScratchDirectory,$OutputDirectory)){
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Compiler, source, scratch and output paths must be absolute'}
}
$source=[IO.Path]::GetFullPath($SourceDirectory)
$scratch=[IO.Path]::GetFullPath($ScratchDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
function IsWithin([string]$Parent,[string]$Child){
    $relative=[IO.Path]::GetRelativePath($Parent,$Child).Replace('\','/')
    return $relative -eq '.' -or (!$relative.StartsWith('../',[StringComparison]::Ordinal) -and ![IO.Path]::IsPathRooted($relative))
}
foreach($pair in @(@($source,$scratch),@($source,$output),@($owner,$scratch),@($owner,$output),@($output,$scratch),@($scratch,$output))){
    if(IsWithin $pair[0] $pair[1]){throw 'Source, owner, scratch and output must have separate paths'}
}
if(!(Test-Path -LiteralPath $Compiler -PathType Leaf) -or !(Test-Path -LiteralPath $source -PathType Container)){throw 'Compiler or source directory is missing'}
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$run=Join-Path $scratch ('nvidia-bootstrap-'+[Guid]::NewGuid().ToString('N'))
$snapshot=Join-Path $run 'source'
$stage=Join-Path $run 'package'
[IO.Directory]::CreateDirectory($snapshot)|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $stage 'artifacts'))|Out-Null
$state=[ordered]@{schema=1;source_verified=$false;export_complete=$false;published=$false;gpu_executed=$false;module_installed=$false}
Write-Host "NVIDIA bootstrap preparation: $run"
try {
    # Compile only the private copy whose complete source catalog was hashed.
    # This closes the source-change window between checking and compilation.
    $inputs=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($scope in $pin.scope){
        $item=Get-Item -Force -LiteralPath (Join-Path $source $scope)
        $entries=@($item)
        if($item.PSIsContainer){$entries+=@(Get-ChildItem -LiteralPath $item.FullName -Force -Recurse)}
        foreach($entry in $entries){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Source symlink or junction'}
            if($entry.PSIsContainer){continue}
            $relative=[IO.Path]::GetRelativePath($source,$entry.FullName).Replace('\','/')
            if($relative.Contains([char]10) -or $relative.Contains([char]13)){throw 'Invalid source path'}
            $inputs.Add($relative,$entry)
        }
    }
    if($inputs.Count -ne $pin.files){throw 'Source file count mismatch; compiler not started'}
    [string[]]$paths=@($inputs.Keys);[Array]::Sort($paths,[StringComparer]::Ordinal)
    $catalog=[Text.StringBuilder]::new();[long]$total=0
    foreach($path in $paths){
        $target=Join-Path $snapshot $path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
        Copy-Item -LiteralPath $inputs[$path].FullName -Destination $target
        $file=Get-Item -Force -LiteralPath $target
        $sha=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant()
        $null=$catalog.Append($sha).Append(' ').Append($file.Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append(' ').Append($path).Append([char]10)
        $total+=$file.Length
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes($catalog.ToString())
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    [IO.File]::WriteAllBytes((Join-Path $run 'source-catalog.txt'),$bytes)
    if($total -ne $pin.bytes -or $digest -cne $pin.catalog_sha256){throw 'Source catalog mismatch; compiler and decoder not started'}
    $state.source_verified=$true
    . (Join-Path $PSScriptRoot 'Rm/Native.ps1')
    $suffix=if($IsWindows){'.exe'}else{''}
    $exe=Join-Path $run ('bootstrap-export'+$suffix)
    $compilerArguments=@('cc','-std=c11','-O2','-DNVGZ_USER',
        '-I',(Join-Path $snapshot 'src/common/sdk/nvidia/inc'),
        '-I',(Join-Path $snapshot 'src/common/inc'),
        '-I',(Join-Path $snapshot 'src/nvidia/arch/nvalloc/common/inc'),
        '-I',(Join-Path $snapshot 'src/nvidia/inc'),
        '-I',(Join-Path $snapshot 'src/nvidia/generated'),
        (Join-Path $PSScriptRoot 'Bootstrap/Export.c'),
        (Join-Path $snapshot 'src/nvidia/src/lib/zlib/inflate.c'),'-o',$exe)
    $code=Invoke-RmNative -Executable $Compiler -Arguments $compilerArguments -WorkingDirectory $run -LogPath (Join-Path $run 'compile.log') -TimeoutSeconds 90
    if($code -ne 0){throw 'Original bootstrap exporter did not compile'}
    $code=Invoke-RmNative -Executable $exe -Arguments @((Join-Path $stage 'artifacts')) -WorkingDirectory $run -LogPath (Join-Path $run 'original.json') -TimeoutSeconds 20
    if($code -ne 0){throw "Original bootstrap decoder failed: $code"}
    $artifacts=Get-Content -Raw (Join-Path $run 'original.json')|ConvertFrom-Json
    if($artifacts.Count -ne 26){throw 'Unexpected artifact count'}
    foreach($entry in $artifacts){
        $encoded=Join-Path $stage ('artifacts/'+$entry.name+'.encoded')
        $decoded=Join-Path $stage ('artifacts/'+$entry.name+'.bin')
        $inputBytes=[IO.File]::ReadAllBytes($encoded)
        $original=[IO.File]::ReadAllBytes($decoded)
        if($inputBytes.Length -ne $entry.encoded_bytes -or $original.Length -ne $entry.bytes){throw 'Original artifact length mismatch'}
        if($entry.compressed){
            $input=[IO.MemoryStream]::new($inputBytes,$false)
            $decoder=[IO.Compression.DeflateStream]::new($input,[IO.Compression.CompressionMode]::Decompress,$true)
            try {
                $check=[byte[]]::new($entry.bytes+1);$read=0
                while($read -lt $check.Length){$next=$decoder.Read($check,$read,$check.Length-$read);if(!$next){break};$read+=$next}
                if($read -ne $entry.bytes){throw 'Bounded raw Deflate length mismatch'}
                for($i=0;$i -lt $read;$i++){if($check[$i] -ne $original[$i]){throw 'Original/.NET decoder disagreement'}}
            }finally{$decoder.Dispose();$input.Dispose()}
        }elseif((Get-FileHash $encoded).Hash -cne (Get-FileHash $decoded).Hash){throw 'Uncompressed original mismatch'}
        $entry|Add-Member -NotePropertyName sha256 -NotePropertyValue (Get-FileHash $decoded).Hash.ToLowerInvariant()
        $entry|Add-Member -NotePropertyName encoded_sha256 -NotePropertyValue (Get-FileHash $encoded).Hash.ToLowerInvariant()
    }
    . (Join-Path $PSScriptRoot 'Bootstrap/Origins.ps1')
    $references=Add-BootstrapOrigins -Source $snapshot -Stage $stage -Artifacts $artifacts
    . (Join-Path $PSScriptRoot 'Bootstrap/FwsecAbi.ps1')
    $fwsecAbi=Confirm-FwsecAbi -Compiler $Compiler -Source $snapshot -Run $run -Stage $stage
    $report=[ordered]@{schema=1;source_commit=$pin.source_commit;rm_version=$firmware.rm_version;source_catalog_sha256=$digest;source_files=$paths.Count;source_bytes=$total;artifacts=$artifacts;references=$references;decoders=@('unchanged NVIDIA utilGz NVGZ_USER','bounded .NET DeflateStream');source_family_mapping='GA106 uses GA102 GSP-RM boot/load/unload and TU102 generic SEC2 loader';gpu_executed=$false;signature_cryptographically_verified=$false;hardware_variant_selected=$false;module_resources_added=$false}
    $report.fwsec_abi=$fwsecAbi
    [IO.File]::WriteAllText((Join-Path $stage 'bootstrap.json'),($report|ConvertTo-Json -Depth 8)+[char]10,$utf8)
    $state.export_complete=$true
    # All provenance, notices and artifacts form one deterministic package.
    # An existing different output is never repaired or overwritten in place.
    if(Test-Path -LiteralPath $output){
        $expected=@(Get-ChildItem -LiteralPath $stage -File -Force -Recurse)
        $actual=@(Get-ChildItem -LiteralPath $output -File -Force -Recurse)
        if($actual.Count -ne $expected.Count){throw 'Existing bootstrap package differs; choose a new output'}
        foreach($file in $expected){
            $other=Join-Path $output ([IO.Path]::GetRelativePath($stage,$file.FullName))
            if(!(Test-Path -LiteralPath $other -PathType Leaf) -or (Get-FileHash -LiteralPath $other).Hash -cne (Get-FileHash -LiteralPath $file.FullName).Hash){throw 'Existing bootstrap package differs; choose a new output'}
        }
        Write-Host "Bootstrap package unchanged and verified: $output"
    }else{
        [IO.Directory]::CreateDirectory((Split-Path -Parent $output))|Out-Null
        [IO.Directory]::Move($stage,$output)
        Write-Host "Bootstrap package prepared: $output"
    }
    $state.published=$true
}catch{
    $state.error=$_.Exception.Message
    throw
}finally{
    [IO.File]::WriteAllText((Join-Path $run 'run.json'),($state|ConvertTo-Json -Depth 4)+[char]10,$utf8)
}
