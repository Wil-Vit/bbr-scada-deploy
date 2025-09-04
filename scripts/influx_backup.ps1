#!/snap/bin/pwsh
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
