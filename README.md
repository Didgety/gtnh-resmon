# GTNH OpenComputers Resource Monitor

An OpenComputers/OpenOS daemon for **GregTech: New Horizons** that monitors selected AE2-visible items and fluids and reports them to Discord.

## Features

- One main AE2 network view through an OC Adapter + ME Interface.
- Arbitrary item/fluid resources grouped into logical reporting groups.
- Separate Discord report and alert webhooks per group.
- Low-resource thresholds, hysteresis/recovery thresholds, and repeat alerts.
- Percentage-of-target reporting.
- Rolling rate-of-change and estimated depletion time.
- Hot-reloaded persistent configuration: add/remove/update resources without restarting.
- Terminal administration with `resmonctl`.
- Optional Discord administration using a bot in a private admin channel.
- Native OpenOS `rc` service for autostart.

## Recommended installation: Pastebin bootstrap

```sh
pastebin run f6Wvf4sY --enable --start
```

Update an existing installation to the latest GitHub Release and restart it:

```sh
pastebin run f6Wvf4sY update --restart
```

Install a specific release:

```sh
pastebin run f6Wvf4sY --tag=v2.2.0
```

The Pastebin code is deliberately tiny. It downloads the current `installer.lua` from the
`main` branch, so installer fixes do **not** require creating a new Pastebin ID. The network
installer then downloads `GTNHResourceMonitor.tar` from the latest GitHub Release, extracts it
under `/tmp`, and delegates to `setup.lua`.

Normal install/update operations preserve:

```text
/etc/resmon.cfg
/var/lib/resmon.state
```

### Direct GitHub fallback

If Pastebin is unavailable, the same installer can be launched directly from GitHub:

```sh
wget -f https://raw.githubusercontent.com/Didgety/gtnh-resmon/main/installer.lua /tmp/resmon-installer.lua && /tmp/resmon-installer.lua --repo=Didgety/gtnh-resmon
```

### Local/repository installation

For development, or if the repository has already been copied onto the OC computer, enter the
repository root and run:

```sh
./setup.lua install
```

The local installer puts files in standard OpenOS locations:

```text
/usr/bin/resmon.lua
/usr/bin/resmonctl.lua
/usr/lib/resmon_common.lua
/etc/rc.d/resmon.lua
```

It also creates the initial configuration if missing:

```text
/etc/resmon.cfg
```

To enable at boot:

```sh
./setup.lua install --enable
```

To start immediately as well:

```sh
./setup.lua install --enable --start
```

## Initial configuration

Set global behavior:

```sh
resmonctl settings siteName="Main Base" pollInterval=60 trendWindow=1800 minTrendSpan=300
```

Configure the default group:

```sh
resmonctl group update default \
  display="Critical Resources" \
  webhook="https://discord.com/api/webhooks/..." \
  reportInterval=1800 \
  alertRepeatInterval=7200 \
  mention="<@&ROLE_ID>"
```

Or create additional groups with their own webhooks:

```sh
resmonctl group add chemistry \
  display="Chemistry" \
  webhook="https://discord.com/api/webhooks/REPORT_WEBHOOK" \
  alertWebhook="https://discord.com/api/webhooks/ALERT_WEBHOOK" \
  reportInterval=1800
```

Add an item:

```sh
resmonctl add item default iron \
  label="Iron Ingot" \
  display="Iron" \
  min=100000 \
  recover=120000 \
  target=1000000
```

Add a fluid:

```sh
resmonctl add fluid chemistry oxygen \
  label="Oxygen" \
  display="Oxygen" \
  unit=L \
  min=1000000 \
  recover=1500000 \
  target=10000000
```

Inspect the config:

```sh
resmonctl list
```

Request an immediate Discord report:

```sh
resmonctl report
resmonctl report chemistry
```

## Starting and autostart

Start manually through OpenOS rc:

```sh
rc resmon start
```

Check status:

```sh
rc resmon status
```

Enable at boot:

```sh
rc resmon enable
```

Other service commands:

```sh
rc resmon stop
rc resmon restart
rc resmon disable
```

The monitor can still be run in the foreground with:

```sh
resmon
```

## Updating

From an updated repository checkout:

```sh
./setup.lua update
```

This replaces only installed program/service files. It preserves:

```text
/etc/resmon.cfg
/var/lib/resmon.state
```

If the daemon is currently running, restart it to load the new code:

```sh
./setup.lua update --restart
```

## Uninstalling

Remove program files while retaining configuration/state:

```sh
./setup.lua uninstall
```

Remove everything, including config and runtime state:

```sh
./setup.lua uninstall --purge
```

## Trend / ETA behavior

The monitor samples AE at `settings.pollInterval`. Rate is calculated across a rolling history window (`settings.trendWindow`, default 30 minutes), after at least `settings.minTrendSpan` history exists.

Example:

```text
Iron: 824k / 1M (82.4%) | -123k/h (-12.3%/h) | depletion ~6h 42m
```

`target` defines 100%. If no target is configured, `min` is used. Depletion ETA is only displayed for a negative rolling rate.

## Live resource changes

No daemon restart is needed when editing monitored resources/config:

```sh
resmonctl update iron min=250000 recover=300000 target=2000000
resmonctl update iron group=chemistry
resmonctl remove iron
resmonctl group update chemistry reportInterval=3600
```

The daemon reloads `/etc/resmon.cfg` automatically (default every five seconds).

## Discord administration

Incoming webhooks only send messages. To accept commands from Discord, the monitor optionally polls a private Discord channel with a bot account.

See [docs/discord-admin.md](docs/discord-admin.md).

## Hardware / software requirements

- GTNH with OpenComputers/OpenOS.
- OC Adapter adjacent to an AE2 ME Interface visible to the main AE network.
- Internet Card for Discord communication.
- Enough OC RAM for the size of the AE network being queried.

## Runtime files

```text
/etc/resmon.cfg          persistent configuration (contains secrets)
/var/lib/resmon.state    trend/alert/Discord cursor state
/tmp/resmon.report       transient immediate-report request
```

Keep `/etc/resmon.cfg` private because it may contain Discord webhook URLs and a bot token.
