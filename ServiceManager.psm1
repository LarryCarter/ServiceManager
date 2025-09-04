using namespace System.IO
using namespace System.Collections.Generic
#requires -Version 5.1
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Reusable service management helpers (config, safety checks, paging edits, logging, monitoring).
#>

#region Configuration

function Import-ServiceConfiguration {
    <#
    .SYNOPSIS  Load and minimally validate the JSON configuration.
    .PARAMETER Path  Path to services.config.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$Path
    )
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to read or parse config JSON at '$Path'. $($_.Exception.Message)"
    }

    foreach ($k in 'Prefix','Core','Profiles','Exceptions','Paging') {
        if (-not $cfg.PSObject.Properties.Name.Contains($k)) { throw "Config missing required key '$k'." }
    }
    if ([string]::IsNullOrWhiteSpace($cfg.Prefix)) { throw "Config.Prefix must be non-empty." }

    return $cfg
}

function Resolve-ServiceConfiguration {
    <#
    .SYNOPSIS  Normalize Core/Profile/Exceptions and surface misconfig issues (prefix & overlaps).
    .PARAMETER Config  The raw config object
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Config)

    $prefix = $Config.Prefix

    $core = @($Config.Core.Services | ForEach-Object { $_.Name })
    $profiles = @{}
    foreach ($p in $Config.Profiles.PSObject.Properties) {
        $profiles[$p.Name] = @($p.Value.Services | ForEach-Object { $_.Name })
    }
    $exceptions = @($Config.Exceptions.Services | ForEach-Object { $_.Name })

    $issues = [List[string]]::new()
    foreach ($s in $core) {
        if ($s -notlike "$prefix*") { $issues.Add("Core service '$s' does not match Prefix '$prefix' → will warn & skip at runtime.") }
    }
    foreach ($kv in $profiles.GetEnumerator()) {
        $pname = $kv.Key; $list = $kv.Value
        foreach ($s in $list) {
            if ($s -notlike "$prefix*") { $issues.Add("Profile '$pname' service '$s' does not match Prefix '$prefix' → will warn & skip at runtime.") }
            if ($core -contains $s) { $issues.Add("Service '$s' appears in Core and Profile '$pname' → will be skipped from Profile at runtime.") }
        }
    }

    [pscustomobject]@{
        Prefix     = $prefix
        Core       = $core
        Profiles   = $profiles
        Exceptions = $exceptions
        Issues     = $issues
        Raw        = $Config
    }
}

#endregion

#region Service discovery & safety

function Get-ServiceDetails {
    <#
    .SYNOPSIS  Return current state & start mode for the given services (via CIM).
    .PARAMETER ServiceNames  Names to query
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ServiceNames)

    $nameSet = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ServiceNames | ForEach-Object { [void]$nameSet.Add($_) }

    try {
        $all = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $nameSet.Contains($_.Name) }
    } catch {
        throw "Failed to query Win32_Service: $($_.Exception.Message)"
    }

    $items = foreach ($s in $all) {
        [pscustomobject]@{
            Name       = $s.Name
            Display    = $s.DisplayName
            State      = $s.State       # Running/Stopped
            StartMode  = $s.StartMode   # Auto/Manual/Disabled
            Status     = $s.Status
            ProcessId  = $s.ProcessId
        }
    }

    $found = $items.Name
    foreach ($n in $ServiceNames | Where-Object { $_ -notin $found }) {
        [pscustomobject]@{
            Name       = $n
            Display    = $null
            State      = 'NotFound'
            StartMode  = 'Unknown'
            Status     = 'NotFound'
            ProcessId  = $null
        }
    }
}

function Get-PrefixedServices {
    <#
    .SYNOPSIS  Return names of installed services that match the prefix.
    .PARAMETER Prefix  The service name prefix
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prefix)
    try {
        return (Get-Service -Name "$Prefix*" -ErrorAction Stop | Select-Object -ExpandProperty Name)
    } catch {
        return @()
    }
}

