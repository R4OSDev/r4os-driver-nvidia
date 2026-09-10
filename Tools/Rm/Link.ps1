# Preserve upstream export roots in an explicit, incomplete partial link.
param(
    [Parameter(Mandatory)][string]$Compiler,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$sourceRoot=[IO.Path]::GetFullPath($SourceDirectory)
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$zig=[IO.Path]::GetFullPath($Compiler)
. (Join-Path $PSScriptRoot 'Native.ps1')
$plan=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-plan.json')|ConvertFrom-Json
$results=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-results.json')|ConvertFrom-Json
$shaders=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'shader-results.json')|ConvertFrom-Json
$adapter=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'os-adapter-results.json')|ConvertFrom-Json
if($adapter.schema -ne 4 -or $adapter.subset -cne 'cpu-memory-clock-semaphores-and-waits' -or $adapter.components.Count -ne 8 -or !$adapter.host_acceptance.passed -or !$adapter.clock_acceptance.passed -or !$adapter.semaphore_acceptance.passed -or !$adapter.wait_acceptance.passed -or $adapter.driver_wait_provider_linked -or $adapter.runtime_complete -or $adapter.driver_heap_provider_linked -or $adapter.driver_clock_provider_linked -or $adapter.driver_semaphore_provider_linked -or $adapter.native_fault_provider_linked -or $adapter.gpu_executed -or $adapter.module_installed){throw 'Verified CPU memory, clock, semaphore and wait adapter subsets are required'}
if($shaders.schema -ne 1 -or $shaders.families -ne 8 -or $shaders.payloads.Count -ne 8 -or $shaders.gpu_executed){throw 'Complete verified shader payloads are required'}
if($results.completed -ne $plan.translation_units.Count -or $results.failed -ne 0 -or $results.not_executed -ne 0){throw 'Compilation must complete before link audit'}
$byId=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($result in $results.results){$byId.Add($result.id,$result)}
$proof=@()
foreach($component in $plan.components) {
    $unit=$component.name
    $objects=@()
    foreach($item in $plan.translation_units|Where-Object {$_.component -ceq $unit}) {
        $expected=$byId[$item.id]
        if($null -eq $expected -or (Get-FileHash -LiteralPath $item.object).Hash.ToLowerInvariant() -cne $expected.sha256){throw "Object verification failed $($item.id)"}
        $objects+=$item.object
    }
    $idSymbol=if($unit -eq 'nvidia'){'NVRM_ID'}else{'NV_KMS_ID'}
    $generated=Join-Path $outputRoot ($unit+'-id.c')
    $text="/* R4OS deterministic port identification; original source revision $($plan.source_commit). */`nconst char $idSymbol[] = `"nvidia id: NVIDIA $unit $($plan.rm_version) for R4OS x86_64`";`nconst char *const p$idSymbol = $idSymbol + 11;`n"
    [IO.File]::WriteAllText($generated,$text,[Text.UTF8Encoding]::new($false))
    $idObject=Join-Path $outputRoot ($unit+'-id.o')
    $flags=@($component.flags)+@('-std=gnu11')
    $idCode=Invoke-RmNative -Executable $zig -Arguments (@('cc')+$flags+@('-c',$generated,'-o',$idObject)) -WorkingDirectory $outputRoot -LogPath (Join-Path $outputRoot ($unit+'-id.log'))
    if($idCode -ne 0){throw "ID compilation failed $unit"}
    $objects+=$idObject
    $componentAdapters=@($adapter.components|Where-Object {$_.component -ceq $unit})
    if($componentAdapters.Count -ne 4){throw 'Memory, clock, semaphore and wait adapters are required for each component'}
    foreach($item in $componentAdapters){
        if((Get-FileHash -LiteralPath $item.object).Hash.ToLowerInvariant() -cne $item.sha256){throw 'OS adapter object changed after verification'}
        $objects+=$item.object
    }
    if($unit -eq 'nvidia-modeset'){
        foreach($payload in $shaders.payloads){
            if(!$payload.upstream_decoder_verified -or !$payload.exact_metadata_extent_verified -or !$payload.readonly_data -or $payload.symbols.Count -ne 2 -or (Get-FileHash -LiteralPath $payload.object).Hash.ToLowerInvariant() -cne $payload.object_sha256){throw 'Shader object changed after verification'}
            $objects+=$payload.object
        }
    }
    $response=Join-Path $outputRoot ($unit+'-objects.rsp')
    $quoted=@($objects|ForEach-Object {'"'+$_.Replace('\','/').Replace('"','\"')+'"'})
    [IO.File]::WriteAllLines($response,$quoted,[Text.UTF8Encoding]::new($false))
    $output=Join-Path $outputRoot ($unit+'-partial.o')
    $arguments=@('cc','-target','x86_64-freestanding-none','-nostdlib','-r','-Xlinker','-z','-Xlinker','noexecstack')
    if($unit -eq 'nvidia') {
        $arguments+=@('-Xlinker','--gc-sections','-Xlinker','-T','-Xlinker',(Join-Path $sourceRoot 'src/nvidia/nv-kernel.ld'))
        foreach($line in Get-Content -LiteralPath (Join-Path $sourceRoot 'src/nvidia/exports_link_command.txt')) {
            if(!$line.Trim()){continue}
            if($line -notmatch '^--undefined=[a-zA-Z0-9_]+$'){throw 'Unexpected original export root'}
            $arguments+=@('-Xlinker','-u','-Xlinker',$line.Substring('--undefined='.Length))
        }
    }
    $arguments+=@(('@'+$response),'-o',$output)
    $code=Invoke-RmNative -Executable $zig -Arguments $arguments -WorkingDirectory $outputRoot -LogPath (Join-Path $outputRoot ($unit+'-link.log'))
    $record=[ordered]@{component=$unit;exit_code=$code;input_objects=$objects.Count;generated_id=$idSymbol;partial_link=$true;runtime_complete=$false;shader_payloads_added=($unit -eq 'nvidia-modeset');os_adapter_added=$true;os_adapter_subset=$adapter.subset}
    if($code -eq 0){$record.bytes=(Get-Item -LiteralPath $output).Length;$record.sha256=(Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant()}
    $proof+=$record
    Write-Host "$unit partial link: exit=$code"
}
[IO.File]::WriteAllText((Join-Path $outputRoot 'link-results.json'),($proof|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
if(@($proof|Where-Object {$_.exit_code -ne 0}).Count){throw 'Partial link failed'}
