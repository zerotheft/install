#!/bin/bash
set -u

abort() {
  printf "%s\n" "$@"
  exit 1
}

# check if environment is passed
if [ $# -gt 0 ]; then  ENV="$1"; else ENV="production"; fi

# check if passed environment is either private or staging or production
if  [[ $ENV != @(private|staging|production) ]]; then
  abort "Environment should be private or staging or production"
fi

if [ -z "${BASH_VERSION:-}" ]; then
  abort "Bash is required to interpret this script."
fi


# First check OS.
OS="$(uname)"
if ! [[ "$OS" == "Linux" ]]; then
  abort "Zerotheft-Holon installation is only supported on Linux."
fi

HOLON_PREFIX="${HOME}/.zerotheft"
HOLON_API_GIT_NAME="zerotheft/zerotheft-holon-node"
HOLON_UI_GIT_NAME="zerotheft/zerotheft-holon-react"
HOLON_API_UTILS_GIT_NAME="zerotheft/zerotheft-node-utils"
HOLON_API_GIT_REMOTE="https://github.com/${HOLON_API_GIT_NAME}" 
HOLON_UI_GIT_REMOTE="https://github.com/${HOLON_UI_GIT_NAME}"
HOLON_UTILS_GIT_REMOTE="https://github.com/${HOLON_API_UTILS_GIT_NAME}"
HOLON_REPOSITORY="${HOLON_PREFIX}/Zerotheft-Holon"
HOLON_API_REPOSITORY="${HOLON_REPOSITORY}/holon-api"
HOLON_API_UTILS_REPOSITORY="${HOLON_REPOSITORY}/holon-api/sub-modules/zerotheft-node-utils"
HOLON_UI_REPOSITORY="${HOLON_REPOSITORY}/holon-ui"
BRANCH="private-blockchainv2.0"

CHOWN="/bin/chown"
GROUP="$(id -gn)"

CONFIG="${HOLON_PREFIX}/config.json"
ENV_FILE="${HOLON_PREFIX}/.zt/env.json" 
INTEGRITY_PROFILE="${HOLON_PREFIX}/integrity_profile.json"
INTEGRITY_PROFILE_YAML="${HOLON_PREFIX}/integrity_profile.yaml"
CRON_LOG="${HOLON_PREFIX}/update.log"
UPDATE_SCRIPT='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/zerotheft/install/${BRANCH}/update.sh)"'

# AUTO_UPDATE=true
# DEPENDENCIES_REINSTALL=true
TIMESTAMP=$(date "+%s")

# fetch the latest tag name of a repo
get_latest_version(){
  cmd="$(curl --silent "https://api.github.com/repos/$1/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')"
  echo "${cmd}"
  # echo 1.0.0
}


# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

have_sudo_access() {
  local -a args
  # if [[ -n "${SUDO_ASKPASS-}" ]]; then
  #   args=("-A")
  # fi
  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]; then
    if [[ -n "${args[*]-}" ]]; then
      SUDO="/usr/bin/sudo ${args[*]}"
    else
      SUDO="/usr/bin/sudo"
    fi
    
    ${SUDO} -v && ${SUDO} -l mkdir &>/dev/null
    HAVE_SUDO_ACCESS="$?"
  fi

  return "$HAVE_SUDO_ACCESS"
}

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

execute_sudo() {
  local -a args=("$@")
    
  # if have_sudo_access; then
    # if [[ -n "${SUDO_ASKPASS-}" ]]; then
    #   args=("-A" "${args[@]}")
    # fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  # else
  #   ohai "${args[@]}"
  #   execute "${args[@]}"
  # fi
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")"
}

getc() {
  local save_state
  save_state=$(/bin/stty -g)
  /bin/stty raw -echo
  IFS= read -r -n 1 -d '' "$@"
  /bin/stty "$save_state"
}

wait_for_user() {
  local c
  echo
  echo "Press ENTER to continue or any other key to abort"
  getc c
  # we test for \r and \n because some stuff does \r instead
  if ! [[ "$c" == $'\r' || "$c" == $'\n' ]]; then
    exit 1
  fi
}
# repo setup from git
git_repo_setup(){
  # we do it in four steps to avoid merge errors when reinstalling
  execute "git" "init" "-q"

  # "git remote add" will fail if the remote is defined in the global config
  execute "git" "config" "remote.origin.url" "$1"
  execute "git" "config" "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"

  # ensure we don't munge line endings on checkout
  execute "git" "config" "core.autocrlf" "false"

  execute "git" "fetch" "--force" "origin"
  execute "git" "fetch" "--force" "--tags" "origin"

  execute "git" "reset" "--hard" "$2"   
}

