# Manage-AppServices – README

A production-ready PowerShell solution to safely **Start/Stop/Restart** a set of Windows services for a single application—driven by a JSON configuration with strict safety rules, optional paging of a Core service query (`custom`), structured run logging, and live log tailing.

---

## 📂 Project Layout

```
/config/
  services.config.json        # Main configuration (Prefix/Core/Profiles/Exceptions/Paging)
/scripts/
  Manage-AppServices.ps1      # Entry point script (run this)
/scripts/Modules/
  AppServiceController.psm1   # Module with helper functions
/logs/
  yyyy-MM-dd/run-HHmmss.log   # Execution logs (auto-created per run)
```

---

## ✅ Key Features

* **Prefix Gate**: Touch only services whose names begin with a configured prefix (safety guardrail).
* **Core vs Profiles**: Core services are immutable during profile operations; services may appear in multiple profiles but never in Core.
* **Exceptions with Prompts**: Always prompt y/n before acting on any Exception service; special handling for Automatic startup type.
* **Startup Type Rules**:

  * Manual → eligible
  * Disabled → warn & skip
  * Automatic → skip unless in Exceptions (then prompt y/n)
* **Preview + Confirm**: Prints an explicit plan (Stop Others, Targets, Reasons) and asks for confirmation before executing.
* **Paging**: Update `OFFSET`/`FETCH NEXT` of `esarBaseQuery` in `appsettings.Production.json` (Next/Prev/RestartFromPage1/NoChange) and restart the designated Core service.
* **Profile Switching Reset**: On changing profiles, automatically reset `OFFSET` to page 1 (configurable).
* **Structured Logging**: Run header + per-service status + config updates.
* **Log Tailing**: Open new windows to tail logs per service or one combined tailer (based on `MonitorSeparate`).

---

## 🔒 Operational Rules (Enforced)

1. **Prefix Safety**

   * Only consider services with names starting with `Prefix`.
   * Any Core/Profile/Exception service without the prefix → warn & skip (Exceptions still prompt for action).

2. **Core vs Profiles**

   * A service can be in multiple profiles.
   * A service **must not** appear in both Core and any Profile (overlap → warn & skip from Profile).
   * In Profile mode, Core services are left alone (apart from Exception prompts you explicitly approve).

3. **Startup Types**

   * **Manual** → eligible.
   * **Disabled** → **warn & skip**.
   * **Automatic** → **skip**, **unless** in **Exceptions** → **prompt y/n**; do only on **y**.

4. **Exceptions**

   * Always prompt y/n before any action.
   * If Automatic + Exception → prompt y/n; act only on y.
   * Always log the decision and any action.

5. **Core-Only Operation**

   * Choose Start/Stop/Restart.
   * Show preview (Core + any Exceptions that would be touched).
   * Confirm y/n, then per-Exception prompts.

6. **Profile Operation**

   * **Stop Others**: Stop all **prefixed** services **not** in Core and **not** in the selected profile (respect startup rules + Exception prompts).
   * **Profile Action**: Apply Start/Stop/Restart to the selected profile’s services (respect rules).
   * Core is untouched (except via per-Exception prompts you approve).
   * Preview shows Stop Others + Profile targets + Exceptions → confirm y/n.

7. **Paging (`appsettings.Production.json`)**

   * Target: a designated Core service owns `esarBaseQuery`.
   * Actions: NextPage / PrevPage / RestartFromPage1 / NoChange.
   * Update `OFFSET` and optionally enforce `FETCH NEXT` to the configured `PageSize`.
   * Backup the JSON with a timestamp; log old/new query.
   * Restart the paging Core service after changes.
   * On **profile change** (if enabled), reset `OFFSET` to 0 before running the profile flow.

8. **Idempotence & Dependencies**

   * Skip “Start” if already Running; skip “Stop” if already Stopped (log reason).
   * Any dependency errors are logged (no `-Force` by default).

---

## ⚙️ Configuration

**File:** `/config/services.config.json`

```json
{
  "Prefix": "Su_",
  "ServiceLogRoot": "C:\\Services\\",
  "MonitorLogs": true,

  "Core": {
    "Services": [
      { "Name": "Su_Auth",     "LogLocation": "core\\auth\\",     "MonitorSeparate": false },
      { "Name": "Su_Registry", "LogLocation": "core\\registry\\", "MonitorSeparate": false }
    ]
  },

  "Profiles": {
    "Web": {
      "Services": [
        { "Name": "Su_WebExtraction", "LogLocation": "web\\extraction\\",  "MonitorSeparate": true  },
        { "Name": "Su_WebFilter",     "LogLocation": "web\\filter\\",      "MonitorSeparate": false },
        { "Name": "Su_WebReconcile",  "LogLocation": "web\\reconcile\\",   "MonitorSeparate": false }
      ]
    },
    "DBOracle": {
      "Services": [
        { "Name": "Su_DBOracleExtraction", "LogLocation": "db\\oracle\\extraction\\", "MonitorSeparate": true  },
        { "Name": "Su_DBOracleFilter",     "LogLocation": "db\\oracle\\filter\\",     "MonitorSeparate": true  },
        { "Name": "Su_DBOracleReconcile",  "LogLocation": "db\\oracle\\reconcile\\",  "MonitorSeparate": false }
      ]
    },
    "Linux": {
      "Services": [
        { "Name": "Su_LinuxExtraction", "LogLocation": "linux\\extraction\\", "MonitorSeparate": false },
        { "Name": "Su_LinuxFilter",     "LogLocation": "linux\\filter\\",     "MonitorSeparate": false },
        { "Name": "Su_LinuxReconcile",  "LogLocation": "linux\\reconcile\\",  "MonitorSeparate": false }
      ]
    }
  },

  "Exceptions": {
    "Services": [
      { "Name": "RamdonSerice", "LogLocation": "", "MonitorSeparate": false }
    ]
  },

  "Paging": {
    "ServiceName": "Su_Auth",
    "AppSettingsPath": "C:\\Services\\core\\auth\\appsettings.Production.json",
    "JsonKey": "esarBaseQuery",
    "PageSize": 1000000,
    "EnforceFetchNextToPageSize": true,
    "ResetOffsetOnProfileChange": true
  }
}
```

