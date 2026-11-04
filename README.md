# Battleships for KOReader

The classic Battleships game for two players, each on their own e-reader, over Wi-Fi. English, with a Czech translation (Lodě).

## Playing
Both devices must be on the same Wi-Fi network. In the menu: **Tools → Battleships**.

- **Host a game**: one player opens a game and places their ships right away. The screen shows the device's address.
- **Find a game**: the other player sees games open on the local network (UDP broadcast) and taps one to join.
- **Join by address…**: when the search finds nothing (some networks block broadcasts), type the address shown on the host's screen, e.g. `192.168.1.10` (or `192.168.1.10:7531`).
- **Your name**: shown to the other player and in the list of games (default: the device model).

### Rules
- Each player has five ships (5, 4, 3, 3 and 2 squares) on a 10 × 10 board. Ships may not touch, not even at the corners.
- Placing: the fleet starts at random positions (**Random** shuffles it again). Tap a ship to select it, tap it again to turn it, tap the water to move it there. While a ship is selected, the squares it doesn't fit on are shaded, and the status line says when it has no room to turn. **Ready** when done.
- The host's device picks who fires first. After a hit you fire again; after a miss it's the opponent's turn.
- Water around a sunk ship is marked automatically. Whoever sinks the whole enemy fleet first wins; the loser then sees the winner's remaining ships. **Play again** starts a new round once both players tap it.

Board marks: gray = ship (dark gray = selected), light gray = no room for the selected ship, small dot = miss, black square = hit, black = sunk ship, light dot = water next to a sunk ship. The last shot is outlined.

## Network
- TCP 7531 (the game, host), UDP 7532 (host answers searches), UDP 7533 (searching device listens for answers).
- On Kindle the plugin opens these ports in the firewall (iptables) for the time of the game.
- The device doesn't go to standby during a game; going to sleep ends it.

## Development
Off-device tests (`lua5.1` works too when luajit isn't installed):

```bash
luajit tests/run.lua
```

```bash
luajit tests/smoke.lua
```
