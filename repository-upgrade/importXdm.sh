#!/bin/bash
set -eo pipefail
trap 'onExit $?;' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

VERBOSE=0
PROG_ARGS=( "$@" )
PROG_HIDDEN_DIR="$HOME/.importXdm"
mkdir -p "$PROG_HIDDEN_DIR"
CACHE_FILE="$PROG_HIDDEN_DIR/cache"
# Setting CACHE_EXPIRATION to 50s because the Keycloak token is valid for 60s
CACHE_EXPIRATION=50 # seconds
CACHE_DISABLED=${IMPORTXDM_NO_CACHE:-}
# reset cache file on each run to avoid stale keycloak token
rm -f "$CACHE_FILE"
touch $CACHE_FILE

TMP_DIR="/tmp/importXdm"
mkdir -p "$TMP_DIR"

BOLD="$(tput bold 2>&- || :)"
CYAN=$(tput setaf 6)
ORANGE=$(tput setaf 3)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

#if linux os then add icon padding (for multiple character icons)
if [[ "$(uname -s)" == "Linux" ]]; then
  ICON_PADDING=" "
fi

SPINNER_FRAMES=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
SPINNER_ENABLED=true

DEFAULT_URL="http://customer.kind.local.gd"
DEFAULT_REALM="customer"
DEFAULT_WORKSPACE="./exportWorkspace"

DEFAULT_KEYCLOAK_USERNAME="semadmin"
DEFAULT_USER_LANGUAGE="en"

LEGACY_KEYCLOAK=false

CHANGE_ME_PASSWORD='{ "type": "secret-shared", "vaultName": "Not a vault", "secretName": "Change me", "secretProperty": "Change me" }'

AVAILABLE_RESOURCES=(
  users
  roles
  pluginBundles
  imageLibraries
  restClients
  variableProviders
  properties
  notificationServers
  datasources
  sequences
  dashboards
  translations
  integBatches
  integLoads
  notificationPolicies
  continuousLoads
  purgeSchedule
  dataNotifications
)

DATA_LOCATION_RESOURCES=(
  notificationPolicies
  continuousLoads
  purgeSchedule
  dataNotifications
  integBatches
  integLoads
)

declare -A RESOURCE_ICONS=(
  [repository]="📦"
  [users]="👪"
  [roles]="🛡️$ICON_PADDING"
  [notificationServers]="📧"
  [pluginBundles]="🔌"
  [imageLibraries]="🖼️$ICON_PADDING"
  [restClients]="🌐"
  [variableProviders]="🔢"
  [translations]="🌍"
  [apiKeys]="🔑"
  [datasources]="🛢️$ICON_PADDING"
  [properties]="⚙️$ICON_PADDING"
  [dashboards]="📊"
  [notificationPolicies]="📣"
  [continuousLoads]="🔄"
  [purgeSchedule]="🧹"
  [dataNotifications]="🚨"
  [sequences]="⏩"
  [dataLocations]="🗺️$ICON_PADDING"
  [integBatches]="🗃️$ICON_PADDING"
  [integLoads]="🚚"
)
ICONS_ENABLED=true

getResourceIcon() {
  if [ "$ICONS_ENABLED" == false ]; then
    echo ""
    return
  fi
  local resource="$1"
  echo "${RESOURCE_ICONS["$resource"]:-❓} "
}

help()
{
    info "_______ Import xDM to SDP _______
This script imports xDM data from a workspace (exported using exportXdm and exportXdmModel scripts).

Usage: $(basename "$0") [resource1 resource2 ...] [-h] [-v] [-y] [-u <url>] [-w <workspaceDir>] [--data-locations <dataLocationoc1,dataLocationoc2,...>]
Arguments
        $(bold "[resource1 resource2 ...]   :") Resources to import. Default: all resources. Available (case insensitive): ${AVAILABLE_RESOURCES[*]}
        $(bold "--url -u                    :") Target SDP URL. Default: $DEFAULT_URL
        $(bold "--url-dm                    :") DM URL in SDP. Default: <Target SDP URL>/dm
        $(bold "--workspace -w              :") Workspace directory for exported data, optionally paired with a datasource to assign. Default: $DEFAULT_WORKSPACE
        $(bold "--data-locations            :") Comma-separated list of data locations to import (all exported data locations are imported if not specified).
        $(bold "--self-hosted               :") Self-hosted SDP (enables import for non SaaS resources)
        $(bold "--client-id                 :") Client ID used for service account authentication (defaults to \$SEM_CLIENT_ID)
        $(bold "                             ") Note: service account authentication also requires client secret to be provided (via \$SEM_CLIENT_SECRET)
        $(bold "--keycloak-url              :") Keycloak Admin URL. Default: <SDP_URL>/auth
        $(bold "--keycloak-realm            :") Keycloak Realm. Default: $DEFAULT_REALM
        $(bold "--legacy-keycloak           :") Use legacy keycloak API (instead of Platform keycloak)
        $(bold "--user-default-language     :") Language for user's without a supported keycloak language. Default: $DEFAULT_USER_LANGUAGE
        $(bold "--no-spinner                :") Disable wait spinner
        $(bold "--no-icons                  :") Disable icons
        $(bold "--no-colors                 :") Disable text colors
        $(bold "--skip                      :") Comma-separated list of resources to skip import.
        $(bold "--ignore-missing-dloc       :") Ignore missing data location(s). Default: fail script if requested data location missing in target plarform
        $(bold "--keep-temp                 :") Do not delete temporary files on exit
        $(bold "--split-translations        :") Extracts archive to temp and creates multiple smaller archives (one per subfolder) before import to avoid size limits.
        $(bold "--show-skipped              :") Log skipped imports.
        $(bold "-v                          :") Verbose mode (-vv for more verbosity)
        $(bold "-x                          :") Debug mode (same as bash +x)
        $(bold "-y                          :") Automatically answer 'yes' to all prompts (replace existing elements in SDP).
        $(bold "--help -h                   :") Show this help message and exit

Required external commands:
    - curl for http calls
    - jq for JSON processing
    - getopt for argument parsing
    - sem (Command Line Interface to operate the Semarchy Data Platform)
    - md5sum for token cache
    - gzip and unzip for archive handling

Examples
  Import all exported xDM resources to https://mySPDHost.com from default workspace
      $(basename "$0") -a 'myApiKey' -u 'https://mySPDHost.com'
  Import users and roles to https://mySPDHost.com from ./myWorkspace workspace
      $(basename "$0") users roles --url 'https://mySPDHost.com' --workspace ./myWorkspace
"
    exit 2
}

deleteTempDir() {
  if [ "$keepTemp" != true ]; then
    log -n "\n🧹 Cleaning up temporary files in $TMP_DIR"
    runWithSpinner rm -rf "$TMP_DIR"
  fi
}

formattedElapsedTime() {
  local startTime=$1
  local elapsed=$(( $(date +%s) - startTime ))
  local hours=$((elapsed/3600))
  local minutes=$(( (elapsed%3600)/60 ))
  local seconds=$((elapsed%60))
  local milliseconds=$(( ( 10#$(date +%N) / 1000000 ) ))
  local formattedElapsed=""
  add() {
    formattedElapsed="${formattedElapsed}$1"
  }
  if [ $hours -gt 0 ]; then
    formattedElapsed="${hours}h"
  fi
  if [ $minutes -gt 0 ]; then
    add "${minutes}min"
  fi
  if [ $seconds -gt 0 ]; then
    add "${seconds}s"
  fi
  if [ $milliseconds -gt 0 ] && [ -z "$formattedElapsed" ]; then
    formattedElapsed="${milliseconds}ms"
  fi
  if [ -z "$formattedElapsed" ]; then
    formattedElapsed="no time at all!"
  fi
  echo "$formattedElapsed"
}

bold() { # text
  local text="$*"
  echo "${BOLD}$text${RESET}"
}

info() {
  if [ "$1" = "-n" ]; then
    shift
    echo -ne "${RESET}$*" >&2
  else
    echo -e "${RESET}$*" >&2
  fi
}

log() {
  if [ "$1" = "-n" ]; then
    shift
    echo -ne "${CYAN}$*${RESET}" >&2
  else
    echo -e "${CYAN}$*${RESET}" >&2
  fi
}

warn() {
  if [ "$1" = "-n" ]; then
    shift
    echo -ne "${ORANGE}$*${RESET}" >&2
  else
    echo -e "${ORANGE}$*${RESET}" >&2
  fi
}

error() {
  if [ "$1" = "-n" ]; then
    shift
    echo -ne "${RED}$*${RESET}" >&2
  else
    echo -e "${RED}$*${RESET}" >&2
  fi
}

onExit() { # code lineno
  # restore terminal cursor (hidden for spinner)
  tput cnorm
  local code="$1" lineno="$2"

  if [ "$code" -eq 0 ]; then
    return
  fi

  echo -ne "\a"
  case "$code" in
    130) error "\n\nReceived user cancellation (Ctrl+C)"; exit $code ;;
    137|143) error "\n\nProcess terminated/killed"; exit $code ;;
  esac

  local atLine=
  [ -n "$lineno" ] && atLine=" at line $lineno"
  >&2 cat <<EOF

⚠️  Oops, an error occurred ($code)$atLine.
You can restart the script in verbose (-v, -vv) or debug (-x) mode.
Args: ${PROG_ARGS[*]}
EOF
  exit 1
}

ellipsis() {
  local str="$1"
  local maxLength="$2"
  local strLength=${#str}
  if (( strLength > maxLength )); then
    local partLength=$(( maxLength - 3 ))
    echo "${str:0:partLength}..."
  else
    echo "$str"
  fi
}

verbose() { # level message
  local level="$1" message="$2"
  (($# == 1)) && message=$(cat)
  if (( level <= VERBOSE )); then
    >&2 echo -e "\n${GREEN}$message" ;
  fi
}

die() {
  set -eo pipefail
  error "$*"
  exit 1
}

available() { # cmd ...
  for cmd in "$@"; do
    verbose 2 "Checking availability of command: $cmd"
    if [ "$cmd" = "sem" ] && [ -n "$sem" ] && [ "$sem" != "sem" ]; then
      echo "sem CLI $($sem version)"
      if [ ! $? ]; then
        die "sem CLI not found in PATH, please install it from https://github.com/semarchy/platform-cli/releases"
      fi
      return
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "$cmd: command required by this script, you must install or define it"
    fi
  done
}

[ "$( (echo "5.0"; echo "$BASH_VERSION") | sort -V | head -1)" = "5.0" ] || die "Bash 5.0 or higher is required"

# because `jq -r` does not trim the trailing \r on Windows
json() {
  local jqOptions=( "$@" )
  jq "${jqOptions[@]}" | sed 's/\r$//'
}

run() { # command
  local command=( "$@" )
  verbose 1 ">>> ${command[*]}"
  "${command[@]}"
}

runWithSpinner() {
  if [ "$DEBUG" == true ] || [ "$SPINNER_ENABLED" == false ]; then
    run "$@"
    return $?
  fi
  local command=( "$@" )
  verbose 1 ">>> ${command[*]}"
  tput civis
  "${command[@]}" &
  pid=$!
  printf " " >&2
  i=0
  framesCount=${#SPINNER_FRAMES[@]}
  if (( VERBOSE > 1 )); then
    # wait a second
    sleep 1
  fi
  printf " "
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %framesCount ))
    printf "\b${CYAN}%s${RESET}" "${SPINNER_FRAMES[$i]}" >&2
    sleep 0.1
  done
  tput cnorm
  wait $pid
  exitCode=$?
  if [ $exitCode -eq 0 ]; then
    printf "\b✔️$ICON_PADDING"  >&2
  # sm function outputs sem CLI error message, so do not print anything here
  elif [[ ! "${command[0]}" == sm* ]]; then
    die "\b❌\n"
  fi
  # return exit code of "${command[@]}" &
  return $exitCode
}

httpCheckStatus() {
  local specificMessages=( "$@" )
  local method="$1"
  local url="$2"

  for specificMessage in "${specificMessages[@]}"; do
    [[ "$specificMessage" = "$HTTP_STATUS: "* ]] && die "${specificMessage#"$HTTP_STATUS": }"
  done

  if [[ -n "$HTTP_BODY" ]]; then
    errorResponse="\nHTTP Response: $HTTP_BODY"
  fi

  failed() {
    die "HTTP request failed: $1 ($HTTP_STATUS) ($method $url)$errorResponse"
  }
  case "$HTTP_STATUS" in
    2*|3*) return 0 ;;
    400) failed "Bad request" ;;
    401) failed "Unauthorized access" ;;
    403) failed "Forbidden" ;;
    404) failed "Not found" ;;
    409) failed "Conflict" ;;
    4*) failed "Client error" ;;
    5*) failed "Server error" ;;
    *) failed "Unexpected status" ;;
  esac
}

