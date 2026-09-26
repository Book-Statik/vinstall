#!/usr/bin/env bash
set -u
set -o pipefail

VERSION="2.3"
APP_NAME="vinstall"
SOURCE_URL="https://raw.githubusercontent.com/Book-Statik/vinstall/main/vinstall.sh"
CHECKSUM_URL="https://raw.githubusercontent.com/Book-Statik/vinstall/main/vinstall.sh.sha256"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/$APP_NAME"
DB="$STATE/packages.db"
ARCHBOX="${VINSTALL_ARCH_BOX:-vinstall-arch}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"

mkdir -p "$STATE" "$BIN_DIR"
touch "$DB"
chmod 700 "$STATE"
chmod 600 "$DB"

have(){ command -v "$1" >/dev/null 2>&1; }
die(){ printf '%s
' "vinstall: $*" >&2; exit 1; }
ok(){ printf '  ✓ %s
' "$*"; }
warn(){ printf '  ! %s
' "$*" >&2; }
native_backend(){
  if have xbps-install; then printf 'xbps';
  elif have rpm-ostree; then printf 'rpm-ostree';
  elif have apt-get; then printf 'apt';
  elif have dnf; then printf 'dnf';
  elif have zypper; then printf 'zypper';
  elif have pacman; then printf 'pacman';
  else return 1
  fi
}
need_native(){
  local backend
  backend=$(native_backend)
  [[ -n "$backend" ]] || die "No supported system package manager found (XBPS, APT, DNF, rpm-ostree, Zypper, or Pacman)."
}
source_nix(){
  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
}

shell_quote(){ printf '%q' "$1"; }

xbps_find(){ xbps-query -Rs "$1" 2>/dev/null | grep -E '^[^ ]' | head -30 || true; }
native_find(){
  local backend
  backend=$(native_backend)
  case "$backend" in
    xbps) xbps_find "$1" ;;
    apt) apt-cache search --names-only "$1" 2>/dev/null | head -30 || true ;;
    dnf) dnf search "$1" 2>/dev/null | head -30 || true ;;
    rpm-ostree) rpm-ostree search "$1" 2>/dev/null | head -30 || true ;;
    zypper) zypper search "$1" 2>/dev/null | head -30 || true ;;
    pacman) pacman -Ss "$1" 2>/dev/null | head -30 || true ;;
  esac
}
native_has(){
  local package="$1" backend
  backend=$(native_backend)
  case "$backend" in
    xbps) xbps-query -Rs "$package" 2>/dev/null | awk -v p="$package" 'index($2, p "-") == 1 { found=1 } END { exit !found }' ;;
    apt) apt-cache show "$package" 2>/dev/null | grep -q '^Package:' ;;
    dnf) dnf list --available --quiet "$package" 2>/dev/null | awk -v p="$package" 'index($1, p ".") == 1 { found=1 } END { exit !found }' ;;
    rpm-ostree) rpm-ostree search "$package" 2>/dev/null | awk -v p="$package" '$1 == p { found=1 } END { exit !found }' ;;
    zypper) zypper --non-interactive search --match-exact --type package "$package" 2>/dev/null | awk -F '|' -v p="$package" '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 == p) found=1 } END { exit !found }' ;;
    pacman) pacman -Si "$package" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
flat_find(){ have flatpak || return 0; flatpak search "$1" 2>/dev/null | head -30 || true; }
nix_find(){ have nix || return 0; nix search nixpkgs "$1" 2>/dev/null | head -30 || true; }
arch_exists(){ have distrobox || return 1; distrobox list --no-color 2>/dev/null | awk '{print $1}' | grep -Fxq "$ARCHBOX"; }
arch(){ distrobox enter "$ARCHBOX" -- bash -lc "$*"; }

common_app_key(){
  local name="${1,,}"
  name=${name// /-}
  case "$name" in
    minecraft|mc) printf 'minecraft' ;;
    *) return 1 ;;
  esac
}

common_app_options(){
  case "$1" in
    minecraft)
      printf 'minecraft-prism\tPrism Launcher (recommended)\n'
      printf 'minecraft-official\tOfficial Minecraft Launcher\n'
      printf 'minecraft-atlauncher\tATLauncher (AUR)\n'
      ;;
  esac
}

