if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Bootstrap.lua
-- Lifecycle driver, last core file. ADDON_LOADED creates the core namespace,
-- activates the locale and initialises modules; PLAYER_LOGIN binds the character
-- and enables modules and entry points; PLAYER_LOGOUT runs module logout hooks and
-- strips defaults. ADDON_LOADED stays registered for demand-loaded modules.
local ADDON_NAME, ns = ...

local CORE_DB = {
    version = 3,
    migrations = {
        -- schema 2: the Prospector module is called Gatherer
        [2] = function(root)
            local modules = root.settings and root.settings.modules
            if type(modules) == "table" and modules.Goblinomics_Prospector ~= nil then
                modules.Goblinomics_Gatherer = modules.Goblinomics_Prospector
                modules.Goblinomics_Prospector = nil
            end
            for _, c in pairs(type(root.chars) == "table" and root.chars or {}) do
                if type(c) == "table" and c.lastTab == "prospector" then c.lastTab = "gatherer" end
            end
        end,
        -- schema 3: existing installations have been set up already (no automatic wizard)
        [3] = function(root)
            if type(root.setup) ~= "table" then root.setup = { done = true } end
        end,
    },
    defaults = {
        minimap = { hide = false },
        locale = "auto",
        modules = {},
        ui = { scale = 1, markSpeculative = true, dashboardDays = 7 },
        sound = { channel = "Master" },
        pricing = {
            preferred = "tsm",
            tsm = { market = "DBMarket", destroy = "Destroy", saleRate = "DBRegionSaleRate" },
            speculativeThreshold = 0.05,
            -- 1000 gold (10 on WoW: Forever): cheaper items are never speculative
            speculativeMinValue = ns.Flavor.IsForever() and 100000 or 10000000,
        },
    },
    charDefaults = {
        window = {},
    },
}
ns.CORE_DB_SPEC = CORE_DB

local function NewAccountId()
    return ("%08x%06x"):format(time() % 0x100000000, math.random(0, 0xffffff))
end

local function OnCoreLoaded()
    local db = ns.DB:Namespace("Goblinomics", "GoblinomicsDB", CORE_DB)
    ns.coreDB = db
    if type(db.root.account) ~= "table" then
        db.root.account = { id = NewAccountId(), created = time() }
    end
    -- a fresh installation gets the setup wizard at the first login (Setup.lua)
    if type(db.root.setup) ~= "table" then db.root.setup = { pending = true } end
    ns.Locale.Activate(db.settings.locale)
    if ns.EntryPoints and ns.EntryPoints.OnCoreLoaded then
        ns.EntryPoints.OnCoreLoaded()
    end
end

--- Character keys that changed identity, kept in root.charRenames. With region-wide
-- unique names (WoW: Forever) the realm part was an internal shard name up to 1.3.0,
-- until Blizzard emptied the realm name ("Name-"); the name alone identifies the
-- character there, so an older key with the same name is the current character.
local function CollectRenames(root, charKey)
    if type(root.charRenames) ~= "table" then root.charRenames = {} end
    if ns.RegionalNames() then
        local name = UnitName("player")
        for key, c in pairs(root.chars) do
            if key ~= charKey and type(c) == "table" and name and (c.name or key:match("^([^%-]+)")) == name then
                root.charRenames[key] = charKey
            end
        end
    end
    -- a key that is current again must not be renamed away; chains end at the last key
    root.charRenames[charKey] = nil
    for old, new in pairs(root.charRenames) do
        local hops = 0
        while root.charRenames[new] and hops < 10 do new, hops = root.charRenames[new], hops + 1 end
        root.charRenames[old] = new
    end
    if next(root.charRenames) == nil then root.charRenames = nil end
    return root.charRenames
end

local function OnLogin()
    ns.CoreEvents:Unregister("PLAYER_LOGIN")
    local charKey = ns.CharKey()
    ns.DB.RenameChars(CollectRenames(ns.coreDB.root, charKey))
    local c = ns.coreDB:BindChar(charKey)
    c.name = UnitName("player")
    c.realm = ns.RealmKey()
    c.class = select(2, UnitClass("player"))
    c.faction = UnitFactionGroup("player")
    c.lastLogin = time()
    ns.Modules.OnLogin()
    if ns.EntryPoints and ns.EntryPoints.OnLogin then
        ns.EntryPoints.OnLogin()
    end
    if ns.Setup then ns.Setup.OnLogin() end
    if ns.Changelog then ns.Changelog.OnLogin() end
end

local function OnLogout()
    local c = ns.coreDB and ns.coreDB.char
    if c then
        -- GetMoney() reads 0 at logout; keep the tracker's last reliable value.
        local money = ns.MoneyTracker and ns.MoneyTracker.GetPlayer()
        if type(money) == "number" then
            c.money = money
        end
    end
    ns.Modules.OnLogout()
    ns.DB.OnLogout()
end

--- Characters of this account seen by Goblinomics ("Name-Realm").
function ns.API.KnownCharacters()
    local list = {}
    local chars = ns.coreDB and ns.coreDB.root.chars or {}
    for key in pairs(chars) do list[#list + 1] = key end
    table.sort(list)
    return list
end

ns.CoreEvents:Register("ADDON_LOADED", function(_, addonName)
    if addonName == ADDON_NAME then
        OnCoreLoaded()
    end
    ns.Modules.OnAddonLoaded(addonName)
end)
ns.CoreEvents:Register("PLAYER_LOGIN", OnLogin)
ns.CoreEvents:Register("PLAYER_LOGOUT", OnLogout)
