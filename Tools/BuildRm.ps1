# Explicit offline source build. Output stays in a fresh scratch transaction;
# neither the installed R4D nor the supplied original source tree is changed.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [ValidateRange(1,8)][int]$Jobs=4
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$moduleRoot=Split-Path -Parent $PSScriptRoot
$pin=Get-Content -Raw -LiteralPath (Join-Path $moduleRoot 'src/firmware-lock.json')|ConvertFrom-Json
$sourcePin=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Rm/Sources.json')|ConvertFrom-Json
if($pin.schema -ne 1 -or $sourcePin.schema -ne 1 -or $sourcePin.source_commit -cne $pin.source_commit){throw 'RM source catalog and firmware version pin disagree'}
foreach($path in @($Compiler,$SourceDirectory,$ScratchDirectory)){
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Compiler, source and scratch paths must be absolute'}
}
$zig=[IO.Path]::GetFullPath($Compiler)
$sourceRoot=[IO.Path]::GetFullPath($SourceDirectory)
$scratchRoot=[IO.Path]::GetFullPath($ScratchDirectory)
if(!(Test-Path -LiteralPath $zig -PathType Leaf) -or !(Test-Path -LiteralPath $sourceRoot -PathType Container)){throw 'Compiler or original source directory is missing'}
foreach($root in @($sourceRoot,$moduleRoot)){
    $relative=[IO.Path]::GetRelativePath($root,$scratchRoot).Replace('\','/')
    if($relative -eq '.' -or (!$relative.StartsWith('../',[StringComparison]::Ordinal) -and ![IO.Path]::IsPathRooted($relative))){throw 'Scratch directory must be outside the input source and driver repositories'}
}
[IO.Directory]::CreateDirectory($scratchRoot)|Out-Null
$runRoot=Join-Path $scratchRoot ('nvidia-rm-'+[Guid]::NewGuid().ToString('N'))
$snapshot=Join-Path $runRoot 'source'
[IO.Directory]::CreateDirectory($snapshot)|Out-Null
Write-Host "NVIDIA RM source build: $runRoot"
$report=[ordered]@{
    schema=1;rm_version=$pin.rm_version;source_commit=$pin.source_commit
    source_verified=$false;compile_complete=$false;partial_links_complete=$false;audit_complete=$false
    runtime_complete=$false;native_initialization_authorized=$false;gpu_executed=$false
    shader_payloads_added=$false;os_adapter_added=$false;module_installed=$false
    source_catalog_sha256=$sourcePin.catalog_sha256
}
$clock=[Diagnostics.Stopwatch]::StartNew()
try {
    # Snapshot all pinned source, header, build and license inputs. Reject
    # symlinks/junctions instead of copying dependencies from outside the tree.
    $inputs=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($scope in $sourcePin.scope){
        $path=Join-Path $sourceRoot $scope
        $root=Get-Item -LiteralPath $path -Force
        $entries=@($root)
        if($root.PSIsContainer){$entries+=@(Get-ChildItem -LiteralPath $path -Force -Recurse)}
        foreach($entry in $entries){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'RM input contains a symlink or junction'}
            if($entry.PSIsContainer){continue}
            $relative=[IO.Path]::GetRelativePath($sourceRoot,$entry.FullName).Replace('\','/')
            if($relative.Contains("`n") -or $relative.Contains("`r")){throw 'Invalid RM source path'}
            $inputs.Add($relative,$entry)
        }
    }
    if($inputs.Count -ne $sourcePin.files){throw "RM source file count differs: $($inputs.Count), expected $($sourcePin.files)"}
    [string[]]$paths=@($inputs.Keys);[Array]::Sort($paths,[StringComparer]::Ordinal)
    $catalog=[Text.StringBuilder]::new();[long]$total=0
    foreach($relative in $paths){
        $target=Join-Path $snapshot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
        Copy-Item -LiteralPath $inputs[$relative].FullName -Destination $target
        $file=Get-Item -LiteralPath $target
        $sha=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant()
        $null=$catalog.Append($sha).Append(' ').Append($file.Length.ToString([Globalization.CultureInfo]::InvariantCulture)).Append(' ').Append($relative).Append("`n")
        $total+=$file.Length
    }
    $catalogBytes=[Text.Encoding]::UTF8.GetBytes($catalog.ToString())
    [IO.File]::WriteAllBytes((Join-Path $runRoot 'source-catalog.txt'),$catalogBytes)
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($catalogBytes)).ToLowerInvariant()
    if($total -ne $sourcePin.bytes -or $digest -cne $sourcePin.catalog_sha256){throw 'RM source catalog mismatch; no compiler was started'}
    $report.source_verified=$true;$report.source_files=$paths.Count;$report.source_bytes=$total
    Write-Host "Verified private snapshot: $($paths.Count) original inputs, $total bytes."
    # These helpers are separate PS7 processes so their own exit status cannot
    # be confused with a stale native LASTEXITCODE from an earlier command.
    $pwsh=(Get-Process -Id $PID).Path
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Rm/Compile.ps1') -Compiler $zig -SourceDirectory $snapshot -OutputDirectory $runRoot -Jobs $Jobs
    if($LASTEXITCODE -ne 0){throw 'Original RM/NVKMS compilation failed; see compile-results.json and compile-logs'}
    $report.compile_complete=$true
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Rm/Link.ps1') -Compiler $zig -SourceDirectory $snapshot -OutputDirectory $runRoot
    if($LASTEXITCODE -ne 0){throw 'RM/NVKMS partial link failed; see link-results.json and component link logs'}
    $report.partial_links_complete=$true
    $components=@();$symbolTables=@{}
    foreach($unit in @('nvidia','nvidia-modeset')){
        & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Rm/InspectElf.ps1') -InputFile (Join-Path $runRoot ($unit+'-partial.o')) -OutputFile (Join-Path $runRoot ($unit+'-elf.json'))
        if($LASTEXITCODE -ne 0){throw "ELF dependency inspection failed: $unit"}
        $elf=Get-Content -Raw -LiteralPath (Join-Path $runRoot ($unit+'-elf.json'))|ConvertFrom-Json
        $symbolTables[$unit]=$elf
        $groups=[ordered]@{}
        foreach($symbol in $elf.undefined){
            $group=switch -Regex ($symbol.name){
                '^libspdm_' {'spdm_crypto';break}
                '^_binary_.*_shaders_xz_(start|end)$' {'embedded_shaders';break}
                '^nvkms_' {'nvkms_os';break}
                '^nvlink_' {'nvlink_os';break}
                '^nvswitch_' {'nvswitch_os';break}
                '^os_' {'rm_os';break}
                '^nv_' {'rm_platform';break}
                default {'runtime_and_globals'}
            }
            if(!$groups.Contains($group)){$groups[$group]=0};$groups[$group]++
        }
        $components+=[ordered]@{
            component=$unit;object_bytes=$elf.bytes;sha256=$elf.sha256
            allocated_section_bytes_before_R4M0_layout=$elf.allocated_section_bytes_before_R4M0_layout
            undefined_count=$elf.undefined_count;defined_count=$elf.defined_count
            tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections
            allocated_relocation_types=$elf.allocated_relocation_types
            undefined_categories=$groups
        }
    }
    $rmNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($symbol in $symbolTables['nvidia'].defined){$null=$rmNames.Add($symbol.name)}
    $report.duplicate_global_definition_candidates=@($symbolTables['nvidia-modeset'].defined|Where-Object {$rmNames.Contains($_.name)}|ForEach-Object {$_.name})
    $report.upstream_memcpy_memset_localization_applied=$false
    $report.components=$components;$report.audit_complete=$true
    Write-Host 'Original RM/NVKMS source build and dependency inspection completed. OS callbacks, shader payloads and a final R4D link are still required.'
} catch {
    $report.error=$_.Exception.Message
    throw
} finally {
    $report.elapsed_seconds=[Math]::Round($clock.Elapsed.TotalSeconds,2)
    [IO.File]::WriteAllText((Join-Path $runRoot 'run.json'),($report|ConvertTo-Json -Depth 9)+"`n",[Text.UTF8Encoding]::new($false))
    # Keep failed attempts and their logs for diagnosis. No previous successful
    # output is overwritten, removed, installed or reported as this attempt.
}
