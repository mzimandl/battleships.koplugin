--[[--
Non-blocking sockets for a match: TCP connection, host listener, UDP discovery.
No KOReader modules: `socket` (LuaSocket) is passed in, so tests can fake it.
Everything here is polled (main.lua polls from a UIManager ZMQ), nothing blocks
except connect().
]]

local Protocol = require("battleshipswifi/protocol")

local M = {}

-- TCP connection ---------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function M.connection(sock, now)
    sock:settimeout(0)
    pcall(sock.setoption, sock, "tcp-nodelay", true)
    return setmetatable({ sock = sock, buffer = Protocol.buffer(), out = "", last_seen = now or 0 }, Conn)
end

--- Connects to host:port, blocking for at most `timeout` seconds.
-- Returns a connection, or nil, error.
function M.connect(socket, host, port, timeout, now)
    local sock = socket.tcp()
    sock:settimeout(timeout or 5)
    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, err
    end
    return M.connection(sock, now)
end

function Conn:send(line)
    if self.closed then return end
    self.out = self.out .. line
    self:flush()
end

function Conn:flush()
    if self.out == "" or self.closed then return end
    local last, err, partial = self.sock:send(self.out)
    local sent = last or partial or 0
    self.out = self.out:sub(sent + 1)
    if not last and err ~= "timeout" then self:close(err) end
end

--- Reads what has arrived. Returns the complete lines (maybe none), or nil, error
-- once the connection is closed.
function Conn:poll(now)
    if self.closed then return nil, self.error end
    self:flush()
    local lines = {}
    while not self.closed do
        local data, err, partial = self.sock:receive(4096)
        local chunk = data or partial
        if chunk and chunk ~= "" then
            self.last_seen = now or self.last_seen
            local got, berr = self.buffer:push(chunk)
            if not got then self:close(berr); break end
            for _i, l in ipairs(got) do lines[#lines + 1] = l end
        end
        if not data then
            if err ~= "timeout" then self:close(err) end
            break
        end
    end
    if self.closed and #lines == 0 then return nil, self.error end
    return lines
end

function Conn:close(err)
    if self.closed then return end
    self.closed, self.error = true, err or "closed"
    if self.out ~= "" then self.sock:send(self.out) end -- last words (BYE), best effort
    self.sock:close()
end

function Conn:peer()
    local ok, ip = pcall(self.sock.getpeername, self.sock)
    return ok and ip or nil
end

-- Host: TCP listener + discovery answers ---------------------------------------

local Host = {}
Host.__index = Host

--- Listens on `port` (TCP) and Protocol.DISCOVERY_PORT (UDP). Returns the host,
-- or nil, error (the TCP port is taken). Discovery is optional: without the UDP
-- socket the game can still be joined by address.
function M.host(socket, port)
    local server, err = socket.bind("*", port)
    if not server then return nil, err end
    server:settimeout(0)
    local udp = socket.udp()
    local ok = udp and udp:setsockname("*", Protocol.DISCOVERY_PORT)
    if ok then udp:settimeout(0) else
        if udp then udp:close() end
        udp = nil
    end
    return setmetatable({ server = server, udp = udp, port = port }, Host)
end

--- A new TCP client socket, or nil.
function Host:accept()
    local client = self.server:accept()
    return client
end

--- Answers discovery requests with our name (only when `name` is given, i.e.
-- while waiting for an opponent).
function Host:answer(name)
    if not self.udp then return end
    while true do
        local msg, ip, port = self.udp:receivefrom()
        if not msg then break end
        if name and Protocol.is_discover(msg) then
            self.udp:sendto(Protocol.announce(self.port, name), ip, port)
        end
    end
end

function Host:close()
    self.server:close()
    if self.udp then self.udp:close() end
end

-- Guest: discovery --------------------------------------------------------------

local Search = {}
Search.__index = Search

--- Broadcasts DISCOVER (send(now) every second or so) and collects answers in
-- `games` (list of { ip, port, name, seen }).
function M.search(socket, local_ip)
    local udp = socket.udp()
    if not udp then return nil, "udp" end
    if not udp:setsockname("*", Protocol.SEARCH_PORT) then
        udp:close()
        udp = socket.udp()
        udp:setsockname("*", 0)
    end
    udp:settimeout(0)
    udp:setoption("broadcast", true)
    return setmetatable({ udp = udp, games = {}, targets = Protocol.broadcasts(local_ip) }, Search)
end

function Search:send()
    for _i, addr in ipairs(self.targets) do
        self.udp:sendto(Protocol.discover(), addr, Protocol.DISCOVERY_PORT)
    end
end

--- Reads answers. Returns true when the list of games changed.
function Search:poll(now)
    local changed = false
    while true do
        local msg, ip = self.udp:receivefrom()
        if not msg then break end
        local game = Protocol.parse_announce(msg)
        if game then
            local found
            for _i, g in ipairs(self.games) do
                if g.ip == ip and g.port == game.port then found = g end
            end
            if found then
                if found.name ~= game.name then changed = true end
                found.name, found.seen = game.name, now
            else
                table.insert(self.games, { ip = ip, port = game.port, name = game.name, seen = now })
                changed = true
            end
        end
    end
    return changed
end

--- Drops games not heard of for `age` seconds. Returns true when any was dropped.
function Search:expire(now, age)
    local changed = false
    for i = #self.games, 1, -1 do
        if now - self.games[i].seen > age then
            table.remove(self.games, i)
            changed = true
        end
    end
    return changed
end

function Search:close()
    self.udp:close()
end

--- Address of the network interface used for outgoing traffic (connecting a
-- UDP socket sends nothing).
function M.local_ip(socket)
    local ok, ip = pcall(function()
        local udp = socket.udp()
        udp:setpeername("8.8.8.8", 80)
        local addr = udp:getsockname()
        udp:close()
        return addr
    end)
    if ok and ip and ip ~= "0.0.0.0" then return ip end
end

return M