choose_common_app(){
  local app="$1" entry token label choice index=1
  local -a options=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && options+=("$entry")
  done < <(common_app_options "$app")
  ((${#options[@]})) || return 1

  if [[ "${VINSTALL_YES:-0}" == "1" ]]; then
    printf '%s' "${options[0]%%$'\t'*}"
    return 0
  fi

  printf 'Common %s choices:\n' "$app" >&2
  for entry in "${options[@]}"; do
    IFS=$'\t' read -r token label <<< "$entry"
    printf '  %d) %s\n' "$index" "$label" >&2
    index=$((index + 1))
  done
  printf '  0) cancel\n' >&2
  read -r -p 'Choose an option: ' choice || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn 'Invalid common application choice.'; return 1; }
  ((choice == 0)) && return 1
  ((choice >= 1 && choice <= ${#options[@]})) || { warn 'Invalid common application choice.'; return 1; }
  entry="${options[$((choice - 1))]}"
  printf '%s' "${entry%%$'\t'*}"
}

package_for(){
  local source="$1" requested="$2" alias
  alias=${requested,,}
  alias=${alias// /-}
  case "$alias" in
    vsc|vscode|visual-studio-code)
      case "$source" in
        xbps) printf 'vscodium' ;;
        flatpak) printf 'com.visualstudio.code' ;;
        nix) printf 'vscode' ;;
        aur) printf 'visual-studio-code-bin' ;;
        *) printf 'code' ;;
      esac ;;
    minecraft-prism)
      case "$source" in
        flatpak) printf 'org.prismlauncher.PrismLauncher' ;;
        *) printf 'prismlauncher' ;;
      esac ;;
    minecraft-official)
      case "$source" in
        flatpak) printf 'com.mojang.Minecraft' ;;
        *) printf 'minecraft-launcher' ;;
      esac ;;
    minecraft-atlauncher)
      [[ "$source" == aur ]] && printf 'atlauncher' ;;
    *) printf '%s' "$requested" ;;
  esac
}

aur_preflight(){
  local package="$1" metadata maintainer out_of_date pkgbuild
  [[ "$package" =~ ^[A-Za-z0-9@._+:-]+$ ]] || {
    warn "AUR security check blocked invalid package name: $package"
    return 1
  }
  have curl || { warn "AUR security check needs curl; refusing to download $package."; return 1; }
  have jq || { warn "AUR security check needs jq; refusing to download $package."; return 1; }

  metadata=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --get --data-urlencode "arg[]=$package" \
    https://aur.archlinux.org/rpc/v5/info) || {
    warn "AUR security check could not contact the official AUR API; refusing $package."
    return 1
  }
  [[ "$(jq -r '.resultcount' <<<"$metadata")" == "1" ]] || {
    warn "AUR security check found no package named $package; refusing download."
    return 1
  }
  maintainer=$(jq -r '.results[0].Maintainer // empty' <<<"$metadata")
  out_of_date=$(jq -r '.results[0].OutOfDate // empty' <<<"$metadata")
  if [[ -z "$maintainer" ]]; then
    warn "AUR security check: $package is orphaned; refusing download."
    return 1
  fi
  if [[ -n "$out_of_date" ]]; then
    warn "AUR security check: $package is marked out-of-date; refusing download."
    return 1
  fi

  pkgbuild=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$package") || {
    warn "AUR security check could not read the PKGBUILD for $package; refusing download."
    return 1
  }
  if grep -Eiq '(^|[;&|]|[[:space:]])(curl|wget)[[:space:]].*[|][[:space:]]*(ba)?sh|(^|[;&|])[[:space:]]*(eval|sudo)[[:space:]]|/dev/tcp|base64[[:space:]]+(-d|--decode)' <<<"$pkgbuild"; then
    warn "AUR security check found suspicious commands in $package's PKGBUILD; refusing download."
    return 1
  fi
  ok "AUR security check passed for $package (maintainer: $maintainer)"
}

ensure_arch(){
  have distrobox || die "Distrobox is required for AUR support. Install it with your system package manager."
  if ! arch_exists; then
    echo "Creating isolated Arch Linux environment for AUR..."
    distrobox create --name "$ARCHBOX" --image archlinux:latest --yes || die "Could not create Arch container."
  fi
  arch 'sudo pacman -Syu --needed --noconfirm base-devel git sudo' || return 1
  if ! arch 'command -v yay >/dev/null 2>&1'; then
    echo "Installing yay in the Arch environment..."
    arch 'tmp=$(mktemp -d) && cd "$tmp" && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd / && rm -rf "$tmp"' || return 1
  fi
}

