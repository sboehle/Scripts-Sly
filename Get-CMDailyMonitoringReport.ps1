<#
.SYNOPSIS
    Generates a daily ConfigMgr monitoring report with prioritized findings.

.DESCRIPTION
    Checks the most relevant daily monitoring tasks for a ConfigMgr site server:
    - Site status
    - Component status
    - Site system status
    - Core service health
    - SQL availability, SQL login mode, and SQL encryption
    - Backup recency for the site database
    - Inbox backlog hotspots
    - Free disk space on important volumes
    - Optional role checks for management point, distribution point, and SUP-related health

    The script returns a structured report sorted by severity, with the most
    serious findings first, followed by a concise daily task summary.

.PARAMETER SiteCode
    Optional ConfigMgr site code. If omitted, the site code is auto-detected.

.PARAMETER SqlServer
    SQL Server host to test. Default: localhost.

.PARAMETER InboxBacklogThreshold
    File count threshold above which an inbox is reported as backlog.

.PARAMETER MinimumFreePercent
    Minimum free disk percentage recommended for monitored volumes.

.PARAMETER TopBacklogItems
    Maximum number of inbox backlogs returned in the report.

.EXAMPLE
    .\Get-CMDailyMonitoringReport.ps1

    Generates the report using the current ConfigMgr PowerShell context.

.EXAMPLE
    .\Get-CMDailyMonitoringReport.ps1 -SiteCode PRI -SqlServer SNSRV002

    Runs the report against the PRI site and the SNSRV002 SQL host.

.OUTPUTS
    System.Management.Automation.PSCustomObject
#>

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string]$SiteCode,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlServer = 'localhost',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 999999)]
    [int]$InboxBacklogThreshold = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$MinimumFreePercent = 15,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$TopBacklogItems = 10
)

$ErrorActionPreference = 'Stop'

function New-Finding {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('High', 'Medium', 'Low')]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Finding,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentState,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Recommendation,

        [Parameter(Mandatory = $false)]
        [int]$Priority = 100
    )

    [PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Check = $Check
        Finding = $Finding
        CurrentState = $CurrentState
        Recommendation = $Recommendation
        Priority = $Priority
    }
}

function Get-SqlCmdOutput {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Query
    )

    $sqlCmd = (Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if (-not $sqlCmd) {
        throw 'sqlcmd.exe not found.'
    }

    $output = & $sqlCmd -S $Server -E -Q $Query -W -s '|' -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL query failed: $($output | Select-Object -First 1)"
    }

    return $output
}

function Get-SiteCodeFromContext {
    $siteDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($siteDrive) {
        return $siteDrive.Name
    }

    $providerLocation = Get-CimInstance -Namespace 'root\SMS' -ClassName 'SMS_ProviderLocation' -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderForLocalSite -eq $true } |
        Select-Object -First 1

    if ($providerLocation) {
        return $providerLocation.SiteCode
    }

    throw 'Unable to determine site code. Open the ConfigMgr PowerShell console first or specify -SiteCode.'
}

