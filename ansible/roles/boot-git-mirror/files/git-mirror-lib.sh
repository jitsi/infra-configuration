#!/bin/bash
# git-mirror-lib.sh: shared clone logic for the on-disk boot scripts (JIT-16092)
#
# Installed at /opt/jitsi/boot/git-mirror-lib.sh by the boot-git-mirror role and
# sourced by every configure-*-local*.sh under /usr/local/bin. It clones
# infra-configuration and infra-customizations into $BOOTSTRAP_DIRECTORY from the
# in-region Gitea mirror when the instance booted with one, and from github
# otherwise. The mirror is an optimisation and github is the floor: nothing in
# here is fatal because of the mirror, and checkout_repos only fails when github
# fails too.
#
# The semantics are copied from infra-provisioning's terraform/lib/postinstall-lib.sh,
# the copy inlined into cloud-init user-data, which is the reference implementation.
# Keep the two in step: a second copy of the boot logic drifting out of sync is
# exactly why this file exists.
#
# Where GIT_MIRROR_HOST comes from on an instance, in order:
#   1. the environment, when this script is a child of the cloud-init user-data
#      that exported it (first boot);
#   2. $GIT_MIRROR_HOST_FILE, written by infra-provisioning's user-data
#      (record_git_mirror_host in terraform/lib/postinstall-lib.sh, called from
#      postinstall-footer.sh so it covers every stack), so reconfigures and later
#      boots, which inherit nothing, make the same decision. This is the path
#      that matters: the jvb and jibri postinstalls are invoked through sudo,
#      which resets the environment, so for them case 1 never happens at all;
#   3. otherwise no mirror. An empty file is case 3, said explicitly.
# "auto" derives $ENVIRONMENT-$ORACLE_REGION-git.$GIT_MIRROR_DNS_ZONE; the -oracle
# scripts get both from /usr/local/bin/oracle_cache.sh. The region gate (mirrors
# exist only in an environment's NOMAD_REGIONS) runs when the stack is created,
# so a recorded "auto" only appears on instances in a region that has a mirror.
#
# The read-only credential for the private repo is read from the boot bucket on
# every run and handed to the one git clone of the mirror host through that
# process's environment and a per-command credential helper (infra-provisioning
# #1202). It is never written to a file: a /root/.netrc breaks nomad's
# unprivileged artifact getter on nodes that keep credentials across
# reconfiguration, so a leftover one is removed on every run.
#
# Everything here is safe under set -e, set -x and bash -v: failures are return
# codes, and the password never enters the trace.

: "${BOOTSTRAP_DIRECTORY:=/tmp/bootstrap}"
: "${LOCAL_REPO_DIRECTORY:=/opt/jitsi/bootstrap}"
: "${GIT_MIRROR_HOST_FILE:=/opt/jitsi/boot/git-mirror-host}"
: "${GIT_MIRROR_DNS_ZONE:=jitsi.net}"
: "${GIT_MIRROR_ORG:=jitsi}"
# what the regional mirrors host; anything else is cloned from github without a mirror attempt
: "${GIT_MIRROR_REPOS:=infra-configuration infra-customizations-private infra-provisioning}"
: "${OCI_BIN:=/usr/local/bin/oci}"
# optional inputs, so the library is also safe under set -u
: "${INFRA_CONFIGURATION_MIRROR_REPO:=}"
: "${INFRA_CUSTOMIZATIONS_MIRROR_REPO:=}"
: "${GIT_FALLBACK_BRANCH:=}"
: "${ENVIRONMENT:=}"
: "${ORACLE_REGION:=}"
MIRROR_GIT_HOST=
MIRROR_GIT_USERNAME=
MIRROR_GIT_PASSWORD=

function loggable_git_url() {
  echo "$1" | sed -E 's#(://)[^@/]*@#\1#'
}

function git_url_host() {
  echo "$1" | sed -E 's#^[a-z]+://([^@/]*@)?([^/:]+).*#\2#'
}

