# Scripts-Sly

PowerShell scripts for Microsoft Configuration Manager (ConfigMgr/SCCM) administrative tasks.

## Overview

This repository contains PowerShell scripts developed during administrative activities for Configuration Manager environments. These scripts help automate common maintenance, auditing, and validation tasks.

**Disclaimer**: These scripts are provided as-is for testing purposes. No warranty or liability is assumed by the author. Test thoroughly in your environment before production use.

## Table of Contents

- [Scripts](#scripts)
  - [CheckAppSourcePaths.ps1](#checkappsourcepathsps1)
  - [CheckDriverPackages.ps1](#checkdriverpackagesps1)
  - [Compare-AD-CM-Clients.ps1](#compare-ad-cm-clientsps1)
  - [New-CMCollection.ps1](#new-cmcollectionps1)
  - [Remove-CMCollection.ps1](#remove-cmcollectionps1)
  - [Add-CMCollectionRegistryRule.ps1](#add-cmcollectionregistryruleps1)
  - [Check-CMSecurityPosture.ps1](#check-cmsecuritypostureps1)
  - [Get-CMDailyMonitoringReport.ps1](#get-cmdailymonitoringreportps1)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage Examples](#usage-examples)
- [Contributing](#contributing)
- [License](#license)

## Scripts

### CheckAppSourcePaths.ps1

Validates ConfigMgr Application source paths for existence and accessibility.

**Purpose**: Identifies applications with missing or inaccessible source directories, which is particularly helpful during ConfigMgr cleanup operations.

**Features**:
- Automatically detects ConfigMgr cmdlets or falls back to WMI/CIM
- Recursively extracts all Windows/UNC paths from application deployment types
- Validates path existence using Test-Path
- Generates detailed CSV report and log file

**Parameters**:
- `OutputDirectory` - Directory for CSV and log output (default: `C:\ConfigMgrAppSourceCheck`)
- `VerboseLog` - Enable detailed logging output

**Example**:
```powershell
.\CheckAppSourcePaths.ps1 -OutputDirectory 'C:\Reports\ConfigMgr' -VerboseLog
```

**Output**:
- CSV file with columns: ApplicationName, ApplicationId, DeploymentTypeName, CandidateSourcePath, PathExists, IsValidWindowsPath, Notes
- Timestamped log file with execution details

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed OR SMS Provider WMI access
- Read permissions on all source paths

---

### CheckDriverPackages.ps1

Audits ConfigMgr Driver Packages for source path existence and content validation.

**Purpose**: Identifies driver packages with missing or empty source directories. Empty directories can cause deployment errors in ConfigMgr.

**Features**:
- Auto-detects site code if not specified
- Validates source path configuration
- Checks directory existence and accessibility
- Verifies directories contain files (not empty)
- Provides summary statistics

**Parameters**:
- `SiteCode` - ConfigMgr site code (e.g., 'P01'), auto-detected if not specified
- `CsvOutputPath` - Path for CSV audit report (default: `C:\Temp\DriverPackageAudit.csv`)
- `VerboseOutput` - Enable detailed console output

**Example**:
```powershell
.\CheckDriverPackages.ps1 -SiteCode 'P01' -CsvOutputPath 'D:\Reports\DriverAudit.csv'
```

**Output**:
- CSV file with columns: PackageID, Name, SourcePath, PathExists, IsFolderEmpty, Status
- Console summary with statistics (total packages, packages with issues, missing paths, empty directories)

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- Read permissions on SMS Provider
- Network access to driver package source paths

---

### Compare-AD-CM-Clients.ps1

Compares active ConfigMgr clients with Active Directory computer objects.

**Purpose**: Validates that ConfigMgr clients have corresponding Active Directory computer accounts. Identifies orphaned ConfigMgr clients or clients with disabled AD accounts.

**Features**:
- Queries ConfigMgr via WMI (SMS Provider)
- Validates against Active Directory using PowerShell module or ADSI fallback
- Supports collection-based filtering
- Supports OU-scoped AD searches
- Optional handling of disabled AD accounts
- CMTrace-compatible logging
- Progress indicators for large environments

**Parameters**:
- `SiteServer` - SMS Provider server name (required)
- `SiteCode` - ConfigMgr site code, e.g., 'P01' (required)
- `CollectionId` - Limit check to specific collection (optional)
- `ADSearchBase` - LDAP search base for AD queries (optional)
- `IncludeDisabledAD` - Treat disabled AD accounts as valid (optional)
- `OutputCsv` - Path for CSV report (optional)
- `LogPath` - Path for CMTrace log file (optional)

**Examples**:

1. **Check all active clients against entire domain**:
```powershell
.\Compare-AD-CM-Clients.ps1 -SiteServer 'CM01' -SiteCode 'P01' -OutputCsv '.\CM_vs_AD.csv' -LogPath '.\Compare.log'
```

2. **Restrict to specific collection and OU**:
```powershell
.\Compare-AD-CM-Clients.ps1 -SiteServer 'CM01' -SiteCode 'P01' -CollectionId 'SMS00001' -ADSearchBase 'OU=Workstations,OU=HQ,DC=contoso,DC=com' -OutputCsv '.\OU_Scope.csv'
```

3. **Ignore disabled AD accounts**:
```powershell
.\Compare-AD-CM-Clients.ps1 -SiteServer 'CM01' -SiteCode 'P01' -IncludeDisabledAD
```

**Output Fields**:
- `CM_Name` / `CM_ResourceId` / `CM_Client` / `CM_Active` / `CM_ClientVersion` - ConfigMgr data
- `AD_Status` - One of:
  - `FoundInAD` - Matching AD computer found
  - `ADDisabled` - AD computer found but disabled (only when `-IncludeDisabledAD` not set)
  - `MissingInAD` - No matching AD computer object found
- `AD_Enabled` / `AD_DNSHostName` / `AD_LastLogonTimestamp` - Selected AD details

**Requirements**:
- PowerShell 5.1 or higher
- Read access to SMS Provider (WMI)
- Read access to Active Directory
- Optional: ActiveDirectory PowerShell module (RSAT-AD-PowerShell)

**Notes**:
- Script tries FQDN first, then NetBIOS name for matching
- For multi-domain environments, use `-ADSearchBase` to target correct domain/OU
- For large environments, use `-CollectionId` or `-ADSearchBase` to limit scope
- Requires read permissions on SMS Provider and Active Directory

---

### New-CMCollection.ps1

Creates a Configuration Manager collection if it does not already exist.

**Purpose**: Provides an idempotent way to create device or user collections in ConfigMgr and avoid duplicate objects.

**Features**:
- Imports the ConfigurationManager module automatically
- Auto-detects site code when not provided
- Supports both device and user collections
- Uses default limiting collections (`All Systems` for device, `All Users` for user)
- Detects existing collection and returns `AlreadyExists` instead of creating duplicates
- Supports `-WhatIf` and `-Confirm` via `SupportsShouldProcess`
- Handles ConfigMgr module version differences (with or without `-Fast` support)

**Parameters**:
- `CollectionName` - Name of the collection to create (default: `TESTtest`)
- `CollectionType` - `Device` or `User` (default: `Device`)
- `SiteCode` - Optional site code (for example: `P01`)
- `LimitingCollectionName` - Optional limiting collection name

**Example**:
```powershell
.\New-CMCollection.ps1 -CollectionName 'TESTtest'
```

**Output**:
- Object with: `CollectionName`, `CollectionType`, `LimitingCollection`, `SiteCode`, `Action`, `CollectionId`
- `Action` is either `Created` or `AlreadyExists`

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- Permissions to create collections in ConfigMgr

---

### Remove-CMCollection.ps1

Removes a Configuration Manager collection if it exists.

**Purpose**: Provides a safe and idempotent way to remove device or user collections in ConfigMgr.

**Features**:
- Imports the ConfigurationManager module automatically
- Auto-detects site code when not provided
- Supports device, user, or automatic collection type detection
- Returns `NotFound` when the collection does not exist
- Supports `-WhatIf` and `-Confirm` via `SupportsShouldProcess`
- Handles ConfigMgr module version differences (with or without `-Fast` support)

**Parameters**:
- `CollectionName` - Name of the collection to remove (default: `TESTtest`)
- `CollectionType` - `Auto`, `Device`, or `User` (default: `Auto`)
- `SiteCode` - Optional site code (for example: `P01`)

**Example**:
```powershell
.\Remove-CMCollection.ps1 -CollectionName 'TESTtest'
```

**Output**:
- Object with: `CollectionName`, `CollectionType`, `SiteCode`, `Action`, `CollectionId`
- `Action` is either `Removed` or `NotFound`

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- Permissions to delete collections in ConfigMgr

---

### Add-CMCollectionRegistryRule.ps1

Adds a query membership rule to an existing ConfigMgr device collection based on an inventory-backed registry value.

**Purpose**: Adds and maintains a query rule that includes clients with a specific registry-derived value (idempotent behavior).

**Features**:
- Imports the ConfigurationManager module automatically
- Auto-detects site code when not provided
- Validates target inventory class and property before adding the rule
- Supports numeric and string comparison values
- Avoids duplicate rules by query normalization
- Returns `AlreadyExists` when the same logical query is already present
- Supports `-WhatIf` and `-Confirm` via `SupportsShouldProcess`

**Parameters**:
- `CollectionName` - Existing device collection name (default: `SampleCollection`)
- `RegistryKeyPath` - Registry path context used in output/rule metadata
- `InventoryClassName` - Inventory class to query (default: `SMS_G_System_SecureBoot_Main_1_0`)
- `InventoryPropertyName` - Property to compare (default: `AvailableUpdates`)
- `DesiredValue` - Expected value (default: `0`)
- `RuleName` - Optional explicit rule name
- `SiteCode` - Optional site code (for example: `P01`)

**Example**:
```powershell
.\Add-CMCollectionRegistryRule.ps1 `
  -CollectionName 'SampleCollection' `
  -RegistryKeyPath 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates' `
  -InventoryClassName 'SMS_G_System_SecureBoot_Main_1_0' `
  -InventoryPropertyName 'AvailableUpdates' `
  -DesiredValue '0' `
  -RuleName 'RegValue: AvailableUpdates = 0'
```

**Output**:
- Object with: `CollectionName`, `RuleName`, `RegistryKeyPath`, `InventoryClassName`, `InventoryPropertyName`, `DesiredValue`, `SiteCode`, `Action`
- `Action` is either `Added` or `AlreadyExists`

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- Existing device collection and required hardware inventory class in ConfigMgr

---

### Check-CMSecurityPosture.ps1

Checks common high-impact ConfigMgr security issues and returns prioritized hardening recommendations.

**Purpose**: Provides a quick security posture assessment for ConfigMgr site servers with actionable hardening guidance.

**Features**:
- Assesses WinRM listener posture (HTTP/HTTPS)
- Assesses SMB hardening posture (SMB1 and signing)
- Checks TLS baseline indicators for legacy protocol hardening
- Checks SQL transport encryption and authentication mode
- Reviews SQL `sysadmin` membership against an allow-list
- Checks high-privilege service account usage for core SQL/ConfigMgr services
- Returns structured findings and deduplicated recommendations

**Parameters**:
- `SiteCode` - Optional site code (auto-detected if omitted)
- `SqlServer` - SQL Server target (default: `localhost`)
- `WarningSysadminAllowList` - Allowed SQL `sysadmin` login list for warning suppression

**Example**:
```powershell
.\Check-CMSecurityPosture.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
```

**Output**:
- Object with: `ComputerName`, `SiteCode`, `AssessedAt`, `SqlServer`, `SqlConnectivity`, `SqlForceEncryption`, `SqlLoginMode`, `SysadminMembers`, `FindingCount`, `Findings`, `HardeningRecommendations`

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- SQL command-line tool (`sqlcmd.exe`) for SQL-specific checks
- Read access to local security/registry settings and SQL metadata

---

### Get-CMDailyMonitoringReport.ps1

Generates a daily ConfigMgr monitoring report with prioritized findings and hardening actions.

**Purpose**: Automates morning monitoring tasks for a ConfigMgr administrator by checking site, component, system, SQL, storage, and backlog health.

**Features**:
- Checks site status, component status, and site system status
- Checks SQL connectivity, SQL encryption, SQL login mode, and sysadmin membership
- Checks database backup recency and disk free space
- Checks inbox backlog hotspots and optional role health signals
- Returns findings sorted by severity and priority with matching recommendations
- Includes a short daily task list in the output for quick review

**Parameters**:
- `SiteCode` - Optional site code (auto-detected if omitted)
- `SqlServer` - SQL Server host to test (default: `localhost`)
- `InboxBacklogThreshold` - Inbox file count threshold before a backlog is reported
- `MinimumFreePercent` - Minimum free disk percentage before a storage warning is reported
- `TopBacklogItems` - Maximum number of inbox backlogs returned

**Example**:
```powershell
.\Get-CMDailyMonitoringReport.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
```

**Output**:
- Object with: `ComputerName`, `SiteCode`, `SqlServer`, `GeneratedAt`, `Summary`, `DailyTasks`, `Findings`, `HardeningRecommendations`, `SysadminMembers`, `DiskSummary`, `InboxBacklog`

**Requirements**:
- PowerShell 5.1 or higher
- ConfigMgr Console installed (ConfigurationManager PowerShell module)
- SQL command-line tool (`sqlcmd.exe`) available on the site server
- Read access to ConfigMgr site data and SQL metadata

---

## Requirements

### Common Requirements

All scripts require:
- **PowerShell 5.1** or higher
- **Windows Operating System** (tested on Windows Server 2016/2019/2022 and Windows 10/11)
- **Execution Policy** allowing script execution (RemoteSigned or Unrestricted)

### Script-Specific Requirements

| Script | ConfigMgr Console | SMS Provider Access | AD Module | Network Access |
|--------|------------------|---------------------|-----------|----------------|
| CheckAppSourcePaths.ps1 | Optional | Yes (WMI/CIM) | No | Source paths |
| CheckDriverPackages.ps1 | Required | Yes | No | Source paths |
| Compare-AD-CM-Clients.ps1 | No | Yes (WMI) | Optional | AD Domain |
| New-CMCollection.ps1 | Required | Yes | No | Access to ConfigMgr site server |
| Remove-CMCollection.ps1 | Required | Yes | No | Access to ConfigMgr site server |
| Add-CMCollectionRegistryRule.ps1 | Required | Yes | No | Access to ConfigMgr site server |
| Check-CMSecurityPosture.ps1 | Required | Yes | No | Access to ConfigMgr site server |
| Get-CMDailyMonitoringReport.ps1 | Required | Yes | No | Access to ConfigMgr site server |

### Permissions

The account running these scripts must have:
- **ConfigMgr**: Read permissions on SMS Provider (WMI namespace `root\SMS\site_<CODE>`)
- **File System**: Read access to all UNC/network paths being validated
- **Active Directory** (Compare script only): Read permissions on computer objects

## Installation

1. **Clone the repository**:
```powershell
git clone https://github.com/sboehle/Scripts-Sly.git
cd Scripte-Sly
```

2. **Set execution policy** (if needed):
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

3. **Verify prerequisites**:
```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Check ConfigMgr module availability (for CheckDriverPackages)
Get-Module -ListAvailable -Name ConfigurationManager

# Check ActiveDirectory module availability (optional for Compare script)
Get-Module -ListAvailable -Name ActiveDirectory
```

## Usage Examples

### Scenario 1: ConfigMgr Application Cleanup

Identify applications with missing source paths before cleanup:

```powershell
# Run the application source check
.\CheckAppSourcePaths.ps1 -OutputDirectory 'C:\Reports' -VerboseLog

# Review the CSV report
Import-Csv 'C:\Reports\AppSourceCheck_*.csv' | 
    Where-Object { $_.PathExists -eq $false } |
    Format-Table -AutoSize
```

### Scenario 2: Driver Package Audit

Audit all driver packages and identify issues:

```powershell
# Run driver package audit
.\CheckDriverPackages.ps1 -SiteCode 'P01' -VerboseOutput

# Find empty driver packages
Import-Csv 'C:\Temp\DriverPackageAudit.csv' -Delimiter ';' |
    Where-Object { $_.IsFolderEmpty -eq 'True' } |
    Select-Object PackageID, Name, SourcePath
```

### Scenario 3: ConfigMgr-AD Reconciliation

Find ConfigMgr clients missing from Active Directory:

```powershell
# Compare all clients to AD
.\Compare-AD-CM-Clients.ps1 -SiteServer 'CM01' -SiteCode 'P01' -OutputCsv '.\CM_AD_Compare.csv' -LogPath '.\Compare.log'

# Analyze missing computers
Import-Csv '.\CM_AD_Compare.csv' |
    Where-Object { $_.AD_Status -eq 'MissingInAD' } |
    Select-Object CM_Name, CM_ResourceId, CM_ClientVersion |
    Export-Csv '.\MissingComputers.csv' -NoTypeInformation
```

### Scenario 4: Multi-Domain Environment

Compare clients in specific OU across different domains:

```powershell
# Target specific OU in domain
.\Compare-AD-CM-Clients.ps1 `
    -SiteServer 'CM01' `
    -SiteCode 'P01' `
    -ADSearchBase 'OU=Workstations,OU=Europe,DC=contoso,DC=com' `
    -CollectionId 'EUR00001' `
    -OutputCsv '.\Europe_Clients.csv'
```

### Scenario 5: Create Collection Idempotently

Create a new device collection, then run the script again without creating duplicates:

```powershell
# First run creates the collection
.\New-CMCollection.ps1 -CollectionName 'TESTtest'

# Second run returns AlreadyExists
.\New-CMCollection.ps1 -CollectionName 'TESTtest'
```

### Scenario 6: Remove Collection Safely

Remove a collection only if it exists:

```powershell
.\Remove-CMCollection.ps1 -CollectionName 'TESTtest'
```

Run with preview mode first:

```powershell
.\Remove-CMCollection.ps1 -CollectionName 'TESTtest' -WhatIf
```

### Scenario 7: Add Registry-Based Query Rule

Add a query rule to include clients where `AvailableUpdates = 0`:

```powershell
.\Add-CMCollectionRegistryRule.ps1 `
  -CollectionName 'SampleCollection' `
  -RegistryKeyPath 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates' `
  -InventoryClassName 'SMS_G_System_SecureBoot_Main_1_0' `
  -InventoryPropertyName 'AvailableUpdates' `
  -DesiredValue '0' `
  -RuleName 'RegValue: AvailableUpdates = 0'
```

Run again to verify idempotency (`Action = AlreadyExists`).

### Scenario 8: Security Posture and Hardening Recommendations

Run a focused ConfigMgr security assessment:

```powershell
.\Check-CMSecurityPosture.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
```

Review high-priority findings:

```powershell
$result = .\Check-CMSecurityPosture.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
$result.Findings |
  Where-Object { $_.Severity -eq 'High' } |
  Select-Object Severity, Category, Issue, Recommendation
```

### Scenario 9: Daily Morning Monitoring

Run the daily monitoring report and review the highest priority findings:

```powershell
.\Get-CMDailyMonitoringReport.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
```

Focus on the highest severity items first:

```powershell
$report = .\Get-CMDailyMonitoringReport.ps1 -SiteCode 'PRI' -SqlServer 'SNSRV002'
$report.Findings |
  Select-Object Severity, Category, Check, Finding, Priority |
  Format-Table -AutoSize
```

## Contributing

Contributions are welcome! Please follow these guidelines:

1. **Fork the repository** and create a feature branch
2. **Follow PowerShell best practices**:
   - Use approved verbs (`Get-Verb`)
   - Include `[CmdletBinding()]` for advanced functions
   - Add comprehensive comment-based help
   - Use proper error handling
   - Follow consistent formatting (4-space indentation)
3. **Test thoroughly** in a lab environment before submitting
4. **Document changes** in commit messages and update README if needed
5. **Submit a pull request** with clear description of changes

### Code Style

- Use approved PowerShell verbs
- Include comprehensive comment-based help with examples
- Use parameter validation attributes
- Implement proper error handling with try-catch
- Use verbose logging for troubleshooting
- Follow naming conventions (PascalCase for functions, camelCase for variables)

## License

These scripts are provided "as-is" without any warranty. Use at your own risk.

The scripts are intended for administrative use in Configuration Manager environments and should be thoroughly tested before production deployment.

## Support

For issues, questions, or contributions:
- **GitHub Issues**: [Create an issue](https://github.com/sboehle/Scripts-Sly/issues)
- **Pull Requests**: [Submit improvements](https://github.com/sboehle/Scripts-Sly/pulls)

## Changelog

### 2026-07-03
- Added `Check-CMSecurityPosture.ps1` for ConfigMgr-focused security posture checks and hardening recommendations
- Added `Get-CMDailyMonitoringReport.ps1` for daily ConfigMgr monitoring and prioritized task reporting
- Added README documentation, requirements entry, and usage examples for the new monitoring script

### 2026-07-02
- Added `New-CMCollection.ps1` for idempotent ConfigMgr collection creation
- Added `Remove-CMCollection.ps1` for safe, idempotent ConfigMgr collection deletion
- Added `Add-CMCollectionRegistryRule.ps1` for idempotent registry-based collection query rules
- Added README documentation, examples, and requirements entries for new scripts

### 2026-01-20
- **Enhanced all scripts** with PowerShell best practices
- Added comprehensive comment-based help to all scripts
- Improved error handling and logging
- Added parameter validation
- Fixed syntax errors in CheckDriverPackages.ps1
- Enhanced README.md with detailed documentation

---

**Author**: Configuration Manager Administrators  
**Repository**: [https://github.com/sboehle/Scripts-Sly](https://github.com/sboehle/Scripts-Sly)  
**Last Updated**: July 03, 2026
