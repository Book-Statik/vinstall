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

usage_output=$(usage)
[[ "$usage_output" != *'Use `vsc`'* && "$usage_output" != *'Use `vinstall -S minecraft`'* && "$usage_output" != *'Use `prism`'* ]] || fail "usage includes app shortcut hints"
pass "usage omits app shortcut hints"

[[ "$(VINSTALL_SOURCE_ONLY=0 bash "$ROOT/vinstall.sh" --fastfetch)" == vinstall ]] || fail "Fastfetch helper prints the package-manager name"
pass "Fastfetch helper prints vinstall"

db_add xbps example example 1.0
grep -Fq $'xbps\texample\texample\t1.0' "$DB" || fail "db_add records a package"
pass "db_add records a package"

have(){ [[ "$1" == rpm-ostree ]]; }
[[ "$(native_backend)" == rpm-ostree ]] || fail "rpm-ostree is detected as the native manager"
sudo(){ return 0; }
rpm(){ printf '42.0'; }
install_native code vsc >/dev/null 2>&1 || fail "rpm-ostree package install path failed"
grep -Fq $'rpm-ostree\tcode\tvsc\t42.0' "$DB" || fail "rpm-ostree install tracks the vsc alias"
pass "rpm-ostree install is tracked"
have(){ command -v "$1" >/dev/null 2>&1; }
sudo(){ "$@"; }

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
native_backend(){ printf 'xbps'; }
native_has(){ return 0; }
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
native_backend(){ printf 'xbps'; }
native_find(){ printf 'example result\n'; }
install_native(){ printf '%s' "$1" > "$TEST_HOME/native-selected"; }
unset VINSTALL_FORCE_AUR
pick example
[[ $(cat "$TEST_HOME/native-selected") == example ]] || fail "native backend wins over AUR"
pass "native backend wins over AUR"

[[ "$(package_for xbps vsc)" == vscodium ]] || fail "vsc resolves to the Void package"
[[ "$(package_for apt vsc)" == code ]] || fail "vsc resolves to the Debian package"
[[ "$(package_for flatpak vsc)" == com.visualstudio.code ]] || fail "vsc resolves to the Flatpak application ID"
[[ "$(package_for nix vsc)" == vscode ]] || fail "vsc resolves to the Nix package"
[[ "$(package_for aur vsc)" == visual-studio-code-bin ]] || fail "vsc resolves to the AUR package"
pass "vsc resolves to backend-specific package names"

have(){ [[ "$1" == flatpak ]]; }
flatpak(){
  printf 'Application ID Name\norg.example.One Cool Editor\norg.example.Two Cool Editor Beta\n'
}
flat_results_output=$(flat_results editor)
[[ "$flat_results_output" == $'org.example.One\tCool Editor\norg.example.Two\tCool Editor Beta' ]] || fail "Flatpak search parses IDs and app names"
pass "Flatpak search returns structured app results"
unset -f flatpak
have(){ command -v "$1" >/dev/null 2>&1; }

[[ "$(package_for flatpak prism)" == org.prismlauncher.PrismLauncher ]] || fail "prism resolves to the Flatpak application ID"
[[ "$(package_for flatpak prism-launcher)" == org.prismlauncher.PrismLauncher ]] || fail "prism-launcher resolves to the Flatpak application ID"
[[ "$(package_for flatpak prismlauncher)" == org.prismlauncher.PrismLauncher ]] || fail "prismlauncher resolves to the Flatpak application ID"
pass "Prism Launcher aliases resolve to its Flatpak ID"

[[ "$(package_for flatpak minecraft-prism)" == org.prismlauncher.PrismLauncher ]] || fail "Prism Launcher resolves to its Flatpak ID"
[[ "$(package_for aur minecraft-official)" == minecraft-launcher ]] || fail "official launcher resolves to its AUR package"
[[ "$(package_for aur minecraft-atlauncher)" == atlauncher ]] || fail "ATLauncher resolves to its AUR package"
[[ "$(VINSTALL_YES=1 choose_common_app minecraft)" == minecraft-prism ]] || fail "--yes chooses the recommended Minecraft launcher"
[[ "$(VINSTALL_YES=0 choose_common_app minecraft 2>/dev/null <<< '2')" == minecraft-official ]] || fail "Minecraft launcher menu honors the selected option"
cancelled_choice=$(VINSTALL_YES=0 choose_common_app minecraft 2>/dev/null <<< '0') || fail "cancel selection returns success"
[[ -z "$cancelled_choice" ]] || fail "cancel selection returns no launcher"
pass "Minecraft launcher choices resolve to backend package IDs"

native_backend(){ printf 'apt'; }
native_find(){ printf 'Visual Studio Code package result\n'; }
native_has(){ return 0; }
nix_find(){ return 0; }
flat_find(){ return 0; }
aur_find(){ return 0; }
install_native(){ printf '%s|%s' "$1" "$2" > "$TEST_HOME/alias-selected"; }
export VINSTALL_YES=1
pick vsc
[[ $(cat "$TEST_HOME/alias-selected") == 'code|vsc' ]] || fail "vsc selection installs the native package and tracks its alias"
pass "vsc selects native package and preserves requested name"

