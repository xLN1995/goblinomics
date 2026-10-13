if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Nodes.lua
-- Gathering nodes (herbs, ore, fish, ...) from a connector, e.g. GatherMate2. One
-- registry like the price sources: a connector registers a source, modules read it
-- through API.Nodes and never touch the other addon. Positions are zone coordinates
-- (0..1) on a uiMapID; ZoneYards turns them into yards for distances.
--   src = { id, name, Types(self) -> { { key, label } }, Zones(self) -> { uiMapID },
--           Nodes(self, uiMapID, type) -> { { id, x, y } },
--           NodeInfo(self, type, id) -> name, icon,
--           Identify(self, localizedName) -> type, id }
-- A source calls API.Nodes:Changed() when its data changes; NODES_CHANGED follows
-- once, debounced.
local _, ns = ...

local Nodes = {}
ns.Nodes = Nodes

local SafeCall = ns.SafeCall
local sources = {}      -- id -> source
local yardsCache = {}   -- uiMapID -> { width, height } | false

function Nodes.RegisterSource(src)
    if type(src) ~= "table" or type(src.id) ~= "string" or type(src.Nodes) ~= "function" then
        error("Goblinomics Nodes:RegisterSource: source needs id and Nodes", 3)
    end
    sources[src.id] = src
    Nodes.Changed()
end

function Nodes.UnregisterSource(id)
    if sources[id] then
        sources[id] = nil
        Nodes.Changed()
    end
end

function Nodes.Changed()
    ns.Timer.Debounce("core:nodes", 1, function() ns.Bus.Emit("NODES_CHANGED", {}) end)
end

--- The source in use (the first registered by id), or nil.
function Nodes.Source()
    local best
    for id, src in pairs(sources) do
        if not best or id < best.id then best = src end
    end
    return best
end

function Nodes.Available() return Nodes.Source() ~= nil end

--- Call a method of the source; nil when there is none or it fails.
local function Call(method, ...)
    local src = Nodes.Source()
    if not (src and type(src[method]) == "function") then return nil end
    local ok, a, b = SafeCall(src[method], src, ...)
    if not ok then return nil end
    return a, b
end

function Nodes.Types() return Call("Types") or {} end
function Nodes.Zones() return Call("Zones") or {} end
function Nodes.List(uiMapID, nodeType) return Call("Nodes", uiMapID, nodeType) or {} end
function Nodes.Info(nodeType, id) return Call("NodeInfo", nodeType, id) end
function Nodes.Identify(name)
    if type(name) ~= "string" or name == "" then return nil end
    return Call("Identify", name)
end

--- Nodes of a zone grouped by type and node: { { type, label, nodes = { { id, name, icon, count } } } },
-- types in the source's order, nodes by name.
function Nodes.Catalog(uiMapID)
    local out = {}
    for _, t in ipairs(Nodes.Types()) do
        local counts = {}
        for _, n in ipairs(Nodes.List(uiMapID, t.key)) do counts[n.id] = (counts[n.id] or 0) + 1 end
        local list = {}
        for id, count in pairs(counts) do
            local name, icon = Nodes.Info(t.key, id)
            list[#list + 1] = { id = id, name = name or ("#" .. id), icon = icon, count = count }
        end
        if #list > 0 then
            table.sort(list, function(a, b) return a.name < b.name end)
            out[#out + 1] = { type = t.key, label = t.label or t.key, nodes = list }
        end
    end
    return out
end

-- Map ---------------------------------------------------------------------------------------
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

--- uiMapID of the player's zone, or nil (instances can have none).
function Nodes.CurrentZone()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local id = C_Map.GetBestMapForUnit("player")
    if IsSecret(id) or type(id) ~= "number" then return nil end
    return id
end

--- Localized name of a zone, or nil.
function Nodes.ZoneName(uiMapID)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMapID)
    return info and info.name or nil
end

--- Width and height of a zone in yards, from two world positions; nil when unknown.
-- The map's x runs along the world's y axis and the other way round.
function Nodes.ZoneYards(uiMapID)
    local cached = yardsCache[uiMapID]
    if cached ~= nil then
        if not cached then return nil end
        return cached[1], cached[2]
    end
    local get = C_Map and C_Map.GetWorldPosFromMapPos
    if not (get and CreateVector2D) then return nil end
    local _, a = get(uiMapID, CreateVector2D(0, 0))
    local _, b = get(uiMapID, CreateVector2D(1, 1))
    if not (a and b) then
        yardsCache[uiMapID] = false
        return nil
    end
    local width, height = math.abs(a.y - b.y), math.abs(a.x - b.x)
    if width <= 0 or height <= 0 then
        yardsCache[uiMapID] = false
        return nil
    end
    yardsCache[uiMapID] = { width, height }
    return width, height
end

ns.API.Nodes = {
    RegisterSource = function(_, src) return Nodes.RegisterSource(src) end,
    UnregisterSource = function(_, id) return Nodes.UnregisterSource(id) end,
    Changed = function() return Nodes.Changed() end,
    Available = function() return Nodes.Available() end,
    Types = function() return Nodes.Types() end,
    Zones = function() return Nodes.Zones() end,
    List = function(_, uiMapID, nodeType) return Nodes.List(uiMapID, nodeType) end,
    Info = function(_, nodeType, id) return Nodes.Info(nodeType, id) end,
    Identify = function(_, name) return Nodes.Identify(name) end,
    Catalog = function(_, uiMapID) return Nodes.Catalog(uiMapID) end,
    CurrentZone = function() return Nodes.CurrentZone() end,
    ZoneName = function(_, uiMapID) return Nodes.ZoneName(uiMapID) end,
    ZoneYards = function(_, uiMapID) return Nodes.ZoneYards(uiMapID) end,
}
