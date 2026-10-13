if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/MinimapRadar.lua
-- Lends Blizzard's minimap to the farm HUD: only the minimap's tracking blips show
-- which nodes stand right now (no API tells that). While lent, the minimap sits
-- enlarged in the HUD's radar, fully zoomed out, its terrain invisible (alpha 0 -
-- the blips still draw), turning with the player, without mouse. Everything that
-- hangs on it (buttons, border, pins of other addons) waits on a hidden stand-in at
-- its old place. Giving it back restores parent, anchors, size, scale, strata,
-- level, alpha, zoom, mouse and the rotation setting exactly as they were - also
-- at logout, since the rotation is a saved setting.
local _, ns = ...

local Radar = {}
ns.MinimapRadar = Radar

-- yards from the centre to the edge at zoom 0 outdoors, when the client cannot say
local FALLBACK_RADIUS = 233.33

local saved, standIn, moved
local lent = false
local enforcing = false
local hooked = false

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- The frame type's own method, past anything another addon put on the minimap.
local function Call(method, ...)
    local mt = getmetatable(Minimap)
    local index = mt and mt.__index
    local fn = type(index) == "table" and index[method] or Minimap[method]
    if type(fn) == "function" then return fn(Minimap, ...) end
end

local function Pack(...) return { n = select("#", ...), ... } end

local function Points(obj)
    local out = {}
    local n = obj.GetNumPoints and obj:GetNumPoints() or 0
    for i = 1, n do out[i] = Pack(obj:GetPoint(i)) end
    return out
end

-- Re-anchor obj to its saved points, with references to `from` pointing at `to`.
local function Anchor(obj, points, from, to)
    obj:ClearAllPoints()
    for _, p in ipairs(points) do
        local args = {}
        for i = 1, p.n do
            local v = p[i]
            if from ~= nil and v == from then v = to end
            args[i] = v
        end
        obj:SetPoint(unpack(args, 1, p.n))
    end
end

local function GetCVar(name)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
end

local function SetCVar(name, value)
    if C_CVar and C_CVar.SetCVar then C_CVar.SetCVar(name, value) end
    if Minimap_UpdateRotationSetting then Minimap_UpdateRotationSetting() end
end

local function Hook()
    if hooked then return end
    hooked = true
    -- others may zoom or fade the minimap while it is lent: keep our values
    hooksecurefunc(Minimap, "SetZoom", function()
        if lent and not enforcing then
            enforcing = true
            Call("SetZoom", 0)
            enforcing = false
        end
    end)
    hooksecurefunc(Minimap, "SetAlpha", function()
        if lent and not enforcing then
            enforcing = true
            Call("SetAlpha", 0)
            enforcing = false
        end
    end)
end

function Radar.IsLent() return lent end

--- Yards from the radar's centre to its edge while lent.
function Radar.ViewRadius()
    local r = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
    if type(r) == "number" and not IsSecret(r) and r > 0 then return r end
    return FALLBACK_RADIUS
end

--- Lend the minimap to parent (centred, size x size pixels). False when it cannot be
-- lent now (no minimap, already lent, in combat).
function Radar.Lend(parent, size)
    if lent or not Minimap or InCombatLockdown() then return false end
    saved = {
        parent = Minimap:GetParent(), points = Points(Minimap), scale = Minimap:GetScale(),
        strata = Minimap:GetFrameStrata(), level = Minimap:GetFrameLevel(), alpha = Minimap:GetAlpha(),
        zoom = Minimap:GetZoom(), mouse = Minimap:IsMouseEnabled(), wheel = Minimap:IsMouseWheelEnabled(),
        rotate = GetCVar("rotateMinimap"),
    }
    saved.width, saved.height = Minimap:GetSize()
    -- a hidden stand-in at the minimap's place keeps what hangs on it
    standIn = standIn or CreateFrame("Frame", nil, UIParent)
    standIn:SetParent(saved.parent or UIParent)
    Anchor(standIn, saved.points, nil, nil)
    standIn:SetSize(saved.width or 140, saved.height or 140)
    standIn:Hide()
    moved = {}
    local objects = { Minimap:GetChildren() }
    for _, r in ipairs({ Minimap:GetRegions() }) do objects[#objects + 1] = r end
    for _, obj in ipairs(objects) do
        if obj ~= parent then
            local entry = { obj = obj, points = Points(obj) }
            if pcall(obj.SetParent, obj, standIn) then
                pcall(Anchor, obj, entry.points, Minimap, standIn)
                moved[#moved + 1] = entry
            end
        end
    end
    Hook()
    lent = true
    enforcing = true
    Call("Hide")
    Call("SetParent", parent)
    Call("ClearAllPoints")
    if not pcall(Call, "SetPoint", "CENTER", parent, "CENTER", 0, 0) then Call("SetAllPoints", parent) end
    Call("SetFrameStrata", parent:GetFrameStrata() or "BACKGROUND")
    Call("SetScale", 1)
    Call("SetSize", size, size)
    Call("SetZoom", 0)
    Call("SetAlpha", 0)
    Call("EnableMouse", false)
    Call("EnableMouseWheel", false)
    Call("Show")
    enforcing = false
    SetCVar("rotateMinimap", "1")
    return true
end

--- Give the minimap back exactly as it was.
function Radar.Return()
    if not lent then return end
    lent = false
    if saved.rotate ~= nil then SetCVar("rotateMinimap", saved.rotate) end
    Call("Hide")
    Call("SetParent", saved.parent)
    Anchor(Minimap, saved.points, nil, nil)
    if saved.width then Call("SetSize", saved.width, saved.height) end
    if saved.scale then Call("SetScale", saved.scale) end
    if saved.strata then Call("SetFrameStrata", saved.strata) end
    if saved.level then Call("SetFrameLevel", saved.level) end
    Call("SetAlpha", saved.alpha or 1)
    if type(saved.zoom) == "number" then
        local levels = Minimap:GetZoomLevels()
        Call("SetZoom", math.min(saved.zoom, type(levels) == "number" and levels - 1 or saved.zoom))
    end
    Call("EnableMouse", saved.mouse ~= false)
    Call("EnableMouseWheel", saved.wheel ~= false)
    Call("Show")
    for _, entry in ipairs(moved or {}) do
        local obj = entry.obj
        if pcall(obj.SetParent, obj, Minimap) then pcall(Anchor, obj, entry.points, standIn, Minimap) end
    end
    moved, saved = nil, nil
end