aur_find(){
  local query results
  have curl && have jq || return 0
  query="$1"
  results=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --get --data-urlencode "arg=$query" \
    https://aur.archlinux.org/rpc/v5/search 2>/dev/null) || return 0
  jq -r '.results[]? | "\(.Name) \(.Version)\t\(.Description // \"\")"' <<<"$results" | head -30
}

# source<TAB>backend-package<TAB>requested-name<TAB>version
db_add(){
  local s="$1" p="$2" r="$3" v="$4" tmp
  tmp=$(mktemp)
  awk -F '	' -v s="$s" -v p="$p" '!(($1==s)&&($2==p))' "$DB" > "$tmp"
  printf '%s	%s	%s	%s
' "$s" "$p" "$r" "$v" >> "$tmp"
  mv "$tmp" "$DB"
}

db_remove(){
  local s="$1" p="$2" tmp
  tmp=$(mktemp)
  awk -F '	' -v s="$s" -v p="$p" '!(($1==s)&&($2==p))' "$DB" > "$tmp"
  mv "$tmp" "$DB"
}

db_show(){
  if [ -s "$DB" ]; then
    column -t -s $'	' "$DB" 2>/dev/null || cat "$DB"
  else
    echo "No packages managed by vinstall yet."
  fi
}

ensure_nix(){
  if have nix; then
    source_nix
    return 0
  fi

  echo "Nix is not installed. Installing the single-user Nix backend..."
  if ! have curl; then install_system_packages curl || return 1; fi
  bash <(curl -L https://nixos.org/nix/install) --no-daemon
  source_nix
  have nix || die "Nix installation completed but nix is not available in this shell. Open a new terminal and run vinstall again."
}

install_xbps(){
  local p="$1" requested="${2:-$1}"
  sudo xbps-install -Sy "$p" || return 1
  local v
  v=$(xbps-query -p pkgver "$p" 2>/dev/null || echo unknown)
  db_add xbps "$p" "$requested" "$v"
  ok "Installed $p through XBPS"
}

install_native(){
  local p="$1" requested="${2:-$1}" backend version
  backend=$(native_backend)
  case "$backend" in
    xbps) install_xbps "$p" "$requested"; return $? ;;
    apt) sudo apt-get update && sudo apt-get install -y "$p" || return 1
      version=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo unknown) ;;
    dnf) sudo dnf install -y "$p" || return 1
      version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p" 2>/dev/null || echo unknown) ;;
    rpm-ostree) sudo rpm-ostree install --assumeyes "$p" || return 1
      version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p" 2>/dev/null || echo unknown) ;;
    zypper) sudo zypper --non-interactive install "$p" || return 1
      version=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p" 2>/dev/null || echo unknown) ;;
    pacman) sudo pacman -S --needed --noconfirm "$p" || return 1
      version=$(pacman -Q "$p" 2>/dev/null | awk '{print $2}' || echo unknown) ;;
    *) warn "No supported native package manager is available."; return 1 ;;
  esac
  db_add "$backend" "$p" "$requested" "$version"
  ok "Installed $p through $backend"
  [[ "$backend" != rpm-ostree ]] || warn "Bazzite applies layered packages after reboot."
}

install_flat(){
  local id="$1" requested="${2:-$1}"
  flatpak install --user -y flathub "$id" || return 1
  local v
  v=$(flatpak info --user --show-version "$id" 2>/dev/null || echo unknown)
  db_add flatpak "$id" "$requested" "$v"
  ok "Installed $id through Flatpak"
}

install_nix(){
  local p="$1" requested="${2:-$1}"
  ensure_nix || return 1
  nix profile install "nixpkgs#$p" || return 1
  local v
  v=$(nix profile list 2>/dev/null | grep -m1 "$p" || echo unknown)
  db_add nix "$p" "$requested" "$v"
  ok "Installed $p through Nix"
}

install_aur(){
  local p="$1" requested="${2:-$1}"
  aur_preflight "$p" || return 1
  ensure_arch || return 1
  local package
  package=$(shell_quote "$p")
  arch "yay -S --needed --noconfirm $package" || return 1
  local v
  v=$(arch "pacman -Q $package 2>/dev/null | awk '{print \$2}'" || echo unknown)
  db_add aur "$p" "$requested" "$v"
  arch "command -v distrobox-export >/dev/null 2>&1 && distrobox-export --app $(shell_quote "$p") >/dev/null 2>&1 || true"
  ok "Installed $p through the isolated AUR backend"
}