# Peroform Zerotheft-Holon installation only when
# releases are found in github for every pacakges
ohai "Checking releases for installation"
  # get the version of holon-api
  HOLON_API_VERSION=$(get_latest_version "${HOLON_API_GIT_NAME}")
  # get the version of holon-api utils
  HOLON_UTILS_VERSION=$(get_latest_version "${HOLON_API_UTILS_GIT_NAME}")
  # get the version of holon-ui
  HOLON_UI_VERSION=$(get_latest_version "${HOLON_UI_GIT_NAME}")

  if [[ -z "$HOLON_API_VERSION" ]] || [[ -z "$HOLON_UTILS_VERSION" ]] || [[ -z "$HOLON_UI_VERSION" ]]; then
    abort "Releases missing. Couldnot install Zerotheft-Holon"
  fi
  echo "OK"
directories=(.zt tmp zt_report/input_jsons .cache public/exports Zerotheft-Holon/holon-api Zerotheft-Holon/holon-ui)
mkdirs=()
for dir in "${directories[@]}"; do
  if ! [[ -d "${HOLON_PREFIX}/${dir}" ]]; then
    mkdirs+=("${HOLON_PREFIX}/${dir}")
  fi
done

ohai "Running script of ${ENV} environment"
echo

ohai "This script will install:"
  echo " - ${HOLON_API_GIT_NAME}: ${HOLON_API_VERSION}"
  echo " - ${HOLON_UI_GIT_NAME}: ${HOLON_UI_VERSION}"
  echo " - ${HOLON_API_UTILS_GIT_NAME}: ${HOLON_UTILS_VERSION}"

if [[ "${#mkdirs[@]}" -gt 0 ]]; then
  ohai "The following new directories will be created:"
  printf "%s\n" "${mkdirs[@]}"
fi

wait_for_user

if ! [[ -d "${HOLON_PREFIX}" ]]; then
  execute "/bin/mkdir" "-p" "${HOLON_PREFIX}"  
  execute "$CHOWN" "$USER:$GROUP" "${HOLON_PREFIX}"
fi

if [[ "${#mkdirs[@]}" -gt 0 ]]; then
  execute "/bin/mkdir" "-p" "${mkdirs[@]}"
  execute "$CHOWN" "$USER:$GROUP" "${mkdirs[@]}"
fi

# check if backend repo already cloned
if ! [[ -d "${HOLON_API_REPOSITORY}" ]]; then
  execute "/bin/mkdir" "-p" "${HOLON_API_REPOSITORY}"
fi
execute_sudo "$CHOWN" "-R" "$USER:$GROUP" "${HOLON_API_REPOSITORY}"

# check if frontend repo already cloned
if ! [[ -d "${HOLON_UI_REPOSITORY}" ]]; then
  execute "/bin/mkdir" "-p" "${HOLON_UI_REPOSITORY}"
fi
execute_sudo "$CHOWN" "-R" "$USER:$GROUP" "${HOLON_UI_REPOSITORY}"

execute_sudo "apt" "update"
sleep 5
# install if git is not installed
if ! command -v git >/dev/null; then
  ohai "- Installing git:"
  if [[ $(command -v apt-get) ]]; then
    execute_sudo "apt" "install" "-y" "git"
  elif [[ $(command -v yum) ]]; then
    execute_sudo "yum" "install" "-y" "git"
  elif [[ $(command -v pacman) ]]; then
    execute_sudo "pacman" "-S" "-y" "git"
  elif [[ $(command -v apk) ]]; then
    execute_sudo "apk" "add" "-y" "git"
  fi
fi

