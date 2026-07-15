# Deploying to Azure App Service (Linux, Node 20)

One small always-on instance is all this backend needs. Commands below use
`az` CLI; adjust names/regions to taste.

## 1. One-time resource setup

```bash
LOCATION=westus2
RG=contactssync-rg
PLAN=contactssync-plan
APP=contactssync-backend          # must be globally unique (*.azurewebsites.net)
STORAGE=contactssyncstore         # 3-24 lowercase alphanumeric, globally unique

az group create --name "$RG" --location "$LOCATION"

# B1 is the cheapest tier that supports Always On (required for the dispatcher).
az appservice plan create --resource-group "$RG" --name "$PLAN" \
  --is-linux --sku B1

az webapp create --resource-group "$RG" --plan "$PLAN" --name "$APP" \
  --runtime "NODE:20-lts"

az webapp config set --resource-group "$RG" --name "$APP" \
  --always-on true --startup-file "npm start"

# Storage account + table for device tokens
az storage account create --resource-group "$RG" --name "$STORAGE" \
  --location "$LOCATION" --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2

STORAGE_KEY=$(az storage account keys list --resource-group "$RG" \
  --account-name "$STORAGE" --query '[0].value' -o tsv)

# Optional: the app creates the table on first use, but you can pre-create it:
az storage table create --name devices \
  --account-name "$STORAGE" --account-key "$STORAGE_KEY"
```

## 2. App settings

```bash
# Escape the .p8 newlines so the key survives as a single-line app setting;
# the server converts "\n" back to real newlines.
APNS_KEY_P8=$(awk 'NR>1{printf "\\n"} {printf "%s", $0}' AuthKey_XXXXXXXXXX.p8)

az webapp config appsettings set --resource-group "$RG" --name "$APP" --settings \
  STORE=azure \
  AZURE_TABLES_ACCOUNT="$STORAGE" \
  AZURE_TABLES_KEY="$STORAGE_KEY" \
  AZURE_TABLES_TABLE=devices \
  APNS_KEY_P8="$APNS_KEY_P8" \
  APNS_KEY_ID=XXXXXXXXXX \
  APNS_TEAM_ID=<your-team-id> \
  APNS_TOPIC=com.openappsstudio.contactssync \
  APNS_ENV=production \
  PUSH_INTERVAL_MIN=20 \
  SCM_DO_BUILD_DURING_DEPLOYMENT=true
```

Notes:
- `PORT` is injected by App Service — do not set it.
- Prefer Key Vault references for `APNS_KEY_P8` and `AZURE_TABLES_KEY` if you
  have a vault: `@Microsoft.KeyVault(SecretUri=...)`.
- For a quick test against the APNs sandbox set `APNS_ENV=sandbox`.
- If you skip Azure Tables at first, use
  `STORE=memory MEMORY_STORE_FILE=/home/data/devices.json` (`/home` persists
  across restarts on App Service).

## 3. Deploy the code

From the repo root (deploys only the `backend/` folder as a zip):

```bash
cd backend
zip -r ../backend.zip . -x 'node_modules/*' -x '*.p8' -x '.env*'
az webapp deploy --resource-group "$RG" --name "$APP" \
  --src-path ../backend.zip --type zip
```

`SCM_DO_BUILD_DURING_DEPLOYMENT=true` makes Oryx run `npm install --production`
on the server, so `node_modules` is not needed in the zip.

## 4. Verify

```bash
az webapp log tail --resource-group "$RG" --name "$APP"     # watch startup logs
curl https://$APP.azurewebsites.net/healthz
```

You should see `{"ok":true,"devices":0,"lastDispatchAt":null}` and, once a
device registers, dispatcher cycle logs every `PUSH_INTERVAL_MIN` minutes.

## GitHub Actions (optional)

Copy `deploy-workflow.yml.sample` to `.github/workflows/deploy-backend.yml` at
the repo root, then create the publish-profile secret:

```bash
az webapp deployment list-publishing-profiles --resource-group "$RG" \
  --name "$APP" --xml
# Save the XML output as the AZURE_WEBAPP_PUBLISH_PROFILE repo secret.
```

## Scaling caveat

Run exactly **one** instance. The dispatcher is an in-process interval timer;
multiple instances would each push independently (harmless for silent pushes,
but wasteful). If you ever need more, move dispatching to a single scheduled
job (e.g. WebJob/Function with a timer trigger).
