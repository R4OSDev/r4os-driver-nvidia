# Driver-private, lock-ordered boot bundles. Original signed bytes and notices
# are unchanged. No runtime directory or generic container ABI is introduced.
param([Parameter(Mandatory)][string]$LockPath,
      [Parameter(Mandatory)][string]$GenerationDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'FirmwarePackage.ps1')
$pin=Get-Content -Raw -LiteralPath $LockPath|ConvertFrom-Json
foreach($profile in $pin.boot_generations){
    if($profile.name -cnotmatch '^(ad102|tu102|tu116)$'){throw 'Unsupported boot generation'}
    $directory=Join-Path $GenerationDirectory $profile.name
    $entries=@(
        foreach($artifact in @($profile.boot.image,$profile.boot.descriptor,$profile.boot.license)){
            @{artifact=$artifact;path=Join-Path $directory ('gsp/'+$artifact.resource)}
        }
        foreach($booter in $profile.booters){
            foreach($field in @('image','header','signatures','patch_location','patch_signature','patch_metadata','signature_count')){
                $artifact=$booter.$field
                @{artifact=$artifact;path=Join-Path $directory ('booter/'+$artifact.resource)}
            }
        }
        @{artifact=$profile.booter_license.artifact;path=Join-Path $directory ('booter/'+$profile.booter_license.artifact.resource)}
    )
    if($entries.Count -ne 18 -or $profile.pack.bytes -le 0 -or $profile.pack.bytes -gt 2MB -or
       $profile.pack.resource -cne ('NVIDIA-570.144-'+$profile.name.ToUpperInvariant()+'-BOOT-PACK.bin')){throw 'Invalid boot pack schema'}
    $stream=[IO.MemoryStream]::new()
    try {
        foreach($entry in $entries){
            Test-NvidiaFirmwareArtifact $entry.path $entry.artifact
            while($stream.Length % 16){$stream.WriteByte(0)}
            if($stream.Length+$entry.artifact.bytes -gt $profile.pack.bytes){throw 'Boot pack exceeds pinned extent'}
            $bytes=[IO.File]::ReadAllBytes($entry.path)
            $stream.Write($bytes,0,$bytes.Length)
        }
        $bytes=$stream.ToArray()
        if($bytes.Length -ne $profile.pack.bytes -or
           [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $profile.pack.sha256){throw 'Boot pack hash mismatch'}
        $target=Join-Path $directory $profile.pack.resource
        if(!(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $profile.pack.sha256){
            [IO.File]::WriteAllBytes($target,$bytes)
        }
        Test-NvidiaFirmwareArtifact $target $profile.pack
    } finally {$stream.Dispose()}
}
Write-Host 'NVIDIA generation boot bundles: exact original files, licenses and aligned ranges verified.'