# install if node is not installed
if ! command -v node >/dev/null; then
  ohai "Installing nodejs:"
  if [[ $(command -v apt-get) ]]; then
    "$(curl -fsSL https://deb.nodesource.com/setup_15.x | sudo -E bash -)"
    execute_sudo "apt" "install" "-y" "nodejs"
  elif [[ $(command -v yum) ]]; then
    execute_sudo "yum" "install" "nodejs" "-y"
  elif [[ $(command -v pacman) ]]; then
    execute_sudo "pacman" "-S" "-y" "nodejs" "npm"
    elif [[ $(command -v dnf) ]]; then
    execute_sudo "dnf" "install" "-y" "nodejs" "npm"
  elif [[ $(command -v apk) ]]; then
    execute_sudo "apk" "add" "--update" "-y" "nodejs" "npm"
  fi
fi

# install if jq is not installed
if ! command -v jq >/dev/null; then
  ohai "Installing jq:"
  if [[ $(command -v apt-get) ]]; then
    execute_sudo "apt" "install" "-y" "jq"
  elif [[ $(command -v yum) ]]; then
    execute_sudo "yum" "install" "jq" "-y"
  elif [[ $(command -v pacman) ]]; then
    execute_sudo "pacman" "-S" "-y" "jq"
    elif [[ $(command -v dnf) ]]; then
    execute_sudo "dnf" "install" "-y" "jq"
  elif [[ $(command -v apk) ]]; then
    execute_sudo "apk" "add" "--update" "jq"
  fi
fi

# install if redis-server is not installed
if ! command -v redis-server >/dev/null; then
  ohai "Installing redis-server:"
  if [[ $(command -v apt-get) ]]; then
    execute_sudo "add-apt-repository" "ppa:chris-lea/redis-server" "-y"
    execute_sudo "apt" "install" "-y" "redis-server"
  elif [[ $(command -v yum) ]]; then
    execute_sudo "yum" "install" "redis" "-y"
  elif [[ $(command -v pacman) ]]; then
    execute_sudo "pacman" "-S" "redis-server"
    elif [[ $(command -v dnf) ]]; then
    execute_sudo "dnf" "install" "redis-server"
  elif [[ $(command -v apk) ]]; then
    execute_sudo "apk" "add" "--update" "redis-server"
  fi
fi

# install if pygments is not installed
if ! command -v  pygmentize >/dev/null; then
  ohai "Installing python3-pygments:"
  if [[ $(command -v apt-get) ]]; then
    execute_sudo "apt" "install" "-y" "python3-pygments"
  elif [[ $(command -v yum) ]]; then
    execute_sudo "yum" "install" "python3-pygments" "-y"
  elif [[ $(command -v pacman) ]]; then
    execute_sudo "pacman" "-S" "-y" "python3-pygments"
    elif [[ $(command -v dnf) ]]; then
    execute_sudo "dnf" "install" "-y" "python3-pygments"
  elif [[ $(command -v apk) ]]; then
    execute_sudo "apk" "add" "--update" "python3-pygments"
  fi
fi

# install if yarn is not installed
if ! command -v yarn >/dev/null; then
  ohai "Installing yarn:"  
  execute_sudo "npm" "install" "--global" "yarn"
fi

# install latex dependency
if ! command -v latex >/dev/null; then
  ohai "Installing texlive"
    execute_sudo "apt" "install" "texlive-latex-extra" "-y"
  ohai "Installing pgf-pie"
    wget "https://mirrors.ctan.org/graphics/pgf/contrib/pgf-pie.zip"
    execute_sudo "unzip" "-d" "/usr/share/texlive/texmf-dist/tex/latex" "pgf-pie.zip"
    execute_sudo "mktexlsr"
    execute_sudo "rm" "pgf-pie.zip"
fi

# start installation
# It will git fetch zerotheft-holon-node, zerotheft-holon-react and zerotheft-node-utils packages from github
ohai "Downloading and installing Zerotheft-Holon."
(
  cd "${HOLON_UI_REPOSITORY}" >/dev/null || return
    ohai "Tapping holon-ui"
      # setup github repo 
      git_repo_setup "${HOLON_UI_GIT_REMOTE}" "origin/${BRANCH}"
      execute "yarn" "install"  
      execute "cp" "src/config.${ENV}.json.example" "src/config.${ENV}.json"
      execute "yarn" "build-${ENV}"

  #move build to different directory but first clear the existing one
  if ! [[ -d "${HOLON_PREFIX}/build" ]]; then
    execute "rm" "-rf" "${HOLON_PREFIX}/build"
  fi
  execute "cp" "-R" "build/" "${HOLON_PREFIX}"
  execute "rm" "-rf" "build/*"  

) || exit 1


