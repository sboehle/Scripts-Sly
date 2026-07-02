<#
.SYNOPSIS
    Adds a query membership rule to a ConfigMgr device collection for a registry-backed inventory value.

.DESCRIPTION
    Imports the ConfigurationManager module, resolves site code, validates the target
    inventory class and collection, builds a WQL query, and adds a query membership rule.
    If a rule with the same query already exists, the script returns AlreadyExists.

.PARAMETER CollectionName
    Existing device collection that should receive the query rule.

.PARAMETER RegistryKeyPath
    Registry key path for documentation context in the rule name.

.PARAMETER InventoryClassName
    Hardware inventory class that contains the value to query.

.PARAMETER InventoryPropertyName
    Property name in the inventory class to compare.

.PARAMETER DesiredValue
    Value that clients must match.

.PARAMETER RuleName
    Optional explicit rule name. If omitted, a descriptive name is generated.

.PARAMETER SiteCode
    Optional ConfigMgr site code (for example PRI). If omitted, it is auto-detected.

.EXAMPLE
    .\Add-CMCollectionRegistryRule.ps1

    Adds a rule to collection SampleCollection that targets AvailableUpdates = 0.

.OUTPUTS
    System.Management.Automation.PSCustomObject
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionName = 'SampleCollection',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RegistryKeyPath = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$InventoryClassName = 'SMS_G_System_SecureBoot_Main_1_0',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$InventoryPropertyName = 'AvailableUpdates',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DesiredValue = '0',

    [Parameter(Mandatory = $false)]
    [string]$RuleName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string]$SiteCode
)

$ErrorActionPreference = 'Stop'
$originalLocation = Get-Location

function Get-NormalizedWql {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$QueryText
    )

    return (($QueryText -replace '\s+', '').Trim().ToLowerInvariant())
}

try {
    Import-Module -Name ConfigurationManager -ErrorAction Stop

    if (-not $SiteCode) {
        $siteDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($siteDrive) {
            $SiteCode = $siteDrive.Name
        } else {
            $providerLocation = Get-CimInstance -Namespace 'root\SMS' -ClassName 'SMS_ProviderLocation' |
                Where-Object { $_.ProviderForLocalSite -eq $true } |
                Select-Object -First 1

            if (-not $providerLocation) {
                throw 'Unable to determine ConfigMgr site code from SMS_ProviderLocation.'
            }

            $SiteCode = $providerLocation.SiteCode
        }
    }

    Set-Location -Path "$SiteCode`:\"

    $siteNamespace = "root\SMS\site_$SiteCode"
    $inventoryClass = Get-CimClass -Namespace $siteNamespace -ClassName $InventoryClassName -ErrorAction SilentlyContinue
    if (-not $inventoryClass) {
        throw "Inventory class '$InventoryClassName' was not found in namespace $siteNamespace."
    }

    if (-not ($inventoryClass.CimClassProperties.Name -contains $InventoryPropertyName)) {
        throw "Property '$InventoryPropertyName' was not found in class '$InventoryClassName'."
    }

    $collection = Get-CMDeviceCollection -Name $CollectionName -ErrorAction SilentlyContinue
    if (-not $collection) {
        throw "Device collection '$CollectionName' does not exist."
    }

    $valueLiteral = $DesiredValue
    if ($DesiredValue -notmatch '^-?\d+$') {
        $escaped = $DesiredValue.Replace("'", "''")
        $valueLiteral = "'$escaped'"
    }

    $queryExpression = @"
select SMS_R_System.ResourceID,
       SMS_R_System.ResourceType,
       SMS_R_System.Name,
       SMS_R_System.SMSUniqueIdentifier,
       SMS_R_System.ResourceDomainORWorkgroup,
       SMS_R_System.Client
from SMS_R_System
inner join $InventoryClassName as Inv on Inv.ResourceID = SMS_R_System.ResourceID
where Inv.$InventoryPropertyName = $valueLiteral
"@

    if (-not $RuleName) {
        $RuleName = "RegValue: $InventoryPropertyName = $DesiredValue"
    }

    $existingRules = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -ErrorAction SilentlyContinue
    $normalizedTargetQuery = Get-NormalizedWql -QueryText $queryExpression
    $sameQueryRule = $existingRules |
        Where-Object { (Get-NormalizedWql -QueryText $_.QueryExpression) -eq $normalizedTargetQuery } |
        Select-Object -First 1

    if ($sameQueryRule) {
        [PSCustomObject]@{
            CollectionName = $CollectionName
            RuleName = $sameQueryRule.RuleName
            RegistryKeyPath = $RegistryKeyPath
            InventoryClassName = $InventoryClassName
            InventoryPropertyName = $InventoryPropertyName
            DesiredValue = $DesiredValue
            SiteCode = $SiteCode
            Action = 'AlreadyExists'
        }
        return
    }

    $sameNameRule = $existingRules | Where-Object { $_.RuleName -eq $RuleName } | Select-Object -First 1
    if ($sameNameRule) {
        throw "A rule named '$RuleName' already exists in collection '$CollectionName' with a different query."
    }

    if ($PSCmdlet.ShouldProcess($CollectionName, "Add query rule '$RuleName'")) {
        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -RuleName $RuleName -QueryExpression $queryExpression -ErrorAction Stop

        [PSCustomObject]@{
            CollectionName = $CollectionName
            RuleName = $RuleName
            RegistryKeyPath = $RegistryKeyPath
            InventoryClassName = $InventoryClassName
            InventoryPropertyName = $InventoryPropertyName
            DesiredValue = $DesiredValue
            SiteCode = $SiteCode
            Action = 'Added'
        }
    }
}
catch {
    throw "Failed to add collection query rule. Error: $($_.Exception.Message)"
}
finally {
    Set-Location -Path $originalLocation
}
