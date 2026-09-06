# Discord administration

The monitor can optionally accept the same commands used by `resmonctl` from a private Discord text channel.

## Why a bot is required

Discord incoming webhooks can post messages but cannot read a channel. For inbound administration, create a normal Discord bot application and give it access only to the private administration channel.

Recommended channel permissions:

- View Channel
- Read Message History
- Send Messages

Enable the Message Content intent for the bot/application so it can read command text.

Do **not** use a normal Discord user token/self-bot.

For more information on configuring a bot, see the [Discord developer documentation](https://docs.discord.com/developers/bots/overview)

## Configure the OC monitor

```sh
resmonctl discord \
  botToken="YOUR_BOT_TOKEN" \
  adminChannelId="CHANNEL_ID" \
  prefix="!res" \
  pollInterval=15
```

Whitelist one or more Discord users:

```sh
resmonctl discord-admin add YOUR_DISCORD_USER_ID
```

Enable Discord administration:

```sh
resmonctl discord enabled=true
```

## Commands

Discord uses the same grammar as `resmonctl`:

```text
!res list
!res add item default iron label="Iron Ingot" min=100000 target=1000000
!res update iron min=150000
!res remove iron
!res group add chemistry display="Chemistry" webhook="https://discord.com/api/webhooks/..."
!res group update chemistry reportInterval=3600
!res report
!res report chemistry
!res help
```

Only Discord user IDs explicitly added with `resmonctl discord-admin add` are accepted.
