# Changelog

## 2.4.1

- Fixes a bug during setup preventing the download of the repository.

## 2.4.0

- Uses tar utility from [mpmxyz](https://github.com/mpmxyz/ocprograms/)
- Fixes bugs that sometimes prevent installation via pastebin.
- Automates releases on GitHub.

## 2.3.0

- Is not real
- Can't hurt you

## 2.2.0 - network/Pastebin installer

- Added a permanent Pastebin bootstrap that forwards to the current GitHub installer.
- Added a network installer that downloads tagged/latest GitHub Release archives.
- Added GitHub Actions release packaging (`GTNHResourceMonitor.tar`).
- Network install/update delegates to the existing OpenOS `setup.lua`, preserving config/state.

## 2.1.0

- Added `setup.lua` installer/updater/uninstaller.
- Installed commands and library into standard OpenOS `/usr` locations.
- Added native OpenOS rc service at `/etc/rc.d/resmon.lua`.
- Added optional install-time service enable/start and update-time restart.
- Preserved config/state across installs and upgrades by default.

## 2.0.0

- Added resource groups with per-group report/alert webhooks.
- Added hot-reloadable persistent configuration and `resmonctl`.
- Added rolling rate, percentage-of-target, and depletion ETA.
- Added optional Discord bot administration.

## 1.0.0

- Proof of concept.