search(){
  local q="$1" native common entry label
  common=$(common_app_key "$q" || true)
  if [[ -n "$common" ]]; then
    echo "=== Common application choices ==="
    while IFS= read -r entry; do
      IFS=$'\t' read -r _ label <<< "$entry"
      printf '  %s\n' "$label"
    done < <(common_app_options "$common")
    echo
  fi
  native=$(native_backend)
  echo "=== System packages${native:+ / $native} ==="
  [[ -z "$native" ]] || native_find "$(package_for "$native" "$q")" || true
  echo
  echo "=== Nixpkgs ==="
  nix_find "$(package_for nix "$q")" || true
  echo
  echo "=== Flathub ==="
  flat_find "$(package_for flatpak "$q")" || true
  echo
  echo "=== AUR ==="
  if have distrobox; then
    aur_find "$(package_for aur "$q")" || true
  else
    echo "(AUR backend not initialized; vinstall --setup to enable it)"
  fi
}

pick(){
  local requested="$1" q="$1" common
  local preferred="${2:-}"
  local native package
  local -a src=()

  common=$(common_app_key "$q" || true)
  if [[ -n "$common" ]]; then
    q=$(choose_common_app "$common") || return 1
  fi

  native=$(native_backend)
  package=$(package_for "$native" "$q")
  if [[ -n "$native" && -n "$package" ]] && native_has "$package"; then src+=("$native"); fi
  package=$(package_for nix "$q")
  if have nix && [[ -n "$package" ]] && nix_find "$package" | grep -q .; then src+=(nix); fi
  package=$(package_for flatpak "$q")
  if have flatpak && [[ -n "$package" ]] && flat_find "$package" | grep -q .; then src+=(flatpak); fi

  package=$(package_for aur "$q")
  if ((${#src[@]} == 0)) || [[ "${VINSTALL_FORCE_AUR:-0}" == "1" ]]; then
    if [[ -n "$package" ]] && aur_find "$package" | grep -q .; then src+=(aur); fi
  fi

  ((${#src[@]})) || die "No package found for '$requested'. Try: vinstall -Ss $requested"

  if [[ -z "$preferred" && "${VINSTALL_YES:-0}" == "1" ]]; then
    preferred="${VINSTALL_FORCE_AUR:+aur}"
    preferred="${preferred:-${src[0]}}"
  fi

  if [[ -n "$preferred" ]]; then
    case " ${src[*]} " in
      *" $preferred "*) ;;
      *) die "Source '$preferred' has no result for '$requested'." ;;
    esac
    case "$preferred" in
      xbps|apt|dnf|rpm-ostree|zypper|pacman)
        [[ "$preferred" == "$native" ]] || die "Source '$preferred' is not this system's native package manager."
        install_native "$(package_for "$preferred" "$q")" "$requested" ;;
      nix) install_nix "$(package_for nix "$q")" "$requested" ;;
      flatpak) install_flat "$(package_for flatpak "$q")" "$requested" ;;
      aur) install_aur "$(package_for aur "$q")" "$requested" ;;
      *) die "Unknown source '$preferred'. Choose the system manager, nix, flatpak, or aur." ;;
    esac
    return
  fi

  echo
  echo "Found '$requested' in:"
  local i=1 s
  for s in "${src[@]}"; do printf '  %d) %s
' "$i" "$s"; i=$((i+1)); done
  echo "  0) cancel"

  read -r -p "Choose a source: " n
  [[ "$n" =~ ^[0-9]+$ ]] || die "Invalid selection."
  ((n == 0)) && exit 0
  ((n >= 1 && n <= ${#src[@]})) || die "Invalid selection."

  s="${src[$((n - 1))]}"
  case "$s" in
    xbps|apt|dnf|rpm-ostree|zypper|pacman) install_native "$(package_for "$s" "$q")" "$requested" ;;
    nix) install_nix "$(package_for nix "$q")" "$requested" ;;
    flatpak)
      id=$(package_for flatpak "$q")
      if [[ "$id" == "$q" ]]; then
        echo "Flatpak search results may use an application ID."
        read -r -p "Application ID (or exact result ID): " id
      fi
      install_flat "$id" "$requested"
      ;;
    aur) install_aur "$(package_for aur "$q")" "$requested" ;;
  esac
}

