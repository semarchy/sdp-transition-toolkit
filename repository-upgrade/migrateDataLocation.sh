#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$0")"
. ./migrateCommons

function help {
  cat <<EOF
Usage: ${0##*/} [options]
Options:
  --xdm-api-key <xdm-key>       The API key to access the xDM instance (defaults to \$XDM_API_KEY)
  --xdm-url <url>               The base URL of the xDM instance (defaults to \$XDM_URL)
  --xdm-db-host <host>          The database host of the xDM repository (defaults to \$XDM_DB_HOST)
  --xdm-db-port <port>          The database port of the xDM repository (defaults to \$XDM_DB_PORT)
  --xdm-db-username <username>  The database username of the xDM repository (defaults to \$XDM_DB_USERNAME)
  --xdm-db-password <password>  The database password of the xDM repository (defaults to \$XDM_DB_PASSWORD)
  --sdp-url <sdp-url>           The base URL of the SDP instance (defaults to \$SDP_URL)
  --sdp-dm-url <dm-url>         The base URL of the SDP DM module if different from <sdp-url>/dm (defaults to \$SDP_DM_URL)
  --sdp-keycloak-url <kc-url>   The base URL of the SDP Keycloak module (defaults to \$SDP_KEYCLOAK_URL)
  --legacy-keycloak             Use legacy keycloak API (instead of Platform keycloak)
  --sdp-tenant-name <name>      The tenant name of the SDP instance (defaults to \$SDP_TENANT_NAME)
  --data-location <name>        The name of the data location to migrate (defaults to \$DATA_LOCATION)
  --datasource <name>           The name of the data source to use (defaults to \$DATASOURCE)
  --model-name <name>           The name of the data location model to export (defaults to \$MODEL_NAME)
  --model-edition-key <key>     The edition key of the data location model to export (defaults to \$MODEL_EDITION_KEY)
  --model-root-folder <path>    The root folder of the model in the DXP workspace (defaults to \$MODEL_ROOT_FOLDER)
  --self-hosted                 Use this flag if migrating to a self-hosted SDP instance (defaults to \$SELF_HOSTED)
  --client-id <id>              Client ID used for service account authentication (defaults to \$SEM_CLIENT_ID)
  --client-secret <secret>      Client secret used for service account authentication (defaults to \$SEM_CLIENT_SECRET)
  --help                        Show this help message and exit
EOF
  exit 0
}

# Parse arguments
while (($#)); do
  case $1 in
    --xdm-api-key)              XDM_API_KEY="$2"; shift 2 ;;
    --xdm-url)                  XDM_URL="$2"; shift 2 ;;
    --xdm-db-host)              XDM_DB_HOST="$2"; shift 2 ;;
    --xdm-db-port)              XDM_DB_PORT="$2"; shift 2 ;;
    --xdm-db-username)          XDM_DB_USERNAME="$2"; shift 2 ;;
    --xdm-db-password)          XDM_DB_PASSWORD="$2"; shift 2 ;;
    --sdp-url)                  SDP_URL="$2"; shift 2 ;;
    --sdp-dm-url)               SDP_DM_URL="$2"; shift 2 ;;
    --sdp-keycloak-url)         SDP_KEYCLOAK_URL="$2"; shift 2 ;;
    --legacy-keycloak)          LEGACY_KEYCLOAK="true"; shift 1 ;;
    --sdp-tenant-name)          SDP_TENANT_NAME="$2"; shift 2 ;;
    --data-location)            DATA_LOCATION="$2"; shift 2 ;;
    --datasource)               DATASOURCE="$2"; shift 2 ;;
    --model-name)               MODEL_NAME="$2"; shift 2 ;;
    --model-edition-key)        MODEL_EDITION_KEY="$2"; shift 2 ;;
    --model-root-folder)        MODEL_ROOT_FOLDER="$2"; shift 2 ;;
    --self-hosted)              SELF_HOSTED="true"; shift ;;
    --client-id)                export SEM_CLIENT_ID="$2"; shift 2 ;;
    --client-secret)            export SEM_CLIENT_SECRET="$2"; shift 2 ;;
    --help)                     help ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

