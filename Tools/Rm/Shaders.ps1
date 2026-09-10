# Build the original NVKMS shader resources from a verified source snapshot.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$XzPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Native.ps1')
$sourceRoot=[IO.Path]::GetFullPath($SourceDirectory)
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$shaderRoot=Join-Path $outputRoot 'shaders'
[IO.Directory]::CreateDirectory($shaderRoot)|Out-Null
$families=[Collections.Generic.List[string]]::new()
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($line in Get-Content -LiteralPath (Join-Path $sourceRoot 'src/nvidia-modeset/Makefile')){
    if($line -match '^\s*\$\(eval \$\(call COMPRESS_SHADERS,([a-z0-9]+)\)\)\s*$'){
        if(!$seen.Add($Matches[1])){throw 'Duplicate original shader family'}
        $families.Add($Matches[1])
    }
}
if($families.Count -ne 8){throw 'Unexpected pinned NVKMS shader list'}
$versionLog=Join-Path $shaderRoot 'xz-version.log'
$code=Invoke-RmNative -Executable $XzPath -Arguments @('--version') -WorkingDirectory $shaderRoot -LogPath $versionLog -TimeoutSeconds 10
if($code -ne 0){throw 'XZ compressor version query failed'}
$checker=Join-Path $shaderRoot $(if($IsWindows){'verify-shader.exe'}else{'verify-shader'})
$flags=@('-std=c11','-O2','-g0','-DNV_XZ_CUSTOM_MEM_HOOKS','-DNV_XZ_USE_NVTYPES','-DXZ_DEC_SINGLE','-Werror=implicit-function-declaration','-Werror=date-time')
foreach($include in @('src/common/unix/xzminidec/interface','src/common/unix/nvidia-3d/interface','src/common/unix/nvidia-3d/include','src/common/sdk/nvidia/inc')){$flags+='-I'+(Join-Path $sourceRoot $include)}
$sources=@((Join-Path $PSScriptRoot 'VerifyShader.c'))
foreach($file in @('xz_crc32.c','xz_dec_lzma2.c','xz_dec_stream.c')){$sources+=Join-Path $sourceRoot ('src/common/unix/xzminidec/src/'+$file)}
$code=Invoke-RmNative -Executable $Compiler -Arguments (@('cc')+$flags+$sources+@('-o',$checker)) -WorkingDirectory $shaderRoot -LogPath (Join-Path $shaderRoot 'verifier-build.log')
if($code -ne 0){throw 'Original NVIDIA XZ Embedded host verifier failed to build'}
$records=@()
foreach($family in $families){
    $inputPath=Join-Path $sourceRoot ('src/nvidia-modeset/src/shaders/g_'+$family+'_shaders')
    $metadata=Join-Path $sourceRoot ('src/nvidia-modeset/src/shaders/g_'+$family+'_shader_info.h')
    $sizes=[regex]::Matches([IO.File]::ReadAllText($metadata),'(?m)^static const size_t [A-Za-z0-9]+ProgramHeapSize = ([0-9]+);\s*$')
    $bytes=(Get-Item -LiteralPath $inputPath).Length
    if($sizes.Count -ne 1 -or $bytes -le 0 -or $bytes -gt 1MB -or [long]$sizes[0].Groups[1].Value -ne $bytes){throw "Original shader metadata and byte extent disagree: $family"}
    $compressed=Join-Path $shaderRoot ($family+'_shaders.xz')
    $arguments=@('--compress','--stdout','--extreme','--check=none','--threads=1')
    $code=Invoke-RmNative -Executable $XzPath -Arguments $arguments -WorkingDirectory $shaderRoot -LogPath (Join-Path $shaderRoot ($family+'-compress.log')) -InputFile $inputPath -OutputFile $compressed -TimeoutSeconds 60
    if($code -ne 0){throw "XZ compression failed: $family"}
    $code=Invoke-RmNative -Executable $checker -Arguments @($compressed,$inputPath) -WorkingDirectory $shaderRoot -LogPath (Join-Path $shaderRoot ($family+'-verify.log')) -TimeoutSeconds 10
    if($code -ne 0){throw "Original XZ_SINGLE decoder rejected shader payload: $family (exit $code)"}
    $name=$family+'_shaders_xz';$escaped=$compressed.Replace('\','/').Replace('"','\"')
    $assembly=@"
/* Pinned original NVIDIA shader data; notices remain in source/COPYING. */
.section .rodata.nvidia_shaders,"a",@progbits
.balign 16
.global _binary_${name}_start
.type _binary_${name}_start,@object
_binary_${name}_start:
.incbin "$escaped"
.global _binary_${name}_end
_binary_${name}_end:
.size _binary_${name}_start, . - _binary_${name}_start
.section .note.GNU-stack,"",@progbits
"@
    $assemblyPath=Join-Path $shaderRoot ($family+'.S');$object=Join-Path $shaderRoot ($family+'.o')
    [IO.File]::WriteAllText($assemblyPath,$assembly+"`n",[Text.UTF8Encoding]::new($false))
    $code=Invoke-RmNative -Executable $Compiler -Arguments @('cc','-target','x86_64-freestanding-none','-g0','-c',$assemblyPath,'-o',$object) -WorkingDirectory $shaderRoot -LogPath (Join-Path $shaderRoot ($family+'-embed.log'))
    if($code -ne 0){throw "Shader readonly embedding failed: $family"}
    $records+=[ordered]@{
        family=$family;original_bytes=$bytes;original_sha256=(Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant()
        metadata_sha256=(Get-FileHash -LiteralPath $metadata).Hash.ToLowerInvariant()
        xz_bytes=(Get-Item -LiteralPath $compressed).Length;xz_sha256=(Get-FileHash -LiteralPath $compressed).Hash.ToLowerInvariant()
        object=$object;object_bytes=(Get-Item -LiteralPath $object).Length;object_sha256=(Get-FileHash -LiteralPath $object).Hash.ToLowerInvariant()
        symbols=@(('_binary_'+$name+'_start'),('_binary_'+$name+'_end'))
        upstream_decoder_verified=$true;exact_metadata_extent_verified=$true;readonly_data=$true
    }
    Write-Host "NVIDIA shader $family : $bytes -> $((Get-Item -LiteralPath $compressed).Length) bytes; original decoder and metadata verified."
}
[long]$originalTotal=0;[long]$compressedTotal=0
foreach($record in $records){$originalTotal+=$record.original_bytes;$compressedTotal+=$record.xz_bytes}
$result=[ordered]@{
    schema=1;families=$records.Count;compressor=[IO.File]::ReadAllText($versionLog).Trim()
    compressor_sha256=(Get-FileHash -LiteralPath $XzPath).Hash.ToLowerInvariant()
    compression_arguments=$arguments;verifier_flags=$flags
    verifier_sha256=(Get-FileHash -LiteralPath $checker).Hash.ToLowerInvariant()
    gpu_executed=$false;original_bytes=$originalTotal
    compressed_bytes=$compressedTotal;payloads=$records
}
[IO.File]::WriteAllText((Join-Path $outputRoot 'shader-results.json'),($result|ConvertTo-Json -Depth 7)+"`n",[Text.UTF8Encoding]::new($false))
