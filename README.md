# LFGcopy

LFGcopy is a World of Warcraft addon that gives you a cleaner, more useful view of Looking for Group search results. It turns the default LFG list into a compact panel with group headers, simplified dungeon/raid labels, role-aware player display, and quick copy actions for names and WarcraftLogs links.

## What it does

- Opens a movable window with the current LFG search results.
- Shows each group with:
  - leader name
  - member count
  - abbreviated dungeon/raid activity names
  - the leader's comment/description
  - player names with class colors and role icons
- Lets you collapse or expand groups by clicking the leader line.
- Provides quick actions for players:
  - left-click: copy the player name
  - shift + left-click: copy a WarcraftLogs link
  - right-click: run /who in chat
  - shift + right-click: open a small context menu with more options
- Includes filters for:
  - search text
  - "trinket only" mode for groups that contain a marked mage
- Adds a second "Secundo" tab that holds groups you park (see Options below).
- Adds optional per-group notes that stay visible even when a group is collapsed.
- Supports a default keybind and slash commands.

## Features in more detail

### Group display

Each LFG result is shown as a grouped row with a compact header and optional expanded details. The addon tries to keep the UI readable by shortening common dungeon and raid names, such as:

- HFR for Hellfire Ramparts
- BF for Blood Furnace
- ShH for Shattered Halls
- Kara for Karazhan
- BT for Black Temple

### Secundo tab (second tab) and parked groups

The tab strip under the title bar has two tabs: **Primo** and **Secundo**.

With the option **"Park collapsed groups on the second tab"** enabled, collapsing any group on the Primo tab moves it to the Secundo tab instead of folding it in place:

- A parked group is shown only on the Secundo tab (with its leader comment and note if enabled).
- Collapsed descriptions are shortened to one line; expand the group to read the full description.
- You can expand/collapse it there freely — expanding it does NOT move it back.
- The only way to move it back is the small **^ arrow button** just left of its [+]/[-] marker. The group returns to the Primo tab expanded.
- The Secundo tab button shows how many groups are parked, e.g. "Secundo (2)".
- Right-clicking a tab (or clicking the "Options" button) also offers "Move all parked groups back".

### Notes per group

With **"Show group notes"** enabled, every row shows a note area (on collapsed rows it shares the second line with the leader comment, right-aligned; on expanded rows it is a slim line under the comment). Click it to add or edit the note in a small popup:

- The note stays visible even when the group is collapsed.
- Notes follow the group across tabs and across collapse/expand cycles (session-only, keyed by group leader).

### Role handling

Player role icons are shown based on the role data returned by the game API. The addon tries to infer the most useful role for display and will prefer the role information that makes the most sense for the listing type.

### Trinket filter

The addon has a "Trinket: ON/OFF" toggle that highlights groups containing a mage who is marked as owning a trinket. It looks for a global table of mage names from another addon's saved data, with a built-in fallback list.

## Installation

1. Copy the LFGcopy folder into your World of Warcraft Interface/AddOns directory.
2. Make sure the folder is named exactly:
   - Interface/AddOns/LFGcopy
3. Reload your UI or restart the game.
4. Open the addon with:
   - /lfgcopy
   - or use the default keybind Alt+I

## Usage

### Commands

- /lfgcopy - toggle the addon window
- /lfgcopyroles - print raw LFG role/debug information for the current search results

### Controls

- Click the leader name to collapse, expand, or (optionally) park a group.
- Click the ^ arrow to move a parked group back from the Secundo tab.
- Click the note text on a row to add/edit that group's note.
- Right-click the leader name to whisper the leader.
- Click a player name to copy it.
- Shift-click a player name to copy a WarcraftLogs link.
- Use the search box to filter results by leader, activity, description, or member name.
- Use the trinket toggle to show only groups with a marked mage.
- Click the Primo/Secundo tabs to switch between the two lists.
- Click "Options" (or right-click a tab) to open the addon options menu.

## Options

Settings are saved in the LFGcopyDB SavedVariables file. Open the menu via the "Options" button on the tab strip (or right-click either tab):

- **Park collapsed groups on the second tab** (default off) — collapsing a group moves it to the Secundo tab; see "Secundo tab" above.
- **Show descriptions on collapsed groups** (default on) — the leader's comment is shown on the collapsed row (single line, dimmed).
- **Show group notes** (default off) — enables the per-group note area described above.
- **Show the second tab** (default on) — hides the Secundo tab and sends any parked groups back to the Primo tab.

## Configuration

The addon is mostly ready to use out of the box. If you want to change the trinket-owner source, edit the configuration values at the top of LFGcopy.lua:

- TRINKET_DB_GLOBAL: the global table name used for the mage owner list
- TRINKET_FALLBACK: a manual fallback list of names
- WCL_SUBDOMAIN: set the WarcraftLogs subdomain if you need a different region style

## Notes

- The addon uses Blizzard's LFG List API and will only work in a client/session where those APIs are available.
- The addon requests fuller member information for search results so that more players show up correctly.
- Some Blizzard-provided strings such as comments are displayed as text but may not be programmatically copyable.
- Options persist through LFGcopyDB; per-group notes and parked/collapsed state are session-only on purpose.

## Development checks

Run `lua tests/ui_regressions.lua` from the repository root (Lua 5.1 or later). The tests use mocked WoW widgets to check protected-description handling, collapse/expand transitions, notes, and tab labels. Actual text rendering still needs an in-game check.

## Author

This addon was created as a lightweight LFG helper focused on copy actions, role visibility, and cleaner grouping.
