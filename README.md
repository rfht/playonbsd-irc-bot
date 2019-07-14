thfr's PlayOnBSD IRC Bot
========================

This is a bot for freenode as it is used for the #openbsd-gaming
channel, written in OpenBSD ksh(1) shell script and using nc(1). It
tracks karma points (via `nick++`/`nick--`) and watches for Twitch
streams with "PlayOnBSD" in the title that are then announced on the
channel.

The code is ISC licensed (see head of the script).

If you want to use it for your own bot, you have to provide a few
variables in the file `bot.config` in the same directory as the script.

Example `bot.config` file:

```
NICK=playonbsd
PASS=mypasscode
CHAN="#openbsd-gaming"
CLIENT_ID=myclientid
FOLLOWER_ID=123456789
```
