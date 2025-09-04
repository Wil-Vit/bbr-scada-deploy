#!/snap/bin/pwsh
cat github-pat | docker login ghcr.io -u wil-vit --password-stdin
docker compose up