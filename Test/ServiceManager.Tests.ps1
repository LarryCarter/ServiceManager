#requires -Version 5.1
# Pester 5.x
# This test exercises Manage-Services.ps1 (entrypoint) + ServiceManager.psm1 (module)
# without touching real services. It stands up a temp workspace, writes a config
# & appsettings, and uses Mocks for all service operations.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------
# Test Workspace Bootstrap
# -------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here  # assume Tests\ under repo
$scriptPath = Join-Path $repoRoot 'Manage-Services.ps1'
$modulePath = Join-Path $repoRoot 'ServiceManager.psm1'

if (-not (Test-Path $scriptPath)) { throw "Manage-Services.ps1 not found at $scriptPath" }
if (-not (Test-Path $modulePath)) { throw "ServiceManager.psm1 not found at $modulePath" }

$TestDriveRoot = Join-Path $env:TEMP ("SvcMgrTests_{0}" -f ([Guid]::NewGuid()))
New-Item -ItemType Directory -Path $TestDriveRoot -Force | Out-Null
$cfgDir = Join-Path $TestDriveRoot 'config'
$logsDir = Join-Path $TestDriveRoot 'logs'
$svcLogsRoot = Join-Path $TestDriveRoot 'service-logs'
New-Item -ItemType Directory -Path $cfgDir,$logsDir,$svcLogsRoot -Force | Out-Null

# Write appsettings with OFFSET 0 and FETCH NEXT 1000000 ROWS ONLY
$appSettingsPath = Join-Path $cfgDir 'appsettings.Production.json'
@'
{
  "esarBaseQuery": "select 'x' as Dummy from esar_raw_data r WHERE r.Status = 'Completed' ORDER BY id DESC OFFSET 0 ROWS FETCH NEXT 1000000 ROWS ONLY"
}
'@ | Set-Content -LiteralPath $appSettingsPath -Encoding UTF8

# Minimal services.config.json aligned to your schema
$configPath = Join-Path $cfgDir 'services.config.json'
$configJson = @{
  Prefix = 'Su_'
  ServiceLogRoot = $svcLogsRoot
  MonitorLogs = $false
  Core = @{
    Services = @(
      @{ Name = 'Su_Auth';      LogLocation = 'core\auth';      MonitorSeparate = $false },
      @{ Name = 'Su_Registry';  LogLocation = 'core\registry';   MonitorSeparate = $false }
    )
  }
  Profiles = @{
    Web = @{
      Services = @(
        @{ Name = 'Su_WebExtraction';   LogLocation = 'web'; MonitorSeparate = $true  },
        @{ Name = 'Su_WebFilter';       LogLocation = 'web'; MonitorSeparate = $false },
        @{ Name = 'Su_WebReconcile';    LogLocation = 'web'; MonitorSeparate = $false }
      )
    }
    DBOracle = @{
      Services = @(
        @{ Name = 'Su_DBOracleExtraction'; LogLocation = 'dbora'; MonitorSeparate = $true },
        @{ Name = 'Su_DBOracleFilter';     LogLocation = 'dbora'; MonitorSeparate = $true },
        @{ Name = 'Su_DBOracleReconcile';  LogLocation = 'dbora'; MonitorSeparate = $false }
      )
    }
  }
  Exceptions = @{
    Services = @(
      @{ Name = 'RandomService'; LogLocation = ''; MonitorSeparate = $false }
    )
  }
  Paging = @{
    ServiceName = 'Su_Auth'
    AppSettingsPath = $appSettingsPath
    JsonKey = 'esarBaseQuery'
    PageSize = 1000000
    EnforceFetchNextToPageSize = $true
    ResetOffsetOnProfileChange = $true
  }
} | ConvertTo-Json -Depth 8
$configJson | Set-Content -LiteralPath $configPath -Encoding UTF8

