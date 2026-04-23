#!/usr/bin/env bash
set -eo pipefail
USER_CANCEL=100
trap 'onExit $?;' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 143' TERM

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
ICONS_ENABLED=true

DEFAULT_URL="http://localhost:8088/semarchy"
DEFAULT_WORKSPACE="./exportWorkspace"

VERBOSE=0

PROG_ARGS=( "$@" )

help()
{
    info "_______ Export xDM Model _______
This interactive script exports a model edition and translations from xDM using the REST API.
If a model name and edition key is provided as arguments, the script will export that model edition directly.

Usage: $(basename "$0") [-h] [-v] [-y] [-a <apiKey>] [-u <xdmUrl>] [-w <workspaceDir>] [-m <model name>] [-e <edition key>] [--all] [--overwrite]
Arguments
        $(bold "--api-key -a          :") xDM API key. Default: XDM_API_KEY env value
        $(bold "--url -u              :") xDM Base URL. Default: $DEFAULT_URL
        $(bold "--workspace -w        :") Workspace directory for for exported data. Default: $DEFAULT_WORKSPACE
        $(bold "--model               :") Model name to export. If not provided, an interactive selection will be presented.
        $(bold "--edition-key         :") Model edition key ('<editionId>.<branchId>') to export. If not provided, an interactive selection will be presented.
        $(bold "--all                 :") Export all models and their editions. Model and edition key arguments will be ignored
                                          ⚠️$ICON_PADDING Can take a long time and generate a lot of data.
        $(bold "--overwrite           :") Overwrite existing files in workspace (default: asks for confirmation if file exists).
        $(bold "--no-spinner          :") Disable wait spinner.
        $(bold "--no-icons            :") Disable icons.
        $(bold "--no-colors           :") Disable text colors.
        $(bold "-v                    :") Verbose mode in ${GREEN}green${RESET} (-vv for more verbosity)
        $(bold "-x                    :") Debug mode (same as bash +x)
        $(bold "-y                    :") Automatically answer 'yes' to all prompts.
        $(bold "--help -h             :") Show this help message and exit.

Required external commands:
    - curl for http calls
    - jq for JSON processing
    - getopt for argument parsing

Examples
  Export xDM model named 'CustomerB2CDemo' with edition ID 1 and branch ID 2 to folder $DEFAULT_WORKSPACE/models/CustomerB2CDemo
      $(basename "$0") --api-key 'myApiKey' --model CustomerB2CDemo --edition-key 1.2
  Export xDM model with interactive selection of model and edition (using API Key env variable)
      XDM_API_KEY='myApiKey' $(basename "$0")
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

onExit() { # code lineno
  # restore terminal cursor (hidden for spinner)
  tput cnorm
  local code="$1" lineno="$2"
  if [ "$code" -eq 0 ] || [ "$code" -eq "$USER_CANCEL" ]; then
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

cancel() {
  exit "$USER_CANCEL"
}

available() { # cmd ...
  for cmd in "$@"; do
    >/dev/null 2>&1 type "$cmd" || die "$cmd: command required by this script, you must install it"
  done
}

available curl jq getopt

# because `jq -r` does not trim the trailing \r on Windows
json() {
  local jqOptions=( "$@" )
  jq "${jqOptions[@]}" | sed 's/\r$//'
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

verbose() {
  local level="$1" message="$2"
  (($# == 1)) && message=$(cat)
  if (( level <= VERBOSE )); then
    >&2 echo -e "\n${GREEN}$message" ;
  fi
}

run() {
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
  printf "  "
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
    printf "\b✔️$ICON_PADDING "
  else
    set -eo pipefail
  fi
  return $exitCode
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
      warn -n " already exists, replacing"
      return 0
    fi
    warn -n " file already exists, replace? (y/N)"
    read reply < /dev/tty
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      log "Skipped!"
      return 1
    fi
  fi
  return 0
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

httpGet() {
  local httpUrl="$1"
  local outputFile="$2"
  local icon="$3"
  if [ "$ICONS_ENABLED" == false ]; then
    icon="\b"
  fi

  local response
  if [ -z "$httpUrl" ]; then
    die "No URL provided to http"
  fi
  if [ -z "$outputFile" ]; then
    echo "$(http "$httpUrl")"
    return
  fi
  log -n "  ${icon} Exporting: .${httpUrl#$url}"
  if ! shouldOverwriteFile "$outputFile"; then
    return
  fi
  startTime=$(date +%s)
  runWithSpinner http "$httpUrl" "$outputFile"
  exitCode=$?
  if [ $exitCode -ne 0 ]; then
    echo ""
    return $exitCode
  fi
  local elapsedTime=$(formattedElapsedTime $startTime)
  local size=$(du -h "$outputFile" | cut -f1 2>/dev/null || wc -c < "$outputFile")
  log "$size in $elapsedTime"
}

checkXdmStatus() {
  if [ "$ICONS_ENABLED" == true ]; then
    log -n "🔍 "
  fi
  log -n "Checking xDM status "
  set +e
  runWithSpinner http "$url/api/rest/probes/started"
  echo ""
}

cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null

SHORT=a:,u:,w:,m:,k:,y,x,h,v
LONG=api-key:,url:,workspace:,model:,edition-key:,all,overwrite,no-spinner,no-icons,no-colors,help
OPTS=$(getopt -a -n "$(basename "$0")" --options $SHORT --longoptions $LONG -- "$@")

apiKey=$XDM_API_KEY
workspace="$DEFAULT_WORKSPACE"
url="$DEFAULT_URL"

eval set -- "$OPTS"

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
    --model)
      modelName="$2"
      shift 2
      ;;
    --edition-key)
      modelEditionKey="$2"
      shift 2
      ;;
    --all)
      exportAll=1
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
    -v) VERBOSE=$((VERBOSE + 1)); shift ;;
    -x) DEBUG=true; set -x; shift ;;
    -y) alwaysYes=1; shift ;;
    -h | --help) help ;;
    --) shift; break ;;
    *) error "Unexpected option: $1"; help ;;
  esac
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
  info "Created workspace directory: $workspace"
  info "$(bold "Workspace directory:") $workspace (Created)"
