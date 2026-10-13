if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/FarmHUD.lua
-- Full-screen farm HUD for a session of a farm with a route. A see-through overlay
-- (clicks pass through): in the middle a radar of RADAR_YARDS around the player,
-- turned with the facing - the farm's known nodes as dots, the stops (clusters
-- larger), a line to the next stop and a thin one on to the stop after it. A side
-- panel (left or right, setting) shows farm, time, gold, GPH, nodes, the three most
-- valuable items and the next two stops with distance and time to reach them.
-- Shown by the hotkey, /gob farm hud or automatically (setting, off by default);
-- hidden in combat, in instances and outside the farm's zone. While it is shown
-- the small session HUD hides. The radar updates TICK times a second only while
-- shown; the side panel's values follow the session events and a 1 s clock.
local _, ns = ...

local FarmHUD = {}
ns.FarmHUD = FarmHUD

local TICK = 1 / 15
local RADAR_YARDS = 300
local RING_SEGMENTS = 48
local PANEL_W = 240
local TOP_ITEMS = 3

local module, frame
local points               -- the farm's nodes (zone coordinates), cached while shown
local elapsed, clock = 0, 0
local checkToken = 0

local function Settings() return module.db.settings end
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
local function Money(copper) return ns.API.Money.Format(copper, { abbreviate = true }) end

--- Farm and route of the running session, or nil.
function FarmHUD.Route()
    local s = ns.Session.Active()
    local farm = s and s.farmId and ns.Farms.Get(s.farmId)
    if farm and farm.route and #farm.route.stops > 0 then return farm.route, farm, s end
    return nil
end

--- Follow state of the session's farm (per character, survives /reload).
function FarmHUD.State()
    local _, farm = FarmHUD.Route()
    local c = module.db.char
    if not farm then return nil end
    if not c.routeFollow or c.routeFollow.farmId ~= farm.id then c.routeFollow = { farmId = farm.id } end
    return c.routeFollow
end

