#!/usr/bin/env bash
set -eo pipefail
trap 'onExit $?;' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BOLD="$(tput bold 2>&- || :)"
CYAN=$(tput setaf 6)
ORANGE=$(tput setaf 3)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
RESET=$(tput sgr0)

SPINNER_FRAMES=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
SPINNER_ENABLED=true
ICONS_ENABLED=true

#if linux os then add icon padding (for multiple character icons)
if [[ "$(uname -s)" == "Linux" ]]; then
  ICON_PADDING=" "
fi

DEFAULT_URL="http://localhost:8088/semarchy"
DEFAULT_WORKSPACE="./exportWorkspace"

DEFAULT_REPO_HOST="localhost"
DEFAULT_REPO_PORT="15432"
DEFAULT_REPO_USERNAME="semarchy_repository"
DEFAULT_REPO_PASSWORD="semarchy_repository"
DEFAULT_SEQUENCE_INCREMENT=1000

# Keycloak user name regex pattern (prohibits special characters: < > & " ' white space $ % ! # ? § , ; : * ~ / \ | ^ = [ ] { } ( ) and control characters)
KEYCLOAK_USERNAME_PATTERN='^[^<>&"'\''[:space:]$%!#?§,;:*~/\\|^=\[\]{}()`[:cntrl:]]+$'
# Keycloak first/last name regex pattern (prohibits special characters: < > & " ' $ % ! # ? § , ; : * ~ / \ | ^ = [ ] { } ( ) and control characters)
KEYCLOAK_FIRST_LAST_NAME_PATTERN='^[^<>&"'\''$%!#?§,;:*~/\\|^=\[\]{}()`[:cntrl:]]+$'

BUILTIN_ROLES=(semarchyAdmin semarchyConnect)
declare -A XDM_PRIVILEGE_SUBSTITUTION=(
  [PLATFORM_ADMIN]=MODULE_ADMIN
)
PLATFORM_ROLE_GRANT_PRIVILEGES=(APP_MANAGEMENT REPOSITORY_INFO USER_MANAGEMENT DASHBOARD_DESIGN ROLE_MANAGEMENT DASHBOARD_MANAGEMENT SYSTEM_ADMIN MODULE_ADMIN APP_DESIGN)
PLATFORM_PROPERTIES=(CSVExportLimit ExcelExportLimit AutoCompleteLimit FaviconUrl ServerBaseUrl )
SEQUENCES=(batchId dataNotifLogId loadId revision)

SUPPORTED_XDM_VERSIONS=("2024.1" "2025.1")

CHANGE_ME_PASSWORD='{ "type": "secret-shared", "vaultName": "Not a vault", "secretName": "Change me", "secretProperty": "Change me" }'

NOOP="NoOp"

VERBOSE=0

PROG_ARGS=( "$@" )

help()
{
    info "_______ Export xDM _______
This script exports xDM Repository data from xDM using the REST API.

Usage: $(basename "$0") [resource1 resource2 ...] [-h] [-v] [-y] [-a <apiKey>] [-u <xdmUrl>] [-w <workspaceDir>] [--data-locations <dloc1,dloc2,...>] [--repository-host <host>] [--repository-port <port>] [--repository-username <username>] [--repository-password <password>] [-p] [--overwrite]
Arguments:
        $(bold "[resource1 resource2 ...]   :") Resources to export (e.g. datasources users notificationPolicies). Default: all resources
        $(bold "--api-key -a                :") xDM API key. Default: XDM_API_KEY env value
        $(bold "--url -u                    :") xDM Base URL. Default: $DEFAULT_URL
        $(bold "--workspace -w              :") Workspace directory for exported data. Default: $DEFAULT_WORKSPACE
        $(bold "--data-locations            :") Comma-separated list of data locations optionally paired with uuids  to export (all data locations are exported if not specified).
        $(bold "                             ") Example: dloc1:uuid1,dloc2:uuid2
        $(bold "--repository-host -host     :") Repository host (Required for data not available via Public REST API). Default: $DEFAULT_REPO_HOST
        $(bold "--repository-port -port     :") Repository port (Required for data not available via Public REST API). Default: $DEFAULT_REPO_PORT
        $(bold "--repository-username -user :") Repository username (Required for data not available via Public REST API). Default: $DEFAULT_REPO_USERNAME
        $(bold "--repository-password -pwd  :") Repository password (Required for data not available via Public REST API): XDM_REPO_PWD env value
        $(bold "--sequence-increment        :") Increment values for sequences export. Default: $DEFAULT_SEQUENCE_INCREMENT. Can be a comma-seperated list of <sequence name>:<increment>
        $(bold "                             ") Example (full): batchId:1000,dataNotifLogId:100,loadId:5000,revision:10
        $(bold "--pretty -p                 :") Pretty print JSON output files. Default: compact
        $(bold "--overwrite                 :") Overwrite existing files in workspace. Default: asks for confirmation if file exists.
        $(bold "--no-spinner                :") Disable wait spinner.
        $(bold "--no-icons                  :") Disable icons.
        $(bold "--no-colors                 :") Disable text colors.
        $(bold "--keep-secrets              :") Do not replace secrets in exported data
        $(bold "                             ") By default: secrets replaced with $(jq -Cc . <<< $CHANGE_ME_PASSWORD)
        $(bold "--ignore-version-check      :") Ignore xDM version check.
        $(bold "--skip                      :") Comma-separated list of resources to skip export.
        $(bold "-v                          :") Verbose mode in ${GREEN}green${RESET} (-vv for more verbosity)
        $(bold "-x                          :") Debug mode (same as bash +x)
        $(bold "-y                          :") Automatically answer 'yes' to all prompts.
        $(bold "--help -h                   :") Show this help message and exit.

Required external commands:
    - curl for http calls
    - jq for JSON processing
    - getopt for argument parsing
    - psql (PostgreSQL sequences export)
    - sqlplus (Oracle sequences export)
    - sqlcmd (SQL Server sequences export)

Examples
  Export all xDM repository resources to folder $DEFAULT_WORKSPACE
      $(basename "$0") -a 'myApiKey' -u 'https://myXdmHost.com'
  Export users and roles from xDM repository to folder ./myWorkspace (using API Key env variable)
      XDM_API_KEY='myApiKey' $(basename "$0") users roles --url 'https://myXdmHost.com' --workspace ./myWorkspace
"
    exit 2
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

die() {
  set -eo pipefail
  error "$*"
  exit 1
}

available() { # cmd ...
  for cmd in "$@"; do
    >/dev/null 2>&1 type "$cmd" || die "$cmd: command required by this script, you must install it"
  done
}

available curl jq getopt gzip

json() {
  local jqOptions=( "$@" )
  jq "${jqOptions[@]}" | sed 's/\r$//'
}

run() { # command
  local command=( "$@" )
  verbose 1 ">>> ${command[*]}"
  "${command[@]}"
  if [ $? -ne 0 ]; then
    die "Command failed: ${command[*]}"
  fi
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
  printf "  " >&2
  i=0
  framesCount=${#SPINNER_FRAMES[@]}
  if (( VERBOSE > 1 )); then
    # wait a second
    sleep 1
  fi
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %framesCount ))
    printf "\b${CYAN}%s${RESET}" "${SPINNER_FRAMES[$i]}" >&2
    sleep 0.1
  done
  tput cnorm
  wait $pid
  exitCode=$?
  if [ $exitCode -eq 0 ]; then
    printf "\b✔️${ICON_PADDING} " >&2
  else
    set -eo pipefail
  fi
  return $exitCode
}

