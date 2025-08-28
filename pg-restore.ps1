param(
  [Parameter(Mandatory = $true)]
  [string]$BlobName,
  [Parameter(Mandatory = $true)]
  [string]$TargetDatabase,
  [Parameter(Mandatory = $false)]
  [string]$PostgreSQLServer = "codegarten-postgres-server.postgres.database.azure.com",
  [Parameter(Mandatory = $false)]
  [string]$AdminUser = "codegarten",

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

  [Parameter(Mandatory = $false)]
  [string]$TempFolder = "./"
)

# Connect using Managed Identity
Connect-AzAccount
# Connect-AzAccount -Identity

# Get PostgreSQL admin password from Key Vault (recommended)
$Password = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultPgSecretName -AsPlainText)

# Set env var for pg_restore
$env:PGPASSWORD = $Password

# Prepare local path
$LocalDumpPath = Join-Path $TempFolder $BlobName

Write-Output "Downloading dump blob '$BlobName'..."

# Get Storage context and download the blob
$StorageContext = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroup -Name $StorageAccountName).Context
Get-AzStorageBlobContent `
  -Container $StorageContainerName `
  -Blob $BlobName `
  -Destination $LocalDumpPath `
  -Context $StorageContext `
  -Force

if (!(Test-Path $LocalDumpPath)) {
  throw "Failed to download blob $BlobName to $LocalDumpPath"
}

Write-Output "Downloaded to: $LocalDumpPath"
Write-Output "Starting restore into database: $TargetDatabase on $PostgreSQLServer"

# Build pg_restore args
$pgRestoreArgs = @(
  "-h", $PostgreSQLServer
  "-U", $AdminUser
  "-d", $TargetDatabase
  "--clean"                 # drops objects before recreating; remove if not desired
  "--if-exists"             # ignore drop errors if object is missing
  # "--no-owner"            # avoids setting object owners (typical for Azure)
  # "--no-privileges"       # skip GRANT/REVOKE from dump (optional)
  "--format=custom"         # input is a custom format dump
  "--verbose"
  "--jobs=1"
  $LocalDumpPath
)
& pg_restore @pgRestoreArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "pg_restore failed with exit code $LASTEXITCODE"
  exit 1
}

Write-Output "Restore completed successfully."

# 6) Cleanup local dump
try {
  Remove-Item $LocalDumpPath -Force
  Write-Output "Cleaned up: $LocalDumpPath"
} catch {
  Write-Warning "Could not delete local dump file: $LocalDumpPath"
}
