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
- Always includes a second "Secundo" tab for groups you park (see Options below).
- Adds optional per-group notes that stay visible even when a group is collapsed.
- Remembers notes, parked/collapsed groups, and the selected tab across reloads and relogs for each character.
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

The tab strip under the title bar always has two tabs: **Primo** and **Secundo**. Secundo cannot be hidden.

With the option **"Park collapsed groups on the second tab"** enabled (the default), collapsing any group on the Primo tab moves it to the Secundo tab instead of folding it in place:

- A parked group is shown only on the Secundo tab (with its leader comment and note if enabled).
- Collapsed groups show the full description, wrapping onto as many lines as needed without adding an ellipsis. Expanding also reveals the player list.
- You can expand/collapse it there freely — expanding it does NOT move it back.
- The only way to move it back is the small **^ arrow button** just left of its [+]/[-] marker. The group returns to the Primo tab expanded.
- The Secundo tab button shows how many groups are parked, e.g. "Secundo (2)".
- Right-clicking a tab (or clicking the "Options" button) also offers "Move all parked groups back".

### Notes per group

With **"Show group notes"** enabled, every row shows a note area (on collapsed rows it sits to the right of the wrapped leader comment; on expanded rows it is a slim line under the comment). Click it to add or edit the note in a small popup:

- The note stays visible even when the group is collapsed.
- Notes follow the group across tabs, collapse/expand cycles, reloads, and relogs.
- Clear the note and press Save to delete it from saved data.

### What survives a reload or relog?

For each character, `LFGcopyCharDB` remembers:

- your own group notes;
- which leaders' groups belong on Primo or Secundo;
- collapsed/expanded state;
- the last selected tab.

State is matched by the leader's name **and realm**, not by temporary LFG result IDs. It is applied when that leader appears in fresh search results; it can also follow a later listing from the same leader. Groups that are no longer listed are not shown as live groups. Entries without an identifiable leader are session-only.

On **World of Warcraft: Forever**, which is realmless, state is matched by the leader's two-part name alone (Forever names are already unique per region, so no realm is appended). See the Forever section below for other Forever-specific adaptations.

Group leaders' **live comments/descriptions are not archived**. WoW can supply these as temporary protected display codes that cannot reliably be reused after a reload. The addon displays the current description supplied by WoW when the listing becomes available again.

WoW writes this data on normal reload/logout. Notes from older, session-only versions cannot be recovered after they were lost. Options remain account-wide in `LFGcopyDB`; group state is separate for each character.

### Role handling

Player role icons are shown based on the role data returned by the game API. The addon tries to infer the most useful role for display and will prefer the role information that makes the most sense for the listing type.

### Trinket filter

The addon has a "Trinket: ON/OFF" toggle that highlights groups containing a mage who is marked as owning a trinket. It looks for a global table of mage names from another addon's saved data, with a built-in fallback list.

### Paladin tank filter (WoW Forever only)

On WoW Forever, a second toggle button ("Pala Tank: ON/OFF") appears next to
the Trinket toggle. Turning it on hides every group that doesn't have at
least one Paladin occupying the tank role, using the same per-member
class/role data the group display already builds (see "Role handling"
above). This button doesn't exist at all on other supported clients — see
the Forever section below for why.

## Supported game versions

- Burning Crusade Classic (Interface 20505) — the original target.
- **World of Warcraft: Forever** (Interface 16001, beta build 1.60.1 as of
  this writing; launches Nov 4, 2026) — see the dedicated section below.

## World of Warcraft: Forever support

World of Warcraft: Forever is Blizzard's realmless, permanent level-60
"Classic+" game line (beta since Sept 17, 2026; launch Nov 4, 2026). It runs
on the modern **Mainline** addon API (the same family Retail uses) rather
than the old Classic-era API, even though its game content and TOC Interface
number are vanilla-shaped. LFGcopy detects Forever automatically and adapts
in several ways:

### How detection works

Forever reports `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`, exactly like real
Retail, but carries a low, vanilla-shaped Interface number (`16001` for beta
build 1.60.1 — it's computed as `major*10000 + minor*100 + patch`, so it
ticks up slightly with every point release: `16002` for 1.60.2, and so on).
Neither fact alone identifies the client — Classic Era/SoD/Anniversary also
have a low Interface number (just under a different `WOW_PROJECT_ID`), and
real Retail also reports `WOW_PROJECT_MAINLINE` (just with a much higher
Interface number). LFGcopy checks the *pair* of values together, which is
unique to Forever. Run `/lfgcopyclient` in-game to see exactly what LFGcopy
detected (client build, Interface number, whether Forever was recognized,
and whether the secret-value system described below is active).

