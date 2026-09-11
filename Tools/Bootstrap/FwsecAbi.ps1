# Called only after PrepareBootstrap verified the complete private snapshot.
function New-GspMessageAbiObject([string]$Compiler,[string]$Source,[string]$Run,[string]$Derived){
    $owner=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $pin=Get-Content -Raw -LiteralPath (Join-Path $owner 'src/firmware-lock.json')|ConvertFrom-Json
    $original=[IO.File]::ReadAllText((Join-Path $Source 'src/common/inc/nvUnixVersion.h'))
    $needle='#if defined(NV_LINUX) || defined(NV_BSD)'
    if(([regex]::Matches($original,[regex]::Escape($needle))).Count -ne 1){throw 'Unexpected upstream version guard'}
    # Same version-only platform adaptation as the original RM build. Preserve
    # its complete notice; no shadow vendor types or host OS emulation headers.
    [IO.File]::WriteAllText((Join-Path $Derived 'nvUnixVersion.h'),$original.Replace($needle,'#if defined(NV_R4OS) || defined(NV_LINUX) || defined(NV_BSD)'),[Text.UTF8Encoding]::new($false))
    $flags=@('-std=gnu11','-O2','-g0','-fno-strict-aliasing','-Werror=implicit-function-declaration',
        '-DNV_UNIX','-DNV_R4OS','-DNV_X86_64','-DNV_ARCH_BITS=64',('-DNV_VERSION_STRING="'+$pin.rm_version+'"'),('-I'+$Derived))
    $unitRoot=Join-Path $Source 'src/nvidia'
    foreach($line in Get-Content -LiteralPath (Join-Path $unitRoot 'Makefile')){
        if($line -match '^\s*CFLAGS \+= -I (.+)$'){
            $relative=$Matches[1].Replace('$(SRC_COMMON)','../common').Trim()
            if($relative.Contains('$')){throw 'Unresolved original GSP ABI include'}
            $flags+='-I'+[IO.Path]::GetFullPath((Join-Path $unitRoot $relative))
        }
        if($line -match '^\s*CFLAGS \+= (-D[^ ]+)$'){
            $define=$Matches[1].Replace('\"','"')
            if($define.Contains('$')){throw 'Unresolved original GSP ABI define'}
            $flags+=$define
        }
    }
    $object=Join-Path $Run 'gsp-message-abi.o'
    $arguments=@('cc')+$flags+@('-MMD','-MF',(Join-Path $Run 'gsp-message-abi.d'),'-c',(Join-Path $PSScriptRoot 'GspMessageAbi.c'),'-o',$object)
    $result=Invoke-RmNative -Executable $Compiler -Arguments $arguments -WorkingDirectory $Run -LogPath (Join-Path $Run 'gsp-message-abi-compile.log') -TimeoutSeconds 90
    if($result -ne 0){throw 'Complete original GSP message ABI headers did not compile'}
    return $object
}

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
    # Preserve the complete original WPR type header, including its MIT notice.
    Copy-Item -LiteralPath (Join-Path $Source 'src/nvidia/arch/nvalloc/common/inc/gsp/gsp_fw_wpr_meta.h') -Destination (Join-Path $derived 'gsp_fw_wpr_meta.h')
    foreach($relative in @('src/common/uproc/os/common/include/libos_init_args.h','src/nvidia/inc/kernel/gpu/gsp/gsp_init_args.h')){
        Copy-Item -LiteralPath (Join-Path $Source $relative) -Destination (Join-Path $derived ([IO.Path]::GetFileName($relative)))
    }
    $msgq=Join-Path $Source 'src/common/shared/msgq'
    $owner=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $suffix=if($IsWindows){'.exe'}else{''}
    $exe=Join-Path $Run ('fwsec-abi'+$suffix)
    $messageObject=New-GspMessageAbiObject -Compiler $Compiler -Source $Source -Run $Run -Derived $derived
    $compilerArguments=@('build-exe','-OReleaseSafe','-lc',
        '-I',(Join-Path $Source 'src/common/sdk/nvidia/inc'),'-I',$derived,'-I',(Join-Path $msgq 'inc'),
        (Join-Path $owner 'src/fwsec_abi_check.zig'),(Join-Path $PSScriptRoot 'FwsecAbi.c'),(Join-Path $msgq 'msgq.c'),$messageObject,("-femit-bin=$exe"))
    $result=Invoke-RmNative -Executable $Compiler -Arguments $compilerArguments -WorkingDirectory $Run -LogPath (Join-Path $Run 'fwsec-abi-compile.log') -TimeoutSeconds 90
    if($result -ne 0){throw 'Original FWSEC ABI comparison did not compile'}
    $result=Invoke-RmNative -Executable $exe -Arguments @() -WorkingDirectory $Run -LogPath (Join-Path $Stage 'fwsec-abi.json') -TimeoutSeconds 20
    if($result -ne 0){throw 'Zig firmware command, memory or message bytes differ from original NVIDIA C structures'}
    $abi=Get-Content -Raw (Join-Path $Stage 'fwsec-abi.json')|ConvertFrom-Json
    if(!$abi.gsp_boot_event_original_comparison -or $abi.gsp_boot_event_fixtures -ne 6){throw 'GSP boot event comparison incomplete'}
    if(!$abi.zig_c_byte_comparison -or !$abi.gsp_wpr_byte_comparison -or !$abi.gsp_init_byte_comparison -or !$abi.original_msgq_create_executed_on_host -or !$abi.gsp_message_byte_comparison -or $abi.gsp_message_fixtures -ne 6 -or !$abi.original_gsp_checksum_executed_on_host -or !$abi.gsp_ring_original_comparison -or $abi.gsp_ring_fixtures -ne 8 -or !$abi.original_msgq_link_submit_consume_executed_on_host -or $abi.gpu_executed){throw 'Firmware ABI result invalid'}
    return $abi
}
