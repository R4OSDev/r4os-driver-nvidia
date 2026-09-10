# Compile the original per-component translation-unit lists for R4OS.
# Inputs are a verified private source snapshot supplied by BuildRm.ps1.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1,8)][int]$Jobs=4,
    [ValidateRange(1,100)][int]$FailureLimit=12
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$sourceRoot=[IO.Path]::GetFullPath($SourceDirectory)
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$pin=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../src/firmware-lock.json')|ConvertFrom-Json
if((Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'version.mk')) -notmatch ('(?m)^NVIDIA_VERSION\s*=\s*'+[regex]::Escape($pin.rm_version)+'\s*$')){throw 'Upstream version differs from the package pin'}
$zig=[IO.Path]::GetFullPath($Compiler)
$objectRoot=Join-Path $outputRoot 'objects';$logRoot=Join-Path $outputRoot 'compile-logs'
[IO.Directory]::CreateDirectory($objectRoot)|Out-Null
[IO.Directory]::CreateDirectory($logRoot)|Out-Null
$includeRoot=Join-Path $outputRoot 'port-include'
[IO.Directory]::CreateDirectory($includeRoot)|Out-Null
$versionHeader=Join-Path $sourceRoot 'src/common/inc/nvUnixVersion.h'
$original=[IO.File]::ReadAllText($versionHeader)
$needle='#if defined(NV_LINUX) || defined(NV_BSD)'
if(([regex]::Matches($original,[regex]::Escape($needle))).Count -ne 1){throw 'Unexpected upstream version guard'}
$ported=$original.Replace($needle,'#if defined(NV_R4OS) || defined(NV_LINUX) || defined(NV_BSD)')
$portedHeader=Join-Path $includeRoot 'nvUnixVersion.h'
[IO.File]::WriteAllText($portedHeader,$ported,[Text.UTF8Encoding]::new($false))
$common=@('-target','x86_64-freestanding-none','-ffreestanding','-fPIC','-fno-stack-protector','-mno-red-zone','-mno-mmx','-mno-sse','-mno-sse2','-msoft-float','-fno-common','-fno-strict-aliasing','-fno-omit-frame-pointer','-ffunction-sections','-fdata-sections','-DNV_UNIX','-DNV_R4OS','-DNV_X86_64','-DNV_ARCH_BITS=64',('-DNV_VERSION_STRING="'+$pin.rm_version+'"'),('-I'+$includeRoot),'-O2','-g0','-Werror=implicit-function-declaration','-Werror=date-time',('-ffile-prefix-map='+$sourceRoot+'=/nvidia-source'),('-ffile-prefix-map='+$outputRoot+'=/r4os-rm-build'))
$groups=@();$translationUnits=@();$inputs=@([ordered]@{path='src/common/inc/nvUnixVersion.h';sha256=(Get-FileHash -LiteralPath $versionHeader).Hash.ToLowerInvariant();port='add NV_R4OS to version-only platform guard';ported_sha256=(Get-FileHash -LiteralPath $portedHeader).Hash.ToLowerInvariant()})
foreach($unit in @('nvidia','nvidia-modeset')) {
    $unitRoot=Join-Path $sourceRoot ('src/'+$unit)
    $flags=@($common)
    $flags+=@('-include',(Join-Path $sourceRoot 'src/common/sdk/nvidia/inc/cpuopsys.h'))
    $makefile=Join-Path $unitRoot 'Makefile';$sourcesFile=Join-Path $unitRoot 'srcs.mk'
    foreach($buildInput in @($makefile,$sourcesFile)){$inputs+=[ordered]@{path=[IO.Path]::GetRelativePath($sourceRoot,$buildInput).Replace('\','/');sha256=(Get-FileHash -LiteralPath $buildInput).Hash.ToLowerInvariant()}}
    # Keep each component's include order and defines separate. The older
    # seven-file probe combined them and was not a complete product build.
    foreach($line in Get-Content -LiteralPath $makefile) {
        if($line -match '^\s*CFLAGS \+= -I (.+)$') {
            $relative=$Matches[1].Replace('$(SRC_COMMON)','../common').Trim()
            if($relative.Contains('$')){throw "Unresolved include: $line"}
            $flags+='-I'+[IO.Path]::GetFullPath((Join-Path $unitRoot $relative))
        }
        if($line -match '^\s*CFLAGS \+= (-D[^ ]+)$') {
            $define=$Matches[1].Replace('\"','"')
            if($define.Contains('$')){throw "Unresolved define: $line"}
            $flags+=$define
        }
    }
    $spdmSources=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $spdmFlags=@()
    if($unit -eq 'nvidia') {
        $spdmFile=Join-Path $unitRoot 'src/libraries/libspdm/nvidia/openspdm.mk'
        $inputs+=[ordered]@{path=[IO.Path]::GetRelativePath($sourceRoot,$spdmFile).Replace('\','/');sha256=(Get-FileHash -LiteralPath $spdmFile).Hash.ToLowerInvariant()}
        foreach($line in Get-Content -LiteralPath $spdmFile) {
            if($line -match '^LIBSPDM_(SOURCES|INCLUDES|DEFINES)\s+\+=\s+(.+)$') {
                $kind=$Matches[1];$value=$Matches[2].Replace('$(LIBSPDM_SOURCE_DIR)','src/libraries/libspdm').Replace('$(LIBSPDM_VERSION)','3.1.1').Replace('\"','"').Trim()
                if($value.Contains('$')){throw "Unresolved libspdm input: $line"}
                switch($kind) {
                    SOURCES {$null=$spdmSources.Add($value)}
                    INCLUDES {$spdmFlags+='-I'+[IO.Path]::GetFullPath((Join-Path $unitRoot $value))}
                    DEFINES {$spdmFlags+='-D'+$value}
                }
            }
        }
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $groupStart=$translationUnits.Count
    foreach($line in Get-Content -LiteralPath $sourcesFile) {
        if(!$line.Trim() -or $line -match '^\s*#|^SRCS(_CXX)?\s+\?=\s*$'){continue}
        if($line -notmatch '^(SRCS|SRCS_CXX)\s+\+=\s+([^\s$]+)$'){throw "Unsupported source-list syntax: $line"}
        $kind=$Matches[1];$relative=$Matches[2]
        if(!$seen.Add($relative)){throw "Duplicate translation unit: $unit/$relative"}
        $source=[IO.Path]::GetFullPath((Join-Path $unitRoot $relative))
        if(!(Test-Path -LiteralPath $source -PathType Leaf) -or ![IO.Path]::GetRelativePath($sourceRoot,$source).Replace('\','/').StartsWith('src/')){throw 'Translation unit outside pinned source tree'}
        $fileFlags=@($flags)
        if($spdmSources.Contains($relative)){$fileFlags+=$spdmFlags}
        $frontend=if($kind -eq 'SRCS_CXX'){'c++'}else{'cc'}
        $fileFlags+=if($frontend -eq 'c++'){@('-std=gnu++11','-fno-operator-names','-fno-rtti','-fno-exceptions','-fcheck-new')}else{@('-std=gnu11')}
        $id=('{0:D4}' -f $translationUnits.Count)+'-'+$unit+'-'+[IO.Path]::GetFileNameWithoutExtension($source)
        $translationUnits+=[ordered]@{id=$id;component=$unit;source=$source;relative_source=[IO.Path]::GetRelativePath($sourceRoot,$source).Replace('\','/');source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant();frontend=$frontend;flags=$fileFlags;object=Join-Path $objectRoot ($id+'.o');log=Join-Path $logRoot ($id+'.log')}
    }
    $groups+=[ordered]@{name=$unit;translation_units=$translationUnits.Count-$groupStart;flags=$flags;spdm_flags=$spdmFlags}
}
$plan=[ordered]@{schema=1;rm_version=$pin.rm_version;source_commit=$pin.source_commit;target='x86_64-freestanding-none PIC';host=[Runtime.InteropServices.RuntimeInformation]::OSDescription;compiler=(& $zig version);linux_os_emulation=$false;compile_only=$true;inputs=$inputs;components=$groups;translation_units=$translationUnits}
[IO.File]::WriteAllText((Join-Path $outputRoot 'compile-plan.json'),($plan|ConvertTo-Json -Depth 9)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host "Resolved $($translationUnits.Count) original translation units; $Jobs compiler processes, no vendor build scripts or Linux OS defines."
$active=[Collections.Generic.List[object]]::new();$results=[Collections.Generic.List[object]]::new()
$next=0;$failed=0;$clock=[Diagnostics.Stopwatch]::StartNew();$lastReport=0.0
try {
    while($next -lt $translationUnits.Count -or $active.Count) {
        while($next -lt $translationUnits.Count -and $active.Count -lt $Jobs -and $failed -lt $FailureLimit) {
            $item=$translationUnits[$next];$next++
            $start=[Diagnostics.ProcessStartInfo]::new($zig)
            $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($name in @('CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','OBJC_INCLUDE_PATH','LIBRARY_PATH')){$null=$start.Environment.Remove($name)}
            $start.WorkingDirectory=Join-Path $sourceRoot ('src/'+$item.component)
            foreach($argument in (@($item.frontend)+@($item.flags)+@('-c',$item.source,'-o',$item.object))){$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::Start($start)
            $active.Add(@{process=$process;item=$item;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync();started=$clock.Elapsed.TotalSeconds;timed_out=$false})
        }
        for($index=$active.Count-1;$index -ge 0;$index--) {
            $job=$active[$index]
            if(!$job.process.HasExited -and $clock.Elapsed.TotalSeconds-$job.started -ge 600){$job.timed_out=$true;$job.process.Kill($true)}
            if(!$job.process.HasExited){continue}
            $code=$job.process.ExitCode;$item=$job.item
            $output=$job.stdout.GetAwaiter().GetResult()+$job.stderr.GetAwaiter().GetResult()
            [IO.File]::WriteAllText($item.log,$output,[Text.UTF8Encoding]::new($false))
            $record=[ordered]@{id=$item.id;component=$item.component;source=$item.relative_source;exit_code=$code;timed_out=$job.timed_out;log=[IO.Path]::GetRelativePath($outputRoot,$item.log).Replace('\','/')}
            if($code -eq 0){$record.bytes=(Get-Item -LiteralPath $item.object).Length;$record.sha256=(Get-FileHash -LiteralPath $item.object).Hash.ToLowerInvariant()}
            else{$failed++;Write-Host "Rejected $($item.id): exit=$code"}
            $results.Add($record);$job.process.Dispose();$active.RemoveAt($index)
        }
        if($clock.Elapsed.TotalSeconds-$lastReport -ge 15){Write-Host "Compiler progress: $($results.Count)/$($translationUnits.Count), failed=$failed, active=$($active.Count), elapsed=$([int]$clock.Elapsed.TotalSeconds)s";$lastReport=$clock.Elapsed.TotalSeconds}
        if($failed -ge $FailureLimit -and $active.Count -eq 0){break}
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach($job in $active){if(!$job.process.HasExited){$job.process.Kill($true);$job.process.WaitForExit()};$job.process.Dispose()}
    $report=[ordered]@{schema=1;rm_version=$pin.rm_version;translation_units=$translationUnits.Count;completed=$results.Count;failed=$failed;not_executed=$translationUnits.Count-$results.Count;elapsed_seconds=[Math]::Round($clock.Elapsed.TotalSeconds,2);linked=$false;gpu_executed=$false;results=@($results|Sort-Object id)}
    [IO.File]::WriteAllText((Join-Path $outputRoot 'compile-results.json'),($report|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
}
if($failed -or $results.Count -ne $translationUnits.Count){throw "Compilation incomplete: $failed rejected, $($results.Count)/$($translationUnits.Count) attempted"}
Write-Host "All $($results.Count) original translation units compiled; linking and OS callbacks remain to be implemented."