replaceSecrets() {
  local resource="$1"
  local inputFile="$2"
  if [ ! -f "$inputFile" ]; then
    return
  fi
  local secretsFile="${inputFile%.json}.secrets"
  json -r '
    def find_secrets(path_so_far):
      if type == "object" then
        if .type == "secret-internal" then
                [ (path_so_far | join(".")) + " (internal)" ]
        elif .type == "secret-external" then
          [ (path_so_far | join(".")) + " (external): " + (with_entries(select(.key != "type")) | tojson) ]
        else
          [to_entries[] | . as $e | ($e.value | find_secrets(path_so_far + [$e.key]))] | add
        end
      elif type == "array" then
        [to_entries[] | . as $e | ($e.value | find_secrets(path_so_far + [($e.key|tostring)]))] | add
      else
        []
      end;

    .[] |
    . as $item |
    find_secrets(["[name: \($item.name // "unknown")]" ])
    | .[]
  ' "$inputFile" > $secretsFile

  if [ -s "$secretsFile" ]; then
    if [ "$keepSecrets" != "true" ]; then
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
      ' "$inputFile" > "${inputFile}.tmp" && mv "${inputFile}.tmp" "$inputFile"
      andRemoved=" and removed"
    fi

    local secretCount=$(wc -l < "$secretsFile")
    warn "  $secretCount secret(s) found$andRemoved in $resource (paths exported to $secretsFile):"
    while IFS= read -r line; do
      warn "  - $line"
    done < "$secretsFile"
  else
    rm -f "$secretsFile"
  fi
}

httpStatus() {
  local httpStatus="$1"
  local url="$2"
  local httpBody="$3"
  errorResponse=""
  if [[ -n "$httpBody" ]]; then
    errorResponse="\nHTTP Response: $httpBody"
  fi
  failed() {
    error "\b❌\nHTTP request failed: $1 ($httpStatus) (url: $url)$errorResponse"
    return 1
  }
  case "$httpStatus" in
    2*|3*) return 0 ;;
    401) failed "Unauthorized access" ;;
    403) failed "Forbidden" ;;
    404) failed "Not found" ;;
    409) failed "Conflict" ;;
    4*) failed "Client error" ;;
    5*) failed "Server error" ;;
    *) failed "Unexpected status" ;;
  esac
}

verbose() { # level message
  local level="$1" message="$2"
  (($# == 1)) && message=$(cat)
  if (( level <= VERBOSE )); then
      >&2 echo -e "\n${GREEN}$message";
  fi
}

httpCheckStatus() {
  local httpStatus="$1"
  local url="$2"
  local httpBody="$3"
  errorResponse=""
  if [[ -n "$httpBody" ]]; then
    errorResponse="\nHTTP Response: $httpBody"
  fi
  failed() {
    error "\b❌\nHTTP request failed: $1 ($httpStatus) (url: $url)$errorResponse"
    return 1
  }
  case "$httpStatus" in
    2*|3*) return 0 ;;
    401) failed "Unauthorized access" ;;
    403) failed "Forbidden" ;;
    404) failed "Not found" ;;
    409) failed "Conflict" ;;
    4*) failed "Client error" ;;
    5*) failed "Server error" ;;
    *) failed "Unexpected status" ;;
  esac
}

http() {
  local url="$1"
  local outputFile="$2"
  local curl="curl -s"
  (( VERBOSE > 1 )) && curl="curl -v"
  verbose 1 "$curl -w \" - %{http_code}\" -H \"API-Key: $apiKey\" \"$url\""

  local response
  if [[ -n "$outputFile" ]]; then
    verbose 1 "File output: $outputFile"
    response="$($curl -w " - %{http_code}" -H "API-Key: $apiKey" "$url" -o "$outputFile")"
    httpStatus="${response#* - }"
    httpCheckStatus  "$httpStatus" "$url"
    exitCode=$?
    if [[ $exitCode -ne 0 ]]; then
      return $exitCode
    fi
  else
    verbose 1 "Std output"
    response="$($curl -w " - %{http_code}" -H "API-Key: $apiKey" "$url")"
    httpBody="${response% - *}"
    httpStatus="${response#* - }"
    httpCheckStatus "$httpStatus" "$url" "$httpBody"
    exitCode=$?
    echo -n "$httpBody"
  fi
  return $exitCode
}

shouldOverwriteFile() {
  local outputFile="$1"
  if [ -f "$outputFile" ] && [ -z "$overwrite" ]; then
    if [ "$alwaysYes" == "1" ]; then
      info -n " already exists, replacing"
      return 0
    fi
    warn -n " file already exists, do you want to replace it? (y/N)"
    read reply < /dev/tty
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      log "skipped!"
      return 1
    fi
  fi
  return 0
}

fileSize() {
  local file="$1"
  if [ -f "$file" ]; then
    du -h "$file" | cut -f1 2>/dev/null || wc -c < "$file"
  else
    echo "0"
  fi
}

httpGet() {
  local httpUrl="$1"
  local outputFile="$2"
  local resource="$3"
  local dloc="$4"
  # add space to dloc if not empty
  [ -n "$dloc" ] && dloc=" for $dloc"

  local startTime=$(date +%s)
  local dir="$(dirname "$outputFile")"
  if [[ ! -d "$dir" ]]; then
    info "\nCreated workspace directory $dir"
    mkdir -p "$dir"
  fi

  local icon=$(getResourceIcon "$resource")
  local tmpOutputFile="$outputFile.tmp"
  local response
  if [ -z "$httpUrl" ]; then
    die "No URL provided to http"
  fi
  if [ -z "$outputFile" ]; then
    echo "$(http "$httpUrl")"
    return
  fi
  log -n "${icon}Exporting $resource$dloc"
  if ! shouldOverwriteFile "$outputFile"; then
    return
  fi
  runWithSpinner http "$httpUrl" "$outputFile"
  exitCode=$?
  if [ $exitCode -ne 0 ]; then
    rm -rf "$outputFile"
    return $exitCode
  fi
  countMessage=""
  local size=$(fileSize "$outputFile")
  if [[ "$outputFile" == *.json ]]; then
    if [[ "$pretty" == "1" ]]; then
      json '.' "$outputFile" > "$tmpOutputFile" && mv "$tmpOutputFile" "$outputFile"
    fi
    verbose 1 "$outputFile"
    # if $outputFile is array count items or else just say 1 item
    count=$(json 'if type=="array" then length else 1 end' "$outputFile" 2>/dev/null || echo "0")
    item="items"
    [ "$count" -eq 1 ] && item="item"
    log "$count $item in $(formattedElapsedTime $startTime) ($size)"
    replaceSecrets "$resource" "$outputFile"
  else
    log "$(basename $outputFile) in $(formattedElapsedTime $startTime) ($size)"
  fi
}

checkXdmStatus() {
  # Skip status check for resources that do not require xDM to be started
  if [ "$resource" == "sequences" ] || [ "$resource" == "integBatches" ] || [ "$resource" == "integLoads" ]; then
    return 0
  fi
  if [ "$ICONS_ENABLED" == true ]; then
    log -n "🔍 "
  fi
  log -n "Checking xDM status"
  set +e
  runWithSpinner http "$url/api/rest/probes/started"
  if [ $? -ne 0 ]; then
    die "\b❌xDM is not started or not reachable at $url"
  fi
  echo ""
}

shouldExport() {
  local icon=$(getResourceIcon "$1")
  local resource="$1"
  if ([[ -z "$resources" ]] || [[ ",${resourceArray[*],,}," == *"${resource,,}"* ]]) && \
      ([[ -z "$skipResources" ]] || [[ ! ",${skipResourceArray[*],,}," == *"${resource,,}"* ]]); then
    return 0
  else
    [[ "$showSkipped" == true] && ["$disableLogSkipped" != true ]] && info "skipped ${icon}$resource"
    return 1
  fi
}

cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null

SHORT=a:,u:,w:,p,v,x,y,h
LONG=api-key:,url:,workspace:,data-locations:,repository-host:,repository-port:,repository-username:,repository-password:,sequence-increment:,\
overwrite,no-spinner,no-icons,no-colors,keep-secrets,ignore-version-check,skip:,pretty,help
OPTS=$(getopt -a -n "$(basename "$0")" --options $SHORT --longoptions $LONG -- "$@")

