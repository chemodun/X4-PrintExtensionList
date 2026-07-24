# Print Extension List

## Features

- On UI startup, writes a report to the debug log containing:
  - Game version.
  - Every enabled DLC (id, name, version, date, location and other fields).
  - Every enabled extension/mod (id, name, author, source, version, date, location and other fields).

## Limitations

- Oriented for mod developers to distribute with their mods, so that users can easily report their mod list to the developer inside the debug log.
- Debug-log only; there is no in-game UI, menu, or notification.
- No configuration - it always logs once per UI load.

## Requirements

- `X4: Foundations` 8.00 or newer.

## Installation

You can download the latest version via Steam client - [Print Extension List](https://steamcommunity.com/sharedfiles/filedetails/?id=)
Or you can do it via the Nexus Mods - [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191)

## Usage

Install and enable the extension. On the next game start look in the debug log for lines starting with prefix `PrintExtensionList:`.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) - for the X series.

## Changelog

### [1.00] - 2026-07-24

- Added
  - Initial public version
