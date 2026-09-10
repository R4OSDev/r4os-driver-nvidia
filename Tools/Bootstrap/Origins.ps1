# Original archive metadata is retained with the complete source notices.
function Add-BootstrapOrigins([string]$Source,[string]$Stage,$Artifacts){
    $groups=@(
        @{name='GspRmBoot-GA102';file='g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c'},
        @{name='BooterLoad-GA102';file='g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c'},
        @{name='BooterUnload-GA102';file='g_bindata_kgspGetBinArchiveBooterUnloadUcode_GA102.c'},
        @{name='Sec2Bl-TU102';file='g_bindata_ksec2GetBinArchiveBlUcode_TU102.c'}
    )
    $sources=@()
    foreach($group in $groups){
        $relative='src/nvidia/generated/'+$group.file
        $text=Get-Content -Raw -LiteralPath (Join-Path $Source $relative)
        if(!$text.Contains('SPDX-License-Identifier: MIT')){throw 'Missing original MIT attribution'}
        $records=[regex]::Matches($text,'(?m)^// FUNCTION: ([A-Za-z0-9_]+)\("([A-Za-z0-9_]+)"\)\r?\n// FILE NAME: ([^\r\n]+)')
        foreach($record in $records){
            $entry=@($Artifacts|Where-Object {$_.name -ceq ($group.name+'-'+$record.Groups[2].Value)})
            if($entry.Count -ne 1){throw 'Source archive key does not match compiled export'}
            $entry[0]|Add-Member -NotePropertyName source_path -NotePropertyValue $relative
            $entry[0]|Add-Member -NotePropertyName archive_function -NotePropertyValue $record.Groups[1].Value
            $entry[0]|Add-Member -NotePropertyName entry_name -NotePropertyValue $record.Groups[2].Value
            $entry[0]|Add-Member -NotePropertyName original_file_name -NotePropertyValue $record.Groups[3].Value
            $entry[0]|Add-Member -NotePropertyName license -NotePropertyValue 'Original generated source: MIT; complete per-file notice retained'
        }
        $sources+=$relative
    }
    foreach($entry in $Artifacts){if(!$entry.source_path){throw 'Unmapped artifact'}}
    $sources+=@('COPYING',
        'src/nvidia/src/lib/zlib/inflate.c','src/nvidia/inc/lib/zlib/inflate.h',
        'src/nvidia/arch/nvalloc/common/inc/rmflcnbl.h',
        'src/nvidia/generated/g_kernel_gsp_nvoc.c','src/nvidia/generated/g_kernel_sec2_nvoc.c',
        'src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_frts_tu102.c',
        'src/nvidia/src/kernel/gpu/gsp/arch/ampere/kernel_gsp_ga100.c',
        'src/nvidia/src/kernel/gpu/gsp/kernel_gsp_fwsec.c',
        'src/common/inc/swref/published/ampere/ga100/dev_fuse.h')
    $facts=@()
    foreach($relative in $sources){
        $file=Join-Path $Source $relative
        $target=Join-Path $Stage ('references/'+$relative)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
        Copy-Item -LiteralPath $file -Destination $target
        $sha=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
        if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -cne $sha){throw 'Reference copy mismatch'}
        $facts+=[ordered]@{path=$relative;bytes=(Get-Item -LiteralPath $file).Length;sha256=$sha}
    }
    return $facts
}
