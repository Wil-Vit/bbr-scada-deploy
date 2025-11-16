#!/snap/bin/pwsh
# Script to backup InfluxDB data from Docker container and upload to SharePoint

$now = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$containerId = docker ps | Select-String -Pattern "influxdb" | ForEach-Object { $_.ToString().Substring(0,12) }

docker exec "$containerId" influxd backup -portable /tmp/backup/$now/

# Copy backup from container to host
$backupHostPath = "../backup"
New-Item -ItemType Directory -Path $backupHostPath -Force | Out-Null
docker cp "${containerId}:/tmp/backup/${now}" $backupHostPath

# Zip files
Compress-Archive -Path "$backupHostPath/$now/*" -DestinationPath "$backupHostPath/influxdb_backup_$now.zip"

# Delete files
Remove-Item -Path "$backupHostPath/$now" -Recurse

python ./upload_file_to_sharepoint.py --file "${backupHostPath}/influxdb_backup_$now.zip" --folder "/2025/IDEX/4062 Stockage FEURS/Backups base de données"