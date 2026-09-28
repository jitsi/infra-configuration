#!/usr/bin/env bash
# Zero-infrastructure tests for git-mirror-lib.sh: local bare repos stand in for
# github, an unroutable https host stands in for a broken mirror, a fake oci and
# a fake "mirror" served over file:// stand in for the bucket and Gitea.
set -u
LIB="${1:-$(cd "$(dirname "$0")/.." && pwd)/files/git-mirror-lib.sh}"
T=$(mktemp -d); export T
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1 :: $2"; fi; }

# ---- fixtures: two "github" repos with main + release branch and a tag
mk_repo() {
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  echo "$(basename "$d") main" > "$d/README"; mkdir -p "$d/ansible"; echo x > "$d/ansible/$(basename "$d").yml"
  git -C "$d" add -A; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$d" branch release-1234; git -C "$d" tag v1
}
mk_repo "$T/github/infra-configuration"
mk_repo "$T/github/infra-customizations-private"
GH_CONF="file://$T/github/infra-configuration.git";  mv "$T/github/infra-configuration/.git" "$T/github/infra-configuration.git"
GH_CUST="file://$T/github/infra-customizations-private.git"; mv "$T/github/infra-customizations-private/.git" "$T/github/infra-customizations-private.git"
# a fake HOME so ~/.ssh and any stray netrc land here, and a fake /root netrc target is not touched
export HOME="$T/home"; mkdir -p "$HOME/.ssh"

run_in_subshell() { # $1 = name, rest = env assignments + commands evaluated after sourcing the lib
  ( set -e; export BOOTSTRAP_DIRECTORY="$T/bootstrap-$1"; export GIT_MIRROR_HOST_FILE="$T/host-file-$1"
    eval "$2"; . "$LIB"; eval "$3" ) 
}

echo "== 1. auto derives the mirror URLs from ENVIRONMENT/ORACLE_REGION"
out=$(run_in_subshell t1 'export GIT_MIRROR_HOST=auto ENVIRONMENT=stage-8x8 ORACLE_REGION=us-phoenix-1 INFRA_CONFIGURATION_REPO=https://github.com/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=git@github.com:jitsi/infra-customizations-private.git' \
  'resolve_git_mirror_host; configure_mirror_repos; echo "CONF=$INFRA_CONFIGURATION_MIRROR_REPO"; echo "CUST=$INFRA_CUSTOMIZATIONS_MIRROR_REPO"')
echo "$out" | sed 's/^/     /'
check "derived infra-configuration URL" '[[ "$out" == *"CONF=https://stage-8x8-us-phoenix-1-git.jitsi.net/jitsi/infra-configuration.git"* ]]'
check "derived private customizations URL from ssh github URL" '[[ "$out" == *"CUST=https://stage-8x8-us-phoenix-1-git.jitsi.net/jitsi/infra-customizations-private.git"* ]]'
check "logs the environment as the source" '[[ "$out" == *"Using GIT_MIRROR_HOST=auto from the environment"* ]]'

echo "== 2. auto without ORACLE_REGION bails to github"
out=$(run_in_subshell t2 'export GIT_MIRROR_HOST=auto ENVIRONMENT=stage-8x8 INFRA_CONFIGURATION_REPO=https://github.com/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=https://github.com/jitsi/infra-customizations-private.git' \
  'resolve_git_mirror_host; configure_mirror_repos; echo "CONF=[$INFRA_CONFIGURATION_MIRROR_REPO] CUST=[$INFRA_CUSTOMIZATIONS_MIRROR_REPO]"')
echo "$out" | sed 's/^/     /'
check "bails with one line" '[[ "$out" == *"ORACLE_REGION is unset, not using a mirror"* ]]'
check "no mirror URLs" '[[ "$out" == *"CONF=[] CUST=[]"* ]]'

echo "== 3. the public infra-customizations default is not mirrored, explicitly"
out=$(run_in_subshell t3 'export GIT_MIRROR_HOST=mirror.example ENVIRONMENT=e ORACLE_REGION=r INFRA_CONFIGURATION_REPO=https://github.com/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=https://github.com/jitsi/infra-customizations.git' \
  'resolve_git_mirror_host; configure_mirror_repos; echo "CONF=[$INFRA_CONFIGURATION_MIRROR_REPO] CUST=[$INFRA_CUSTOMIZATIONS_MIRROR_REPO]"')
