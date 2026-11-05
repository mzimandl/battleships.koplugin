--[[--
One match between two players: the state machine on top of the wire format.
Pure Lua: no KOReader modules, no sockets. main.lua passes in `send(line)`
and feeds received lines to receive().

Phases: "placing" (ships being placed, waiting for READY from both),
"battle", "over". The host picks who shoots first (START). A hit or a sunk
ship lets the shooter fire again; a miss passes the turn.

receive() and the local actions return an event table for the UI (or nil when
nothing visible changed); on a protocol error receive() returns nil, error.
Events: joined, peer_ready, start, incoming (opponent's shot), result (ours),
fleet, rematch_request, rematch, left.
]]

local Board = require("battleshipswifi/board")
local Protocol = require("battleshipswifi/protocol")

local M = {}

local Match = {}
Match.__index = Match

--- opts: role = "host" | "guest", name, send(line), rand (math.random)
function M.new(opts)
    local m = setmetatable({
        role = opts.role,
        name = Protocol.clean_name(opts.name),
        send_line = opts.send,
        rand = opts.rand or math.random,
    }, Match)
    m:reset()
    return m
end

function Match:reset()
    self.phase = "placing"
    self.board = Board.new()
    self.board:randomize(self.rand)
    self.target = Board.target()
    self.ready, self.peer_ready = false, false
    self.rematch, self.peer_rematch = false, false
    self.turn, self.pending, self.winner = nil, nil, nil
    self.last_fired, self.last_incoming = nil, nil
end

function Match:send(...)
    if self.send_line then self.send_line(Protocol.line(...)) end
end

--- Guest: introduce ourselves after connecting.
function Match:hello()
    self:send("HELLO", Protocol.VERSION, self.name)
end

function Match:ping()
    self:send("PING")
end

function Match:bye()
    self:send("BYE")
end

--- Host: the opponent left before the battle; wait for another one.
function Match:drop_peer()
    self.peer = nil
    self.peer_ready = false
end

function Match:begin(first)
    self.phase = "battle"
    self.turn = first == self.role and "me" or "peer"
    return { type = "start", turn = self.turn }
end

function Match:maybe_start()
    if self.role ~= "host" or self.phase ~= "placing" then return nil end
    if not (self.peer and self.ready and self.peer_ready) then return nil end
    local first = self.rand(2) == 1 and "host" or "guest"
    self:send("START", first)
    return self:begin(first)
end

--- Confirms our fleet. Returns an event when the battle starts at once.
function Match:set_ready()
    if self.phase ~= "placing" or self.ready or not self.board:complete() then return nil end
    self.ready = true
    if self.peer then self:send("READY") end
    return self:maybe_start()
end

--- Our shot. Returns true when it was sent.
function Match:fire(x, y)
    if self.phase ~= "battle" or self.turn ~= "me" or self.pending then return false end
    if not self.target:can_fire(x, y) then return false end
    self.pending = { x, y }
    self:send("SHOT", x, y)
    return true
end

function Match:request_rematch()
    if self.phase ~= "over" or self.rematch then return nil end
    self.rematch = true
    self:send("REMATCH")
    if self.peer_rematch then
        self:reset()
        return { type = "rematch" }
    end
end

local function coords(words)
    local x, y = tonumber(words[1]), tonumber(words[2])
    if not x or not y or x % 1 ~= 0 or y % 1 ~= 0 or not Board.inside(x, y) then return nil end
    return x, y
end

local handlers = {}

function handlers:HELLO(words, rest)
    if self.role ~= "host" then return nil, "unexpected HELLO" end
    if self.peer then return nil, "already joined" end
    if tonumber(words[1]) ~= Protocol.VERSION then
        self:send("ERROR", "version")
        return nil, "version"
    end
    self.peer = Protocol.clean_name(rest:match("^%S+%s*(.*)$"))
    self:send("WELCOME", Protocol.VERSION, self.name)
    if self.ready then self:send("READY") end
    return { type = "joined", name = self.peer }
end

function handlers:WELCOME(words, rest)
    if self.role ~= "guest" or self.peer then return nil, "unexpected WELCOME" end
    if tonumber(words[1]) ~= Protocol.VERSION then return nil, "version" end
    self.peer = Protocol.clean_name(rest:match("^%S+%s*(.*)$"))
    if self.ready then self:send("READY") end
    return { type = "joined", name = self.peer }
end

function handlers:ERROR(words)
    return nil, words[1] or "error"
end

function handlers:READY()
    if self.phase ~= "placing" or not self.peer then return nil, "unexpected READY" end
    self.peer_ready = true
    return self:maybe_start() or { type = "peer_ready" }
end

function handlers:START(words)
    if self.role ~= "guest" or self.phase ~= "placing" or not (self.ready and self.peer_ready) then
        return nil, "unexpected START"
    end
    if words[1] ~= "host" and words[1] ~= "guest" then return nil, "bad START" end
    return self:begin(words[1])
end

function handlers:SHOT(words)
    if self.phase ~= "battle" or self.turn ~= "peer" then return nil, "not your turn" end
    local x, y = coords(words)
    if not x then return nil, "bad SHOT" end
    local result, ship = self.board:shoot(x, y)
    if not result then return nil, "bad SHOT" end
    self.last_incoming = { x, y }
    if ship then self:send("RESULT", x, y, result, Board.encode_ship(ship))
    else self:send("RESULT", x, y, result) end
    if result == "miss" then self.turn = "me" end
    if result == "won" then
        self.phase, self.winner = "over", "peer"
    end
    return { type = "incoming", x = x, y = y, result = result }
end

function handlers:RESULT(words)
    local x, y = coords(words)
    local p = self.pending
    if not p or not x or p[1] ~= x or p[2] ~= y then return nil, "unexpected RESULT" end
    local result = words[3]
    local ship
    if result == "sunk" or result == "won" then
        ship = Board.decode_ship(words[4])
        if not ship then return nil, "bad RESULT" end
    elseif result ~= "miss" and result ~= "hit" then
        return nil, "bad RESULT"
    end
    self.pending = nil
    self.last_fired = { x, y }
    self.target:apply(x, y, result, ship)
    if result == "miss" then self.turn = "peer" end
    if result == "won" then
        self.phase, self.winner = "over", "me"
        self:send("FLEET", self.board:encode_fleet())
    end
    return { type = "result", x = x, y = y, result = result }
end

function handlers:FLEET(words)
    if self.phase ~= "over" then return nil, "unexpected FLEET" end
    local ships = {}
    for _i, w in ipairs(words) do
        local ship = Board.decode_ship(w)
        if ship then ships[#ships + 1] = ship end
    end
    self.target:reveal(ships)
    return { type = "fleet" }
end

function handlers:REMATCH()
    if self.phase ~= "over" then return nil end
    self.peer_rematch = true
    if self.rematch then
        self:reset()
        return { type = "rematch" }
    end
    return { type = "rematch_request" }
end

function handlers:BYE()
    return { type = "left" }
end

function handlers:PING()
    return nil
end

--- A line from the opponent.
function Match:receive(line)
    local cmd, words, rest = Protocol.parse(line)
    local handler = cmd and handlers[cmd]
    if not handler then return nil end -- unknown commands are ignored (newer versions)
    return handler(self, words, rest)
end

--- Whose turn it is: "me", "peer" or nil.
function Match:my_turn()
    return self.phase == "battle" and self.turn == "me" and not self.pending
end

return M