apiKey=$XDM_API_KEY
workspace="$DEFAULT_WORKSPACE"
url="$DEFAULT_URL"

repositoryHost="$DEFAULT_REPO_HOST"
repositoryPort="$DEFAULT_REPO_PORT"
repositoryUsername="$DEFAULT_REPO_USERNAME"
repositoryPassword="$XDM_REPO_PWD"
sequenceIncrement=$DEFAULT_SEQUENCE_INCREMENT

eval set -- "$OPTS"

resources=""
while :
do
  case "$1" in
    -a | --api-key)
      apiKey="$2"
      shift 2
      ;;
    -u | --url)
      url="$2"
      shift 2
      ;;
    -w | --workspace)
      workspace="$2"
      shift 2
      ;;
    --data-locations)
      declare -A dataLocationUuidMap
      for pair in ${2//,/ }; do
        dloc="${pair%%:*}"
        if [[ "$pair" == "$dloc" ]]; then
          # no uuid provided, set empty
          uuid=""
        else
          uuid="${pair#*:}"
          # check uuid is valid uuid format
          if ! [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            die "Invalid UUID format for data location '$dloc': '$uuid'"
          fi
        fi
        dataLocationUuidMap["$dloc"]="$uuid"
        dataLocations="${dataLocations}${dataLocations:+,}$dloc"
      done
      shift 2
      ;;
    --repository-host)
      repositoryHost="$2"
      shift 2
      ;;
    --repository-port)
      repositoryPort="$2"
      shift 2
      ;;
    --repository-username)
      repositoryUsername="$2"
      shift 2
      ;;
    --repository-password)
      repositoryPassword="$2"
      shift 2
      ;;
    --sequence-increment)
      sequenceIncrement="$2"
      if [[ "$sequenceIncrement" == *,* ]]; then
        # parse comma-seperated list of <sequence name>:<increment>
        declare -A sequenceIncrementMap
        for pair in ${sequenceIncrement//,/ }; do
          seqName="${pair%%:*}"
          increment="${pair#*:}"
          if ! [[ "$increment" =~ ^[0-9]+$ ]]; then
            die "Invalid sequence increment value for sequence '$seqName': '$increment'"
          fi
          if [[ ! " ${SEQUENCES[*]} " =~ " ${seqName} " ]]; then
            die "Unknown sequence name: '$seqName'. Valid sequence names are: $(IFS=, ; echo "${SEQUENCES[*]}")"
          fi
          sequenceIncrementMap["$seqName"]="$increment"
        done
        sequenceIncrement=""
      fi
      shift 2
      ;;
    -p | --pretty)
      pretty=1
      shift
      ;;
    --overwrite)
      overwrite=1
      shift
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
    --keep-secrets)
      keepSecrets=true
      shift
      ;;
    --ignore-version-check)
      ignoreVersionCheck=true
      shift
      ;;
    --skip)
      skipResources="$2"
      IFS=',' read -ra skipResourceArray <<< "$skipResources"
      shift 2
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

if [ -z "$url" ]; then
  error "Error: xDM URL is required."
  echo ""
  help
else
  info "$(bold "xDM URL:") ${url}"
fi

if [ -z "$apiKey" ]; then
  error "Error: API key is required\nEither set XDM_API_KEY environment variable or use --api-key argument"
  echo ""
  help
else
  maskedApiKey="${apiKey:0:4}...${apiKey: -4}"
  info "$(bold "API Key:") $maskedApiKey"
fi

if [ ! -d "$workspace" ]; then
  mkdir -p "$workspace"
  info "$(bold "Workspace directory:") $workspace (Created)"
else
  info "$(bold "Workspace directory:") $workspace"
fi

repoWorkspaceDir="$workspace/repository"

if [ ! -d "$repoWorkspaceDir" ]; then
  mkdir -p "$repoWorkspaceDir"
  info "Created repository workspace directory"
fi

restUrl="$url/api/rest"
adminUrl="$restUrl/admin"
dataLocationsUrl="$restUrl/app-builder/data-locations"
dataLocationUrl="$dataLocationsUrl/{dloc-name}"

declare -A resourceConfig=(
  [repository]="📦|$adminUrl/repository|json"
  [users]="👪|$adminUrl/users|json|validateUsers"
  [roles]="🛡️${ICON_PADDING}|$adminUrl/roles|json|removeBuiltInRolesAndNonPlatformGrants"
  [notificationServers]="📧|$adminUrl/notification-servers|json|checkNotificationServers"
  [pluginBundles]="🔌|$adminUrl/plugin-bundles|json|checkPluginBundles"
  [imageLibraries]="🖼️${ICON_PADDING}|$adminUrl/image-libraries|json"
  [restClients]="🌐|$adminUrl/rest-clients|json"
  [variableProviders]="🔢|$adminUrl/variable-providers|json|checkVariableProviders"
  [translations]="🌍|$adminUrl/translations|zip"
  [apiKeys]="🔑|$adminUrl/api-keys|json"
  [datasources]="🛢️|$adminUrl/datasources|json"
  [properties]="⚙️${ICON_PADDING}|$adminUrl/properties|json|removeNonPlatformProperties"
  [dashboards]="📊|$restUrl/dashboard-builder/dashboard-applications|json"
  [notificationPolicies]="📣|$dataLocationUrl/notification-policies|json"
  [continuousLoads]="🔄|$dataLocationUrl/continuous-loads|json"
  [purgeSchedule]="🧹|$dataLocationUrl/purge-schedule|json"
  [dataNotifications]="🚨|$dataLocationUrl/data-notifications|json|checkDataNotifications"
  [sequences]="⏩|$NOOP"
  [dataLocations]="🗺️${ICON_PADDING}|$NOOP"
  [integBatches]="🗃️${ICON_PADDING}|$NOOP"
  [integLoads]="🚚|$NOOP"
)

getResourceName() {
  local resource="$1"
  # get string from resourceConfig with case insensitive key
  for key in "${!resourceConfig[@]}"; do
    if [[ "${key,,}" == "${resource,,}" ]]; then
      echo "$key"
      return
    fi
  done
}

getResourceConfig() {
  local resource="$1"
  # get string from resourceConfig with case insensitive key
  for key in "${!resourceConfig[@]}"; do
    if [[ "${key,,}" == "${resource,,}" ]]; then
      echo "${resourceConfig[$key]}"
      return
    fi
  done
}

getResourceIcon() {
  if [ "$ICONS_ENABLED" == false ]; then
    echo ""
    return
  fi
  local resource="$1"
  local config=$(getResourceConfig "$resource")
  echo "$(echo "$config" | cut -d'|' -f1) "
}

getResourceEndpoint() {
  local resource="$1"
  local config=$(getResourceConfig "$resource")
  echo "$config" | cut -d'|' -f2
}

getResourceOutputFilename() {
  local resource="$1"
  local config=$(getResourceConfig "$resource")
  fileExtension=$(echo "$config" | cut -d'|' -f3)
  if [ "$fileExtension" != "${resourceConfig[$resource]}" ]; then
    echo "$resource.$fileExtension"
  else
    echo "$resource.json"
  fi
}

getResourceEvalFunction() {
  local resource="$1"
  local config=$(getResourceConfig "$resource")
  echo "$config" | cut -d'|' -f4
}

mainStartTime=$(date +%s)

IFS=',' read -ra resourceArray <<< "$resources"
resources=""
for res in "${resourceArray[@]}"; do
  name=$(getResourceName "$res")
  config=$(getResourceConfig "$res")
  if [[ -z "$config" ]]; then
    error "Unknown export resource: $res"
    error "Available resources (case insensitive):"
    echo "$(IFS=, ; error "${!resourceConfig[*]}" | sed 's/,/, /g')"
    exit 1
  fi
  if [ -z "$resources" ]; then
    resources="$name"
  else
    resources="$resources,$name"
  fi