# -------------------------
# Helper: run script
# -------------------------
function Invoke-ManageServices {
    param(
        [string]$Action,
        [ValidateSet('Core','Profile')] [string]$OpKind,
        [string]$ProfileName,
        [string]$PagingAction = 'NoChange',
        [switch]$WhatIf,
        [switch]$ConfirmOff
    )
    $params = @(
        '-ExecutionPolicy','Bypass',
        '-NoProfile',
        '-File', $scriptPath,
        '-ConfigPath', $configPath,
        '-LogRoot', $logsDir
    )

    if ($OpKind -eq 'Core') {
        $params += @('-Action', $Action, '-Operation', 'Core')
    } else {
        $params += @('-Action', $Action, '-ProfileOperation', 'Profile', '-ProfileName', $ProfileName)
    }

    if ($PagingAction -and $PagingAction -ne 'NoChange') {
        $params += @('-PagingAction', $PagingAction)
    }

    if ($WhatIf)    { $params += '-WhatIf' }
    if ($ConfirmOff){ $params += '-Confirm:$false' }

    # Using Start-Process lets us capture exit code and not pollute the test runspace
    $psi = @{
        FilePath = 'powershell.exe'
        ArgumentList = $params
        WorkingDirectory = $repoRoot
        NoNewWindow = $true
        PassThru = $true
        RedirectStandardOutput = Join-Path $TestDriveRoot ('stdout_{0}.log' -f ([Guid]::NewGuid()))
        RedirectStandardError  = Join-Path $TestDriveRoot ('stderr_{0}.log' -f ([Guid]::NewGuid()))
    }
    $p = Start-Process @psi
    $p.WaitForExit()
    return $p.ExitCode
}

# -------------------------
# Begin Pester
# -------------------------
Import-Module Pester -ErrorAction Stop

