# Service Manager Test Suite

## 📌 Overview

This repository includes a **Pester-based test suite** designed to validate the functionality of the **Service Manager** system (`AppServiceController.psm1` and `Manage-Services.ps1`).

The tests verify:

* Configuration parsing & validation
* Execution plan generation
* Service eligibility rules
* Paging query updates (`OFFSET/FETCH NEXT`)
* Logging and monitoring functionality
* State file persistence

This ensures the service management framework runs safely, predictably, and in compliance with operational rules.

---

## ⚙️ Requirements

* **Windows PowerShell 5.1** or **PowerShell 7+**
* **Pester v5** (PowerShell testing framework)

Check if Pester is installed:

```powershell
Get-Module -ListAvailable Pester
```

If missing, install it:

```powershell
Install-Module -Name Pester -Force
```

---

## 📂 Project Structure

```
/ServiceManager/
│── AppServiceController.psm1   # Core reusable module
│── Manage-Services.ps1         # Entry point script (orchestrator)
│── config/
│    └── services.config.json   # Test configuration file
│── tests/
│    └── ServiceManager.Tests.ps1  # Pester test suite
```

---

## ▶️ Running the Tests

Run the following from the **project root**:

```powershell
Invoke-Pester -Path .\tests\ServiceManager.Tests.ps1 -Output Detailed
```

To run with code coverage:

```powershell
Invoke-Pester -Path .\tests\ServiceManager.Tests.ps1 -CodeCoverage .\AppServiceController.psm1
```

---

## ✅ What the Tests Cover

1. **Configuration Validation**

   * Ensures required sections (`Prefix`, `Core`, `Profiles`, `Exceptions`, `Paging`) exist.
   * Validates Core/Profile overlap rules.
   * Checks prefix compliance warnings are logged.

2. **Execution Plan**

   * Generates preview plans for Core and Profile operations.
   * Confirms `Stop Others` logic works.
   * Ensures Exception services always require prompts.

3. **Service Operations**

   * Tests idempotence (skips already running/stopped services).
   * Validates `-WhatIf` and `-Confirm` functionality.
   * Verifies `Force` only applies when explicitly set.

4. **Paging Management**

   * Updates `OFFSET` and `FETCH NEXT` values correctly.
   * Backs up appsettings file before modification.
   * Handles reset on profile switch.

5. **Logging**

   * Writes correct format:

     ```
     DateTime:: Operation:: (Core/Profile) Action:: Start/Stop/Restart
     DateTime:: ServiceName: Status: Success/Skipped/Error
     ```
   * Ensures skipped services log reasons.

6. **State File**

   * Persists last used profile.
   * Resets paging offset correctly when profile changes.

---

## 🧪 Example Test Run

```powershell
Describing Service Manager Tests
 [+] Loads valid configuration 500ms
 [+] Detects invalid config keys 250ms
 [+] Generates Core execution plan 1.2s
 [+] Handles Stop Others correctly 890ms
 [+] Skips disabled services 320ms
 [+] Applies paging update and backup 1.1s
 [+] Logs all operations correctly 640ms
Tests completed in 4.9s
Passed: 7 Failed: 0 Skipped: 0 Pending: 0
```

---

## 📖 Notes

* Tests are written to avoid impacting **real services**.
* Mocks are used where possible to simulate service operations.
* For live environment tests, update `services.config.json` to match actual service names.