require XDM_URL DATA_LOCATION
WORKSPACE_DIR="$HOME/.migrate/${XDM_URL//[:\/]/_}"
mkdir -p "$WORKSPACE_DIR"
STATUS_FILE="$WORKSPACE_DIR/status-data-location-${DATA_LOCATION}"
SDP_DM_URL="${SDP_DM_URL:-$SDP_URL/dm}"
[ -n "$SELF_HOSTED" ] && SELF_HOSTED_FLAG="--self-hosted" || SELF_HOSTED_FLAG=""
[ -n "$LEGACY_KEYCLOAK" ] && LEGACY_KEYCLOAK_FLAG="--legacy-keycloak" || LEGACY_KEYCLOAK_FLAG=""

function exportDataLocationModel {
  if [[ -z "$MODEL_EDITION_KEY" ]]; then
    echo
    echo "[Export data location model] Skipped as no model edition key was provided to export a specific model edition."
    return 0
  fi

  executeOrSkip "Export data location model" || return 0
  require XDM_URL XDM_API_KEY MODEL_NAME MODEL_EDITION_KEY
  XDM_API_KEY="$XDM_API_KEY" \
    run bash exportXdmModel \
      --overwrite --workspace "$WORKSPACE_DIR" \
      --url "$XDM_URL" \
      --model "$MODEL_NAME" \
      --edition-key "$MODEL_EDITION_KEY"
  executed "Export data location model"
}

function convertDataLocationModel {
  if [[ -n "$MODEL_ROOT_FOLDER" && -d "$MODEL_ROOT_FOLDER" && -z "$MODEL_EDITION_KEY" ]]; then
    echo
    echo "[Convert data location model] Skipped as model root folder '$MODEL_ROOT_FOLDER' already exists and no model edition key was provided to convert a specific model edition."
    return 0
  fi

  executeOrSkip "Convert data location model" || return 0
  require MODEL_ROOT_FOLDER MODEL_NAME MODEL_EDITION_KEY
  [ -d "$MODEL_ROOT_FOLDER" ] &&
    die "Model root folder already exists: $MODEL_ROOT_FOLDER. Delete it and restart script."
  run mkdir -p "$MODEL_ROOT_FOLDER"
  run sem-design dm model migrate \
    --xml-path "$WORKSPACE_DIR/models/$MODEL_NAME/$MODEL_NAME [$MODEL_EDITION_KEY].xml" \
    --model-folder-path "$MODEL_ROOT_FOLDER"
  executed "Convert data location model"
}

function fixDataLocationModel {
  executeOrSkip "Fix data location model" || return 0
  require MODEL_ROOT_FOLDER MODEL_NAME
  prompt "Manually fix model issues (if any) in $MODEL_ROOT_FOLDER/src/$MODEL_NAME. Enter C to Continue." "C" >/dev/null
  executed "Fix data location model"
}

function buildDataLocationModelPayload {
  executeOrSkip "Build data location model payload" || return 0
  require MODEL_ROOT_FOLDER MODEL_NAME
  run sem-design dm model build --root-folder "$MODEL_ROOT_FOLDER/src/$MODEL_NAME"
  executed "Build data location model payload"
}

function createDataLocation {
  executeOrSkip "Create data location" || return 0
  require DATA_LOCATION DATASOURCE MODEL_ROOT_FOLDER MODEL_NAME SDP_DM_URL

  local dataLocationVersion modelVersion modelFile
  dataLocationVersion="$(jq -r '.[] | select(.name=="'"$DATA_LOCATION"'") | .version' "$WORKSPACE_DIR/repository/dataLocations.json")"
  modelVersion="$(jq -r ".dataHubModelSchemaVersion" "$MODEL_ROOT_FOLDER/src/$MODEL_NAME/model.json")"
  modelFile="$MODEL_ROOT_FOLDER/src/$MODEL_NAME/model.json"
  cat <<EOF
Creating data location: $DATA_LOCATION
  Data source: $DATASOURCE
  Model: $MODEL_NAME
  Model file: $modelFile
  Model version: $modelVersion
  Data location version: $dataLocationVersion
EOF
  {
    cat <<EOF
{
  "name": "$DATA_LOCATION",
  "dataSource": "${DATASOURCE}",
  "modelSchemaVersion": "$modelVersion",
  "version": "$dataLocationVersion",
  "model": $(cat $modelFile | jq -r ".dataHubModel")
}
EOF
  } |
    # Pass API Key via file descriptor to avoid it appearing in process list (/!\ does not work on Windows)
    curl -s --fail-with-body --location --request POST "$SDP_DM_URL/api/rest/internal/data-locations-attach" \
      --header 'Content-Type: application/json' \
      --header "@/proc/self/fd/3" \
      --data-binary @- 3<<<"Authorization: Bearer $(accessToken)"
  echo
  executed "Create data location"
}

