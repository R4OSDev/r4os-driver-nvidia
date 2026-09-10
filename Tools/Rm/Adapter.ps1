# Build the R4OS memory and monotonic-clock subsets against pinned headers.
# Private providers remain unresolved in these partial objects. Host fixtures
# supply an allocator and clock; nothing from this build is installed in R4D.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$moduleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$zig=[IO.Path]::GetFullPath($Compiler)
. (Join-Path $PSScriptRoot 'Native.ps1')
$plan=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-plan.json')|ConvertFrom-Json
$adapterRoot=Join-Path $outputRoot 'adapter'
$sourceRoot=Join-Path $adapterRoot 'source'
$inputs=@()
foreach($relative in @('src/rm/memory.h','src/rm/os_memory.c','src/rm/nvkms_memory.c','Tests/RmMemory.c','src/rm/clock.h','src/rm/os_clock.c','src/rm/nvkms_clock.c','Tests/RmClock.c')){
    $source=Join-Path $moduleRoot $relative
    $copy=Join-Path $sourceRoot $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $copy))|Out-Null
    Copy-Item -LiteralPath $source -Destination $copy
    $inputs+=[ordered]@{path=$relative;bytes=(Get-Item -LiteralPath $copy).Length;sha256=(Get-FileHash -LiteralPath $copy).Hash.ToLowerInvariant()}
}
$components=@();$includes=@();$hostObjects=@()
foreach($component in $plan.components){
    $name=if($component.name -ceq 'nvidia'){'os_memory'}elseif($component.name -ceq 'nvidia-modeset'){'nvkms_memory'}else{throw 'Unexpected RM component'}
    $source=Join-Path $sourceRoot ('src/rm/'+$name+'.c')
    $object=Join-Path $adapterRoot ($name+'.o')
    $flags=@($component.flags)+@('-std=gnu11','-Werror','-Wmissing-prototypes')
    $code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$flags+@('-c',$source,'-o',$object)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot ($name+'-compile.log'))
    if($code -ne 0){throw "R4OS memory adapter compilation failed: $name"}
    $elfFile=Join-Path $adapterRoot ($name+'-elf.json')
    $pwsh=(Get-Process -Id $PID).Path
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'InspectElf.ps1') -InputFile $object -OutputFile $elfFile
    if($LASTEXITCODE -ne 0){throw "R4OS memory adapter inspection failed: $name"}
    $elf=Get-Content -Raw -LiteralPath $elfFile|ConvertFrom-Json
    [string[]]$undefined=@($elf.undefined|ForEach-Object {$_.name});[Array]::Sort($undefined,[StringComparer]::Ordinal)
    if(($undefined -join ',') -cne 'r4nv_heap_allocate,r4nv_heap_free' -or $elf.tls_bytes -ne 0 -or $elf.initializer_sections.Count){throw 'Memory adapter gained an unexpected runtime dependency'}
    $expected=if($name -eq 'os_memory'){8}else{9}
    if($elf.defined_count -ne $expected){throw 'Memory adapter export count changed'}
    $components+=[ordered]@{component=$component.name;object=$object;bytes=$elf.bytes;sha256=$elf.sha256;implemented=@($elf.defined|ForEach-Object {$_.name});undefined=$undefined;tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections}
    $includes+=@($component.flags|Where-Object {$_.StartsWith('-I')})
    $hostObjects+=$object
}

