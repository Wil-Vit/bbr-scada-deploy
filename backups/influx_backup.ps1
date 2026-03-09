# ============================================================
# influx_backup.ps1
# Sauvegarde InfluxDB depuis le conteneur Docker vers C:\Backups
# ============================================================

param(
    [string]$ContainerName      = "scada-influxdb-1",
    [string]$BackupRootDir      = "C:\Backups",
    [string]$TmpInsideContainer = "/tmp/influx_backup",
    [int]$BankCount             = 2,
    [string]$EveBaseDir         = "C:\Users\BBR\Documents\EVE\HMI data",
    [int]$NumberAutomate        = 1,
    [string]$ModbusLogDir       = "C:\Users\BBR\Documents\modbus_log\txt"
)


# --- Configuration SMTP -------------------------------------

$SmtpServer     = "mail.smtp2go.com"
$SmtpPort       = 2525
$SmtpFrom       = "backup@bbr-energie.fr"
$SmtpTo         = "informatique@bbr-energie.fr"
$SmtpUser       = "backup@bbr-energie.fr"
$SmtpCredTarget = "SMTP_BBR"   # Nom de l'entrée dans Windows Credential Manager
$SiteName       = "4062 - Feurs"


# --- Configuration NAS (SSH/SCP) ----------------------------

$NasHost      = "10.8.0.7"
$NasPort      = 64891
$NasUser      = "ssh.bbr"
$NasBackupDir = "~/Backup"
$NasCredTarget = "NAS_BBR"   # Nom de l'entrée dans Windows Credential Manager
$NasHostKey   = "ssh-ed25519 255 SHA256:FUEtY+2JOx05/zB5ta3ck0Lq6iUZOMOTy0QU3HYMIBI"


# --- Dossier de travail temporaire (hors C:\Backups) --------

$dateSuffix = Get-Date -Format "yyyy_MM_dd-HH-mm-ss"
$dateEve    = Get-Date -Format "yyyy-MM-dd"
$WorkTmpDir = Join-Path $env:TEMP "influx_backup_$dateSuffix"
New-Item -ItemType Directory -Path $WorkTmpDir -Force | Out-Null

# --- Configuration logs (dans le dossier temporaire) --------

$LogDir  = Join-Path $WorkTmpDir "logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "influx_backup_$dateSuffix.log"

# --- Fonctions utilitaires ----------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $script:MailLog += "$line`n"
}

function Send-Mail {
    param(
        [string]$Subject,
        [string]$Body,
        [string]$BodyColor = "black"
    )
    Write-Log "Connexion SMTP : $SmtpServer`:$SmtpPort (SSL) avec l'utilisateur $SmtpUser" "INFO"
    try {
        $htmlBody = @"
<html><body style="font-family:Arial,sans-serif;font-size:13px;">
<h2 style="color:$BodyColor;">$Subject</h2>
<pre style="background:#f4f4f4;padding:12px;border-radius:6px;font-size:12px;">$Body</pre>
<p style="color:#888;font-size:11px;">Serveur : $env:COMPUTERNAME &mdash; $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p style="color:#888;font-size:11px;">Fichier log : $LogFile</p>
</body></html>
"@

        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $smtp.EnableSsl   = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($SmtpUser, $SmtpPassword)

        Write-Log "Objet SMTP créé, envoi en cours..." "INFO"

        $msg                 = New-Object System.Net.Mail.MailMessage
        $msg.From            = $SmtpFrom
        $msg.To.Add($SmtpTo)
        $msg.Subject         = $Subject
        $msg.Body            = $htmlBody
        $msg.IsBodyHtml      = $true
        $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
        $msg.BodyEncoding    = [System.Text.Encoding]::UTF8

        $smtp.Send($msg)
        $msg.Dispose()
        $smtp.Dispose()

        Write-Log "Mail envoyé avec succès à $SmtpTo" "OK"
    } catch {
        $errDetail = $_.Exception.Message
        $errInner  = if ($_.Exception.InnerException) { " | Détail : " + $_.Exception.InnerException.Message } else { "" }
        Write-Log "Échec envoi mail : $errDetail$errInner" "WARN"
        Write-Log "Fichier log complet : $LogFile" "WARN"
        Read-Host "Appuie sur Entrée pour continuer..."
    }
}

