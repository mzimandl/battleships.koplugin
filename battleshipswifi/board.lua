--[[--
Battleships boards. Pure Lua: no KOReader modules.

Coordinates are 0-based: x = column (A–J), y = row (1–10).
A ship is { x, y, len, dir = "h" | "v", hits }; (x, y) is its top/left cell.
Ships may not overlap or touch, not even diagonally.
]]

local M = {}

M.SIZE = 10
M.FLEET = { 5, 4, 3, 3, 2 }

local function inside(x, y)
    return x >= 0 and y >= 0 and x < M.SIZE and y < M.SIZE
end
M.inside = inside

--- Cells of a ship: list of { x, y }.
function M.cells(ship)
    local out = {}
    for i = 0, ship.len - 1 do
        if ship.dir == "h" then
            out[#out + 1] = { ship.x + i, ship.y }
        else
            out[#out + 1] = { ship.x, ship.y + i }
        end
    end
    return out
end

local function covers(ship, x, y)
    if ship.dir == "h" then
        return y == ship.y and x >= ship.x and x < ship.x + ship.len
    end
    return x == ship.x and y >= ship.y and y < ship.y + ship.len
end

--- Water cells around a ship (inside the board).
function M.around(ship)
    local out = {}
    local w = ship.dir == "h" and ship.len or 1
    local h = ship.dir == "v" and ship.len or 1
    for y = ship.y - 1, ship.y + h do
        for x = ship.x - 1, ship.x + w do
            if inside(x, y) and not covers(ship, x, y) then out[#out + 1] = { x, y } end
        end
    end
    return out
end

function M.encode_ship(ship)
    return string.format("%d,%d,%d,%s", ship.x, ship.y, ship.len, ship.dir)
end

function M.decode_ship(s)
    local x, y, len, dir = (s or ""):match("^(%d+),(%d+),(%d+),([hv])$")
    if not x then return nil end
    local ship = { x = tonumber(x), y = tonumber(y), len = tonumber(len), dir = dir, hits = 0 }
    if ship.len < 1 or ship.len > M.SIZE then return nil end
    local last = M.cells(ship)[ship.len]
    if not inside(ship.x, ship.y) or not inside(last[1], last[2]) then return nil end
    return ship
end

-- Own board -------------------------------------------------------------------

local Board = {}
Board.__index = Board

function M.new()
    local b = setmetatable({ ships = {}, shots = {} }, Board)
    for y = 0, M.SIZE - 1 do b.shots[y] = {} end
    return b
end

--- Index of the ship on (x, y), or nil.
function Board:ship_at(x, y)
    for i, ship in ipairs(self.ships) do
        if covers(ship, x, y) then return i end
    end
end

--- Whether `ship` fits on the board without touching the others (ship `skip` ignored).
function Board:fits(ship, skip)
    local last = M.cells(ship)[ship.len]
    if not inside(ship.x, ship.y) or not inside(last[1], last[2]) then return false end
    for i, other in ipairs(self.ships) do
        if i ~= skip then
            local ow = other.dir == "h" and other.len or 1
            local oh = other.dir == "v" and other.len or 1
            local sw = ship.dir == "h" and ship.len or 1
            local sh = ship.dir == "v" and ship.len or 1
            -- rectangles grown by one cell overlap → touching
            if ship.x <= other.x + ow and other.x <= ship.x + sw
                and ship.y <= other.y + oh and other.y <= ship.y + sh then
                return false
            end
        end
    end
    return true
end

--- Places the whole fleet at random. rand(n) returns 1..n (math.random).
function Board:randomize(rand)
    rand = rand or math.random
    for _attempt = 1, 100 do
        self.ships = {}
        local ok = true
        for _i, len in ipairs(M.FLEET) do
            local placed = false
            for _try = 1, 200 do
                local dir = rand(2) == 1 and "h" or "v"
                local span = M.SIZE - len + 1
                local ship = { len = len, dir = dir, hits = 0 }
                if dir == "h" then
                    ship.x, ship.y = rand(span) - 1, rand(M.SIZE) - 1
                else
                    ship.x, ship.y = rand(M.SIZE) - 1, rand(span) - 1
                end
                if self:fits(ship) then
                    table.insert(self.ships, ship)
                    placed = true
                    break
                end
            end
            if not placed then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

-- Ship i placed with its top/left cell at x, y (moved back onto the board when
-- the tap is near the edge) and `dir`; nil when it doesn't fit there.
function Board:placed(i, x, y, dir)
    local ship = self.ships[i]
    local moved = { x = x, y = y, len = ship.len, dir = dir or ship.dir, hits = 0 }
    if moved.dir == "h" then moved.x = math.min(x, M.SIZE - moved.len)
    else moved.y = math.min(y, M.SIZE - moved.len) end
    if self:fits(moved, i) then return moved end
end

--- Moves ship i so that its top/left cell is (x, y). Returns true when it fits.
function Board:move(i, x, y)
    local moved = self:placed(i, x, y)
    if not moved then return false end
    self.ships[i] = moved
    return true
end

--- Whether ship i can turn around its top/left cell.
function Board:can_rotate(i)
    local ship = self.ships[i]
    return self:placed(i, ship.x, ship.y, ship.dir == "h" and "v" or "h") ~= nil
end

--- Rotates ship i around its top/left cell. Returns true when it fits.
function Board:rotate(i)
    local ship = self.ships[i]
    local turned = self:placed(i, ship.x, ship.y, ship.dir == "h" and "v" or "h")
    if not turned then return false end
    self.ships[i] = turned
    return true
end

--- Water squares where tapping can't move ship i (it wouldn't fit):
-- blocked[y][x] = true.
function Board:blocked(i)
    local blocked = {}
    for y = 0, M.SIZE - 1 do
        blocked[y] = {}
        for x = 0, M.SIZE - 1 do
            if not self:ship_at(x, y) and not self:placed(i, x, y) then blocked[y][x] = true end
        end
    end
    return blocked
end

--- Whether the fleet is complete (all of M.FLEET placed).
function Board:complete()
    return #self.ships == #M.FLEET
end

--- An opponent's shot. Returns "miss" | "hit" | "sunk" | "won" and the ship
-- (for sunk/won), or nil, "repeat" / "outside".
function Board:shoot(x, y)
    if not inside(x, y) then return nil, "outside" end
    if self.shots[y][x] then return nil, "repeat" end
    local i = self:ship_at(x, y)
    if not i then
        self.shots[y][x] = "miss"
        return "miss"
    end
    self.shots[y][x] = "hit"
    local ship = self.ships[i]
    ship.hits = ship.hits + 1
    if ship.hits < ship.len then return "hit" end
    for _i, other in ipairs(self.ships) do
        if other.hits < other.len then return "sunk", ship end
    end
    return "won", ship
end

function Board:encode_fleet()
    local parts = {}
    for _i, ship in ipairs(self.ships) do parts[#parts + 1] = M.encode_ship(ship) end
    return table.concat(parts, " ")
end

-- Target board (what we know of the opponent's) ------------------------------

local Target = {}
Target.__index = Target

--- marks[y][x]: nil (unknown), "miss", "near" (water next to a sunk ship),
-- "hit", "sunk". `ships` = sunk ships and, after the game, the revealed fleet.
function M.target()
    local t = setmetatable({ marks = {}, ships = {}, sunk = 0 }, Target)
    for y = 0, M.SIZE - 1 do t.marks[y] = {} end
    return t
end

function Target:can_fire(x, y)
    return inside(x, y) and self.marks[y][x] == nil
end

--- Records the result of our shot; `ship` comes with sunk/won.
function Target:apply(x, y, result, ship)
    if result == "miss" then
        self.marks[y][x] = "miss"
        return
    end
    self.marks[y][x] = "hit"
    if (result == "sunk" or result == "won") and ship then
        self.sunk = self.sunk + 1
        table.insert(self.ships, ship)
        for _i, c in ipairs(M.cells(ship)) do self.marks[c[2]][c[1]] = "sunk" end
        for _i, c in ipairs(M.around(ship)) do
            if self.marks[c[2]][c[1]] == nil then self.marks[c[2]][c[1]] = "near" end
        end
    end
end

--- Adds the opponent's revealed fleet (after the game); sunk ships are skipped.
function Target:reveal(ships)
    for _i, ship in ipairs(ships) do
        local known = false
        for _j, s in ipairs(self.ships) do
            if s.x == ship.x and s.y == ship.y and s.dir == ship.dir and s.len == ship.len then known = true end
        end
        if not known then
            ship.revealed = true
            table.insert(self.ships, ship)
        end
    end
end

--- Index into ships of the ship covering (x, y), or nil.
function Target:ship_at(x, y)
    for i, ship in ipairs(self.ships) do
        if covers(ship, x, y) then return i end
    end
end

--- Column letter and row number: (0, 0) → "A1".
function M.label(x, y)
    return string.char(65 + x) .. tostring(y + 1)
end

return M
