# Shared artifact admission for explicit provisioning and module builds.
function Test-NvidiaFirmwareArtifact([string]$Path,$Artifact) {
    foreach($name in @($Artifact.file,$Artifact.resource)) {
        if([string]::IsNullOrEmpty($name) -or $name.Length -gt 63 -or
           $name -match '[^\x21-\x7e]|[\\/:]' -or $name -in @('.','..')) {throw 'Invalid artifact name in lock.'}
    }
    $file=Get-Item -LiteralPath $Path
    if($file.PSIsContainer -or $file.Length -ne $Artifact.bytes -or
       (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Artifact.sha256) {
        throw "Firmware package size/hash mismatch: $Path"
    }
}
