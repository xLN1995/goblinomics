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
            speculativeMinValue = 10000000,   -- 1000 gold: cheaper items are never speculative
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

local function OnLogin()
    ns.CoreEvents:Unregister("PLAYER_LOGIN")
    local c = ns.coreDB:BindChar(ns.CharKey())
    c.name = UnitName("player")
    c.realm = GetNormalizedRealmName and GetNormalizedRealmName() or c.realm
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