function Invoke-DockerCommand {
    param([string]$Description, [string[]]$Arguments)
    Write-Log "Exécution : docker $($Arguments -join ' ')"
    $result = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "$Description a échoué (code $LASTEXITCODE) : $result" "ERROR"
        Send-Mail `
            -Subject   "[$SiteName] Backup InfluxDB ECHOUE - $env:COMPUTERNAME" `
            -Body      $script:MailLog `
            -BodyColor "red"
        exit 1
    }
    return $result
}

# --- Initialisation -----------------------------------------

$script:MailLog = ""
Write-Log "=== Démarrage de la sauvegarde InfluxDB ===" "INFO"
Write-Log "Fichier de log : $LogFile" "INFO"

# --- Vérifications préalables -------------------------------

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker n'est pas installé ou n'est pas dans le PATH." "ERROR"
    Send-Mail -Subject "[$SiteName] Backup InfluxDB ECHOUE - $env:COMPUTERNAME" -Body $script:MailLog -BodyColor "red"
    exit 1
}

$running = docker inspect --format "{{.State.Running}}" $ContainerName 2>&1
if ($LASTEXITCODE -ne 0 -or $running -ne "true") {
    Write-Log "Le conteneur '$ContainerName' n'est pas en cours d'exécution." "ERROR"
    Send-Mail -Subject "[$SiteName] Backup InfluxDB ECHOUE - $env:COMPUTERNAME" -Body $script:MailLog -BodyColor "red"
    exit 1
}

Write-Log "Conteneur '$ContainerName' détecté et actif." "OK"

# --- Lecture des mots de passe depuis Windows Credential Manager ------------

if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
    Write-Log "Module 'CredentialManager' introuvable. Installez-le : Install-Module CredentialManager" "ERROR"
    exit 1
}
Import-Module CredentialManager -ErrorAction Stop

$smtpCred = Get-StoredCredential -Target $SmtpCredTarget
if (-not $smtpCred) {
    Write-Log "Identifiants SMTP introuvables dans le Credential Manager (cible : '$SmtpCredTarget')." "ERROR"
    Write-Log "Exécutez : New-StoredCredential -Target '$SmtpCredTarget' -UserName '$SmtpUser' -Password 'motdepasse' -Type Generic -Persist LocalMachine" "ERROR"
    exit 1
}
$SmtpPassword = $smtpCred.GetNetworkCredential().Password
Write-Log "Identifiants SMTP récupérés depuis le Credential Manager (cible : '$SmtpCredTarget')." "OK"

$nasCred = Get-StoredCredential -Target $NasCredTarget
if (-not $nasCred) {
    Write-Log "Identifiants NAS introuvables dans le Credential Manager (cible : '$NasCredTarget')." "ERROR"
    Write-Log "Exécutez : New-StoredCredential -Target '$NasCredTarget' -UserName '$NasUser' -Password 'motdepasse' -Type Generic -Persist LocalMachine" "ERROR"
    Send-Mail -Subject "[$SiteName] Backup InfluxDB ECHOUE - $env:COMPUTERNAME" -Body $script:MailLog -BodyColor "red"
    exit 1
}
$NasPassword = $nasCred.GetNetworkCredential().Password
Write-Log "Identifiants NAS récupérés depuis le Credential Manager (cible : '$NasCredTarget')." "OK"

# --- Préparation des dossiers -------------------------------

$tempDir = Join-Path $WorkTmpDir "_influx_data"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Log "Dossier de travail temporaire : $tempDir" "OK"

Invoke-DockerCommand "Nettoyage /tmp" @("exec", $ContainerName, "rm", "-rf", $TmpInsideContainer)

# --- Sauvegarde dans le conteneur ---------------------------

Write-Log "Lancement du backup InfluxDB dans le conteneur..."
Invoke-DockerCommand "influxd backup" @(
    "exec", "-i", $ContainerName,
    "influxd", "backup", "-portable", $TmpInsideContainer
)
Write-Log "[$SiteName] Backup InfluxDB terminé dans le conteneur." "OK"

# --- Copie vers Windows (dossier temp) ----------------------

Write-Log "Copie des fichiers vers $tempDir..."
Invoke-DockerCommand "docker cp" @(
    "cp",
    "${ContainerName}:${TmpInsideContainer}/.",
    $tempDir
)
Write-Log "Fichiers copiés avec succès." "OK"

# --- Nettoyage dans le conteneur ----------------------------

Invoke-DockerCommand "Nettoyage post-backup" @("exec", $ContainerName, "rm", "-rf", $TmpInsideContainer)
Write-Log "Nettoyage du dossier temporaire dans le conteneur effectué." "OK"

# --- Collecte des fichiers EVE HMI (AlarmLog + DataLog) ----

Write-Log "Collecte des fichiers EVE HMI (Banks 1 à $BankCount)..."
$eveDataDir = Join-Path $tempDir "eve_data"
New-Item -ItemType Directory -Path $eveDataDir -Force | Out-Null

for ($bank = 1; $bank -le $BankCount; $bank++) {
    $bankName    = "Bank $bank"
    $bankDestDir = Join-Path $eveDataDir $bankName
    New-Item -ItemType Directory -Path $bankDestDir -Force | Out-Null

    # AlarmLog du jour
    $alarmSrc = Join-Path $EveBaseDir "$bankName\AlarmLog\Alarm_$dateEve.csv"
    if (Test-Path $alarmSrc) {
        Copy-Item -Path $alarmSrc -Destination $bankDestDir -Force
        Write-Log "[$bankName] AlarmLog copié : $alarmSrc" "OK"
    } else {
        Write-Log "[$bankName] AlarmLog introuvable : $alarmSrc" "WARN"
    }

    # DataLog du jour (tous les fichiers correspondant au pattern)
    $dataLogDir = Join-Path $EveBaseDir "$bankName\DataLog"
    $dataFiles  = Get-ChildItem -Path $dataLogDir -Filter "$dateEve*.csv.gz" -ErrorAction SilentlyContinue
    if ($dataFiles -and $dataFiles.Count -gt 0) {
        foreach ($f in $dataFiles) {
            Copy-Item -Path $f.FullName -Destination $bankDestDir -Force
        }
        Write-Log "[$bankName] DataLog : $($dataFiles.Count) fichier(s) copié(s)" "OK"
    } else {
        Write-Log "[$bankName] DataLog introuvable : $dataLogDir\$dateEve*.csv.gz" "WARN"
    }
}

Write-Log "Collecte EVE terminée." "OK"

# --- Collecte des logs Modbus (AUT1..AUTn) ------------------

Write-Log "Collecte des logs Modbus (AUT1 à AUT$NumberAutomate)..."
$modbusDataDir = Join-Path $tempDir "modbus_log"
New-Item -ItemType Directory -Path $modbusDataDir -Force | Out-Null

for ($aut = 1; $aut -le $NumberAutomate; $aut++) {
    $autName    = "AUT$aut"
    $autSrc     = Join-Path $ModbusLogDir "$autName\$dateEve.txt"
    $autDestDir = Join-Path $modbusDataDir $autName
    New-Item -ItemType Directory -Path $autDestDir -Force | Out-Null

    if (Test-Path $autSrc) {
        Copy-Item -Path $autSrc -Destination $autDestDir -Force
        Write-Log "[$autName] Log Modbus copié : $autSrc" "OK"
    } else {
        Write-Log "[$autName] Log Modbus introuvable : $autSrc" "WARN"
    }
}

Write-Log "Collecte Modbus terminée." "OK"

# --- Compression en ZIP -------------------------------------

$zipPath = Join-Path $WorkTmpDir "influxdb_backup_$dateSuffix.zip"

Write-Log "Compression des fichiers vers $zipPath..."
Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force
Write-Log "Archive créée : $zipPath" "OK"

Remove-Item -Recurse -Force $tempDir
Write-Log "Dossier temporaire local supprimé." "OK"

# --- Déplacement final vers C:\Backups et C:\Backups-Bess --

$zipName = "influxdb_backup_$dateSuffix.zip"

# Destination principale
New-Item -ItemType Directory -Path $BackupRootDir -Force | Out-Null
$finalZipPath = Join-Path $BackupRootDir $zipName
Copy-Item -Path $zipPath -Destination $finalZipPath -Force
Write-Log "Archive copiée vers : $finalZipPath" "OK"

# Destination secondaire
$BackupBessDir = "C:\Backups-Bess"
New-Item -ItemType Directory -Path $BackupBessDir -Force | Out-Null
$finalZipBessPath = Join-Path $BackupBessDir $zipName
Move-Item -Path $zipPath -Destination $finalZipBessPath -Force
Write-Log "Archive copiée vers : $finalZipBessPath" "OK"

$sizeMo = [math]::Round((Get-Item $finalZipPath).Length / 1MB, 2)
Write-Log "Taille  : $sizeMo Mo" "OK"

# Déplacer le log vers C:\Backups\logs
$finalLogDir  = Join-Path $BackupRootDir "logs"
New-Item -ItemType Directory -Path $finalLogDir -Force | Out-Null
$finalLogPath = Join-Path $finalLogDir (Split-Path $LogFile -Leaf)

Write-Log "=== Sauvegarde terminée avec succès ===" "OK"
Write-Log "Log déplacé vers : $finalLogPath" "OK"

# Mettre à jour $LogFile avant de copier pour que Send-Mail référence le bon chemin
$tmpLogFile = $LogFile
$LogFile    = $finalLogPath
Copy-Item -Path $tmpLogFile -Destination $finalLogPath -Force

# Nettoyer le dossier de travail temporaire
Remove-Item -Recurse -Force $WorkTmpDir -ErrorAction SilentlyContinue

# --- Envoi vers le NAS (SSH/SCP) ----------------------------

Write-Log "Envoi du ZIP vers le NAS ($NasUser@${NasHost}:$NasPort)..."
try {
    $nasRemoteDir  = "$NasBackupDir/$SiteName"
    $nasRemotePath = "$nasRemoteDir/$zipName"

    $hasPlink = [bool](Get-Command plink -ErrorAction SilentlyContinue)
    $hasPscp  = [bool](Get-Command pscp  -ErrorAction SilentlyContinue)

    if ($hasPlink -and $hasPscp) {
        # --- Authentification par mot de passe via PuTTY (plink/pscp) -------
        # -batch : désactive les prompts interactifs (host-key, etc.)
        # -pw    : mot de passe SSH en clair (stockez-le dans un secret vault en prod)

        $mkdirOutput = plink -P $NasPort -pw $NasPassword -batch -hostkey $NasHostKey "${NasUser}@${NasHost}" "mkdir -p `"$nasRemoteDir`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Impossible de créer le dossier NAS '$nasRemoteDir' : $mkdirOutput" "WARN"
        } else {
            $nasRemotePathEscaped = $nasRemotePath -replace ' ', '\ '
            $scpOutput = pscp -P $NasPort -pw $NasPassword -batch -hostkey $NasHostKey "$finalZipPath" "${NasUser}@${NasHost}:$nasRemotePathEscaped" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "ZIP envoyé vers le NAS : $nasRemotePath" "OK"
            } else {
                Write-Log "Échec envoi NAS (code $LASTEXITCODE) : $scpOutput" "WARN"
            }
        }
    } else {
        # --- Fallback : authentification par clé SSH (ssh/scp natif) ---------
        Write-Log "plink/pscp introuvables — utilisation de ssh/scp (clé SSH requise). Installez PuTTY pour gérer le mot de passe." "WARN"

        $mkdirOutput = ssh -p $NasPort "${NasUser}@${NasHost}" "mkdir -p `"$nasRemoteDir`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Impossible de créer le dossier NAS '$nasRemoteDir' : $mkdirOutput" "WARN"
        } else {
            $scpOutput = scp -P $NasPort "$finalZipPath" "${NasUser}@${NasHost}:`"$nasRemotePath`"" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "ZIP envoyé vers le NAS : $nasRemotePath" "OK"
            } else {
                Write-Log "Échec envoi NAS (code $LASTEXITCODE) : $scpOutput" "WARN"
            }
        }
    }
} catch {
    Write-Log "Erreur lors de l'envoi vers le NAS : $($_.Exception.Message)" "WARN"
}

# --- Résumé + Mail succès -----------------------------------

Send-Mail `
    -Subject   "[$SiteName] Backup InfluxDB reussi - $env:COMPUTERNAME" `
    -Body      $script:MailLog `
    -BodyColor "green"