http() { # curlOptions
  local curlOptions=( "$@" )
  local curl="curl -s"
  (( VERBOSE > 1 )) && curl="curl -sv"
  [[ ! " ${curlOptions[*]} " =~ " skipHttpCheckStatus " ]] && doHttpCheckStatus=true
  verbose 1 "$curl -w \" - %{http_code}\" -X ${curlOptions[*]}"

  local response
  response="$($curl -w " - %{http_code}" -X "${curlOptions[@]}" || :)"
  exitCode=$?
  [[ -z "$response" ]] && die "HTTP request failed: no response (possible network error or invalid URL)"
  HTTP_BODY="${response%% - *}"
  HTTP_STATUS="${response#* - }"
  HTTP_STATUS="${HTTP_STATUS%% - *}"
  [[ "$HTTP_STATUS" =~ /^\d{3}$/ ]] && die "HTTP request failed: unable to extract HTTP status"
  if [[ "$doHttpCheckStatus" == true ]]; then
    httpCheckStatus "$1" "$2"
    exitCode=$?
  fi
  verbose 1 "----RESPONSE ----\n$response"
  return $exitCode
}

fileSize() {
  local file="$1"
  if [ -f "$file" ]; then
    du -h "$file" | cut -f1 2>/dev/null || wc -c < "$file"
  else
    echo "0"
  fi
}

replaceSecrets() {
  # replace secret properties
  json --argjson changeMe "$CHANGE_ME_PASSWORD" '
    def replace_secrets:
      if type == "object" and (.type == "secret-internal" or .type == "secret-external") then
        $changeMe
      elif type == "array" then
        map(replace_secrets)
      elif type == "object" then
        with_entries(.value |= replace_secrets)
      else
        .
      end;
    replace_secrets
  ' <<<$(cat)
}

runSem() {
    if [ -n "$SEM_CLIENT_ID" ]; then
      verbose 1 ">>> sem $@ --url $sdpUrl"
      sem "$@" --url "$sdpUrl"
    else
      verbose 1 ">>> sem $@"
      sem "$@"
    fi
}

smToken() {
  if [ -z "$SEM_TOKEN" ]; then
    SEM_TOKEN=$(runSem auth token 2>/dev/null ||
      die "sem CLI not logged in (or logged in with an API-Key, which is not supported). Please login using 'sem auth login' command or set service account authentication parameters/env variables."
    )
  fi
  echo "$SEM_TOKEN"
}

############## Keycloak related functions
setKeycloakRealmUrl() {
  if [ "$LEGACY_KEYCLOAK" = "false" ]; then
    KEYCLOAK_REALM_URL="$keycloakUrl/realms/$keycloakRealm/platform"
    # test if Platform Keycloak API is accessible
    http GET "$KEYCLOAK_REALM_URL/users/profile" skipHttpCheckStatus \
                        -H "Authorization: Bearer $(smToken)"
    if [[ ! "$HTTP_STATUS" =~ ^2 ]]; then
      warn "Unable to access Keycloak Platform realm API at $KEYCLOAK_REALM_URL. Reverted to legacy Keycloak API."
      export LEGACY_KEYCLOAK=true
      export KEYCLOAK_REALM_URL="$keycloakUrl/admin/realms/$keycloakRealm"
    fi
  else
    export KEYCLOAK_REALM_URL="$keycloakUrl/admin/realms/$keycloakRealm"
  fi
}

kcHttp() {
  method="$1"
  url="$2"
  shift 2
  http $method "$url" -H "Authorization: Bearer $(smToken)" "$@"
}

kcGetUserProfileConfig() {
  kcHttp GET "$KEYCLOAK_REALM_URL/users/profile"
  json -r '.' <<<"$HTTP_BODY"
}

kcGetUsers() {
  if [ -z "$keyCloakUsers" ]; then
    kcHttp GET "$KEYCLOAK_REALM_URL/users"
    keyCloakUsers=$(echo "$HTTP_BODY" | json -r '.')
  fi
  echo "$keyCloakUsers"
}

kcListUsernames() {
  local users=$(kcGetUsers)
  json -r '.[] | .username' <<<"$users"
}

kcGetRolesOfUser() {
  local userId="$1"
  kcHttp GET "$KEYCLOAK_REALM_URL/users/$userId/role-mappings/realm"
  json -r '.[] | .name' <<<"$HTTP_BODY" | sort
}