function Test-ServiceEligibility {
    <#
    .SYNOPSIS  Enforce safety rules (prefix, startup type, exceptions).
    .PARAMETER ServiceName
    .PARAMETER Prefix
    .PARAMETER IsException
    .PARAMETER StartMode  Auto/Automatic/Manual/Disabled/Unknown
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][bool]$IsException,
        [Parameter(Mandatory)][string]$StartMode
    )

    $eligible = $false
    $requiresPrompt = $false
    $reason = $null

    if ($IsException) {
        # Exceptions: always prompt; Disabled → skip; Automatic allowed with confirmation.
        $requiresPrompt = $true
        if ($StartMode -match '^(Disabled)$') { $eligible = $false; $reason = 'Disabled (Exception → warn & skip)' }
        elseif ($StartMode -match '^(Auto|Automatic)$') { $eligible = $true; $reason = 'Automatic & in Exceptions (confirm)' }
        else { $eligible = $true; $reason = 'In Exceptions (confirm)' }
        return [pscustomobject]@{ Eligible=$eligible; RequiresPrompt=$requiresPrompt; Reason=$reason }
    }

    # Non-exceptions must be prefixed & Manual; Automatic skipped; Disabled skipped.
    if ($ServiceName -notlike "$Prefix*") { return [pscustomobject]@{ Eligible=$false; RequiresPrompt=$false; Reason='Not prefixed (skip)' } }

    switch -Regex ($StartMode) {
        '^(Manual)$'           { $eligible=$true;  $reason='Manual (eligible)'; break }
        '^(Disabled)$'         { $eligible=$false; $reason='Disabled (skip)'; break }
        '^(Auto|Automatic)$'   { $eligible=$false; $reason='Automatic (skip unless Exception)'; break }
        default                { $eligible=$false; $reason='Unknown StartMode (skip)'; break }
    }
    [pscustomobject]@{ Eligible=$eligible; RequiresPrompt=$requiresPrompt; Reason=$reason }
}

#endregion

#region Actions & paging

function Write-ServiceLog {
    <#
    .SYNOPSIS  Append a line to the operation log (and emit verbose/warn/error to console).
    .PARAMETER LogFile
    .PARAMETER Message
    .PARAMETER Level  INFO/WARN/ERROR (for console only; log format remains "DateTime:: Message")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO'
    )
    $line = '{0}:: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error $Message }
        default { Write-Verbose $Message -Verbose }
    }
}

function Invoke-ServiceOperation {
    <#
    .SYNOPSIS  Idempotent Start/Stop/Restart with WhatIf logging and Restart→Start fallback.
    .PARAMETER ServiceName
    .PARAMETER Action  Start|Stop|Restart
    .PARAMETER LogFile
    .PARAMETER Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][ValidateSet('Start','Stop','Restart')][string]$Action,
        [Parameter(Mandatory)][string]$LogFile,
        [switch]$Force
    )

    if (-not $PSCmdlet.ShouldProcess($ServiceName, $Action)) {
        Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Skipped (WhatIf/Confirm)" -f $ServiceName)
        return [pscustomobject]@{ Service=$ServiceName; Action=$Action; Success=$false; Result='WhatIf'; Message='Skipped (WhatIf/Confirm)' }
    }

    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction Stop

        switch ($Action) {
            'Start' {
                if ($svc.Status -eq 'Running') {
                    Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Skipped (Already Running)" -f $ServiceName)
                    return [pscustomobject]@{ Service=$ServiceName; Action=$Action; Success=$true; Result='NoChange'; Message='Already Running' }
                }
                Start-Service -Name $ServiceName -ErrorAction Stop
                Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Started" -f $ServiceName)
            }
            'Stop' {
                if ($svc.Status -eq 'Stopped') {
                    Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Skipped (Already Stopped)" -f $ServiceName)
                    return [pscustomobject]@{ Service=$ServiceName; Action=$Action; Success=$true; Result='NoChange'; Message='Already Stopped' }
                }
                if ($Force) { Stop-Service -Name $ServiceName -Force -ErrorAction Stop }
                else { Stop-Service -Name $ServiceName -ErrorAction Stop }
                Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Stopped" -f $ServiceName)
            }
            'Restart' {
                # Restart→Start fallback for stopped services
                $svc = Get-Service -Name $ServiceName -ErrorAction Stop
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name $ServiceName -ErrorAction Stop
                    Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Start (was Stopped)" -f $ServiceName)
                } else {
                    if ($Force) { Restart-Service -Name $ServiceName -Force -ErrorAction Stop }
                    else { Restart-Service -Name $ServiceName -ErrorAction Stop }
                    Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Restarted" -f $ServiceName)
                }
            }
        }
        [pscustomobject]@{ Service=$ServiceName; Action=$Action; Success=$true; Result='Success'; Message='OK' }
    } catch {
        Write-ServiceLog -LogFile $LogFile -Message ("{0}: Status: Failed ({1})" -f $ServiceName, $_.Exception.Message) -Level ERROR
        [pscustomobject]@{ Service=$ServiceName; Action=$Action; Success=$false; Result='Error'; Message=$_.Exception.Message }
    }
}

