if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/FarmHUD.lua
-- Full-screen farm HUD for a session of a farm with a route. A see-through overlay
-- (clicks pass through): in the middle a radar around the player, turned with the
-- facing. Under it Blizzard's minimap (MinimapRadar, setting on by default): its
-- tracking blips show the nodes that stand right now. On top the farm's known nodes
-- as dots (yellow, grey once mined or found empty on this lap), the next three stops
-- (clusters larger) and lines along them, thinner further ahead. A side
-- panel at the small session window's place (dragging either moves both) shows farm, time, gold, GPH, nodes, the three most
-- valuable items and the next three stops with distance and time to reach them.
-- Shown by the hotkey, /gob farm hud or automatically (setting, off by default);
-- hidden in combat, in instances and outside the farm's zone. While it is shown
-- the small session HUD hides. The radar updates TICK times a second only while
-- shown; the side panel's values follow the session events and a 1 s clock.
local _, ns = ...

local FarmHUD = {}
ns.FarmHUD = FarmHUD

local TICK = 1 / 15
local RADAR_YARDS = 300   -- without the minimap; with it the minimap's view radius
local PANEL_W = 240
local TOP_ITEMS = 3
local AHEAD = 3            -- stops drawn and listed ahead
local LINE_STYLE = { { 7, 0.95 }, { 5, 0.7 }, { 4, 0.45 } }  -- thickness (soft edges), alpha per leg

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
    -- stands where the small session window stands; dragging either moves both (locked with it)
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(self)
        if not Settings().hudLocked then self:StartMoving() end
    end)
    p:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.HUD.SavePlace(self)
    end)
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
    p.title:SetPoint("RIGHT", -(S.SM + 44), 0)
    -- back to the small session window
    p.off = W.Button(p, L["HUD"], { width = 40, height = 16, onClick = function() FarmHUD.Toggle() end,
        tooltip = L["Farm HUD"], tooltipLines = { L["Switches back to the small session window."] } })
    p.off:SetPoint("TOPRIGHT", -S.SM, -S.SM + 2)
    p.off:SetSelected(true)
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
    for i = 1, AHEAD do
        local fs = Line(i == 1 and 12 or 11, i == 1 and C.text or C.textDim)
        fs:SetPoint("RIGHT", -S.SM, 0)
        p.next[i] = fs
        y = y - 16
    end
    p.round = Line(11, C.textDim)
    y = y - 16
    p.legend = Line(10, C.textDim)
    p.legend:SetPoint("RIGHT", -S.SM, 0)
    p.legend:SetText(Theme.Colorize(L["not checked"], C.gold) .. "  " .. Theme.Colorize(L["mined or empty"], C.neutral))
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
    f.yards = RADAR_YARDS
    -- our drawing sits on a frame above the lent minimap
    f.overlay = CreateFrame("Frame", nil, f.radar)
    f.overlay:SetAllPoints(f.radar)
    f.overlay:EnableMouse(false)
    -- ring
    -- smooth shapes placed between pixels: dots and lines glide instead of jumping
    f.ring = Theme.Unsnap(f.overlay:CreateTexture(nil, "BACKGROUND"))
    f.ring:SetTexture(Theme.RING)
    f.ring:SetAllPoints(f.radar)
    Theme.Tint(f.ring, C.textDim, 0.55)
    f.player = W.Chevron(f.overlay, "up", 14)
    f.player:SetPoint("CENTER")
    f.player:SetColor(C.text)
    f.scaleLabel = Theme.Text(f.overlay, 10, C.textDim)
    f.scaleLabel:SetPoint("TOP", f.radar, "BOTTOM", 0, -4)
    f.dots = Pool(function() return Theme.SmoothDot(f.overlay:CreateTexture(nil, "ARTWORK")) end)
    f.stops = Pool(function() return Theme.SmoothDot(f.overlay:CreateTexture(nil, "OVERLAY")) end)
    f.labels = Pool(function() return Theme.Text(f.overlay, 10, C.text) end)
    f.lines = Pool(function() return Theme.SmoothLine(f.overlay:CreateLine(nil, "ARTWORK")) end)
    f.panel = BuildPanel(f)
    f:Hide()   -- new frames show at once: Refresh shows it and starts the updates
    return f
end

--- The side panel at the session window's place.
local function PlacePanel()
    ns.HUD.Place(frame.panel)
end