done
# reread resources into array (proper case)
IFS=',' read -ra resourceArray <<< "$resources"
info -n "$(bold "Data to export:") "
if [[ -n "$resources" ]]; then
    info "$resources"
else
    info -n "all"
    if [[ -n "$skipResources" ]]; then
      info " (except: $skipResources)"
    else
      info ""
    fi
fi

checkXdmStatus
if [[ $? -ne 0 ]]; then
  die "xDM does not seem to be started properly or is not reachable at $url"
  exit 1
fi

validateUsers() {
  local inputFile="$1"
  invalidUsersFile="$workspace/repository/users-invalid.json"
  validUsersFile="$workspace/repository/users-valid.json"
  # Extract valid users
  json --arg name_pattern "$KEYCLOAK_USERNAME_PATTERN" --arg firstLastName_pattern "$KEYCLOAK_FIRST_LAST_NAME_PATTERN" '
    [.[] | select(
        (.name | type == "string" and test($name_pattern))
        and (if has("firstName") and .firstName != null and .firstName != "" then (.firstName | type == "string" and test($firstLastName_pattern)) else true end)
        and (if has("lastName") and .lastName != null and .lastName != "" then (.lastName | type == "string" and test($firstLastName_pattern)) else true end)
        and has("email")
        and .name == .email
      )]
  ' "$inputFile" > "$validUsersFile"

  # Filter invalid users
  json --arg name_pattern "$KEYCLOAK_USERNAME_PATTERN" --arg firstLastName_pattern "$KEYCLOAK_FIRST_LAST_NAME_PATTERN" '
        [
          .[] |
          select(
            (.name | test($name_pattern)|not) or
            (has("firstName") and .firstName != null and .firstName != "" and (.firstName | test($firstLastName_pattern)|not)) or
            (has("lastName") and .lastName != null and .lastName != "" and (.lastName | test($firstLastName_pattern)|not)) or
            (has("email")|not) or
            (has("email") and .name != .email)
          )
          | . + {
                    issues: [
                      (if (.name | test($name_pattern)|not) then "name '\''" + .name + "'\'' contains prohibited character(s): " + ([.name | split("") | .[] | select(test($name_pattern)|not)] | unique | map("'\''" + . + "'\''") | join(", ")) else empty end),
                      (if has("firstName") and .firstName != null and .firstName != "" and (.firstName | test($firstLastName_pattern)|not) then "firstName '\''" + .firstName + "'\'' contains prohibited character(s): " + ([.firstName | split("") | .[] | select(test($firstLastName_pattern)|not)] | unique | map("'\''" + . + "'\''") | join(", ")) else empty end),
                      (if has("lastName") and .lastName != null and .lastName != "" and (.lastName | test($firstLastName_pattern)|not) then "lastName '\''" + .lastName + "'\'' contains prohibited character(s): " + ([.lastName | split("") | .[] | select(test($firstLastName_pattern)|not)] | unique | map("'\''" + . + "'\''") | join(", ")) else empty end),
                      (if has("email")|not then "Missing email" else empty end),
                      (if has("email") and .name != .email then "name '\''" + .name + "'\'' different from email '\''" + .email + "'\''" else empty end)
                    ]
                 }
        ]' $inputFile > "$invalidUsersFile"

  # Overwrite users.json with only valid users
  mv "$validUsersFile" "$inputFile"

  invalidCount=$(json 'length' $invalidUsersFile)
  if [ "$invalidCount" -gt 0 ]; then
    warn "  $invalidCount invalid user(s) found (removed and exported to $invalidUsersFile):"
    json -c '.[]' $invalidUsersFile | while read -r user; do
      userName=$(echo $user | json -r '.name // "<missing>"')
      warn "  - [name: $userName] issues:"
      json -rc '.issues[]' <<< "$user" | while read -r issue; do
        # black dot
        warn "    • $issue"
      done
    done
  else
    rm -f "$invalidUsersFile"
  fi
}

removeBuiltInRolesAndNonPlatformGrants() {
  local inputFile="$1"
  local tmpFile="${inputFile}.tmp"
  # for each role, check that warn and remove grants not in VALID_ROLE_GRANTS
  while IFS= read -r role; do
    roleName=$(echo "$role" | json -r '.name')
    log -n "    - $roleName"

    if [[ " ${BUILTIN_ROLES[*]} " =~ " ${roleName} " ]]; then
      warn " skipped (built-in role)"
      json -c --arg rn "$roleName" '
        map(select(.name != $rn))
      ' $inputFile > "$tmpFile" && cp "$tmpFile" "$inputFile"
      continue
    fi
    echo ""

    for privilege in "${!XDM_PRIVILEGE_SUBSTITUTION[@]}"; do
      substitutePrivilege="${XDM_PRIVILEGE_SUBSTITUTION[$privilege]}"
      if echo "$role" | json -c '.grants[] | select(.privilege == "'"$privilege"'")' >/dev/null; then
        info "      substituted grant privilege '$privilege' with '$substitutePrivilege'"
        json -c --arg rn "$roleName" --arg p "$privilege" --arg sp "$substitutePrivilege" '
          map(
            if .name == $rn then
              .grants |= map(
                if .privilege == $p then
                  .privilege = $sp
                else
                  .
                end
              )
            else
              .
            end
          )
        ' $inputFile > "$tmpFile" && cp "$tmpFile" "$inputFile"
      fi
    done

    while IFS= read -r grant; do
      privilege=$(echo "$grant" | json -r '.privilege')
      if [[ ! " ${PLATFORM_ROLE_GRANT_PRIVILEGES[*]} " =~ " ${privilege} " ]]; then
        info "      removed non-platform grant privilege '$privilege'"
        json -c --arg rn "$roleName" --arg p "$privilege" '
          map(
            if .name == $rn then
              .grants |= map(select(.privilege != $p))
            else
              .
            end
          )
        ' $inputFile > "$tmpFile" && cp "$tmpFile" "$inputFile"
      fi
    done < <(echo "$role" | json -c '.grants[]')
  done < <(json -c '.[]' $inputFile)
  if [ -f "$tmpFile" ]; then
    if [[ "$pretty" == "1" ]]; then
      json '.' "$tmpFile" > "${tmpFile}.pretty" && mv "${tmpFile}.pretty" "$tmpFile"
    fi
    mv "$tmpFile" "$inputFile"
  fi
}

removeNonPlatformProperties() {
  local inputFile="$1"
  local tmpFile="${inputFile}.tmp"
  local allowedKeys
  allowedKeys=$(IFS="|"; echo "${PLATFORM_PROPERTIES[*]}")
  # Get all original keys
  mapfile -t originalKeys < <(json 'keys[]' "$inputFile")
  # Filter only allowed keys
  json "with_entries(select(.key|test(\"^($allowedKeys)\$\")))" "$inputFile" > "$tmpFile"
  mapfile -t filteredKeys < <(json 'keys[]' "$tmpFile")
  # Log removed properties
  for key in "${originalKeys[@]}"; do
    if [[ ! " ${filteredKeys[*]} " =~ " $key " ]]; then
      warn "    Removed non-platform property $key"
    fi
  done
  if [[ "$pretty" == "1" ]]; then
    json '.' "$tmpFile" > "${tmpFile}.pretty" && mv "${tmpFile}.pretty" "$tmpFile"
  fi
  mv "$tmpFile" "$inputFile"
}

checkNotificationServers() {
  local inputFile="$1"
  local smtpPlugin="com.semarchy.notification.plugin.convergence.mail.smtp"
  # Extract non SaaS notification servers
  nonSaasProviders=$(json -c ".[] | select(.pluginId != \"$smtpPlugin\")" $inputFile)
  if [ -n "$nonSaasProviders" ]; then
    count=$(json -c ".[] | select(.pluginId != \"$smtpPlugin\")" $inputFile | json -s 'length')
    warn "  $count non-SaaS notification server(s) (only SMTP plugins supported):"
    echo "$nonSaasProviders" | while read -r notif; do
      name=$(echo $notif | json -r '.name // "<no name>"')
      pluginId=$(echo $notif | json -r '.pluginId // "<no pluginId>"')
      warn "  - [name: $name] (pluginId: $pluginId)"
    done
  fi
}