function Update-PagingConfiguration {
    <#
    .SYNOPSIS  Update OFFSET (and optionally FETCH NEXT) in appsettings JSON with backup & WhatIf support.
    .PARAMETER AppSettingsPath
    .PARAMETER JsonKey
    .PARAMETER PagingAction  NextPage|PreviousPage|RestartFromPage1|NoChange|PrevPage
    .PARAMETER PageSize
    .PARAMETER EnforceFetchNextToPageSize
    .PARAMETER LogFile
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$AppSettingsPath,
        [Parameter(Mandatory)][string]$JsonKey,
        [Parameter(Mandatory)][ValidateSet('NextPage','PreviousPage','RestartFromPage1','NoChange','PrevPage')][string]$PagingAction,
        [Parameter(Mandatory)][int]$PageSize,
        [Parameter(Mandatory)][bool]$EnforceFetchNextToPageSize,
        [Parameter(Mandatory)][string]$LogFile
    )

    if ($PagingAction -eq 'NoChange') {
        return [pscustomobject]@{ Success=$true; Changed=$false; OldOffset=$null; NewOffset=$null; BackupPath=$null }
    }
    if ($PagingAction -eq 'PrevPage') { $PagingAction = 'PreviousPage' }

    if (-not (Test-Path -LiteralPath $AppSettingsPath)) {
        Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: File not found: {0}" -f $AppSettingsPath) -Level WARN
        return [pscustomobject]@{ Success=$false; Changed=$false; Error='File not found' }
    }

    try {
        $json = Get-Content -LiteralPath $AppSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $json.PSObject.Properties.Name.Contains($JsonKey)) {
            Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: Key '{0}' not found in {1}" -f $JsonKey, $AppSettingsPath) -Level WARN
            return [pscustomobject]@{ Success=$false; Changed=$false; Error='Key not found' }
        }
        $query = [string]$json.$JsonKey

        $offsetPat = 'OFFSET\s+(?<offset>\d+)\s+ROWS'
        $m = [regex]::Match($query, $offsetPat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) {
            Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: OFFSET pattern not found in query for key '{0}'." -f $JsonKey) -Level WARN
            return [pscustomobject]@{ Success=$false; Changed=$false; Error='OFFSET not found' }
        }

        $old = [int]$m.Groups['offset'].Value
        $new = switch ($PagingAction) {
            'NextPage'         { $old + $PageSize }
            'PreviousPage'     { [Math]::Max(0, $old - $PageSize) }
            'RestartFromPage1' { 0 }
            default            { $old }
        }

        $newQuery = [regex]::Replace($query, $offsetPat, ("OFFSET {0} ROWS" -f $new), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if ($EnforceFetchNextToPageSize) {
            $fetchPat = 'FETCH\s+NEXT\s+\d+\s+ROWS\s+ONLY'
            if ([regex]::IsMatch($newQuery, $fetchPat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $newQuery = [regex]::Replace($newQuery, $fetchPat, ("FETCH NEXT {0} ROWS ONLY" -f $PageSize), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            } else {
                $newQuery = ($newQuery.TrimEnd() + " FETCH NEXT $PageSize ROWS ONLY")
            }
        }

        if (-not $PSCmdlet.ShouldProcess($AppSettingsPath, "Update OFFSET $old -> $new")) {
            Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: Skipped (WhatIf) File={0} Key={1} Old=""{2}"" New=""{3}""" -f $AppSettingsPath, $JsonKey, $query, $newQuery)
            return [pscustomobject]@{ Success=$true; Changed=$false; OldOffset=$old; NewOffset=$new; WhatIf=$true }
        }

        $backup = "{0}.bak.{1}" -f $AppSettingsPath, (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item -LiteralPath $AppSettingsPath -Destination $backup -Force
        $json.$JsonKey = $newQuery
        $json | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $AppSettingsPath -Encoding UTF8

        Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: File={0} Key={1} Old=""{2}"" New=""{3}"" Backup=""{4}""" -f $AppSettingsPath, $JsonKey, $query, $newQuery, $backup)
        [pscustomobject]@{ Success=$true; Changed=$true; OldOffset=$old; NewOffset=$new; BackupPath=$backup; OldQuery=$query; NewQuery=$newQuery }
    } catch {
        Write-ServiceLog -LogFile $LogFile -Message ("ConfigUpdate: Failed ({0})" -f $_.Exception.Message) -Level ERROR
        [pscustomobject]@{ Success=$false; Changed=$false; Error=$_.Exception.Message }
    }
}

#endregion

#region State & logging setup

function Get-ServiceManagerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{ LastProfile=$null; LastRun=$null }
    }
    try {
        $s = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        [pscustomobject]@{ LastProfile=$s.LastProfile; LastRun=$s.LastRun }
    } catch {
        [pscustomobject]@{ LastProfile=$null; LastRun=$null }
    }
}

