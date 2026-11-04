-- Smoke test of main.lua against stubbed KOReader modules and fake sockets.
-- Run from the repo root:  luajit tests/smoke.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("TMPDIR") or "/tmp"
local root = tmp .. "/battleships-smoke-" .. os.time()
os.execute("mkdir -p " .. root .. "/settings")

local shown, notes, toasts = {}, {}, {}
local function stub(name, mod) package.preload[name] = function() return mod end end
local function class(t)
    t = t or {}
    t.extend = function(self, o) o = o or {}; setmetatable(o, { __index = self }); o.extend = t.extend; o.new = t.new; return o end
    t.new = function(self, o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o._init then o:_init() end
        if o.init then o:init() end
        return o
    end
    return t
end
local function sized(h) return class({ getSize = function() return { w = 100, h = h } end, free = function() end }) end

stub("gettext", setmetatable({ current_lang = "C" }, { __call = function(_, s) return s end }))
stub("ffi/util", { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end })
stub("ffi/blitbuffer", setmetatable({}, { __index = function(_, k) return k end }))
stub("datastorage", { getSettingsDir = function() return root .. "/settings" end })
stub("logger", { warn = print, info = function() end, dbg = function() end })
local kindle = false
stub("device", {
    model = "Kindle Test",
    isKindle = function() return kindle end,
    hasKeys = function() return true end,
    input = { group = { Back = "Back" } },
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
})
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/gesturerange", class())
stub("ui/size", { padding = { large = 10, default = 5 }, line = { thin = 1 } })
stub("ui/widget/container/widgetcontainer", class())
stub("ui/widget/container/inputcontainer", class({
    _init = function(self) self.key_events = self.key_events or {}; self.ges_events = self.ges_events or {} end,
}))
stub("ui/widget/container/framecontainer", class())
stub("ui/widget/verticalgroup", class())
stub("ui/widget/horizontalgroup", class())
stub("ui/widget/verticalspan", class())
stub("ui/widget/horizontalspan", class())
stub("ui/widget/titlebar", sized(50))
stub("ui/widget/textboxwidget", sized(40))
stub("ui/widget/buttontable", sized(45))
local TextWidget = sized(20)
TextWidget.getFontSizeToFitHeight = function(_, _name, h) return h end
TextWidget.paintTo = function() end
stub("ui/widget/textwidget", TextWidget)
stub("ui/widget/infomessage", class({ init = function(self) table.insert(notes, self.text) end }))
stub("ui/widget/confirmbox", class())
local dialogs = {}
stub("ui/widget/inputdialog", class({
    init = function(self) table.insert(dialogs, self) end,
    onShowKeyboard = function() end,
    getInputText = function(self) return self.text_value or self.input end,
}))
local menus = {}
stub("ui/widget/menu", class({
    init = function(self) table.insert(menus, self) end,
    switchItemTable = function(self, _title, items) self.item_table = items end,
}))
stub("ui/widget/notification", { notify = function(_, text) table.insert(toasts, text) end })
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end })
local clock = 0
stub("ui/time", { now = function() return clock end, to_s = function(t) return t end })
local zmqs, standby, closed = {}, 0, {}
local last_close_refresh
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    close = function(_, w, refresh)
        last_close_refresh = refresh
        table.insert(closed, w)
        if w and w.onCloseWidget then w:onCloseWidget() end
    end,
    forceRePaint = function() end,
    setDirty = function() end,
    insertZMQ = function(_, z) table.insert(zmqs, z); return z end,
    removeZMQ = function(_, z) for i = #zmqs, 1, -1 do if zmqs[i] == z then table.remove(zmqs, i) end end end,
    preventStandby = function() standby = standby + 1 end,
    allowStandby = function() standby = standby - 1 end,
})
stub("luasettings", { open = function()
    local data = {}
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() end,
    }
end })

