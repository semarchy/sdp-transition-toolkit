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
  --sequence-increment <number> The sequence increment to use when exporting sequences (defaults to \$SEQUENCE_INCREMENT)
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
    --xdm-api-key)            XDM_API_KEY="$2"; shift 2 ;;
    --xdm-url)                XDM_URL="$2"; shift 2 ;;
    --xdm-db-host)            XDM_DB_HOST="$2"; shift 2 ;;
    --xdm-db-port)            XDM_DB_PORT="$2"; shift 2 ;;
    --xdm-db-username)        XDM_DB_USERNAME="$2"; shift 2 ;;
    --xdm-db-password)        XDM_DB_PASSWORD="$2"; shift 2 ;;
    --sdp-url)                SDP_URL="$2"; shift 2 ;;
    --sdp-dm-url)             SDP_DM_URL="$2"; shift 2 ;;
    --sdp-keycloak-url)       SDP_KEYCLOAK_URL="$2"; shift 2 ;;
    --legacy-keycloak)        LEGACY_KEYCLOAK="true"; shift ;;
    --sdp-tenant-name)        SDP_TENANT_NAME="$2"; shift 2 ;;
    --sequence-increment)     SEQUENCE_INCREMENT="$2"; shift 2 ;;
    --self-hosted)            SELF_HOSTED="true"; shift ;;
    --client-id)              export SEM_CLIENT_ID="$2"; shift 2 ;;
    --client-secret)          export SEM_CLIENT_SECRET="$2"; shift 2 ;;
    --help)                   help ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

require SDP_URL
SDP_DM_URL="${SDP_DM_URL:-$SDP_URL/dm}"

require XDM_URL
WORKSPACE_DIR="$HOME/.migrate/${XDM_URL//[:\/]/_}"
mkdir -p "$WORKSPACE_DIR"
STATUS_FILE="$WORKSPACE_DIR/status-repository"
[ -n "$SELF_HOSTED" ] && SELF_HOSTED_FLAG="--self-hosted" || SELF_HOSTED_FLAG=""
[ -n "$LEGACY_KEYCLOAK" ] && LEGACY_KEYCLOAK_FLAG="--legacy-keycloak" || LEGACY_KEYCLOAK_FLAG=""

function exportRepositoryResources {
  executeOrSkip "Export repository resources" || return 0
  require XDM_API_KEY XDM_URL XDM_DB_PORT XDM_DB_HOST XDM_DB_USERNAME XDM_DB_PASSWORD
  XDM_API_KEY="$XDM_API_KEY" \
  XDM_REPO_PWD="$XDM_DB_PASSWORD" \
    run bash exportXdm \
        --pretty --overwrite --workspace "$WORKSPACE_DIR" --url "$XDM_URL" \
        --repository-port "${XDM_DB_PORT}" --repository-host "$XDM_DB_HOST" --repository-username "$XDM_DB_USERNAME" \
      users \
      roles \
      apiKeys \
      notificationServers \
      pluginBundles \
      imageLibraries \
      restClients \
      variableProviders \
      properties \
      dataSources \
      dashboards \
      translations
  executed "Export repository resources"
}

function fixExportedResources {
  executeOrSkip "Fix exported resources" || return 0
  cat <<EOF
Some resources might require manual adjustments before importing them into the target SDP instance.
For example, you might want to:
- Remove all users you don't want to import (as they will receive an onboarding email with a short-lived link to set their password)
- Update datasources JDBC URL as they could be different in the target environment
- Update the notification servers configuration (SMTP server, etc.)
- Update the ServerBaseURL property to reflect the target SDP instance URL (properties.json)
- More generally any resource that contains environment-specific configuration (variable providers, rest clients, etc.)
EOF
  prompt "Manually fix exported resources if required. Enter C to Continue." "C" >/dev/null
  executed "Fix exported resources"
}

function importRepositoryResources {
  executeOrSkip "Import repository resources" || return 0
  require SDP_URL SDP_DM_URL SDP_TENANT_NAME SDP_KEYCLOAK_URL
    run bash importXdm \
        --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL" \
        --keycloak-realm "$SDP_TENANT_NAME" --keycloak-url "$SDP_KEYCLOAK_URL" \
        $SELF_HOSTED_FLAG \
        $LEGACY_KEYCLOAK_FLAG \
        --split-translations \
      roles \
      notificationServers \
      pluginBundles \
      imageLibraries \
      restClients \
      variableProviders \
      properties \
      dataSources \
      dashboards \
      translations
  executed "Import repository resources"
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

function importUsers {
  executeOrSkip "Import users" || return 0
  require SDP_URL SDP_DM_URL SDP_TENANT_NAME SDP_KEYCLOAK_URL
    run bash importXdm \
        --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL" \
        --keycloak-realm "$SDP_TENANT_NAME" --keycloak-url "$SDP_KEYCLOAK_URL" \
        $SELF_HOSTED_FLAG \
        $LEGACY_KEYCLOAK_FLAG \
      users
  executed "Import users"
}

function exportRepositorySequences {
  executeOrSkip "Export repository sequences" || return 0
  require XDM_URL XDM_DB_PORT XDM_DB_HOST XDM_DB_USERNAME XDM_DB_PASSWORD SEQUENCE_INCREMENT
  XDM_API_KEY="$XDM_API_KEY" \
  XDM_REPO_PWD="$XDM_DB_PASSWORD" \
    run bash exportXdm \
        --pretty --overwrite --workspace "$WORKSPACE_DIR" --url "$XDM_URL" \
        --repository-port "${XDM_DB_PORT}" --repository-host "$XDM_DB_HOST" --repository-username "$XDM_DB_USERNAME" \
        --sequence-increment "$SEQUENCE_INCREMENT" \
      sequences
  executed "Export repository sequences"
}

function importRepositorySequences {
  executeOrSkip "Import repository sequences" || return 0
  require SDP_URL SDP_DM_URL SDP_TENANT_NAME SDP_KEYCLOAK_URL
    run bash importXdm \
        --workspace "$WORKSPACE_DIR" --url "$SDP_URL" --url-dm "$SDP_DM_URL" \
        --keycloak-realm "$SDP_TENANT_NAME" --keycloak-url "$SDP_KEYCLOAK_URL" \
        $SELF_HOSTED_FLAG \
        $LEGACY_KEYCLOAK_FLAG \
      sequences
  executed "Import repository sequences"
}

available importXdm exportXdm sem sem-design
checkSemAuthentication "$SDP_URL"

if [ -f "$STATUS_FILE" ]; then
  echo "Resuming migrate process..."
  echo "To start over, delete the status file at: $STATUS_FILE"
else
  echo "Starting migrate process..."
fi

# Export phase: those steps require access to source XDM instance
exportRepositoryResources
fixExportedResources
exportRepositorySequences

# Import phase: those steps require access to target SDP instance
importRepositoryResources
fixImportedResources
importUsers
importRepositorySequences