if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64){throw 'Memory adapter host acceptance requires an x86_64 host'}
$hostFlags=@('-std=gnu11','-O2','-g0','-fno-builtin','-fno-strict-aliasing','-DNV_UNIX','-DNV_R4OS','-DNV_X86_64','-DNV_ARCH_BITS=64','-Werror=implicit-function-declaration','-Werror=date-time')+$includes+@('-I'+(Join-Path $sourceRoot 'src/rm'))
$check=Join-Path $adapterRoot $(if($IsWindows){'check-memory.exe'}else{'check-memory'})
# Linux x86_64 executes the exact freestanding objects that enter the partial
# links. Windows builds the same C sources for its native calling convention;
# those host objects never replace the freestanding target objects.
$exactTargetObjects=$IsLinux
$hostInputs=@((Join-Path $sourceRoot 'Tests/RmMemory.c'))
if($exactTargetObjects){$hostInputs+=$hostObjects}
else{$hostInputs+=@((Join-Path $sourceRoot 'src/rm/os_memory.c'),(Join-Path $sourceRoot 'src/rm/nvkms_memory.c'))}
$buildLog=Join-Path $adapterRoot 'host-build.log'
$code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$hostFlags+$hostInputs+@('-o',$check)) -WorkingDirectory $adapterRoot -LogPath $buildLog
if($code -ne 0){throw 'R4OS memory adapter host acceptance did not build'}
$checkLog=Join-Path $adapterRoot 'host-check.log'
$code=Invoke-RmNative -Executable $check -Arguments @('check') -WorkingDirectory $adapterRoot -LogPath $checkLog -TimeoutSeconds 30
$message=Get-Content -Raw -LiteralPath $checkLog
if($code -ne 0 -or $message -notmatch '^RM memory adapters: OK checks=(\d+) allocations=(\d+) frees=(\d+) live=0 guard-pages=active gpu=none\r?\n$'){throw 'R4OS memory adapter host acceptance failed'}
$acceptance=[ordered]@{passed=$true;checks=[long]$Matches[1];allocation_calls=[int]$Matches[2];frees=[int]$Matches[3];live_allocations=0;guard_pages=$true;exact_freestanding_objects_executed=$exactTargetObjects;host=[Runtime.InteropServices.RuntimeInformation]::OSDescription;executable_sha256=(Get-FileHash -LiteralPath $check).Hash.ToLowerInvariant();gpu_executed=$false}
Write-Host $message.Trim()
$clockObjects=@()
foreach($component in $plan.components){
    $name=if($component.name -ceq 'nvidia'){'os_clock'}else{'nvkms_clock'}
    $source=Join-Path $sourceRoot ('src/rm/'+$name+'.c')
    $object=Join-Path $adapterRoot ($name+'.o')
    $flags=@($component.flags)+@('-std=gnu11','-Werror','-Wmissing-prototypes')
    $code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$flags+@('-c',$source,'-o',$object)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot ($name+'-compile.log'))
    if($code -ne 0){throw "R4OS clock adapter compilation failed: $name"}
    $elfFile=Join-Path $adapterRoot ($name+'-elf.json')
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'InspectElf.ps1') -InputFile $object -OutputFile $elfFile
    if($LASTEXITCODE -ne 0){throw "R4OS clock adapter inspection failed: $name"}
    $elf=Get-Content -Raw -LiteralPath $elfFile|ConvertFrom-Json
    [string[]]$undefined=@($elf.undefined|ForEach-Object {$_.name});[Array]::Sort($undefined,[StringComparer]::Ordinal)
    $expectedImports=if($name -ceq 'os_clock'){'r4nv_clock_now_ns,r4nv_clock_resolution_ns'}else{'r4nv_clock_now_ns'}
    $expectedExports=if($name -ceq 'os_clock'){3}else{1}
    if(($undefined -join ',') -cne $expectedImports -or $elf.defined_count -ne $expectedExports -or $elf.tls_bytes -ne 0 -or $elf.initializer_sections.Count){throw 'Clock adapter gained an unexpected runtime dependency'}
    $components+=[ordered]@{component=$component.name;object=$object;bytes=$elf.bytes;sha256=$elf.sha256;implemented=@($elf.defined|ForEach-Object {$_.name});undefined=$undefined;tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections}
    $clockObjects+=$object
}
$clockCheck=Join-Path $adapterRoot $(if($IsWindows){'check-clock.exe'}else{'check-clock'})
$clockInputs=@((Join-Path $sourceRoot 'Tests/RmClock.c'))
if($exactTargetObjects){$clockInputs+=$clockObjects}
else{$clockInputs+=@((Join-Path $sourceRoot 'src/rm/os_clock.c'),(Join-Path $sourceRoot 'src/rm/nvkms_clock.c'))}
$code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$hostFlags+$clockInputs+@('-o',$clockCheck)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot 'clock-host-build.log')
if($code -ne 0){throw 'R4OS clock adapter host acceptance did not build'}
$clockLog=Join-Path $adapterRoot 'clock-host-check.log'
$code=Invoke-RmNative -Executable $clockCheck -Arguments @('check') -WorkingDirectory $adapterRoot -LogPath $clockLog -TimeoutSeconds 10
$message=Get-Content -Raw -LiteralPath $clockLog
if($code -ne 0 -or $message -notmatch '^RM clock adapters: OK checks=(\d+) reads=(\d+) resolution-reads=(\d+) units=ns/us gpu=none\r?\n$'){throw 'R4OS clock adapter host acceptance failed'}
$clockAcceptance=[ordered]@{passed=$true;checks=[int]$Matches[1];reads=[int]$Matches[2];resolution_reads=[int]$Matches[3];exact_freestanding_objects_executed=$exactTargetObjects;executable_sha256=(Get-FileHash -LiteralPath $clockCheck).Hash.ToLowerInvariant();gpu_executed=$false}
$report=[ordered]@{schema=2;subset='cpu-memory-strings-and-monotonic-clock';runtime_complete=$false;driver_heap_provider_linked=$false;driver_clock_provider_linked=$false;gpu_executed=$false;module_installed=$false;inputs=$inputs;components=$components;host_acceptance=$acceptance;clock_acceptance=$clockAcceptance}
[IO.File]::WriteAllText((Join-Path $outputRoot 'os-adapter-results.json'),($report|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host $message.Trim()
