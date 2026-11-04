-- Off-device tests. Run from the repo root:  luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local Board = require("battleships/board")
local Protocol = require("battleships/protocol")
local Match = require("battleships/match")
local Net = require("battleships/net")

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n  expected: %q\n  actual:   %q"):format(name, tostring(expected), tostring(actual)))
    end
end

-- Seeded random numbers, the same on every Lua version.
local function rng(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return s % n + 1
    end
end

-- Board: placement ------------------------------------------------------------
local function ship(x, y, len, dir) return { x = x, y = y, len = len, dir = dir, hits = 0 } end

local b = Board.new()
b.ships = { ship(0, 0, 3, "h") }
eq(b:fits(ship(0, 2, 2, "h")), true, "one row of water between ships is enough")
eq(b:fits(ship(3, 1, 2, "h")), false, "ships may not touch at a corner")
eq(b:fits(ship(3, 0, 2, "v")), false, "ships may not touch at the end")
eq(b:fits(ship(4, 0, 2, "v")), true, "a gap of one column is enough")
eq(b:fits(ship(9, 0, 2, "h")), false, "ships stay on the board")
eq(b:fits(ship(1, 0, 3, "h"), 1), true, "the ship itself is ignored when moving it")
eq(b:ship_at(2, 0), 1, "ship_at finds the ship")
eq(b:ship_at(3, 0), nil, "ship_at: water")

for seed = 1, 20 do
    local r = Board.new()
    eq(r:randomize(rng(seed)), true, "random fleet " .. seed)
    local ok = r:complete()
    for i, s in ipairs(r.ships) do
        if not r:fits(s, i) then ok = false end
    end
    eq(ok, true, "random fleet is valid " .. seed)
end

b = Board.new()
b.ships = { ship(8, 0, 2, "h"), ship(0, 5, 3, "v") }
eq(b:rotate(1), true, "rotate a ship")
eq(Board.encode_ship(b.ships[1]), "8,0,2,v", "rotated around its first cell")
eq(b:rotate(2), true, "rotate at the edge")
eq(Board.encode_ship(b.ships[2]), "0,5,3,h", "rotated ship")
eq(b:move(2, 9, 9), true, "move near the edge")
eq(Board.encode_ship(b.ships[2]), "7,9,3,h", "moved ship kept on the board")
eq(b:move(2, 7, 1), false, "can't move next to another ship")
eq(Board.encode_ship(b.ships[2]), "7,9,3,h", "failed move leaves the ship")
b.ships = { ship(0, 0, 4, "h"), ship(0, 2, 2, "h") }
eq(b:rotate(1), false, "can't rotate onto another ship")

-- Board: shooting -------------------------------------------------------------
b = Board.new()
b.ships = { ship(0, 0, 2, "h"), ship(5, 5, 1, "h") }
eq(b:shoot(9, 9), "miss", "miss")
eq(select(2, b:shoot(9, 9)), "repeat", "same square twice")
eq(select(2, b:shoot(10, 0)), "outside", "outside the board")
eq(b:shoot(0, 0), "hit", "hit")
local res, sunk = b:shoot(1, 0)
eq(res .. " " .. Board.encode_ship(sunk), "sunk 0,0,2,h", "sunk with its ship")
eq(b:shoot(5, 5), "won", "last ship sunk wins")
eq(b:encode_fleet(), "0,0,2,h 5,5,1,h", "fleet encoding")

local t = Board.target()
eq(t:can_fire(3, 3), true, "unknown square can be fired at")
t:apply(3, 3, "miss")
eq(t:can_fire(3, 3), false, "known square can't")
t:apply(0, 0, "hit")
t:apply(1, 0, "sunk", ship(0, 0, 2, "h"))
eq(t.marks[0][0] .. t.marks[0][1], "sunksunk", "sunk ship marked")
eq(t.marks[1][2], "near", "water around a sunk ship is marked")
eq(t:can_fire(2, 1), false, "can't fire next to a sunk ship")
eq(t.marks[3][3], "miss", "misses stay")
t:reveal({ ship(0, 0, 2, "h"), ship(5, 5, 3, "v") })
eq(#t.ships, 2, "revealed fleet adds only unknown ships")
eq(t:ship_at(5, 7), 2, "revealed ship found")

eq(Board.label(0, 0) .. Board.label(9, 9), "A1J10", "labels")
eq(Board.decode_ship("8,0,3,h"), nil, "ship off the board rejected")
eq(Board.decode_ship("1,2,3,x"), nil, "bad direction rejected")
eq(Board.encode_ship(Board.decode_ship("1,2,3,v")), "1,2,3,v", "ship round trip")
eq(#Board.around(ship(0, 0, 2, "h")), 4, "water around a corner ship")

-- Protocol ----------------------------------------------------------------------
eq(Protocol.clean_name("  Ann\nB\tc  "), "Ann B c", "names lose control characters")
eq(Protocol.clean_name(string.rep("ž", 30)), string.rep("ž", 24), "names are cut by characters")
local cmd, words, rest = Protocol.parse("HELLO 1 Žluťoučký kůň")
eq(cmd .. "|" .. words[1] .. "|" .. rest, "HELLO|1|1 Žluťoučký kůň", "parse")
eq(Protocol.parse("hello"), nil, "commands are upper case")
local buf = Protocol.buffer()
eq(#buf:push("PI"), 0, "partial line waits")
local lines = buf:push("NG\r\nSHOT 1 2\nRES")
eq(table.concat(lines, ","), "PING,SHOT 1 2", "complete lines")
eq(buf:push("ULT\n")[1], "RESULT", "rest of the line")
eq(select(2, buf:push(string.rep("x", 600))), "too long", "endless line is an error")
local h, p = Protocol.parse_address(" 192.168.1.5 ")
eq(h .. ":" .. p, "192.168.1.5:" .. Protocol.PORT, "address without port")
h, p = Protocol.parse_address("10.0.0.2:7000")
eq(h .. ":" .. p, "10.0.0.2:7000", "address with port")
eq(Protocol.parse_address("10.0.0.2:99999"), nil, "port out of range")
eq(Protocol.parse_address("a b"), nil, "invalid address")
eq(table.concat(Protocol.broadcasts("192.168.1.5"), ","), "255.255.255.255,192.168.1.255", "broadcast addresses")
eq(#Protocol.broadcasts(nil), 1, "global broadcast without an address")
eq(Protocol.is_discover(Protocol.discover()), true, "discover")
eq(Protocol.is_discover("DISCOVER 99"), false, "other version ignored")
local ann = Protocol.parse_announce(Protocol.announce(7531, "Kindle Paperwhite"))
eq(ann.port .. " " .. ann.name, "7531 Kindle Paperwhite", "announce round trip")
eq(Protocol.parse_announce("GAME 99 7531 x"), nil, "announce of another version ignored")

-- Match: two players wired together ------------------------------------------
local function pair(seed)
    local host, guest
    local to_guest, to_host = {}, {}
    host = Match.new{ role = "host", name = "Host", rand = rng(seed), send = function(l) table.insert(to_guest, l) end }
    guest = Match.new{ role = "guest", name = "Guest", rand = rng(seed + 100), send = function(l) table.insert(to_host, l) end }
    local events = { host = {}, guest = {} }
    local function deliver()
        local any = true
        while any do
            any = false
            while #to_host > 0 do
                any = true
                local l = table.remove(to_host, 1):gsub("\n$", "")
                local ev, err = host:receive(l)
                assert(not err, "host: " .. tostring(err) .. " on " .. l)
                if ev then table.insert(events.host, ev.type) end
            end
            while #to_guest > 0 do
                any = true
                local l = table.remove(to_guest, 1):gsub("\n$", "")
                local ev, err = guest:receive(l)
                assert(not err, "guest: " .. tostring(err) .. " on " .. l)
                if ev then table.insert(events.guest, ev.type) end
            end
        end
    end
    return host, guest, deliver, events
end

local host, guest, deliver, events = pair(7)
eq(host.phase, "placing", "host starts placing")
eq(host.board:complete(), true, "a random fleet is ready at the start")
eq(host:set_ready(), nil, "host ready before anyone joined")
guest:hello()
deliver()
eq(host.peer .. "/" .. guest.peer, "Guest/Host", "names exchanged")
eq(guest.peer_ready, true, "guest learns that the host is ready")
eq(events.host[1], "joined", "host: joined event")
local ev = guest:set_ready()
deliver()
eq(host.phase .. guest.phase, "battlebattle", "both ready: the battle starts")
eq(events.guest[#events.guest], "start", "guest: start event")
eq((host.turn == "me") ~= (guest.turn == "me"), true, "exactly one player's turn")
eq(guest:fire(0, 0) and host:fire(0, 0), false, "only the player on turn can fire")

-- play the whole game: each player fires at every square in order
local function play(a, z, deliver_fn)
    local next_shot = { [a] = 0, [z] = 0 }
    for _step = 1, 400 do
        if a.phase ~= "battle" then break end
        local shooter = a:my_turn() and a or z
        repeat
            local n = next_shot[shooter]
            next_shot[shooter] = n + 1
            local x, y = n % 10, math.floor(n / 10)
            local fired = shooter.target:can_fire(x, y) and shooter:fire(x, y)
        until fired
        deliver_fn()
    end
end
play(host, guest, deliver)
eq(host.phase .. guest.phase, "overover", "the game ends")
eq((host.winner == "me") ~= (guest.winner == "me"), true, "exactly one winner")
local winner, loser = host, guest
if guest.winner == "me" then winner, loser = guest, host end
eq(winner.target.sunk, #Board.FLEET, "winner sank the whole fleet")
eq(#loser.target.ships, #Board.FLEET, "loser sees the winner's whole fleet")
eq(winner:fire(9, 9), false, "no shots after the game")

guest:request_rematch()
deliver()
eq(host.phase, "over", "rematch needs both players")
eq(events.host[#events.host], "rematch_request", "host: rematch request")
host:request_rematch()
deliver()
eq(host.phase .. guest.phase, "placingplacing", "rematch: both place ships again")
eq(host.ready or guest.ready or host.peer_ready, false, "rematch resets ready")
eq(host.peer, "Guest", "rematch keeps the opponent")

-- protocol errors
host, guest, deliver = pair(3)
eq(select(2, guest:receive("SHOT 1 1")), "not your turn", "shot before the battle")
eq(select(2, guest:receive("HELLO 1 x")), "unexpected HELLO", "guest doesn't take HELLO")
eq(select(2, host:receive("HELLO 99 x")), "version", "other version refused")
eq(select(2, host:receive("READY")), "unexpected READY", "READY before HELLO")
eq(host:receive("FUTURE stuff"), nil, "unknown commands are ignored")
eq(select(2, host:receive("ERROR busy")), "busy", "ERROR ends the match")
host:receive("HELLO 1 G")
eq(select(2, host:receive("HELLO 1 G")), "already joined", "second HELLO refused")
host:set_ready()
host:receive("READY")
eq(host.phase, "battle", "host starts when both are ready")
host.turn = "peer"
eq(select(2, host:receive("SHOT 10 0")), "bad SHOT", "shot outside the board")
host:receive("SHOT 0 0")
eq(select(2, host:receive("SHOT 0 0")) ~= nil, true, "same square twice is an error (or not the turn)")
host.turn, host.pending = "me", nil
host:fire(4, 4)
eq(select(2, host:receive("RESULT 5 5 miss")), "unexpected RESULT", "result for another square")
eq(select(2, host:receive("RESULT 4 4 sunk")), "bad RESULT", "sunk without the ship")
host:receive("RESULT 4 4 miss")
eq(host.turn, "peer", "miss passes the turn")

-- the host's opponent leaves before the battle
host = Match.new{ role = "host", name = "H", send = function() end }
host:receive("HELLO 1 G")
host:receive("READY")
host:drop_peer()
eq(host.peer == nil and not host.peer_ready, true, "drop_peer waits for another opponent")

-- Net with fake sockets ----------------------------------------------------------
local function fake_tcp(incoming)
    local s = { sent = "", incoming = incoming or {}, closed = false }
    function s:settimeout() end
    function s:setoption() return true end
    function s:send(data) self.sent = self.sent .. data; return #data end
    function s:receive()
        local chunk = table.remove(self.incoming, 1)
        if chunk == "CLOSE" then return nil, "closed", "" end
        if chunk then return nil, "timeout", chunk end
        return nil, "timeout", ""
    end
    function s:close() self.closed = true end
    return s
end

local sock = fake_tcp({ "PING\nSHO", "T 1 2\n" })
local conn = Net.connection(sock, 0)
local got = conn:poll(5)
eq(table.concat(got, ","), "PING", "first poll: one line")
eq(conn.last_seen, 5, "data updates last_seen")
eq(conn:poll(6)[1], "SHOT 1 2", "line completed in the next poll")
eq(#conn:poll(7), 0, "nothing more")
eq(conn.last_seen, 6, "no data, last_seen kept")
conn:send("BYE\n")
eq(sock.sent, "BYE\n", "send")
sock.incoming = { "CLOSE" }
eq(select(2, conn:poll(8)), "closed", "closed connection reported")
eq(sock.closed, true, "socket closed")

-- partial sends are kept for later
sock = fake_tcp()
local accept = 2
function sock:send(data)
    local n = math.min(accept, #data)
    self.sent = self.sent .. data:sub(1, n)
    if n < #data then return nil, "timeout", n end
    return n
end
conn = Net.connection(sock, 0)
conn:send("ABCDEF\n")
eq(sock.sent, "AB", "partial send")
accept = 100
conn:poll(1)
eq(sock.sent, "ABCDEF\n", "rest sent on the next poll")

-- discovery
local function fake_udp()
    local u = { out = {}, inbox = {} }
    function u:setsockname(_h, port) self.port = port; return true end
    function u:settimeout() end
    function u:setoption() return true end
    function u:sendto(msg, ip, port) table.insert(self.out, { msg, ip, port }) end
    function u:receivefrom()
        local m = table.remove(self.inbox, 1)
        if not m then return nil, "timeout" end
        return m[1], m[2], m[3]
    end
    function u:close() self.closed = true end
    return u
end
local udps = {}
local fake_socket = {
    udp = function() local u = fake_udp(); table.insert(udps, u); return u end,
    bind = function() local s = fake_tcp(); s.accept = function() return nil end; return s end,
}
local hst = Net.host(fake_socket, 7531)
local hudp = udps[#udps]
eq(hudp.port, Protocol.DISCOVERY_PORT, "host listens for discovery")
hudp.inbox = { { "DISCOVER 1", "10.0.0.9", 7533 }, { "junk", "10.0.0.8", 1 } }
hst:answer("Host")
eq(#hudp.out .. " " .. hudp.out[1][1] .. " " .. hudp.out[1][2], "1 GAME 1 7531 Host 10.0.0.9", "host answers DISCOVER only")
hudp.inbox = { { "DISCOVER 1", "10.0.0.9", 7533 } }
hst:answer(nil)
eq(#hudp.out, 1, "no answers once the game is full")

local search = Net.search(fake_socket, "10.0.0.5")
local sudp = udps[#udps]
eq(sudp.port, Protocol.SEARCH_PORT, "search listens on its port")
search:send()
eq(#sudp.out .. " " .. sudp.out[2][2], "2 10.0.0.255", "discover broadcast to both addresses")
sudp.inbox = { { "GAME 1 7531 Host", "10.0.0.9", 7532 }, { "GAME 1 7531 Host", "10.0.0.9", 7532 } }
eq(search:poll(1), true, "found a game")
eq(#search.games .. " " .. search.games[1].name .. " " .. search.games[1].ip, "1 Host 10.0.0.9", "one entry per host")
eq(search:poll(2), false, "nothing new")
eq(search:expire(4, 5), false, "recently seen game stays")
eq(search:expire(7, 5), true, "silent game dropped")
eq(#search.games, 0, "list empty")

-- L10n: every _("…") of main.lua is translated, and the catalog has no stale entries
loadstring = loadstring or load
local function msgids(path)
    local src = io.open(path):read("*a")
    local ids = {}
    for lit in src:gmatch('_%(%s*(".-[^\\]")%s*%)') do ids[loadstring("return " .. lit)()] = true end
    for lit in src:gmatch('_%(%s*%[%[(.-)%]%]%s*%)') do ids[lit] = true end
    return ids
end
local used = msgids("main.lua")
local cs = require("battleships/l10n/cs")
local missing, stale = {}, {}
for id in pairs(used) do if not cs[id] then missing[#missing + 1] = id end end
for id in pairs(cs) do if not used[id] then stale[#stale + 1] = id end end
table.sort(missing); table.sort(stale)
eq(table.concat(missing, " | "), "", "all strings translated to Czech")
eq(table.concat(stale, " | "), "", "no unused Czech translations")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
