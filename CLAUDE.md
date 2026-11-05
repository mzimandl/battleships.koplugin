# KOReader Battleships (Wi-Fi)
- Repo root is the plugin folder (battleshipswifi.koplugin). Plugin id, folder and module are `battleshipswifi` since 0.2.0 (before: `battleships`, renamed like backgammonwifi.koplugin to stay clear of other plugins in ZenPM); init() copies name/last_address from the old battleships.lua settings once. Pure-Lua modules in battleshipswifi/ must not require KOReader modules (testable off-device); net.lua gets LuaSocket passed in.
- Only main.lua touches KOReader APIs. Verify API names against koreader/koreader source before using them.
- LuaJIT 2.1 / Lua 5.1: no utf8 library, no goto.
- Tests: `luajit tests/run.lua` (board, protocol, two Match instances wired together, net with fake sockets, translations) and `luajit tests/smoke.lua` (main.lua against stubbed KOReader modules and a fake `socket`) must pass before finishing any change (`lua5.1` works too). smoke.lua finds menu items by their `battleshipswifi_item` field.
- Translations: main.lua's `_` (battleshipswifi/l10n.lua) looks up battleshipswifi/l10n/<lang>.lua first. Every new `_("…")` needs an entry in battleshipswifi/l10n/cs.lua (run.lua checks both ways); _meta.lua keeps its Czech inline. Czech texts avoid past-tense verbs with a player name (gender unknown): "%1 odchází", "Vyhrává %1".
- Distributed through ZenPM from mzimandl/koplugins (manifest.json, installs the master branch zip). ZenPM offers an update only when `version` in _meta.lua grows: bump it for every change that should reach devices. A push to master that changes _meta.lua asks koplugins to sync at once (.github/workflows/notify-koplugins.yml, secret KOPLUGINS_TOKEN).
- Own modules must be required at load time from main.lua (PluginLoader only adds the plugin folder to package.path while main.lua loads).

## Modules
- board.lua: Board (own ships + opponent's shots: shoot() → miss/hit/sunk/won), Target (what we know of the opponent's board; "near" = water around a sunk ship, auto-marked since ships may not touch). 0-based x/y, ship = { x, y, len, dir "h"/"v", hits }, wire form "x,y,len,dir". Placing: placed(i, x, y, dir) is the one check behind move()/rotate()/can_rotate()/blocked() (squares shaded for the selected ship), so the shading always matches what a tap does.
- protocol.lua: line format (documented at its top), Buffer for partial TCP reads, address parsing, discovery messages, ports.
- match.lua: state machine of one match (phases placing → battle → over, rematch back to placing). receive(line) → event | nil | nil, error; local actions set_ready()/fire()/request_rematch(). The host sends START (random first player). Unknown commands are ignored, so new commands can be added without breaking older versions; changing the meaning of existing ones needs Protocol.VERSION + 1 (both sides refuse other versions).
- net.lua: non-blocking Conn (out buffer for partial sends), Host (TCP listener + UDP discovery answers), Search (DISCOVER broadcasts to 255.255.255.255 and the /24 broadcast, games list with expiry).

## main.lua
- State is module-level (`game`, `finder`), not on `self`: KOReader makes a new plugin instance for every reader/file manager.
- Sockets are polled from UIManager ZMQs (poller(): waitEvent() runs every ~50 ms and must return nil). preventStandby() while a game runs; onSuspend/onExit end the game and the search.
- GameScreen rebuilds its whole widget tree on every update() (build()); status text comes from the match state plus `game.message` (last event). BoardWidget paints the grid itself (Blitbuffer paintRect/paintCircle/paintBorder) and maps taps to cells.
- Host: the guest leaving before the battle (or timing out) frees the seat (Match:drop_peer()); a second guest while one is connected gets ERROR busy. After the battle starts any loss ends the game (`game.lost`).
- Kindle: iptables rules opened per role (host_rules / guest_rules / search_rules) and removed with the same list.
