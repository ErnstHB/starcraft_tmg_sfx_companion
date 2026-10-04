$rootPath = $PSScriptRoot
$registry = [ordered]@{
    ost = [ordered]@{
        starcraft1 = [ordered]@{ protoss = @(); terran = @(); zerg = @() }
        starcraft2 = [ordered]@{ protoss = @(); terran = @(); zerg = @() }
    }
    units = [ordered]@{ protoss = [ordered]@{}; terran = [ordered]@{}; zerg = [ordered]@{} }
    # Optional StarCraft I audio bank: units/<race>/<unit>/sc1/<action>/. Same action names as `units`.
    unitsSC1 = [ordered]@{ protoss = [ordered]@{}; terran = [ordered]@{}; zerg = [ordered]@{} }
    unitConfigs = [ordered]@{ protoss = [ordered]@{}; terran = [ordered]@{}; zerg = [ordered]@{} }
}
$sc1FolderName = 'sc1'

function Get-ConfigScalar([string]$value) {
    $value = $value.Trim()
    if ($value -eq 'null') { return $null }
    if ($value.StartsWith('"')) { return ($value | ConvertFrom-Json) }
    return $value
}

function Read-UnitConfig([string]$path) {
    $config = [ordered]@{
        unit = [ordered]@{}
        regular_abilities = [ordered]@{}
        additional_abilities = [ordered]@{}
    }
    $section = ''
    $ability = ''

    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^(unit|regular_abilities|additional_abilities):\s*$') {
            $section = $Matches[1]
            $ability = ''
            continue
        }
        if ($line -match '^  ([a-zA-Z0-9_-]+):\s*$' -and $section -ne 'unit') {
            $ability = $Matches[1]
            $config[$section][$ability] = [ordered]@{ sound_sources = @() }
            continue
        }
        if ($section -eq 'unit' -and $line -match '^  ([a-zA-Z0-9_-]+):\s*(.*?)\s*$') {
            $config.unit[$Matches[1]] = Get-ConfigScalar $Matches[2]
            continue
        }
        if ($ability -and $line -match '^    button_size:\s*(\d+)\s*$') {
            $config[$section][$ability].button_size = [int]$Matches[1]
            continue
        }
        if ($ability -and $line -match '^    playback:\s*([a-zA-Z_-]+)\s*$') {
            $config[$section][$ability].playback = $Matches[1]
            continue
        }
        if ($ability -and $line -match '^    sound_sources:\s*\[(.*?)\]\s*$') {
            $sources = @()
            if ($Matches[1].Trim()) { $sources = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() }) }
            $config[$section][$ability].sound_sources = $sources
        }
    }

    if (-not $config.unit.name -or -not $config.unit.role) {
        throw "Missing unit name or role in config: $path"
    }
    return $config
}

# Scan soundtrack files.
$ostRoot = Join-Path $rootPath 'ost'
if (Test-Path -LiteralPath $ostRoot) {
    Get-ChildItem -LiteralPath $ostRoot -File -Recurse | ForEach-Object {
        if ($_.Extension.ToLower() -in @('.wav', '.ogg', '.mp3')) {
            $relPath = $_.FullName.Substring($rootPath.Length + 1).Replace([string][char]92, '/')
            $parts = $relPath.Split('/')
            if ($parts.Count -ge 4) {
                $ver = $parts[1]
                $race = $parts[2]
                if ($registry.ost.Contains($ver) -and $registry.ost[$ver].Contains($race)) {
                    $registry.ost[$ver][$race] += $relPath
                }
            }
        }
    }
}

# Scan sound files and require a config for each unit.
$unitsRoot = Join-Path $rootPath 'units'
foreach ($raceDir in Get-ChildItem -LiteralPath $unitsRoot -Directory) {
    $race = $raceDir.Name
    if (-not $registry.units.Contains($race)) { throw "Unsupported unit faction folder: $race" }
    foreach ($unitDir in Get-ChildItem -LiteralPath $raceDir.FullName -Directory) {
        $unit = $unitDir.Name
        $configPath = Join-Path $unitDir.FullName 'config.yaml'
        if (-not (Test-Path -LiteralPath $configPath)) {
            throw "Missing config.yaml for units/$race/$unit. Add the unit config before building the registry."
        }
        $registry.unitConfigs[$race][$unit] = Read-UnitConfig $configPath
        $registry.units[$race][$unit] = [ordered]@{}
    }
}

