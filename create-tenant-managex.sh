#!/bin/bash

# Prerequisites:
# 1.  Change variables in this file
# 2.  Run this script sh ./create-tenant-managex.sh

# VARIABLES YOU CAN CHANGE
ENV=prod
COMPANY=
HOST_NAME=
PRIVATE_DNS_ZONE=
# Pick IP from 10.224.0.0/16 range
LOAD_BALANCER_IP=

NODE_POOL=mainpool
LOCATION=polandcentral
APP_VERSION=2.4.16-acr

MAIL_HOST=
MAIL_PORT=
MAIL_USERNAME=
MAIL_PASSWORD=

# DO NOT CHANGE ANYTHING BELOW
APP_NAME=managex-$ENV
TENANT=tenant-$COMPANY
APP_NAME=$TENANT-$APP_NAME
SUBSCRIPTION=codegarten-subscription
KEY_VAULT=$TENANT-kv
RESOURCE_GROUP=$TENANT-resource-group
TAGS=tenant=$COMPANY

MANAGED_IDENTITY_ID=c9704c86-3cc5-4442-bcc7-eb2aeaf8aae5
MANAGED_IDENTITY=azurekeyvaultsecretsprovider-codegarten-prod-poland
PRIVATE_DNS_ZONE_RESOURCE_GROUP=MC_CodeGarten_codegarten-prod-poland_polandcentral
PRIVATE_DNS_ZONE_LINK_TO_VNET_NAME=aks-vnet-38780670

PG_HOST=codegarten-postgres-server.postgres.database.azure.com
PG_USER=codegarten
PG_PORT=5432
PG_DATABASE=postgres
PG_PASSWORD="$(az keyvault secret show --vault-name codegarten-key-vault --name codegarten-postgres-admin --query value -o tsv)"

PG_NEW_DB_NAME=$TENANT-managex-$ENV
PG_NEW_DB_USER_NAME=$TENANT-managex-$ENV
PG_NEW_DB_USER_PASSWORD=$(openssl rand -hex 6)