function exportDataLocationResources {
  executeOrSkip "Export data location resources" || return 0
  require XDM_URL XDM_API_KEY XDM_DB_PORT XDM_DB_HOST XDM_DB_USERNAME XDM_DB_PASSWORD DATA_LOCATION
  XDM_API_KEY="$XDM_API_KEY" \
  XDM_REPO_PWD="$XDM_DB_PASSWORD" \
    run bash exportXdm \
        --pretty --overwrite --workspace "$WORKSPACE_DIR" --url "$XDM_URL" \
        --repository-port "${XDM_DB_PORT}" --repository-host "$XDM_DB_HOST" --repository-username "$XDM_DB_USERNAME" \
        --data-locations "$DATA_LOCATION" \
      notificationPolicies continuousLoads purgeSchedule dataNotifications
  executed "Export data location resources"
}

function fixExportedResources {
  executeOrSkip "Fix exported resources" || return 0
  cat <<EOF
Some resources might require manual adjustments before importing them into the target SDP instance.
For example, you might want to update targets of data notifications.
EOF

  prompt "Manually fix exported resources if required. Press C to continue." "C" >/dev/null
  executed "Fix exported resources"
}

function exportDataLocationLoads {
  executeOrSkip "Export data location loads" || return 0
  require XDM_URL XDM_API_KEY XDM_DB_PORT XDM_DB_HOST XDM_DB_USERNAME XDM_DB_PASSWORD DATA_LOCATION
  XDM_API_KEY="$XDM_API_KEY" \
  XDM_REPO_PWD="$XDM_DB_PASSWORD" \
    run bash exportXdm \
        --pretty --overwrite --workspace "$WORKSPACE_DIR" --url "$XDM_URL" \
        --repository-port "${XDM_DB_PORT}" --repository-host "$XDM_DB_HOST" --repository-username "$XDM_DB_USERNAME" \
        --data-locations "$DATA_LOCATION" \
      integLoads
  executed "Export data location loads"
}

function exportDataLocationBatches {
  executeOrSkip "Export data location batches" || return 0
  require XDM_URL XDM_API_KEY XDM_DB_PORT XDM_DB_HOST XDM_DB_USERNAME XDM_DB_PASSWORD DATA_LOCATION
  XDM_API_KEY="$XDM_API_KEY" \
  XDM_REPO_PWD="$XDM_DB_PASSWORD" \
    run bash exportXdm \
        --pretty --overwrite --workspace "$WORKSPACE_DIR" --url "$XDM_URL" \
        --repository-port "${XDM_DB_PORT}" --repository-host "$XDM_DB_HOST" --repository-username "$XDM_DB_USERNAME" \
        --data-locations "$DATA_LOCATION" \
      integBatches
  executed "Export data location batches"
}

function migrateData {
  executeOrSkip "Migrate data" || return 0
  cat <<EOF
When not reusing the original datasource, data need to be migrated in a separate process.
- In case of a SDP SaaS migration or a SDP Self Hosted out-of-place migration, you must migrate your data at this point.
- In case of a SDP Self Hosted in-place migration, no action is needed and you can continue with the script.
EOF
  prompt "Press C when you are ready to continue (data migrated)." "C" >/dev/null
  executed "Migrate data"
}