checkPluginBundles() {
  local inputFile="$1"
  pluginBundles=$(json -c '.[]' $inputFile)
  if [ -n "$pluginBundles" ]; then
    count=$(echo "$pluginBundles" | json -s 'length')
    warn "  $count non-SaaS plugin bundle(s) found:"
    echo "$pluginBundles" | while read -r plugin; do
      name=$(echo $plugin | json -r '.name // "<no name>"')
      version=$(echo $plugin | json -r '.version // "<no version>"')
      provider=$(echo $plugin | json -r '.provider // "<no provider>"')
      warn "  - [name: $name]: version: $version, provider: $provider"
    done
  fi
}

checkVariableProviders() {
  local inputFile="$1"
  local datasourcePlugin="com.semarchy.semql.plugins.convergence.sql.variableprovider.datasource"
  # Extract non SaaS variable providers
  nonSaasProviders=$(json -c ".[] | select(.pluginId != \"$datasourcePlugin\")" $inputFile)
  if [ -n "$nonSaasProviders" ]; then
    count=$(json -c ".[] | select(.pluginId != \"$datasourcePlugin\")" $inputFile | json -s 'length')
    warn "  $count non-SaaS variable provider(s) (only datasource plugins supported):"
    echo "$nonSaasProviders" | while read -r notif; do
      name=$(echo $notif | json -r '.name // "<no name>"')
      pluginId=$(echo $notif | json -r '.pluginId // "<no pluginId>"')
      warn "  - [name: $name] (pluginId: $pluginId)"
    done
  fi
}

checkDataNotifications() {
  local inputFile="$1"
  local saasTargetType="REST"
  # Extract non SaaS data notifications
  nonSaasDataNotifications=$(json -c ".[] | select(.targetType != \"$saasTargetType\")" $inputFile)
  if [ -n "$nonSaasDataNotifications" ]; then
    count=$(json -c ".[] | select(.targetType != \"$saasTargetType\")" $inputFile | json -s 'length')
    warn "  $count non-SaaS data notification(s) (only $saasTargetType target type supported):"
    echo "$nonSaasDataNotifications" | while read -r notif; do
      name=$(echo $notif | json -r '.name // "<no name>"')
      targetType=$(echo $notif | json -r '.targetType // "<no targetType>"')
      warn "  - [name: $name] (targetType: $targetType)"
    done
  fi
}

queryRepository() {
  local query="$1"
  case "$repositoryDbType" in
    POSTGRESQL)
      available psql
      cmd="psql -h "$repositoryHost" -p "$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -t -A -F\",\" -c "$query""
      verbose 1 "$cmd"
      export PGPASSWORD="$repositoryPassword"
      result=$(psql -h "$repositoryHost" -p "$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -t -A -F"," -c "$query" || die "Failed to query $repositoryDbType database")
      exitCode=$?
      unset PGPASSWORD
      if [[ $exitCode -ne 0 ]]; then
        die "Failed to query $repositoryDbType database.\nCommand: $cmd"
      fi
      ;;
    ORACLE)
      available sqlplus
      cmd="sqlplus -S \"$repositoryUsername/$repositoryPassword@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$repositoryHost)(PORT=$repositoryPort))(CONNECT_DATA=(SERVICE_NAME=$repositoryDbName)))\" <<EOF
SET HEADING OFF
SET FEEDBACK OFF
$query
EXIT
EOF
"
      verbose 1 "$cmd"
      result=$(sqlplus -S "$repositoryUsername/$repositoryPassword@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$repositoryHost)(PORT=$repositoryPort))(CONNECT_DATA=(SERVICE_NAME=$repositoryDbName)))" <<EOF
SET HEADING OFF
SET FEEDBACK OFF
$query
EXIT
EOF
)
      if [[ $? -ne 0 ]]; then
        die "Failed to query $repositoryDbType database.\nCommand: $cmd"
      fi
      ;;
    SQLSERVER)
      available sqlcmd
      query="SET NOCOUNT ON; $query"
      cmd="sqlcmd -S \"$repositoryHost,$repositoryPort\" -U \"$repositoryUsername\" -d \"$repositoryDbName\" -h -1 -W -Q \"$query\" -m 1"
      verbose 1 "$cmd"
      export SQLCMDPASSWORD="$repositoryPassword"
      result=$(sqlcmd -b -S "$repositoryHost,$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -h -1 -W -Q "$query")
      exitCode=$?
      unset SQLCMDPASSWORD
      if [[ $exitCode -ne 0 ]]; then
        die "Failed to query $repositoryDbType database.\nCommand: $cmd"
      fi
      ;;
    *)
      die "Unsupported repository database type '$repositoryDbType'"
      ;;
  esac
  echo "$result"
}

tableAllColumnsExpressionAndHeader() {
  local table="$1"
  # only for MTA_INTEG_LOAD and MTA_INTEG_BATCH in Oracle
  local clobColumn="$2"
  local onlyClobColumn="$3"
  allColumnsExpression=""
  header=""

  case "$repositoryDbType" in
    POSTGRESQL)
      columns=$(queryRepository "SELECT column_name FROM information_schema.columns WHERE table_name = '$table' ORDER BY ordinal_position;")
      while IFS= read -r col; do
        if [ -z "$header" ]; then
          header="$col"
        else
          header="$header,$col"
        fi
        # Quote non-null values, leave nulls empty
        nvlExp="CASE WHEN $col IS NULL THEN '' ELSE '\"' || REPLACE($col, '\"', '\"\"') || '\"' END"
        if [ -z "$allColumnsExpression" ]; then
          allColumnsExpression="$nvlExp"
        else
          allColumnsExpression="$allColumnsExpression || ',' || $nvlExp"
        fi
      done <<< "$columns"
      ;;
    ORACLE)
      columnCondition=""
      if [ "$onlyClobColumn" = "true" ]; then
        columnCondition=" AND UPPER(COLUMN_NAME) = '$clobColumn'"
      else
        columnCondition=" AND UPPER(COLUMN_NAME) != '$clobColumn'"
      fi
      columnsWithTypes=$(queryRepository "SELECT COLUMN_NAME || ' ' || DATA_TYPE FROM USER_TAB_COLUMNS WHERE TABLE_NAME = UPPER('$table')$columnCondition;" | grep -v '^[[:space:]]*$')
      verbose 1 "columnsWithTypes=$columnsWithTypes"
      # for each column and type in columnsWithTypes
      while IFS= read -r colType; do
        col=$(echo "$colType" | cut -d' ' -f1)
        type=$(echo "$colType" | cut -d' ' -f2)
        columnName="$col"
        if [ -z "$header" ]; then
          header="$col"
        else
          header="$header,$col"
        fi
        case "$type" in
          DATE|TIMESTAMP*)
            col="TO_CHAR($col, 'YYYY-MM-DD HH24:MI:SS.FF')"
            ;;
          RAW*)
            # UUID
            col="LOWER(REGEXP_REPLACE(RAWTOHEX($col), '(.{8})(.{4})(.{4})(.{4})(.{12})', '\1-\2-\3-\4-\5'))"
            ;;
          CLOB)
            col="DBMS_LOB.SUBSTR($col, 4000, 1)"
            ;;
          NUMBER*)
            col="TO_CHAR($col)"
            ;;
        esac
        if [ "$columnName" = "$clobColumn" ]; then
          nvlExp="CASE WHEN $col IS NULL THEN '' ELSE $col END"
        else
          # Quote non-null values, leave nulls empty + double any quotes
          nvlExp="CASE WHEN $col IS NULL THEN '' ELSE '\"' || REPLACE($col, '\"', '\"\"') || '\"' END"
        fi
        if [ -z "$allColumnsExpression" ]; then
          allColumnsExpression="$nvlExp"
        else
          allColumnsExpression="$allColumnsExpression || ',' || $nvlExp"
        fi
      done <<< "$columnsWithTypes"
      ;;
    SQLSERVER)
      columns=$(queryRepository "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = UPPER('$table') ORDER BY ORDINAL_POSITION;")
      while IFS= read -r col; do
        col=$(echo "$col" | xargs)
        if [ -z "$header" ]; then
          header="$col"
        else
          header="$header,$col"
        fi
        # Quote non-null values, leave nulls empty
        nvlExp="CASE WHEN $col IS NULL THEN '' ELSE '\"' + REPLACE($col, '\"', '\"\"') + '\"' END "
        if [ -z "$allColumnsExpression" ]; then
          allColumnsExpression="$nvlExp"
        else
          allColumnsExpression="$allColumnsExpression, $nvlExp"
        fi
      done <<< "$columns"
      ;;
    *)
      die "Unsupported repository database type '$repositoryDbType'"
      ;;
  esac
}

