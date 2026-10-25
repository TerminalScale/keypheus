# Thock

Plays a mechanical keyboard sound every time you press a key. Works on macOS and Windows.

Key releases get their own sound, each click is panned left or right depending on where the key sits, and the volume shifts a little per press so it doesn't sound like one sample on loop. It only listens. It never touches what you type.

I wanted my MacBook keyboard to feel mechanical, and the Windows version is a port of that.

Most of the code was written by Claude. I planned it, ran it and tested it.

## Download

Grab `Thock.dmg` (Mac) or `Thock.exe` (Windows) from the [latest release](https://github.com/TerminalScale/thock/releases/latest).

## Mac

Open the dmg and move `Thock.app` into Applications. The app isn't notarized, so on first launch right click it, hit Open, then Open again.

It needs Input Monitoring permission to hear your keypresses (System Settings, Privacy & Security). Thock lives in the menu bar, and Ctrl+Option+Cmd+T opens its panel if the icon is hidden.

I built it on an M4 MacBook, so it probably won't run on Intel Macs.

## Windows

Double click `Thock.exe`. It sits in the system tray, so click the `^` arrow near the clock to find it. The exe is unsigned, so SmartScreen will warn you. Click More info, then Run anyway.

## Sound packs

Blue, Brown, Black, Cream, Panda, Red and Topre.

## Credits

- Blue, Brown, Black, Creamy and Holy Panda recordings are from [kbsim](https://github.com/tplai/kbsim) by Thomas Lai (MIT).
- Red and Topre recordings are from [Mechvibes](https://github.com/hainguyents13/mechvibes) by Hai Nguyen (MIT).

## Build from source

Mac: `cd mac && bash run.sh`

Windows: `cd windows`, then run `build_exe.bat`.
