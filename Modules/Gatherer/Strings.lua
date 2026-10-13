if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Strings.lua
-- Farm and watchlist exchange strings:
--   !GOB:FARM:2!<data>    one or more farm definitions (without history); version 1
--                         strings (expected items plus a farm watchlist) still import.
--                         Zone and nodes are optional fields: older versions ignore them
--   !GOB:WATCH:1!<data>   item keys of a watchlist
-- data = LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(LibSerialize:Serialize(payload)))
-- Import checks prefix, version and every field; imported farms get new ids and
-- a unique name, watchlist items are added to the global watchlist.
local _, ns = ...

local Strings = {}
ns.Strings = Strings

local VERSIONS = { FARM = 2, WATCH = 1 }
local MAX_ITEMS = 500
local MAX_FARMS = 100

local function Libs()
    local serialize = LibStub and LibStub("LibSerialize", true)
    local deflate = LibStub and LibStub("LibDeflate", true)
    return serialize, deflate
end

local function Encode(kind, payload)
    local serialize, deflate = Libs()
    if not (serialize and deflate) then return nil end
    local data = deflate:EncodeForPrint(deflate:CompressDeflate(serialize:Serialize(payload)))
    return ("!GOB:%s:%d!%s"):format(kind, VERSIONS[kind], data)
end

--- kind, payload, version or nil, error key.
local function Decode(text)
    local serialize, deflate = Libs()
    if not (serialize and deflate) then return nil, "libs" end
    text = strtrim(text or ""):gsub("%s", "")
    local kind, version, data = text:match("^!GOB:(%u+):(%d+)!(.+)$")
    if not kind then return nil, "format" end
    version = tonumber(version)
    if not VERSIONS[kind] then return nil, "format" end
    if version > VERSIONS[kind] then return nil, "version" end
    local decoded = deflate:DecodeForPrint(data)
    local raw = decoded and deflate:DecompressDeflate(decoded)
    if not raw then return nil, "format" end
    local ok, payload = serialize:Deserialize(raw)
    if not ok or type(payload) ~= "table" then return nil, "format" end
    return kind, payload, version
end

local function ValidKey(key)
    return type(key) == "string" and #key <= 100 and key:match("^[ip]:%d") ~= nil and not key:find("[^%w:%-]")
end

local function KeyList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, math.min(#list, MAX_ITEMS) do
        if ValidKey(list[i]) then out[#out + 1] = list[i] end
    end
    return out
end

local function FarmPayload(farm)
    return {
        name = farm.name, category = farm.category, expectedHighlights = farm.expectedHighlights,
        instance = farm.instance, highlightThreshold = farm.highlightThreshold,
        zone = farm.zone, nodes = farm.nodes,
    }
end

local function Nodes(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i = 1, math.min(#list, 50) do out[#out + 1] = list[i] end
    return ns.Farms.CleanNodes(out) or false
end

--- Export string of farms (list of farm ids).
function Strings.ExportFarms(ids)
    local farms = {}
    for _, id in ipairs(ids) do
        local farm = ns.Farms.Get(id)
        if farm then farms[#farms + 1] = FarmPayload(farm) end
    end
    if #farms == 0 then return nil end
    return Encode("FARM", { farms = farms })
end

function Strings.ExportWatchlist()
    return Encode("WATCH", { items = ns.Highlights.Watchlist() })
end

local function UniqueName(name)
    if not ns.Farms.FindByName(name) then return name end
    local n = 2
    while ns.Farms.FindByName(("%s (%d)"):format(name, n)) do n = n + 1 end
    return ("%s (%d)"):format(name, n)
end

-- Version 1 had expected items and a separate farm watchlist; both are highlights now.
local function Highlights(f, version)
    if version >= 2 then return KeyList(f.expectedHighlights) end
    local list = KeyList(f.expectedItems)
    local extra = {}
    for _, key in ipairs(KeyList(f.watchlist)) do
        if not tContains(list, key) then extra[#extra + 1] = key end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do list[#list + 1] = key end
    return list
end

-- Older strings carry the instance as a plain name.
local function Instance(f)
    if type(f.instance) == "string" then
        return ns.Farms.CleanInstance({ name = f.instance, isRaid = f.category == "raid" }) or false
    end
    return ns.Farms.CleanInstance(f.instance) or false
end

local function ImportFarms(payload, version)
    if type(payload.farms) ~= "table" then return nil, "format" end
    local specs = {}
    for i = 1, math.min(#payload.farms, MAX_FARMS) do
        local f = payload.farms[i]
        if type(f) ~= "table" or type(f.name) ~= "string" or strtrim(f.name) == "" or #f.name > 100 then
            return nil, "format"
        end
        specs[#specs + 1] = {
            name = strtrim(f.name), category = type(f.category) == "string" and f.category or "other",
            expectedHighlights = Highlights(f, version),
            instance = Instance(f),
            highlightThreshold = tonumber(f.highlightThreshold),
            zone = tonumber(f.zone) or false, nodes = Nodes(f.nodes) or false,
        }
    end
    if #specs == 0 then return nil, "format" end
    local created = {}
    for _, spec in ipairs(specs) do
        spec.name = UniqueName(spec.name)
        created[#created + 1] = ns.Farms.Create(spec)
    end
    return "farms", created
end

local function ImportWatchlist(payload)
    local keys = KeyList(payload.items)
    if #keys == 0 then return nil, "format" end
    for _, key in ipairs(keys) do ns.Highlights.SetWatched(key, true, nil) end
    return "watchlist", keys
end

--- Import a string. Returns kind ("farms" | "watchlist"), created list; or nil, error key.
function Strings.Import(text)
    local kind, payload, version = Decode(text)
    if not kind then return nil, payload end
    if kind == "FARM" then return ImportFarms(payload, version) end
    if kind == "WATCH" then return ImportWatchlist(payload) end
    return nil, "format"
end

function Strings.ErrorText(err)
    local L = ns.L
    if err == "version" then return L["This string needs a newer Goblinomics version."] end
    return L["Not a valid Goblinomics farm or watchlist string."]
end

-- Dialogs ------------------------------------------------------------------------
function Strings.ShowExport(id)
    local L = ns.L
    local text = id and Strings.ExportFarms({ id })
    if not text then return end
    ns.TextDialog.ShowCopy({ title = L["Export farm"], text = text })
end

function Strings.ShowWatchlistExport()
    local L = ns.L
    ns.TextDialog.ShowCopy({ title = L["Export watchlist"], text = Strings.ExportWatchlist() or "" })
end

function Strings.ShowImport()
    local L = ns.L
    ns.TextDialog.ShowPaste({
        title = L["Import farm or watchlist"],
        onAccept = function(text)
            local kind, result = Strings.Import(text)
            if not kind then return false, Strings.ErrorText(result) end
            if kind == "farms" and ns.GathererUI then ns.GathererUI.Select(result[1].id) end
            ns.API.Print(kind == "farms" and ns.API.Lf("Imported %d farms.", #result)
                or ns.API.Lf("Added %d items to the watchlist.", #result), true)
            return true
        end,
    })
end
