if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/JealousmeterUI.lua
-- Jealousmeter display: right-hand side panel of the main window (face on top,
-- a vertical bar filling bottom to top by absolute gold towards the next level
-- with marks at 0/25/50/75/100 % showing the gold needed there, "GALLYWIX" read
-- top to bottom on its left and "JEALOUSMETER" on its right, the current wealth
-- - the figure the level is measured by - below it; levels have no
-- names, the faces suffice), an optional
-- movable and lockable window with the same content,
-- prestige frames drawn in code, the level-up toast and the tooltip line for the
-- minimap / LDB / compartment. Updates only on NETWORTH_UPDATED. The meter leaves
-- speculative items out: their value is too uncertain to count.
local _, ns = ...

local JUI = {}
ns.JealousmeterUI = JUI

local API = ns.API
local J = ns.Jealousmeter
local L = API.L

local vault
local state = { copper = 0, level = nil }
local preview = nil          -- { copper, level, highest } while /gob jealous is active
local meters = {}            -- built meter objects (side panel, window)
local window

local GOLD = { API.Theme.colors.brass, API.Theme.colors.brassDark }
local MARKS = { 0, 0.25, 0.5, 0.75, 1 }

--- Letters of a word one per line (read top to bottom).
local function Vertical(word)
    return (word:gsub("(.)", "%1\n"):gsub("\n$", ""))
end
JUI.Vertical = Vertical
local DIAMOND = { { 1, 1, 1, 1 }, API.Theme.colors.diamond }

-- Drawing ------------------------------------------------------------------------
local function Edge(parent, color, inset, size)
    local edges = {}
    local specs = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i = 1, 4 do
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(unpack(color))
        local a, b, horizontal = specs[i][1], specs[i][2], specs[i][3]
        local ox = (a:find("LEFT") and -inset or inset)
        local oy = (a:find("TOP") and inset or -inset)
        t:SetPoint(a, parent, a, ox, oy)
        local bx = (b:find("LEFT") and -inset or inset)
        local by = (b:find("TOP") and inset or -inset)
        t:SetPoint(b, parent, b, bx, by)
        if horizontal then t:SetHeight(size) else t:SetWidth(size) end
        edges[i] = t
    end
    return edges
end

local function SetEdges(edges, shown, color)
    for i = 1, #edges do
        edges[i]:SetShown(shown)
        if color then edges[i]:SetColorTexture(unpack(color)) end
    end
end