--- Player position on the route's zone (x, y) and facing, or nil (other zone, instance).
function FarmHUD.Position(route)
    if IsInInstance and IsInInstance() then return nil end
    local pos = C_Map.GetPlayerMapPosition(route.zone, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if IsSecret(x) or IsSecret(y) or (x == 0 and y == 0) then return nil end
    local facing = GetPlayerFacing and GetPlayerFacing()
    if IsSecret(facing) then facing = nil end
    return x, y, facing or 0
end

--- Wanted by the player: the session's choice (hotkey, command), else the setting.
function FarmHUD.Wanted()
    local route, _, s = FarmHUD.Route()
    if not route then return false end
    if s.farmHud ~= nil then return s.farmHud end
    return Settings().farmHudAuto == true
end

function FarmHUD.Allowed()
    local route = FarmHUD.Route()
    return route ~= nil and not InCombatLockdown() and FarmHUD.Position(route) ~= nil
end

-- Pools -------------------------------------------------------------------------------------------
local function Pool(create)
    local pool = { items = {}, used = 0 }
    function pool:Next()
        self.used = self.used + 1
        local item = self.items[self.used]
        if not item then
            item = create()
            self.items[self.used] = item
        end
        item:Show()
        return item
    end
    function pool:Finish()
        for i = self.used + 1, #self.items do self.items[i]:Hide() end
        self.used = 0
    end
    return pool
end

-- Frame -------------------------------------------------------------------------------------------
local function BuildPanel(f)
    local API, L = ns.API, ns.L
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local p = CreateFrame("Frame", nil, f)
    p:SetWidth(PANEL_W)
    p:EnableMouse(true)
    Theme.Backdrop(p, C.overlay, C.border)
    local y = -S.SM
    local function Line(size, color, right)
        local fs = Theme.Text(p, size, color)
        fs:SetPoint(right and "TOPRIGHT" or "TOPLEFT", right and -S.SM or S.SM, y)
        fs:SetJustifyH(right and "RIGHT" or "LEFT")
        fs:SetWordWrap(false)
        return fs
    end
    p.title = Line(12, C.gold)
    p.title:SetPoint("RIGHT", -S.SM, 0)
    y = y - 18
    p.time = Line(16, C.text)
    p.pause = W.Button(p, L["Pause"], { width = 70, height = 20, onClick = function()
        if ns.Session.IsRunning() then ns.Session.Pause() else ns.Session.Resume() end
    end })
    p.pause:SetPoint("TOPRIGHT", -(S.SM + 70 + S.XS), y)
    p.stop = W.Button(p, L["Stop"], { width = 70, height = 20, onClick = function() ns.HUD.StopAndSummarize() end })
    p.stop:SetPoint("TOPRIGHT", -S.SM, y)
    y = y - 24
    p.total = Line(14, C.gold)
    p.gph = Line(11, C.textDim, true)
    y = y - 18
    p.nodes = Line(11, C.textDim)
    p.nodes:SetPoint("RIGHT", -S.SM, 0)
    y = y - 18
    p.items = {}
    for i = 1, TOP_ITEMS do
        local name = Line(11, C.text)
        name:SetPoint("RIGHT", -70, 0)
        local value = Line(11, C.text, true)
        p.items[i] = { name = name, value = value }
        y = y - 15
    end
    y = y - S.XS
    p.next = {}
    for i = 1, 2 do
        local fs = Line(i == 1 and 12 or 11, i == 1 and C.text or C.textDim)
        fs:SetPoint("RIGHT", -S.SM, 0)
        p.next[i] = fs
        y = y - 16
    end
    p.round = Line(11, C.textDim)
    y = y - 16
    p:SetHeight(-y + S.SM)
    return p
end

local function Build()
    local API = ns.API
    local W, Theme = API.Widgets, API.Theme
    local C = Theme.colors
    local f = CreateFrame("Frame", "GoblinomicsGathererFarmHUD", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("BACKGROUND")
    f:EnableMouse(false)
    f.radar = CreateFrame("Frame", nil, f)
    f.radar:SetPoint("CENTER")
    f.radar:EnableMouse(false)
    local screenH = UIParent.GetHeight and UIParent:GetHeight() or 768
    local size = math.floor(screenH * 0.6)
    f.radar:SetSize(size, size)
    f.radius = size / 2
    -- ring
    for i = 1, RING_SEGMENTS do
        local a1, a2 = (i - 1) / RING_SEGMENTS * 2 * math.pi, i / RING_SEGMENTS * 2 * math.pi
        local line = f.radar:CreateLine(nil, "BACKGROUND")
        line:SetThickness(1.5)
        line:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.8)
        line:SetStartPoint("CENTER", f.radar, math.cos(a1) * f.radius, math.sin(a1) * f.radius)
        line:SetEndPoint("CENTER", f.radar, math.cos(a2) * f.radius, math.sin(a2) * f.radius)
    end
    f.player = W.Chevron(f.radar, "up", 14)
    f.player:SetPoint("CENTER")
    f.player:SetColor(C.text)
    f.scaleLabel = Theme.Text(f.radar, 10, C.textDim)
    f.scaleLabel:SetPoint("TOP", f.radar, "BOTTOM", 0, -4)
    f.scaleLabel:SetText(RADAR_YARDS .. " yd")
    f.dots = Pool(function() return f.radar:CreateTexture(nil, "ARTWORK") end)
    f.stops = Pool(function() return f.radar:CreateTexture(nil, "OVERLAY") end)
    f.labels = Pool(function() return Theme.Text(f.radar, 10, C.text) end)
    f.lines = Pool(function() return f.radar:CreateLine(nil, "ARTWORK") end)
    f.panel = BuildPanel(f)
    return f
end

local function PlacePanel()
    local side = Settings().farmHudSide == "right" and "RIGHT" or "LEFT"
    frame.panel:ClearAllPoints()
    frame.panel:SetPoint(side, UIParent, side, side == "LEFT" and 24 or -24, 0)
end

-- Drawing -----------------------------------------------------------------------------------------
--- Radar point of zone position (x, y) seen from (px, py): pixels right, up and
-- whether it lies inside the radar (outside: clamped to the edge).
local function RadarPoint(x, y, px, py, facing, width, height)
    local rx, ry = ns.RouteFollow.Project((x - px) * width, (y - py) * height, facing)
    local d = math.sqrt(rx * rx + ry * ry)
    local scale = frame.radius / RADAR_YARDS
    if d > RADAR_YARDS then
        return rx / d * frame.radius, ry / d * frame.radius, false
    end
    return rx * scale, ry * scale, true
end

local function Dot(pool, x, y, size, color, alpha)
    local t = pool:Next()
    t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
    t:ClearAllPoints()
    t:SetPoint("CENTER", frame.radar, "CENTER", x, y)
    t:SetSize(size, size)
    return t
end

local function Line(x1, y1, x2, y2, thickness, color, alpha)
    local l = frame.lines:Next()
    l:SetThickness(thickness)
    l:SetColorTexture(color[1], color[2], color[3], alpha or 1)
    l:SetStartPoint("CENTER", frame.radar, x1, y1)
    l:SetEndPoint("CENTER", frame.radar, x2, y2)
end

local function DrawRadar(route, state, px, py, facing, width, height)
    local C = ns.API.Theme.colors
    for _, p in ipairs(points or {}) do
        local x, y, inside = RadarPoint(p.x, p.y, px, py, facing, width, height)
        if inside then Dot(frame.dots, x, y, 3, C.textDim, 0.8) end
    end
    frame.dots:Finish()
    local Follow = ns.RouteFollow
    local nextI, afterI = state.index, Follow.After(route, state.index, 1)
    for i, s in ipairs(route.stops) do
        local x, y, inside = RadarPoint(s.x, s.y, px, py, facing, width, height)
        if inside then
            local current = i == nextI or i == afterI
            Dot(frame.stops, x, y, s.n > 1 and 9 or 6, current and C.accent or (s.n > 1 and C.gold or C.text))
            if s.n > 1 then
                local fs = frame.labels:Next()
                fs:SetText(tostring(s.n))
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", frame.radar, "CENTER", x + 6, y)
            end
        end
    end
    frame.stops:Finish()
    frame.labels:Finish()
    local s1, s2 = route.stops[nextI], route.stops[afterI]
    local x1, y1 = RadarPoint(s1.x, s1.y, px, py, facing, width, height)
    Line(0, 0, x1, y1, 3, C.accent)
    if #route.stops > 1 then
        local x2, y2 = RadarPoint(s2.x, s2.y, px, py, facing, width, height)
        Line(x1, y1, x2, y2, 1.5, C.accent, 0.5)
    end
    frame.lines:Finish()
end

--- "~5 s" or "~1:20" to travel distance yards at speed.
function FarmHUD.TravelText(distance, speed)
    local t = math.floor(distance / speed + 0.5)
    if t < 60 then return "~" .. ns.API.Lf("%d s", t) end
    return ("~%d:%02d"):format(math.floor(t / 60), t % 60)
end

--- "Stop 12: 140 yd (3 nodes) ~5 s".
function FarmHUD.StopText(route, i, distance, speed)
    local API = ns.API
    local s = route.stops[i]
    return API.Lf("Stop %d: %s yd", i, API.Format:Number(math.floor(distance + 0.5)))
        .. (s.n > 1 and ("  " .. API.Lf("(%d nodes)", s.n)) or "")
        .. "  " .. FarmHUD.TravelText(distance, speed)
end

local function DrawStops(route, state, px, py, width, height, speed)
    local Follow = ns.RouteFollow
    local i1 = state.index
    local i2 = Follow.After(route, i1, 1)
    local d1 = Follow.Distance(route, i1, px, py, width, height)
    local s1 = route.stops[i1]
    local s2 = route.stops[i2]
    local d2 = d1 + math.sqrt(((s2.x - s1.x) * width) ^ 2 + ((s2.y - s1.y) * height) ^ 2)
    frame.panel.next[1]:SetText("> " .. FarmHUD.StopText(route, i1, d1, speed))
    frame.panel.next[2]:SetText(#route.stops > 1 and ("> " .. FarmHUD.StopText(route, i2, d2, speed)) or "")
    frame.panel.round:SetText(ns.API.Lf("Stop %d/%d", i1, #route.stops)
        .. ((state.laps or 0) > 0 and ("  " .. ns.API.Lf("Lap %d", state.laps + 1)) or ""))
end

--- Session values of the side panel.
function FarmHUD.RefreshPanel()
    if not (frame and frame:IsShown()) then return end
    local L = ns.L
    local _, farm, s = FarmHUD.Route()
    if not s then return end
    local p = frame.panel
    local v = ns.Session.Evaluate(s)
    local duration = ns.Session.Duration(s)
    p.title:SetText(farm.name)
    p.time:SetText(ns.Valuation.FormatDuration(duration))
    p.total:SetText(Money(v.total))
    p.gph:SetText(Money(ns.Valuation.PerHour(v.total, duration)) .. " / h")
    p.nodes:SetText(ns.NodeTracker.Text(s.nodes, duration, v.total) or "")
    p.pause:SetText(s.runningSince and L["Pause"] or L["Resume"])
    for i = 1, TOP_ITEMS do
        local row, item = p.items[i], v.items[i]
        if item then
            row.name:SetText((s.links[item.key] or ns.Valuation.ItemName(item.key)) .. " x" .. item.quantity)
            row.value:SetText(item.value > 0 and Money(item.value) or "-")
        else
            row.name:SetText(i == 1 and L["No loot yet"] or "")
            row.value:SetText("")
        end
    end
end

local function OnUpdate(_, dt)
    elapsed, clock = elapsed + dt, clock + dt
    if elapsed < TICK then return end
    elapsed = 0
    local route = FarmHUD.Route()
    local px, py, facing
    if route then px, py, facing = FarmHUD.Position(route) end
    if not px or InCombatLockdown() then
        FarmHUD.Refresh()
        return
    end
    local width, height = ns.API.Nodes:ZoneYards(route.zone)
    if not width then return end
    local state = FarmHUD.State()
    ns.RouteFollow.Advance(state, route, px, py, width, height)
    local speed = ns.RouteFollow.Speed(state, GetTime(), px * width, py * height)
    DrawRadar(route, state, px, py, facing, width, height)
    DrawStops(route, state, px, py, width, height, speed)
    if clock >= 1 then
        clock = 0
        FarmHUD.RefreshPanel()
    end
end

-- Showing -----------------------------------------------------------------------------------------
--- While wanted but not allowed (combat, other zone), look again every second.
local function WatchLater()
    checkToken = checkToken + 1
    local token = checkToken
    module:After(1, function()
        if token == checkToken then FarmHUD.Refresh() end
    end)
end

function FarmHUD.Refresh()
    if not module then return end
    local show = FarmHUD.Wanted() and FarmHUD.Allowed()
    if show then
        frame = frame or Build()
        local route, farm = FarmHUD.Route()
        if not frame:IsShown() or frame.farmId ~= farm.id then
            points = ns.Route.Points(route.zone, farm.nodes)
            frame.farmId = farm.id
        end
        PlacePanel()
        local wasShown = frame:IsShown()
        frame:Show()
        if not wasShown then
            elapsed, clock = TICK, 0
            frame:SetScript("OnUpdate", OnUpdate)
            OnUpdate(frame, 0)
        end
        FarmHUD.RefreshPanel()
    elseif frame and frame:IsShown() then
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
    end
    if not show and FarmHUD.Wanted() then WatchLater() end
    if ns.HUD then ns.HUD.Refresh() end
end

function FarmHUD.IsShown() return frame ~= nil and frame:IsShown() end

--- Hotkey and /gob farm hud: switch the full-screen HUD for this session.
-- Returns false when the session's farm has no route.
function FarmHUD.Toggle()
    local _, _, s = FarmHUD.Route()
    if not s then return false end
    s.farmHud = not FarmHUD.Wanted()
    FarmHUD.Refresh()
    return true
end

--- Skip key and /gob farm skip: the next stop moves one on.
function FarmHUD.Skip()
    local route = FarmHUD.Route()
    local state = route and FarmHUD.State()
    if not (state and state.index) then return false end
    ns.RouteFollow.Move(state, route, 1)
    return true
end

local function OnSession(_, p)
    if p.action == "start" or p.action == "stop" then module.db.char.routeFollow = nil end
    if p.action == "update" then
        FarmHUD.RefreshPanel()
    else
        FarmHUD.Refresh()
    end
end

function FarmHUD.Enable(m)
    module = m
    local OWNER = "Goblinomics_Gatherer.FarmHUD"
    ns.API.On("GATHERER_SESSION", OnSession, OWNER)
    ns.API.On("GATHERER_FARMS", function() FarmHUD.Refresh() end, OWNER)
    ns.API.On("NODES_CHANGED", function() points = nil; if frame then frame.farmId = nil end; FarmHUD.Refresh() end, OWNER)
    m:RegisterEvent("PLAYER_REGEN_DISABLED", function() FarmHUD.Refresh() end, "FarmHUD")
    m:RegisterEvent("PLAYER_REGEN_ENABLED", function() FarmHUD.Refresh() end, "FarmHUD")
    m:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() FarmHUD.Refresh() end, "FarmHUD")
    FarmHUD.Refresh()
end

function FarmHUD.Disable()
    checkToken = checkToken + 1
    if frame then
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
    end
    if ns.API then
        local OWNER = "Goblinomics_Gatherer.FarmHUD"
        ns.API.Off("GATHERER_SESSION", OWNER)
        ns.API.Off("GATHERER_FARMS", OWNER)
        ns.API.Off("NODES_CHANGED", OWNER)
    end
end