else
  info "$(bold "Workspace directory:") $workspace"
fi

checkXdmStatus "$url"
if [[ $? -ne 0 ]]; then
  die "xDM does not seem to be started properly or is not reachable at $url"
  exit 1
fi

restUrl="$url/api/rest"
modelsUrl="$restUrl/app-builder/models"

# Fetch available models
log -n "🕵️$ICON_PADDING Fetching available models ... "
modelsJson=$(httpGet "$modelsUrl")
echo "$modelsJson" | jq 'if type == "array" then empty else error("Not an array") end' >/dev/null 2>&1
if [ $? -ne 0 ] || [ -z "$modelsJson" ] || [ "$modelsJson" = "[]" ]; then
  die "\nNo models found or failed to fetch models from $modelsUrl"
fi
modelCount=$(echo "$modelsJson" | json 'length')
echo "✔️$ICON_PADDING found $modelCount model(s)."

exportModelEdition() {
  local modelName="$1"
  local modelEditionKey="$2"

  modelWorkspaceDir="$workspace/models/$modelName"
  if [ ! -d "$modelWorkspaceDir" ]; then
    mkdir -p "$modelWorkspaceDir"
    log "Created workspace directory: $modelWorkspaceDir" >&2
  fi

  local modelEditionUrl="$restUrl/app-builder/models/$modelName/editions/$modelEditionKey/content"
  httpGet "$modelEditionUrl" "$modelWorkspaceDir/$modelName [$modelEditionKey].xml" "🧩"
  local modelEditionTranslationsUrl="$restUrl/app-builder/models/$modelName/editions/$modelEditionKey/translations"
  httpGet "$modelEditionTranslationsUrl" "$modelWorkspaceDir/$modelName [$modelEditionKey]_i18n.zip" "🌍"
}

if [ "$exportAll" = "1" ]; then
  warn -n "⚠️$ICON_PADDING Exporting all models and their editions can take a while. "
  if [ "$alwaysYes" == "1" ]; then
    warn -n "Proceeding automatically... "
  else
    warn -n "Are you sure? (y/N) "
    read reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi

  mainStartTime=$(date +%s)
  index=1
  # Iterate over each model
  echo "$modelsJson" | json -r '.[].name' | while read -r model; do
    log "\n🏗️$ICON_PADDING Model $index/$modelCount: [$model]"
    modelEditionsUrl="$modelsUrl/$model/editions"
    modelEditionsJson=$(httpGet "$modelEditionsUrl")

    if [ -z "$modelEditionsJson" ] || [ "$modelEditionsJson" = "[]" ]; then
      warn "No editions found for model $model, skipping..."
      continue
    fi

    # Iterate over each edition of the model
    echo "$modelEditionsJson" | json -r 'sort_by(.key)[].key' | while read -r editionKey; do
      description=$(echo "$modelEditionsJson" | json -r --arg key "$editionKey" '.[] | select(.key == $key) | .description')
      log " 📐 Edition: $editionKey - $description"
      exportModelEdition "$model" "$editionKey"
    done
    index=$((index + 1))
  done
  log "\n✔️$ICON_PADDING All done in $(formattedElapsedTime $mainStartTime)!"
  exit 0