ORIGINAL_SUBSCRIPTION=$(az account show --query id -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
MY_TENANT_ID=a6d7dd13-7033-47e2-b1af-7ebfd6f69e1a

export PGPASSWORD="$PG_PASSWORD"

set -e  # Exit immediately if a command exits with a non-zero status

# Function to reset subscription context
reset_subscription() {
  echo "Resetting Azure subscription context to original subscription..."
  az account set --subscription "$ORIGINAL_SUBSCRIPTION"
  echo "Subscription context reset."
}

# Trap EXIT (script end, error or not) to always reset subscription
trap reset_subscription EXIT

if [[ ${#KEY_VAULT} -gt 24 ]]; then
  echo "Error: Key Vault name '$KEY_VAULT' is longer than 24 characters."
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is not installed" >&2
    exit 1
fi

if ! command -v bcrypt-cli >/dev/null 2>&1; then
    echo "Error: bcrypt-cli is not installed" >&2
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm is not installed" >&2
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is not installed" >&2
    exit 1
fi

echo "Rollout ManageX for $COMPANY."

echo "Setting Azure subscription context..."
az account set --subscription "$SUBSCRIPTION"
echo "Subscription context set."

echo "1/14 - Creating Resource Group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --tags $TAGS \
  > /dev/null

echo "2/14 - Creating Private DNS Zone..."
az network private-dns zone create \
  --resource-group $PRIVATE_DNS_ZONE_RESOURCE_GROUP \
  --name $PRIVATE_DNS_ZONE \
  --tags $TAGS \
  > /dev/null
az network private-dns link vnet create \
  --name codegarten-aks-vnet-link \
  --virtual-network $PRIVATE_DNS_ZONE_LINK_TO_VNET_NAME \
  --resource-group  $PRIVATE_DNS_ZONE_RESOURCE_GROUP \
  --zone-name $PRIVATE_DNS_ZONE \
  --registration-enabled true \
  --tags $TAGS \
  > /dev/null

echo "3/14 - Creating Key Vault..."
az provider register --namespace Microsoft.KeyVault --only-show-errors
az keyvault create \
  --name $KEY_VAULT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --tags $TAGS \
  > /dev/null

echo "4/14 - Assigning Key Vault Secrets User role to Managed Identity..."
KEY_VAULT_ID=$(az keyvault show \
  --name $KEY_VAULT \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)
az role assignment create \
  --assignee-object-id $MY_OBJECT_ID \
  --role "Key Vault Administrator" \
  --scope $KEY_VAULT_ID \
  > /dev/null
az role assignment create \
  --assignee $MANAGED_IDENTITY_ID \
  --role "Key Vault Secrets User" \
  --scope $KEY_VAULT_ID \
  > /dev/null

echo "5/14 - Creating database..."
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DATABASE user=$PG_USER sslmode=require" \
  -c "CREATE DATABASE \"$PG_NEW_DB_NAME\";" > /dev/null

echo "6/14 - Copying tables from managex-init to the database..."
pg_dump --no-owner "host=$PG_HOST port=$PG_PORT user=$PG_USER dbname=managex-init sslmode=require" | \
psql "host=$PG_HOST port=$PG_PORT user=$PG_USER dbname=$PG_NEW_DB_NAME sslmode=require" > /dev/null

echo "7/14 - Creating new database user..."
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DATABASE user=$PG_USER sslmode=require" \
  -c "CREATE USER \"$PG_NEW_DB_USER_NAME\" WITH PASSWORD '$PG_NEW_DB_USER_PASSWORD'" \
  > /dev/null

echo "8/14 - Giving db permissions to the user..."
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "CREATE EXTENSION IF NOT EXISTS unaccent;" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "GRANT CREATE ON DATABASE \"$PG_NEW_DB_NAME\" TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "GRANT CONNECT ON DATABASE \"$PG_NEW_DB_NAME\" TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "GRANT ALL ON SCHEMA public TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$PG_NEW_DB_USER_NAME\";" \
  > /dev/null

echo "9/14 - Saving user's password in the key vault..."
for i in {1..30}; do
  if az keyvault secret set \
    --vault-name $KEY_VAULT \
    --content-type "password" \
    --value $PG_NEW_DB_USER_PASSWORD \
    --name "$APP_NAME-strapi-database-password" \
    --tags $TAGS \
    > /dev/null 2>&1; then
    break # Secret set successfully!
  else
    sleep 1 # Failed, waiting 1 seconds...
  fi
  if [ $i -eq 30 ]; then
    echo "Failed to set secret after 30 attempts"
    exit 1
  fi
done

echo "10/14 - Generating new super admin password..."
STRAPI_SUPER_ADMIN_PASSWORD=$(openssl rand -hex 6)
STRAPI_SUPER_ADMIN_PASSWORD_HASH=$(bcrypt-cli $STRAPI_SUPER_ADMIN_PASSWORD 10)
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "UPDATE admin_users SET password = '$STRAPI_SUPER_ADMIN_PASSWORD_HASH' WHERE id = 1;" \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "password" \
  --value $STRAPI_SUPER_ADMIN_PASSWORD \
  --name "$APP_NAME-strapi-super-admin-password" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "password" \
  --value support@codegarten.com \
  --name "$APP_NAME-strapi-super-admin-email" \
  --tags $TAGS \
  > /dev/null

echo "11/14 - Generating secrets to key vault..."
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $(openssl rand -base64 16) \
  --name "$APP_NAME-next-auth-secret" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $(openssl rand -base64 16) \
  --name "$APP_NAME-strapi-admin-jwt-secret" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value "$(openssl rand -base64 16),$(openssl rand -base64 16),$(openssl rand -base64 16)" \
  --name "$APP_NAME-strapi-app-keys" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $(openssl rand -base64 16) \
  --name "$APP_NAME-strapi-jwt-secret" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $(openssl rand -base64 16) \
  --name "$APP_NAME-strapi-refresh-token-secret" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $(openssl rand -base64 16) \
  --name "$APP_NAME-strapi-transfer-token-salt" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "password" \
  --value ${MAIL_PASSWORD:-not-defined} \
  --name "$APP_NAME-strapi-mail-password" \
  --tags $TAGS \
  > /dev/null

echo "12/14 - Generating full access token..."
ACCESS_TOKEN=$(openssl rand -hex 128)
API_TOKEN_SALT=$(openssl rand -base64 16)
ACCESS_KEY=$(echo -n "$ACCESS_TOKEN" | openssl dgst -sha512 -hmac "$API_TOKEN_SALT" | awk '{print $2}')
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "secret" \
  --value $API_TOKEN_SALT \
  --name "$APP_NAME-strapi-api-token-salt" \
  --tags $TAGS \
  > /dev/null
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --content-type "token" \
  --value $ACCESS_TOKEN \
  --name "$APP_NAME-next-strapi-full-access-token" \
  --tags $TAGS \
  > /dev/null
# Delete all existing API TOKENS
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "DELETE FROM strapi_api_tokens;" \
  > /dev/null
# Insert new API TOKEN
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_NEW_DB_NAME user=$PG_USER sslmode=require" \
  -c "INSERT INTO strapi_api_tokens (document_id, name, description, type, access_key, created_at, updated_at, published_at)
      VALUES ('b3ziqnfbey83gl8qogxms8jg', 'NEXT_STRAPI_FULL_ACCESS_TOKEN', 'PLEASE DO NOT DELETE OR CHANGE IT', 'full-access', '$ACCESS_KEY', NOW(), NOW(), NOW());" \
  > /dev/null

echo "13/14 - Creating helm chart..."
mkdir "$TENANT"
cd "./$TENANT"
helm create "$APP_NAME"
rm -rf ./$APP_NAME/charts
rm -rf ./$APP_NAME/.helmignore
rm -rf ./$APP_NAME/templates/*
sed -i "" "s/^appVersion: .*/appVersion: \"$APP_VERSION\"/" ./$APP_NAME/Chart.yaml
cat > "./$APP_NAME/values.yaml" <<EOL
# General application settings
namespace: $TENANT
appName: $APP_NAME
hostName: $HOST_NAME
replicas: 1
storage: 1Gi
nodePool: $NODE_POOL
loadBalancerIP: $LOAD_BALANCER_IP

# Identity and security
keyVault: $KEY_VAULT
tenantId: $MY_TENANT_ID
managedIdentityId: $MANAGED_IDENTITY_ID

# Database configuration
databaseHost: $PG_HOST
databasePort: $PG_PORT
databaseName: $PG_NEW_DB_NAME
databaseUsername: $PG_NEW_DB_USER_NAME

# Mail server configuration
mailHost: $MAIL_HOST
mailPort: $MAIL_PORT
mailUsername: $MAIL_USERNAME
EOL
cp "../deployment-template-managex-vpn.yaml" "./$APP_NAME/templates/deployment.yaml"

echo "14/14 - Installing ManageX..."
kubectl create namespace "$TENANT"
helm install "$APP_NAME" "./$APP_NAME" --namespace "$TENANT"

echo "All steps completed successfully!"

echo "Visit https://$HOST_NAME. Sometimes it can take few minutes to get ready."
