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
function Invoke-Compiler([string[]]$Arguments,[string]$LogPath){
    $start=[Diagnostics.ProcessStartInfo]::new($zig)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.WorkingDirectory=$outputRoot
    foreach($name in @('CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','OBJC_INCLUDE_PATH','LIBRARY_PATH')){$null=$start.Environment.Remove($name)}
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    try {
        $timedOut=!$process.WaitForExit(600000)
        if($timedOut){$process.Kill($true);$process.WaitForExit()}
        [IO.File]::WriteAllText($LogPath,$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
        if($timedOut){throw 'RM link compiler exceeded ten minutes'}
        return $process.ExitCode
    } finally {
        if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()}
        $process.Dispose()
    }
}
$plan=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-plan.json')|ConvertFrom-Json
$results=Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'compile-results.json')|ConvertFrom-Json
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
    $idCode=Invoke-Compiler (@('cc')+$flags+@('-c',$generated,'-o',$idObject)) (Join-Path $outputRoot ($unit+'-id.log'))
    if($idCode -ne 0){throw "ID compilation failed $unit"}
    $objects+=$idObject
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
    $code=Invoke-Compiler $arguments (Join-Path $outputRoot ($unit+'-link.log'))
    $record=[ordered]@{component=$unit;exit_code=$code;input_objects=$objects.Count;generated_id=$idSymbol;partial_link=$true;runtime_complete=$false;shader_payloads_added=$false;os_adapter_added=$false}
    if($code -eq 0){$record.bytes=(Get-Item -LiteralPath $output).Length;$record.sha256=(Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant()}
    $proof+=$record
    Write-Host "$unit partial link: exit=$code"
}
[IO.File]::WriteAllText((Join-Path $outputRoot 'link-results.json'),($proof|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
if(@($proof|Where-Object {$_.exit_code -ne 0}).Count){throw 'Partial link failed'}
