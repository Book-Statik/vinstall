#!/usr/bin/env bash
set -u
set -o pipefail

VERSION="2.1"
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
need_void(){ have xbps-install || die "XBPS was not found. This program requires Void Linux."; }
source_nix(){
  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  elif [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
}

shell_quote(){ printf '%q' "$1"; }

xbps_find(){ xbps-query -Rs "$1" 2>/dev/null | grep -E '^[^ ]' | head -30 || true; }
flat_find(){ have flatpak || return 0; flatpak search "$1" 2>/dev/null | head -30 || true; }
nix_find(){ have nix || return 0; nix search nixpkgs "$1" 2>/dev/null | head -30 || true; }
arch_exists(){ have distrobox || return 1; distrobox list --no-color 2>/dev/null | awk '{print $1}' | grep -Fxq "$ARCHBOX"; }
arch(){ distrobox enter "$ARCHBOX" -- bash -lc "$*"; }

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
  have distrobox || die "Distrobox is required for AUR support. Install it with: sudo xbps-install -Sy distrobox"
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
  have curl || sudo xbps-install -Sy curl
  bash <(curl -L https://nixos.org/nix/install) --no-daemon
  source_nix
  have nix || die "Nix installation completed but nix is not available in this shell. Open a new terminal and run vinstall again."
}

install_xbps(){
  local p="$1"
  sudo xbps-install -Sy "$p" || return 1
  local v
  v=$(xbps-query -p pkgver "$p" 2>/dev/null || echo unknown)
  db_add xbps "$p" "$p" "$v"
  ok "Installed $p through XBPS"
}

install_flat(){
  local id="$1"
  flatpak install --user -y flathub "$id" || return 1
  local v
  v=$(flatpak info --user --show-version "$id" 2>/dev/null || echo unknown)
  db_add flatpak "$id" "$id" "$v"
  ok "Installed $id through Flatpak"
}

install_nix(){
  local p="$1"
  ensure_nix || return 1
  nix profile install "nixpkgs#$p" || return 1
  local v
  v=$(nix profile list 2>/dev/null | grep -m1 "$p" || echo unknown)
  db_add nix "$p" "$p" "$v"
  ok "Installed $p through Nix"
}

install_aur(){
  local p="$1"
  aur_preflight "$p" || return 1
  ensure_arch || return 1
  local package
  package=$(shell_quote "$p")
  arch "yay -S --needed --noconfirm $package" || return 1
  local v
  v=$(arch "pacman -Q $package 2>/dev/null | awk '{print \$2}'" || echo unknown)
  db_add aur "$p" "$p" "$v"
  arch "command -v distrobox-export >/dev/null 2>&1 && distrobox-export --app $(shell_quote "$p") >/dev/null 2>&1 || true"
  ok "Installed $p through the isolated AUR backend"
}

search(){
  local q="$1"
  echo "=== XBPS / Void ==="
  xbps_find "$q" || true
  echo
  echo "=== Nixpkgs ==="
  nix_find "$q" || true
  echo
  echo "=== Flathub ==="
  flat_find "$q" || true
  echo
  echo "=== AUR ==="
  if have distrobox; then
    aur_find "$q" || true
  else
    echo "(AUR backend not initialized; vinstall --setup to enable it)"
  fi
}

pick(){
  local q="$1"
  local preferred="${2:-}"
  local -a src=()

  if xbps_find "$q" | grep -q .; then src+=(xbps); fi
  if have nix && nix_find "$q" | grep -q .; then src+=(nix); fi
  if have flatpak && flat_find "$q" | grep -q .; then src+=(flatpak); fi

  if ((${#src[@]} == 0)) || [[ "${VINSTALL_FORCE_AUR:-0}" == "1" ]]; then
    if aur_find "$q" | grep -q .; then src+=(aur); fi
  fi

  ((${#src[@]})) || die "No package found for '$q'. Try: vinstall -Ss $q"

  if [[ -z "$preferred" && "${VINSTALL_YES:-0}" == "1" ]]; then
    preferred="${VINSTALL_FORCE_AUR:+aur}"
    preferred="${preferred:-${src[0]}}"
  fi

  if [[ -n "$preferred" ]]; then
    case " ${src[*]} " in
      *" $preferred "*) ;;
      *) die "Source '$preferred' has no result for '$q'." ;;
    esac
    case "$preferred" in
      xbps) install_xbps "$q" ;;
      nix) install_nix "$q" ;;
      flatpak) install_flat "$q" ;;
      aur) install_aur "$q" ;;
      *) die "Unknown source '$preferred'. Choose xbps, nix, flatpak, or aur." ;;
    esac
    return
  fi

  echo
  echo "Found '$q' in:"
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
    xbps) install_xbps "$q" ;;
    nix) install_nix "$q" ;;
    flatpak)
      echo "Flatpak search results may use an application ID."
      read -r -p "Application ID (or exact result ID): " id
      install_flat "$id"
      ;;
    aur) install_aur "$q" ;;
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
  need_void
  echo "=== Updating Void Linux ==="
  sudo xbps-install -Su || die "Void update failed."
  ok "Void Linux is updated"

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
  sudo xbps-remove -Oy || true
  if have nix; then nix store gc || true; fi
  if have flatpak; then flatpak uninstall --user --unused -y || true; fi
  ok "Update complete"
}

repair_xbps(){
  local package="$1"
  need_void
  echo "Repairing $package through XBPS..."
  sudo xbps-install -Sfy "$package" || die "XBPS could not repair $package."
  ok "Reinstalled $package through XBPS"
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
  local setup_warnings=0
  need_void
  echo "vinstall setup"
  echo
  echo "Installing the native helpers vinstall uses..."
  sudo xbps-install -Sy curl ca-certificates git jq distrobox flatpak || die "Could not install required helpers."
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
  echo
  echo "Installing Nix..."
  ensure_nix || { warn "Nix setup was not completed."; setup_warnings=1; }
  echo
  echo "AUR support is lazy and will create the Arch container only when an AUR package is installed."
  echo
  echo "Setting up Flathub..."
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || { warn "Could not configure Flathub."; setup_warnings=1; }
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
  echo "vinstall doctor"
  echo
  need_void && ok "Void/XBPS"
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
vinstall — universal package manager frontend for Void Linux

  vinstall -S  <name>    Search sources and install
  vinstall -S --source <backend> <name>
                          Install from a specific backend without choosing
  vinstall --yes -S <name>
                          Install using the first available backend
  vinstall -A  <name>    Search all sources, including AUR, and install
  vinstall -Ss <query>   Search every backend
  vinstall -R  <name>    Remove a package installed through vinstall
  vinstall -Syu          Update Void + Nix + Flatpak + AUR + cleanup
  vinstall --repair <name>
                          Force-reinstall a Void package through XBPS
  vinstall --repair-vinstall
                          Download and validate a fresh vinstall command
  vinstall -Q            List packages managed by vinstall
  vinstall -Qi <name>    Show tracked package information
  vinstall --setup       One-time automatic backend setup
  vinstall --doctor      Diagnose the installation
  vinstall --uninstall   Remove vinstall but keep package state
  vinstall --help        Help

The intended workflow is to use vinstall instead of xbps, pacman/yay,
flatpak, or nix directly.
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
  need_void
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
      repair_xbps "$2" ;;
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