echo "$out" | sed 's/^/     /'
check "configuration mirrored from explicit host" '[[ "$out" == *"CONF=[https://mirror.example/jitsi/infra-configuration.git]"* ]]'
check "customizations not mirrored" '[[ "$out" == *"CUST=[]"* ]]'
check "says why" '[[ "$out" == *"The mirror does not host infra-customizations"* ]]'

echo "== 4. host file resolution when the environment has nothing"
out=$(run_in_subshell t4 'echo "auto" > "$GIT_MIRROR_HOST_FILE"; export ENVIRONMENT=beta ORACLE_REGION=uk-london-1 INFRA_CONFIGURATION_REPO=https://github.com/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=https://github.com/jitsi/infra-customizations-private.git' \
  'resolve_git_mirror_host; configure_mirror_repos; echo "HOST=$GIT_MIRROR_RESOLVED_HOST"')
echo "$out" | sed 's/^/     /'
check "reads the recorded value" '[[ "$out" == *"from $T/host-file-t4"* && "$out" == *"HOST=beta-uk-london-1-git.jitsi.net"* ]]'
out=$(run_in_subshell t4b ': > "$GIT_MIRROR_HOST_FILE"; export INFRA_CONFIGURATION_REPO=x INFRA_CUSTOMIZATIONS_REPO=y' 'resolve_git_mirror_host; configure_mirror_repos; echo "HOST=[$GIT_MIRROR_RESOLVED_HOST]"')
check "empty recorded file means no mirror" '[[ "$out" == *"is empty"* && "$out" == *"HOST=[]"* ]]'
out=$(run_in_subshell t4c 'export INFRA_CONFIGURATION_REPO=x INFRA_CUSTOMIZATIONS_REPO=y' 'resolve_git_mirror_host; configure_mirror_repos; echo "HOST=[$GIT_MIRROR_RESOLVED_HOST]"')
check "no env, no file means no mirror, one line" '[[ "$out" == *"No GIT_MIRROR_HOST in the environment and no"* && "$out" == *"HOST=[]"* ]]'
out=$(run_in_subshell t4d 'export GIT_MIRROR_HOST= INFRA_CONFIGURATION_REPO=x INFRA_CUSTOMIZATIONS_REPO=y' 'resolve_git_mirror_host; configure_mirror_repos; echo "HOST=[$GIT_MIRROR_RESOLVED_HOST]"')
check "set-but-empty env means not opted in" '[[ "$out" == *"set but empty"* && "$out" == *"HOST=[]"* ]]'