fi

selectModelName() {
  # Parse and display models
  info "Available models:" >&2
  echo "$modelsJson" | json -r '.[] | "\(.name) - \(.label). " + (if (.usedIn|length) > 0 then "Used in data location(s): \(.usedIn | join(", "))" else "Not used in any data locations" end)' | nl -w2 -s') ' >&2


  # Get model names into array
  readarray -t modelNames < <(echo "$modelsJson" | json -r '.[].name')
  count=${#modelNames[@]}

  if [ $count -eq 0 ]; then
    die "No models available"
  fi

  range="1"
  if [ $count -gt 1 ]; then
    range="$range-$count"
  fi
  # Interactive selection
  while true; do
    read -p "Select model ($range) or 'q' to quit: " selection >&2

    if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
      die "Export cancelled"
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ]; then
        modelName="${modelNames[$((selection-1))]}"
        break
    else
        warn "Invalid selection. Please enter a number between 1 and $count, or 'q' to quit." >&2
    fi
  done
  echo "$modelName"
}

selectModelEdition() {
  local modelName="$1"
  local modelEditionsUrl="$modelsUrl/$modelName/editions"
  # Fetch available model editions
  log "Fetching available $modelName editions ... " >&2
  modelEditionsJson=$(httpGet "$modelEditionsUrl")

  if [ -z "$modelEditionsJson" ] || [ "$modelEditionsJson" = "[]" ]; then
    die "No model editions found or failed to fetch models from $modelEditionsUrl"
  fi

  # Get edition keys into array
  readarray -t modelEditionKeys < <(echo "$modelEditionsJson" | json -r 'sort_by(.key)[].key')
  count=${#modelEditionKeys[@]}

  # Parse and display model editions
  info "Available $modelName editions with key[<branch ID>.<edition ID>]:" >&2
  echo "$modelEditionsJson" | json -r 'sort_by(.key)[] | "key[\(.key)] - \(.description) - status \(.status)"' | nl -w2 -s') ' >&2

  if [ $count -eq 0 ]; then
    die "No $modelName editions available"
  fi

  range="1"
  if [ $count -gt 1 ]; then
    range="$range-$count"
  fi
  # Interactive selection
  while true; do
    read -p "Select model edition to export ($range) or 'q' to quit: " selection >&2

    if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
      die "Export cancelled"
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ]; then
        modelEditionKey="${modelEditionKeys[$((selection-1))]}"
        break
    else
        warn "Invalid selection. Please enter a number between 1 and $count, or 'q' to quit." >&2
    fi
  done
  echo "$modelEditionKey"
}

if [[ -n "$modelName" ]]; then
  # Validate provided model name
  if ! echo "$modelsJson" | json -e --arg name "$modelName" '.[] | select(.name == $name)' >/dev/null; then
    error "Model '$modelName' not found. Available models are:"
    echo "$modelsJson" | json -r '.[] | " - name[\(.name)] - \(.label) (used in \(.usedIn))"'
    exit 1
  fi
else
  modelName=$(selectModelName)
  if [ -z "$modelName" ]; then
    cancel
  fi
fi

echo ""
if [[ -n "$modelEditionKey" ]]; then
  # Validate provided model edition key
  modelEditionsUrl="$modelsUrl/$modelName/editions"
  modelEditionsJson=$(httpGet "$modelEditionsUrl")

  if ! echo "$modelEditionsJson" | json -e --arg key "$modelEditionKey" '.[] | select(.key == $key)' >/dev/null; then
    error "Model edition with key '$modelEditionKey' not found for model '$modelName'. Available editions are with key[<branch ID>.<edition ID>]:"
    echo "$modelEditionsJson" | json -r '.[] | "  - key[\(.key)] - \(.description) - status \(.status)"'
    exit 1
  fi
else
  modelEditionKey=$(selectModelEdition "$modelName")
  if [ -z "$modelEditionKey" ]; then
    cancel
  fi
fi

mainStartTime=$(date +%s)
exportModelEdition "$modelName" "$modelEditionKey"
log "\n✔️$ICON_PADDING All done in $(formattedElapsedTime $mainStartTime)!"
