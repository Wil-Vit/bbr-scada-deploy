#!/snap/bin/pwsh
$backupDate = "2025-07-18_15-56-54"
$containerId = docker ps | Select-String -Pattern "influxdb" | ForEach-Object { $_.ToString().Substring(0,12) }

# Copy backup from host to container
$backupHostPath = "../backup"
New-Item -ItemType Directory -Path $backupHostPath -Force | Out-Null
docker cp "${backupHostPath}/${backupDate}" "${containerId}:/tmp/backup/${backupDate}" 

docker exec "$containerId" influxd restore -portable /tmp/backup/$backupDate/