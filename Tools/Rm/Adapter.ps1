# Build the actual R4OS CPU-memory subset against the pinned NVIDIA headers.
# The private heap provider remains unresolved in target objects; only the
# host acceptance supplies a test allocator. Nothing is installed into R4D.
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
foreach($relative in @('src/rm/memory.h','src/rm/os_memory.c','src/rm/nvkms_memory.c','Tests/RmMemory.c')){
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
$report=[ordered]@{schema=1;subset='cpu-memory-and-strings';runtime_complete=$false;driver_heap_provider_implemented=$false;gpu_executed=$false;module_installed=$false;inputs=$inputs;components=$components;host_acceptance=$acceptance}
[IO.File]::WriteAllText((Join-Path $outputRoot 'os-adapter-results.json'),($report|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host $message.Trim()
