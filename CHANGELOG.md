# Changelog

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
