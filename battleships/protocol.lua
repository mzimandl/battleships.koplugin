--[[--
Wire format. Pure Lua: no KOReader modules.

TCP: one message per line ("\n"), words separated by spaces. A player name is
the rest of its line. Guest → host first: HELLO <version> <name>; the host
answers WELCOME <version> <name>, or ERROR <reason> and closes.
Then both sides: READY, START host|guest (host only), SHOT x y,
RESULT x y miss|hit|sunk|won [ship], FLEET [ship ...], REMATCH, PING, BYE.
A ship is "x,y,len,dir" (see board.lua).

UDP discovery: a guest sends DISCOVER <version> to the broadcast address,
the host waiting for an opponent answers GAME <version> <tcp port> <name>.
]]

local M = {}

M.VERSION = 1
M.PORT = 7531           -- TCP, host
M.DISCOVERY_PORT = 7532 -- UDP, host listens
M.SEARCH_PORT = 7533    -- UDP, guest listens for answers
M.MAX_NAME = 24         -- characters
M.MAX_LINE = 512        -- bytes; longer lines are an error

--- Name cleaned for the wire: no control characters, at most MAX_NAME characters.
function M.clean_name(name)
    name = tostring(name or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local out, count = {}, 0
    for ch in name:gmatch("[\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > M.MAX_NAME then break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

--- Splits a line into its command and words; `rest` = everything after the command.
function M.parse(line)
    local cmd, rest = line:match("^(%u+)%s*(.-)%s*$")
    if not cmd then return nil end
    local words = {}
    for w in rest:gmatch("%S+") do words[#words + 1] = w end
    return cmd, words, rest
end

function M.line(...)
    return table.concat({ ... }, " ") .. "\n"
end

--- Collects TCP data and returns complete lines.
local Buffer = {}
Buffer.__index = Buffer

function M.buffer()
    return setmetatable({ data = "" }, Buffer)
end

--- Adds received data; returns the complete lines, or nil, "too long".
function Buffer:push(chunk)
    self.data = self.data .. chunk
    local lines = {}
    while true do
        local nl = self.data:find("\n", 1, true)
        if not nl then break end
        lines[#lines + 1] = self.data:sub(1, nl - 1):gsub("\r$", "")
        self.data = self.data:sub(nl + 1)
    end
    if #self.data > M.MAX_LINE then return nil, "too long" end
    return lines
end

--- "192.168.1.5" or "192.168.1.5:7000" → host, port (default PORT); nil when invalid.
function M.parse_address(s)
    s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local host, port = s:match("^([%w%.%-]+):(%d+)$")
    if not host then host = s:match("^[%w%.%-]+$") end
    if not host then return nil end
    port = tonumber(port) or M.PORT
    if port < 1 or port > 65535 then return nil end
    return host, port
end

--- Broadcast addresses to try for a local IPv4 address (assumes /24 besides the global one).
function M.broadcasts(ip)
    local out = { "255.255.255.255" }
    local a, b, c = (ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then table.insert(out, a .. "." .. b .. "." .. c .. ".255") end
    return out
end

function M.discover()
    return "DISCOVER " .. M.VERSION
end

function M.announce(port, name)
    return string.format("GAME %d %d %s", M.VERSION, port, M.clean_name(name))
end

--- An answer to DISCOVER: { port, name }, or nil for anything else.
function M.parse_announce(msg)
    local version, port, name = (msg or ""):match("^GAME (%d+) (%d+) ?(.-)%s*$")
    if not version or tonumber(version) ~= M.VERSION then return nil end
    return { port = tonumber(port), name = M.clean_name(name) }
end

function M.is_discover(msg)
    local version = (msg or ""):match("^DISCOVER (%d+)")
    return version ~= nil and tonumber(version) == M.VERSION
end

return M
