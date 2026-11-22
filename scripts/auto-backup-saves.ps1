$Source = "$env:LOCALAPPDATA\RSDragonwilds\Saved"
$BackupDir = "$env:USERPROFILE\Desktop\Dragonwilds_Backups"
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ZipPath = "$BackupDir\Dragonwilds_Backup_$Timestamp.zip"

# Create the backup folder if it doesn't exist
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# Compress both SaveGames and SaveCharacters into one ZIP
Compress-Archive -Path "$Source\SaveGames", "$Source\SaveCharacters" -DestinationPath $ZipPath -Force

Write-Host "Backup saved to: $ZipPath" -ForegroundColor Green
