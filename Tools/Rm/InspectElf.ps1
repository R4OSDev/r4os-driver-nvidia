# Bounded ELF64/LE ET_REL inspection for the explicit NVIDIA source build.
param([Parameter(Mandatory)][string]$InputFile,[Parameter(Mandatory)][string]$OutputFile)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$file=Get-Item -LiteralPath $InputFile
if($file.Length -lt 64 -or $file.Length -gt 256MB){throw 'Unexpected object extent'}
$data=[IO.File]::ReadAllBytes($file.FullName)
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class R4ElfRelocationCounter {
    public static Dictionary<uint,long> Count(byte[] data, long offset, long length, int stride) {
        var result = new Dictionary<uint,long>();
        for (long at = offset; at < offset + length; at += stride) {
            uint kind = BitConverter.ToUInt32(data, checked((int)(at + 8)));
            result.TryGetValue(kind, out long count);
            result[kind] = count + 1;
        }
        return result;
    }
}
'@
function Range([ulong]$Offset,[ulong]$Length){if($Offset -gt $data.Length -or $Length -gt $data.Length-$Offset){throw 'ELF range'}}
function U16([int]$Offset){Range $Offset 2;return [BitConverter]::ToUInt16($data,$Offset)}
function U32([int]$Offset){Range $Offset 4;return [BitConverter]::ToUInt32($data,$Offset)}
function U64([int]$Offset){Range $Offset 8;return [BitConverter]::ToUInt64($data,$Offset)}
function Name([ulong]$Base,[ulong]$Length,[uint]$Offset){
    if($Offset -ge $Length){throw 'ELF string offset'}
    $start=[int]($Base+$Offset);$end=$start;$limit=[Math]::Min($Base+$Length,$start+65536)
    while($end -lt $limit -and $data[$end] -ne 0){$end++}
    if($end -eq $limit){throw 'Unterminated ELF string'}
    return [Text.Encoding]::UTF8.GetString($data,$start,$end-$start)
}
if([Text.Encoding]::ASCII.GetString($data,0,4) -cne ([char]127+'ELF') -or $data[4] -ne 2 -or $data[5] -ne 1 -or (U16 16) -ne 1 -or (U16 18) -ne 62 -or (U16 58) -ne 64){throw 'Expected ELF64 LE x86_64 relocatable object'}
$offset=U64 40;$count=U16 60;$namesIndex=U16 62
if($count -eq 0 -or $namesIndex -ge $count){throw 'Extended or invalid section table'}
Range $offset ($count*64)
$sections=@()
for($index=0;$index -lt $count;$index++) {
    $entry=[int]($offset+$index*64)
    $section=[ordered]@{index=$index;name_offset=(U32 $entry);type=(U32 ($entry+4));flags=(U64 ($entry+8));offset=(U64 ($entry+24));bytes=(U64 ($entry+32));link=(U32 ($entry+40));info=(U32 ($entry+44));alignment=(U64 ($entry+48));entry_bytes=(U64 ($entry+56))}
    if($section.type -ne 8){Range $section.offset $section.bytes}
    $sections+=,$section
}
$strings=$sections[$namesIndex]
foreach($section in $sections){$section.name=Name $strings.offset $strings.bytes $section.name_offset}
$undefined=[Collections.Generic.List[object]]::new();$defined=[Collections.Generic.List[object]]::new();$relocations=@{};$allocatedRelocations=@{}
[long]$allocated=0;[long]$tlsBytes=0;$initializers=@()
foreach($section in $sections) {
    if($section.flags -band 2){$allocated+=$section.bytes}
    if($section.flags -band 1024){$tlsBytes+=$section.bytes}
    if($section.name -match '^\.(preinit_array|init_array|fini_array|ctors|dtors|init|fini)(\.|$)'){$initializers+=[ordered]@{name=$section.name;bytes=$section.bytes}}
    if($section.type -eq 2) {
        if($section.entry_bytes -ne 24 -or $section.bytes%24 -ne 0 -or $section.link -ge $count){throw 'Invalid symbol table'}
        $names=$sections[$section.link]
        for($at=[long]$section.offset;$at -lt $section.offset+$section.bytes;$at+=24) {
            $binding=$data[$at+4] -shr 4
            if($binding -eq 0){continue}
            $symbol=[ordered]@{name=(Name $names.offset $names.bytes (U32 $at));binding=$binding;type=($data[$at+4] -band 15);visibility=($data[$at+5] -band 3);section=(U16 ($at+6));bytes=(U64 ($at+16))}
            if($symbol.section -eq 0){$undefined.Add($symbol)}else{$defined.Add($symbol)}
        }
    }
    if($section.type -in @(4,9)) {
        $stride=if($section.type -eq 4){24}else{16}
        if($section.entry_bytes -ne $stride -or $section.bytes%$stride -ne 0){throw 'Invalid relocation table'}
        if($section.info -ge $count){throw 'Relocation target outside section table'}
        $counts=[R4ElfRelocationCounter]::Count($data,$section.offset,$section.bytes,$stride)
        foreach($entry in $counts.GetEnumerator()) {
            $key=[string]$entry.Key
            if(!$relocations.ContainsKey($key)){$relocations[$key]=0};$relocations[$key]+=$entry.Value
            if($sections[$section.info].flags -band 2){if(!$allocatedRelocations.ContainsKey($key)){$allocatedRelocations[$key]=0};$allocatedRelocations[$key]+=$entry.Value}
        }
    }
}
$result=[ordered]@{schema=1;file=$file.Name;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();section_count=$count;allocated_section_bytes_before_R4M0_layout=$allocated;tls_bytes=$tlsBytes;initializer_sections=$initializers;relocation_types=$relocations;allocated_relocation_types=$allocatedRelocations;undefined_count=$undefined.Count;defined_count=$defined.Count;undefined=@($undefined|Sort-Object {$_['name']});defined=@($defined|Sort-Object {$_['name']})}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputFile),($result|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
Write-Host "$($file.Name): $($undefined.Count) undefined, $($defined.Count) global/weak definitions; TLS=$tlsBytes bytes, initializer sections=$($initializers.Count)"
