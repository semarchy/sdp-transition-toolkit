#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Environment variables for migrateRepository.sh and migrateDataLocation.sh
#
# Usage (must be SOURCED, not executed, so the variables stay in your shell):
#   source ./setEnv.sh        # or:  . ./setEnv.sh
#   bash ./migrateRepository.sh
#   bash ./migrateDataLocation.sh
#
# Replace every <...> placeholder. Do not commit this file once it holds real
# API keys, passwords or client secrets.
# Variables are only checked when the step that needs them runs, so you can
# leave the SDP ones as placeholders while only exporting from xDM.
# -----------------------------------------------------------------------------

# ===== Source: xDM instance (both scripts) ==================================
export XDM_URL="http://localhost:8088/semarchy"        # Base URL of the xDM instance
export XDM_API_KEY="<xdm-api-key>"                     # API key for the xDM REST API

# ===== Source: xDM repository database (both scripts) =======================
export XDM_DB_HOST="localhost"                         # Repository DB host
export XDM_DB_PORT="5432"                              # Repository DB port
export XDM_DB_USERNAME="semarchy_repository"           # Repository DB user
export XDM_DB_PASSWORD="<xdm-db-password>"             # Repository DB password

# ===== Target: SDP instance (both scripts) ==================================
export SDP_URL="https://<sdp-host>"                    # Base URL of the SDP instance
export SDP_TENANT_NAME="<sdp-tenant-name>"             # Target SDP tenant name
export SDP_KEYCLOAK_URL="https://<sdp-host>/auth"      # Keycloak base URL of the tenant

# ===== Flags (both scripts) =================================================
# WARNING: any non-empty value turns the flag ON (even "false").
# To turn a flag off, unset it.
export SELF_HOSTED="true"                              # Target is self-hosted SDP
# unset SELF_HOSTED                                    # <- use this for SDP SaaS

# ===== sem CLI service-account authentication (optional, both scripts) ======
# Set BOTH only if the sem CLI is not already logged in (sem auth login).
# If SEM_CLIENT_ID is set, it takes precedence over an existing sem session.
# API-key based sem authentication is NOT supported by the migration scripts.
unset SEM_CLIENT_ID SEM_CLIENT_SECRET
# export SEM_CLIENT_ID="<client-id>"
# export SEM_CLIENT_SECRET="<client-secret>"

# ===== migrateRepository.sh only ============================================
# Single value for all sequences, or per sequence:
#   "batchId:1000000,dataNotifLogId:500000,loadId:1000000,revision:10000000"
export SEQUENCE_INCREMENT="1000000"

# ===== migrateDataLocation.sh only ==========================================
export DATA_LOCATION="<data-location-name>"            # Data location to migrate
export DATASOURCE="<datasource-name>"                  # Datasource used by the data location
export MODEL_NAME="<model-name>"                       # Model to export/convert/import
export MODEL_ROOT_FOLDER="$HOME/DXP/<model-name>"      # Model root folder in the DXP workspace containing the 'src' folder
# MODEL_EDITION_KEY: set it to export + convert the model from xDM.
# Leave it unset if the converted model already exists in MODEL_ROOT_FOLDER.
# Make sure the seml files can be found in $MODEL_ROOT_FOLDER/src/$MODEL_NAME
export MODEL_EDITION_KEY="0.0"
# unset MODEL_EDITION_KEY

# ===== Optional: importXdm.sh =================================================
# export IMPORTXDM_NO_CACHE="true"                     # Disable importXdm caching

echo "Migration environment variables set for xDM '$XDM_URL' -> SDP '$SDP_URL' (tenant '$SDP_TENANT_NAME')."