# Decide where GIT_MIRROR_HOST comes from for this run. Exactly one line per outcome.
function resolve_git_mirror_host() {
  if [ -n "${GIT_MIRROR_HOST+set}" ]; then
    if [ -n "$GIT_MIRROR_HOST" ]; then
      echo "Using GIT_MIRROR_HOST=$GIT_MIRROR_HOST from the environment"
    else
      echo "GIT_MIRROR_HOST is set but empty, this stack is not opted into a git mirror; cloning from github"
    fi
    return 0
  fi
  if [ -f "$GIT_MIRROR_HOST_FILE" ]; then
    GIT_MIRROR_HOST="$(head -n1 "$GIT_MIRROR_HOST_FILE" | tr -d '[:space:]')"
    if [ -n "$GIT_MIRROR_HOST" ]; then
      echo "Using GIT_MIRROR_HOST=$GIT_MIRROR_HOST from $GIT_MIRROR_HOST_FILE"
    else
      echo "$GIT_MIRROR_HOST_FILE is empty, this instance booted without a git mirror; cloning from github"
    fi
    return 0
  fi
  GIT_MIRROR_HOST=""
  echo "No GIT_MIRROR_HOST in the environment and no $GIT_MIRROR_HOST_FILE; cloning from github"
  return 0
}

# Mirror URL for a github URL, or nothing when the mirror does not host that repo.
# Explicit list rather than basename alone: the scripts' default customizations
# repo is the public infra-customizations, which the mirror does not have.
function mirror_url_for_repo() {
  local origin_url="$1" name
  [ -z "$origin_url" ] && return 0
  name="$(basename "$origin_url" .git)"
  [[ " $GIT_MIRROR_REPOS " == *" $name "* ]] || return 0
  echo "https://$GIT_MIRROR_RESOLVED_HOST/$GIT_MIRROR_ORG/$name.git"
  return 0
}

# Turn GIT_MIRROR_HOST into INFRA_CONFIGURATION_MIRROR_REPO / INFRA_CUSTOMIZATIONS_MIRROR_REPO.
# No-op without a host. "auto" needs ENVIRONMENT and ORACLE_REGION or bails to github.
function configure_mirror_repos() {
  GIT_MIRROR_RESOLVED_HOST=""
  [ -z "${GIT_MIRROR_HOST:-}" ] && return 0
  if [ "$GIT_MIRROR_HOST" == "auto" ]; then
    if [ -z "$ENVIRONMENT" ] || [ -z "$ORACLE_REGION" ]; then
      echo "GIT_MIRROR_HOST=auto but ENVIRONMENT or ORACLE_REGION is unset, not using a mirror"
      return 0
    fi
    GIT_MIRROR_RESOLVED_HOST="$ENVIRONMENT-$ORACLE_REGION-git.$GIT_MIRROR_DNS_ZONE"
  else
    GIT_MIRROR_RESOLVED_HOST="$GIT_MIRROR_HOST"
  fi
  if [ -z "$INFRA_CONFIGURATION_MIRROR_REPO" ]; then
    INFRA_CONFIGURATION_MIRROR_REPO="$(mirror_url_for_repo "$INFRA_CONFIGURATION_REPO")"
  fi
  if [ -z "$INFRA_CUSTOMIZATIONS_MIRROR_REPO" ]; then
    INFRA_CUSTOMIZATIONS_MIRROR_REPO="$(mirror_url_for_repo "$INFRA_CUSTOMIZATIONS_REPO")"
  fi
  echo "Using git mirror $GIT_MIRROR_RESOLVED_HOST"
  if [ -z "$INFRA_CONFIGURATION_MIRROR_REPO" ]; then
    echo "The mirror does not host $(basename "$INFRA_CONFIGURATION_REPO" .git) (it hosts: $GIT_MIRROR_REPOS); cloning infra-configuration from github"
  fi
  if [ -z "$INFRA_CUSTOMIZATIONS_MIRROR_REPO" ]; then
    echo "The mirror does not host $(basename "$INFRA_CUSTOMIZATIONS_REPO" .git) (it hosts: $GIT_MIRROR_REPOS); cloning infra-customizations from github"
  fi
  return 0
}

