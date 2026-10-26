<#
.SYNOPSIS
    Copies StarCraft II audio extracted from your own game install into units/<race>/<unit>/<action>/.

.DESCRIPTION
    Blizzard's audio is not distributed with this tool. Extract the files you need from your own
    StarCraft II installation with CascView (https://www.zezula.net/en/casc/main.html) into the
    staging folder (default: tmp_assets/, ignored by git), keeping the path structure, then run:

        powershell -ExecutionPolicy Bypass -File .\import-sc2-audio.ps1
        python convert-to-ogg.py          # only needed when WAV files were imported
        powershell -ExecutionPolicy Bypass -File .\generate-registry.ps1

    The $importMap table below says which staged files go to which unit action folder. Patterns are
    PowerShell -like wildcards (* and ?) matched against the full path of each staged file, using
    backslashes. Files that are already in the destination are skipped, and entries without any
    staged file only produce a notice (extract them and run the script again).

.PARAMETER SourceRoot
    Staging folder with the CascView extraction (default: tmp_assets next to this script).
#>
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot 'tmp_assets')
)

$ErrorActionPreference = 'Stop'
$unitsRoot = Join-Path $PSScriptRoot 'units'

# Standard English unit voice lines live here (enUS tag in CascView):
$voice = '*\mods\liberty.sc2mod\enus.sc2assets\localizeddata\sounds\protossunitvo'

# target = '<race>/<unit>/<action>', patterns = staged files to copy there.
$importMap = @(
    # --- Protoss High Templar (TMG wave 3) ---
    @{ target = 'protoss/high_templar/deploy';        patterns = @("$voice\hightemplar\hightemplar_ready??.ogg",
                                                                   '*\campaigns\voidstory.sc2campaign\enus.sc2assets\localizeddata\sounds\vo\pmission_ulnar03_hightemplar_117.ogg') }  # extra mission line, picked by the maintainer
    @{ target = 'protoss/high_templar/move';          patterns = @("$voice\hightemplar\hightemplar_yes??.ogg") }
    @{ target = 'protoss/high_templar/psionic_storm'; patterns = @("$voice\hightemplar\hightemplar_psionicstorm??.ogg") }                    # voice: "Saraht tuun!"
    @{ target = 'protoss/high_templar/psionic_stormFX'; patterns = @('*\mods\liberty.sc2mod\base.sc2assets\assets\sounds\protoss\hightemplar\hightemplar_psionicstormimpact?.wav') }  # storm impact, played after the voice
    @{ target = 'protoss/high_templar/attack';        patterns = @("$voice\hightemplar\hightemplar_attack04.ogg", "$voice\hightemplar\hightemplar_attack06.ogg") }  # picked by the maintainer; no AttackLaunch file exists
    @{ target = 'protoss/high_templar/death';         patterns = @("$voice\hightemplar\hightemplar_death*.ogg", "$voice\hightemplar\hightemplar_death*.wav",
                                                                   "$voice\hightemplar\hightemplar_energylow00.ogg",                              # "low energy" line as an extra death line
                                                                   '*\campaigns\liberty.sc2campaign\enus.sc2assets\localizeddata\sounds\protossvo\campaignunits\karass\karass_death*.wav') }  # Karass is a campaign High Templar
)

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    Write-Error "Staging folder not found: $SourceRoot. Extract the game files with CascView first (see the script header)."
}

$staged = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File)
Write-Host "Staged files found in ${SourceRoot}: $($staged.Count)"

$stats = @{ copied = 0; skipped = 0; pending = 0 }
$wavCopied = $false

foreach ($entry in $importMap) {
    $matches = @($staged | Where-Object {
        $path = $_.FullName
        foreach ($pattern in $entry.patterns) { if ($path -like $pattern) { return $true } }
        return $false
    })
    if ($matches.Count -eq 0) {
        $stats.pending++
        Write-Host "  (nothing staged yet) $($entry.target)"
        continue
    }
    $targetDir = Join-Path $unitsRoot ($entry.target -replace '/', '\')
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }
    foreach ($file in $matches) {
        $destination = Join-Path $targetDir $file.Name
        $oggTwin = [System.IO.Path]::ChangeExtension($destination, '.ogg')
        if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $oggTwin)) { $stats.skipped++; continue }
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $stats.copied++
        if ($file.Extension -ieq '.wav') { $wavCopied = $true }
        Write-Host "  + units/$($entry.target)/$($file.Name)"
    }
}

if ($wavCopied) { Write-Host 'WAV files were copied. Run `python convert-to-ogg.py` to transcode them to OGG.' }
Write-Host "Done. Copied: $($stats.copied), skipped (already present): $($stats.skipped), entries with nothing staged: $($stats.pending)"