kcCreateOrUpdateUser() {
  getPropOptions() { # propName defaultValue
    local propName="$1"
    # if propName is in select_attrs, return its options, otherwise return empty string
    echo "$select_attrs" | grep -E "^$propName:" | cut -d: -f2- | xargs
  }
  removeCountryCode() {
    local value="${value:-$(cat)}"
    # remove country code if present (e.g. en_US -> en)
    result="$(echo "$value" | cut -d'_' -f1 | cut -d'-' -f1)"
    if [ "$result" != "$value" ]; then
      info -n "\b \n   removed country code from language value '$value', using '$result' instead  "
    fi
    echo "$result"
  }
  validOptionOrDefault() { # value default
    local value="${value:-$(cat)}"
    local propName="$1"
    local propOptions=$(echo "$userProfileConfig" | json -r '.attributes[] | select(.validations.options.options) | "\(.name): \(.validations.options.options | join(","))"' | grep -E "^$propName:" | cut -d: -f2- | xargs)
    local maxLengths=$(echo "$userProfileConfig" | json -r '.attributes[] | select(.validations.options.options) | "\(.name): \(.validations.options.options | join(","))"' | grep -E "^$propName:" | cut -d: -f2- | xargs)
    # defaultValue is first option if propOptions is not empty, empty string otherwise
    local defaultValue=""
    if [ -n "$propOptions" ]; then
      IFS=',' read -r -a optionsArray <<< "$propOptions"
      defaultValue="${optionsArray[0]}"
    fi
    if [ "$propName" == "language" ]; then
      defaultValue="$userDefaultLanguage"
    fi
    # value is valid if it is in propOptions or if propOptions is empty
    if [ -n "$propOptions" ] && [[ ! ",$propOptions," =~ ",$value," ]]; then
      invalidValue=true
    fi
    # if value is invalid, return defaultValue, otherwise return value
    if [ "$invalidValue" == true ]; then
        warn "⚠️ Invalid option '$value' for $propName property (supported options: $propOptions). Using default value '$defaultValue'"
      echo "$defaultValue"
    else
      echo "$value"
    fi
  }
  trimToMaxLength() { # value propName
    local value="${value:-$(cat)}"
    local propName="$1"
    local maxLength=$(echo "$userProfileConfig" | json -r '.attributes[] | select(.name == "'"$propName"'") | .validations.length.max' )
    if [ -n "$maxLength" ] && [ "$maxLength" != "null" ] && [ "${#value}" -gt "$maxLength" ]; then
      local trimmedValue="${value:0:maxLength}"
      warn "⚠️ Value '$value' for $propName property exceeds max length of $maxLength characters. Trimmed to '$trimmedValue'"
      echo "$trimmedValue"
    else
      echo "$value"
    fi
  }
  att() {
    json -r '.'$1' // ""'
  }
  local user="$1"
  local userId="$2"
  local username=$(echo "$user" | att 'name' | trimToMaxLength "username")
  local firstName=$(echo "$user" | att 'firstName' | trimToMaxLength "firstName")
  local lastName=$(echo "$user" | att 'lastName' | trimToMaxLength "lastName")
  local email=$(echo "$user" | att 'email' | trimToMaxLength "email")
  local primaryPhone=$(echo "$user" | att 'primaryPhoneNumber')
  local secondaryPhone=$(echo "$user" | att 'secondaryPhoneNumber')
  local jobTitle=$(echo "$user" | att 'jobTitle')
  local company=$(echo "$user" | att 'companyName' | validOptionOrDefault)
  local department=$(echo "$user" | att 'department' | validOptionOrDefault)
  local address=$(echo "$user" | att 'address')
  local city=$(echo "$user" | att 'city')
  local country=$(echo "$user" | att 'country' | validOptionOrDefault)
  local postalCode=$(echo "$user" | att 'postalCode' | validOptionOrDefault)
  local language=$(echo "$user" | att 'language' | removeCountryCode | validOptionOrDefault "language")
  local timezone=$(echo "$user" | att 'timezone')
  local dateFormat=$(echo "$user" | att 'dateFormat')
  local dateTimeFormat=$(echo "$user" | att 'dateTimeFormat')
  local decimalSeparator=$(echo "$user" | att 'decimalSeparator')
  local thousandSeparator=$(echo "$user" | att 'thousandSeparator')
  local densityMode=$(echo "$user" | att 'densityMode' | validOptionOrDefault "densityMode")
  local roles=$(echo "$user" | att 'roles[]?')

  # method is POST when userId is not provided (create), PUT otherwise (update)
  local method="POST"
  local userUrl="$KEYCLOAK_REALM_URL/users"
  local usernameAttr='
    "username": "'"$email"'",
  '
  if [ -n "$userId" ]; then
    method="PUT"
    userUrl="$userUrl/$userId"
    usernameAttr=''
  fi

  firstNameAttr=""
  if [ -n "$firstName" ]; then
    firstNameAttr='"firstName": "'"$firstName"'"',
  fi
  lastNameAttr=""
  if [ -n "$lastName" ]; then
    lastNameAttr='"lastName": "'"$lastName"'"',
  fi
  
  attribute() {
    local name="$1"
    local isLast="$2"
    local value="${!name}"
    if [ -n "$value" ]; then
      if [ "$isLast" = "true" ]; then
        echo "\"$name\": [\"$value\"]"
      else
        echo "\"$name\": [\"$value\"],"
      fi
    fi
  }
  echo '{
           '"${usernameAttr}"'
           '"${firstNameAttr}"'
           '"${lastNameAttr}"'
           "email": "'"$email"'",
           "enabled": true,
           "attributes": {
             '$(attribute "primaryPhone")'
             '$(attribute "secondaryPhone")'
             '$(attribute "jobTitle")'
             '$(attribute "company")'
             '$(attribute "department")'
             '$(attribute "address")'
             '$(attribute "city")'
             '$(attribute "country")'
             '$(attribute "postalCode")'
             '$(attribute "language")'
             '$(attribute "timezone")'
             '$(attribute "dateFormat")'
             '$(attribute "dateTimeFormat")'
             '$(attribute "decimalSeparator")'
             '$(attribute "thousandSeparator")'
             '$(attribute "densityMode" true)'
           }
         }' > "$TMP_DIR/user_$username.json"

  kcHttp $method "$userUrl" \
    -H "Content-Type: application/json" \
    skipHttpCheckStatus \
    -d @"$TMP_DIR/user_$username.json"

  if [[ ! "$HTTP_STATUS" =~ ^2 ]]; then
    operation="create"
    [ -n "$userId" ] && operation="update"
    errorMessage=$(echo "$HTTP_BODY" | json -r 'if .errors then [.errors[] | select(.field and .errorMessage) | "\(.field): \(.errorMessage)"] | join("\n") else (select(.field and .errorMessage) | "\(.field): \(.errorMessage)") end')
    [ -n "$errorMessage" ] && errorMessage="Reasons:\n$errorMessage"
    if [[ -z "$errorMessage" ]]; then
      httpCheckStatus "Failed to $operation user $displayEmail"
    fi
    error "⚠️ Failed to $operation user $displayEmail $errorMessage\n"
    return 1
  fi
}

kcSendUserInviteEmail() {
  local userId="$1"
  local redirect_uri="$(curl -Gso /dev/null -w '%{url_effective}' --data-urlencode "redirect_uri=$sdpUrl/welcome/api/auth/login" "http://localhost" | cut -d? -f2-)"
  kcHttp PUT "$KEYCLOAK_REALM_URL/users/$userId/execute-actions-email?lifespan=259200&client_id=sem-welcome&$redirect_uri" \
    -H "Content-Type: application/json" \
    -d '["VERIFY_EMAIL","UPDATE_PASSWORD"]'
}

kcDeleteUser() { # userID
  local userId="$1"
  kcHttp DELETE "$KEYCLOAK_REALM_URL/users/$userId"
}

kcGetUserIdByName() { # username
  local username="$1"
  json -r '.[] | select(.username == "'"$username"'") | .id' <<<"$(kcGetUsers)"
}

kcGetRoles() {
  if [ -z "$keyCloakRoles" ]; then
    kcHttp GET "$KEYCLOAK_REALM_URL/roles"
    keyCloakRoles=$(echo "$HTTP_BODY" | json -r '.')
  fi
  echo "$keyCloakRoles"
}

kcGetRoleIdByName() { # roleName
  local roleName="$1"
  json -r '.[] | select(.name == "'"$roleName"'") | .id' <<<"$(kcGetRoles)"
}

kcAssignRolesToUser() { # userId roleId roleName
  local userId="$1" roleId="$2" roleName="$3"
  kcHttp POST "$KEYCLOAK_REALM_URL/users/$userId/role-mappings/realm" \
    -H "Content-Type: application/json" \
    -d "[{ \"id\": \"$roleId\", \"name\": \"$roleName\" }]"
}

kcListRoleNames() {
  local keyCloakRoles=$(kcGetRoles)
  json -r '.[] | .name' <<<"$keyCloakRoles" | sort
}

kcGetSupportedLanguages() {
  if [ -z "$userProfileConfig" ]; then
    userProfileConfig=$(run kcGetUserProfileConfig)
    if [ -z "$userProfileConfig" ]; then
      die "Failed to load Keycloak user profile configuration"
    fi
  fi
  json -r '.attributes[] | select(.name == "language") | .validations.options.options | join(",")' <<<"$userProfileConfig"
}
############## /Keycloak related functions

############## Sem CLI related functions
sm() {
  local options=( "$@" )
  local outputFile="$TMP_DIR/sm_out$$.json"
  local errorFile="$TMP_DIR/sm_err$$.json"
  set +e
  if (( VERBOSE < 2)); then
    # Hide output except for JSON response (if any)
    runSem "${options[@]}" -o "$outputFile" &>"$errorFile" --json
    exitCode=$?
    if [ $exitCode -ne 0 ]; then
      error=$(json -r '"\(.error.statusCode) - \(.error.errorMessage)"' "$outputFile" 2>/dev/null)
    fi
    [[ -f "$outputFile" ]] && response=$(cat "$outputFile")
  else
    response=$(runSem -d "${options[@]}" --json)
    exitCode=$?
    error=$(json -r '"\(.error.statusCode) - \(.error.errorMessage)"' <<<"$response" 2>/dev/null)
  fi
  set -eo pipefail
  if [ $exitCode -ne 0 ]; then
    if [ -z "$error" ]; then
      error=$(cat "$errorFile" 2>/dev/null)
      [ -z "$error" ] && error="Unknown error"
    fi
    error -n "\b❌ $error"
    return $exitCode
  fi
  jsonResponse=$(echo "$response" | json . 2>/dev/null)
  verbose 2 "JSON response:\n$jsonResponse"
  rm -f $outputFile $errorFile
  [ -n "$jsonResponse" ] && echo "$jsonResponse"
  return $exitCode
}

smLoginCheck() {
  runSem auth token >/dev/null 2>&1 ||
    die "sem CLI not logged in (or logged in with an API-Key, which is not supported). Please login using 'sem auth login' command or set service account authentication parameters/env variables."
}

smUserExists() {
  local username="$1"
  statusCode=$(runSem dm admin users get "$username" --json 2>/dev/null | jq -r '.error.statusCode' 2>/dev/null)
  if [ "$statusCode" = "404" ]; then
    return 1
  else
    return 0
  fi
}

waitForDmUser() {
  local username="$1"
  local maxRetries=5
  local retryCount=0
  local waitTime=5
  while [ $retryCount -lt $maxRetries ]; do
    verbose 1 "Waiting for user $username to be created in DM (retry $((retryCount + 1))/$maxRetries)"
    smUserExists "$username"
    if [ $? -eq 0 ]; then
      return 0
    fi
    sleep $waitTime
    retryCount=$((retryCount + 1))
  done
  warn "⚠️ Timed out waiting for user to be created in DM after $((maxRetries * waitTime)) seconds."
  return 1
}

smAssignRoleToUser() {
  set +e
  local username="$1"
  local role="$2"
  smUserExists "$username"
  if [ $? -ne 0 ]; then
    info -n "\bwaiting for user to be created in DM"
    waitForDmUser "$username"
  fi
  if [ $? -ne 0 ]; then
    warn "⚠️ Failed to find user $username in DM, cannot assign role $role\n"
    return 1
  fi
  set -eo pipefail
  sm dm admin users assign "$username" "$role" >/dev/null
}

smUnassignRoleFromUser() {
  local username="$1"
  local role="$2"
  sm dm admin users unassign "$username" "$role"
}

smUnAssignAllRolesFromUser() {
  local username="$1"
  set +e
  smUserExists "$username"
  if [ $? -ne 0 ]; then
    info -n "\b\n   waiting for user to be created in DM"
    runWithSpinner waitForDmUser "$username"
  fi
  local roles=$(echo "$user" | json -r '.roles[]?' | xargs)
  if [ $? -ne 0 ]; then
    verbose 1 "Unknown user $username, cannot unassign roles"
    return 0
  fi
  if [ -z "$roles" ]; then
    verbose 1 "User $username has no roles assigned"
    return 0
  fi
  set -eo pipefail
  for role in $roles; do
    smUnassignRoleFromUser "$username" "$role"
  done
}