function importDataLocationResources {
  executeOrSkip "Import data location resources" || return 0
  require SDP_URL SDP_DM_URL DATA_LOCATION SDP_KEYCLOAK_URL SDP_TENANT_NAME
  run bash importXdm \
      --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL" \
      --keycloak-url "$SDP_KEYCLOAK_URL" --keycloak-realm "$SDP_TENANT_NAME" \
      --data-locations "$DATA_LOCATION" \
      $SELF_HOSTED_FLAG \
      $LEGACY_KEYCLOAK_FLAG \
    notificationPolicies continuousLoads purgeSchedule dataNotifications
  executed "Import data location resources"
}

function fixImportedResources {
  executeOrSkip "Fix imported resources" || return 0
  cat <<EOF
Some imported resources might contain secrets that need to be manually fixed.
You can get the list of all the secrets to fix in the files with the extension '.secrets' in the folder '$WORKSPACE_DIR'.
EOF
  prompt "Manually fix all created resources. Enter C to Continue." "C" >/dev/null
  executed "Fix imported resources"
}

function importDataLocationLoads {
  executeOrSkip "Import data location loads" || return 0
  require SDP_URL SDP_DM_URL DATA_LOCATION SDP_KEYCLOAK_URL SDP_TENANT_NAME
  run bash importXdm \
      --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL" \
      --keycloak-url "$SDP_KEYCLOAK_URL" --keycloak-realm "$SDP_TENANT_NAME" \
      --data-locations "$DATA_LOCATION" \
      $SELF_HOSTED_FLAG \
      $LEGACY_KEYCLOAK_FLAG \
    integLoads
  executed "Import data location loads"
}

function importDataLocationBatches {
  executeOrSkip "Import data location batches" || return 0
  require SDP_URL SDP_DM_URL DATA_LOCATION SDP_KEYCLOAK_URL SDP_TENANT_NAME
  run bash importXdm \
      --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL"  \
      --keycloak-url "$SDP_KEYCLOAK_URL" --keycloak-realm "$SDP_TENANT_NAME" \
      --data-locations "$DATA_LOCATION" \
      $SELF_HOSTED_FLAG \
      $LEGACY_KEYCLOAK_FLAG \
    integBatches
  executed "Import data location batches"
}

function sanitizeDataLocation {
  executeOrSkip "Sanitize data location" || return 0
  require SDP_DM_URL DATA_LOCATION
  {
    cat <<EOF
{
  "name": "$DATA_LOCATION"
}
EOF
  } |
    # Pass API Key via file descriptor to avoid it appearing in process list (/!\ does not work on Windows)
    curl -s --fail-with-body --location --request POST "$SDP_DM_URL/api/rest/internal/data-locations-sanitize" \
      --header 'Content-Type: application/json' \
      --header "@/proc/self/fd/3" \
      --data-binary @- 3<<<"Authorization: Bearer $(accessToken)"
  executed "Sanitize data location"
}

function setDataLocationReady {
  executeOrSkip "Set data location ready" || return 0
  require DATA_LOCATION
  run sem dm data-locations set-status "$DATA_LOCATION" DL_READY
  executed "Set data location ready"
}

available importXdm exportXdm exportXdmModel sem sem-design curl
checkSemAuthentication "$SDP_URL"

if [ -f "$STATUS_FILE" ]; then
  echo "Resuming migrate process..."
  echo "To start over, delete the status file at: $STATUS_FILE"
else
  echo "Starting migrate process..."
fi

echo
prompt "🚨 Source data location ($DATA_LOCATION) must be frozen (no more changes) before migration 🚨
You can do that for instance by setting it to maintenance mode and waiting for all jobs to complete.
Press C to continue" "C" >/dev/null

migrateData

# Export phase: those steps require access to source XDM instance
exportDataLocationResources
fixExportedResources
exportDataLocationLoads
exportDataLocationBatches
exportDataLocationModel

# Import phase: those steps require access to target SDP instance
convertDataLocationModel
fixDataLocationModel
buildDataLocationModelPayload
createDataLocation
importDataLocationResources
fixImportedResources
importDataLocationLoads
importDataLocationBatches
sanitizeDataLocation
setDataLocationReady
