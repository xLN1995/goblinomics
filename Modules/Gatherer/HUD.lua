if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/HUD.lua
-- Compact standalone session window: farm, running time, total, GPH, the three
-- most valuable items, pause/resume and stop. Visible while a session exists
-- (hideable per session). The clock ticks once per second only while a session
-- runs and the HUD is shown; values are recomputed on session updates, debounced.
local _, ns = ...

local HUD = {}
ns.HUD = HUD

local WIDTH, HEIGHT = 230, 150
local TOP_ITEMS = 3

local module, frame, ticker
local valuation            -- cached valuation of the active session
local dirtyToken = 0

local function Position()
    local c = module.db.char
    c.hudPos = c.hudPos or {}
    return c.hudPos
end

local function Build()
    local API = ns.API
    local W, Theme = API.Widgets, API.Theme
    local C = Theme.colors
    local L = ns.L
    local f = CreateFrame("Frame", "GoblinomicsGathererHUD", UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    Theme.Backdrop(f, C.overlay, C.border)
    f:SetScript("OnDragStart", function(self)
        if not module.db.settings.hudLocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pos = Position()
        local point, _, relPoint, x, y = self:GetPoint(1)
        pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y
    end)
    local pos = Position()
    if pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPRIGHT", -260, -200)
    end

    f.title = Theme.Text(f, 12, C.gold)
    f.title:SetPoint("TOPLEFT", 8, -7)
    f.title:SetPoint("RIGHT", -24, 0)
    f.title:SetWordWrap(false)
    local close = CreateFrame("Button", nil, f)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -4, -4)
    close.label = Theme.Text(close, 12, C.textDim)
    close.label:SetPoint("CENTER")
    close.label:SetText("x")
    close:SetScript("OnClick", function() HUD.HideForSession() end)
    close:SetScript("OnEnter", function(self)
        W.ShowTooltip(self, L["Hide"], { L["Hides the HUD until the next session. /gob farm hud shows it again."] })
    end)
    close:SetScript("OnLeave", W.HideTooltip)

    f.time = Theme.Text(f, 16, C.text)
    f.time:SetPoint("TOPLEFT", 8, -24)
    f.total = Theme.Text(f, 14, C.gold)
    f.total:SetPoint("TOPRIGHT", -8, -24)
    f.total:SetJustifyH("RIGHT")
    f.gph = Theme.Text(f, 11, C.textDim)
    f.gph:SetPoint("TOPRIGHT", -8, -44)
    f.gph:SetJustifyH("RIGHT")
    f.status = Theme.Text(f, 11, C.textDim)
    f.status:SetPoint("TOPLEFT", 8, -44)

    f.items = {}
    for i = 1, TOP_ITEMS do
        local name = Theme.Text(f, 11, C.text)
        name:SetPoint("TOPLEFT", 8, -60 - (i - 1) * 15)
        name:SetPoint("RIGHT", -80, 0)
        name:SetWordWrap(false)
        local value = Theme.Text(f, 11, C.text)
        value:SetPoint("TOPRIGHT", -8, -60 - (i - 1) * 15)
        value:SetJustifyH("RIGHT")
        f.items[i] = { name = name, value = value }
    end

    f.pause = W.Button(f, L["Pause"], { width = 105, height = 20, onClick = function()
        if ns.Session.IsRunning() then ns.Session.Pause() else ns.Session.Resume() end
    end })
    f.pause:SetPoint("BOTTOMLEFT", 6, 6)
    f.stop = W.Button(f, L["Stop"], { width = 105, height = 20, onClick = function() HUD.StopAndSummarize() end })
    f.stop:SetPoint("BOTTOMRIGHT", -6, 6)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then API.UI:Show("gatherer") end
    end)
    return f
end

local function Money(copper)
    return ns.API.Money.Format(copper, { abbreviate = true })
end

local function UpdateClock()
    if not frame or not frame:IsShown() then return end
    local s = ns.Session.Active()
    if not s then return end
    local duration = ns.Session.Duration(s)
    frame.time:SetText(ns.Valuation.FormatDuration(duration))
    if valuation then
        frame.gph:SetText(Money(ns.Valuation.PerHour(valuation.total, duration)) .. " / h")
    end
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(1, UpdateClock)
end

function HUD.Refresh()
    local s = ns.Session.Active()
    -- the full-screen farm HUD replaces it while shown
    if not s or s.hudHidden or (ns.FarmHUD and ns.FarmHUD.IsShown()) then
        StopTicker()
        if frame then frame:Hide() end
        return
    end
    frame = frame or Build()
    local L = ns.L
    local farm = s.farmId and ns.Farms.Get(s.farmId) or nil
    frame.title:SetText(farm and farm.name or L["Ad-hoc session"])
    valuation = ns.Session.Evaluate(s)
    frame.total:SetText(Money(valuation.total))
    local running = s.runningSince ~= nil
    frame.status:SetText(running and "" or (s.autoPaused and L["Auto-paused"] or L["Paused"]))
    frame.pause:SetText(running and L["Pause"] or L["Resume"])
    for i = 1, TOP_ITEMS do
        local row, item = frame.items[i], valuation.items[i]
        if item then
            local label = s.links[item.key] or ns.Valuation.ItemName(item.key)
            row.name:SetText(label .. ns.API.ItemMarks:Inline(item.key) .. " x" .. item.quantity)
            row.value:SetText(item.value > 0 and Money(item.value) or "-")
        else
            row.name:SetText(i == 1 and L["No loot yet"] or "")
            row.value:SetText("")
        end
    end
    frame:Show()
    UpdateClock()
    if running then StartTicker() else StopTicker() end
end

-- Loot can arrive in bursts (AoE loot, restricted replay): recompute once.
local function RefreshSoon()
    dirtyToken = dirtyToken + 1
    local token = dirtyToken
    module:After(0.3, function()
        if token == dirtyToken then HUD.Refresh() end
    end)
end

function HUD.HideForSession()
    local s = ns.Session.Active()
    if s then s.hudHidden = true end
    HUD.Refresh()
end

function HUD.ShowForSession()
    local s = ns.Session.Active()
    if s then s.hudHidden = nil end
    HUD.Refresh()
end

function HUD.StopAndSummarize()
    local summary = ns.Session.Stop()
    if summary and ns.Summary then ns.Summary.Show(summary) end
end

function HUD.IsShown() return frame ~= nil and frame:IsShown() end

local function OnSession(_, p)
    if p.action == "update" then
        RefreshSoon()
    else
        HUD.Refresh()
    end
end

function HUD.Enable(m)
    module = m
    m:On("GATHERER_SESSION", OnSession)
    m:On("PRICES_CHANGED", function() if frame and frame:IsShown() then RefreshSoon() end end)
    HUD.Refresh()
end

function HUD.Disable()
    StopTicker()
    if frame then frame:Hide() end
end