smGetJson() {
  local resourceType="$1"
  local dataLocation="$2"
  local command="admin"
  case "$resourceType" in
  "dataLocations")
    command="data-locations"
    resourceType=""
    ;;
  "dashboards applications")
    command="dashboards"
    resourceType="applications"
    ;;
  esac
  if [ -n "$dataLocation" ]; then
    command="data-locations"
    dataLocation="--data-location-name $dataLocation"
  fi
  sm dm "$command" $resourceType $dataLocation --json
}

smListNames() {
  local resourceType="$1"
  local dataLocation="$2"
  smGetJson "$resourceType" $dataLocation | json -r '.[].name' | sort
}

smCreateOrUpdate() {
  local resourceType="$1"
  local resourceContent="$2"
  local resourceName="$3"
  local dataLocation="$4"
  local command="admin"
  if [ -n "$dataLocation" ]; then
    command="data-locations"
    dataLocation="--data-location-name $dataLocation"
  fi
  echo "$resourceContent" | replaceSecrets | sm dm "$command" "$resourceType" set $resourceName $dataLocation >/dev/null
}

smDeletePluginBundle() {
  local bundleName="$1"
  sm dm admin plugin-bundles delete "$bundleName" --force
}

smImportPluginBundle() {
  local file="$1"
  cat "$file" | sm dm admin plugin-bundles import >/dev/null
}

smImportImageLibraryBundle() {
  local file="$1"
  local name="$(basename "$file" .zip)"
  cat "$file" | sm dm admin image-libraries import "$name" >/dev/null
}

smImportDashboard() {
  local file="$1"
  local dashboardName="$2"
  cat "$file" | sm dm dashboards applications import "$dashboardName" >/dev/null
}

smImportTranslations() {
  local file="$1"
  cat "$file" | sm dm admin translations set >/dev/null
}

smGetDataLocationUuid() {
  local dataLocationName="$1"
  sm dm data-locations get "$dataLocationName" --json | json -r '.id'
}

allDone() {
  deleteTempDir

  local elapsed=$(formattedElapsedTime "$mainStartTime")
  ############## All done
  log "\n✔️${ICON_PADDING} All done in $elapsed!"

  exit 0
}

############## /Sem CLI related functions

checkExists() {
  local resource="$1"
  if [[ ! " ${AVAILABLE_RESOURCES[*],,} " =~ " ${resource,,} " ]]; then
    error "Error: Unknown resource '$resource'. Available resources (case-insensitive): ${AVAILABLE_RESOURCES[*]}"
    echo ""
    help
  fi
}

shouldImport() {
  local icon=$(getResourceIcon "$1")
  local disableLogSkipped="$2"
  local resource="$1"
  if ([[ -z "$resources" ]] || [[ ",${resourceArray[*],,}," == *"${resource,,}"* ]]) && \
      ([[ -z "$skipResources" ]] || [[ ! ",${skipResourceArray[*],,}," == *"${resource,,}"* ]]); then
    return 0
  else
    [[ "$showSkipped" == true] && ["$disableLogSkipped" != true ]] && info "skipped ${icon}$resource"
    return 1
  fi
}

############## Main script

mainStartTime=$(date +%s)

cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null

SHORT=u:,w:,v,y,d,x,h
LONG=url:,url-dm:,self-hosted,client-id:,keycloak-url:,keycloak-realm:,legacy-keycloak,user-default-language:,workspace:,data-locations:,\
no-spinner,no-icons,no-colors,skip:,ignore-missing-dlocs,keep-temp,split-translations,show-skipped,help
OPTS=$(getopt -a -n "$(basename "$0")" --options $SHORT --longoptions $LONG -- "$@")

workspace="$DEFAULT_WORKSPACE"
sdpUrl="$DEFAULT_URL"
keycloakUrl="$sdpUrl/auth"
keycloakRealm="$DEFAULT_REALM"
userDefaultLanguage="$DEFAULT_USER_LANGUAGE"

eval set -- "$OPTS"

resources=""
while :
do
  case "$1" in
    -u | --url)
      sdpUrl="$2"
      shift 2
      ;;
    --url-dm)
      urlDm="$2"
      shift 2
      ;;
    --self-hosted)
      selfHosted=true
      shift
      ;;
    --client-id)
      export SEM_CLIENT_ID="$2"
      shift 2
      ;;
    --keycloak-url)
      keycloakUrl="$2"
      shift 2
      ;;
    --keycloak-realm)
      keycloakRealm="$2"
      shift 2
      ;;
    --legacy-keycloak)
      LEGACY_KEYCLOAK=true
      shift
      ;;
    --user-default-language)
      userDefaultLanguage="$2"
      shift 2
      ;;
    -w | --workspace)
      workspace="$2"
      shift 2
      ;;
    --data-locations)
      dataLocations="$2"
      shift 2
      ;;
    --no-spinner)
      SPINNER_ENABLED=false
      shift
      ;;
    --no-icons)
      ICONS_ENABLED=false
      shift
      ;;
    --no-colors)
      CYAN=""
      GREEN=""
      ORANGE=""
      RED=""
      shift
      ;;
    --skip)
      skipResources="$2"
      IFS=',' read -ra skipResourceArray <<< "$skipResources"
      for s in "${skipResourceArray[@]}"; do
        checkExists "$s"
      done
      shift 2
      ;;
    --ignore-missing-dlocs)
      ignoreMissingDlocs=true
      shift
      ;;
    --keep-temp)
      keepTemp=true
      shift
      ;;
    --split-translations)
      splitTranslations=true
      shift
      ;;
    --show-skipped)
      showSkipped=true
      shift
      ;;
    -v) VERBOSE=$((VERBOSE + 1)); shift ;;
    -y) alwaysYes=1; shift ;;
    -x) DEBUG=true; set -x; shift ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) error "Unexpected option: $1"; help ;;
  esac
done