(
  cd "${HOLON_API_REPOSITORY}" >/dev/null || return
    ohai "Tapping holon-api"  
      git_repo_setup "${HOLON_API_GIT_REMOTE}" "origin/${BRANCH}"

  # look if submodules is installed or not; otherwise install
  cd "${HOLON_API_UTILS_REPOSITORY}" >/dev/null || return
    ohai "Tapping holon-api/sub-modules/zerotheft-node-utils"
    
      git_repo_setup "${HOLON_UTILS_GIT_REMOTE}" "origin/${BRANCH}"
      execute "yarn" "install"  
     
  cd "${HOLON_API_REPOSITORY}" >/dev/null || return

    execute "cp" "config.${ENV}.json.example" "config.${ENV}.json"
    execute "yarn" "install"

    # activate zt-holon command
    execute_sudo "npm" "link"


) || exit 1

# Prompt for user inputs if config doesn't exist
# It will asks holon_url, port
if ! [[ -f "${CONFIG}" ]]; then
  ohai "Provide information to start HOLON"

  read -p "- ${tty_bold}Enter Your Holon URL${tty_reset}(eg: ${tty_underline}http://<holon_url>${tty_reset}): " holon_address
  read -p "- ${tty_bold}Enter PORT${tty_reset}: " port

  valid_yaml=false
  while [ "$valid_yaml" != true ]
  do
    read -p "- ${tty_bold}Enter a valid url for integrity profile${tty_reset}: " integrity_profile
    content=$(curl -L "$integrity_profile")
    json_validator=$(curl -X POST  --data "data=$(cat "$content")" https://www.lint-trilogy.com/lint/yaml/json)
    valid_yaml=$(echo "$json_validator" | jq -r '.valid')
    echo "$valid_yaml"
    if [ "$valid_yaml" != true ]; then
      warn "Please have a valid yaml in the given link"
    fi
    echo "$content" >> "$INTEGRITY_PROFILE_YAML"
  done
  echo "{ \"PROFILE_URL\": \"$integrity_profile\" }" >> "$INTEGRITY_PROFILE"

  # Check the holon address is empty or not
  if [ "$holon_address" != "" ]; then
    #remove trailing slash from url
    [[ "${holon_address}" == */ ]] && holon_address="${holon_address: : -1}"  
    
    ohai "Track Zerotheft-Holon version"
      # keep information recorded in config.json
      echo "{ \"BASE_URL\": \"$holon_address\",\"APP_URL\": \"$holon_address\", \"PORT\":$port, \"AUTO_UPDATE\":\"true\",\"VERSION_TIMESTAMP\":$TIMESTAMP,\"HOLON_API_VERSION\":\"$HOLON_API_VERSION\",\"HOLON_UI_VERSION\":\"$HOLON_UI_VERSION\",\"HOLON_UTILS_VERSION\":\"$HOLON_UTILS_VERSION\" }" >> "$CONFIG"
  fi

  # write environment value in env.json
  ohai "Setting up ${ENV} environment"
    echo "{\"MODE\": \"$ENV\"}" >> "${ENV_FILE}"
else
  port=$(jq .PORT "${CONFIG}")
  # AUTO_UPDATE=$(jq .AUTO_UPDATE ${CONFIG})
  # DEPENDENCIES_REINSTALL=false
fi

# find and replace port in config file 
# Zerotheft-Holon will star in this port
sed -i "s/40107/$port/" "${HOLON_API_REPOSITORY}/config.${ENV}.json"

ohai "Installation successful!"
echo

# After successful install holon will run in user given holon_url and port
ohai "Starting Zerotheft-Holon"
(
  cd "${HOLON_API_REPOSITORY}" >/dev/null || return
  execute "yarn" "run-${ENV}"
)

# Add cron job that checks if new release is made in github and do auto update
# Auto update is only possible if AUTO_UPDATE key is true in config
# Cron will run every 4 HOURS
ohai 'Add updater cron if not present'
  (crontab -l | grep "${UPDATE_SCRIPT} >> ${CRON_LOG} 2>&1" || echo "0 */3 * * *  ${UPDATE_SCRIPT}  >> ${CRON_LOG} 2>&1") | crontab -

