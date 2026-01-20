In diesem Repository veröffentliche ich Scripte die im Rahmen von administrativen Tätigkeiten entwickelt wurden.

Die Scripte sind eigenverantwortlich zu testen und es wird keine Garantie oder Haftung meinerseits übernommen.

********************
CheckDriverpackages:
Dieses Script liest die Treiberpakete einer ConfigMgr Site aus und prüft die konfigurierten Sourceverzeichnisse. Existieren die Verzeichnisse und enthalten die Verzeichnisse Dateien. Das Script ist hilfreich bei Aufräumaktionen in ConfigMgr. Auch sind so schnell Treiberpakete identifiziert bei denen Sourceverzeichnisse gelöscht wurden oder deren Verzeichnisse leer sind. Leere Verzeichnisse bei Treiberpaketen führen u.U. zu Fehlern.

*************************
Compare-AD-CM-Clients.ps1:
Existiert ein AD-Computerobjekt zum ConfigMgr‑Client?
Ist dieses AD‑Objekt deaktiviert? (optional ignorierbar)
Optional: AD‑Suchbasis (OU) einstellbar
Optional: nur bestimmte Collection (über CollectionId)
CSV‑Export mit Status je Gerät („FoundInAD“, „MissingInAD“, „ADDisabled“)

Felder & Status

CM_Name / CM_ResourceId / CM_Client / CM_Active / CM_ClientVersion – aus ConfigMgr
AD_Status

FoundInAD: passender AD‑Computer gefunden
ADDisabled: AD‑Computer gefunden, deaktiviert (nur wenn -IncludeDisabledAD nicht gesetzt)
MissingInAD: kein passendes AD‑Computerobjekt gefunden

AD_Enabled / AD_DNSHostName / AD_LastLogonTimestamp – ausgewählte AD‑Details

Beispiele:

1) Alle aktiven Clients gegen gesamte Domäne prüfen, CSV & Log schreiben
.\Compare-CMClientsToAD.ps1 -SiteServer CM01 -SiteCode P01 -OutputCsv .\CM_vs_AD.csv -LogPath .\Compare.log

2) Auf eine Collection einschränken und innerhalb einer OU suchen
.\Compare-CMClientsToAD.ps1 -SiteServer CM01 -SiteCode P01 -CollectionId SMS00001 -ADSearchBase "OU=Workstations,OU=HQ,DC=contoso,DC=com" -OutputCsv .\OU_Scope.csv

3) Deaktivierte AD-Konten nicht als Befund werten
.\Compare-CMClientsToAD.ps1 -SiteServer CM01 -SiteCode P01 -IncludeDisabledAD

Hinweise / Anpassungen
Namensauflösung: Das Skript versucht zuerst mit FQDN (falls vorhanden), dann mit NetBIOS‑Name zu matchen.
Mehrdomänen-Umgebungen: Setze -ADSearchBase, um auf die richtige Domäne/OU einzugrenzen.
Leistung: Für sehr große Umgebungen empfiehlt sich die Eingrenzung über -CollectionId oder -ADSearchBase.
Rechte: Es sind Leserechte auf dem SMS Provider und im AD erforderlich.