-- Drawing -----------------------------------------------------------------------------------------
--- Radar point of zone position (x, y) seen from (px, py): pixels right, up and
-- whether it lies inside the radar (outside: clamped to the edge).
local function RadarPoint(x, y, px, py, facing, width, height)
    local rx, ry = ns.RouteFollow.Project((x - px) * width, (y - py) * height, facing)
    local d = math.sqrt(rx * rx + ry * ry)
    local scale = frame.radius / frame.yards
    if d > frame.yards then
        return rx / d * frame.radius, ry / d * frame.radius, false
    end
    return rx * scale, ry * scale, true
end

local function Dot(pool, x, y, size, color, alpha)
    local t = pool:Next()
    ns.API.Theme.Tint(t, color, alpha or 1)
    t:ClearAllPoints()
    t:SetPoint("CENTER", frame.radar, "CENTER", x, y)
    t:SetSize(size, size)
    return t
end

local function Line(x1, y1, x2, y2, thickness, color, alpha)
    local l = frame.lines:Next()
    l:SetThickness(thickness)
    ns.API.Theme.Tint(l, color, alpha or 1)
    l:SetStartPoint("CENTER", frame.radar, x1, y1)
    l:SetEndPoint("CENTER", frame.radar, x2, y2)
end

--- Colour of a known node: mined or found empty grey, otherwise yellow.
function FarmHUD.NodeColor(status)
    local C = ns.API.Theme.colors
    if status == "gathered" or status == "gone" then return C.neutral end
    return C.gold
end

