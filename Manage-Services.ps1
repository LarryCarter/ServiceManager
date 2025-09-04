#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'CoreOperation')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\services.config.json'),

    [Parameter(Mandatory = $true, ParameterSetName = 'CoreOperation')]
    [Parameter(Mandatory = $true, ParameterSetName = 'ProfileOperation')]
    [ValidateSet('Start','Stop','Restart')]
    [string]$Action,

    [Parameter(Mandatory = $true, ParameterSetName = 'CoreOperation')]
    [ValidateSet('Core')]
    [string]$Operation = 'Core',

    [Parameter(Mandatory = $true, ParameterSetName = 'ProfileOperation')]
    [ValidateSet('Profile')]
    [string]$ProfileOperation = 'Profile',

    [Parameter(Mandatory = $true, ParameterSetName = 'ProfileOperation')]
    [ValidateNotNullOrEmpty()]
    [string]$ProfileName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('NextPage','PreviousPage','RestartFromPage1','NoChange','PrevPage')]
    [string]$PagingAction = 'NoChange',

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = (Join-Path $PSScriptRoot 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load module
$modulePath = Join-Path $PSScriptRoot 'ServiceManager.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "ServiceManager module not found at $modulePath"
}
Import-Module $modulePath -Force

try {
    # Initialize logging
    $logFile = New-LogFile -LogRoot $LogRoot

    $opHuman = if ($PSCmdlet.ParameterSetName -eq 'ProfileOperation') {
        "Profile:$ProfileName"
    } else {
        "Core Only"
    }
    Write-ServiceLog -LogFile $logFile -Message ("Operation:: {0} Action:: {1}" -f $opHuman, $Action)

    # Load & resolve configuration
    $cfg = Import-ServiceConfiguration -Path $ConfigPath
    $res = Resolve-ServiceConfiguration -Config $cfg

    foreach ($issue in $res.Issues) {
        Write-ServiceLog -LogFile $logFile -Message ("ConfigIssue:: {0}" -f $issue) -Level WARN
    }

    # State path
    $statePath = "$ConfigPath.state.json"
    $state = Get-ServiceManagerState -StatePath $statePath

    # Profile change → reset paging (if configured)
    $profileChanged = $false
    if (
        $PSCmdlet.ParameterSetName -eq 'ProfileOperation' -and
        $cfg.Paging.ResetOffsetOnProfileChange -and
        $state.LastProfile -and
        ($state.LastProfile -ne $ProfileName)
    ) {
        $profileChanged = $true
        Write-ServiceLog -LogFile $logFile -Message ("Profile changed from '{0}' to '{1}' - resetting paging offset" -f $state.LastProfile, $ProfileName)

        $r = Update-PagingConfiguration -AppSettingsPath $cfg.Paging.AppSettingsPath `
                                        -JsonKey $cfg.Paging.JsonKey `
                                        -PagingAction 'RestartFromPage1' `
                                        -PageSize $cfg.Paging.PageSize `
                                        -EnforceFetchNextToPageSize $cfg.Paging.EnforceFetchNextToPageSize `
                                        -LogFile $logFile
        if ($r.Success -and $r.Changed) {
            Write-ServiceLog -LogFile $logFile -Message ("Paging:: Service={0} OldOffset={1} NewOffset={2} PageSize={3}" -f $cfg.Paging.ServiceName, $r.OldOffset, $r.NewOffset, $cfg.Paging.PageSize)
        }
    }

    # Explicit paging action (optional)
    if ($PagingAction -ne 'NoChange') {
        Write-ServiceLog -LogFile $logFile -Message ("Paging:: Action={0}" -f $PagingAction)

        $r = Update-PagingConfiguration -AppSettingsPath $cfg.Paging.AppSettingsPath `
                                        -JsonKey $cfg.Paging.JsonKey `
                                        -PagingAction $PagingAction `
                                        -PageSize $cfg.Paging.PageSize `
                                        -EnforceFetchNextToPageSize $cfg.Paging.EnforceFetchNextToPageSize `
                                        -LogFile $logFile
        if ($r.Success -and $r.Changed) {
            Write-ServiceLog -LogFile $logFile -Message ("Paging:: Service={0} OldOffset={1} NewOffset={2} PageSize={3}" -f $cfg.Paging.ServiceName, $r.OldOffset, $r.NewOffset, $cfg.Paging.PageSize)
        } elseif (-not $r.Success) {
            Write-ServiceLog -LogFile $logFile -Message ("Paging update failed: {0}" -f $r.Error) -Level WARN
        }
    }

    # Determine service sets
    $exceptions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $res.Exceptions | ForEach-Object { [void]$exceptions.Add($_) }

    $targetNames = @()
    $stopOthers  = @()

    if ($PSCmdlet.ParameterSetName -eq 'CoreOperation') {
        $targetNames = $res.Core
    } else {
        if (-not $res.Profiles.ContainsKey($ProfileName)) {
            throw "Profile '$ProfileName' not found. Available profiles: $($res.Profiles.Keys -join ', ')"
        }

        $profileNames = $res.Profiles[$ProfileName]

        # Stop-Others: all prefixed services not in Core and not in this profile
        $installed = Get-PrefixedServices -Prefix $res.Prefix
        $stopOthers = $installed | Where-Object { ($_ -notin $res.Core) -and ($_ -notin $profileNames) }

        # Targets: profile services, but SKIP any that overlap with Core (hard rule)
        $targetNames = $profileNames | Where-Object { $_ -notin $res.Core }
        foreach ($dup in ($profileNames | Where-Object { $_ -in $res.Core })) {
            Write-ServiceLog -LogFile $logFile -Message ("{0}: Status: Skipped (Also in Core)" -f $dup) -Level WARN
        }
    }

    # Add paging service restart if paging changed or profile switched
    $pagingRestart = @()
    if ($profileChanged -or $PagingAction -ne 'NoChange') {
        if ($cfg.Paging.ServiceName) { $pagingRestart = @($cfg.Paging.ServiceName) }
    }

    # Collect details
    $allNames = ($stopOthers + $targetNames + $pagingRestart) | Sort-Object -Unique
    $details = @{}
    if ($allNames.Count -gt 0) {
        foreach ($d in (Get-ServiceDetails -ServiceNames $allNames)) {
            $details[$d.Name] = $d
        }
    }

    # Build plan
    $plan = New-Object System.Collections.Generic.List[object]

    function Add-PlanItem {
        param(
            [string]$Phase,
            [string]$Name,
            [string]$DoAction,
            [bool]$IsExc
        )
        $d = if ($details.ContainsKey($Name)) { $details[$Name] } else { [pscustomobject]@{ Name=$Name; State='NotFound'; StartMode='Unknown' } }
        $elig = Test-ServiceEligibility -ServiceName $Name -Prefix $res.Prefix -IsException:$IsExc -StartMode $d.StartMode
        $plan.Add([pscustomobject]@{
            Phase           = $Phase
            ServiceName     = $Name
            IntendedAction  = $DoAction
            CurrentState    = $d.State
            StartMode       = $d.StartMode
            IsException     = $IsExc
            Eligible        = $elig.Eligible
            RequiresPrompt  = $elig.RequiresPrompt
            Reason          = $elig.Reason
        })
    }

    if ($stopOthers.Count -gt 0) {
        foreach ($n in ($stopOthers | Sort-Object)) {
            Add-PlanItem -Phase 'Stop Others' -Name $n -DoAction 'Stop' -IsExc:($exceptions.Contains($n))
        }
    }

    $phaseForTargets = if ($PSCmdlet.ParameterSetName -eq 'CoreOperation') { 'Core' } else { "Profile:$ProfileName" }
    foreach ($n in ($targetNames | Sort-Object)) {
        # Warn at preview if not prefixed (eligibility still enforces rule)
        if ($n -notlike "$($res.Prefix)*") {
            Write-ServiceLog -LogFile $logFile -Message ("WARNING: Target service '{0}' does not match Prefix '{1}' (will be skipped)" -f $n, $res.Prefix) -Level WARN
        }
        Add-PlanItem -Phase $phaseForTargets -Name $n -DoAction $Action -IsExc:($exceptions.Contains($n))
    }

    foreach ($n in $pagingRestart) {
        Add-PlanItem -Phase 'Paging Restart' -Name $n -DoAction 'Restart' -IsExc:($exceptions.Contains($n))
    }

    # Preview
    Write-Host ""
    Write-Host "=== EXECUTION PLAN PREVIEW ===" -ForegroundColor Cyan
    Write-Host ("Operation: {0}" -f $opHuman) -ForegroundColor Yellow
    Write-Host ("Action: {0}" -f $Action) -ForegroundColor Yellow
    Write-Host ("Paging: {0}" -f $PagingAction) -ForegroundColor Yellow
    Write-Host ("Log: {0}" -f $logFile) -ForegroundColor Gray

    if ($plan.Count -eq 0) {
        Write-Host "`nNo services to process." -ForegroundColor Yellow
        Write-ServiceLog -LogFile $logFile -Message "No services to process."
        exit 0
    }

    $plan | Format-Table Phase,ServiceName,IntendedAction,CurrentState,StartMode,Eligible,RequiresPrompt,Reason -AutoSize

    # One-shot confirmation / WhatIf gate
    if (-not $PSCmdlet.ShouldProcess(("$($plan.Count) services"), "Execute plan")) {
        Write-ServiceLog -LogFile $logFile -Message "Execution cancelled (WhatIf/Confirm)."
        Write-Host "`nCancelled." -ForegroundColor Yellow
        exit 0
    }

    # Execute
    $monitored = New-Object System.Collections.Generic.List[string]
    foreach ($item in $plan) {
        $name = $item.ServiceName

        if (-not $item.Eligible) {
            Write-ServiceLog -LogFile $logFile -Message ("{0}: Status: Skipped ({1})" -f $name, $item.Reason)
            continue
        }

        if ($item.RequiresPrompt) {
            $caption = "Exception Confirmation"
            $msg = ("Exception service '{0}' requires confirmation for action '{1}'. Proceed?" -f $name, $item.IntendedAction)
            if (-not $PSCmdlet.ShouldContinue($msg, $caption)) {
                Write-ServiceLog -LogFile $logFile -Message ("{0}: Status: Skipped (Exception prompt declined)" -f $name)
                continue
            } else {
                Write-ServiceLog -LogFile $logFile -Message ("{0}: Exception prompt confirmed" -f $name)
            }
        }

        $resOp = Invoke-ServiceOperation -ServiceName $name -Action $item.IntendedAction -LogFile $logFile -Force:$Force
        if ($resOp.Success -and ($item.IntendedAction -in 'Start','Restart')) {
            [void]$monitored.Add($name)
        }
    }

    # Persist state
    if ($PSCmdlet.ParameterSetName -eq 'ProfileOperation') {
        Set-ServiceManagerState -StatePath $statePath -LastProfile $ProfileName
    } else {
        Set-ServiceManagerState -StatePath $statePath -LastProfile $null
    }

    # Start log monitoring (only services that were started/restarted and are present in config)
    if ($cfg.MonitorLogs -and $monitored.Count -gt 0) {
        $index = @{}
        foreach ($s in $cfg.Core.Services) { $index[$s.Name] = $s }
        foreach ($p in $cfg.Profiles.PSObject.Properties) {
            foreach ($s in $p.Value.Services) { $index[$s.Name] = $s }
        }
        foreach ($s in $cfg.Exceptions.Services) { $index[$s.Name] = $s }

        $toWatch = @()
        foreach ($n in $monitored) {
            if ($index.ContainsKey($n)) { $toWatch += $index[$n] }
        }
        if ($toWatch.Count -gt 0) {
            Start-ServiceLogMonitoring -Services $toWatch -ServiceLogRoot $cfg.ServiceLogRoot
        }
    }

    Write-Host "`nOperation completed." -ForegroundColor Green
    Write-ServiceLog -LogFile $logFile -Message "Operation completed successfully"
}
catch {
    $msg = $_.Exception.Message
    if ($logFile) {
        Write-ServiceLog -LogFile $logFile -Message ("ERROR: {0}" -f $msg) -Level ERROR
    }
    Write-Error "Service management failed: $msg"
    exit 1
}
finally {
    # Remove by path-loaded name (base of psm1)
    Remove-Module ServiceManager -ErrorAction SilentlyContinue
}
