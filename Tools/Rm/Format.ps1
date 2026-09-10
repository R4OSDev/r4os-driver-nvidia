# Called by the existing build-rm adapter acceptance; no new workspace gate.
param([Parameter(Mandatory)][string]$Compiler,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$adapterRoot=Join-Path $outputRoot 'adapter'
$sourceRoot=Join-Path $adapterRoot 'source'
$plan=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-plan.json')|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Native.ps1')
$pwsh=(Get-Process -Id $PID).Path
$components=@();$objects=@();$sources=@();$includes=@()
foreach($component in $plan.components){
    $prefix=if($component.name -ceq 'nvidia'){'os'}else{'nvkms'}
    foreach($part in @('format','log')){
        $name=$prefix+'_'+$part
        $source=Join-Path $sourceRoot ('src/rm/'+$name+'.c')
        $object=Join-Path $adapterRoot ($name+'.o')
        $flags=@($component.flags)+@('-std=gnu11','-Werror','-Wmissing-prototypes')
        $code=Invoke-RmNative -Executable $Compiler -Arguments (@('cc')+$flags+@('-c',$source,'-o',$object)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot ($name+'-compile.log'))
        if($code -ne 0){throw "Formatting/logging compilation failed: $name"}
        $elfFile=Join-Path $adapterRoot ($name+'-elf.json')
        & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'InspectElf.ps1') -InputFile $object -OutputFile $elfFile
        if($LASTEXITCODE -ne 0){throw "Formatting/logging inspection failed: $name"}
        $elf=Get-Content -Raw -LiteralPath $elfFile|ConvertFrom-Json
        [string[]]$undefined=@($elf.undefined|ForEach-Object {$_.name});[Array]::Sort($undefined,[StringComparer]::Ordinal)
        $expectedImports=if($part -eq 'format'){''}elseif($prefix -eq 'os'){'os_vsnprintf,r4nv_log'}else{'nvkms_snprintf,r4nv_log'}
        $expectedExports=if($part -eq 'format'){2}elseif($prefix -eq 'os'){4}else{1}
        if(($undefined -join ',') -cne $expectedImports -or $elf.defined_count -ne $expectedExports -or $elf.tls_bytes -ne 0 -or $elf.initializer_sections.Count){throw "Formatting/logging gained an unexpected dependency: $name"}
        $components+=[ordered]@{component=$component.name;object=$object;bytes=$elf.bytes;sha256=$elf.sha256;implemented=@($elf.defined|ForEach-Object {$_.name});undefined=$undefined;tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections}
        $objects+=$object;$sources+=$source
    }
    $includes+=@($component.flags|Where-Object {$_.StartsWith('-I')})
}
$executable=Join-Path $adapterRoot $(if($IsWindows){'check-format.exe'}else{'check-format'})
$hostFlags=@('-std=gnu11','-O2','-g0','-fno-builtin','-fno-strict-aliasing','-DNV_UNIX','-DNV_R4OS','-DNV_X86_64','-DNV_ARCH_BITS=64','-Werror=implicit-function-declaration','-Werror=date-time')+$includes+@('-I'+(Join-Path $sourceRoot 'src/rm'))
$inputs=@((Join-Path $sourceRoot 'Tests/RmFormat.c'))
if($IsLinux){$inputs+=$objects}else{$inputs+=$sources}
$code=Invoke-RmNative -Executable $Compiler -Arguments (@('cc')+$hostFlags+$inputs+@('-o',$executable)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot 'format-host-build.log')
if($code -ne 0){throw 'Formatting/logging host acceptance did not build'}
$log=Join-Path $adapterRoot 'format-host-check.log'
$code=Invoke-RmNative -Executable $executable -Arguments @('check') -WorkingDirectory $adapterRoot -LogPath $log -TimeoutSeconds 15
$message=Get-Content -Raw -LiteralPath $log
if($code -ne 0 -or $message -notmatch '^RM format adapters: OK checks=(\d+) comparisons=(\d+) records=(\d+) guard-pages=active gpu=none\r?\n$'){throw 'Formatting/logging host acceptance failed'}
$acceptance=[ordered]@{passed=$true;checks=[int]$Matches[1];libc_comparisons=[int]$Matches[2];records=[int]$Matches[3];guard_pages=$true;exact_freestanding_objects_executed=$IsLinux;executable_sha256=(Get-FileHash -LiteralPath $executable).Hash.ToLowerInvariant();driver_log_provider_linked=$false;gpu_executed=$false}
[IO.File]::WriteAllText((Join-Path $adapterRoot 'format-results.json'),([ordered]@{schema=1;components=$components;acceptance=$acceptance}|ConvertTo-Json -Depth 6)+[char]10,[Text.UTF8Encoding]::new($false))
Write-Host $message.Trim()
