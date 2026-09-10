# Shared native subprocess handling for the explicit RM host build. Binary
# compression input/output uses streams, never PowerShell text redirection.
function Invoke-RmNative {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$LogPath,
        [ValidateRange(1,600)][int]$TimeoutSeconds=600,
        [string]$InputFile,
        [string]$OutputFile
    )
    $start=[Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.RedirectStandardInput=![string]::IsNullOrEmpty($InputFile)
    $start.WorkingDirectory=$WorkingDirectory
    foreach($name in @('CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','OBJC_INCLUDE_PATH','LIBRARY_PATH','XZ_DEFAULTS','XZ_OPT')){$null=$start.Environment.Remove($name)}
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $process=$null;$inputStream=$null;$outputStream=$null
    $clock=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
    try {
        $process=[Diagnostics.Process]::Start($start)
        $stderr=$process.StandardError.ReadToEndAsync()
        if([string]::IsNullOrEmpty($OutputFile)){$stdout=$process.StandardOutput.ReadToEndAsync()}
        else {
            $outputStream=[IO.File]::Create($OutputFile)
            $stdout=$process.StandardOutput.BaseStream.CopyToAsync($outputStream)
        }
        $write=$null;$inputClosed=$false;$inputFailure=$null
        if($start.RedirectStandardInput){
            $inputStream=[IO.File]::OpenRead($InputFile)
            $write=$inputStream.CopyToAsync($process.StandardInput.BaseStream)
        }
        while($true){
            if($null -ne $write -and !$inputClosed -and $write.IsCompleted){
                try {$null=$write.GetAwaiter().GetResult();$process.StandardInput.Close()}
                catch {$inputFailure=$_.Exception.Message}
                $inputClosed=$true
            }
            if($process.HasExited){break}
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){
                $timedOut=$true;$process.Kill($true);$process.WaitForExit();break
            }
            Start-Sleep -Milliseconds 20
        }
        # The child has exited before either output drain is joined. Closing
        # the complete process tree on timeout also closes its inherited pipes.
        $text=$stderr.GetAwaiter().GetResult()
        if([string]::IsNullOrEmpty($OutputFile)){$text=$stdout.GetAwaiter().GetResult()+$text}
        else {$null=$stdout.GetAwaiter().GetResult()}
        if($null -ne $write -and !$timedOut -and $null -eq $inputFailure){
            try {$null=$write.GetAwaiter().GetResult()}catch {$inputFailure=$_.Exception.Message}
        }
        if($null -ne $inputFailure){$text+="`nInput stream failure: $inputFailure`n"}
        [IO.File]::WriteAllText($LogPath,$text,[Text.UTF8Encoding]::new($false))
        if($timedOut){throw "Native RM build tool exceeded $TimeoutSeconds seconds; see $LogPath"}
        if($null -ne $inputFailure -and $process.ExitCode -eq 0){throw "Native RM build tool did not consume its input; see $LogPath"}
        return $process.ExitCode
    } finally {
        if($null -ne $process){
            if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()}
            $process.Dispose()
        }
        if($null -ne $inputStream){$inputStream.Dispose()}
        if($null -ne $outputStream){$outputStream.Dispose()}
    }
}