remove(){
  local q="$1" found=0 s p r v
  while IFS=$'	' read -r s p r v; do
    [[ -n "${s:-}" ]] || continue
    if [[ "$q" == "$p" || "$q" == "$r" ]]; then
      found=1
      case "$s" in
        xbps) sudo xbps-remove -y "$p" || return 1 ;;
        apt) sudo apt-get remove -y "$p" || return 1 ;;
        dnf) sudo dnf remove -y "$p" || return 1 ;;
        rpm-ostree) sudo rpm-ostree uninstall --assumeyes "$p" || return 1
          warn "Bazzite applies package removals after reboot." ;;
        zypper) sudo zypper --non-interactive remove "$p" || return 1 ;;
        pacman) sudo pacman -Rns --noconfirm "$p" || return 1 ;;
        flatpak) flatpak uninstall --user -y "$p" || return 1 ;;
        nix) ensure_nix && nix profile remove "nixpkgs#$p" || return 1 ;;
        aur)
          ensure_arch || return 1
          arch "yay -Rns --noconfirm $(shell_quote "$p")" || return 1
          ;;
      esac
      db_remove "$s" "$p"
      ok "Removed $q"
    fi
  done < "$DB"
  ((found)) || die "'$q' is not registered with vinstall."
}

update(){
  need_native
  local backend
  backend=$(native_backend)
  echo "=== Updating system packages ($backend) ==="
  case "$backend" in
    xbps) sudo xbps-install -Su || die "XBPS update failed." ;;
    apt) sudo apt-get update && sudo apt-get upgrade -y || die "APT update failed." ;;
    dnf) sudo dnf upgrade --refresh -y || die "DNF update failed." ;;
    rpm-ostree) sudo rpm-ostree upgrade || die "rpm-ostree update failed."
      warn "Bazzite applies the new deployment after reboot." ;;
    zypper) sudo zypper --non-interactive refresh && sudo zypper --non-interactive update || die "Zypper update failed." ;;
    pacman) sudo pacman -Syu --noconfirm || die "Pacman update failed." ;;
  esac
  ok "System packages are updated"

  if have nix; then
    echo
    echo "=== Updating Nix packages ==="
    nix profile upgrade '.*' || warn "Some Nix packages could not be upgraded."
  fi

  if have flatpak; then
    echo
    echo "=== Updating Flatpak ==="
    flatpak update --user -y || warn "Some Flatpak packages could not be upgraded."
  fi

  if arch_exists; then
    echo
    echo "=== Updating AUR / Arch backend ==="
    arch 'yay -Syu --noconfirm' || warn "AUR backend update failed."
  fi

  echo
  echo "=== Cleanup ==="
  if [[ "$backend" == xbps ]]; then sudo xbps-remove -Oy || true; fi
  if have nix; then nix store gc || true; fi
  if have flatpak; then flatpak uninstall --user --unused -y || true; fi
  ok "Update complete"
}

repair_xbps(){
  local package="$1"
  have xbps-install || die "XBPS was not found."
  echo "Repairing $package through XBPS..."
  sudo xbps-install -Sfy "$package" || die "XBPS could not repair $package."
  ok "Reinstalled $package through XBPS"
}

repair_native(){
  local package="$1" backend
  backend=$(native_backend)
  case "$backend" in
    xbps) repair_xbps "$package"; return $? ;;
    apt) sudo apt-get install --reinstall -y "$package" || die "APT could not repair $package." ;;
    dnf) sudo dnf reinstall -y "$package" || die "DNF could not repair $package." ;;
    zypper) sudo zypper --non-interactive install --force "$package" || die "Zypper could not repair $package." ;;
    pacman) sudo pacman -S --noconfirm "$package" || die "Pacman could not repair $package." ;;
    rpm-ostree) die "rpm-ostree does not support package reinstall; use the system's rollback or rebase workflow." ;;
    *) die "No supported system package manager is available." ;;
  esac
  ok "Reinstalled $package through $backend"
}

install_system_packages(){
  local backend
  backend=$(native_backend)
  case "$backend" in
    xbps) sudo xbps-install -Sy "$@" ;;
    apt) sudo apt-get update && sudo apt-get install -y "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    rpm-ostree) sudo rpm-ostree install --assumeyes "$@" ;;
    zypper) sudo zypper --non-interactive install "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm "$@" ;;
    *) return 1 ;;
  esac
}

