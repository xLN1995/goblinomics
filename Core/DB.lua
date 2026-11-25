if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/DB.lua
-- SavedVariables namespaces with defaults, schema versions and migrations.
--
-- Layout of every namespace root:
--   { _schema = n, settings = {...}, chars = { ["Name-Realm"] = {...} }, <free keys> }
-- settings and chars[*] get their defaults merged at load and stripped (from a
-- copy) at logout. Migrations migrations[n](root) upgrade to schema n; each runs
-- in pcall, a failure stops at the last good version, goes to the error handler
-- and marks the namespace as not ok (its module stays disabled this session).
-- A fresh SavedVariable starts at the current version without migrations.
local _, ns = ...

local DB = {}
ns.DB = DB
ns.API.DB = DB

local namespaces = {}

local function DeepMerge(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then
                target[k] = {}
            end
            DeepMerge(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end
DB.DeepMerge = DeepMerge

local function DeepCopy(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = type(v) == "table" and DeepCopy(v) or v
    end
    return copy
end
DB.DeepCopy = DeepCopy

local function Strip(t, defaults)
    for k, v in pairs(defaults) do
        local current = t[k]
        if type(v) == "table" then
            if type(current) == "table" then
                Strip(current, v)
                if next(current) == nil then
                    t[k] = nil
                end
            end
        elseif current == v then
            t[k] = nil
        end
    end
end
DB.Strip = Strip

local Namespace = {}
Namespace.__index = Namespace

-- Character key renames { [old] = new } (set by the core at PLAYER_LOGIN, kept in
-- GoblinomicsDB.charRenames). Applied once per namespace (root._renamed): every
-- string value equal to old and every table key equal to old becomes new, so
-- chars[old], record fields (char, seenBy), per-character settings and the ledger
-- charIndex all follow. Where both keys exist, tables merge (new wins).
local renames = {}

local function RenameIn(t, old, new, seen)
    if seen[t] then return end
    seen[t] = true
    local moved
    for k, v in pairs(t) do
        if v == old then
            t[k] = new
        elseif type(v) == "table" and k ~= "_renamed" and k ~= "charRenames" then
            RenameIn(v, old, new, seen)
        end
        if k == old then moved = true end
    end
    if moved then
        local from, into = t[old], t[new]
        if type(from) == "table" and type(into) == "table" then
            DeepMerge(into, from)
        elseif into == nil then
            t[new] = from
        end
        t[old] = nil
    end
end
DB.RenameIn = function(t, old, new) RenameIn(t, old, new, {}) end

local function ApplyRenames(db)
    local root = db.root
    for old, new in pairs(renames) do
        if type(root._renamed) ~= "table" or not root._renamed[old] then
            RenameIn(root, old, new, {})
            if type(root._renamed) ~= "table" then root._renamed = {} end
            root._renamed[old] = new
        end
    end
end

--- Rename character keys in every namespace, now and when created later.
function DB.RenameChars(map)
    for old, new in pairs(map or {}) do
        if old ~= new then renames[old] = new end
    end
    for i = 1, #namespaces do
        if namespaces[i].ok then ApplyRenames(namespaces[i]) end
    end
end

--- Create (or return) the namespace bound to the SavedVariable svName.
-- Call at the owning addon's ADDON_LOADED. spec = { defaults, charDefaults, version, migrations }
function DB:Namespace(id, svName, spec)
    for i = 1, #namespaces do
        if namespaces[i].svName == svName then
            return namespaces[i]
        end
    end
    spec = spec or {}
    local version = spec.version or 1
    local root = _G[svName]
    local fresh = type(root) ~= "table"
    if fresh then
        root = {}
        _G[svName] = root
        root._schema = version
    end

    local db = setmetatable({ id = id, svName = svName, root = root, spec = spec, ok = true }, Namespace)
    local current = root._schema or 1
    if current > version then
        db.ok = false
        db.error = ("saved data has schema %d, this version understands %d"):format(current, version)
    else
        for n = current + 1, version do
            local migrate = spec.migrations and spec.migrations[n]
            if migrate then
                local ok, err = pcall(migrate, root)
                if not ok then
                    db.ok = false
                    db.error = ("migration to schema %d failed: %s"):format(n, tostring(err))
                    ns.errorhandler("Goblinomics " .. id .. ": " .. db.error)
                    break
                end
            end
            root._schema = n
        end
    end

    if type(root.settings) ~= "table" then root.settings = {} end
    if type(root.chars) ~= "table" then root.chars = {} end
    DeepMerge(root.settings, spec.defaults or {})
    db.settings = root.settings
    namespaces[#namespaces + 1] = db
    if db.ok then ApplyRenames(db) end
    return db
end

--- Bind db.char to the current character's table (from PLAYER_LOGIN on).
function Namespace:BindChar(charKey)
    local chars = self.root.chars
    local c = chars[charKey]
    if type(c) ~= "table" then
        c = {}
        chars[charKey] = c
    end
    DeepMerge(c, self.spec.charDefaults or {})
    self.char = c
    self.charKey = charKey
    return c
end

--- Strip defaults from copies of settings and every char table (PLAYER_LOGOUT).
function DB.OnLogout()
    for i = 1, #namespaces do
        local db = namespaces[i]
        local root, spec = db.root, db.spec
        if spec.defaults then
            local copy = DeepCopy(root.settings)
            Strip(copy, spec.defaults)
            root.settings = copy
        end
        if spec.charDefaults then
            for key, c in pairs(root.chars) do
                if type(c) == "table" then
                    local copy = DeepCopy(c)
                    Strip(copy, spec.charDefaults)
                    root.chars[key] = copy
                end
            end
        end
    end
end

function DB.List()
    return namespaces
end