Get-ChildItem -LiteralPath $unitsRoot -File -Recurse | ForEach-Object {
    if ($_.Extension.ToLower() -in @('.wav', '.ogg', '.mp3')) {
        $relPath = $_.FullName.Substring($rootPath.Length + 1).Replace([string][char]92, '/')
        $parts = $relPath.Split('/')
        if ($parts.Count -ge 5) {
            $race = $parts[1]
            $unit = $parts[2]
            $isSC1 = $parts[3] -eq $sc1FolderName
            if ($isSC1 -and $parts.Count -lt 6) { return }
            $action = if ($isSC1) { $parts[4] } else { $parts[3] }
            $bank = if ($isSC1) { $registry.unitsSC1 } else { $registry.units }
            if ($registry.units[$race] -and $registry.units[$race].Contains($unit)) {
                if ($isSC1 -and -not $bank[$race].Contains($unit)) {
                    $bank[$race][$unit] = [ordered]@{}
                }
                if (-not $bank[$race][$unit].Contains($action)) {
                    $bank[$race][$unit][$action] = @()
                }
                $bank[$race][$unit][$action] += $relPath
            }
        }
    }
}

# Validate every configured sound source resolves to at least one audio file.
foreach ($race in $registry.unitConfigs.Keys) {
    foreach ($unit in $registry.unitConfigs[$race].Keys) {
        foreach ($section in @('regular_abilities', 'additional_abilities')) {
            foreach ($ability in $registry.unitConfigs[$race][$unit][$section].Keys) {
                $sources = @($registry.unitConfigs[$race][$unit][$section][$ability].sound_sources)
                if ($sources.Count -eq 0) { throw "Ability '$ability' has no sound_sources in units/$race/$unit/config.yaml" }
                foreach ($source in $sources) {
                    if (-not $registry.units[$race][$unit].Contains($source) -or $registry.units[$race][$unit][$source].Count -eq 0) {
                        throw "Sound source '$source' for ability '$ability' has no audio files in units/$race/$unit/"
                    }
                }
                if ($sources.Count -gt 1 -and $registry.unitConfigs[$race][$unit][$section][$ability].playback -notin @('simultaneous', 'sequential')) {
                    throw "Ability '$ability' in units/$race/$unit/config.yaml needs playback: simultaneous or sequential because it has multiple sound sources."
                }
            }
        }
    }
}

# SC1 folders are optional overrides, so only warn when one does not match any configured sound source (likely a typo).
$sc1FileCount = 0
foreach ($race in $registry.unitsSC1.Keys) {
    foreach ($unit in $registry.unitsSC1[$race].Keys) {
        $configuredSources = @()
        foreach ($section in @('regular_abilities', 'additional_abilities')) {
            foreach ($ability in $registry.unitConfigs[$race][$unit][$section].Values) { $configuredSources += @($ability.sound_sources) }
        }
        foreach ($action in $registry.unitsSC1[$race][$unit].Keys) {
            $sc1FileCount += $registry.unitsSC1[$race][$unit][$action].Count
            if ($action -notin $configuredSources) {
                Write-Warning "units/$race/$unit/$sc1FolderName/$action is not referenced by any sound_sources in config.yaml and will never play."
            }
        }
    }
}

$json = $registry | ConvertTo-Json -Depth 30
$jsContent = "// Automatically generated by generate-registry.ps1. Do not modify manually.`nwindow.AUDIO_REGISTRY = $json;`n"
[System.IO.File]::WriteAllText((Join-Path $rootPath 'audio-registry.js'), $jsContent, [System.Text.UTF8Encoding]::new($false))
$sc1UnitCount = $registry.unitsSC1.protoss.Count + $registry.unitsSC1.terran.Count + $registry.unitsSC1.zerg.Count
Write-Host "audio-registry.js generated with configs for $($registry.unitConfigs.protoss.Count + $registry.unitConfigs.terran.Count + $registry.unitConfigs.zerg.Count) units ($sc1UnitCount with an SC1 bank, $sc1FileCount SC1 files)."