### What's adapted for Forever

- **TOC Interface declaration.** `LFGcopy.toc` lists Forever's Interface
  numbers (`16001`-`16010`, covering 1.60.1 through a hypothetical 1.60.10)
  alongside BC Classic's `20505`, so the addon loads on both clients without
  needing the "Load out of date AddOns" checkbox. **If Blizzard ships a
  bigger version bump** (e.g. 1.61.0 → Interface `16100`) after this was
  written, add that number to the `## Interface:` line in `LFGcopy.toc`.
- **Two-part, realmless character names.** Forever has no realms, so every
  character is identified by a two-word "First Last" display name (e.g.
  Blizzard's own example, "Ana Forever") instead of a single name or
  "Name-Realm" pair.
  - Display, copy-to-clipboard, and `/who` all handle the embedded space
    correctly already.
  - Whispering the group leader now uses Blizzard's `ChatFrame_SendTell` /
    `ChatFrameUtil.SendTell` helpers instead of typing a raw `/w NAME `
    string, because typing the name as literal text would make the chat
    parser treat only the first word as the whisper target and swallow the
    rest of the name into the message.
  - The copied WarcraftLogs link percent-encodes the name so the space
    doesn't break the URL (`Ana Forever` → `.../Ana%20Forever`).
- **"Secret values" hardening.** Forever shares Mainline/Midnight's anti-bot
  "secret value" system. Under certain client-side restrictions (new/low-
  level accounts, a chat-messaging lockdown, etc.) the strings and booleans
  `C_LFGList` hands back can arrive as opaque "secret" values that error if
  you try to lowercase, search, concatenate, or directly branch on them —
  exactly the kind of bulk name/text processing LFGcopy does on every
  listing. Every raw value pulled out of the LFG List API is sanitized the
  moment it leaves the API (via internal `SafeString`/`SafeFlag` helpers)
  before anything else touches it:
  - A secret/hidden player name shows as a placeholder ("Hidden Player N")
    instead of silently dropping that member from the roster.
  - A secret/missing leader name falls back to "Unknown" (same as when the
    API simply doesn't return a leader at all).
  - Secret role flags are treated as "not set" rather than erroring, and the
    existing role-detection fallbacks (member info, member counts, base
    role string) take over.
  - `/lfgcopyroles` (the raw API dumper) now reports `SECRET VALUE` for any
    field it can't safely print instead of crashing.
  - This is a no-op (does nothing extra) on clients without the secret-value
    system, like BC Classic.
- **New dungeon/raid abbreviations** for Forever's nine new leveling
  dungeons and its new raids (see the list below), plus `Ony` for Onyxia's
  Lair, which Forever keeps as its one 40-player raid.
- **Class colors** prefer the modern `C_ClassColor.GetClassColor()` API when
  available (Forever/Retail) and fall back to the classic
  `RAID_CLASS_COLORS`/`CUSTOM_CLASS_COLORS` table otherwise.
- **Persisted notes/parked groups** (Secundo tab) key off the leader's name
  without trying to append a realm on Forever, since Forever's two-part
  names are already unique per region. This also avoids feeding a possibly
  "secret" raw name straight into the key-building/SavedVariables code.
- **"Pala Tank" filter toggle.** Forever's talent trees let Paladins
  meaningfully tank its Classic-style dungeons and raids from level 60
  (unlike vanilla/BC Classic, where Protection Paladins essentially never
  tank), so "only show groups that actually have a Paladin tank" is a
  filter that's only useful there. The toggle button is created only when
  `IS_FOREVER` is detected; it's completely absent on every other client,
  and the rest of the title-bar layout (search box position, etc.) adjusts
  automatically whether or not it's present.

### What's still a best guess

WarcraftLogs has not published a confirmed subdomain or URL shape for
Forever yet (it's a brand-new client still in beta). The WarcraftLogs link
builder guesses the Classic Era subdomain (`classic.warcraftlogs.com`) as
the closest existing match, with a one-time in-chat warning the first time
you copy a link on Forever. If WarcraftLogs documents a different shape,
update `WCL_FOREVER_SUBDOMAIN` and `WCL_FOREVER_REALM_FALLBACK` near the top
of `LFGcopy.lua`.

The "trinket only" filter was built around Burning Crusade's Mage trinket
farming (Karazhan/Gruul's Lair). It's harmless on Forever — it just won't
match anything unless you populate `TRINKET_FALLBACK` yourself — since
Forever's level-60 raid content doesn't have an equivalent farm target.

### Forever dungeon/raid abbreviations

New at Forever's Nov 4, 2026 launch (levels are from the beta client and may
shift before/after launch):

- HoT — Hall of Thanes (13-18)
- RoL — Ruins of Lordaeron (15-20)
- ExcW — Excavation Site / Excavation Site: Wetlands (24-29)
- CoD — City of Dalaran (28-33)
- TDC — The Drowned City (35-40)
- KDS — Krol'dok Stronghold (40-45)
- AP — Alcaz Island Prison (48-53)
- BMH — Blackmaw Hold (55-60)
- ShT — Shaper's Terrace (58-60)

Arriving Dec 9, 2026 (five weeks after launch):

- HyS — Hyjal Summit (20-player raid; distinct from the existing `Hyjal`
  tag, which is Burning Crusade's Battle for Mount Hyjal)
- BD — The Barrow Deeps (10-player raid)
- Ony — Onyxia's Lair (40-player raid)

## Installation

1. Copy the LFGcopy folder into your World of Warcraft Interface/AddOns directory.
2. Make sure the folder is named exactly:
   - Interface/AddOns/LFGcopy
3. Reload your UI or restart the game.
4. After installing this update, `/reload` should announce **LFGcopy v6.5.0** in chat. An older version number means older files are installed.
5. Open the addon with:
   - /lfgcopy
   - or use the default keybind Alt+I

## Usage

### Commands

- /lfgcopy - toggle the addon window
- /lfgcopyroles - print raw LFG role/debug information for the current search results
- /lfgcopyclient - print a compatibility probe (detected client, build/Interface number, whether WoW Forever and/or the secret-value system were detected)

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

Settings are saved in the LFGcopyDB SavedVariables file. Existing saved choices are preserved when defaults change. Open the menu via the "Options" button on the tab strip (or right-click either tab):

- **Park collapsed groups on the second tab** (default on) — collapsing a group moves it to the Secundo tab; see "Secundo tab" above.
- **Show descriptions on collapsed groups** (default on) — the full leader comment is shown on the collapsed row (wrapped and dimmed).
- **Show group notes** (default off) — enables the per-group note area described above.

## Configuration

The addon is mostly ready to use out of the box. If you want to change the trinket-owner source, edit the configuration values at the top of LFGcopy.lua:

- TRINKET_DB_GLOBAL: the global table name used for the mage owner list
- TRINKET_FALLBACK: a manual fallback list of names
- WCL_SUBDOMAIN: set the WarcraftLogs subdomain if you need a different region style (non-Forever clients)
- WCL_FOREVER_SUBDOMAIN: the WarcraftLogs subdomain guess used on WoW Forever specifically (see the Forever section above)
- WCL_FOREVER_REALM_FALLBACK: the URL realm segment used on Forever when the client doesn't report a usable realm name

## Notes

- The addon uses Blizzard's LFG List API and will only work in a client/session where those APIs are available.
- The addon requests fuller member information for search results so that more players show up correctly.
- Some Blizzard-provided strings such as comments are displayed as text but may not be programmatically copyable.
- Options persist through `LFGcopyDB`; your notes and group/tab state persist per character through `LFGcopyCharDB`.

## Development checks

From the repository root with Lua 5.1 or later, run:

```sh
lua tests/ui_regressions.lua
lua tests/persistence_regressions.lua
lua tests/copy_popup_regressions.lua
lua tests/paladin_tank_filter_regressions.lua
```

The tests use mocked WoW APIs/widgets to check full description sizing, reused rows, permanent tabs, saved defaults, reload/relog state, full-length copying after a note popup reuses the same edit box, and (Forever-only) the Paladin-tank filter's detection logic and interaction with the other filters. Actual rendering and disk saving still need an in-game check.

## Author

This addon was created as a lightweight LFG helper focused on copy actions, role visibility, and cleaner grouping.
