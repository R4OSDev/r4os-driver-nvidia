# Called only after PrepareBootstrap verified the complete private snapshot.
function Confirm-FwsecAbi([string]$Compiler,[string]$Source,[string]$Run,[string]$Stage){
    $relative='src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_frts_tu102.c'
    $original=Get-Content -Raw -LiteralPath (Join-Path $Source $relative)
    $license=[regex]::Match($original,'\A/\*[\s\S]*?\*/').Value
    if(!$license.Contains('SPDX-License-Identifier: MIT')){throw 'FWSEC source attribution missing'}
    $marker=$original.IndexOf('// Structures and defines for FWSEC commands',[StringComparison]::Ordinal)
    if($marker -lt 0){throw 'FWSEC command section missing'}
    $start=$original.IndexOf('typedef struct',$marker,[StringComparison]::Ordinal)
    $endMarker='} FWSECLIC_FRTS_CMD;'
    $end=$original.IndexOf($endMarker,$start,[StringComparison]::Ordinal)
    if($start -lt 0 -or $end -lt $start){throw 'FWSEC original type boundaries missing'}
    $types=$original.Substring($start,$end+$endMarker.Length-$start)
    $derived=Join-Path $Stage 'derived'
    [IO.Directory]::CreateDirectory($derived)|Out-Null
    $header=Join-Path $derived 'FwsecAbi-original.h'
    [IO.File]::WriteAllText($header,$license+"`n// Mechanically extracted without type changes from $relative`n"+'#include "nvtypes.h"'+"`n"+$types+"`n",[Text.UTF8Encoding]::new($false))
    $owner=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $suffix=if($IsWindows){'.exe'}else{''}
    $exe=Join-Path $Run ('fwsec-abi'+$suffix)
    $compilerArguments=@('build-exe','-OReleaseSafe','-lc',
        '-I',(Join-Path $Source 'src/common/sdk/nvidia/inc'),'-I',$derived,
        (Join-Path $owner 'src/fwsec_abi_check.zig'),(Join-Path $PSScriptRoot 'FwsecAbi.c'),("-femit-bin=$exe"))
    $result=Invoke-RmNative -Executable $Compiler -Arguments $compilerArguments -WorkingDirectory $Run -LogPath (Join-Path $Run 'fwsec-abi-compile.log') -TimeoutSeconds 90
    if($result -ne 0){throw 'Original FWSEC ABI comparison did not compile'}
    $result=Invoke-RmNative -Executable $exe -Arguments @() -WorkingDirectory $Run -LogPath (Join-Path $Stage 'fwsec-abi.json') -TimeoutSeconds 20
    if($result -ne 0){throw 'Zig command bytes differ from original NVIDIA C structures'}
    $abi=Get-Content -Raw (Join-Path $Stage 'fwsec-abi.json')|ConvertFrom-Json
    if(!$abi.zig_c_byte_comparison -or $abi.gpu_executed){throw 'FWSEC ABI result invalid'}
    return $abi
}