local function DrawRadar(route, state, px, py, facing, width, height)
    local C = ns.API.Theme.colors
    local Follow = ns.RouteFollow
    local ahead = {}
    for k = 0, math.min(AHEAD, #route.stops) - 1 do ahead[Follow.After(route, state.index, k)] = true end
    local nodes = state.nodes or {}
    for _, p in ipairs(points or {}) do
        local x, y, inside = RadarPoint(p.x, p.y, px, py, facing, width, height)
        if inside then Dot(frame.dots, x, y, 7, FarmHUD.NodeColor(nodes[Follow.NodeKey(p)]), 0.95) end
    end
    frame.dots:Finish()
    -- the next stops as rings of their colour, clusters with their count
    for i, s in ipairs(route.stops) do
        if ahead[i] then
            local x, y, inside = RadarPoint(s.x, s.y, px, py, facing, width, height)
            if inside then
                Dot(frame.stops, x, y, s.n > 1 and 16 or 11, C.text, 0.3)
                if s.n > 1 then
                    local fs = frame.labels:Next()
                    fs:SetText(tostring(s.n))
                    fs:ClearAllPoints()
                    fs:SetPoint("LEFT", frame.radar, "CENTER", x + 7, y)
                end
            end
        end
    end
    frame.stops:Finish()
    frame.labels:Finish()
    -- player -> next stop -> the one after -> ..., thinner further ahead
    local fromX, fromY = 0, 0
    for k = 0, math.min(AHEAD, #route.stops) - 1 do
        local s = route.stops[Follow.After(route, state.index, k)]
        local x, y = RadarPoint(s.x, s.y, px, py, facing, width, height)
        local style = LINE_STYLE[k + 1]
        Line(fromX, fromY, x, y, style[1], C.text, style[2])
        fromX, fromY = x, y
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

--- The next AHEAD stops along the round with the distance flown to each.
function FarmHUD.Ahead(route, state, px, py, width, height)
    local Follow = ns.RouteFollow
    local out, distance, prev = {}, 0, nil
    for k = 0, math.min(AHEAD, #route.stops) - 1 do
        local i = Follow.After(route, state.index, k)
        local s = route.stops[i]
        if prev then
            distance = distance + math.sqrt(((s.x - prev.x) * width) ^ 2 + ((s.y - prev.y) * height) ^ 2)
        else
            distance = Follow.Distance(route, i, px, py, width, height)
        end
        out[#out + 1] = { index = i, distance = distance }
        prev = s
    end
    return out
end

local function DrawStops(route, state, px, py, width, height, speed)
    local ahead = FarmHUD.Ahead(route, state, px, py, width, height)
    for k = 1, AHEAD do
        local a = ahead[k]
        frame.panel.next[k]:SetText(a and ("> " .. FarmHUD.StopText(route, a.index, a.distance, speed)) or "")
    end
    frame.panel.round:SetText(ns.API.Lf("Stop %d/%d", state.index, #route.stops)
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
    -- what the player learned about the nodes: mined, passed within reach
    local _, _, s = FarmHUD.Route()
    local gathered = s and s.nodes and s.nodes.total or 0
    if state.gathered and gathered > state.gathered and points then
        ns.RouteFollow.Mark(state, points, px, py, width, height, "gathered")
    end
    state.gathered = gathered
    if points then ns.RouteFollow.Observe(state, points, px, py, width, height) end
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
        if not wasShown then FarmHUD.UseMinimap() end
        if not wasShown then
            elapsed, clock = TICK, 0
            frame:SetScript("OnUpdate", OnUpdate)
            OnUpdate(frame, 0)
        end
        FarmHUD.RefreshPanel()
    elseif frame and frame:IsShown() then
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
        ns.MinimapRadar.Return()
    end
    if not show and FarmHUD.Wanted() then WatchLater() end
    if ns.HUD then ns.HUD.Refresh() end
end

--- Lend the minimap to the radar (setting) and match the radar's scale to it.
function FarmHUD.UseMinimap()
    local Radar = ns.MinimapRadar
    Radar.Return()
    frame.yards = RADAR_YARDS
    if Settings().farmHudMinimap ~= false and Radar.Lend(frame.radar, frame.radius * 2) then
        frame.yards = Radar.ViewRadius()
        frame.overlay:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)
    end
    frame.player:SetShown(not Radar.IsLent())   -- the minimap draws its own arrow
    frame.scaleLabel:SetText(math.floor(frame.yards + 0.5) .. " yd")
end

function FarmHUD.IsShown() return frame ~= nil and frame:IsShown() end

--- The interact target became a game object near the player: a node stands there.
function FarmHUD.OnSoftInteract(_, _, guid)
    if not FarmHUD.IsShown() or not points then return end
    guid = guid or (UnitGUID and UnitGUID("softinteract"))
    if IsSecret(guid) or type(guid) ~= "string" or not guid:match("^GameObject") then return end
    local route = FarmHUD.Route()
    if not route then return end
    local px, py = FarmHUD.Position(route)
    local width, height = ns.API.Nodes:ZoneYards(route.zone)
    if px and width then ns.RouteFollow.Mark(FarmHUD.State(), points, px, py, width, height, "seen") end
end

--- Hotkey and /gob farm hud: switch the full-screen HUD for this session.
-- Returns false when the session's farm has no route.
function FarmHUD.Toggle()
    local _, _, s = FarmHUD.Route()
    if not s then return false end
    s.farmHud = not FarmHUD.Wanted()
    FarmHUD.Refresh()
    return true
end

--- Toggle, and say why the HUD does not show when it cannot right now (other zone,
-- combat, instance). False when the session's farm has no route.
function FarmHUD.ToggleWithHint()
    if not FarmHUD.Toggle() then return false end
    if FarmHUD.Wanted() and not FarmHUD.IsShown() then
        ns.API.Print(ns.L["The farm HUD shows up in the farm's zone, out of combat and outside instances."], true)
    end
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
    -- after a login or /reload the HUD stays off until switched on again
    local s = ns.Session.Active()
    if s then s.farmHud = false end
    local OWNER = "Goblinomics_Gatherer.FarmHUD"
    ns.API.On("GATHERER_SESSION", OnSession, OWNER)
    ns.API.On("GATHERER_FARMS", function() FarmHUD.Refresh() end, OWNER)
    ns.API.On("NODES_CHANGED", function() points = nil; if frame then frame.farmId = nil end; FarmHUD.Refresh() end, OWNER)
    m:RegisterEvent("PLAYER_REGEN_DISABLED", function() FarmHUD.Refresh() end, "FarmHUD")
    m:RegisterEvent("PLAYER_REGEN_ENABLED", function() FarmHUD.Refresh() end, "FarmHUD")
    m:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() FarmHUD.Refresh() end, "FarmHUD")
    -- the minimap's rotation is a saved setting: give it back before it is saved
    m:RegisterEvent("PLAYER_LOGOUT", function() ns.MinimapRadar.Return() end, "FarmHUD")
    m:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED", FarmHUD.OnSoftInteract, "FarmHUD")
    FarmHUD.Refresh()
end

function FarmHUD.Disable()
    checkToken = checkToken + 1
    if frame then
        frame:SetScript("OnUpdate", nil)
        frame:Hide()
    end
    ns.MinimapRadar.Return()
    if ns.API then
        local OWNER = "Goblinomics_Gatherer.FarmHUD"
        ns.API.Off("GATHERER_SESSION", OWNER)
        ns.API.Off("GATHERER_FARMS", OWNER)
        ns.API.Off("NODES_CHANGED", OWNER)
    end
end
