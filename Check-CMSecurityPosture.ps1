<#
.SYNOPSIS
    Checks common high-impact ConfigMgr security issues and suggests hardening steps.

.DESCRIPTION
    Runs a focused security posture assessment on a ConfigMgr site server.
    The script checks protocol exposure, SMB hardening, TLS baseline signals,
    SQL encryption/authentication settings, SQL sysadmin membership, and service
    account privilege level for core ConfigMgr/SQL services.

    Returns a structured result with findings and prioritized recommendations.

.PARAMETER SiteCode
    Optional ConfigMgr site code. If omitted, it is auto-detected from CMSite PSDrive.

.PARAMETER SqlServer
    SQL Server target for SQL-specific checks. Default: localhost.

.PARAMETER WarningSysadminAllowList
    Optional list of SQL sysadmin logins that are considered approved.
    Logins outside this list are reported as findings.

.EXAMPLE
    .\Check-CMSecurityPosture.ps1

    Runs assessment with auto-detected site code and localhost SQL target.

.EXAMPLE
    .\Check-CMSecurityPosture.ps1 -SqlServer 'SNSRV002'

    Runs assessment against SQL instance on SNSRV002.

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
    [string[]]$WarningSysadminAllowList = @(
        'NT AUTHORITY\SYSTEM',
        'NT SERVICE\MSSQLSERVER',
        'NT SERVICE\SQLSERVERAGENT'
    )
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
        [string]$Issue,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentState,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Recommendation
    )

    [PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Issue = $Issue
        CurrentState = $CurrentState
        Recommendation = $Recommendation
    }
}

