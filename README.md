# FPLOpticord

FPLOpticord is a small wrapper over the [**FPL Opti**mization Tools](https://github.com/sertalpbilal/FPL-Optimization-Tools) python solver for Dis**cord**, which runs on Zig.

# Status

FPLOpticord is in quite early stages of development, issues may arise. If you run into one, please check out the [known issues section](#known-issues) and, if it is not there, please report the issue on the issues page!

As of right now, there are no precompiled binaries, but precompiled binaries are planned to be supported.

# Getting started

1. Prerequisites
   - [FPL Optimization Tools](https://github.com/sertalpbilal/FPL-Optimization-Tools)

# Building from source

- Install [Zig 0.14.0](https://ziglang.org/download/#release-0.14.0)
- Copy .env.example and replace the placeholder variables with [valid data](#environment-variables).
- Run `zig build run`

# Environment variables

```
token=<ADD DISCORD TOKEN HERE>
prefix=<ADD YOUR BOT PREFIX HERE>
optimization-tools-path=<ADD YOUR PATH TO THE SOLVER HERE>
```

**IMPORTANT**: Do NOT give your Discord token to anyone who you do not trust, as you will be giving them full access to the bot account until the token is reset. This can have major consequences and, depending on the permissions the bot has been given, it can lead to the server getting [nuked](https://www.urbandictionary.com/define.php?term=nuke%20bot).

- token

  - Your [Discord bot](https://discord.com/developers/applications) token. It is located inside the `Bot` section under `token`. **IMPORTANT**: Do not share this with others!

- prefix

  - The prefix that will be added to the commands, in order to distinguish itself from other bots. (ex. `!`)

- optimization-tools-path
  - The path to [/run folder](https://github.com/sertalpbilal/FPL-Optimization-Tools/tree/main/run) of the solver. If you are running this on WSL, provide the Windows path to the solver instead of the WSL one (ex. use `D:/FPL-Optimization-Tools` instead of `/mnt/d/FPL-Optimization-Tools`).

# Known issues

1. Unstable performance on Windows

   Due to an [issue](https://github.com/ziglang/zig/issues/21492) in Zig's standard library, websockets on Windows tend to randomly close. The Zig std pull request currently addressing the issue is [here](https://github.com/ziglang/zig/pull/19751), tracked on the [wrangle-writer-buffering](https://github.com/ziglang/zig/tree/wrangle-writer-buffering) branch of Zig.

   ETA for the fix would be at some point during Zig's `0.15.0-dev` cycle, however a specific timeline is hard for me to provide as I don't work on Zig or [websocket.zig](https://github.com/karlseguin/websocket.zig) 😅.

   **Workaround**: Run the bot on Linux or WSL until the pull request is merged in Zig.
