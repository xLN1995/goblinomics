if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Workshop.lua
-- Workshop: every craft with the reagents it really used (market price at the
-- time of the craft), quality, concentration and resourcefulness; crafted items
-- as FIFO lots matched against auction house sales and fulfilled crafting
-- orders; concentration value per profession; salvage with its yield; the
-- Workshop tab. This file registers the module and wires the parts together.
local ADDON_NAME, ns = ...

local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end
ns.API = API
ns.L = API.L

local Workshop = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "Workshop",
    description = function() return API.L["Crafts with their real reagent costs and profit per recipe."] end,
    order = 40,
    db = {
        sv = "GoblinomicsWorkshopDB",
        version = 1,
        defaults = {
            retentionDays = 90,       -- raw craft records, then aggregates per recipe
            lotDays = 90,             -- unsold crafted items leave the open stock after this
            concentrationDays = 30,   -- window of the average concentration value
            concentrationThreshold = 1000,   -- notices when concentration reaches this
            notifyToast = true, notifyChat = true, notifyTooltip = true,
            professionsHidden = {},   -- charKey -> true: left out of concentration and cooldowns
            pulseThreshold = 15,      -- warning when the price is this many percent below its 14-day value
            pulseToast = true, pulseChat = true,
        },
        charDefaults = {},
    },
})
ns.Workshop = Workshop

local PARTS = { "Recipes", "Reagents", "Purchases", "CraftTracker", "Lots", "Orders", "Concentration", "Salvage",
    "Disenchant",
    "Stats", "Retention", "Recompute", "Professions", "ProfessionNotices", "Pulse", "PulseNotices", "ProfessionButton",
    "WorkshopSummary", "WorkshopUI", "WorkshopProfessions", "WorkshopPulse" }

function Workshop:OnInit()
    local root = self.db.root
    for _, key in ipairs({ "crafts", "lots", "matches", "orders", "aggregates", "transfers" }) do
        if type(root[key]) ~= "table" then root[key] = {} end
    end
    if type(root.nextId) ~= "number" then root.nextId = 1 end
end

-- Public, read-only: crafting profit for other modules (Insights).
API.Workshop = {
    Breakdown = function(_, filter) return ns.Stats and ns.Stats.Breakdown(filter or {}) end,
    Daily = function(_, days, filter) return ns.Stats and ns.Stats.Daily(days, filter or {}) end,
}

--- New record id (unique per account).
function ns.NextId()
    local root = Workshop.db.root
    local id = root.nextId
    root.nextId = id + 1
    return id
end

function Workshop:OnEnable()
    for _, part in ipairs(PARTS) do
        if ns[part] and ns[part].Enable then ns[part].Enable(self) end
    end
    ns.Recipes.PurgeIgnored(self.db.root)   -- runeforging recorded before it was left out
end

function Workshop:OnDisable()
    for i = #PARTS, 1, -1 do
        local part = ns[PARTS[i]]
        if part and part.Disable then part.Disable(self) end
    end
end