while [ $# -gt 0 ]; do
  if [[ "$1" != -* ]]; then
    if [ -z "$resources" ]; then
      resources="$1"
    else
      resources="$resources,$1"
    fi
  fi
  shift
done

IFS=',' read -ra resourceArray <<< "$resources"
for s in "${resourceArray[@]}"; do
  checkExists "$s"
done

if [ "$selfHosted" == true ]; then
  info "$(bold "Deployment type:") Self-Hosted"
else
  info "$(bold "Deployment type:") SaaS"
fi

if [[ -n "$resources" ]]; then
    info "$(bold "Data to import:") $(IFS=, ; echo "${resources[*]}" | sed 's/,/, /g')"
else
    info "$(bold "Data to import:") all"
fi
available curl jq getopt sem gzip md5sum zip unzip

if [ -z "$sdpUrl" ]; then
  error "Error: SDP URL is required."
  echo ""
  help
else
  info "$(bold "SDP URL:") ${sdpUrl}"
fi

[ -z "$urlDm" ] && urlDm="$sdpUrl/dm"
info "$(bold "DM URL:") ${urlDm}"

smLoginCheck

log "🔑 Configuring Keycloak access"
setKeycloakRealmUrl

supportedLanguages=$(run kcGetSupportedLanguages)
if [[ ! ",$supportedLanguages," =~ ",$userDefaultLanguage," ]]; then
  die "Default keycloak language '$userDefaultLanguage' is not supported by Keycloak (supported languages: $supportedLanguages)"
fi

if [ ! -d "$workspace" ]; then
  die "Workspace directory not found: $workspace"
fi

dmRestUrl="$urlDm/api/rest"

dataLocationWorkspaceDir="$workspace/dataLocations"
mapfile -t workspaceDlocArray < <(find "$dataLocationWorkspaceDir" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null)
allDataLocations=$(IFS=, ; echo "${workspaceDlocArray[*]}")
if [ -n "$dataLocations" ]; then
  IFS=',' read -ra dataLocationArray <<< "$dataLocations"
  for dataLocation in "${dataLocationArray[@]}"; do
    if [ ! -d "$dataLocationWorkspaceDir/$dataLocation" ]; then
      die "Data location directory not found: $dataLocationWorkspaceDir/$dataLocation\nAvailable data locations: $allDataLocations"
    fi
  done
  info "$(bold "Data locations to import:") $(IFS=, ; echo "${dataLocationArray[*]}" | sed 's/,/, /g')"
else
  IFS=',' read -ra dataLocationArray <<< "$allDataLocations"
  info -n "$(bold "Data locations to import:")"
  if [ ${#dataLocationArray[@]} -eq 0 ]; then
    warn " no data locations found in workspace: $dataLocationWorkspaceDir"
  else
    info " all ($(IFS=, ; echo "${dataLocationArray[*]}" | sed 's/,/, /g'))"
  fi
fi

mapToString() {
  local -n map=$1
  local result=""
  for key in "${!map[@]}"; do
    if [ -n "$result" ]; then
      result="$result, "
    fi
    result="$result$key=${map[$key]}"
  done
  echo "$result"
}

repoWorkspaceDir="$workspace/repository"

confirmReplace() {
  local alwaysYesMessage="$1"
  local question="$2"
  local answer="y"

  if [ -z "$alwaysYesMessage" ]; then
    alwaysYesMessage="already exists, replacing"
  fi
  if [ -z "$question" ]; then
    question="already exists, do you want to replace it?"
  fi

  if [ -n "$alwaysYes" ]; then
    info -n " $alwaysYesMessage"
  else
    warn -n " $question [y/N]: "
    read -r answer < /dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      info -n "   replacing"
    fi
  fi

  echo "$answer"
}

if shouldImport "users" "true" || shouldImport "roles" "true"; then
  log -n "\n$(getResourceIcon "users")Loading existing users"
  kcGetUsers >/dev/null

  log -n "\n$(getResourceIcon "roles")Loading existing user roles"
  kcGetRoles >/dev/null
fi

dataLocationsFile="$repoWorkspaceDir/dataLocations.json"
declare -A datasourceDataLocationMap
declare -A sourceDataLocationUuidMap
while IFS= read -r dloc; do
  dlocName=$(echo "$dloc" | json -r '.name')
  dlocDatasource=$(echo "$dloc" | json -r '.dataSource')
  dlocUuid=$(echo "$dloc" | json -r '.id')
  datasourceDataLocationMap["$dlocDatasource"]="$dlocName"
  sourceDataLocationUuidMap["$dlocName"]="$dlocUuid"
done < <(json -c '.[]' "$dataLocationsFile")

############## Users
resource="users"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Users ------"

  importUsers() {
    log -n "Importing $count users from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingUsernames < <(kcListUsernames)
    verbose 1 "Existing SDP usernames:\n${existingUsernames[*]}"

    mapfile -t existingRoleNames < <(kcListRoleNames)
    verbose 1 "Existing SDP roles:\n${existingRoleNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    createUser() {
      local user="$1"
      runWithSpinner kcCreateOrUpdateUser "$user"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateUser() {
      local user="$1"
      local userId="$2"
      local email="$3"
      runWithSpinner kcCreateOrUpdateUser "$user" "$userId"
      if [ $? -eq 0 ]; then
        smUnAssignAllRolesFromUser "$email"
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    while IFS= read -r user; do
      username=$(echo "$user" | json -r '.name')
      email=$(echo "$user" | json -r '.email')
      displayEmail=$(ellipsis "$email" 60)
      roles=$(echo "$user" | json -r '.roles | join(",")')
      xDMUserRole="xDM User"
      # add xDMUserRole to roles if not already present
      if [[ -n "$roles" ]] && [[ ! " $roles " =~ ",$xDMUserRole," ]]; then
        roles="$roles,$xDMUserRole"
      elif [ -z "$roles" ]; then
        roles="$xDMUserRole"
      fi
      log -n "\n - $displayEmail"
      if [ "$username" != "$displayEmail" ]; then
        warn -n " (username '$username' is different than email)"
      fi

      if [[ " ${existingUsernames[*]} " == *" $email "* ]]; then
        userId=$(run kcGetUserIdByName "$email")
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateUser "$user" "$userId" "$email"
          info ""
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createUser "$user"
        info ""
        if [ $? -ne 0 ]; then
          continue
        fi
        userId=$(run kcGetUserIdByName "$email")
      fi

      if [ -n "$userId" ]; then
        info -n "   sending invitation email"
        runWithSpinner kcSendUserInviteEmail "$userId"
      fi

      if [ -n "$roles" ]; then
        # for each role in roles, assign it to user
        IFS=',' read -r -a rolesArray <<< "$roles"
        for role in "${rolesArray[@]}"; do
          role=$(echo "$role" | xargs)
          if [ "$role" == "semarchyAdmin" ]; then
            role="xDM Admin"
            verbose 1 "xDM role semarchyAdmin mapped to SDP role $role"
          fi

          if [[ " ${existingRoleNames[*]} " == *" $role "* ]]; then
            roleId=$(run kcGetRoleIdByName "$role")
            info -n "\n   assigning SDP role '$role'"
            runWithSpinner kcAssignRolesToUser "$userId" "$roleId" "$role"
          else
            info -n "\n   assigning DM role '$role'"
            runWithSpinner smAssignRoleToUser "${email}" "$role"
          fi
        done
      fi
    done < <(json -c '.[]' $inputFile)

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Users imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }

  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "Users file not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi

  if [ $count -eq 0 ]; then
    warn "No users to import"
  else
    importUsers
  fi
fi
############## /Users

############## Roles
resource="roles"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Roles ------"

  importRoles() {
    log -n "Importing $count roles from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingRoleNames < <(run smListNames "roles")
    verbose 1 "Existing DM roles:\n${existingRoleNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    createRole() {
      local role="$1"
      local roleName="$2"
      runWithSpinner smCreateOrUpdate "roles" "$role" "$roleName"
      if [ $? -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
    }

    updateRole() {
      local role="$1"
      local roleName="$2"
      runWithSpinner smCreateOrUpdate "roles" "$role" "$roleName"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    while IFS= read -r role; do
      roleName=$(echo "$role" | json -r '.name')
      log -n "\n - '$roleName'"

      if [[ " ${existingRoleNames[*]} " == *" $roleName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateRole "$role" "$roleName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
          info -n " creating"
        createRole "$role" "$roleName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(json -c '.[]' $inputFile)

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Roles imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }

  count=0
  inputFile="$repoWorkspaceDir/roles.json"
  if [ ! -f "$inputFile" ]; then
    warn "Roles file not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No roles to import"
  else
    importRoles
  fi
fi
############## /Roles

############## Plugin bundles
resource="pluginBundles"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Plugin bundles ------"

  importPluginBundles() {
    log -n "Importing $count plugin bundles from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingPluginBundleNames < <(run smListNames "plugin-bundles")
    verbose 1 "Existing DM plugin bundles:\n${existingPluginBundleNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    importPluginBundle() {
      local bundleFile="$1"
      runWithSpinner smImportPluginBundle "$bundleFile"
      if [ $? -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
    }

    replacePluginBundle() {
      local bundleFile="$1"
      local bundleName="$2"
      runWithSpinner smDeletePluginBundle "$bundleName"
      runWithSpinner smImportPluginBundle "$bundleFile"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    while IFS= read -r pluginBundle; do
      bundleName=$(echo "$pluginBundle" | json -r '.name')
      bundleFilePath="$repoWorkspaceDir/$resource/${bundleName}.jar"
      if [ ! -f "${bundleFilePath}" ]; then
        warn -n "Plugin bundle jar not found: $bundleFilePath, skipping"
        failed=$((failed+1))
        continue
      fi
      version=$(echo "$pluginBundle" | json -r '.version')
      provider=$(echo "$pluginBundle" | json -r '.provider')
      state=$(echo "$pluginBundle" | json -r '.state')
      filePath="$repoWorkspaceDir/$resource/${name}.jar"
      log -n "\n - '$bundleName' (version: $version, provider: $provider)"
      if [[ " ${existingPluginBundleNames[*]} " == *" $bundleName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          replacePluginBundle "$bundleFilePath" "$bundleName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        importPluginBundle "$bundleFilePath"
      fi
    done < <(json -c '.[]' $inputFile)

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Plugin bundles imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }

  if [ "$selfHosted" != true ]; then
    warn "⚠️ Plugin bundles can only be imported for self-hosted installations, skipping"
  else
    count=0
    inputFile="$repoWorkspaceDir/pluginBundles.json"
    if [ ! -f "$inputFile" ]; then
      warn "File not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi

    if [ $count -eq 0 ]; then
      warn "No pluginBundles to import"
    else
      importPluginBundles
    fi
  fi
fi
############## /Plugin bundles

############## Image libraries
resource="imageLibraries"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Image libraries ------"

  importImageLibraries() {
    log -n "Importing $count image libraries from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingImageLibraryNames < <(run smListNames "image-libraries")
    verbose 1 "Existing DM image libraries:\n${existingImageLibraryNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    importImageLibrary() {
      local libraryFile="$1"
      runWithSpinner smImportImageLibraryBundle "$libraryFile"
      if [ $? -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
    }

    replaceImageLibrary() {
      local libraryFile="$1"
      local libraryName="$2"
      runWithSpinner smImportImageLibraryBundle "$libraryFile"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    count=0
    while IFS= read -r imageLibrary; do
      libraryName=$(echo "$imageLibrary" | json -r '.name')
      libraryFilePath="$repoWorkspaceDir/$resource/${libraryName}.zip"
      if [ ! -f "${libraryFilePath}" ]; then
        warn -n "\nImage library zip not found: $libraryFilePath, skipping"
        failed=$((failed+1))
        continue
      fi

      filePath="$repoWorkspaceDir/$resource/${name}.zip"
      log -n "\n - '$libraryName'"
      if [[ " ${existingImageLibraryNames[*]} " == *" $libraryName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          replaceImageLibrary "$libraryFilePath" "$libraryName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " importing"
        importImageLibrary "$libraryFilePath"
      fi
      count=$((count+1))
    done < <(json -c '.[]' $inputFile)

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Image libraries imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }

  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "File not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No $resource to import"
  else
    importImageLibraries
  fi
fi
############## /Image libraries

############## Rest clients
resource="restClients"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}REST clients ------"

  importRestClients() {
    log -n "Importing $count REST clients from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingRestClientNames < <(run smListNames "rest-clients")
    verbose 1 "Existing SDP REST clients:\n${existingRestClientNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    createRestClient() {
      local restClient="$1"
      local restClientName="$2"
      runWithSpinner smCreateOrUpdate "rest-clients" "$restClient" "$restClientName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateRestClient() {
      local restClient="$1"
      local restClientName="$2"
      runWithSpinner smCreateOrUpdate "rest-clients" "$restClient" "$restClientName"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    while IFS= read -r restClient; do
      restClientName=$(echo "$restClient" | json -r '.name')
      log -n "\n - '$restClientName'"

      if [[ " ${existingRestClientNames[*]} " == *" $restClientName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateRestClient "$restClient" "$restClientName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createRestClient "$restClient" "$restClientName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(json -c '.[]' $inputFile)
    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}REST clients imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }
  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "REST clients file not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No REST clients to import"
  else
    importRestClients
  fi
fi
############## /Rest clients

############## Variable providers
resource="variableProviders"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Variable providers ------"

  importVariableProviders() {
    log -n "Importing $count variable providers from $inputFile"
    datasourcePlugin="com.semarchy.semql.plugins.convergence.sql.variableprovider.datasource"
    if [ "$selfHosted" != true ]; then
      warn -n "\nOnly '$datasourcePlugin' plugins are supported for SaaS."
    fi
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingVariableProviderNames < <(run smListNames "variable-providers")
    verbose 1 "Existing SDP Variable providers:\n${existingVariableProviderNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    createVariableProvider() {
      local variableProvider="$1"
      local variableProviderName="$2"
      runWithSpinner smCreateOrUpdate "variable-providers" "$variableProvider" "$variableProviderName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateVariableProvider() {
      local variableProvider="$1"
      local variableProviderName="$2"
      runWithSpinner smCreateOrUpdate "variable-providers" "$variableProvider" "$variableProviderName"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    while IFS= read -r variableProvider; do
      variableProviderName=$(echo "$variableProvider" | json -r '.name')
      variableProviderPluginId=$(echo "$variableProvider" | json -r '.pluginId')
      log -n "\n - '$variableProviderName' (plugin '$variableProviderPluginId')"
      if [ "$selfHosted" != true ] && [ "$variableProviderPluginId" != "$datasourcePlugin" ]; then
        warn -n " skipped (unsupported plugin)"
        skipped=$((skipped+1))
        continue
      fi

      if [[ " ${existingVariableProviderNames[*]} " == *" $variableProviderName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateVariableProvider "$variableProvider" "$variableProviderName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createVariableProvider "$variableProvider" "$variableProviderName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(json -c '.[]' $inputFile)
    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Variable providers imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }
  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "Variable providers files not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No variableProviders to import"
  else
    importVariableProviders
  fi
fi
############## /Variable providers

############## Properties
resource="properties"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Properties ------"

  importProperties() {
    log "Importing properties from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    existingProperties=$(smGetJson "properties" | json .)
    verbose 1 "Existing SDP properties:\n$existingProperties"

    updated=0
    failed=0

    properties=$(json . "$inputFile")
    if [ -z "$properties" ] || [ "$properties" = "null" ]; then
      warn "No properties to import"
      return
    fi
    count=$(json 'length' <<<"$properties")

    existingServerBaseUrl=$(json -r '.ServerBaseUrl' <<<"$existingProperties")
    inputServerBaseUrl=$(json -r '.ServerBaseUrl' <<<"$properties")

    if [ "$existingServerBaseUrl" != "$inputServerBaseUrl" ]; then
      warn "serverBaseUrl '$inputServerBaseUrl' is different from current '$existingServerBaseUrl'."
      if [ "$selfHosted" != true ]; then
        existingServerBaseUrl=$(json -r '.ServerBaseUrl' <<<"$existingProperties")
        warn "keeping current SaaS platform value."
        properties=$(json --arg url "$existingServerBaseUrl" '.ServerBaseUrl = $url' <<<"$properties")
      else
        warn "updating for self-hosted platform."
      fi
    fi

    # Count properties with values different from existing
    updated=0
    while IFS= read -r key; do
      newValue=$(json -r --arg key "$key" '.[$key]' <<<"$properties")
      existingValue=$(json -r --arg key "$key" '.[$key]' <<<"$existingProperties")
      if [ "$newValue" != "$existingValue" ]; then
        updated=$((updated+1))
        warn "Property '$key' value will be updated from '$existingValue' to '$newValue'"
      fi
    done < <(json -r 'keys[]' <<<"$properties")

    info -n "Updating properties"
    runWithSpinner smCreateOrUpdate "properties" "$properties"
    if [ $? -ne 0 ]; then
      updated=0
      failed=$updated
    fi
    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Properties imported in ${elapsed}: $count processed, $updated updated, $failed failed ------\n"
  }

  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "Properties files not found: $inputFile"
  else
    importProperties
  fi
fi
############## /Properties

############## Notification servers
resource="notificationServers"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Notification servers ------"

  importNotificationServers() {
    log -n "Importing $count notification servers from $inputFile"
    smtpPlugin="com.semarchy.notification.plugin.convergence.mail.smtp"
    if [ "$selfHosted" != true ]; then
      warn -n "\nOnly '$smtpPlugin' plugins are supported for SaaS."
    fi
    # start calculating elapsed time
    startTime=$(date +%s)

    mapfile -t existingNotificationServerNames < <(run smListNames "notification-servers")
    verbose 1 "Existing DM notification servers:\n${existingNotificationServerNames[*]}"
    created=0
    updated=0
    skipped=0
    failed=0

    createNotificationServer() {
      local notificationServer="$1"
      local notificationServerName="$2"
      runWithSpinner smCreateOrUpdate "notification-servers" "$notificationServer" "$notificationServerName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateNotificationServer() {
      local notificationServer="$1"
      local notificationServerName="$2"
      runWithSpinner smCreateOrUpdate "notification-servers" "$notificationServer" "$notificationServerName"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    replaceMailAuthProperty() {
      local notificationServer="$1"
      # check if auth property is missing in pluginProperties
      notificationServerMailAuth=$(echo "$notificationServer" | json -r '.pluginProperties["mail.smtp.auth"] // empty')
      notificationServerAuth=$(echo "$notificationServer" | json -r '.pluginProperties.auth // empty')
      # add auth property if missing and plugin is SMTP
      if [ "$notificationServerAuth" = "null" ] || [ -z "$notificationServerAuth" ]; then
        notificationServerAuth="None"
        if [ "$notificationServerMailAuth" == "true" ]; then
          notificationServerAuth="Basic"
        fi
        notificationServer=$(json --arg auth "$notificationServerAuth" '.pluginProperties.auth = $auth' <<<"$notificationServer")
        notificationServer=$(json 'del(.pluginProperties["mail.smtp.auth"])' <<<"$notificationServer")
        warn " replaced \"mail.smtp.auth\": \"$notificationServerMailAuth\" with \"auth\": \"$notificationServerAuth\" in plugin properties"
      fi
      echo "$notificationServer"
    }

    while IFS= read -r notificationServer; do
      notificationServerName=$(echo "$notificationServer" | json -r '.name')
      notificationServerPluginId=$(echo "$notificationServer" | json -r '.pluginId')
      log -n "\n - '$notificationServerName' (plugin '$notificationServerPluginId')"
      if [[ "$notificationServerPluginId" != "$smtpPlugin" ]]; then
        if [ "$selfHosted" != true ]; then
          warn -n " skipped (unsupported SaaS plugin)"
          skipped=$((skipped+1))
          continue
        fi
      fi
      if [ "$notificationServerPluginId" = "$smtpPlugin" ]; then
        notificationServer=$(replaceMailAuthProperty "$notificationServer")
      fi

      if [[ " ${existingNotificationServerNames[*]} " == *" $notificationServerName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            updateNotificationServer "$notificationServer" "$notificationServerName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createNotificationServer "$notificationServer" "$notificationServerName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(json -c '.[]' $inputFile)
  }
  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "Notification servers file not found: $inputFile"
  else
    count=$(json 'length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No notification servers to import"
  else
    importNotificationServers
  fi
  elapsed=$(formattedElapsedTime $startTime)
  info "\n------ ${icon}Notification servers imported in ${elapsed}: $count processed, $created created, $updated updated, $failed failed ------\n"
fi
############## /Notification servers

############## Datasources
resource="datasources"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Datasources ------"

  importDatasources() {
    log -n "Importing $count datasources from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)
    mapfile -t existingDatasourceNames < <(run smListNames "datasources")
    verbose 1 "Existing DM datasources:\n${existingDatasourceNames[*]}"
    created=0
    updated=0
    skipped=0
    failed=0

    createDatasource() {
      local datasource="$1"
      local datasourceName="$2"
      runWithSpinner smCreateOrUpdate "datasources" "$datasource" "$datasourceName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateDatasource() {
      local datasource="$1"
      local datasourceName="$2"
      runWithSpinner smCreateOrUpdate "datasources" "$datasource" "$datasourceName"
      if [ $? -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    }

    local defaultPassword='{ "type": "secret-private", "value": "Change me" }'
    while IFS= read -r datasource; do
      datasourceName=$(echo "$datasource" | json -r '.name')
      datasourceDataLocation=${datasourceDataLocationMap["$datasourceName"]}
      # set password to $defaultPassword if empty or missing
      datasourcePassword=$(echo "$datasource" | json -r '.password // empty')
      if [ -z "$datasourcePassword" ] || [ "$datasourcePassword" = "null" ]; then
        datasource=$(json --argjson pwd "$defaultPassword" '.password = $pwd' <<<"$datasource")
      fi
      if [ -z "$datasourceDataLocation" ]; then
        warn -n "\n - '$datasourceName' skipped (not used by a data location in $dataLocationsFile)"
        skipped=$((skipped+1))
        continue
      fi
      log -n "\n - '$datasourceName' (data location '$datasourceDataLocation')"

      if [[ " ${existingDatasourceNames[*]} " == *" $datasourceName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateDatasource "$datasource" "$datasourceName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createDatasource "$datasource" "$datasourceName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(json -c '.[]' $inputFile)
    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Datasources imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }
  if [ "$selfHosted" != true ]; then
    warn "Datasources can only be imported for self-hosted installations, skipping"
  else
    count=0
    inputFile="$repoWorkspaceDir/$resource.json"
    if [ ! -f "$inputFile" ]; then
      warn "Datasources file not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi
    if [ $count -eq 0 ]; then
      warn "No datasources to import"
    else
      importDatasources
    fi
  fi
fi
############## /Datasources

############## Sequences
resource="sequences"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Sequences ------"

  importSequences() {
    sequenceNames=$(json -r 'keys | join(", ")' "$inputFile")
    log -n "Importing $count sequences ($sequenceNames) from $inputFile"
    # start calculating elapsed time
    startTime=$(date +%s)

    sequenceUrl="$dmRestUrl/internal/sequences"

    runWithSpinner http PUT ${sequenceUrl} \
                    -H "Authorization: Bearer $(smToken)" \
                    -H "Content-Type: application/json" \
                    -d @"$inputFile"

    if [ $? -eq 0 ]; then
      updated=$count
    else
      failed=$count
    fi

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Sequences imported in ${elapsed}: $count processed, $updated updated, $failed failed ------\n"
  }
  count=0
  inputFile="$repoWorkspaceDir/$resource.json"
  if [ ! -f "$inputFile" ]; then
    warn "Sequences file not found: $inputFile"
  else
    count=$(json 'keys | length' "$inputFile")
  fi
  if [ $count -eq 0 ]; then
    warn "No sequences to import"
  else
    importSequences
  fi
fi
############## /Sequences

############## Dashboards
resource="dashboards"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Dashboards ------"
  importDashboards() {
    log -n "Importing $count dashboards from $dashboardWorkspace"
    # start calculating elapsed time
    startTime=$(date +%s)
    mapfile -t existingDashboardNames < <(run smListNames "dashboards applications")
    verbose 1 "Existing DM dashboards:\n${existingDashboardNames[*]}"

    created=0
    updated=0
    skipped=0
    failed=0

    createDashboard() {
      local dashboardName="$1"
      runWithSpinner smImportDashboard "$inputFile" "$dashboardName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        created=$((created+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }

    updateDashboard() {
      local dashboardName="$1"
      runWithSpinner smImportDashboard "$inputFile" "$dashboardName"
      exitCode=$?
      if [ $exitCode -eq 0 ]; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
      return $exitCode
    }
    # for each file in dashboardWorkspace ending with .zip
    while
    IFS= read -r -d '' inputFile; do
      # dashboardName is extracted from the zip file name
      dashboardName=$(basename "$inputFile" .zip)
      log -n "\n - '$dashboardName'"

      if [[ " ${existingDashboardNames[*]} " == *" $dashboardName "* ]]; then
        answer="$(confirmReplace)"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          updateDashboard "$dashboardName"
        else
          info "   skipped"
          skipped=$((skipped+1))
          continue
        fi
      else
        info -n " creating"
        createDashboard "$dashboardName"
        if [ $? -ne 0 ]; then
          continue
        fi
      fi
    done < <(find "$dashboardWorkspace" -type f -name "*.zip" -print0)
    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Dashboards imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
  }
  dashboardWorkspace="$workspace/$resource"
  # count number of .zip files in dashboardWorkspace
  count=$(find "$dashboardWorkspace" -type f -name "*.zip" | wc -l)
  if [ $count -eq 0 ]; then
    warn "No dashboards to import"
  else
    importDashboards
  fi
fi
############## /Dashboards

############## Translations
resource="translations"
if shouldImport "$resource"; then
  icon=$(getResourceIcon "$resource")
  info "\n------ ${icon}Translations ------"

  importTranslations() {
    log -n "Importing translations from $inputFile ($(fileSize "$inputFile"))"
    # start calculating elapsed time
    startTime=$(date +%s)
    failed=0
    created=0

    if [ "$splitTranslations" = true ]; then
      importUrl="$dmRestUrl/admin/$resource"

      # unzip inputFile to temp dir can create a zip file for each sub-folder
      tmpDir="$TMP_DIR/$resource"
      info -n "\nextracting to $tmpDir"
      runWithSpinner unzip -oq "$inputFile" -d "$tmpDir"
      cd "$tmpDir"

      # count number of sub folders in $TMP_DIR/$resource
      count=$(find "$TMP_DIR/$resource" -mindepth 1 -maxdepth 1 -type d | wc -l)
      index=1
      #for each sub folder in $TMP_DIR/$resource
      for subFolder in "$tmpDir"/*/; do
        folderStartTime=$(date +%s)
        subFolderName=$(basename "$subFolder")
        subFolderZip="$tmpDir/$subFolderName.zip"
        log -n "\n - '$subFolderName' translations ($index of $count)"
        # count number of files in subFolder
        fileCount=$(find "$subFolder" -type f | wc -l)
        info -n "\n   creating '$subFolderName.zip' with $fileCount files"
        runWithSpinner zip -rq "$subFolderZip" "$subFolderName"
        info -n " $(fileSize "$subFolderZip")"

        info -n "\n   calling $importUrl with $subFolderZip"
        runWithSpinner smImportTranslations "$subFolderZip"

        importExitCode=$?
        info -n "\n   '$subFolderName' translations imported in $(formattedElapsedTime $folderStartTime)"
        if [ $importExitCode -ne 0 ]; then
          failed=$((failed+1))
        else
          created=$((created+1))
        fi
        index=$((index+1))
      done
      cd - >/dev/null
    else
      warn -n "\nImporting all translations in a single request (retry with --split-translations option if it fails)"
      runWithSpinner smImportTranslations "$inputFile"
      if [ $? -eq 0 ]; then
        created=1
      else
        failed=1
      fi
    fi

    elapsed=$(formattedElapsedTime $startTime)
    info "\n------ ${icon}Translations imported in ${elapsed}: $count processed, $created imported, $failed failed ------\n"
  }
  inputFile="$repoWorkspaceDir/$resource.zip"
  if [ ! -f "$inputFile" ]; then
    warn "Translations file not found: $inputFile"
  else
    count=1
    importTranslations
  fi
fi
############## /Translations


#######  Data location resources

shouldImportDataLocationResource=false
for resource in "${DATA_LOCATION_RESOURCES[@]}"; do
  if shouldImport "$resource"; then
    shouldImportDataLocationResource=true
    break
  fi
done

if [ "$shouldImportDataLocationResource" = false ]; then
  allDone
fi

declare -A targetDataLocationUuidMap
dlocIcon=$(getResourceIcon "dataLocations")
log -n "${icon}Getting current DM data locations"
existingDataLocations="$(smGetJson "dataLocations" | json -r '.[].name' || die "Failed to get existing data locations")"
mapfile -t existingDataLocationArray <<<"$existingDataLocations"
log "\n${icon}Checking data locations to import (existing in target: ${existingDataLocationArray[*]}):"
# exit script or remove data locations from dataLocationArray that are not in existingDataLocationArray
for i in "${!dataLocationArray[@]}"; do
  dataLocation="${dataLocationArray[$i]}"
  log -n " - $dataLocation"
  if [[ ! " ${existingDataLocationArray[*]} " =~ " $dataLocation " ]]; then
    if [[ "$ignoreMissingDlocs" == true ]]; then
      warn " ⚠️$ICON_PADDING skipped (does not exist in target DM platform, but ignoring missing data locations)"
      unset 'dataLocationArray[i]'
      continue
    else
      error " ⛔️$ICON_PADDING data location '$dataLocation' does not exist in the target DM platform. Retry with --ignore-missing-dlocs to skip missing data locations."
      exit 1
    fi
  else
    targetDataLocationUuid=$(smGetDataLocationUuid "$dataLocation")
    targetDataLocationUuidMap["$dataLocation"]="$targetDataLocationUuid"

    log " ✔️${ICON_PADDING} id: $targetDataLocationUuid"
  fi
done

if [ ${#dataLocationArray[@]} -eq 0 ]; then
  warn "No valid data locations found, skipping resources: ${DATA_LOCATION_RESOURCES[*]}"

  log "\n✔️${ICON_PADDING} All done!"
  exit 0
fi
for dataLocation in "${dataLocationArray[@]}"; do
  dlocDir="$dataLocationWorkspaceDir/$dataLocation"
  dlocTmpDir="$TMP_DIR/$dataLocation"
  mkdir -p "$dlocTmpDir"
  dlocStartTime=$(date +%s)
  oldDataLocationUuid="${sourceDataLocationUuidMap["$dataLocation"]}"
  newDataLocationUuid="${targetDataLocationUuidMap["$dataLocation"]}"
  info "\n============= ${dlocIcon}$dataLocation ============="

  ############## Notification policies
  resource="notificationPolicies"
  if shouldImport "$resource"; then
    icon=$(getResourceIcon "$resource")
    info "\n------ ${icon}Notification policies ------"
    startTime=$(date +%s)

    importNotificationPolicies() {
      log -n "Importing $count notification policies from $inputFile"
      # start calculating elapsed time
      startTime=$(date +%s)

      mapfile -t existingNotificationPolicyNames < <(run smListNames "notification-policies" "$dataLocation")
      verbose 1 "Existing DM notification policies:\n${existingNotificationPolicyNames[*]}"

      created=0
      updated=0
      skipped=0
      failed=0

      createNotificationPolicy() {
        local notificationPolicy="$1"
        local notificationPolicyName="$2"
        runWithSpinner smCreateOrUpdate "notification-policies" "$notificationPolicy" "$notificationPolicyName" "$dataLocation"
        exitCode=$?
        if [ $exitCode -eq 0 ]; then
          created=$((created+1))
        else
          failed=$((failed+1))
        fi
        return $exitCode
      }

      updateNotificationPolicy() {
        local notificationPolicy="$1"
        local notificationPolicyName="$2"
        runWithSpinner smCreateOrUpdate "notification-policies" "$notificationPolicy" "$notificationPolicyName" "$dataLocation"
        if [ $? -eq 0 ]; then
          updated=$((updated+1))
        else
          failed=$((failed+1))
        fi
      }

      while IFS= read -r notificationPolicy; do
        notificationPolicyName=$(echo "$notificationPolicy" | json -r '.name')
        log -n "\n - '$notificationPolicyName'"

        if [[ " ${existingNotificationPolicyNames[*]} " == *" $notificationPolicyName "* ]]; then
          answer="$(confirmReplace)"
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            updateNotificationPolicy "$notificationPolicy" "$notificationPolicyName"
          else
            info "   skipped"
            skipped=$((skipped+1))
            continue
          fi
        else
          info -n " creating"
          createNotificationPolicy "$notificationPolicy" "$notificationPolicyName"
          if [ $? -ne 0 ]; then
            continue
          fi
        fi
      done < <(json -c '.[]' $inputFile)
      elapsed=$(formattedElapsedTime $dlocStartTime)
      info "\n------ ${icon}${dataLocation} notification policies imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
    }
    count=0
    inputFile="$dlocDir/$resource.json"
    if [ ! -f "$inputFile" ]; then
      warn "${dataLocation} notification policies file not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi
    if [ $count -eq 0 ]; then
      warn "No ${dataLocation} notification policies to import"
    else
      importNotificationPolicies "$dataLocation"
    fi
  fi
  ############## /Notification policies

  ############## Continuous loads
  resource="continuousLoads"
  if shouldImport "$resource"; then
    icon=$(getResourceIcon "$resource")
    info "\n------ ${icon}Continuous loads ------"

    importContinuousLoads() {
      log -n "Importing $count continuous loads from $inputFile"
      # start calculating elapsed time
      startTime=$(date +%s)

      mapfile -t existingContinuousLoadNames < <(run smListNames "continuous-loads" "$dataLocation")
      verbose 1 "Existing DM continuous loads:\n${existingContinuousLoadNames[*]}"

      created=0
      updated=0
      skipped=0
      failed=0

      createContinuousLoad() {
        local continuousLoad="$1"
        local continuousLoadName="$2"
        runWithSpinner smCreateOrUpdate "continuous-loads" "$continuousLoad" "$continuousLoadName" "$dataLocation"
        exitCode=$?
        if [ $exitCode -eq 0 ]; then
          created=$((created+1))
        else
          failed=$((failed+1))
        fi
        return $exitCode
      }

      updateContinuousLoad() {
        local continuousLoad="$1"
        local continuousLoadName="$2"
        runWithSpinner smCreateOrUpdate "continuous-loads" "$continuousLoad" "$continuousLoadName" "$dataLocation"
        if [ $? -eq 0 ]; then
          updated=$((updated+1))
        else
          failed=$((failed+1))
        fi
      }

      while IFS= read -r continuousLoad; do
        continuousLoadName=$(echo "$continuousLoad" | json -r '.name')
        log -n "\n - '$continuousLoadName'"

        if [[ " ${existingContinuousLoadNames[*]} " == *" $continuousLoadName "* ]]; then
          answer="$(confirmReplace)"
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            updateContinuousLoad "$continuousLoad" "$continuousLoadName"
          else
            info "   skipped"
            skipped=$((skipped+1))
            continue
          fi
        else
          info -n " creating"
          createContinuousLoad "$continuousLoad" "$continuousLoadName"
          if [ $? -ne 0 ]; then
            continue
          fi
        fi
      done < <(json -c '.[]' $inputFile)
      elapsed=$(formattedElapsedTime $dlocStartTime)
      info "\n------ ${icon}${dataLocation} continuous loads imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed ------\n"
    }
    count=0
    inputFile="$dlocDir/$resource.json"
    if [ ! -f "$inputFile" ]; then
      warn "${dataLocation} continuous loads file not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi
    if [ $count -eq 0 ]; then
      warn "No ${dataLocation} continuous loads to import"
    else
      importContinuousLoads "$dataLocation"
    fi
  fi
  ############## /Continuous loads

  ############## Purge schedules
  resource="purgeSchedule"
  if shouldImport "$resource"; then
    icon=$(getResourceIcon "$resource")
    info "\n------ ${icon}Purge schedules ------"
    startTime=$(date +%s)

    importPurgeSchedule() {
      dataLocation="$1"
      log -n "Importing purge schedule from $inputFile"
      # start calculating elapsed time
      startTime=$(date +%s)

      local purgeSchedule=$(json . "$inputFile")
      if [ -z "$purgeSchedule" ] || [ "$purgeSchedule" = "null" ]; then
        warn "No purge schedule to import"
        return
      fi
      runWithSpinner smCreateOrUpdate "purge-schedule" "$purgeSchedule" "" "$dataLocation"
      if [ $? -eq 0 ]; then
        updated=1
      else
        failed=1
      fi
      elapsed=$(formattedElapsedTime $dlocStartTime)
      info "\n------ ${icon}${dataLocation} purge schedule imported in ${elapsed}: 1 processed, $updated updated, $failed failed ------\n"
    }
    count=0
    inputFile="$dlocDir/$resource.json"
    if [ ! -f "$inputFile" ]; then
      warn "${dataLocation} purge schedule file not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi
    if [ $count -eq 0 ]; then
      warn "No ${dataLocation} purge schedule to import"
    else
      importPurgeSchedule "$dataLocation"
    fi
  fi
  ############### /Purge schedules

  ############## Data notifications
  resource="dataNotifications"
  if shouldImport "$resource"; then
    icon=$(getResourceIcon "$resource")
    info "\n------ ${icon}Data notifications ------"
    startTime=$(date +%s)

    importDataNotifications() {
      log -n "Importing $count data notifications from $inputFile"
      saasTargetTypes=(REST)
      if [ "$selfHosted" != true ]; then
        warn -n "\nOnly '${saasTargetTypes[*]}' target types are supported for SaaS."
      fi
      # start calculating elapsed time
      startTime=$(date +%s)

      mapfile -t existingDataNotificationNames < <(run smListNames "data-notifications" "$dataLocation")
      verbose 1 "Existing DM data notifications:\n${existingDataNotificationNames[*]}"

      created=0
      updated=0
      skipped=0
      failed=0

      createDataNotification() {
        local dataNotification="$1"
        local dataNotificationName="$2"
        runWithSpinner smCreateOrUpdate "data-notifications" "$dataNotification" "$dataNotificationName" "$dataLocation"
        exitCode=$?
        if [ $exitCode -eq 0 ]; then
          created=$((created+1))
        else
          failed=$((failed+1))
        fi
        return $exitCode
      }

      updateDataNotification() {
        local dataNotification="$1"
        local dataNotificationName="$2"
        runWithSpinner smCreateOrUpdate "data-notifications" "$dataNotification" "$dataNotificationName" "$dataLocation"
        if [ $? -eq 0 ]; then
          updated=$((updated+1))
        else
          failed=$((failed+1))
        fi
      }

      while IFS= read -r dataNotification; do
        dataNotificationName=$(echo "$dataNotification" | json -r '.name')
        targetType=$(echo "$dataNotification" | json -r '.targetType')
        log -n "\n - '$dataNotificationName' $targetType target type"
        if [ "$selfHosted" != true ] && [[ ! " ${saasTargetTypes[*]} " =~ " $targetType " ]]; then
          warn -n " skipped (unsupported target type)"
          skipped=$((skipped+1))
          continue
        fi

        if [[ " ${existingDataNotificationNames[*]} " == *" $dataNotificationName "* ]]; then
          answer="$(confirmReplace)"
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            updateDataNotification "$dataNotification" "$dataNotificationName"
          else
            info "   skipped"
            skipped=$((skipped+1))
            continue
          fi
        else
          info -n " creating"
          createDataNotification "$dataNotification" "$dataNotificationName"
          if [ $? -ne 0 ]; then
            continue
          fi
        fi
      done < <(json -c '.[]' $inputFile)
      elapsed=$(formattedElapsedTime $dlocStartTime)
      info "\n------ ${icon}${dataLocation} data notifications imported in ${elapsed}: $count processed, $created created, $updated updated, $skipped skipped, $failed failed -----"
    }
    count=0
    inputFile="$dlocDir/$resource.json"
    if [ ! -f "$inputFile" ]; then
      warn "${dataLocation} data notifications file not found: $inputFile"
    else
      count=$(json 'length' "$inputFile")
    fi
    if [ $count -eq 0 ]; then
      warn "No ${dataLocation} data notifications to import"
    else
      importDataNotifications "$dataLocation"
    fi
  fi
  ############## /Data notifications

  importIntegData() {
    label="$1"
    label=$(echo "$label" | sed -E 's/(^| )[a-z]/\U\0/g')
    icon=$(getResourceIcon "$resource")
    info "\n------ ${icon}$label ------"

    replaceDataLocationUuid() {
      local inputFilename="$(basename $inputFile)"
      local base="${resource}"
      local outputFilename="${base}-${newDataLocationUuid}.csv"
      local outputFile="$dlocDir/$outputFilename"

      info -n "Creating $outputFilename with target data location UUID"
      # sed inputFile to outputFile and gzip it
      runWithSpinner $(zcat "$inputFile" | sed "s/$oldDataLocationUuid/$newDataLocationUuid/ig" > "$outputFile" && gzip -f "$outputFile")
      info ""
    }

    doImport() {
      log -n "Importing $count $label from $inputFile"
      # start calculating elapsed time
      startTime=$(date +%s)

      created=0
      failed=0

      # lowercase label with space replaced by hyphen
      resourceUrl=$(echo "$label" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      importUrl="$dmRestUrl/internal/$resourceUrl?dataLocation=$dataLocation"

      info -n "\n   - calling $importUrl"
      runWithSpinner http POST ${importUrl} \
                      -H "Authorization: Bearer $(smToken)" \
                      -H "Content-Type:multipart/form-data" \
                      -F "file=@$inputFile"
      importExitCode=$?
      if [ $importExitCode -ne 0 ]; then
        failed="$count"
      else
        created="$count"
      fi

      elapsed=$(formattedElapsedTime $startTime)
      info "\n------ ${icon}$label imported in ${elapsed}: $count processed, $created imported, $failed failed ------\n"
    }
    count=0
    inputFile="$dlocDir/$resource.csv.gz"
    inputFileWithUuid="$dlocDir/${resource}-${newDataLocationUuid}.csv.gz"
    if [ ! -f "$inputFile" ] && [ ! -f "$inputFileWithUuid" ]; then
      die "$label file not found: $inputFile or $inputFileWithUuid"
    fi

    if [ ! -f "$inputFileWithUuid" ]; then
      replaceDataLocationUuid
    fi
    inputFile="$inputFileWithUuid"
    count=$(zcat "$inputFile" | grep -c "$newDataLocationUuid" || :)

    if [ $count -gt 0 ]; then
      doImport
    else
      warn "No ${dataLocation} $label to import"
    fi
  }

  ############## Integration Batches
  resource="integBatches"
  if shouldImport "$resource"; then
    importIntegData "integration batches"
  fi
  ############## /Integration Batches

  ############## Integration Loads
  resource="integLoads"
  if shouldImport "$resource"; then
    importIntegData "integration loads"
  fi
  ############## /Integration batches

  dlocElapsed=$(formattedElapsedTime $dlocStartTime)
  info "============= ${dlocIcon}$dataLocation resources imported in ${dlocElapsed} ============="

done


#######  /Data location resources

allDone
