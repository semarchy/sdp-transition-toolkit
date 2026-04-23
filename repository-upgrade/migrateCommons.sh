#!/bin/bash

function available() { # commands
  for cmd in "$@"; do
    >/dev/null 2>&1 type "$cmd" || die "$cmd: command required by this script, you must install it"
  done
}

function run { # command args...
  local command=("$@")
  >&2 echo "Executing command: ${command[*]}"
  "${command[@]}"
}

function die() { # message
  local message="$1"
  >&2 echo "FATAL: $message"
  exit 1
}

function askForValue() { # message defaultValue
  local message="$1"
  local defaultValue="$2"

  local response
  read -rp "$message [$defaultValue]: " response
  response=${response:-$defaultValue}
  echo "$response"
}

function prompt() { # message options
  local message="$1"
  local options="$2"

  local response
  while true; do
    read -rp "$message [$options]: " response
    [[ "$response" =~ ^[$options]$ ]] && break
  done
  echo "$response"
}

function executeOrSkip() { # stepName
  local stepName="$1"
  local executionStatus outputs

  echo
  executionStatus="$(grep -F "$stepName: " "$STATUS_FILE" 2>/dev/null)"
  [ -n "$executionStatus" ] && {
    echo "[$stepName] Already executed"
    outputs="${executionStatus#$stepName: }"
    [ -n "$outputs" ] && echo "$outputs" && eval "$outputs"
    return 1
  }
  echo -n "[$stepName] Press ENTER to execute or CTRL+C to interrupt... " && read -r
  echo "[$stepName] Executing..."
}

function executed() { # stepName outputs
  local stepName="$1"; shift
  local outputs="$*"
  echo "[$stepName] Executed"
  echo "$stepName: $outputs" >> "$STATUS_FILE"
}

function require() { # [var1 ...]
  local param failed
  for var in "$@"; do
    local param="--${var//_/-}"; param="${param,,}"
    [ -z "${!var}" ] &&
      >&2 echo "Error: environment variable $var must be set to execute this step (you can also use the option $param)" &&
     failed=true
  done
  [ -z "$failed" ] || exit 1
}

function checkSemAuthentication() { # sdpUrl
  local sdpUrl="${1%/}"
  if [ -n "$SEM_CLIENT_ID" ]; then
    sem auth token --url "$sdpUrl" >/dev/null 2>&1 ||
      die "You must provide valid Client ID and Client Secret parameters or environment variables to authenticate against $sdpUrl."
    return
  fi
  sem auth | grep -q "$sdpUrl" >/dev/null 2>&1 ||
    die "You must be authenticated against $sdpUrl. Please run 'sem auth login $sdpUrl' and try again."
  sem auth | grep -q "authenticated to" >/dev/null 2>&1 ||
    die "Your authentication token has expired. Please run 'sem auth login' and try again."
}

function accessToken() {
  if [ -n "$SEM_CLIENT_ID" ]; then
    sem auth token --url "$SDP_URL" 2>/dev/null
  else
    sem auth token 2>/dev/null
  fi
}
