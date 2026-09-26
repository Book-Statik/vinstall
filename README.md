# vinstall

`vinstall` is a package-management frontend for Linux. It uses the host's
native package manager (XBPS, APT, DNF, rpm-ostree, Zypper, or Pacman), with
optional Nix, Flatpak, and an Arch Linux Distrobox container for AUR packages.
The native package manager is preferred when more than one backend provides
the software.

## Requirements

- A supported Linux package manager: XBPS, APT, DNF, rpm-ostree, Zypper, or
	Pacman
- A normal user account with `sudo` access
- Internet access for package searches and installation
- Bash

The `--setup` command installs helper tools through the detected system
package manager and can initialize Nix and Flathub. Void repository prompts
are shown only on Void. The Arch/AUR container is created lazily only when an
AUR package is selected for installation.

## Install and run

### From GitHub

Download the latest installer directly from GitHub:

[Download vinstall.sh](https://raw.githubusercontent.com/Book-Statik/vinstall/main/vinstall.sh)

To install the command directly without first saving the file manually, run
this in a Linux terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Book-Statik/vinstall/main/vinstall.sh | sudo tee /usr/local/bin/vinstall >/dev/null && sudo chmod 755 /usr/local/bin/vinstall && vinstall --setup
```

The setup output identifies itself as `vinstall`. For a fetched script that
should only run setup without installing the command, use:

```sh
curl -fsSL https://raw.githubusercontent.com/Book-Statik/vinstall/main/vinstall.sh | bash -s -- --setup
```

The `main` URL tracks the latest source. For reproducible automation, replace
`main` with a reviewed commit, for example:

```sh
REVISION=COMMIT_SHA
curl -fsSL "https://raw.githubusercontent.com/Book-Statik/vinstall/$REVISION/vinstall.sh" | bash -s -- --setup
```

### From a local checkout

From a terminal in this directory:

```sh
chmod +x vinstall.sh
./vinstall.sh
```

With no arguments, the script installs itself as `/usr/local/bin/vinstall`
and then starts setup. Run it as your normal user; it uses `sudo` only for
system package operations.

The usual one-time setup command after installation is:

```sh
vinstall --setup
```

If you do not want to install the command globally, run it directly instead:

```sh
./vinstall.sh --setup
```

## Commands

```text
vinstall -S <name>       Search available backends and install a selection
vinstall -S --source <backend> <name>
						 Install from the system manager, nix, flatpak, or aur
vinstall -S <name> --source <backend>
						 Equivalent source-selection form
vinstall -A <name>       Search all backends, including the AUR, and install
vinstall -Ss <query>     Search the system manager, Nixpkgs, Flathub, and AUR
vinstall -R <name>       Remove a package tracked by vinstall
vinstall -Syu            Update system packages, Nix, Flatpak, and AUR
vinstall --repair <name> Reinstall a native package where supported
vinstall --repair-vinstall Download and validate a fresh vinstall command
vinstall -Q              List packages tracked by vinstall
vinstall -Qi <name>      Show tracked package information
vinstall --setup         Install helpers and initialize package backends
vinstall --doctor        Check backend availability and show tracked packages
vinstall --uninstall     Remove vinstall but preserve its package database
vinstall --yes -S <name> Install with the first available backend
vinstall --version       Print the vinstall version
vinstall --help          Show command help
```

Examples:

```sh
vinstall -Ss firefox
vinstall -S firefox
vinstall -S --source apt firefox
vinstall --yes -S firefox
vinstall -A visual-studio-code-bin
vinstall -S vsc
vinstall -S minecraft
vinstall -Ss minecraft
vinstall -S prism
vinstall -Q
vinstall -Qi firefox
vinstall -R firefox
vinstall --repair firefox
vinstall --repair-vinstall
vinstall -Syu
vinstall --doctor
```

`-S` presents the available backends that contain a result and asks you to
choose one. AUR is used only when the system manager, Nix, and Flatpak have no
result. `-A` is the
explicit escape hatch that also searches AUR. AUR search uses the public API
and does not open Distrobox; Distrobox is entered only after an AUR package is
selected for installation.
`--source` skips that selection and targets one backend. `--yes` selects the
first available backend, preferring AUR for `-A`. The shortcut `vsc` (also
`vscode` and `visual-studio-code`) maps to the package name or application ID
used by each backend. For other Flatpak applications, use the exact
application ID when selecting directly.
`minecraft` (or `mc`) opens a launcher menu with Prism Launcher, the official
Minecraft Launcher, and ATLauncher. Prism is the default for `--yes`; choosing
a launcher then checks which backends provide it. `-Ss minecraft` also lists
these common choices alongside repository search results. There is no single
complete cross-distro database of human names and package IDs, so these
multi-choice mappings are curated; other names continue through the normal
backend searches.
`prism`, `prism-launcher`, and `prismlauncher` all resolve directly to Prism
Launcher, including its Flathub application ID, so Flatpak installs do not
need a second ID prompt.
When needed, the AUR backend creates an Arch Linux container named
`vinstall-arch` and installs `yay` inside it. Set `VINSTALL_ARCH_BOX` to use a
different container name.

On Bazzite and other rpm-ostree systems, native package installs and removals
are layered into a new deployment and require a reboot. Flatpak or Distrobox
is generally preferable for desktop applications on an immutable host.

Before an AUR download, vinstall contacts the official AUR API over HTTPS,
rejects missing, orphaned, or out-of-date packages, downloads only the
`PKGBUILD` for inspection, and blocks several suspicious command patterns.
It prints a warning and stops before `yay` downloads the package when a check
fails. This is a heuristic safety gate, not antivirus software; no static
check can prove that an AUR package is harmless.

## State and configuration

The package tracking database is stored at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/vinstall/packages.db
```

The state directory is restricted to the current user, and the package
database is stored with `600` permissions.

The script prepends `${XDG_BIN_HOME:-$HOME/.local/bin}` to `PATH`. Existing
packages installed outside vinstall are not added to its tracking database.

## Troubleshooting

Run the diagnostic command first:

```sh
vinstall --doctor
```

If no supported native package manager is found, check that the host provides
XBPS, APT, DNF, rpm-ostree, Zypper, or Pacman. If an optional backend is
unavailable, rerun `vinstall --setup` or install it manually. The
Nix installer may require a new terminal before the `nix` command is visible.
If setup reports warnings, run `vinstall --doctor` and address the unavailable
backend before installing packages through it. A failed package removal keeps
the package in vinstall's tracking database so it can be retried.
For a broken native package, `vinstall --repair <name>` invokes the host
package manager's reinstall operation. rpm-ostree does not support package
reinstallation through this command. Use the package's own backend for Nix,
Flatpak, or AUR repairs.
If vinstall itself is damaged, `vinstall --repair-vinstall` downloads the
latest script and its SHA-256 checksum from GitHub, validates both the
checksum and Bash syntax, and replaces the installed command while preserving
package state. The checksum file is `vinstall.sh.sha256` in the repository.

## Development

Run the local checks with:

```sh
bash -n vinstall.sh tests/test_vinstall.sh
bash tests/test_vinstall.sh
shellcheck vinstall.sh tests/test_vinstall.sh
```

GitHub Actions runs the same checks on pushes and pull requests.

## License

No license has been specified for this project.