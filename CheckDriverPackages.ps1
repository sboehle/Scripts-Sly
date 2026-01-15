<#
.SYNOPSIS
    Prüft ConfigMgr Treiberpakete hinsichtlich der hinterlegten Sourcen. Sind die Sourcen noch vorhanden und enthalten die Verzeichnisse auch Dateien.
    $SiteCode muss angegeben werden!
#>

# --- KONFIGURATION ---
$CsvOutputPath = "C:\Temp\DriverPackageAudit.csv"
$SiteCode = $null
# ---------------------

$ErrorActionPreference = "Stop"

try {
    # 1. Modul laden & Verbinden
    if (-not (Get-Module -Name ConfigurationManager)) {
        $AdminConsolePath = Join-Path $env:SMS_ADMIN_UI_PATH ".."
        Import-Module (Join-Path $AdminConsolePath "ConfigurationManager.psd1")
    }

    if (-not $SiteCode) {
        $SiteProvider = Get-PSDrive -PSProvider CMSite
        if ($SiteProvider) { $SiteCode = $SiteProvider.Name + ":" }
        else { Throw "Kein SiteCode gefunden." }
    }

    Set-Location $SiteCode
    Write-Host "Verbunden mit Site: $SiteCode" -ForegroundColor Green

    # 2. Treiberpakete holen
    $DriverPackages = Get-CMDriverPackage
    $Report = @()

    foreach ($Pkg in $DriverPackages) {
        $SourcePath = $Pkg.PkgSourcePath
       
        # Pfad, der explizit den FileSystem-Provider nutzt
        if ($SourcePath -match "^\\\\") {
            # UNC Pfad
            $TestablePath = "FileSystem::$SourcePath"
        } elseif ($SourcePath -match "^[a-zA-Z]:") {
            # Lokaler Pfad (z.B. D:\Sources)
            $TestablePath = "FileSystem::$SourcePath"
        } else {
            # Unbekanntes Format
            $TestablePath = $SourcePath
        }
        # --------------------------------------------

        $PathExists = $false
        $IsFolderEmpty = $null
        $StatusInfo = "OK"

        if ([string]::IsNullOrWhiteSpace($SourcePath)) {
            $StatusInfo = "Pfad ist in SCCM leer"
        }
         
        elseif (Test-Path -LiteralPath $TestablePath) {
            $PathExists = $true
           
            
            $Content = Get-ChildItem -LiteralPath $TestablePath -Force -ErrorAction SilentlyContinue | Select-Object -First 1
           
            if ($Content) {
                $IsFolderEmpty = $false
            } else {
                $IsFolderEmpty = $true
                $StatusInfo = "WARNUNG: Verzeichnis leer"
            }
        }
        else {
            $PathExists = $false
            $StatusInfo = "FEHLER: Verzeichnis nicht gefunden (oder Zugriff verweigert)"
        }

        $Report += [PSCustomObject]@{
            PackageID     ageID
            Name            = $Pkg.Name
            SourcePath      = $SourcePath
            PathExists      = $PathExists
            IsFolderEmpty   = $IsFolderEmpty
            Status          = $StatusInfo
        }
    }

    $ExportDir = Split-Path $CsvOutputPath
    if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir | Out-Null }
    $Report | Export-Csv -Path $CsvOutputPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
   
    Write-Host "Export fertig: $CsvOutputPath" -ForegroundColor Green
}
catch {
    Write-Error "Fehler: $_"
}
