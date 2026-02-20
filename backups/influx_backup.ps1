# ============================================================
# influx_backup.ps1
# Sauvegarde InfluxDB depuis le conteneur Docker vers C:\Backups
# ============================================================

param(
    [string]$ContainerName  = "scada-influxdb-1",
    [string]$BackupRootDir  = "C:\Backups",
    [string]$TmpInsideContainer = "/tmp/influx_backup"
)


# --- Configuration SMTP -------------------------------------

$SmtpServer   = "mail.smtp2go.com"
$SmtpPort     = 2525
$SmtpFrom     = "backup@bbr-energie.fr"
$SmtpTo       = "informatique@bbr-energie.fr"
$SmtpUser     = "backup@bbr-energie.fr"
$SmtpPassword = "changeme"


# --- Configuration logs -------------------------------------

$LogDir  = Join-Path $BackupRootDir "logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("influx_backup_" + (Get-Date -Format "yyyy_MM_dd-HH-mm-ss") + ".log")

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
            -Subject   "Backup InfluxDB ECHOUE - $env:COMPUTERNAME" `
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
    Send-Mail -Subject "Backup InfluxDB ECHOUE - $env:COMPUTERNAME" -Body $script:MailLog -BodyColor "red"
    exit 1
}

$running = docker inspect --format "{{.State.Running}}" $ContainerName 2>&1
if ($LASTEXITCODE -ne 0 -or $running -ne "true") {
    Write-Log "Le conteneur '$ContainerName' n'est pas en cours d'exécution." "ERROR"
    Send-Mail -Subject "Backup InfluxDB ECHOUE - $env:COMPUTERNAME" -Body $script:MailLog -BodyColor "red"
    exit 1
}

Write-Log "Conteneur '$ContainerName' détecté et actif." "OK"

# --- Préparation des dossiers -------------------------------

$tempDir = Join-Path $BackupRootDir "_tmp_influx"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Log "Dossier temporaire local : $tempDir" "OK"

Invoke-DockerCommand "Nettoyage /tmp" @("exec", $ContainerName, "rm", "-rf", $TmpInsideContainer)

# --- Sauvegarde dans le conteneur ---------------------------

Write-Log "Lancement du backup InfluxDB dans le conteneur..."
Invoke-DockerCommand "influxd backup" @(
    "exec", "-i", $ContainerName,
    "influxd", "backup", "-portable", $TmpInsideContainer
)
Write-Log "Backup InfluxDB terminé dans le conteneur." "OK"

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

# --- Compression en ZIP -------------------------------------

$dateSuffix = Get-Date -Format "yyyy_MM_dd-HH-mm-ss"
$zipPath    = Join-Path $BackupRootDir "influxdb_backup_$dateSuffix.zip"

Write-Log "Compression des fichiers vers $zipPath..."
Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force
Write-Log "Archive créée : $zipPath" "OK"

Remove-Item -Recurse -Force $tempDir
Write-Log "Dossier temporaire local supprimé." "OK"

# --- Résumé + Mail succès -----------------------------------

$sizeMo = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Log "=== Sauvegarde terminée avec succès ===" "OK"
Write-Log "Archive : $zipPath" "OK"
Write-Log "Taille  : $sizeMo Mo" "OK"
Write-Log "Log     : $LogFile" "OK"

Send-Mail `
    -Subject   "Backup InfluxDB reussi - $env:COMPUTERNAME" `
    -Body      $script:MailLog `
    -BodyColor "green"