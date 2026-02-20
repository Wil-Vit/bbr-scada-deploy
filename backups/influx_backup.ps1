# ============================================================
# influx_backup.ps1
# Sauvegarde InfluxDB depuis le conteneur Docker vers C:\Backups
# ============================================================

param(
    [string]$ContainerName  = "scada-influxdb-1",
    [string]$BackupRootDir  = "C:\Backups",
    [string]$TmpInsideContainer = "/tmp/influx_backup"
)

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
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Invoke-DockerCommand {
    param([string]$Description, [string[]]$Arguments)
    Write-Log "Exécution : docker $($Arguments -join ' ')"
    $result = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "$Description a échoué (code $LASTEXITCODE) : $result" "ERROR"
        exit 1
    }
    return $result
}

# --- Vérifications préalables -------------------------------

Write-Log "=== Démarrage de la sauvegarde InfluxDB ===" "INFO"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker n'est pas installé ou n'est pas dans le PATH." "ERROR"
    exit 1
}

$running = docker inspect --format "{{.State.Running}}" $ContainerName 2>&1
if ($LASTEXITCODE -ne 0 -or $running -ne "true") {
    Write-Log "Le conteneur '$ContainerName' n'est pas en cours d'exécution." "ERROR"
    exit 1
}

Write-Log "Conteneur '$ContainerName' détecté et actif." "OK"

# --- Préparation des dossiers -------------------------------

# Dossier temporaire local pour recevoir les fichiers du docker cp
$tempDir = Join-Path $BackupRootDir "_tmp_influx"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-Log "Dossier temporaire local : $tempDir" "OK"

# Nettoyer le dossier temporaire dans le conteneur s'il existe déjà
Invoke-DockerCommand "Nettoyage /tmp" @("exec", $ContainerName, "rm", "-rf", $TmpInsideContainer)

# --- Sauvegarde dans le conteneur ---------------------------

Write-Log "Lancement du backup InfluxDB dans le conteneur..."
Invoke-DockerCommand "influxd backup" @(
    "exec", $ContainerName,
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

# Supprimer uniquement le dossier temporaire local
Remove-Item -Recurse -Force $tempDir
Write-Log "Dossier temporaire local supprimé." "OK"

# --- Résumé -------------------------------------------------

$sizeMo = (Get-Item $zipPath).Length / 1MB
Write-Log "=== Sauvegarde terminée ===" "OK"
Write-Log "Archive     : $zipPath" "OK"
Write-Log "Taille      : $([math]::Round($sizeMo, 2)) Mo" "OK"