repair_vinstall(){
  local tmp checksum_file expected actual
  if [ "$(id -u)" -eq 0 ]; then
    die "Run vinstall --repair-vinstall as your normal user, not root."
  fi
  have curl || die "curl is required to repair vinstall. Run vinstall --setup first."
  have sha256sum || die "sha256sum is required to verify the repair download."
  tmp=$(mktemp) || die "Could not create a temporary repair file."
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$SOURCE_URL" > "$tmp"; then
    rm -f "$tmp"
    die "Could not download a fresh vinstall script."
  fi
  checksum_file=$(mktemp) || { rm -f "$tmp"; die "Could not create a temporary checksum file."; }
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$CHECKSUM_URL" > "$checksum_file"; then
    rm -f "$tmp" "$checksum_file"
    die "Could not download the vinstall checksum."
  fi
  expected=$(awk 'NF { print $1; exit }' "$checksum_file")
  actual=$(sha256sum "$tmp" | awk '{print $1}')
  if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ || "$actual" != "$expected" ]]; then
    rm -f "$tmp" "$checksum_file"
    die "Downloaded vinstall script failed checksum validation."
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp" "$checksum_file"
    die "Downloaded vinstall script failed Bash syntax validation."
  fi
  sudo install -m 755 "$tmp" /usr/local/bin/vinstall || {
    rm -f "$tmp" "$checksum_file"
    die "Could not replace /usr/local/bin/vinstall."
  }
  rm -f "$tmp" "$checksum_file"
  ok "Repaired vinstall from $SOURCE_URL. Package state was preserved."
}