search_output=$(search minecraft)
[[ "$search_output" == *"Prism Launcher (recommended)"* && "$search_output" == *"ATLauncher (AUR)"* ]] || fail "minecraft search lists common launcher choices"
pass "minecraft search lists launcher options"

VINSTALL_YES=1 pick minecraft
[[ $(cat "$TEST_HOME/alias-selected") == 'prismlauncher|minecraft' ]] || fail "minecraft defaults to Prism Launcher and preserves the common name"
VINSTALL_YES=0 pick minecraft <<< $'2\n1' 2>/dev/null
[[ $(cat "$TEST_HOME/alias-selected") == 'minecraft-launcher|minecraft' ]] || fail "minecraft can select the official launcher"
previous_install=$(cat "$TEST_HOME/alias-selected")
VINSTALL_YES=0 pick minecraft <<< '0' >/dev/null 2>&1 || fail "canceling the common app menu exits successfully"
[[ $(cat "$TEST_HOME/alias-selected") == "$previous_install" ]] || fail "canceling the common app menu does not install"
pass "Minecraft choices install their package and retain the typed name"

native_has(){ return 1; }
have(){ [[ "$1" == flatpak ]]; }
flat_results(){
  case "$1" in
    org.prismlauncher.PrismLauncher) printf 'org.prismlauncher.PrismLauncher\tPrism Launcher\n' ;;
    editor) printf 'org.example.One\tCool Editor\norg.example.Two\tCool Editor Beta\n' ;;
  esac
}
install_flat(){ printf '%s|%s' "$1" "$2" > "$TEST_HOME/prism-selected"; }
VINSTALL_YES=0 pick prism <<< '1' 2>/dev/null
[[ $(cat "$TEST_HOME/prism-selected") == 'org.prismlauncher.PrismLauncher|prism' ]] || fail "direct Prism install skips the application ID prompt"
pass "direct Prism install resolves and tracks the user name"
VINSTALL_YES=0 pick editor <<< $'1\n2' 2>/dev/null
[[ $(cat "$TEST_HOME/prism-selected") == 'org.example.Two|editor' ]] || fail "Flatpak search menu installs the selected application ID"
pass "Flatpak app names show multiple matching results"
have(){ command -v "$1" >/dev/null 2>&1; }

if aur_preflight 'not a valid package name' >/dev/null 2>&1; then
  fail "AUR preflight accepts invalid package names"
fi
pass "AUR preflight rejects invalid package names"

nix_ready=0
sudo(){ "$@"; }
prepare_nix_store "$TEST_HOME/nix-store" >/dev/null || fail "Nix store directory can be prepared"
[[ -d "$TEST_HOME/nix-store" && -w "$TEST_HOME/nix-store" ]] || fail "prepared Nix store is writable"
pass "Nix setup prepares a writable store directory"
sudo(){ return 1; }
if prepare_nix_store "$TEST_HOME/nix-store-fail" >/dev/null 2>&1; then
  fail "Nix store preparation reports permission failure"
fi
[[ ! -e "$TEST_HOME/nix-store-fail" ]] || fail "failed Nix preparation leaves no partial path"
pass "Nix setup reports an unwritable store path"
sudo(){ "$@"; }

prepare_nix_store(){ return 0; }
have(){ [[ "$1" == curl ]] || [[ "$1" == nix && "$nix_ready" == 1 ]]; }
curl(){ printf ':\n'; }
source_nix(){ nix_ready=1; }
ensure_nix >/dev/null 2>&1 || fail "Nix installer success is recognized"
pass "Nix setup sources the installed profile"
nix_ready=0
curl(){ return 1; }
if ensure_nix >/dev/null 2>&1; then
  fail "Nix download failure is reported"
fi
pass "Nix download failures return a setup warning"
nix_ready=0
have(){ [[ "$1" == wget ]] || [[ "$1" == nix && "$nix_ready" == 1 ]]; }
wget(){ printf ':\n'; }
ensure_nix >/dev/null 2>&1 || fail "Nix installer uses wget when curl is unavailable"
pass "Nix setup supports a secure wget fallback"

native_backend(){ printf 'apt'; }
install_system_packages(){ return 0; }
nix_setup_calls=0
aur_setup_calls=0
ensure_nix(){ nix_setup_calls=$((nix_setup_calls + 1)); return 0; }
ensure_arch(){ aur_setup_calls=$((aur_setup_calls + 1)); return 0; }
flatpak(){ return 0; }
setup >/dev/null 2>&1 || fail "setup runs successfully with mocked backends"
[[ "$nix_setup_calls" == 1 && "$aur_setup_calls" == 1 ]] || fail "setup initializes Nix and the AUR container"
pass "setup initializes both Nix and AUR backends"

printf 'all vinstall tests passed\n'