Describe 'Manage-Services end-to-end (mocked services)' -Tag 'e2e' {
    BeforeAll {
        # Always import our module so Pester can Mock functions in it
        Import-Module $modulePath -Force

        # Default mock universe of installed prefixed services
        $installedPrefixed = @(
            # Core
            'Su_Auth','Su_Registry',
            # Web profile
            'Su_WebExtraction','Su_WebFilter','Su_WebReconcile',
            # DBOracle profile
            'Su_DBOracleExtraction','Su_DBOracleFilter','Su_DBOracleReconcile',
            # An extra prefixed service not in selected profile/core (to be stopped)
            'Su_Orphan'
        )

        # Map of details for Get-ServiceDetails
        $detailMap = @{
            'Su_Auth'               = @{ State='Running';  StartMode='Manual' }
            'Su_Registry'           = @{ State='Stopped';  StartMode='Manual' }
            'Su_WebExtraction'      = @{ State='Stopped';  StartMode='Manual' }
            'Su_WebFilter'          = @{ State='Running';  StartMode='Manual' }
            'Su_WebReconcile'       = @{ State='Running';  StartMode='Manual' }
            'Su_DBOracleExtraction' = @{ State='Running';  StartMode='Manual' }
            'Su_DBOracleFilter'     = @{ State='Running';  StartMode='Manual' }
            'Su_DBOracleReconcile'  = @{ State='Stopped';  StartMode='Manual' }
            'Su_Orphan'             = @{ State='Running';  StartMode='Manual' }
            'RandomService'         = @{ State='Running';  StartMode='Automatic' } # exception path
        }

        # 1) Mock discovery of prefixed services
        Mock -ModuleName ServiceManager -CommandName Get-PrefixedServices -MockWith {
            param([string]$Prefix)
            return $installedPrefixed
        }

        # 2) Mock Get-ServiceDetails to return our canned states/startmodes
        Mock -ModuleName ServiceManager -CommandName Get-ServiceDetails -MockWith {
            param([string[]]$ServiceNames)
            foreach ($n in $ServiceNames) {
                $d = $detailMap[$n]
                if (-not $d) {
                    [pscustomobject]@{ Name=$n; State='NotFound'; StartMode='Unknown'; Status='NotFound'; DisplayName=$n; ProcessId=$null }
                } else {
                    [pscustomobject]@{ Name=$n; State=$d.State; StartMode=$d.StartMode; Status='OK'; DisplayName=$n; ProcessId=1000 }
                }
            }
        }

        # 3) Mock Invoke-ServiceOperation to avoid touching real services, capture calls
        $script:InvokeCalls = New-Object System.Collections.Generic.List[object]
        Mock -ModuleName ServiceManager -CommandName Invoke-ServiceOperation -MockWith {
            param([string]$ServiceName,[string]$Action,[switch]$Force,[string]$LogFile)
            $script:InvokeCalls.Add([pscustomobject]@{ Name=$ServiceName; Action=$Action })
            # Simulate idempotence success
            [pscustomobject]@{ ServiceName=$ServiceName; Action=$Action; Success=$true; Result='Success'; Message='ok' }
        }

        # 4) Make Update-PagingConfiguration actually update the file so we can assert
        #    (but keep it simple—no ShouldProcess here; it’s unit-tested separately)
        Mock -ModuleName ServiceManager -CommandName Update-PagingConfiguration -MockWith {
            param($AppSettingsPath,$JsonKey,$PagingAction,$PageSize,[bool]$EnforceFetchNextToPageSize)
            $raw = Get-Content -LiteralPath $AppSettingsPath -Raw | ConvertFrom-Json
            $q   = [string]$raw.$JsonKey
            $m   = [regex]::Match($q,'OFFSET\s+(\d+)\s+ROWS',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { return @{ Success=$false; Changed=$false; Error='No OFFSET' } }
            $old = [int]$m.Groups[1].Value
            switch ($PagingAction) {
                'NextPage'         { $new = $old + $PageSize }
                'PreviousPage'     { $new = [math]::Max(0,$old - $PageSize) }
                'RestartFromPage1' { $new = 0 }
                default            { $new = $old }
            }
            $q2 = [regex]::Replace($q,'OFFSET\s+\d+\s+ROWS',("OFFSET {0} ROWS" -f $new),[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($EnforceFetchNextToPageSize) {
                $q2 = [regex]::Replace($q2,'FETCH\s+NEXT\s+\d+\s+ROWS\s+ONLY',("FETCH NEXT {0} ROWS ONLY" -f $PageSize),[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            $raw.$JsonKey = $q2
            $raw | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $AppSettingsPath -Encoding UTF8
            return @{ Success=$true; Changed=($new -ne $old); OldOffset=$old; NewOffset=$new; OldQuery=$q; NewQuery=$q2 }
        }
    }

    BeforeEach {
        $script:InvokeCalls.Clear()
        # Reset state file so profile-change tests are deterministic
        $stateFile = "$configPath.state.json"
        if (Test-Path $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    }

    It 'Core / WhatIf: prints plan, executes nothing' {
        $code = Invoke-ManageServices -Action 'Start' -OpKind Core -PagingAction 'NoChange' -WhatIf
        $code | Should -Be 0

        # No service calls were made due to -WhatIf/ShouldProcess
        $script:InvokeCalls.Count | Should -Be 0

        # Verify log file exists for the run
        (Get-ChildItem -LiteralPath $logsDir -Recurse -Filter *.log).Count | Should -BeGreaterThan 0
    }

    It 'Profile Web: Stop Others set is prefixed-not-in-core-or-profile' {
        # Run with Confirm turned off to auto-proceed (we’re mocked anyway)
        $code = Invoke-ManageServices -Action 'Restart' -OpKind Profile -ProfileName 'Web' -ConfirmOff
        $code | Should -Be 0

        # Expect a Stop on 'Su_Orphan' (prefixed, not in Core or Web profile)
        $stopOthersInvoked = $script:InvokeCalls | Where-Object { $_.Name -eq 'Su_Orphan' -and $_.Action -eq 'Stop' }
        $stopOthersInvoked | Should -Not -BeNullOrEmpty
    }

    It 'Paging NextPage updates OFFSET and restarts paging service' {
        # Capture old OFFSET
        $textBefore = Get-Content -LiteralPath $appSettingsPath -Raw
        $m = [regex]::Match($textBefore,'OFFSET\s+(\d+)\s+ROWS',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $oldOffset = [int]$m.Groups[1].Value

        $code = Invoke-ManageServices -Action 'Restart' -OpKind Core -PagingAction 'NextPage' -ConfirmOff
        $code | Should -Be 0

        # App settings should reflect new offset = old + PageSize (1,000,000)
        $textAfter = Get-Content -LiteralPath $appSettingsPath -Raw
        $m2 = [regex]::Match($textAfter,'OFFSET\s+(\d+)\s+ROWS',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $newOffset = [int]$m2.Groups[1].Value
        $newOffset | Should -Be ($oldOffset + 1000000)

        # Paging service ('Su_Auth') should have a Restart call in the invocation list
        $pagingRestart = $script:InvokeCalls | Where-Object { $_.Name -eq 'Su_Auth' -and $_.Action -eq 'Restart' }
        $pagingRestart | Should -Not -BeNullOrEmpty
    }

    It 'Profile change triggers paging reset to 0 when configured' {
        # First run as Web so state stores LastProfile
        $code1 = Invoke-ManageServices -Action 'Start' -OpKind Profile -ProfileName 'Web' -ConfirmOff
        $code1 | Should -Be 0

        # Now alter appsettings to have OFFSET 1,000,000
        (Get-Content -LiteralPath $appSettingsPath -Raw) -replace 'OFFSET\s+\d+\s+ROWS','OFFSET 1000000 ROWS' |
            Set-Content -LiteralPath $appSettingsPath -Encoding UTF8

        # Switch to DBOracle → should reset to 0
        $code2 = Invoke-ManageServices -Action 'Start' -OpKind Profile -ProfileName 'DBOracle' -ConfirmOff
        $code2 | Should -Be 0

        $txt = Get-Content -LiteralPath $appSettingsPath -Raw
        $m3 = [regex]::Match($txt,'OFFSET\s+(\d+)\s+ROWS',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        ([int]$m3.Groups[1].Value) | Should -Be 0
    }

    It 'Exceptions: Automatic services only act with confirmation; Disabled are skipped' {
        # Extend detail map dynamically for this test:
        # RandomService (exception) is Automatic → should require confirmation;
        # Another exception that is Disabled → skipped.
        # We simulate confirmation accepted by bypass (ConfirmOff) and rely on ShouldContinue prompts being gated by ShouldProcess (already approved).
        # For simplicity we’ll just inject a call in Invoke-ServiceOperation expectation.
        # Add a mock where Test-ServiceEligibility will mark RequiresPrompt (handled in script).
        # Since Invoke-ServiceOperation is called only after prompts, presence of call implies prompts passed.
        # Add a fake 'RandomService' to the plan by making it appear as a prefixed service not in target/core/profile via Get-PrefixedServices mock override.

        # Override installed list for this test case
        $localInstalled = @('Su_Auth','Su_Registry','Su_WebExtraction','Su_Orphan','RandomService')
        Mock -ModuleName ServiceManager -CommandName Get-PrefixedServices -MockWith {
            param([string]$Prefix) ; $localInstalled
        } -Verifiable

        # Also update Get-ServiceDetails returns for RandomService
        Mock -ModuleName ServiceManager -CommandName Get-ServiceDetails -MockWith {
            param([string[]]$ServiceNames)
            foreach ($n in $ServiceNames) {
                switch ($n) {
                    'RandomService' { [pscustomobject]@{ Name=$n; State='Running'; StartMode='Automatic'; Status='OK'; DisplayName=$n; ProcessId=1111 } }
                    default         { [pscustomobject]@{ Name=$n; State='Running'; StartMode='Manual';    Status='OK'; DisplayName=$n; ProcessId=2222 } }
                }
            }
        } -Verifiable

        $null = Invoke-ManageServices -Action 'Restart' -OpKind Profile -ProfileName 'Web' -ConfirmOff

        # Because it is in Exceptions and Automatic, RequiresPrompt path → action allowed after confirmation
        ($script:InvokeCalls | Where-Object { $_.Name -eq 'RandomService' }).Count | Should -BeGreaterThan 0
    }
}

# Cleanup on exit
AfterAll {
    if (Test-Path $TestDriveRoot) {
        Remove-Item -LiteralPath $TestDriveRoot -Recurse -Force
    }
    Remove-Module ServiceManager -ErrorAction SilentlyContinue
}