exportRepositoryTable() {
  local tableName="$1"
  local outputFile="$2"
  local dataLocationUuid="$3"
  local newDataLocationUuid="$4"
  # only for MTA_INTEG_LOAD and MTA_INTEG_BATCH in Oracle
  local clobColumn="$5"
  local onlyClobColumn="$6"

  local continuousLoadExcludeCondition=""
  if [ "$tableName" == "MTA_INTEG_LOAD" ]; then
    if [ -n "$dataLocationUuid" ]; then
      continuousLoadExcludeCondition=" AND CLASSNAME != 'ContinuousLoad'"
    else
      continuousLoadExcludeCondition=" WHERE CLASSNAME != 'ContinuousLoad'"
    fi
  fi

  case "$repositoryDbType" in
    POSTGRESQL)
      available psql
      if [ -n "$dataLocationUuid" ]; then
        whereDataLocation=" WHERE O_DATALOCATION = '$dataLocationUuid'"
      fi
      query="COPY (SELECT * FROM ${tableName}${whereDataLocation}${continuousLoadExcludeCondition}) TO STDOUT WITH CSV HEADER"
      cmd="psql -h "$repositoryHost" -p "$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -c \"$query\" > \"$outputFile\""
      verbose 1 "$cmd"
      export PGPASSWORD="$repositoryPassword"
      psql -h "$repositoryHost" -p "$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -c "$query" > "$outputFile"
      exitCode=$?
      unset PGPASSWORD
      if [[ $exitCode -ne 0 ]]; then
        die "Failed to export table $tableName from $repositoryDbType database.\nCommand: $cmd"
      fi
      ;;
    ORACLE)
      available sqlplus
      tableAllColumnsExpressionAndHeader "$tableName" "$clobColumn" "$onlyClobColumn"
      if [ -n "$dataLocationUuid" ]; then
        whereDataLocation=" WHERE O_DATALOCATION = HEXTORAW(REPLACE('$dataLocationUuid', '-', ''))"
      fi
      query="SELECT $allColumnsExpression FROM ${tableName}${whereDataLocation}${continuousLoadExcludeCondition} ORDER BY UUID;"
      cmd="sqlplus -S \"$repositoryUsername/$repositoryPassword@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$repositoryHost)(PORT=$repositoryPort))(CONNECT_DATA=(SERVICE_NAME=$repositoryDbName)))\" <<EOF >/dev/null 2>&1
WHENEVER SQLERROR EXIT 1
WHENEVER OSERROR EXIT 1
SET PAGESIZE 0
SET TRIMSPOOL ON
SET LINESIZE 1000
SET FEEDBACK OFF
SET HEADING ON
SPOOL $outputFile
$query
SPOOL OFF
EXIT
EOF
"
      verbose 1 "$cmd"
      sqlplus -S "$repositoryUsername/$repositoryPassword@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$repositoryHost)(PORT=$repositoryPort))(CONNECT_DATA=(SERVICE_NAME=$repositoryDbName)))" <<EOF >/dev/null 2>&1
WHENEVER SQLERROR EXIT 1
WHENEVER OSERROR EXIT 1
SET PAGESIZE 0
SET TRIMSPOOL ON
SET LINESIZE 32767
SET FEEDBACK OFF
SET HEADING OFF
SPOOL $outputFile
$query
SPOOL OFF
EXIT
EOF
      if [[ $? -ne 0 ]]; then
        die "Failed to export table $tableName from $repositoryDbType database:\n$(cat "$outputFile")"
      fi
      # add header to outputFile
      tmpFile="${outputFile}.tmp"
      echo "$header" > "$tmpFile"
      cat "$outputFile" >> "$tmpFile"
      mv "$tmpFile" "$outputFile"
      ;;
    SQLSERVER)
      available sqlcmd
      tableAllColumnsExpressionAndHeader "$tableName"
      if [ -n "$dataLocationUuid" ]; then
        whereDataLocation=" WHERE O_DATALOCATION = '$dataLocationUuid'"
      fi
      query="SET NOCOUNT ON; SELECT ${allColumnsExpression} FROM ${tableName}${whereDataLocation}${continuousLoadExcludeCondition} ORDER BY UUID;"
      cmd="sqlcmd -w 65535 -y 0 -b -S \"$repositoryHost,$repositoryPort\" -U \"$repositoryUsername\" -d \"$repositoryDbName\" -W -s \",\" -Q \"$query\" -o \"$outputFile\" -h-1"
      verbose 1 "$cmd"
      export SQLCMDPASSWORD="$repositoryPassword"
      sqlcmd -w 65535 -y 0 -b -S "$repositoryHost,$repositoryPort" -U "$repositoryUsername" -d "$repositoryDbName" -W -s "," -Q "$query" -o "$outputFile" -h-1
      exitCode=$?
      unset SQLCMDPASSWORD
      if [[ $exitCode -ne 0 ]]; then
        die "Failed to export table $tableName from $repositoryDbType database.\nCommand: $cmd"
      fi
      # add header to outputFile
      tmpFile="${outputFile}.tmp"
      echo "$header" > "$tmpFile"
      cat "$outputFile" >> "$tmpFile"
      mv "$tmpFile" "$outputFile"
      ;;
    *)
      die "Unsupported repository database type '$repositoryDbType'"
      ;;
  esac
  if [ -n "$newDataLocationUuid" ]; then
    # replace data location uuid in outputFile
    cmd="sed -i \"s/$dataLocationUuid/$newDataLocationUuid/g\" \"$outputFile\""
    verbose 1 "$cmd"
    eval "$cmd"
  fi
}

getDataLocationVersion() {
  if [ "$ICONS_ENABLED" == true ]; then
    log -n "🧐 "
  fi
  log -n "Determining version for data location '$1'"
  local dataLocationName="$1"
  local query="SELECT DLOC_VERSION FROM MTA_DATA_LOCATION WHERE NAME = '$dataLocationName';"
  local version=$(queryRepository "$query" | grep -m 1 -v '^[[:space:]]*$' | tr -d '[:space:]')
  # version must start with a digit
  if [[ ! $version =~ ^[0-9] ]]; then
    version=""
  fi
  if [ -z "$version" ]; then
    die " ❌${ICON_PADDING} Failed to determine version"
    exit 1
  else
    log " ✔️${ICON_PADDING} $version"
  fi
  echo "$version"
}

repositoryFile="$repoWorkspaceDir/repository.json"
httpGet "$(getResourceEndpoint "repository")" "$repositoryFile" "repository"
if [ $? -ne 0 ]; then
  exit $?