### Notes on `ServiceLogRoot` + `LogLocation`

* Effective log dir = `ServiceLogRoot` + `LogLocation`, with extra slashes safely normalized.
* The script locates the active log file by `<ServiceName>*.log` and picks the most recent if multiple exist.
* Daily rotation/zip is supported; only the current day’s file is tailed.

---

## 🧭 Usage

> **Run as Administrator** (service control requires elevation).

From `/scripts`:

### Profile operations

```powershell
# Restart selected profile services, stop other prefixed/non-core services, no paging change
.\Manage-AppServices.ps1 -ConfigPath ..\config\services.config.json `
                         -Operation Profile `
                         -ProfileName DBOracle `
                         -Action Restart `
                         -PagingAction NoChange `
                         -Verbose
```

### Profile with paging

```powershell
# Move to next page (OFFSET += PageSize), restart paging core service, then do profile restart
.\Manage-AppServices.ps1 -ConfigPath ..\config\services.config.json `
                         -Operation Profile `
                         -ProfileName DBOracle `
                         -Action Restart `
                         -PagingAction NextPage
```

### Core-only operations

```powershell
# Start only Core services (with Exceptions prompts as needed)
.\Manage-AppServices.ps1 -ConfigPath ..\config\services.config.json `
                         -Operation CoreOnly `
                         -Action Start `
                         -PagingAction NoChange
```

### Other paging options

```powershell
# Previous page
-PagingAction PrevPage

# Restart from page 1 (OFFSET = 0)
-PagingAction RestartFromPage1
```

---

## 🧪 Preview & Prompts

* The script prints a **PREVIEW** table of:

  * Phase (`StopOthers`, `Targets`, `PagingRestart`)
  * Service
  * IntendedAction
  * StartMode
  * Eligible / RequiresPrompt
  * Reason
* You must confirm **y/n** to proceed.
* For each Exception encountered, you’ll get an additional **y/n** prompt per service.

---

## 📝 Logging

* Logs are written to `/logs/yyyy-MM-dd/run-HHmmss.log`.
* Header line:

  ```
  DateTime:: Operation:: (Core Only | Profile:<Name>) Action::(Start|Stop|Restart|NextPage|PrevPage|RestartFromPage1|NoChange)
  Paging:: Service=<Name> OldOffset=<N> NewOffset=<M> PageSize=<K>
  ```
* Per-service lines:

  ```
  DateTime:: ServiceName: Status: <Started|Stopped|Restarted|Skipped> (Reason/Error)
  ```
* Config update line:

  ```
  DateTime:: ConfigUpdate: File=<path> Key=esarBaseQuery Old="..." New="..." Backup="<backupPath>"
  ```

---

## 📡 Log Tailing

* If `"MonitorLogs": true`:

  * Services with `"MonitorSeparate": true` → **new window** per service tailing that log.
  * Others → **combined** tailer window with each line prefixed by the file name.
* The tailers show the last 50 lines and stream live appends.

---

## 🔧 Requirements

* **PowerShell**: `#requires -Version 5.1` (Windows PowerShell).
* **Admin rights**: Required to manage Windows services.
* **File access**: Read/write access to `services.config.json`, the `Paging.AppSettingsPath`, and `/logs`.

---

## 🛡️ Design & Style

* Strict Mode enabled; `[CmdletBinding()]` used; parameter validation with `ValidateSet/ValidateScript`.
* Uses CIM (`Win32_Service`) to reliably read StartMode (Auto/Manual/Disabled).
* Clear separation of concerns: config parsing, plan building, execution, logging, tailing.
* Conservative defaults: no `-Force` on service operations; explicit user confirmation.

---

## 🧰 Troubleshooting

* **“Service not found”** in preview
  Ensure the Windows service `Name` matches exactly (not DisplayName). Verify prefix.
* **“Disabled (warn & skip)”**
  Set startup type to Manual if you intend the script to control it (outside the script, or add as Exception to prompt—but Disabled still always skips).
* **Paging pattern not found**
  Confirm `JsonKey` exists and contains `OFFSET <N> ROWS FETCH NEXT <K> ROWS ONLY`.
* **No logs tailed**
  Check `ServiceLogRoot` + `LogLocation` are correct and a `<ServiceName>*.log` exists.
* **Access denied**
  Run terminal as Administrator; verify file permissions for config and appsettings.

---

## 🔄 Extending

* Add profiles/services by editing `services.config.json`.
* Add `Exceptions` to allow prompted control over services (including Automatic startup).
* Switch to stricter validation (JSON Schema) if desired.
* Add a `-Force` switch (opt-in) to push through dependencies for Stop/Restart.

---

## ⚖️ License

I have to come back to this. 

---

## ✍️ Author & Support

Script and structure devised for controlled Windows service orchestration with auditability and safety in enterprise environments.
For enhancements (Pester tests, schema validation, CI hooks), open an issue or request additions.

