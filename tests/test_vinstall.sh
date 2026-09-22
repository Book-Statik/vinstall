#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export HOME="$TEST_HOME/home"
export XDG_STATE_HOME="$TEST_HOME/state"
export XDG_BIN_HOME="$TEST_HOME/bin"
export VINSTALL_SOURCE_ONLY=1
mkdir -p "$HOME"

# shellcheck source=../vinstall.sh
source "$ROOT/vinstall.sh"

fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass(){ printf 'ok - %s\n' "$1"; }

[[ "$(shell_quote "package name")" == "package\ name" ]] || fail "shell_quote escapes spaces"
pass "shell_quote escapes spaces"

db_add xbps example example 1.0
grep -Fq $'xbps\texample\texample\t1.0' "$DB" || fail "db_add records a package"
pass "db_add records a package"

sudo(){ return 1; }
if remove example >/dev/null 2>&1; then
  fail "remove reports backend failure"
fi
grep -Fq $'xbps\texample\texample\t1.0' "$DB" || fail "failed removal keeps package state"
pass "failed removal keeps package state"

sudo(){ "$@"; }
xbps-install(){ printf '%s\n' "$*" > "$TEST_HOME/repair-command"; }
repair_xbps example >/dev/null || fail "XBPS repair command failed"
[[ $(cat "$TEST_HOME/repair-command") == "-Sfy example" ]] || fail "XBPS repair uses the force reinstall flags"
pass "XBPS repair uses the force reinstall flags"

curl(){
  case "$*" in
    *.sha256) printf '%064d  vinstall.sh\n' 0 ;;
    *) printf '#!/usr/bin/env bash\nexit 0\n' ;;
  esac
}
sha256sum(){ printf '%064d  %s\n' 0 "$1"; }
install(){ printf '%s\n' "$*" > "$TEST_HOME/self-repair-command"; }
repair_vinstall >/dev/null || fail "vinstall self-repair failed"
grep -Fq -- '-m 755 ' "$TEST_HOME/self-repair-command" || fail "self-repair did not install the validated script"
pass "vinstall self-repair validates and installs a fresh script"

xbps_find(){ printf 'example result\n'; }
install_xbps(){ printf '%s' "$1" > "$TEST_HOME/selected"; }
export VINSTALL_YES=1
pick example
[[ $(cat "$TEST_HOME/selected") == example ]] || fail "--yes selects the available backend"
pass "--yes selects the available backend"

arch(){ fail "AUR search entered Distrobox"; }
curl(){
  printf '{"resultcount":1,"results":[{"Name":"example","Version":"1.0","Description":"test"}]}'
}
jq(){ printf 'example 1.0\ttest\n'; }
aur_find example >/dev/null || fail "AUR search does not work without Distrobox"
pass "AUR search does not enter Distrobox"

aur_find(){ printf 'aur result\n'; }
install_xbps(){ printf '%s' "$1" > "$TEST_HOME/native-selected"; }
unset VINSTALL_FORCE_AUR
pick example
[[ $(cat "$TEST_HOME/native-selected") == example ]] || fail "native backend wins over AUR"
pass "native backend wins over AUR"

if aur_preflight 'not a valid package name' >/dev/null 2>&1; then
  fail "AUR preflight accepts invalid package names"
fi
pass "AUR preflight rejects invalid package names"

printf 'all vinstall tests passed\n'
