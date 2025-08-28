param(
  [Parameter(Mandatory=$false)]
  [string]$PostgreSQLServer = "codegarten-postgres-server.postgres.database.azure.com",
  [Parameter(Mandatory=$false)]
  [string]$AdminUser = "codegarten",
  [Parameter(Mandatory=$false)]
  [string[]]$DatabaseList = @("managex-dev", "managex-init", "tenant-omegadent-managex-prod"),

  [Parameter(Mandatory=$false)]
  [string]$StorageAccountName = "fb2952cd6f8bb46ddb79a7a",
  [Parameter(Mandatory=$false)]
  [string]$StorageResourceGroup = "MC_CodeGarten_codegarten-prod-poland_polandcentral",
  [Parameter(Mandatory=$false)]
  [string]$StorageContainerName = "pg-backup-days",

  [Parameter(Mandatory = $false)]
  [string]$KeyVaultName = "codegarten-key-vault",
  [Parameter(Mandatory = $false)]
  [string]$KeyVaultPgSecretName = "codegarten-postgres-admin",

  [Parameter(Mandatory=$false)]
  [int]$RetentionDays = 7
)

# Connect using Managed Identity
Connect-AzAccount
# Connect-AzAccount -Identity

# Get PostgreSQL admin password from Key Vault (recommended)
$Password = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultPgSecretName -AsPlainText)

$Date = Get-Date -Format "MM-dd-yyyy HH:mm:ss"
# $TempPath = $env:TEMP
$TempPath = './'

Write-Output "Starting PostgreSQL backup for server: $PostgreSQLServer"
Write-Output "Databases to backup: $($DatabaseList -join ', ')"

foreach ($Database in $DatabaseList) {
  try {
    $BackupFileName = "${Database} ${Date}.dump"
    $LocalFilePath = Join-Path $TempPath $BackupFileName

    Write-Output "Backing up database: $Database"

    # Set environment variable for password
    $env:PGPASSWORD = $Password

    # Run pg_dump
    $pgDumpArgs = @(
      "-h", $PostgreSQLServer
      "-U", $AdminUser
      "-d", $Database
      "-F", "c"
      "-f", $LocalFilePath
    )
    & pg_dump @pgDumpArgs

    if ($LASTEXITCODE -eq 0) {
      Write-Output "Successfully created backup file: $BackupFileName"

      # Upload to Azure Blob Storage
      $StorageContext = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -Name $StorageAccountName).Context

      Set-AzStorageBlobContent -File $LocalFilePath `
        -Container $StorageContainerName `
        -Context $StorageContext `
        -Blob $BackupFileName `
        -Force

      Write-Output "Successfully uploaded $BackupFileName to storage"

      # Clean up local file
      Remove-Item $LocalFilePath -Force
    } else {
      Write-Error "pg_dump failed for database: $Database"
    }
  } catch {
    Write-Error "Error backing up database ${Database}: $($_.Exception.Message)"
  }
}

# Cleanup old backups
Write-Output "Cleaning up backups older than $RetentionDays days"
try {
  $StorageContext = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -Name $StorageAccountName).Context
  $CutoffDate = (Get-Date).AddDays(-$RetentionDays)

  $OldBlobs = Get-AzStorageBlob -Container $StorageContainerName -Context $StorageContext |
              Where-Object { $_.LastModified -lt $CutoffDate -and $_.Name -like "*.dump" }

  foreach ($Blob in $OldBlobs) {
    Remove-AzStorageBlob -Blob $Blob.Name -Container $StorageContainerName -Context $StorageContext -Force
    Write-Output "Deleted old backup: $($Blob.Name)"
  }
} catch {
  Write-Error "Error during cleanup: $($_.Exception.Message)"
}

Write-Output "Backup process completed"
