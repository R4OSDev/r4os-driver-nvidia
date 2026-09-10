# Build the R4OS CPU subsets against pinned headers. Private providers and the
# mandatory native-fault boundary remain unresolved in these partial objects.
# Hosted fixtures never become target providers or get installed in R4D.
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
foreach($relative in @('src/rm/memory.h','src/rm/os_memory.c','src/rm/nvkms_memory.c','Tests/RmMemory.c','src/rm/clock.h','src/rm/os_clock.c','src/rm/nvkms_clock.c','Tests/RmClock.c','src/rm/semaphore.h','src/rm/native_fault.h','src/rm/os_semaphore.c','src/rm/nvkms_semaphore.c','Tests/RmSemaphore.c','src/rm/wait.h','src/rm/os_wait.c','src/rm/nvkms_wait.c','Tests/RmWait.c')){
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
Write-Host $message.Trim()
$semaphoreObjects=@()
foreach($component in $plan.components){
    $name=if($component.name -ceq 'nvidia'){'os_semaphore'}else{'nvkms_semaphore'}
    $source=Join-Path $sourceRoot ('src/rm/'+$name+'.c')
    $object=Join-Path $adapterRoot ($name+'.o')
    $flags=@($component.flags)+@('-std=gnu11','-Werror','-Wmissing-prototypes')
    $code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$flags+@('-c',$source,'-o',$object)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot ($name+'-compile.log'))
    if($code -ne 0){throw "R4OS semaphore adapter compilation failed: $name"}
    $elfFile=Join-Path $adapterRoot ($name+'-elf.json')
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'InspectElf.ps1') -InputFile $object -OutputFile $elfFile
    if($LASTEXITCODE -ne 0){throw "R4OS semaphore adapter inspection failed: $name"}
    $elf=Get-Content -Raw -LiteralPath $elfFile|ConvertFrom-Json
    [string[]]$undefined=@($elf.undefined|ForEach-Object {$_.name});[Array]::Sort($undefined,[StringComparer]::Ordinal)
    $expectedImports=if($name -ceq 'os_semaphore'){'r4nv_native_fault,r4nv_semaphore_acquire,r4nv_semaphore_context_flags,r4nv_semaphore_create,r4nv_semaphore_free,r4nv_semaphore_release'}else{'r4nv_native_fault,r4nv_semaphore_acquire,r4nv_semaphore_create,r4nv_semaphore_free,r4nv_semaphore_release'}
    $expectedExports=if($name -ceq 'os_semaphore'){12}else{4}
    if(($undefined -join ',') -cne $expectedImports -or $elf.defined_count -ne $expectedExports -or $elf.tls_bytes -ne 0 -or $elf.initializer_sections.Count){throw 'Semaphore adapter gained an unexpected runtime dependency'}
    $components+=[ordered]@{component=$component.name;object=$object;bytes=$elf.bytes;sha256=$elf.sha256;implemented=@($elf.defined|ForEach-Object {$_.name});undefined=$undefined;tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections}
    $semaphoreObjects+=$object
}
$semaphoreCheck=Join-Path $adapterRoot $(if($IsWindows){'check-semaphore.exe'}else{'check-semaphore'})
$semaphoreInputs=@((Join-Path $sourceRoot 'Tests/RmSemaphore.c'))
if($exactTargetObjects){$semaphoreInputs+=$semaphoreObjects}
else{$semaphoreInputs+=@((Join-Path $sourceRoot 'src/rm/os_semaphore.c'),(Join-Path $sourceRoot 'src/rm/nvkms_semaphore.c'))}
$code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$hostFlags+$semaphoreInputs+@('-o',$semaphoreCheck)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot 'semaphore-host-build.log')
if($code -ne 0){throw 'R4OS semaphore adapter host acceptance did not build'}
$semaphoreLog=Join-Path $adapterRoot 'semaphore-host-check.log'
$code=Invoke-RmNative -Executable $semaphoreCheck -Arguments @('check') -WorkingDirectory $adapterRoot -LogPath $semaphoreLog -TimeoutSeconds 10
$message=Get-Content -Raw -LiteralPath $semaphoreLog
if($code -ne 0 -or $message -notmatch '^RM semaphore adapters: OK checks=(\d+) creates=(\d+) acquires=(\d+) releases=(\d+) frees=(\d+) faults=(\d+) live=0 gpu=none\r?\n$'){throw 'R4OS semaphore adapter host acceptance failed'}
$semaphoreAcceptance=[ordered]@{passed=$true;checks=[int]$Matches[1];creates=[int]$Matches[2];acquires=[int]$Matches[3];releases=[int]$Matches[4];frees=[int]$Matches[5];nonreturning_faults=[int]$Matches[6];live_allocations=0;exact_freestanding_objects_executed=$exactTargetObjects;executable_sha256=(Get-FileHash -LiteralPath $semaphoreCheck).Hash.ToLowerInvariant();native_fault_provider='host-only setjmp/longjmp fixture; target provider excluded from partial links';kernel_waits_executed=$false;gpu_executed=$false}
Write-Host $message.Trim()
$waitObjects=@()
foreach($component in $plan.components){
    $name=if($component.name -ceq 'nvidia'){'os_wait'}else{'nvkms_wait'}
    $source=Join-Path $sourceRoot ('src/rm/'+$name+'.c')
    $object=Join-Path $adapterRoot ($name+'.o')
    $flags=@($component.flags)+@('-std=gnu11','-Werror','-Wmissing-prototypes')
    $code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$flags+@('-c',$source,'-o',$object)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot ($name+'-compile.log'))
    if($code -ne 0){throw "R4OS wait adapter compilation failed: $name"}
    $elfFile=Join-Path $adapterRoot ($name+'-elf.json')
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'InspectElf.ps1') -InputFile $object -OutputFile $elfFile
    if($LASTEXITCODE -ne 0){throw "R4OS wait adapter inspection failed: $name"}
    $elf=Get-Content -Raw -LiteralPath $elfFile|ConvertFrom-Json
    [string[]]$undefined=@($elf.undefined|ForEach-Object {$_.name});[Array]::Sort($undefined,[StringComparer]::Ordinal)
    $expectedImports=if($name -ceq 'os_wait'){'r4nv_schedule,r4nv_wait_ns'}else{'r4nv_native_fault,r4nv_schedule,r4nv_wait_ns'}
    $expectedExports=if($name -ceq 'os_wait'){3}else{2}
    if(($undefined -join ',') -cne $expectedImports -or $elf.defined_count -ne $expectedExports -or $elf.tls_bytes -ne 0 -or $elf.initializer_sections.Count){throw 'Wait adapter gained an unexpected runtime dependency'}
    $components+=[ordered]@{component=$component.name;object=$object;bytes=$elf.bytes;sha256=$elf.sha256;implemented=@($elf.defined|ForEach-Object {$_.name});undefined=$undefined;tls_bytes=$elf.tls_bytes;initializer_sections=$elf.initializer_sections}
    $waitObjects+=$object
}
$waitCheck=Join-Path $adapterRoot $(if($IsWindows){'check-wait.exe'}else{'check-wait'})
$waitInputs=@((Join-Path $sourceRoot 'Tests/RmWait.c'))
if($exactTargetObjects){$waitInputs+=$waitObjects}
else{$waitInputs+=@((Join-Path $sourceRoot 'src/rm/os_wait.c'),(Join-Path $sourceRoot 'src/rm/nvkms_wait.c'))}
$code=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$hostFlags+$waitInputs+@('-o',$waitCheck)) -WorkingDirectory $adapterRoot -LogPath (Join-Path $adapterRoot 'wait-host-build.log')
if($code -ne 0){throw 'R4OS wait adapter host acceptance did not build'}
$waitLog=Join-Path $adapterRoot 'wait-host-check.log'
$code=Invoke-RmNative -Executable $waitCheck -Arguments @('check') -WorkingDirectory $adapterRoot -LogPath $waitLog -TimeoutSeconds 10
$message=Get-Content -Raw -LiteralPath $waitLog
if($code -ne 0 -or $message -notmatch '^RM wait adapters: OK checks=(\d+) calls=(\d+) faults=(\d+) width=64 status=preserved gpu=none\r?\n$'){throw 'R4OS wait adapter host acceptance failed'}
$waitAcceptance=[ordered]@{passed=$true;checks=[int]$Matches[1];calls=[int]$Matches[2];nonreturning_faults=[int]$Matches[3];exact_freestanding_objects_executed=$exactTargetObjects;executable_sha256=(Get-FileHash -LiteralPath $waitCheck).Hash.ToLowerInvariant();native_fault_provider='host-only setjmp/longjmp fixture; target provider excluded from partial links';kernel_waits_executed=$false;gpu_executed=$false}
$report=[ordered]@{schema=4;subset='cpu-memory-clock-semaphores-and-waits';runtime_complete=$false;driver_heap_provider_linked=$false;driver_clock_provider_linked=$false;driver_semaphore_provider_linked=$false;native_fault_provider_linked=$false;gpu_executed=$false;module_installed=$false;inputs=$inputs;components=$components;host_acceptance=$acceptance;clock_acceptance=$clockAcceptance;semaphore_acceptance=$semaphoreAcceptance;wait_acceptance=$waitAcceptance;driver_wait_provider_linked=$false}
[IO.File]::WriteAllText((Join-Path $outputRoot 'os-adapter-results.json'),($report|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host $message.Trim()