fi
repositoryDbType=$(json -r '.dbType' "$repoWorkspaceDir/repository.json")
repositoryDbName=$(json -r '.dbName' "$repoWorkspaceDir/repository.json")
repositoryDbSchema=$(json -r '.dbSchema' "$repoWorkspaceDir/repository.json")
repositoryVersion=$(json -r '.version' "$repoWorkspaceDir/repository.json")
if [ -z "$repositoryDbType" ] || [ -z "$repositoryDbName" ] || [ -z "$repositoryDbSchema" ]; then
  die "Cannot determine repository database type, name and schema from $repoWorkspaceDir/repository.json"
fi
info -n "$(bold "xDM version:") $repositoryVersion"

repositoryVersionMajorAndMinor=$(echo "$repositoryVersion" | cut -d'.' -f1,2)
if [[ ! " ${SUPPORTED_XDM_VERSIONS[*]} " =~ " ${repositoryVersionMajorAndMinor} " ]]; then
  supportedVersions="Supported LTS versions: $(IFS=, ; echo "${SUPPORTED_XDM_VERSIONS[*]}" | sed 's/,/, /g')"
  if [ "$ignoreVersionCheck" == true ]; then
    warn " ⚠️$ICON_PADDING Version is not supported. $supportedVersions"
  else
    die " ❌$ICON_PADDING Version is not supported. $supportedVersions"
  fi
else
  info " ✔️"
fi

dataLocationsFile="$repoWorkspaceDir/dataLocations.json"
httpGet "$dataLocationsUrl" "$dataLocationsFile" "dataLocations"
allDataLocations=$(json -r '.[].name' "$dataLocationsFile" | sort | awk 'ORS="," {print}' | sed 's/,$//')
# filter data locations where name in dataLocations array
for dataLoc in ${dataLocations//,/ }; do
  json -c --arg dloc "$dataLoc" '
    [.[] | select(.name == $dloc)]
  ' "$dataLocationsFile" > "${dataLocationsFile}.tmp" && mv "${dataLocationsFile}.tmp" "$dataLocationsFile"
done

# Add version property to each data location in dataLocationsFile
tmpFile="${dataLocationsFile}.tmp"
json -c '.[]' "$dataLocationsFile" | while read -r dloc; do
  name=$(echo "$dloc" | json -r '.name')
  version=$(getDataLocationVersion "$name")
  exitCode=$?
  if [ $exitCode -ne 0 ]; then
    exit $?
  fi

  echo "$dloc" | jq --arg version "$version" '. + {version: $version}'
done | jq -s '.' > "$tmpFile" && mv "$tmpFile" "$dataLocationsFile"

allRequestedDataLocations=$(json -r '.[].name' "$dataLocationsFile" | sort | awk 'ORS="," {print}' | sed 's/,$//')

requestedDataLocations=""
if [ -n "$dataLocations" ]; then
  for dataLoc in ${dataLocations//,/ }; do
    if ! grep -qw "$dataLoc" <<< "${allRequestedDataLocations//,/ }"; then
      die "Data location '$dataLoc' does not exist in available data locations: $allDataLocations"
    else
      if [ -n "$requestedDataLocations" ]; then
        requestedDataLocations="$requestedDataLocations,$dataLoc"
      else
        requestedDataLocations="$dataLoc"
      fi
    fi
  done
else
  requestedDataLocations="$allRequestedDataLocations"
fi
if [ -z "$requestedDataLocations" ]; then
  info "$(bold "Data locations to export:") none found"
else
  info "$(bold "Data locations to export:") $requestedDataLocations"
fi
IFS=',' read -ra requestedDataLocationArray <<< "$requestedDataLocations"

callEndpoint() {
  local resource="$1"
  local endpoint=$(getResourceEndpoint "$resource")
  if [[ "$endpoint" == "$NOOP" ]]; then
    return
  fi
  local outputFilename=$(getResourceOutputFilename "$resource")
  local evalFunc=$(getResourceEvalFunction "$resource")
  if [[ "$endpoint" == *"{dloc-name}"* ]]; then
    for dloc in "${requestedDataLocationArray[@]}"; do
      dlocWorkspaceDir="$workspace/dataLocations/$dloc"
      if [ ! -d "$dlocWorkspaceDir" ]; then
        mkdir -p "$dlocWorkspaceDir"
        info "\nCreated data location workspace directory: $dlocWorkspaceDir"
      fi
      dlocEndpoint="${endpoint//\{dloc-name\}/$dloc}"
      httpGet "$dlocEndpoint" "$dlocWorkspaceDir/$outputFilename" "$resource" "$dloc"
      if [ -n "$evalFunc" ]; then
        eval "$evalFunc" "$dlocWorkspaceDir/$outputFilename"
      fi
    done
  else
    if [ ! -d "$repoWorkspaceDir" ]; then
      mkdir -p "$repoWorkspaceDir"
      info "Created repository workspace directory: $repoWorkspaceDir"
    fi
    httpGet "$endpoint" "$repoWorkspaceDir/$outputFilename" "$resource"
    if [ -n "$evalFunc" ]; then
      eval "$evalFunc" "$repoWorkspaceDir/$outputFilename"
    fi
  fi
}

if [ ${#resourceArray[@]} -ne 0 ]; then
  for s in "${resourceArray[@]}"; do
    if shouldExport "$s"; then
      callEndpoint "$s"
    fi
  done
else
  # Default: all resourceConfig
  for s in "${!resourceConfig[@]}"; do
    if shouldExport "$s"; then
      callEndpoint "$s"
    fi
  done
fi

# Image Libraries - download zips
resource="imageLibraries"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  imageLibWorkspaceDir="$repoWorkspaceDir/imageLibraries"
  if [ ! -d "$imageLibWorkspaceDir" ]; then
    mkdir -p "$imageLibWorkspaceDir"
    info "Created image library workspace directory: $imageLibWorkspaceDir"
  fi
  imageLibsFile="$repoWorkspaceDir/imageLibraries.json"
  if [ -f "$imageLibsFile" ]; then
    json -c '.[]' "$imageLibsFile" | while read -r lib; do
      libName=$(echo $lib | json -r '.name')
      imageLibraryZip="$repoWorkspaceDir/imageLibraries/${libName}.zip"
      httpGet "$adminUrl/image-libraries/$libName" "$imageLibraryZip" "imageLibraries"
    done
  fi
fi

# Plugin Bundles - download jars
resource="pluginBundles"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  pluginWorkspaceDir="$repoWorkspaceDir/pluginBundles"
  if [ ! -d "$pluginWorkspaceDir" ]; then
    mkdir -p "$pluginWorkspaceDir"
    info "Created plugin bundle workspace directory: $pluginWorkspaceDir"
  fi
  pluginBundlesFile="$repoWorkspaceDir/pluginBundles.json"
  if [ -f "$pluginBundlesFile" ]; then
    json -c '.[]' "$pluginBundlesFile" | while read -r plugin; do
      pluginName=$(echo $plugin | json -r '.name')
      pluginJarFile="$repoWorkspaceDir/pluginBundles/${pluginName}.jar"
      httpGet "$adminUrl/plugin-bundles/$pluginName/jar" "$pluginJarFile" "pluginBundles"
    done
  fi
fi

# Dashboards - download zips
resource="dashboards"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  dashboardWorkspaceDir="$workspace/dashboards"
  if [ ! -d "$dashboardWorkspaceDir" ]; then
    mkdir -p "$dashboardWorkspaceDir"
    info "Created dashboard workspace directory: $dashboardWorkspaceDir"
  fi
  dashboardsFile="$repoWorkspaceDir/dashboards.json"
  json -c '.[]' "$dashboardsFile" | while read -r dash; do
    name=$(echo $dash | json -r '.name')
    httpGet "$restUrl/dashboard-builder/dashboard-applications/$name/content" "$workspace/dashboards/${name}.zip" "dashboards"
  done
fi

repositoryParamAreDefined() {
  if [ -z "$repositoryHost" ] || [ -z "$repositoryPort" ] || [ -z "$repositoryUsername" ] || [ -z "$repositoryPassword" ]; then
    warn "Skipped '$resource'. Repository host, port, username, and password are required."
  fi
}

# Database sequences
resource="sequences"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  if repositoryParamAreDefined; then
    sequenceFile="$repoWorkspaceDir/sequences.json"
    log -n "${icon}Exporting database sequences from $repositoryDbType repository database named '$repositoryDbName' at $repositoryHost:$repositoryPort to $sequenceFile"
    if shouldOverwriteFile "$sequenceFile"; then
      sequenceIncrementValue() {
        local sequence="$1"
        # if sequenceIncrementMap is empty, return sequenceIncrement
        if [ ${#sequenceIncrementMap[@]} -eq 0 ]; then
          echo "$sequenceIncrement"
        else
          echo "${sequenceIncrementMap[$sequence]:-0}"
        fi
      }
      currentSequenceValueExpression() {
        local sequenceName="$1"
        case "$repositoryDbType" in
          POSTGRESQL)
            echo "(select coalesce(last_value, start_value) from pg_sequences where sequencename = '${sequenceName}' and sequenceowner = '${repositoryUsername}')"
            ;;
          ORACLE)
            echo "(select nvl(last_number, min_value) from sys.all_sequences where sequence_name = upper('${sequenceName}') and sequence_owner = upper('${repositoryUsername}'))"
            ;;
          SQLSERVER)
            echo "(select coalesce(current_value, start_value) from sys.sequences where name = '${sequenceName}')"
            ;;
          *)
        esac
      }

      case "$repositoryDbType" in
        POSTGRESQL)
          result=$(queryRepository "select concat($(currentSequenceValueExpression 'seq_batchid'), ' ', $(currentSequenceValueExpression 'seq_datanotiflogid'), ' ',$(currentSequenceValueExpression 'seq_loadid'), ' ', $(currentSequenceValueExpression 'seq_revision'))")
          ;;
        ORACLE)
          result=$(queryRepository "SELECT $(currentSequenceValueExpression 'seq_batchid') || ' ' || $(currentSequenceValueExpression 'seq_datanotiflogid') || ' ' || $(currentSequenceValueExpression 'seq_loadid') || ' ' || $(currentSequenceValueExpression 'seq_revision') FROM dual;")
          ;;
        SQLSERVER)
          result=$(queryRepository "SELECT $(currentSequenceValueExpression 'SEQ_BATCHID'), $(currentSequenceValueExpression 'SEQ_DATANOTIFLOGID'), $(currentSequenceValueExpression 'SEQ_LOADID'), $(currentSequenceValueExpression 'SEQ_REVISION')")
          ;;
        *)
          warn "\nSkipped sequences export. Unsupported repository database type '$repositoryDbType'"
          ;;
      esac
      if [ $? -ne 0 ]; then
        die "Failed to export database sequences from $repositoryDbType repository database."
      fi
      if [ -n "$result" ]; then
        echo "$result" | grep -E '^[0-9]+[[:space:]][0-9]+[[:space:]][0-9]+[[:space:]][0-9]+$' | \
          awk -v batchIdInc="$(sequenceIncrementValue "batchId")" -v dataNotifLogIdInc=$(sequenceIncrementValue "dataNotifLogId") \
              -v loadIdInc="$(sequenceIncrementValue "loadId")" -v revisionInc="$(sequenceIncrementValue "revision")" \
          -F' ' '{printf "{\"batchId\":%d,\"dataNotifLogId\":%d,\"loadId\":%d,\"revision\":%d}\n", $1+batchIdInc, $2+dataNotifLogIdInc, $3+loadIdInc, $4+revisionInc}' > $sequenceFile
        log " ✔️"
        verbose 1 "$(json . $sequenceFile)"
        if [[ "$pretty" == "1" ]]; then
          json . "$sequenceFile" > "${sequenceFile%.json}-pretty.json"
          mv "${sequenceFile%.json}-pretty.json" "$sequenceFile"
        fi
      fi
    fi
  fi