function Get-SqlQueryResult {
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

try {
    Import-Module -Name ConfigurationManager -ErrorAction Stop

    if (-not $SiteCode) {
        $siteDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $siteDrive) {
            throw 'No CMSite PSDrive found. Open ConfigMgr PowerShell context first.'
        }
        $SiteCode = $siteDrive.Name
    }

    $findings = [System.Collections.Generic.List[object]]::new()

    # WinRM listener posture
    $listenerText = (winrm enumerate winrm/config/listener 2>$null | Out-String)
    $hasHttp = $listenerText -match 'Transport = HTTP'
    $hasHttps = $listenerText -match 'Transport = HTTPS'
    if ($hasHttp -and -not $hasHttps) {
        $findings.Add((New-Finding -Severity High -Category 'Remote Management' -Issue 'WinRM HTTP-only listener' -CurrentState 'HTTP (5985) enabled, HTTPS listener not detected.' -Recommendation 'Configure WinRM HTTPS (5986) with server certificate and restrict/disable HTTP where possible.'))
    }

    # SMB hardening
    $smb = Get-SmbServerConfiguration
    if ($smb.EnableSMB1Protocol) {
        $findings.Add((New-Finding -Severity High -Category 'SMB' -Issue 'SMB1 enabled' -CurrentState 'EnableSMB1Protocol=True' -Recommendation 'Disable SMB1 protocol on server and verify legacy dependencies before enforcement.'))
    }
    if (-not $smb.RequireSecuritySignature -or -not $smb.EnableSecuritySignature) {
        $findings.Add((New-Finding -Severity High -Category 'SMB' -Issue 'SMB signing not enforced' -CurrentState "RequireSecuritySignature=$($smb.RequireSecuritySignature), EnableSecuritySignature=$($smb.EnableSecuritySignature)" -Recommendation 'Enable and require SMB signing via policy baseline on servers and clients.'))
    }

    # TLS baseline signals
    $tls10 = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server' -ErrorAction SilentlyContinue
    $tls11 = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server' -ErrorAction SilentlyContinue
    if (($tls10.Enabled -ne 0) -or ($tls11.Enabled -ne 0)) {
        $findings.Add((New-Finding -Severity Medium -Category 'TLS' -Issue 'Legacy TLS protocols may be enabled' -CurrentState 'TLS 1.0/1.1 server disable state not explicitly hardened.' -Recommendation 'Disable TLS 1.0/1.1 and weak cipher suites after compatibility testing.'))
    }

    # Service account posture
    $serviceNames = @('MSSQLSERVER', 'SQLSERVERAGENT', 'SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')
    $svc = Get-CimInstance Win32_Service | Where-Object { $_.Name -in $serviceNames }
    $localSystemSvc = $svc | Where-Object { $_.StartName -eq 'LocalSystem' }
    foreach ($item in $localSystemSvc) {
        $findings.Add((New-Finding -Severity High -Category 'Service Accounts' -Issue "Service $($item.Name) runs as LocalSystem" -CurrentState 'StartName=LocalSystem' -Recommendation 'Migrate to least-privileged domain account or gMSA where supported, then validate component health.'))
    }

    # SQL posture checks
    $sqlCmdPresent = $null -ne (Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue)
    $sqlConnectivity = 'NotTested'
    $sqlForceEncryption = 'Unknown'
    $sqlLoginMode = 'Unknown'
    $sysadminLogins = @()

    if ($sqlCmdPresent) {
        try {
            $null = Get-SqlQueryResult -Server $SqlServer -Query 'SET NOCOUNT ON; SELECT @@SERVERNAME;'
            $sqlConnectivity = 'OK'

            $instanceReg = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
            $sqlNet = Get-ItemProperty -Path $instanceReg -ErrorAction SilentlyContinue
            if ($sqlNet) {
                $sqlForceEncryption = $sqlNet.ForceEncryption
                if ($sqlForceEncryption -ne 1) {
                    $findings.Add((New-Finding -Severity High -Category 'SQL Transport' -Issue 'SQL ForceEncryption disabled' -CurrentState "ForceEncryption=$sqlForceEncryption" -Recommendation 'Set SQL ForceEncryption=1 and ensure certificate trust chain is valid for all SQL clients.'))
                }
            }

            $sqlBase = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer' -ErrorAction SilentlyContinue
            if ($sqlBase) {
                $sqlLoginMode = if ($sqlBase.LoginMode -eq 1) { 'WindowsOnly' } elseif ($sqlBase.LoginMode -eq 2) { 'Mixed' } else { 'Unknown' }
                if ($sqlBase.LoginMode -eq 2) {
                    $findings.Add((New-Finding -Severity Medium -Category 'SQL Authentication' -Issue 'SQL mixed mode enabled' -CurrentState 'LoginMode=Mixed' -Recommendation 'Prefer Windows-only authentication for ConfigMgr SQL instance unless SQL auth is strictly required.'))
                }
            }

            $sysadminRaw = Get-SqlQueryResult -Server $SqlServer -Query "SET NOCOUNT ON; SELECT sp.name FROM sys.server_principals sp INNER JOIN sys.server_role_members rm ON rm.member_principal_id=sp.principal_id INNER JOIN sys.server_principals r ON r.principal_id=rm.role_principal_id WHERE r.name='sysadmin' ORDER BY sp.name;"
            $sysadminLogins = $sysadminRaw | Where-Object { $_ -and $_.Trim() }

            foreach ($login in $sysadminLogins) {
                if ($WarningSysadminAllowList -notcontains $login) {
                    $findings.Add((New-Finding -Severity Medium -Category 'SQL Authorization' -Issue "Unexpected sysadmin membership: $login" -CurrentState "sysadmin includes $login" -Recommendation 'Review and remove unnecessary sysadmin principals. Use role separation and JIT elevation for admin tasks.'))
                }
            }
        }
        catch {
            $findings.Add((New-Finding -Severity Medium -Category 'SQL Connectivity' -Issue 'Unable to complete SQL security checks' -CurrentState $_.Exception.Message -Recommendation 'Validate SQL connectivity and permissions, then rerun security posture assessment.'))
            $sqlConnectivity = 'Failed'
        }
    }
    else {
        $findings.Add((New-Finding -Severity Low -Category 'Tooling' -Issue 'sqlcmd not found on server' -CurrentState 'sqlcmd.exe missing' -Recommendation 'Install SQL command-line tooling to enable automated SQL posture checks.'))
    }

    $recommendations = $findings |
        Sort-Object @{ Expression = { switch ($_.Severity) { 'High' { 1 } 'Medium' { 2 } default { 3 } } } }, Category |
        Select-Object Severity, Category, Recommendation -Unique

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        SiteCode = $SiteCode
        AssessedAt = Get-Date
        SqlServer = $SqlServer
        SqlConnectivity = $sqlConnectivity
        SqlForceEncryption = $sqlForceEncryption
        SqlLoginMode = $sqlLoginMode
        SysadminMembers = $sysadminLogins
        FindingCount = @($findings).Count
        Findings = $findings
        HardeningRecommendations = $recommendations
    }
}
catch {
    throw "Security posture check failed. Error: $($_.Exception.Message)"
}
