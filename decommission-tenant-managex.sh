#!/bin/bash

# Prerequisites:
# 1.  Terminate All Connections to the Database
# 2.  Change variables in this file
# 3.  Run this script sh ./decommission-tenant-managex.sh

# VARIABLES YOU CAN CHANGE
COMPANY=

# DO NOT CHANGE ANYTHING BELOW
HELM_APP=prod-$COMPANY
TENANT=tenant-$COMPANY
SUBSCRIPTION=codegarten-subscription
RESOURCE_GROUP=$TENANT-resource-group
ORIGINAL_SUBSCRIPTION=$(az account show --query id -o tsv)

PG_HOST=codegarten-postgres-server.postgres.database.azure.com
PG_USER=codegarten
PG_PORT=5432
PG_DATABASE=postgres
PG_PASSWORD="$(az keyvault secret show --vault-name codegarten-key-vault --name codegarten-postgres-admin --query value -o tsv)"

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

if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm is not installed" >&2
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is not installed" >&2
    exit 1
fi

echo "Setting Azure subscription context..."
az account set --subscription "$SUBSCRIPTION"
echo "Subscription context set."

echo "1/5 - Deleting resources..."
az resource list --resource-group $RESOURCE_GROUP --output table
az group delete --name $RESOURCE_GROUP

echo "2/5 - Deleting Private DNS Zones..."
az resource list --tag tenant=$COMPANY --query "[?type=='Microsoft.Network/privateDnsZones'].{name:name, rg:resourceGroup}" -o tsv | while read name rg; do
  # Remove all vNet links for this zone
  for link in $(az network private-dns link vnet list --resource-group "$rg" --zone-name "$name" --query "[].name" -o tsv); do
    az network private-dns link vnet delete --resource-group "$rg" --zone-name "$name" --name "$link" --yes
  done
  # Delete the zone
  az network private-dns zone delete --name "$name" --resource-group "$rg" --yes
done

echo "3/5 - Uninstall managex..."
if helm status "$HELM_APP" > /dev/null 2>&1; then
  helm uninstall "$HELM_APP"
fi
kubectl delete namespace "$HELM_APP"

echo "4/5 - Deleting database and its user..."
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DATABASE user=$PG_USER sslmode=require" \
  -c "DROP DATABASE \"$TENANT-managex-prod\";" \
  > /dev/null
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DATABASE user=$PG_USER sslmode=require" \
  -c "DROP USER \"$TENANT-managex-prod\";" \
  > /dev/null

echo "5/5 - Deleting helm chart..."
rm -rf ./$HELM_APP

echo "All steps completed successfully!"

# Next steps?
# Remove database from pwsh pg-backup script?