# Read-only mirror user for the private repo: bucket -> shell variables that only
# the clone of the mirror host ever sees. Never a URL, never a file. No creds => github.
function fetch_mirror_credentials() {
  # earlier revisions wrote this credential to /root/.netrc; nomad's artifact
  # getter runs unprivileged with HOME=/root and fails every download when it
  # finds a root-owned netrc it cannot read, so a leftover one is removed on
  # every run, mirror or not
  rm -f /root/.netrc
  MIRROR_GIT_HOST=
  MIRROR_GIT_USERNAME=
  MIRROR_GIT_PASSWORD=
  [ -z "$INFRA_CUSTOMIZATIONS_MIRROR_REPO" ] && return 0
  if [ -z "$ENVIRONMENT" ]; then
    echo "ENVIRONMENT is unset, cannot read mirror credentials from the boot bucket; the private repo will come from github"
    return 0
  fi
  if ! command -v "$OCI_BIN" >/dev/null 2>&1; then
    echo "No OCI CLI at $OCI_BIN, cannot read mirror credentials from the boot bucket; the private repo will come from github"
    return 0
  fi
  local bucket="jvb-bucket-${ENVIRONMENT}"
  local creds_file mirror_host
  mirror_host=$(git_url_host "$INFRA_CUSTOMIZATIONS_MIRROR_REPO")
  if [ -z "$mirror_host" ]; then
    echo "Could not read a hostname from the mirror URL, not fetching mirror credentials"
    return 0
  fi
  # a private (0600) scratch file that lives only until jq has read it
  creds_file="$(mktemp "${TMPDIR:-/tmp}/gitea-read-user.XXXXXX")" || return 0
  if ! "$OCI_BIN" os object get -bn "$bucket" --name gitea-read-user --file "$creds_file" >/dev/null 2>&1; then
    echo "No gitea-read-user in $bucket; the private repo will come from github"
    rm -f "$creds_file"
    return 0
  fi
  # keep the password out of the set -x trace
  local xtrace=false
  [[ $- == *x* ]] && xtrace=true
  set +x
  local username password
  username=$(jq -r '.username // empty' "$creds_file" 2>/dev/null || true)
  password=$(jq -r '.password // empty' "$creds_file" 2>/dev/null || true)
  rm -f "$creds_file"
  if [ -z "$username" ] || [ -z "$password" ]; then
    [ "$xtrace" == "true" ] && set -x
    echo "gitea-read-user in $bucket has no username or password; the private repo will come from github"
    return 0
  fi
  MIRROR_GIT_HOST="$mirror_host"
  MIRROR_GIT_USERNAME="$username"
  MIRROR_GIT_PASSWORD="$password"
  [ "$xtrace" == "true" ] && set -x
  echo "Holding mirror credentials for $username at $mirror_host for this run's clones"
  return 0
}

function forget_mirror_credentials() {
  MIRROR_GIT_HOST=
  MIRROR_GIT_USERNAME=
  MIRROR_GIT_PASSWORD=
}

# git clone at boot: there is no terminal, so fail instead of waiting on a prompt.
# For the mirror host the read-only credential rides along in this one git
# process only: a credential helper reads it from git's environment, so it is
# never in argv (ps, set -x), never on disk, and never offered to github.
function git_clone_for_boot() {
  local url="$1"
  local target="$2"
  if [ -z "${MIRROR_GIT_PASSWORD:+set}" ] || [ "$(git_url_host "$url")" != "$MIRROR_GIT_HOST" ]; then
    GIT_TERMINAL_PROMPT=0 git clone "$url" "$target"
    return $?
  fi
  # the environment prefix would be expanded into the set -x trace
  local xtrace=false
  [[ $- == *x* ]] && xtrace=true
  set +x
  echo "+ git clone $(loggable_git_url "$url") $target  (mirror credential from the environment, trace off)"
  local rc=0
  GIT_TERMINAL_PROMPT=0 MIRROR_GIT_USERNAME="$MIRROR_GIT_USERNAME" MIRROR_GIT_PASSWORD="$MIRROR_GIT_PASSWORD" \
    git -c credential.helper= \
        -c 'credential.helper=!f() { if [ "$1" = get ]; then printf "username=%s\npassword=%s\n" "$MIRROR_GIT_USERNAME" "$MIRROR_GIT_PASSWORD"; fi; }; f' \
        clone "$url" "$target" || rc=$?
  [ "$xtrace" == "true" ] && set -x
  return $rc
}

# Clone, check out the ref, and prove the ref exists. Non-zero on any failure so
# the caller can fall back.
function clone_repo_at_ref() {
  local url="$1"
  local target="$2"
  local ref="$3"
  [ -z "$url" ] && return 1
  [ -z "$target" ] && return 1
  rm -rf "$target"
  git_clone_for_boot "$url" "$target" || return 1
  git -C "$target" checkout "$ref" || return 1
  # neither infra repo has submodules; if one grows some they fetch from the URL
  # in .gitmodules, not through the mirror credential
  git -C "$target" submodule update --init --recursive || return 1
  git -C "$target" show-ref "heads/$ref" || git -C "$target" show-ref "tags/$ref" || return 1
  return 0
}

