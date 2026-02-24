# Installer le module si pas encore fait
Install-Module CredentialManager -Scope CurrentUser -Force

# Stocker le mot de passe NAS
New-StoredCredential -Target "NAS_BBR" `
    -UserName "ssh.bbr" `
    -Password "ton_mot_de_passe_nas" `
    -Type Generic `
    -Persist LocalMachine

# Stocker le mot de passe SMTP
New-StoredCredential -Target "SMTP_BBR" `
    -UserName "backup@bbr-energie.fr" `
    -Password "ton_mot_de_passe_smtp" `
    -Type Generic `
    -Persist LocalMachine
