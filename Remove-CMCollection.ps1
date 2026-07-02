<#
.SYNOPSIS
    Removes a Configuration Manager collection if it exists.

.DESCRIPTION
    Imports the ConfigurationManager module, resolves the current site code,
    switches to the ConfigMgr PSDrive, detects the collection type, and removes
    the collection. If the collection does not exist, no error is raised.

.PARAMETER CollectionName
    Name of the collection to remove.

.PARAMETER CollectionType
    Collection type: Auto, Device, or User.
    Auto checks device first, then user collections.

.PARAMETER SiteCode
    Optional ConfigMgr site code (for example PRI). If omitted, it is auto-detected.

.EXAMPLE
    .\Remove-CMCollection.ps1 -CollectionName 'TESTtest'

    Removes collection TESTtest if present.

.OUTPUTS
    System.Management.Automation.PSCustomObject
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionName = 'TESTtest',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Device', 'User')]
    [string]$CollectionType = 'Auto',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string]$SiteCode
)

$ErrorActionPreference = 'Stop'
$originalLocation = Get-Location

try {
    Import-Module -Name ConfigurationManager -ErrorAction Stop

    $supportsFastDevice = (Get-Command -Name Get-CMDeviceCollection -ErrorAction Stop).Parameters.ContainsKey('Fast')
    $supportsFastUser = (Get-Command -Name Get-CMUserCollection -ErrorAction Stop).Parameters.ContainsKey('Fast')

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

    $targetCollection = $null
    $resolvedType = $null

    if ($CollectionType -in @('Auto', 'Device')) {
        if ($supportsFastDevice) {
            $targetCollection = Get-CMDeviceCollection -Name $CollectionName -Fast -ErrorAction SilentlyContinue
        } else {
            $targetCollection = Get-CMDeviceCollection -Name $CollectionName -ErrorAction SilentlyContinue
        }

        if ($targetCollection) {
            $resolvedType = 'Device'
        }
    }

    if (-not $targetCollection -and $CollectionType -in @('Auto', 'User')) {
        if ($supportsFastUser) {
            $targetCollection = Get-CMUserCollection -Name $CollectionName -Fast -ErrorAction SilentlyContinue
        } else {
            $targetCollection = Get-CMUserCollection -Name $CollectionName -ErrorAction SilentlyContinue
        }

        if ($targetCollection) {
            $resolvedType = 'User'
        }
    }

    if (-not $targetCollection) {
        [PSCustomObject]@{
            CollectionName = $CollectionName
            CollectionType = $CollectionType
            SiteCode = $SiteCode
            Action = 'NotFound'
            CollectionId = $null
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($CollectionName, "Remove $resolvedType collection")) {
        if ($resolvedType -eq 'Device') {
            Remove-CMDeviceCollection -Id $targetCollection.CollectionID -Force -ErrorAction Stop
        } else {
            Remove-CMUserCollection -Id $targetCollection.CollectionID -Force -ErrorAction Stop
        }

        [PSCustomObject]@{
            CollectionName = $CollectionName
            CollectionType = $resolvedType
            SiteCode = $SiteCode
            Action = 'Removed'
            CollectionId = $targetCollection.CollectionID
        }
    }
}
catch {
    throw "Failed to remove collection '$CollectionName'. Error: $($_.Exception.Message)"
}
finally {
    Set-Location -Path $originalLocation
}