function Set-ServiceManagerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [string]$LastProfile,
        [datetime]$LastRun = (Get-Date)
    )
    $dir = Split-Path -Path $StatePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]@{ LastProfile=$LastProfile; LastRun=$LastRun.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function New-LogFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogRoot)
    $dateDir = Join-Path -Path $LogRoot -ChildPath (Get-Date -Format 'yyyy-MM-dd')
    if (-not (Test-Path -LiteralPath $dateDir)) { New-Item -ItemType Directory -Path $dateDir -Force | Out-Null }
    $file = Join-Path -Path $dateDir -ChildPath ("ServiceManager_{0}.log" -f (Get-Date -Format 'HHmmss'))
    New-Item -ItemType File -Path $file -Force | Out-Null
    $file
}

#endregion

#region Log discovery & tail

function Get-LatestServiceLogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceLogRoot,
        [Parameter(Mandatory)][string]$LogLocation,
        [Parameter(Mandatory)][string]$ServiceName
    )
    $root = $ServiceLogRoot.TrimEnd('\','/')
    $loc  = $LogLocation.TrimStart('\','/')
    $dir  = if ([string]::IsNullOrWhiteSpace($loc)) { $root } else { Join-Path $root $loc }
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $files = Get-ChildItem -LiteralPath $dir -Filter ("{0}*.log" -f $ServiceName) -File | Sort-Object LastWriteTime -Descending
    if ($files.Count -gt 0) { $files[0].FullName } else { $null }
}

function Start-ServiceLogMonitoring {
    <#
    .SYNOPSIS  Tail logs for processed services (separate windows for MonitorSeparate; combined otherwise).
    .PARAMETER Services  Array of config service objects (Name, LogLocation, MonitorSeparate)
    .PARAMETER ServiceLogRoot
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Services,
        [Parameter(Mandatory)][string]$ServiceLogRoot
    )
    $separate = New-Object System.Collections.Generic.List[string]
    $combined = New-Object System.Collections.Generic.List[string]

    foreach ($svc in $Services) {
        if (-not $svc.LogLocation) { continue }
        $lf = Get-LatestServiceLogFile -ServiceLogRoot $ServiceLogRoot -LogLocation $svc.LogLocation -ServiceName $svc.Name
        if (-not $lf) { continue }
        if ($svc.MonitorSeparate -eq $true) { [void]$separate.Add($lf) } else { [void]$combined.Add($lf) }
    }

    foreach ($file in $separate) {
        $tmp = [IO.Path]::Combine($env:TEMP, ("tail-{0}.ps1" -f ([guid]::NewGuid())))
@"
`$f = '$file'
Write-Host "Tailing: `$f" -ForegroundColor Cyan
if (Test-Path -LiteralPath `$f) { Get-Content -LiteralPath `$f -Tail 50 -Wait } else { Write-Host "File not found: `$f"; pause }
"@ | Set-Content -LiteralPath $tmp -Encoding UTF8
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit","-ExecutionPolicy","Bypass","-File","`"$tmp`""
    }

    if ($combined.Count -gt 0) {
        $tmp2 = [IO.Path]::Combine($env:TEMP, ("tail-combined-{0}.ps1" -f ([guid]::NewGuid())))
        $filesList = ($combined | ForEach-Object { "'{0}'" -f $_ }) -join ','
@"
`$files = @($filesList)
`$jobs = foreach(`$f in `$files){
  Start-Job -ScriptBlock { param(`$pf)
    if (Test-Path -LiteralPath `$pf){
      Get-Content -LiteralPath `$pf -Tail 50 -Wait | ForEach-Object { "[" + (Split-Path -Leaf `$pf) + "] " + `$_ }
    } else { "File not found: `$pf" }
  } -ArgumentList `$f
}
Write-Host "Combined tail started for $($combined.Count) files." -ForegroundColor Cyan
while($true){ Receive-Job -Job `$jobs -Keep | Out-Host; Start-Sleep -Milliseconds 250 }
"@ | Set-Content -LiteralPath $tmp2 -Encoding UTF8
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit","-ExecutionPolicy","Bypass","-File","`"$tmp2`""
    }
}

#endregion

Export-ModuleMember -Function *-*
