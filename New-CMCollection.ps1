<#
.SYNOPSIS
    Creates a Configuration Manager collection if it does not already exist.

.DESCRIPTION
    Imports the ConfigurationManager module, resolves the current site code,
    switches to the ConfigMgr PSDrive, and creates a device or user collection.
    If the collection already exists, no duplicate is created.

.PARAMETER CollectionName
    Name of the collection to create.

.PARAMETER CollectionType
    Collection type: Device or User.

.PARAMETER SiteCode
    Optional ConfigMgr site code (for example P01). If omitted, it is auto-detected.

.PARAMETER LimitingCollectionName
    Optional limiting collection name. Defaults to All Systems for device
    collections and All Users for user collections.

.EXAMPLE
    .\New-CMCollection.ps1 -CollectionName 'TESTtest'

    Creates device collection TESTtest using All Systems as limiting collection.

.EXAMPLE
    .\New-CMCollection.ps1 -CollectionName 'TESTtest' -CollectionType User -LimitingCollectionName 'All Users and User Groups'

    Creates a user collection with a custom limiting collection.

.OUTPUTS
    System.Management.Automation.PSCustomObject
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionName = 'TESTtest',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Device', 'User')]
    [string]$CollectionType = 'Device',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string]$SiteCode,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LimitingCollectionName
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

    if (-not $LimitingCollectionName) {
        if ($CollectionType -eq 'Device') {
            $LimitingCollectionName = 'All Systems'
        } else {
            $LimitingCollectionName = 'All Users'
        }
    }

    Set-Location -Path "$SiteCode`:\"

    if ($CollectionType -eq 'Device') {
        if ($supportsFastDevice) {
            $existingCollection = Get-CMDeviceCollection -Name $CollectionName -Fast -ErrorAction SilentlyContinue
        } else {
            $existingCollection = Get-CMDeviceCollection -Name $CollectionName -ErrorAction SilentlyContinue
        }
    } else {
        if ($supportsFastUser) {
            $existingCollection = Get-CMUserCollection -Name $CollectionName -Fast -ErrorAction SilentlyContinue
        } else {
            $existingCollection = Get-CMUserCollection -Name $CollectionName -ErrorAction SilentlyContinue
        }
    }

    if ($existingCollection) {
        [PSCustomObject]@{
            CollectionName = $CollectionName
            CollectionType = $CollectionType
            LimitingCollection = $LimitingCollectionName
            SiteCode = $SiteCode
            Action = 'AlreadyExists'
            CollectionId = $existingCollection.CollectionID
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($CollectionName, "Create $CollectionType collection")) {
        if ($CollectionType -eq 'Device') {
            $null = New-CMDeviceCollection -Name $CollectionName -LimitingCollectionName $LimitingCollectionName -RefreshType None
            if ($supportsFastDevice) {
                $createdCollection = Get-CMDeviceCollection -Name $CollectionName -Fast -ErrorAction Stop
            } else {
                $createdCollection = Get-CMDeviceCollection -Name $CollectionName -ErrorAction Stop
            }
        } else {
            $null = New-CMUserCollection -Name $CollectionName -LimitingCollectionName $LimitingCollectionName -RefreshType None
            if ($supportsFastUser) {
                $createdCollection = Get-CMUserCollection -Name $CollectionName -Fast -ErrorAction Stop
            } else {
                $createdCollection = Get-CMUserCollection -Name $CollectionName -ErrorAction Stop
            }
        }

        [PSCustomObject]@{
            CollectionName = $CollectionName
            CollectionType = $CollectionType
            LimitingCollection = $LimitingCollectionName
            SiteCode = $SiteCode
            Action = 'Created'
            CollectionId = $createdCollection.CollectionID
        }
    }
}
catch {
    throw "Failed to create collection '$CollectionName'. Error: $($_.Exception.Message)"
}
finally {
    Set-Location -Path $originalLocation
}
