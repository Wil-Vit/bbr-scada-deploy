# ============================================================
# cleanup_old_backups.ps1
# Supprime les fichiers de sauvegarde locaux de plus d'un mois
# dans C:\Backups et C:\Backups-Bess
# ============================================================

param(
    [string[]]$BackupDirs    = @("C:\Backups", "C:\Backups-Bess"),
    [int]$RetentionDays      = 30
)


# --- Fonctions utilitaires ----------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}


# --- Configuration logs -------------------------------------

$dateSuffix = Get-Date -Format "yyyy_MM_dd-HH-mm-ss"
$LogDir     = "C:\Logs\cleanup_backups"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile    = Join-Path $LogDir "cleanup_$dateSuffix.log"


# --- Main ---------------------------------------------------

Write-Log "Debut du nettoyage (retention : $RetentionDays jours)"
Write-Log "Dossiers cibles : $($BackupDirs -join ', ')"

$cutoffDate   = (Get-Date).AddDays(-$RetentionDays)
$totalDeleted = 0
$totalErrors  = 0

foreach ($dir in $BackupDirs) {

    if (-not (Test-Path $dir)) {
        Write-Log "Dossier introuvable, ignore : $dir" "WARN"
        continue
    }

    Write-Log "Traitement du dossier : $dir"

    $oldFiles = Get-ChildItem -Path $dir -Recurse -File |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }

    if ($oldFiles.Count -eq 0) {
        Write-Log "Aucun fichier a supprimer dans $dir"
        continue
    }

    foreach ($file in $oldFiles) {
        try {
            Remove-Item -Path $file.FullName -Force
            Write-Log "Supprime : $($file.FullName)"
            $totalDeleted++
        } catch {
            Write-Log "Erreur lors de la suppression de $($file.FullName) : $_" "ERROR"
            $totalErrors++
        }
    }

    # Supprime les sous-dossiers vides apres nettoyage
    Get-ChildItem -Path $dir -Recurse -Directory |
        Sort-Object FullName -Descending |
        Where-Object { (Get-ChildItem $_.FullName -Force).Count -eq 0 } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Force
                Write-Log "Dossier vide supprime : $($_.FullName)"
            } catch {
                Write-Log "Erreur suppression dossier vide $($_.FullName) : $_" "WARN"
            }
        }
}

Write-Log "Nettoyage termine. Fichiers supprimes : $totalDeleted | Erreurs : $totalErrors"

if ($totalErrors -gt 0) {
    exit 1
}
