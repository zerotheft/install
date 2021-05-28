#!/bin/bash
set -u

abort() {
  printf "%s\n" "$@"
  exit 1
}

if [ -z "${BASH_VERSION:-}" ]; then
  abort "Bash is required to interpret this script."
fi
declare -r TRUE=0
declare -r FALSE=1

HOLON_PREFIX="${HOME}/.zerotheft"
HOLON_API_GIT_NAME="zerotheft/zerotheft-holon-node"
HOLON_UI_GIT_NAME="zerotheft/zerotheft-holon-react"
HOLON_API_UTILS_GIT_NAME="zerotheft/zerotheft-node-utils"
HOLON_REPOSITORY="${HOLON_PREFIX}/Zerotheft-Holon"
HOLON_API_REPOSITORY="${HOLON_REPOSITORY}/holon-api"
HOLON_API_UTILS_REPOSITORY="${HOLON_REPOSITORY}/holon-api/sub-modules/zerotheft-node-utils"
HOLON_UI_REPOSITORY="${HOLON_REPOSITORY}/holon-ui"
BRANCH="master"

CONFIG="${HOLON_PREFIX}/config.json"
ENV_FILE="${HOLON_PREFIX}/.zt/env.json" 
TIMESTAMP=$(date "+%s")

remove_quotes(){
  local temp
  temp="${1%\"}"
  echo "${temp#\"}"
}

# only perform update if auto update is enabled
if ! [[ -f "${CONFIG}" ]]; then
  abort "Configs missing"
fi
AUTO_UPDATE=$(remove_quotes "$(jq .AUTO_UPDATE ${CONFIG})")
if [[ "$AUTO_UPDATE" = "false" ]]; then
  abort "Auto update is disabled."
fi

# get ENV if present
if ! [[ -f "${ENV_FILE}" ]]; then
  abort "Environment missing"
fi
ENV=$(remove_quotes "$(jq .MODE ${ENV_FILE})")

# fetch thel latest tag name of a repo
get_required_version(){
  cmd="$(curl --silent "https://api.github.com/repos/$1/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')"
  echo "${cmd}"
  # echo 1.0.1
}

# returns the current version of app
get_current_version(){
  ver=$(jq .HOLON_"$1"_VERSION ${CONFIG})
  remove_quotes "$ver"
}

version_compare(){  
  if [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; then 
    return $FALSE
  else
    return $TRUE
  fi
}

# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_blue="$(tty_mkbold 34)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

execute() {
  if ! "$@"; then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}
ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

# repo upte from git
git_repo_update(){
 
  execute "git" "fetch" "--force" "origin"
  execute "git" "fetch" "--force" "--tags" "origin"

  execute "git" "reset" "--hard" "$1"   
}

required_api_ver=$(get_required_version "${HOLON_API_GIT_NAME}")
required_ui_ver=$(get_required_version "${HOLON_UI_GIT_NAME}")
required_utils_ver=$(get_required_version "${HOLON_API_UTILS_GIT_NAME}")
# required_api_ver="1.2.16"
# required_ui_ver="1.2.14"
# required_utils_ver="1.2.13"

current_api_ver=$(get_current_version "API")
current_ui_ver=$(get_current_version "UI")
current_utils_ver=$(get_current_version "UTILS")
# required_api_ver="1.0.0"
# current_api_ver="1.0.0"

# checking version of holon-ui and update if needed
ohai  "Checking holon-ui"
version_compare "$required_ui_ver" "$current_ui_ver" &&
(
  (
    echo "holon-ui is out of date."
    echo "- Current version: ${current_ui_ver}"
    echo "- Required version: ${required_ui_ver}"
    cd "${HOLON_UI_REPOSITORY}" >/dev/null || return

      git_repo_update  "origin/${BRANCH}"

      execute "yarn" "install"      

      execute "yarn" "build-${ENV}"

    #move build to different directory but first clear the existing one
    if ! [[ -d "${HOLON_PREFIX}/build" ]]; then
      execute "rm" "-rf" "${HOLON_PREFIX}/build"
    fi
    execute "cp" "-R" "build/" "${HOLON_PREFIX}"
    execute "rm" "-rf" "build/*"  

  ) || exit 1
) || echo 'holon-ui is up to date'

# checking version of holon-api and update if needed
ohai  "Checking holon-api"
version_compare "$required_api_ver" "$current_api_ver" &&
(
  (
    echo "holon-api is out of date."
    echo "- Current version: ${current_api_ver}"
    echo "- Required version: ${required_api_ver}"

    cd "${HOLON_API_REPOSITORY}" >/dev/null || return  
        
      git_repo_update "origin/${BRANCH}"

      execute "yarn" "install"

  ) || exit 1

) ||  echo 'holon-api is up to date'

ohai "Checking holon-api/sub-modules/zerotheft-node-utils"
  version_compare "$required_utils_ver" "$current_utils_ver" &&
  (
    (
      echo "holon-utils is out of date."
      echo "- Current version: ${current_utils_ver}"
      echo "- Required version: ${required_utils_ver}"

      cd "${HOLON_API_UTILS_REPOSITORY}" >/dev/null || return
    
        git_repo_update "origin/${BRANCH}"

      execute "yarn" "install"

    ) || exit 1
  ) || echo 'holon-utils is up to date'
# save the latest version in config
ohai "Track Zerotheft-Holon version"
  tmp=$(mktemp)
  jq -M ". + {\"HOLON_API_VERSION\":\"${required_api_ver}\", \"HOLON_UI_VERSION\":\"${required_ui_ver}\",\"HOLON_UTILS_VERSION\":\"${required_utils_ver}\",\"VERSION_TIMESTAMP\":${TIMESTAMP}}" ${CONFIG} > "$tmp" && mv "$tmp" $CONFIG

ohai "Update Complete"
echo

ohai "Re-starting Zerotheft-Holon"
(
  cd "${HOLON_API_REPOSITORY}" >/dev/null || return
  execute "yarn" "run-${ENV}"
)