# Mirror first when there is one, github on any mirror failure. Never fatal
# because of the mirror; fails only when github fails too.
function clone_repo_with_fallback() {
  local name="$1"
  local mirror_url="$2"
  local origin_url="$3"
  local target="$4"
  local ref="$5"
  if [ -n "$mirror_url" ]; then
    echo "Cloning $name at $ref from the in-region mirror $(loggable_git_url "$mirror_url")"
    if clone_repo_at_ref "$mirror_url" "$target" "$ref"; then
      echo "Cloned $name at $ref from the in-region mirror"
      return 0
    fi
    echo "WARNING: mirror clone of $name at $ref failed, falling back to github"
  fi
  echo "Cloning $name at $ref from $(loggable_git_url "$origin_url")"
  if clone_repo_at_ref "$origin_url" "$target" "$ref"; then
    echo "Cloned $name at $ref from github"
    return 0
  fi
  echo "Failed to clone $name at $ref from github"
  return 1
}

# One infra repo at $GIT_BRANCH, mirror then github. When GIT_FALLBACK_BRANCH is
# set (the jvb and jigasi oracle scripts use main) and $GIT_BRANCH exists in
# neither source, the same sources are tried again at that branch, which is what
# those scripts always did.
function clone_infra_repo() {
  local name="$1"
  local mirror_url="$2"
  local origin_url="$3"
  local target="$BOOTSTRAP_DIRECTORY/$name"
  clone_repo_with_fallback "$name" "$mirror_url" "$origin_url" "$target" "$GIT_BRANCH" && return 0
  if [ -n "$GIT_FALLBACK_BRANCH" ] && [ "$GIT_FALLBACK_BRANCH" != "$GIT_BRANCH" ]; then
    echo "WARNING: could not get $name at $GIT_BRANCH from any source, trying $GIT_FALLBACK_BRANCH"
    clone_repo_with_fallback "$name" "$mirror_url" "$origin_url" "$target" "$GIT_FALLBACK_BRANCH" && return 0
  fi
  return 1
}

# Fresh copies of both infra repos in $BOOTSTRAP_DIRECTORY, customizations laid
# over configuration. Uses INFRA_CONFIGURATION_REPO, INFRA_CUSTOMIZATIONS_REPO
# and GIT_BRANCH from the caller. Returns non-zero only when a repo could not be
# had from any source; call it as "if ! checkout_repos" so set -e does not fire
# inside it.
function checkout_repos() {
  if [ -z "$BOOTSTRAP_DIRECTORY" ]; then
    echo "No BOOTSTRAP_DIRECTORY set, refusing to check out repos"
    return 1
  fi
  if [ -z "${INFRA_CONFIGURATION_REPO:-}" ] || [ -z "${INFRA_CUSTOMIZATIONS_REPO:-}" ]; then
    echo "INFRA_CONFIGURATION_REPO or INFRA_CUSTOMIZATIONS_REPO is unset, refusing to check out repos"
    return 1
  fi
  : "${GIT_BRANCH:=main}"
  rm -rf "$BOOTSTRAP_DIRECTORY/infra-configuration" "$BOOTSTRAP_DIRECTORY/infra-customizations"
  mkdir -p "$BOOTSTRAP_DIRECTORY" || return 1
  # the github fallback may still be an ssh URL
  if ! grep -q "^github.com " ~/.ssh/known_hosts 2>/dev/null; then
    mkdir -p ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
  fi
  if [ -d "$LOCAL_REPO_DIRECTORY" ]; then
    echo "Found local repo copies in $LOCAL_REPO_DIRECTORY, setting GIT_ALTERNATE_OBJECT_DIRECTORIES"
    export GIT_ALTERNATE_OBJECT_DIRECTORIES="$LOCAL_REPO_DIRECTORY/infra-configuration/.git/objects:$LOCAL_REPO_DIRECTORY/infra-customizations/.git/objects"
  fi
  resolve_git_mirror_host
  configure_mirror_repos
  fetch_mirror_credentials
  local status_code=0
  clone_infra_repo "infra-configuration" "$INFRA_CONFIGURATION_MIRROR_REPO" "$INFRA_CONFIGURATION_REPO" || status_code=1
  if [ $status_code -eq 0 ]; then
    clone_infra_repo "infra-customizations" "$INFRA_CUSTOMIZATIONS_MIRROR_REPO" "$INFRA_CUSTOMIZATIONS_REPO" || status_code=1
  fi
  forget_mirror_credentials
  [ $status_code -ne 0 ] && return 1
  cp -a "$BOOTSTRAP_DIRECTORY/infra-customizations/"* "$BOOTSTRAP_DIRECTORY/infra-configuration" || return 1
  return 0
}