setup(){
  local setup_warnings=0 backend
  local -a helpers
  need_native
  backend=$(native_backend)
  echo "vinstall setup"
  echo
  echo "Installing the native helpers vinstall uses..."
  if [[ "$backend" == rpm-ostree ]]; then
    helpers=()
    have curl || helpers+=(curl)
    have git || helpers+=(git)
    have jq || helpers+=(jq)
    if ((${#helpers[@]})); then
      install_system_packages "${helpers[@]}" || die "Could not install required helpers."
    fi
    have distrobox || { warn "Distrobox is unavailable; AUR support will not work."; setup_warnings=1; }
    have flatpak || { warn "Flatpak is unavailable."; setup_warnings=1; }
  else
    install_system_packages curl ca-certificates git jq distrobox flatpak || die "Could not install required helpers."
  fi
  if [[ "$backend" == xbps ]]; then
    echo
    read -r -p "Enable Void's official nonfree repository? [Y/n] " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
      sudo xbps-install -Sy void-repo-nonfree || { warn "Could not enable the nonfree repository."; setup_warnings=1; }
    fi
    echo
    read -r -p "Enable Void's official multilib repository (x86_64 glibc only)? [y/N] " a
    if [[ "$a" =~ ^[Yy]$ ]]; then
      sudo xbps-install -Sy void-repo-multilib void-repo-multilib-nonfree || { warn "Could not enable the multilib repositories."; setup_warnings=1; }
    fi
  fi
  echo
  echo "Installing Nix..."
  ensure_nix || { warn "Nix setup was not completed."; setup_warnings=1; }
  echo
  echo "AUR support is lazy and will create the Arch container only when an AUR package is installed."
  echo
  echo "Setting up Flathub..."
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || { warn "Could not configure Flathub."; setup_warnings=1; }
  if ((setup_warnings)); then
    warn "vinstall setup completed with warnings. Run vinstall --doctor."
  else
    ok "vinstall setup complete"
  fi
  echo
  echo "From now on, use vinstall for package management:"
  echo "  vinstall -S <package>"
  echo "  vinstall -R <package>"
  echo "  vinstall -Ss <query>"
  echo "  vinstall -Syu"
}

doctor(){
  local backend
  echo "vinstall doctor"
  echo
  if backend=$(native_backend); then ok "System package manager: $backend"; else warn "No supported system package manager"; fi
  have flatpak && ok "Flatpak" || warn "Flatpak unavailable"
  have nix && ok "Nix" || warn "Nix unavailable"
  have distrobox && ok "Distrobox" || warn "Distrobox unavailable"
  arch_exists && ok "Arch/AUR container" || warn "Arch/AUR container not initialized"
  echo
  echo "Managed packages:"
  db_show
}

usage(){
  cat <<'EOF'
vinstall — package manager frontend for Linux

  vinstall -S  <name>    Search sources and install
  vinstall -S --source <backend> <name>
                          Install from a specific backend without choosing
  vinstall --yes -S <name>
                          Install using the first available backend
  vinstall -A  <name>    Search all sources, including AUR, and install
  vinstall -Ss <query>   Search every backend
  vinstall -R  <name>    Remove a package installed through vinstall
  vinstall -Syu          Update system packages + Nix + Flatpak + AUR
  vinstall --repair <name>
                          Reinstall a native package (not supported by rpm-ostree)
  vinstall --repair-vinstall
                          Download and validate a fresh vinstall command
  vinstall -Q            List packages managed by vinstall
  vinstall -Qi <name>    Show tracked package information
  vinstall --setup       One-time automatic backend setup
  vinstall --doctor      Diagnose the installation
  vinstall --uninstall   Remove vinstall but keep package state
  vinstall --help        Help

The native backend uses the host distribution's package manager. Flatpak,
Nix, and the isolated Arch/AUR backend are optional additional sources.
Supported native managers: XBPS, APT, DNF, rpm-ostree, Zypper, and Pacman.
Use `vsc` (or `vscode`) as a shortcut for Visual Studio Code.
Use `vinstall -S minecraft` for a curated launcher selection.
EOF
}

info(){
  local q="$1" s p r v
  while IFS=$'	' read -r s p r v; do
    [[ "$q" == "$p" || "$q" == "$r" ]] || continue
    printf 'Source:    %s
Package:   %s
Requested: %s
Version:   %s
' "$s" "$p" "$r" "$v"
  done < "$DB"
}

uninstall_self(){
  local target
  target=$(command -v vinstall 2>/dev/null || true)
  [[ -n "$target" ]] || die "vinstall is not installed in PATH."
  sudo rm -f "$target" || die "Could not remove $target."
  ok "Removed $target. Package state was preserved at $DB."
}

install_self(){
  case "$(basename -- "$0")" in
    bash|sh|-bash|-sh)
      die "A fetched script needs an explicit command. Use: curl -fsSL $SOURCE_URL | bash -s -- --setup"
      ;;
  esac
  if [ "$(id -u)" -eq 0 ]; then
    die "Run this installer as your normal user, not root."
  fi
  need_native
  sudo install -d -m 755 /usr/local/bin
  sudo install -m 755 "$0" /usr/local/bin/vinstall
  ok "Installed vinstall to /usr/local/bin"
  exec /usr/local/bin/vinstall --setup
}

main(){
  if [[ -z "${1:-}" && "$(basename -- "$0")" != "vinstall" ]]; then
    install_self
  fi

  [[ $# -gt 0 ]] || { usage; exit 0; }

  case "$1" in
    -Syu|-Syyu) update ;;
    --repair)
      [[ $# -ge 2 ]] || die "Usage: vinstall --repair <package>"
      repair_native "$2" ;;
    --repair-vinstall) repair_vinstall ;;
    -S)
      if [[ "${2:-}" == "--source" ]]; then
        [[ $# -ge 4 ]] || die "Usage: vinstall -S --source <backend> <package>"
        pick "$4" "$3"
      elif [[ "${3:-}" == "--source" ]]; then
        [[ $# -ge 4 ]] || die "Usage: vinstall -S <package> --source <backend>"
        pick "$2" "$4"
      else
        [[ $# -ge 2 ]] || die "Usage: vinstall -S <package>"
        pick "$2"
      fi ;;
    -A)
      [[ $# -ge 2 ]] || die "Usage: vinstall -A <package>"
      VINSTALL_FORCE_AUR=1 pick "$2" ;;
    -Ss)
      [[ $# -ge 2 ]] || die "Usage: vinstall -Ss <query>"
      search "$2" ;;
    -R)
      [[ $# -ge 2 ]] || die "Usage: vinstall -R <package>"
      remove "$2" ;;
    -Q) db_show ;;
    -Qi)
      [[ $# -ge 2 ]] || die "Usage: vinstall -Qi <package>"
      info "$2" ;;
    --setup) setup ;;
    --uninstall) uninstall_self ;;
    --yes)
      shift
      VINSTALL_YES=1 main "$@"
      ;;
    --doctor) doctor ;;
    --help|-h) usage ;;
    --version|-V) echo "vinstall $VERSION" ;;
    *) die "Unknown option '$1'. Run: vinstall --help" ;;
  esac
}

if [[ "${VINSTALL_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
