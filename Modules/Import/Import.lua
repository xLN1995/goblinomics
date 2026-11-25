if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Import/Import.lua
-- Import (load on demand, M8): history from TSM Accounting and Journalator into
-- the Ledger (bookings, auction log; AH purchases of the last 14 days become
-- Workshop purchase lots through LEDGER_TRANSACTION). Readers (TSM.lua,
-- Journalator.lua) turn the other addon's data into a batch { entries, events };
-- the Ledger's API.Ledger:Import skips everything already known, so repeated
-- imports and TSM followed by Journalator stay free of duplicates. Every import
-- is listed with its id and can be undone.
local ADDON_NAME, ns = ...

local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end
ns.API = API
ns.L = API.L

local Import = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "Import",
    description = function() return API.L["Imports the history of TSM Accounting and Journalator."] end,
    order = 70,
    db = {
        sv = "GoblinomicsImportDB",
        version = 1,
        defaults = {},
        charDefaults = {},
    },
})
ns.Import = Import

--- Readers in import order (TSM first: the longer history, Journalator adds to it).
Import.ORDER = { "tsm", "journalator" }

local function Reader(id) return id == "tsm" and ns.TSM or id == "journalator" and ns.Journalator or nil end
Import.Reader = Reader

function Import:OnInit()
    if type(self.db.root.imports) ~= "table" then self.db.root.imports = {} end
end

--- Own characters by lower-case name per realm key: set["name-realm"] = charKey.
function Import.OwnCharacters()
    local set = {}
    for _, key in ipairs(API.KnownCharacters()) do set[key:lower()] = key end
    return set
end

--- Own character keys by lower-case name alone (region-wide unique names).
function Import.OwnByName()
    local set = {}
    for _, key in ipairs(API.KnownCharacters()) do set[(key:match("^([^%-]+)") or key):lower()] = key end
    return set
end

--- Goblinomics key of a character named by another addon. With region-wide unique
-- names (WoW: Forever) the realm is a shard name without identity: match by name
-- (byName from Import.OwnByName) and fall back to the current realm key.
function Import.CharKey(name, realm, byName)
    if API.RegionalNames() then
        local short = name:match("^([^%-]+)") or name
        return (byName or Import.OwnByName())[short:lower()] or (short .. "-" .. API.RealmKey())
    end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. Import.Realm(realm)
end

--- Normalised realm ("Burning Legion" -> "BurningLegion", faction suffix dropped).
function Import.Realm(realm)
    realm = (realm or ""):gsub("%s*%-%s*%a+$", "")
    return (realm:gsub("[%s%-']", ""))
end

--- { available, count, from, to, note } of a source.
function Import.Detect(id)
    local reader = Reader(id)
    if not reader or not reader.Available() then return { available = false } end
    return reader.Detect()
end

--- Read a source into a batch; callback(batch) (Journalator decodes in a job).
function Import.Read(id, callback)
    local reader = Reader(id)
    if not reader or not reader.Available() then return callback(nil) end
    reader.Read(callback)
end

--- Preview: counts of new and known bookings; callback(result, batch).
function Import.Preview(id, callback)
    if not API.Ledger or not API.Ledger.Import then return callback(nil) end
    Import.Read(id, function(batch)
        if not batch then return callback(nil) end
        batch.source = id .. ":preview"
        callback(API.Ledger:Import(batch, true), batch)
    end)
end

--- Import a source; callback(result) with the stored import record.
function Import.Run(id, callback)
    if not API.Ledger or not API.Ledger.Import then return callback(nil) end
    Import.Read(id, function(batch)
        if not batch then return callback(nil) end
        local importId = id .. ":" .. time()
        batch.source = importId
        local result = API.Ledger:Import(batch)
        local record = { id = importId, source = id, time = time(), added = result.added, events = result.events,
            duplicates = result.duplicates }
        if result.added > 0 or result.events > 0 then
            table.insert(Import.db.root.imports, 1, record)
        end
        API.Emit("IMPORT_DONE", record)
        callback(result, record)
    end)
end

--- All sources in order; callback(results by id).
function Import.RunAll(callback)
    local results, i = {}, 0
    local function Next()
        i = i + 1
        local id = Import.ORDER[i]
        if not id then return callback(results) end
        if not Import.Detect(id).available then return Next() end
        Import.Run(id, function(result)
            results[id] = result
            Next()
        end)
    end
    Next()
end

--- Undo an import: its bookings and auction events are removed.
function Import.Undo(importId)
    local removed, events = 0, 0
    if API.Ledger and API.Ledger.RemoveImport then removed, events = API.Ledger:RemoveImport(importId) end
    local list = Import.db.root.imports
    for i = #list, 1, -1 do
        if list[i].id == importId then table.remove(list, i) end
    end
    return removed, events
end

function Import.List() return Import.db.root.imports end