-- Fake LuaSocket ----------------------------------------------------------------
local function fake_tcp(incoming)
    local s = { sent = "", incoming = incoming or {}, closed = false }
    function s:settimeout() end
    function s:setoption() return true end
    function s:send(data) self.sent = self.sent .. data; return #data end
    function s:receive()
        local chunk = table.remove(self.incoming, 1)
        if chunk == "CLOSE" then return nil, "closed", "" end
        return nil, "timeout", chunk or ""
    end
    function s:close() self.closed = true end
    return s
end
local udps, pending_clients, bind_error = {}, {}, nil
-- the newest UDP socket bound to `port`
local function udp_on(port)
    for i = #udps, 1, -1 do if udps[i].port == port then return udps[i] end end
end
local connect_to
local function fake_udp()
    local u = { out = {}, inbox = {} }
    function u:setsockname(_h, port) self.port = port; return true end
    function u:setpeername() end
    function u:getsockname() return "192.168.1.20" end
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
local tcps = {}
stub("socket", {
    udp = function() local u = fake_udp(); table.insert(udps, u); return u end,
    tcp = function()
        local s = fake_tcp()
        function s:connect(host, port)
            connect_to = host .. ":" .. port
            if host == "10.0.0.66" then return nil, "connection refused" end
            return 1
        end
        table.insert(tcps, s)
        return s
    end,
    bind = function()
        if bind_error then return nil, bind_error end
        local s = fake_tcp()
        s.accept = function() return table.remove(pending_clients, 1) end
        return s
    end,
})

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n  expected: %q\n  actual:   %q"):format(name, tostring(expected), tostring(actual)))
    end
end

local function tick(n)
    for _i = 1, n or 1 do
        for _j, z in ipairs({ unpack(zmqs) }) do eq(z.waitEvent(z), nil, "waitEvent returns nil") end
    end
end

-- Finds widgets in the screen's tree.
local function find_all(w, pred, out)
    out = out or {}
    if type(w) ~= "table" then return out end
    if pred(w) then table.insert(out, w) end
    for _i, child in ipairs(w) do find_all(child, pred, out) end
    return out
end
local function boards(screen) return find_all(screen, function(w) return w.cell ~= nil end) end
local function buttons(screen)
    local tables = find_all(screen, function(w) return w.buttons ~= nil end)
    local out = {}
    for _i, b in ipairs(tables[1] and tables[1].buttons[1] or {}) do out[b.text] = b end
    return out
end
local function paint(board)
    local calls = 0
    local bb = setmetatable({}, { __index = function() return function() calls = calls + 1 end end })
    board:paintTo(bb, 5, 7)
    return calls
end

local Battleships = dofile("main.lua")
local plugin = Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } }
local menu_items = {}
plugin:addToMainMenu(menu_items)
eq(menu_items.battleships.text, "Battleships", "main menu entry")
local function item(id)
    for _i, it in ipairs(menu_items.battleships.sub_item_table_func()) do
        if it.battleships_item == id then return it end
    end
