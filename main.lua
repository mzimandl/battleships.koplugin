--[[--
Battleships plugin: the classic game for two players, each on their own
e-reader, over Wi-Fi. One device hosts the game, the other joins it, either by
address or by finding it on the local network (UDP broadcast).

@module koplugin.Battleships
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local Board = require("battleships/board")
local L10n = require("battleships/l10n")
local Match = require("battleships/match")
local Net = require("battleships/net")
local Protocol = require("battleships/protocol")

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local gettext = require("gettext")
-- The plugin's strings are not in KOReader's catalog: its own catalog for
-- KOReader's language first (battleships/l10n/<lang>.lua, required now, see above).
local _ = L10n.wrap(gettext, L10n.catalog(gettext.current_lang, function(name)
    local ok, catalog = pcall(require, "battleships/l10n/" .. name)
    return ok and catalog or nil
end))
local T = require("ffi/util").template

local Battleships = WidgetContainer:extend{
    name = "battleships",
    is_doc_only = false,
}

local PING_INTERVAL = 5    -- seconds
local PEER_TIMEOUT = 30    -- seconds without any message → connection lost
local CONNECT_TIMEOUT = 5  -- seconds, blocks the UI
local SEARCH_INTERVAL = 1  -- seconds between DISCOVER broadcasts
local SEARCH_EXPIRE = 5    -- seconds: games not heard of are dropped from the list

local function now()
    return time.to_s(time.now())
end

local function notify(text)
    Notification:notify(text)
end

-- The running game and the game search. Module-level, not on the plugin
-- instance: KOReader makes a new instance for every reader/file manager.
-- game: { role, match, conn, host, ip, screen, zmq, message, lost, last_ping, rules }
local game = {}
-- finder: { search, menu, zmq, last_sent, rules }
local finder = {}

-- Kindle firewall --------------------------------------------------------------

local function host_rules(port)
    return {
        string.format("INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", port),
        string.format("OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
        string.format("INPUT -p udp --dport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
        string.format("OUTPUT -p udp --sport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
    }
end

local function guest_rules(port)
    return {
        string.format("OUTPUT -p tcp --dport %d -j ACCEPT", port),
        string.format("INPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
    }
end

local function search_rules()
    return {
        string.format("INPUT -p udp --dport %d -j ACCEPT", Protocol.SEARCH_PORT),
        string.format("OUTPUT -p udp --sport %d -j ACCEPT", Protocol.SEARCH_PORT),
        string.format("OUTPUT -p udp --dport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
    }
end

-- Opens (op "-A") or closes ("-D") ports in the Kindle firewall (as httpinspector does).
local function kindle_firewall(op, rules)
    if not rules or not Device:isKindle() then return end
    for _i, rule in ipairs(rules) do os.execute("iptables " .. op .. " " .. rule) end
end

-- Polling: UIManager calls a ZMQ's waitEvent() about every 50 ms; it must
-- return nil (anything else is treated as an input event).
local function poller(fn, name)
    return UIManager:insertZMQ({ waitEvent = function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("Battleships:", name, err) end
        return nil
    end })
end

-- Board widget -----------------------------------------------------------------

local font_sizes = {} -- cell size → label font size

--- A 10 × 10 board with column letters and row numbers.
-- mode "own": board = Board (our ships and the opponent's shots), selected = ship index;
-- mode "target": target = Board.target(). last = { x, y } is outlined.
-- on_tap(x, y) makes it tappable.
local BoardWidget = InputContainer:extend{
    size = nil,
    mode = "own",
    board = nil,
    target = nil,
    selected = nil,
    last = nil,
    on_tap = nil,
}

function BoardWidget:init()
    local n = Board.SIZE + 1
    self.cell = math.floor(self.size / n)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.cell * n, h = self.cell * n }
    self.line = math.max(1, math.floor(self.cell / 25))
    local fs = font_sizes[self.cell]
    if not fs then
        fs = TextWidget:getFontSizeToFitHeight("cfont", math.floor(self.cell * 0.75), 0)
        font_sizes[self.cell] = fs
    end
    local face = Font:getFace("cfont", fs)
    self.cols, self.rows = {}, {}
    for i = 0, Board.SIZE - 1 do
        self.cols[i] = TextWidget:new{ text = string.char(65 + i), face = face, padding = 0 }
        self.rows[i] = TextWidget:new{ text = tostring(i + 1), face = face, padding = 0 }
    end
    if self.on_tap then
        self.ges_events = {
            TapBoard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function BoardWidget:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function BoardWidget:onTapBoard(_args, ges)
    local x = math.floor((ges.pos.x - self.dimen.x) / self.cell) - 1
    local y = math.floor((ges.pos.y - self.dimen.y) / self.cell) - 1
    if Board.inside(x, y) then self.on_tap(x, y) end
    return true
end

local function paint_centered(bb, widget, x, y, w, h)
    local size = widget:getSize()
    widget:paintTo(bb, x + math.floor((w - size.w) / 2), y + math.floor((h - size.h) / 2))
end

function BoardWidget:paintCell(bb, px, py, x, y)
    local c = self.cell
    local function fill(color) bb:paintRect(px, py, c, c, color) end
    local function square(color)
        local s = math.floor(c * 0.5)
        bb:paintRect(px + math.floor((c - s) / 2), py + math.floor((c - s) / 2), s, s, color)
    end
    local function dot(r, color)
        bb:paintCircle(px + math.floor(c / 2), py + math.floor(c / 2), math.max(1, math.floor(r)), color)
    end
    if self.mode == "own" then
        local i = self.board:ship_at(x, y)
        local shot = self.board.shots[y][x]
        if i then
            local ship = self.board.ships[i]
            if ship.hits >= ship.len then fill(Blitbuffer.COLOR_BLACK)
            else
                fill(i == self.selected and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_GRAY)
                if shot == "hit" then square(Blitbuffer.COLOR_BLACK) end
            end
        elseif shot == "miss" then
            dot(c / 8, Blitbuffer.COLOR_BLACK)
        end
        return
    end
    local mark = self.target.marks[y][x]
    if mark == "sunk" then
        fill(Blitbuffer.COLOR_BLACK)
        return
    end
    if self.target:ship_at(x, y) then fill(Blitbuffer.COLOR_GRAY) end -- revealed after the game
    if mark == "hit" then square(Blitbuffer.COLOR_BLACK)
    elseif mark == "miss" then dot(c / 8, Blitbuffer.COLOR_BLACK)
    elseif mark == "near" then dot(c / 14, Blitbuffer.COLOR_GRAY_9) end
end

function BoardWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local c, n = self.cell, Board.SIZE
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    for i = 0, n - 1 do
        paint_centered(bb, self.cols[i], x + c * (i + 1), y, c, c)
        paint_centered(bb, self.rows[i], x, y + c * (i + 1), c, c)
    end
    local ox, oy = x + c, y + c
    for cy = 0, n - 1 do
        for cx = 0, n - 1 do self:paintCell(bb, ox + cx * c, oy + cy * c, cx, cy) end
    end
    for i = 0, n do
        local w = (i == 0 or i == n) and self.line * 2 or self.line
        bb:paintRect(ox + i * c, oy, w, n * c + w, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy + i * c, n * c + w, w, Blitbuffer.COLOR_BLACK)
    end
    if self.last then
        bb:paintBorder(ox + self.last[1] * c, oy + self.last[2] * c, c + self.line, c + self.line,
            math.max(2, math.floor(c / 8)), Blitbuffer.COLOR_BLACK)
    end
end

function BoardWidget:onCloseWidget()
    for i = 0, Board.SIZE - 1 do
        self.cols[i]:free()
        self.rows[i]:free()
    end
end

-- Game screen ------------------------------------------------------------------

local GameScreen = InputContainer:extend{
    covers_fullscreen = true,
    selected = nil, -- ship being moved while placing
}

function GameScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
end

function GameScreen:statusText()
    local m = game.match
    local lines = {}
    if game.message then lines[#lines + 1] = game.message end
    if game.lost then
        -- message says why
    elseif m.phase == "placing" then
        if not m.ready then
            lines[#lines + 1] = _("Place your ships: tap a ship to select it, tap it again to turn it, tap the water to move it there.")
        elseif m.peer then
            lines[#lines + 1] = T(_("Waiting for %1 to place their ships…"), m.peer)
        end
        if not m.peer then
            if game.role == "host" then
                lines[#lines + 1] = game.ip and T(_("Waiting for an opponent. Your address: %1"), game.ip)
                    or _("Waiting for an opponent.")
            else
                lines[#lines + 1] = _("Connecting…")
            end
        end
    elseif m.phase == "battle" then
        if m.pending then lines[#lines + 1] = _("Firing…")
        elseif m.turn == "me" then lines[#lines + 1] = _("Your turn: tap a square on the opponent's board.")
        else lines[#lines + 1] = T(_("%1 is aiming…"), m.peer) end
    else
        lines[#lines + 1] = m.winner == "me" and _("You won!") or T(_("%1 won."), m.peer)
        if m.rematch and not m.peer_rematch then
            lines[#lines + 1] = T(_("Waiting for %1…"), m.peer)
        elseif m.peer_rematch and not m.rematch then
            lines[#lines + 1] = T(_("%1 wants to play again."), m.peer)
        end
    end
    return table.concat(lines, "\n")
end

function GameScreen:buttonRow()
    local m = game.match
    local close = { text = _("Close"), callback = function() self:onClose() end }
    if game.lost then return { close } end
    if m.phase == "placing" then
        return {
            { text = _("Random"), enabled = not m.ready, callback = function()
                m.board:randomize()
                self.selected = nil
                self:update()
            end },
            { text = _("Ready"), enabled = not m.ready, callback = function()
                self.selected = nil
                local ev = m:set_ready()
                if ev then Battleships.onGameEvent(ev) else self:update() end
            end },
        }
    elseif m.phase == "over" then
        return {
            { text = _("Play again"), enabled = not m.rematch, callback = function()
                local ev = m:request_rematch()
                if ev then Battleships.onGameEvent(ev) else self:update() end
            end },
            close,
        }
    end
end

function GameScreen:onOwnTap(x, y)
    local m = game.match
    if m.phase ~= "placing" or m.ready then return end
    local i = m.board:ship_at(x, y)
    if self.selected and i == self.selected then
        if not m.board:rotate(i) then notify(_("The ship cannot turn here.")) end
    elseif i then
        self.selected = i
    elseif self.selected then
        if m.board:move(self.selected, x, y) then self.selected = nil
        else notify(_("The ship does not fit there. Ships may not touch.")) end
    end
    self:update()
end

function GameScreen:onTargetTap(x, y)
    local m = game.match
    if m:fire(x, y) then self:update() end
end

function GameScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local m = game.match
    local pad = Size.padding.large
    local inner_w = w - 2 * pad
    self.title_bar = TitleBar:new{
        width = w,
        fullscreen = true,
        title = _("Battleships"),
        subtitle = m.peer and T(_("Opponent: %1"), m.peer) or nil,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local status = TextBoxWidget:new{
        text = self:statusText(),
        face = Font:getFace("cfont", 18),
        width = inner_w,
        alignment = "center",
    }
    local row = self:buttonRow()
    local buttons = row and ButtonTable:new{ width = inner_w, buttons = { row }, show_parent = self }
    local used = self.title_bar:getSize().h + status:getSize().h + 3 * pad
        + (buttons and buttons:getSize().h + pad or 0)
    local avail_h = h - used

    local boards
    if m.phase == "placing" then
        boards = BoardWidget:new{
            size = math.min(inner_w, avail_h),
            mode = "own", board = m.board, selected = self.selected,
            on_tap = not m.ready and function(x, y) self:onOwnTap(x, y) end or nil,
        }
    else
        local face = Font:getFace("cfont", 16)
        local label_target = TextWidget:new{ text = _("Opponent's board"), face = face }
        local label_own = TextWidget:new{ text = _("Your board"), face = face }
        local label_h = label_target:getSize().h
        local target_size, own_size
        local landscape = w > h
        if landscape then
            target_size = math.min(math.floor((inner_w - pad) * 0.58), avail_h - label_h)
            own_size = math.min(inner_w - pad - target_size, avail_h - label_h)
        else
            local h2 = avail_h - 2 * label_h - pad
            target_size = math.min(inner_w, math.floor(h2 * 0.6))
            own_size = math.min(inner_w, h2 - target_size)
        end
        local target = BoardWidget:new{
            size = target_size, mode = "target", target = m.target, last = m.last_fired,
            on_tap = m.phase == "battle" and not game.lost and function(x, y) self:onTargetTap(x, y) end or nil,
        }
        local own = BoardWidget:new{ size = own_size, mode = "own", board = m.board, last = m.last_incoming }
        local group = landscape and HorizontalGroup or VerticalGroup
        boards = group:new{
            align = landscape and "top" or "center",
            VerticalGroup:new{ align = "center", label_target, target },
            landscape and HorizontalSpan:new{ width = pad } or VerticalSpan:new{ width = pad },
            VerticalGroup:new{ align = "center", label_own, own },
        }
    end

    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        VerticalSpan:new{ width = pad },
        status,
        VerticalSpan:new{ width = pad },
        boards,
        VerticalSpan:new{ width = pad },
    }
    if buttons then table.insert(content, buttons) end
    self[1] = FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

function GameScreen:update()
    self:build()
    UIManager:setDirty(self, "ui")
end

function GameScreen:onClose()
    local m = game.match
    local idle = game.lost or m.phase == "over" or not m.peer
    if idle then
        Battleships.endGame()
    else
        UIManager:show(ConfirmBox:new{
            text = _("Leave the game?"),
            ok_text = _("Leave"),
            ok_callback = function() Battleships.endGame() end,
        })
    end
    return true
end

-- Running a game ---------------------------------------------------------------

local ERRORS = {
    version = _("The other device has a different version of Battleships."),
    busy = _("This game already has two players."),
}

function Battleships.endGame()
    if game.conn then
        if game.match and game.match.peer then game.match:bye() end
        game.conn:close()
    end
    if game.host then game.host:close() end
    if game.zmq then
        UIManager:removeZMQ(game.zmq)
        UIManager:allowStandby()
    end
    kindle_firewall("-D", game.rules)
    local screen = game.screen
    game = {}
    if screen then UIManager:close(screen) end
end

--- The connection ended: `reason` = "left" (BYE), an ERRORS key, or a socket error.
local function connection_lost(reason)
    if game.conn then game.conn:close() end
    game.conn = nil
    local m = game.match
    local who = m.peer or _("The opponent")
    if game.role == "host" and m.phase == "placing" and not ERRORS[reason] then
        -- the battle hasn't started: wait for someone else
        if m.peer then game.message = T(_("%1 left."), who) end
        m:drop_peer()
    else
        game.lost = true
        if ERRORS[reason] then game.message = ERRORS[reason]
        elseif reason == "left" then game.message = T(_("%1 left the game."), who)
        else game.message = m.peer and T(_("Connection to %1 lost."), who) or _("Connection lost.") end
        if game.host then game.host:close(); game.host = nil end
    end
    if game.screen then game.screen:update() end
end

local RESULT_TEXT = {
    miss = _("%1: miss."),
    hit = _("%1: hit! Fire again."),
    sunk = _("%1: hit and sunk! Fire again."),
    won = _("%1: hit and sunk!"),
}

local INCOMING_TEXT = {
    miss = _("%1 fired at %2: miss."),
    hit = _("%1 fired at %2: hit."),
    sunk = _("%1 fired at %2: your ship is sunk."),
    won = _("%1 fired at %2: your last ship is sunk."),
}

--- Updates the screen after a match event (see battleships/match.lua).
function Battleships.onGameEvent(ev)
    local m = game.match
    local t = ev.type
    if t == "joined" then
        game.message = game.role == "host" and T(_("%1 joined the game."), ev.name)
            or T(_("You joined %1's game."), ev.name)
    elseif t == "peer_ready" then
        game.message = T(_("%1 is ready."), m.peer)
    elseif t == "start" then
        game.message = ev.turn == "me" and _("The battle begins. You fire first.")
            or T(_("The battle begins. %1 fires first."), m.peer)
    elseif t == "result" then
        game.message = T(RESULT_TEXT[ev.result], Board.label(ev.x, ev.y))
    elseif t == "incoming" then
        game.message = T(INCOMING_TEXT[ev.result], m.peer, Board.label(ev.x, ev.y))
    elseif t == "rematch" then
        game.message = _("New game: place your ships.")
        if game.screen then game.screen.selected = nil end
    elseif t == "left" then
        connection_lost("left")
        return
    end
    if game.screen then game.screen:update() end
end

local function poll_game()
    local t = now()
    if game.host then
        local client = game.host:accept()
        if client then
            if game.conn then
                client:settimeout(1)
                client:send(Protocol.line("ERROR", "busy"))
                client:close()
            else
                game.conn = Net.connection(client, t)
                game.last_ping = t
            end
        end
        game.host:answer(not game.conn and game.match.name or nil)
    end
    local conn = game.conn
    if not conn then return end
    local lines, err = conn:poll(t)
    for _i, line in ipairs(lines or {}) do
        local ev, perr = game.match:receive(line)
        if perr then
            logger.warn("Battleships: protocol error", perr, line)
            if not ERRORS[perr] then conn:send(Protocol.line("ERROR", "protocol")) end
            connection_lost(perr)
            return
        end
        if ev then Battleships.onGameEvent(ev) end
        if game.conn ~= conn then return end -- the event ended the connection
    end
    if not lines then
        connection_lost(err)
    elseif t - conn.last_seen > PEER_TIMEOUT then
        connection_lost("timeout")
    elseif t - (game.last_ping or 0) >= PING_INTERVAL then
        game.last_ping = t
        game.match:ping()
    end
end

function Battleships:startGame(role, fields)
    game = fields
    game.role = role
    game.match = Match.new{
        role = role,
        name = self:playerName(),
        send = function(line) if game.conn then game.conn:send(line) end end,
    }
    game.last_ping = now()
    game.zmq = poller(poll_game, "game")
    UIManager:preventStandby()
    game.screen = GameScreen:new{}
    UIManager:show(game.screen)
end

function Battleships:hostGame()
    NetworkMgr:runWhenOnline(function()
        Battleships.endGame()
        local socket = require("socket")
        local host, err = Net.host(socket, Protocol.PORT)
        if not host then
            UIManager:show(InfoMessage:new{ text = T(_("Cannot host a game: %1"), tostring(err)) })
            return
        end
        local rules = host_rules(Protocol.PORT)
        kindle_firewall("-A", rules)
        self:startGame("host", { host = host, ip = Net.local_ip(socket), rules = rules })
    end)
end

function Battleships:joinGame(ip, port)
    NetworkMgr:runWhenOnline(function()
        Battleships.endGame()
        local socket = require("socket")
        local rules = guest_rules(port)
        kindle_firewall("-A", rules)
        local msg = InfoMessage:new{ text = T(_("Connecting to %1…"), ip) }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local conn, err = Net.connect(socket, ip, port, CONNECT_TIMEOUT, now())
        UIManager:close(msg)
        if not conn then
            kindle_firewall("-D", rules)
            UIManager:show(InfoMessage:new{ text = T(_("Cannot connect to %1: %2"), ip, tostring(err)) })
            return
        end
        self:startGame("guest", { conn = conn, rules = rules })
        game.match:hello()
    end)
end

function Battleships:joinByAddress()
    local dialog
    dialog = InputDialog:new{
        title = _("Join by address"),
        input = self.settings:readSetting("last_address") or "",
        input_hint = "192.168.1.10",
        description = _("The address is shown on the host's screen."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Join"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                local ip, port = Protocol.parse_address(text)
                if not ip then
                    notify(_("Invalid address"))
                    return
                end
                UIManager:close(dialog)
                self.settings:saveSetting("last_address", text)
                self.settings:flush()
                self:joinGame(ip, port)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Finding games ----------------------------------------------------------------

local function stop_finder()
    if finder.zmq then UIManager:removeZMQ(finder.zmq) end
    if finder.search then finder.search:close() end
    kindle_firewall("-D", finder.rules)
    finder = {}
end

function Battleships:finderItems()
    local items = {}
    for _i, g in ipairs(finder.search and finder.search.games or {}) do
        table.insert(items, {
            text = g.name ~= "" and g.name or g.ip,
            mandatory = g.ip,
            callback = function()
                local ip, port = g.ip, g.port
                UIManager:close(finder.menu)
                self:joinGame(ip, port)
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("Searching for games…"), dim = true, callback = function() end })
    end
    items[#items].separator = true
    table.insert(items, { text = _("Join by address…"), callback = function()
        UIManager:close(finder.menu)
        self:joinByAddress()
    end })
    return items
end

local function poll_finder(plugin)
    local t = now()
    if t - finder.last_sent >= SEARCH_INTERVAL then
        finder.last_sent = t
        finder.search:send()
    end
    local changed = finder.search:poll(t)
    changed = finder.search:expire(t, SEARCH_EXPIRE) or changed
    if changed and finder.menu then
        finder.menu:switchItemTable(nil, plugin:finderItems())
    end
end

function Battleships:findGames()
    NetworkMgr:runWhenOnline(function()
        stop_finder()
        local socket = require("socket")
        local search, err = Net.search(socket, Net.local_ip(socket))
        if not search then
            UIManager:show(InfoMessage:new{ text = T(_("Cannot search for games: %1"), tostring(err)) })
            return
        end
        finder = { search = search, last_sent = 0, rules = search_rules() }
        kindle_firewall("-A", finder.rules)
        local menu = Menu:new{
            title = _("Find a game"),
            item_table = self:finderItems(),
            covers_fullscreen = true,
            is_borderless = true,
            is_popout = false,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        }
        local on_close = menu.onCloseWidget
        menu.onCloseWidget = function(m)
            stop_finder()
            if on_close then return on_close(m) end
        end
        finder.menu = menu
        finder.zmq = poller(function() poll_finder(self) end, "search")
        UIManager:show(menu)
    end)
end

-- Plugin -----------------------------------------------------------------------

function Battleships:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/battleships.lua")
    self.ui.menu:registerToMainMenu(self)
end

function Battleships:playerName()
    local name = Protocol.clean_name(self.settings:readSetting("name"))
    if name == "" then name = Protocol.clean_name(Device.model or "") end
    if name == "" then name = _("Player") end
    return name
end

function Battleships:editName(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Your name"),
        input = self:playerName(),
        description = _("Shown to the other player and in the list of games."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.settings:saveSetting("name", Protocol.clean_name(dialog:getInputText()))
                self.settings:flush()
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Battleships:showRules()
    UIManager:show(InfoMessage:new{
        text = _([[Each player has a fleet of five ships (5, 4, 3, 3 and 2 squares) on a 10 × 10 board. Ships may not touch, not even at the corners.

Players take turns firing at a square of the opponent's board. After a hit you fire again, after a miss it's the opponent's turn. Whoever sinks the whole enemy fleet first wins.

Both devices must be on the same Wi-Fi network. One player hosts the game, the other finds it in Find a game or joins by the address shown on the host's screen.]]),
    })
end

function Battleships:mainMenu()
    return {
        { text = _("Host a game"), battleships_item = "host", callback = function() self:hostGame() end },
        { text = _("Find a game"), battleships_item = "find", callback = function() self:findGames() end },
        { text = _("Join by address…"), battleships_item = "join", callback = function() self:joinByAddress() end,
            separator = true },
        { text_func = function() return T(_("Your name: %1"), self:playerName()) end, battleships_item = "name",
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editName(touchmenu_instance) end },
        { text = _("Rules"), battleships_item = "rules", keep_menu_open = true,
            callback = function() self:showRules() end },
    }
end

function Battleships:addToMainMenu(menu_items)
    menu_items.battleships = {
        text = _("Battleships"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:mainMenu() end,
    }
end

function Battleships:onSuspend()
    -- Wi-Fi goes off while the device sleeps: leave instead of timing out.
    stop_finder()
    Battleships.endGame()
end

function Battleships:onExit()
    stop_finder()
    Battleships.endGame()
end

return Battleships