fi

doTableExport() {
  if repositoryParamAreDefined; then
    local label="$1"
    local table="$2"
    local outputFilename="$3"
    local clobColumn="$4"
    for dataLocation in "${requestedDataLocationArray[@]}"; do
      local startTime=$(date +%s)
      dlocWorkspaceDir="$workspace/dataLocations/$dataLocation"
      if [ ! -d "$dlocWorkspaceDir" ]; then
        mkdir -p "$dlocWorkspaceDir"
        info "Created data location workspace directory: $dlocWorkspaceDir"
      fi
      dataLocationUuid=$(json -r --arg dloc "$dataLocation" '.[] | select(.name == $dloc) | .id' "$dataLocationsFile")
      newDataLocationUuid="${dataLocationUuidMap[$dataLocation]}"
      fileDataLocationUuid="$dataLocationUuid"
      if [ -n "$newDataLocationUuid" ]; then
        # suffix outputFilename wit"h "-$newDataLocationUuid" before extension
        base="${outputFilename%.*}"
        ext="${outputFilename##*.}"
        outputFilename="${base}-${newDataLocationUuid}.${ext}"
        fileDataLocationUuid="$newDataLocationUuid"
      fi
      outputFile="$dlocWorkspaceDir/$outputFilename"
      outputFileGz="$outputFile.gz"

      log -n "${icon}Exporting $dataLocation $label from $repositoryDbType database"
      if shouldOverwriteFile "$outputFileGz"; then
        runWithSpinner exportRepositoryTable "$table" "$outputFile" "$dataLocationUuid" "$newDataLocationUuid" "$clobColumn" "false"
        if [ -n "$clobColumn" ] && [ "$repositoryDbType" = "ORACLE" ]; then
          clobColumnFile="${outputFile}_$clobColumn.tmp"
          run exportRepositoryTable "$table" "$clobColumnFile" "$dataLocationUuid" "$newDataLocationUuid" "$clobColumn" "true"
          # Normalize DESCRIPTION export so it can be safely merged as an extra CSV column
          # This ensures all DESCRIPTION values are consistently quoted, so embedded commas/whitespace
          # do not break the CSV format when we paste this file alongside the main export.
          awk '
              # Pass the header line through unchanged
              NR == 1 { print; next }

              # Pass blank lines through unchanged
              /^[[:space:]]*$/ { print; next }

              # For all other lines:
              {
                  # Double all internal quotes for CSV safety
                  gsub(/"/, "\"\"")

                  # Wrap the whole line in double quotes
                  print "\"" $0 "\""
              }
          ' "$clobColumnFile" > "${clobColumnFile}_tmp" && mv "${clobColumnFile}_tmp" "${clobColumnFile}"
          # merge
          sed -i 's/\r$//' "$outputFile"
          paste -d',' "$outputFile" "$clobColumnFile" > "${outputFile}_tmp" && mv "${outputFile}_tmp" "$outputFile" && rm -f "$clobColumnFile"
        fi
        # remove empty lines in outputFile
        cmd="sed -i '/^$/d' \"$outputFile\""
        verbose 1 "$cmd"
        eval "$cmd"
        count=$(grep -c "$fileDataLocationUuid" "$outputFile")
        gzip -f "$outputFile"
      fi
      size=$(du -h "$outputFileGz" | cut -f1)

      log "$count records in $(formattedElapsedTime $startTime) ($size)"
    done
  fi
}

# Integration batches
resource="integBatches"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  doTableExport "integration batches" "MTA_INTEG_BATCH" "integBatches.csv" "JOB_MESSAGE"
fi

# Integration loads
resource="integLoads"
if shouldExport "$resource"; then
  icon=$(getResourceIcon "$resource")
  doTableExport "integration loads" "MTA_INTEG_LOAD" "integLoads.csv" "DESCRIPTION"
fi

log "\n✔️${ICON_PADDING} All done in $(formattedElapsedTime $mainStartTime)!"