try {
    Import-Module -Name ConfigurationManager -ErrorAction Stop

    if (-not $SiteCode) {
        $SiteCode = Get-SiteCodeFromContext
    }

    $siteDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($siteDrive -and $siteDrive.Name -ne $SiteCode) {
        try {
            Set-Location "$SiteCode`:\"
        }
        catch {
            Set-Location "$($siteDrive.Name)`:\"
        }
    }
    elseif ($siteDrive) {
        Set-Location "$SiteCode`:\"
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    $dailyTasks = [System.Collections.Generic.List[string]]::new()

    $dailyTasks.Add('Review site status, component status, and site system status for non-green entries.')
    $dailyTasks.Add('Check SQL connectivity, backup recency, and SQL privilege drift.')
    $dailyTasks.Add('Review inbox backlogs, disk free space, and core service health.')
    $dailyTasks.Add('Review optional role health for management points, distribution points, and SUP-related components.')

    # Site status
    $site = Get-CimInstance -Namespace "root\SMS\site_$SiteCode" -ClassName SMS_Site -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($site -and $site.Status -ne 1) {
        $findings.Add((New-Finding -Severity High -Category 'Site' -Check 'Site status' -Finding "Site status is $($site.Status)" -CurrentState "SiteCode=$($site.SiteCode); Status=$($site.Status)" -Recommendation 'Investigate site health and recent status changes in the Monitoring node.' -Priority 1))
    }

    # Component status
    $componentIssues = Get-CimInstance -Namespace "root\SMS\site_$SiteCode" -ClassName SMS_ComponentSummarizer -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 0 } |
        Sort-Object -Property @{ Expression = { $_.Severity } }, @{ Expression = { $_.ComponentName } }

    foreach ($item in $componentIssues) {
        $severity = if ($item.Severity -ge 3 -or $item.Status -ge 2) { 'High' } elseif ($item.Severity -ge 2 -or $item.Status -eq 1) { 'Medium' } else { 'Low' }
        $findings.Add((New-Finding -Severity $severity -Category 'Component' -Check 'Component status' -Finding "Component $($item.ComponentName) is not healthy" -CurrentState "Status=$($item.Status); Severity=$($item.Severity)" -Recommendation 'Review the component log and recent status messages; resolve the underlying service or dependency issue.' -Priority 10))
    }

    # Site system status
    $siteSystemIssues = Get-CimInstance -Namespace "root\SMS\site_$SiteCode" -ClassName SMS_SiteSystemSummarizer -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 0 } |
        Sort-Object SiteSystem, Role, Status -Unique

    foreach ($item in $siteSystemIssues) {
        $findings.Add((New-Finding -Severity Medium -Category 'Site System' -Check 'Site system status' -Finding "$($item.Role) on $($item.SiteSystem) is not healthy" -CurrentState "Status=$($item.Status)" -Recommendation 'Check the role-specific logs, server health, and connectivity from the site server.' -Priority 20))
    }

    # Core service health
    $serviceNames = @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER', 'MSSQLSERVER', 'SQLSERVERAGENT', 'SMS_NOTIFICATION_SERVER', 'SMS_WSUS_CONTROL_MANAGER')
    $services = Get-CimInstance Win32_Service | Where-Object { $_.Name -in $serviceNames }
    foreach ($svc in $services | Where-Object { $_.State -ne 'Running' }) {
        $findings.Add((New-Finding -Severity High -Category 'Services' -Check 'Core service health' -Finding "Service $($svc.Name) is not running" -CurrentState "State=$($svc.State); StartName=$($svc.StartName)" -Recommendation 'Restore the service and inspect dependency/service logs before returning to production monitoring.' -Priority 5))
    }

    # SQL connectivity and posture
    $sqlConnectivity = 'NotTested'
    $sqlForceEncryption = 'Unknown'
    $sqlLoginMode = 'Unknown'
    $sysadminMembers = @()

    try {
        $null = Get-SqlCmdOutput -Server $SqlServer -Query 'SET NOCOUNT ON; SELECT @@SERVERNAME;'
        $sqlConnectivity = 'OK'

        $sqlNetPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
        $sqlNet = Get-ItemProperty -Path $sqlNetPath -ErrorAction SilentlyContinue
        if ($sqlNet) {
            $sqlForceEncryption = $sqlNet.ForceEncryption
            if ($sqlForceEncryption -ne 1) {
                $findings.Add((New-Finding -Severity High -Category 'SQL' -Check 'SQL transport encryption' -Finding 'SQL ForceEncryption is disabled' -CurrentState 'ForceEncryption=0' -Recommendation 'Enable SQL ForceEncryption and validate certificate trust for all clients.' -Priority 2))
            }
        }

        $sqlBasePath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer'
        $sqlBase = Get-ItemProperty -Path $sqlBasePath -ErrorAction SilentlyContinue
        if ($sqlBase) {
            $sqlLoginMode = if ($sqlBase.LoginMode -eq 1) { 'WindowsOnly' } elseif ($sqlBase.LoginMode -eq 2) { 'Mixed' } else { 'Unknown' }
            if ($sqlBase.LoginMode -eq 2) {
                $findings.Add((New-Finding -Severity Medium -Category 'SQL' -Check 'SQL authentication mode' -Finding 'SQL mixed mode is enabled' -CurrentState 'LoginMode=Mixed' -Recommendation 'Prefer Windows-only authentication for the ConfigMgr SQL instance unless SQL authentication is explicitly required.' -Priority 30))
            }
        }

        $sysadminQuery = "SET NOCOUNT ON; SELECT sp.name + '|' + CAST(sp.is_disabled AS varchar(1)) FROM sys.server_principals sp INNER JOIN sys.server_role_members rm ON rm.member_principal_id=sp.principal_id INNER JOIN sys.server_principals r ON r.principal_id=rm.role_principal_id WHERE r.name='sysadmin' ORDER BY sp.name;"
        $sysadminRaw = Get-SqlCmdOutput -Server $SqlServer -Query $sysadminQuery | Where-Object { $_ -and $_.Trim() }
        $sysadminMembers = foreach ($line in $sysadminRaw) {
            $parts = $line -split '\|', 2
            [PSCustomObject]@{
                Name = $parts[0]
                IsDisabled = [bool]([int]$parts[1])
            }
        }
        $allowedSysadmins = @(
            'NT AUTHORITY\SYSTEM',
            'NT SERVICE\MSSQLSERVER',
            'NT SERVICE\SQLSERVERAGENT',
            'NT SERVICE\SQLWriter',
            'NT SERVICE\Winmgmt'
        )
        foreach ($member in $sysadminMembers) {
            if (-not $member.IsDisabled -and $allowedSysadmins -notcontains $member.Name) {
                $findings.Add((New-Finding -Severity Medium -Category 'SQL' -Check 'SQL sysadmin membership' -Finding "Unexpected active sysadmin principal: $($member.Name)" -CurrentState "sysadmin=$($member.Name); Disabled=$($member.IsDisabled)" -Recommendation 'Review SQL sysadmin membership and remove unnecessary administrative principals.' -Priority 40))
            }
        }
    }
    catch {
        $findings.Add((New-Finding -Severity Medium -Category 'SQL' -Check 'SQL connectivity' -Finding 'SQL security checks could not complete' -CurrentState $_.Exception.Message -Recommendation 'Verify SQL connectivity and permissions, then rerun the report.' -Priority 35))
    }

    # Backup recency
    try {
        $dbName = if ($SiteCode) { "CM_$SiteCode" } else { 'CM_PRI' }
        $backupQuery = "SET NOCOUNT ON; SELECT COALESCE(CONVERT(varchar(19), MAX(backup_finish_date), 120), 'NULL') FROM msdb.dbo.backupset WHERE database_name = '$dbName' AND type='D';"
        $backupResult = Get-SqlCmdOutput -Server $SqlServer -Query $backupQuery | Select-Object -First 1
        if ($backupResult -eq 'NULL') {
            $findings.Add((New-Finding -Severity High -Category 'Backup' -Check 'Database backup recency' -Finding "No full backup history found for $dbName" -CurrentState 'LastFullBackup=NULL' -Recommendation 'Verify database backup jobs and backup history retention immediately.' -Priority 3))
        }
        else {
            try {
                $backupDate = [datetime]::ParseExact($backupResult, 'yyyy-MM-dd HH:mm:ss', $null)
                $ageDays = (New-TimeSpan -Start $backupDate -End (Get-Date)).Days
                if ($ageDays -gt 1) {
                    $findings.Add((New-Finding -Severity High -Category 'Backup' -Check 'Database backup recency' -Finding "Last full backup is $ageDays day(s) old" -CurrentState "LastFullBackup=$backupResult" -Recommendation 'Confirm daily backup success and investigate stalled or missing backup jobs.' -Priority 4))
                }
            }
            catch {
                $findings.Add((New-Finding -Severity Medium -Category 'Backup' -Check 'Database backup recency' -Finding 'Could not parse backup timestamp' -CurrentState "LastFullBackup=$backupResult" -Recommendation 'Validate the SQL backup history format and backup job outputs.' -Priority 45))
            }
        }
    }
    catch {
        $findings.Add((New-Finding -Severity Medium -Category 'Backup' -Check 'Database backup recency' -Finding 'Could not verify backup recency' -CurrentState $_.Exception.Message -Recommendation 'Check SQL backup history and site maintenance tasks.' -Priority 45))
    }

    # Disk space
    $disk = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Select-Object DeviceID, Size, FreeSpace, @{N='FreePct'; E={ if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } else { 0 } }}

    foreach ($d in $disk | Where-Object { $_.FreePct -lt $MinimumFreePercent }) {
        $findings.Add((New-Finding -Severity High -Category 'Storage' -Check 'Disk free space' -Finding "Drive $($d.DeviceID) below threshold" -CurrentState "FreePct=$($d.FreePct)" -Recommendation 'Free space or expand the volume; watch site and SQL data locations closely.' -Priority 6))
    }

    # Inbox backlogs
    $inboxRoots = @(
        'C:\Program Files\Microsoft Configuration Manager\inboxes',
        'D:\Program Files\Microsoft Configuration Manager\inboxes'
    )
    $existingInboxRoot = $inboxRoots | Where-Object { Test-Path $_ } | Select-Object -First 1
    $inboxBacklog = @()
    if ($existingInboxRoot) {
        $inboxBacklog = Get-ChildItem -Path $existingInboxRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $count = (Get-ChildItem -Path $_.FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
                [PSCustomObject]@{ Inbox = $_.Name; FileCount = $count }
            } |
            Where-Object { $_.FileCount -ge $InboxBacklogThreshold } |
            Sort-Object FileCount -Descending |
            Select-Object -First $TopBacklogItems

        foreach ($b in $inboxBacklog) {
            $findings.Add((New-Finding -Severity Medium -Category 'Inbox' -Check 'Inbox backlog' -Finding "Inbox $($b.Inbox) has $($b.FileCount) file(s)" -CurrentState "Threshold=$InboxBacklogThreshold" -Recommendation 'Inspect the inbox handler or downstream role that processes these files.' -Priority 25))
        }
    }

    # Optional role summary signals
    $roleSignals = $siteSystemIssues | Where-Object { $_.Role -match 'Management Point|Distribution Point|Software Update Point|Reporting Services Point' }
    foreach ($role in $roleSignals) {
        $findings.Add((New-Finding -Severity Medium -Category 'Role' -Check 'Optional role health' -Finding "$($role.Role) on $($role.SiteSystem) is not healthy" -CurrentState "Status=$($role.Status)" -Recommendation 'Review role-specific logs and connectivity for the affected site system.' -Priority 22))
    }

    $severityRank = @{
        High = 1
        Medium = 2
        Low = 3
    }

    $sortedFindings = $findings |
        Sort-Object -Property @{ Expression = { $severityRank[$_.Severity] } }, @{ Expression = { $_.Priority } }, @{ Expression = { $_.Category } }

    $recommendations = $sortedFindings |
        Select-Object Severity, Category, Recommendation -Unique

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        SiteCode = $SiteCode
        SqlServer = $SqlServer
        GeneratedAt = Get-Date
        Summary = [PSCustomObject]@{
            FindingCount = @($sortedFindings).Count
            HighCount = @($sortedFindings | Where-Object { $_.Severity -eq 'High' }).Count
            MediumCount = @($sortedFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
            LowCount = @($sortedFindings | Where-Object { $_.Severity -eq 'Low' }).Count
            SQLConnectivity = $sqlConnectivity
            SQLForceEncryption = $sqlForceEncryption
            SQLLoginMode = $sqlLoginMode
        }
        DailyTasks = $dailyTasks
        Findings = $sortedFindings
        HardeningRecommendations = $recommendations
        SysadminMembers = @($sysadminMembers | ForEach-Object { $_.Name })
        DiskSummary = $disk
        InboxBacklog = $inboxBacklog
    }
}
catch {
    throw "Daily monitoring report failed. Error: $($_.Exception.Message)"
}
