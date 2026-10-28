if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Flips.lua
-- Flips: items bought on the auction house and sold there again. Every purchase
-- (from the Ledger) becomes a candidate lot; posting the same item makes it a
-- flip. Sales, expired and cancelled auctions are matched FIFO against the lots:
-- profit after cut and lost deposits, ROI, sale rate of the flip postings and
-- holding time from purchase to sale. This file registers the module and wires
-- the parts together.
local ADDON_NAME, ns = ...

local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end
ns.API = API
ns.L = API.L

local Flips = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "Flips",
    description = function() return API.L["Items bought on the auction house and resold: profit, sale rate and holding time."] end,
    order = 25,
    db = {
        sv = "GoblinomicsFlipsDB",
        version = 1,
        defaults = {
            candidateDays = 14,   -- purchases that are not posted within this many days are no flip
            retentionDays = 90,   -- closed lots older than this fold into aggregates
            auctionHints = true,  -- cost basis and flip record at the auction house
        },
        charDefaults = {},
    },
})
ns.Flips = Flips

local PARTS = { "Store", "Engine", "Stats", "Retention", "Backfill", "FlipsUI" }

function Flips:OnInit()
    local root = self.db.root
    for _, key in ipairs({ "lots", "aggregates", "ignoredKeys" }) do
        if type(root[key]) ~= "table" then root[key] = {} end
    end
    if type(root.nextId) ~= "number" then root.nextId = 1 end
end

-- Public, read-only: flip statistics for other modules (Insights, Workshop).
API.Flips = {
    --- true while the key has an open flip lot or candidate.
    Claims = function(_, key) return Flips:IsEnabled() and ns.Store and ns.Store.Claims(key) or false end,
    --- Statistics of one item for the last `days` days (nil = all time), or nil.
    ItemStats = function(_, key, days) return ns.Stats and ns.Stats.Item(key, days) end,
    --- Totals over all items: filter = { days, char }.
    Summary = function(_, filter) return ns.Stats and ns.Stats.Summary(filter or {}) end,
    --- Profit per day for the last `days` days: { { day, profit, revenue, cost } }.
    Daily = function(_, days, filter) return ns.Stats and ns.Stats.Daily(days, filter or {}) end,
    --- Open lots of a key (copies), oldest first.
    OpenLots = function(_, key) return ns.Store and ns.Store.OpenLots(key) or {} end,
}

--- Something changed in the lots (UI refresh, debounced by the listeners).
function ns.Changed()
    ns.API.Emit("FLIPS_CHANGED", {})
end

function Flips:OnEnable()
    for _, part in ipairs(PARTS) do
        if ns[part] and ns[part].Enable then ns[part].Enable(self) end
    end
end

function Flips:OnDisable()
    for i = #PARTS, 1, -1 do
        local part = ns[PARTS[i]]
        if part and part.Disable then part.Disable(self) end
    end
end