local function BuildMeter(parent)
    local m = {}
    local face = parent:CreateTexture(nil, "ARTWORK")
    face:SetSize(64, 64)
    face:SetPoint("TOP", 0, -10)
    m.face = face
    -- prestige frames and glow are anchored to the face
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(face)
    m.outer = Edge(holder, GOLD[1], 4, 2)
    m.inner = Edge(holder, GOLD[2], 2, 2)
    local glow = holder:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("TOPLEFT", -10, 10)
    glow:SetPoint("BOTTOMRIGHT", 10, -10)
    local dc = API.Theme.colors.diamond
    glow:SetColorTexture(dc[1], dc[2], dc[3], 0.25)
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local a = pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.2)
    a:SetToAlpha(0.8)
    a:SetDuration(1.2)
    m.glow, m.pulse = glow, pulse
    SetEdges(m.outer, false)
    SetEdges(m.inner, false)

    local Theme = API.Theme
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(unpack(API.Theme.colors.brass))
    bar:SetMinMaxValues(0, 1)
    bar:SetWidth(40)
    bar:SetPoint("TOP", face, "BOTTOM", 0, -14)
    bar:SetPoint("BOTTOM", parent, "BOTTOM", 0, 34)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(API.Theme.colors.track))
    m.bar = bar

    -- "GALLYWIX" left and "JEALOUSMETER" right of the bar, read top to bottom
    for _, side in ipairs({ { "GALLYWIX", "RIGHT", "LEFT", -7 }, { "JEALOUSMETER", "LEFT", "RIGHT", 7 } }) do
        local fs = Theme.Text(parent, 9, Theme.colors.gold)
        fs:SetJustifyH("CENTER")
        fs:SetSpacing(1)
        fs:SetText(Vertical(side[1]))
        fs:SetPoint(side[2], bar, side[3], side[4], 0)
    end

    -- marks at 0/25/50/75/100 % with the gold needed there
    m.marks = {}
    local layer = CreateFrame("Frame", nil, bar)
    layer:SetAllPoints()
    layer:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)
    for i, frac in ipairs(MARKS) do
        local tick = layer:CreateTexture(nil, "OVERLAY")
        tick:SetColorTexture(0, 0, 0, 0.55)
        tick:SetHeight(1)
        local label = layer:CreateFontString(nil, "OVERLAY")
        label:SetFontObject(Theme.Font(9, "OUTLINE"))
        label:SetTextColor(1, 1, 1, 1)
        label:SetJustifyH("CENTER")
        m.marks[i] = { frac = frac, tick = tick, label = label }
    end
    local function PlaceMarks()
        local h = (bar.GetHeight and bar:GetHeight()) or 0
        if not h or h <= 0 then h = 200 end
        for _, mark in ipairs(m.marks) do
            local y = mark.frac * h
            mark.tick:ClearAllPoints()
            mark.tick:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, y)
            mark.tick:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, y)
            mark.label:ClearAllPoints()
            if mark.frac == 0 then
                mark.label:SetPoint("BOTTOM", bar, "BOTTOM", 0, 2)
            elseif mark.frac == 1 then
                mark.label:SetPoint("TOP", bar, "TOP", 0, -2)
            else
                mark.label:SetPoint("BOTTOM", bar, "BOTTOM", 0, y + 2)
            end
        end
    end
    bar:SetScript("OnSizeChanged", PlaceMarks)
    PlaceMarks()

    -- the wealth the level is measured by
    local wealth = Theme.Text(parent, 11, Theme.colors.gold)
    wealth:SetPoint("BOTTOM", 0, 12)
    wealth:SetWidth(112)
    wealth:SetJustifyH("CENTER")
    m.wealth = wealth

    parent:EnableMouse(true)
    parent:SetScript("OnEnter", function(self) JUI.ShowTiersTooltip(self) end)
    parent:SetScript("OnLeave", function() GameTooltip:Hide() end)
    parent:SetScript("OnHide", function() pulse:Stop() end)
    meters[#meters + 1] = m
    return m
end

local function Current()
    if preview then return preview.copper, preview.level end
    return state.copper, state.level or 0
end

local function UpdateMeter(m)
    local copper, level = Current()
    local info = J.Info(copper, level)
    m.face:SetTexture(J.Texture(level))
    m.bar:SetValue(info.progress)
    m.wealth:SetText(API.Money.Format(math.floor(copper / 10000) * 10000, { abbreviate = true }))
    for _, mark in ipairs(m.marks) do
        if info.next then
            local lo = J.THRESHOLDS[level]
            mark.label:SetText(API.Charts.AxisLabel((lo + (info.next - lo) * mark.frac) * 10000))
        else
            mark.label:SetText(mark.frac == 1 and L["Maximum"] or "")
        end
    end
    local p = info.prestige
    SetEdges(m.outer, p >= 1, p >= 2 and DIAMOND[1] or GOLD[1])
    SetEdges(m.inner, p >= 1, p >= 2 and DIAMOND[2] or GOLD[2])
    local shine = p >= 3
    m.glow:SetShown(shine)
    if shine and m.face:IsVisible() then m.pulse:Play() else m.pulse:Stop() end
end

function JUI.Refresh()
    for i = 1, #meters do UpdateMeter(meters[i]) end
end

function JUI.ShowTiersTooltip(owner)
    local _, level = Current()
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(L["Gallywix Jealousmeter"], 1, 0.82, 0)
    for l = 0, J.MAX_LEVEL do
        local _, prestige = J.Face(l)
        local label = ("|T%s:18|t"):format(J.Texture(l, true)) .. (prestige > 0 and (" x" .. ({ 2, 5, 10 })[prestige]) or "")
        local text = API.Money.Format(J.THRESHOLDS[l] * 10000, { abbreviate = true })
        if l == level then
            GameTooltip:AddDoubleLine("> " .. label, text, 0.247, 0.749, 0.247, 0.247, 0.749, 0.247)
        else
            GameTooltip:AddDoubleLine(label, text, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

-- Window -------------------------------------------------------------------------
local function WindowPosition()
    local c = vault.db.char
    c.jealousWindow = c.jealousWindow or {}
    return c.jealousWindow
end

local function BuildWindow()
    window = CreateFrame("Frame", "GoblinomicsJealousmeterWindow", UIParent)
    window:SetSize(118, 380)
    window:SetFrameStrata("MEDIUM")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    -- floating windows share one look: overlay background with a 1 px border (like the HUD)
    API.Theme.Backdrop(window, API.Theme.colors.overlay, API.Theme.colors.border)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self)
        if not vault.db.settings.jealousmeter.locked then self:StartMoving() end
    end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pos = WindowPosition()
        local point, _, relPoint, x, y = self:GetPoint(1)
        pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y
    end)
    local pos = WindowPosition()
    window:ClearAllPoints()
    if pos.point then
        window:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        window:SetPoint("RIGHT", -40, 0)
    end
    BuildMeter(window)