end
eq(item("name").text_func(), "Your name: Kindle Test", "default name is the device model")
item("name").callback({ updateItems = function() end })
dialogs[#dialogs].text_value = "  Martin\n "
dialogs[#dialogs].buttons[1][2].callback()
eq(item("name").text_func(), "Your name: Martin", "name saved, cleaned")
item("rules").callback()
eq(notes[#notes]:match("^Each player") ~= nil, true, "rules shown")

-- Hosting ------------------------------------------------------------------------
bind_error = "address already in use"
item("host").callback()
eq(notes[#notes], "Cannot host a game: address already in use", "port taken")
eq(#zmqs, 0, "nothing polled after a failed host")
bind_error = nil

kindle = true
local executed = {}
local real_execute = os.execute
os.execute = function(cmd) table.insert(executed, cmd) end
item("host").callback()
os.execute = real_execute
eq(#executed, 4, "Kindle firewall opened for TCP and discovery")
local screen = shown[#shown]
eq(screen.covers_fullscreen, true, "game screen shown")
eq(#zmqs, 1, "game polled")
eq(standby, 1, "standby prevented")
eq(screen.title_bar.subtitle, nil, "no opponent yet")
local status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("Your address: 192.168.1.20") ~= nil, true, "host address shown")
eq(#boards(screen), 1, "one board while placing")
eq(paint(boards(screen)[1]) > 30, true, "board painted")

-- discovery answered while waiting
local hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 1", "192.168.1.30", 7533 } }
tick()
eq(hudp.out[1] and hudp.out[1][1], "GAME 1 7531 Martin", "discovery answered")

-- placing: select, rotate, move
local game_board = boards(screen)[1].board
local s1 = game_board.ships[1]
local before = s1.dir
screen:onOwnTap(s1.x, s1.y)
eq(screen.selected, 1, "tap selects a ship")
screen:onOwnTap(s1.x, s1.y)
local after = game_board.ships[1].dir
eq(after ~= before or #toasts > 0, true, "second tap turns it (or explains why not)")
buttons(screen)["Random"].callback()
eq(screen.selected, nil, "Random clears the selection")

-- a guest joins
local client = fake_tcp({ "HELLO 1 Guest\n" })
table.insert(pending_clients, client)
tick(2)
eq(client.sent:match("^WELCOME 1 Martin\n") ~= nil, true, "host welcomes the guest")
eq(screen.title_bar.subtitle, "Opponent: Guest", "opponent shown")
-- a third device is turned away
local extra = fake_tcp()
table.insert(pending_clients, extra)
tick()
eq(extra.sent .. tostring(extra.closed), "ERROR busy\ntrue", "second guest refused")

buttons(screen)["Ready"].callback()
eq(client.sent:match("READY\n$") ~= nil, true, "READY sent")
eq(buttons(screen)["Ready"].enabled, false, "Ready only once")
client.incoming = { "READY\n" }
tick()
eq(client.sent:match("START %a+\n$") ~= nil, true, "START sent when both are ready")
eq(#boards(screen), 2, "two boards in the battle")
for _i, bw in ipairs(boards(screen)) do paint(bw) end

-- make it our turn: if the guest starts, it misses
eq(boards(screen)[1].mode, "target", "the opponent's board comes first")
if client.sent:match("START guest\n$") then
    local own = boards(screen)[2].board
    local free
    for y = 0, 9 do for x = 0, 9 do if not free and not own:ship_at(x, y) then free = { x, y } end end end
    client.incoming = { ("SHOT %d %d\n"):format(free[1], free[2]) }
    tick()
    eq(client.sent:match("RESULT %d+ %d+ miss\n$") ~= nil, true, "opponent's miss answered")
end
boards(screen)[1].on_tap(3, 4)
eq(client.sent:match("SHOT 3 4\n$") ~= nil, true, "tap fires")
client.incoming = { "RESULT 3 4 hit\n" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^D5: hit! Fire again.") ~= nil, true, "result shown")
eq(boards(screen)[1].last[1] .. boards(screen)[1].last[2], "34", "last shot outlined")

-- the opponent leaves
client.incoming = { "BYE\n" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Guest left the game.", "opponent left")
eq(buttons(screen)["Close"] ~= nil, true, "only Close left")
eq(boards(screen)[1].on_tap, nil, "no more shots")
executed = {}
os.execute = function(cmd) table.insert(executed, cmd) end
buttons(screen)["Close"].callback()
os.execute = real_execute
kindle = false
eq(#executed == 4 and executed[1]:match("^iptables %-D") ~= nil, true, "firewall closed")
eq(#zmqs .. " " .. standby, "0 0", "polling and standby released")
eq(closed[#closed], screen, "screen closed")
eq(last_close_refresh, "full", "screen below refreshed")

-- Host: a guest leaving before the battle frees the seat ------------------------
item("host").callback()
screen = shown[#shown]
client = fake_tcp({ "HELLO 1 Guest\n" })
table.insert(pending_clients, client)
tick(2)
client.incoming = { "CLOSE" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^Guest left.") ~= nil, true, "guest left before the battle")
eq(screen.title_bar.subtitle, nil, "waiting for another opponent")
hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 1", "192.168.1.31", 7533 } }
tick()
eq(#hudp.out, 1, "discovery answered again")
client = fake_tcp({ "HELLO 1 Second\n" })
table.insert(pending_clients, client)
tick(2)
eq(screen.title_bar.subtitle, "Opponent: Second", "another guest joins")
-- silence → timeout
clock = clock + 31
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Second left.\nPlace your ships: tap a ship to select it, tap it again to turn it, tap the water to move it there.\nWaiting for an opponent. Your address: 192.168.1.20",
    "timeout before the battle: wait again")
-- protocol error
client = fake_tcp({ "HELLO 99 Old\n" })
table.insert(pending_clients, client)
tick(2)
eq(client.sent, "ERROR version\n", "old version refused")
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^The other device has a different version") ~= nil, true, "version error shown")
screen:onClose()
eq(#zmqs, 0, "game ended")

-- Joining by address -----------------------------------------------------------
item("join").callback()
local dialog = dialogs[#dialogs]
dialog.text_value = "not an address!"
dialog.buttons[1][2].callback()
eq(toasts[#toasts], "Invalid address", "invalid address")
dialog.text_value = "10.0.0.66"
dialog.buttons[1][2].callback()
eq(notes[#notes], "Cannot connect to 10.0.0.66: connection refused", "connection refused")
eq(#zmqs, 0, "no game")
item("join").callback()
dialog = dialogs[#dialogs]
eq(dialog.input, "10.0.0.66", "last address remembered")
dialog.text_value = "10.0.0.9:7000"
dialog.buttons[1][2].callback()
eq(connect_to, "10.0.0.9:7000", "connects to the address")
local sock = tcps[#tcps]
eq(sock.sent, "HELLO 1 Martin\n", "guest says hello")
screen = shown[#shown]
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("Connecting…$") ~= nil, true, "guest waits for WELCOME")
sock.incoming = { "WELCOME 1 Host\nREADY\n" }
tick()
eq(screen.title_bar.subtitle, "Opponent: Host", "guest joined")
clock = clock + 6
tick()
eq(sock.sent:match("PING\n$") ~= nil, true, "keepalive")
sock.incoming = { "CLOSE" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Connection to Host lost.", "guest: connection lost ends the game")
plugin:onSuspend()
eq(#zmqs .. " " .. standby, "0 0", "suspend ends the game")

-- Finding games ------------------------------------------------------------------
item("find").callback()
local menu = menus[#menus]
eq(menu.item_table[1].text, "Searching for games…", "searching")
eq(#zmqs, 1, "search polled")
local sudp = udp_on(7533)
tick()
eq(#sudp.out, 2, "DISCOVER broadcast")
sudp.inbox = { { "GAME 1 7531 Host", "192.168.1.40", 7532 } }
tick()
eq(menu.item_table[1].text .. " " .. menu.item_table[1].mandatory, "Host 192.168.1.40", "game listed")
eq(menu.item_table[2].text, "Join by address…", "join by address below")
clock = clock + 10
tick()
eq(menu.item_table[1].text, "Searching for games…", "silent game dropped")
sudp.inbox = { { "GAME 1 7531 Host", "192.168.1.40", 7532 } }
tick()
menu.item_table[1].callback()
eq(sudp.closed, true, "search stopped when the list closes")
eq(connect_to, "192.168.1.40:7531", "joins the game found")
eq(#zmqs, 1, "only the game polled")
plugin:onExit()
eq(#zmqs .. " " .. standby, "0 0", "exit ends the game")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
