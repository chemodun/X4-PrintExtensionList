# Print Extension List

## Features

- Mod developers can include this as a dependency, allowing users to easily export their mod list to the debug log.
- On UI startup, writes a report to the debug log containing:
  - Game version.
  - Current screen resolution and the UI settings that affect menu layout: UI scale and menu width options, the engine UI scale values, and the Helper view size, `uiScale` and `scaleX`/`scaleY` results.
  - Every enabled DLC (id, name, version, date, location and other fields).
  - Every enabled extension/mod (id, name, author, source, version, date, location and other fields).

## Limitations

- Debug-log only; there is no in-game UI, menu, or notification.
- No configuration - it always logs once per UI load.

## Requirements

- `X4: Foundations` 8.00 or newer.

## Installation

- **Steam Workshop** - [Print Extension List](https://steamcommunity.com/sharedfiles/filedetails/?id=3770927339)
- **Nexus Mods** - [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191)

## Usage

Install and enable the extension. On the next game start look in the debug log for lines starting with prefix `PrintExtensionList:`.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) - for the X series.

## Changelog

### [1.01] - 2026-07-31

- Added
  - Current screen resolution to the `Game Data` section of the report.
  - UI related settings to the `Game Data` section: UI scale option, menu width option, both `GetUIScale()` variants, Helper view width/height, Helper `uiScale`, and the `Helper.scaleX()`/`Helper.scaleY()` results for a 100 pixel reference value.

### [1.00] - 2026-07-24

- Added
  - Initial public version