end

function JUI.ApplyWindowSetting()
    local on = vault and vault.db.settings.jealousmeter.window
    if on then
        if not window then BuildWindow() end
        window:Show()
        JUI.Refresh()
    elseif window then
        window:Hide()
    end
end

-- Level changes ------------------------------------------------------------------
local function Toast(level)
    local _, prestige = J.Face(level)
    local text = API.Money.Format(J.THRESHOLDS[level] * 10000, { abbreviate = true })
        .. (prestige > 0 and (" (x" .. ({ 2, 5, 10 })[prestige] .. ")") or "")
    local sound = API.Sounds:Resolve(vault.db.settings.jealousmeter.sound, "kit:UI_EPICLOOT_TOAST")
    if sound == "none" then sound = nil end
    API.UI:Toast({ title = L["Gallywix Jealousmeter"], text = text, icon = J.Texture(level, true), sound = sound })
end

--- Apply a new total (copper). Toasts a new high; first ever value is recorded silently.
function JUI.SetTotal(copper)
    state.copper = copper
    state.level = J.Level(copper, state.level)
    local store = vault.db.root.jealousmeter
    if (store.highestLevel or -1) < 0 then
        store.highestLevel = state.level
    elseif J.IsNewHigh(state.level, store.highestLevel) then
        store.highestLevel = state.level
        Toast(state.level)
    end
    if not preview then JUI.Refresh() end
end

--- The value the meter measures: wealth without the speculative items.
function JUI.Value(result)
    return math.max(0, (result.wealth or 0) - (result.speculative or 0))
end

local function OnNetworth(_, result)
    JUI.SetTotal(JUI.Value(result))
end

-- /gob jealous <gold> | off : display preview (does not change saved data)
local function PreviewCommand(arg)
    arg = (arg or ""):lower()
    if arg == "off" or arg == "" then
        preview = nil
        JUI.Refresh()
        return
    end
    local gold = tonumber((arg:gsub("[%s,%.]", "")))
    if not gold then return end
    local copper = gold * 10000
    preview = preview or { highest = state.level or 0 }
    preview.copper = copper
    preview.level = J.Level(copper, preview.level)
    if preview.level > preview.highest then
        preview.highest = preview.level
        Toast(preview.level)
    end
    JUI.Refresh()
end

function JUI.Enable(module)
    vault = module
    module:On("NETWORTH_UPDATED", OnNetworth)
    API.UI:RegisterSidePanel({
        id = "jealousmeter",
        width = 118,
        build = function(frame) BuildMeter(frame) end,
        onShow = function() JUI.Refresh() end,
    })
    API.UI:RegisterTooltipProvider("jealousmeter", function(tt)
        local copper, level = Current()
        tt:AddLine(" ")
        tt:AddDoubleLine(("|T%s:20|t %s"):format(J.Texture(level, true), L["Wealth"]),
            API.Money.Format(copper, { abbreviate = true }), 1, 0.82, 0, 1, 1, 1)
    end)
    API.RegisterCommand("jealous", PreviewCommand, L["<gold>|off - preview the Jealousmeter"])
    JUI.ApplyWindowSetting()
end

function JUI.Disable()
    if window then window:Hide() end
end

JUI.Current = Current
JUI.Meters = function() return meters end
JUI.GetState = function() return state end