echo "== 5. full checkout_repos: unreachable mirror falls back to github and succeeds under set -e"
out=$(run_in_subshell t5 "export GIT_MIRROR_HOST=127.0.0.1:9 ENVIRONMENT=e ORACLE_REGION=r GIT_BRANCH=release-1234 INFRA_CONFIGURATION_REPO=$GH_CONF INFRA_CUSTOMIZATIONS_REPO=file://$T/github/infra-customizations-private.git OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo "CHECKOUT_FAILED"; exit 1; fi; echo "CHECKOUT_OK"; echo "BRANCH=$(git -C "$BOOTSTRAP_DIRECTORY/infra-configuration" rev-parse --abbrev-ref HEAD)/$(git -C "$BOOTSTRAP_DIRECTORY/infra-customizations" rev-parse --abbrev-ref HEAD)"; ls "$BOOTSTRAP_DIRECTORY/infra-configuration/ansible"' 2>&1)
echo "$out" | sed 's/^/     /'
check "returns success" '[[ "$out" == *"CHECKOUT_OK"* ]]'
check "warned about the mirror, once per repo" '[[ $(echo "$out" | grep -c "WARNING: mirror clone of .* failed, falling back to github") -eq 2 ]]'
check "both cloned from github" '[[ $(echo "$out" | grep -c "^Cloned .* from github$") -eq 2 ]]'
check "release branch checked out in both" '[[ "$out" == *"BRANCH=release-1234/release-1234"* ]]'
check "customizations overlaid onto configuration" '[[ "$out" == *"infra-customizations-private.yml"* && "$out" == *"infra-configuration.yml"* ]]'
check "no OCI CLI is a logged non-event" '[[ "$out" == *"No OCI CLI"* ]]'

echo "== 6. a working mirror (file:// stand-in) is used, github never contacted"
mkdir -p "$T/mirror/jitsi"; git clone -q --bare "$GH_CONF" "$T/mirror/jitsi/infra-configuration.git"; git clone -q --bare "$GH_CUST" "$T/mirror/jitsi/infra-customizations-private.git"
out=$(run_in_subshell t6 "export GIT_MIRROR_HOST=unused ENVIRONMENT=e ORACLE_REGION=r GIT_BRANCH=main INFRA_CONFIGURATION_REPO=https://github.invalid/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=https://github.invalid/jitsi/infra-customizations-private.git INFRA_CONFIGURATION_MIRROR_REPO=file://$T/mirror/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_MIRROR_REPO=file://$T/mirror/jitsi/infra-customizations-private.git OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo CHECKOUT_FAILED; exit 1; fi; echo CHECKOUT_OK' 2>&1)
echo "$out" | sed 's/^/     /'
check "both from the mirror" '[[ $(echo "$out" | grep -c "from the in-region mirror$") -eq 2 && "$out" == *CHECKOUT_OK* ]]'
check "github never tried" '[[ "$out" != *"github.invalid"* ]]'

echo "== 7. a branch a repo does not have falls back to main, per repo"
HEAD_OF='echo "BRANCH=$(git -C "$BOOTSTRAP_DIRECTORY/infra-configuration" rev-parse --abbrev-ref HEAD)/$(git -C "$BOOTSTRAP_DIRECTORY/infra-customizations" rev-parse --abbrev-ref HEAD)"'
out=$(run_in_subshell t7 "export GIT_BRANCH=no-such-branch INFRA_CONFIGURATION_REPO=$GH_CONF INFRA_CUSTOMIZATIONS_REPO=$GH_CUST OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo CHECKOUT_FAILED; exit 1; fi; echo CHECKOUT_OK; '"$HEAD_OF" 2>&1)
check "a branch in neither repo: both at main, by default" '[[ "$out" == *CHECKOUT_OK* && "$out" == *"BRANCH=main/main"* && $(echo "$out" | grep -c "trying main") -eq 2 ]]'
# a feature branch pushed to infra-configuration only: the shape of a jibri boot loop in stage-8x8
git -C "$T/github/infra-configuration.git" branch conf-only main
out=$(run_in_subshell t7b "export GIT_BRANCH=conf-only INFRA_CONFIGURATION_REPO=$GH_CONF INFRA_CUSTOMIZATIONS_REPO=$GH_CUST OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo CHECKOUT_FAILED; exit 1; fi; echo CHECKOUT_OK; '"$HEAD_OF" 2>&1)
echo "$out" | sed 's/^/     /'
check "a branch in infra-configuration only: that branch there, main of customizations" '[[ "$out" == *CHECKOUT_OK* && "$out" == *"BRANCH=conf-only/main"* ]]'
check "only customizations fell back" '[[ $(echo "$out" | grep -c "trying main") -eq 1 && "$out" == *"could not get infra-customizations at conf-only"* ]]'
out=$(run_in_subshell t7c "export GIT_BRANCH=no-such-branch GIT_FALLBACK_BRANCH=no-such-fallback INFRA_CONFIGURATION_REPO=$GH_CONF INFRA_CUSTOMIZATIONS_REPO=$GH_CUST OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo CHECKOUT_FAILED; exit 1; fi; echo CHECKOUT_OK' 2>&1)
check "a fallback that is missing too is a failure, not a hang or a crash" '[[ "$out" == *CHECKOUT_FAILED* && "$out" == *"Failed to clone infra-configuration at no-such-fallback from github"* ]]'
# pushed to github after the mirror last synced: github has it, the mirror does not
git -C "$T/github/infra-configuration.git" branch not-yet-mirrored main
git -C "$T/github/infra-customizations-private.git" branch not-yet-mirrored main
out=$(run_in_subshell t7d "export GIT_MIRROR_HOST=unused ENVIRONMENT=e ORACLE_REGION=r GIT_BRANCH=not-yet-mirrored INFRA_CONFIGURATION_REPO=$GH_CONF INFRA_CUSTOMIZATIONS_REPO=$GH_CUST INFRA_CONFIGURATION_MIRROR_REPO=file://$T/mirror/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_MIRROR_REPO=file://$T/mirror/jitsi/infra-customizations-private.git OCI_BIN=/nonexistent/oci" \
  'if ! checkout_repos; then echo CHECKOUT_FAILED; exit 1; fi; echo CHECKOUT_OK; '"$HEAD_OF" 2>&1)
check "a branch the mirror lacks comes from github, not main" '[[ "$out" == *"BRANCH=not-yet-mirrored/not-yet-mirrored"* && $(echo "$out" | grep -c "^Cloned .* at not-yet-mirrored from github$") -eq 2 && "$out" != *"trying main"* ]]'

echo "== 8. credentials: fake oci, set -x and bash -v on, password must not leak"
mkdir -p "$T/bin"; cat > "$T/bin/oci" <<'OCI'
#!/bin/bash
# fake: oci os object get -bn B --name gitea-read-user --file F
while [ $# -gt 0 ]; do [ "$1" = "--file" ] && F="$2"; shift; done
printf '{"username":"mirror-reader","password":"S3cretPassw0rdXYZ"}' > "$F"
OCI
chmod +x "$T/bin/oci"
# a git shim on PATH (a real child process, like git): run whatever credential helper the lib hands it, the way git would
cat > "$T/bin/git" <<'SHIM'
#!/bin/bash
all="$*"; helper=""; while [ $# -gt 0 ]; do if [ "$1" = "-c" ]; then shift; case "$1" in credential.helper=!*) helper="${1#credential.helper=!}";; esac; fi; shift; done
if [ -n "$helper" ]; then bash -c "$helper get" >> "$HELPER_OUT" 2>&1; else echo "no helper for $all" >> "$HELPER_OUT"; fi
SHIM
chmod +x "$T/bin/git"
# a credential helper that records what git asked for, standing in for the https mirror challenge
cat > "$T/creds-probe.sh" <<PROBE
set -e -x
export BOOTSTRAP_DIRECTORY="$T/bootstrap-t8" GIT_MIRROR_HOST_FILE="$T/none"
export GIT_MIRROR_HOST=mirror.example ENVIRONMENT=e ORACLE_REGION=r OCI_BIN="$T/bin/oci" HOME="$HOME"
export INFRA_CONFIGURATION_REPO=https://github.com/jitsi/infra-configuration.git INFRA_CUSTOMIZATIONS_REPO=https://github.com/jitsi/infra-customizations-private.git
. "$LIB"
resolve_git_mirror_host; configure_mirror_repos; fetch_mirror_credentials
echo "HELD_USER=\$MIRROR_GIT_USERNAME HELD_HOST=\$MIRROR_GIT_HOST PW_SET=\${MIRROR_GIT_PASSWORD:+yes}"
export PATH="$T/bin:\$PATH" HELPER_OUT="$T/helper-out"
git_clone_for_boot https://mirror.example/jitsi/infra-customizations-private.git "$T/x"
git_clone_for_boot https://github.com/jitsi/infra-configuration.git "$T/y"
forget_mirror_credentials
echo "AFTER_FORGET=[\${MIRROR_GIT_PASSWORD:-}]"
PROBE
out=$(bash -v "$T/creds-probe.sh" 2>&1)
check "credentials held in variables" '[[ "$out" == *"HELD_USER=mirror-reader HELD_HOST=mirror.example PW_SET=yes"* ]]'
check "one log line for the credential outcome" '[[ "$out" == *"Holding mirror credentials for mirror-reader at mirror.example"* ]]'
check "password absent from the -v -x trace and stdout" '[[ "$out" != *"S3cretPassw0rdXYZ"* ]]'
check "xtrace restored afterwards" '[[ "$out" == *"+ echo "*"HELD_USER="* ]]'
check "the helper would return the password to git on get" 'grep -q "password=S3cretPassw0rdXYZ" "$T/helper-out" && grep -q "username=mirror-reader" "$T/helper-out"'
check "the github clone got no helper at all" 'grep -q "no helper for clone --depth 1 --single-branch https://github.com/jitsi/infra-configuration.git" "$T/helper-out"'
check "forgotten after the clones" '[[ "$out" == *"AFTER_FORGET=[]"* ]]'
check "creds json removed" '[[ -z "$(ls "${TMPDIR:-/tmp}"/gitea-read-user.* 2>/dev/null)" ]]'
check "nothing written under the fake HOME besides ssh" '[[ -z "$(ls -A "$HOME" | grep -v "^.ssh$")" ]]'

echo "== 9. git_clone_for_boot only attaches the credential to the mirror host"
out=$( set -e; export HOME; . "$LIB"; MIRROR_GIT_HOST=mirror.example; MIRROR_GIT_USERNAME=u; MIRROR_GIT_PASSWORD=p
  git() { echo "GIT_ARGS: $*"; echo "ENV_PW=${MIRROR_GIT_PASSWORD-unset}"; }
  git_clone_for_boot https://github.com/jitsi/x.git /tmp/x; echo ---; git_clone_for_boot https://mirror.example/jitsi/x.git /tmp/y )
echo "$out" | sed 's/^/     /'
check "github clone: plain, no helper" '[[ "$out" == *"GIT_ARGS: clone --depth 1 --single-branch https://github.com/jitsi/x.git /tmp/x"* ]]'
check "mirror clone: helper attached, password only via env" '[[ "$out" == *"credential.helper=!f()"* && "$out" == *"clone --depth 1 --single-branch https://mirror.example/jitsi/x.git /tmp/y"* ]]'

echo "== 11. boot clones are shallow and fetch only the ref, branch or tag"
mk_history() { # a repo with history on two branches and a tag, so depth is observable
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  for i in 1 2 3; do echo "$i" > "$d/f"; git -C "$d" add -A; git -C "$d" -c user.email=t@t -c user.name=t commit -qm "c$i"; done
  git -C "$d" tag rel-tag HEAD~1; git -C "$d" branch other HEAD~2
}
mk_history "$T/hist/repo"; mv "$T/hist/repo/.git" "$T/hist/repo.git"; HIST="file://$T/hist/repo.git"
out=$( set -e; . "$LIB"; clone_repo_at_ref "$HIST" "$T/h-branch" main >/dev/null 2>&1; echo "RC=$?"
  echo "SHALLOW=$(git -C "$T/h-branch" rev-parse --is-shallow-repository)"
  echo "COMMITS=$(git -C "$T/h-branch" rev-list --count HEAD)"
  echo "REMOTE_BRANCHES=$(git -C "$T/h-branch" branch -r | grep -vc HEAD)"
  echo "FILE=$(cat "$T/h-branch/f")" )
echo "$out" | sed 's/^/     /'
check "branch clone succeeds" '[[ "$out" == *"RC=0"* ]]'
check "branch clone is shallow, one commit" '[[ "$out" == *"SHALLOW=true"* && "$out" == *"COMMITS=1"* ]]'
check "branch clone fetched only that branch" '[[ "$out" == *"REMOTE_BRANCHES=1"* ]]'
check "branch clone has the branch tip" '[[ "$out" == *"FILE=3"* ]]'
out=$( set -e; . "$LIB"; clone_repo_at_ref "$HIST" "$T/h-tag" rel-tag >/dev/null 2>&1; echo "RC=$?"
  echo "AT_TAG=$(git -C "$T/h-tag" describe --tags --exact-match)"; echo "FILE=$(cat "$T/h-tag/f")" )
echo "$out" | sed 's/^/     /'
check "tag clone lands on the tag" '[[ "$out" == *"RC=0"* && "$out" == *"AT_TAG=rel-tag"* && "$out" == *"FILE=2"* ]]'
out=$( . "$LIB"; clone_repo_at_ref "$HIST" "$T/h-missing" no-such-ref >/dev/null 2>&1; echo "RC=$?"; echo "LEFT=$(ls -A "$T/h-missing" 2>/dev/null | wc -l | tr -d " ")" )
check "a missing ref fails and leaves no checkout" '[[ "$out" == *"RC=1"* && "$out" == *"LEFT=0"* ]]'

echo "== 10. leftover /root/.netrc handling is a no-op we can at least call (not root here)"
out=$( . "$LIB"; INFRA_CUSTOMIZATIONS_MIRROR_REPO=""; fetch_mirror_credentials && echo RC0 )
check "fetch_mirror_credentials returns 0 with no mirror repo" '[[ "$out" == *RC0* ]]'

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$T"; [ $FAIL -eq 0 ]
