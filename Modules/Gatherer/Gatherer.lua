if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Gatherer.lua
-- Gatherer: farms, the session tracker (items, raw gold, prorated repair,
-- estimated and realized value), highlights, the compact HUD, the detailed tab
-- per farm, lockouts and farm/watchlist strings. This file registers the module
-- and wires the parts together; the other files share the namespace.
local ADDON_NAME, ns = ...

local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end
ns.API = API
ns.L = API.L

local Gatherer = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "Gatherer",
    description = function() return API.L["Farm sessions with HUD, loot highlights and lockouts."] end,
    order = 30,
    db = {
        sv = "GoblinomicsGathererDB",
        version = 4,
        migrations = {
            -- schema 2: the Mythic+ category was removed; such farms become dungeons
            [2] = function(root)
                for _, farm in pairs(type(root.farms) == "table" and root.farms or {}) do
                    if type(farm) == "table" and farm.category == "mythicplus" then farm.category = "dungeon" end
                end
            end,
            -- schema 3: expected items and the farm watchlist merge into expected highlights
            [3] = function(root)
                for _, farm in pairs(type(root.farms) == "table" and root.farms or {}) do
                    if type(farm) == "table" then
                        local list = {}
                        for _, key in ipairs(type(farm.expectedItems) == "table" and farm.expectedItems or {}) do
                            if not tContains(list, key) then list[#list + 1] = key end
                        end
                        local extra = {}
                        for key in pairs(type(farm.watchlist) == "table" and farm.watchlist or {}) do
                            if not tContains(list, key) then extra[#extra + 1] = key end
                        end
                        table.sort(extra)
                        for _, key in ipairs(extra) do list[#list + 1] = key end
                        farm.expectedHighlights = list
                        farm.expectedItems, farm.watchlist = nil, nil
                    end
                end
            end,
            -- schema 4: no expected GPH and duration; the instance becomes a record
            [4] = function(root)
                for _, farm in pairs(type(root.farms) == "table" and root.farms or {}) do
                    if type(farm) == "table" then
                        farm.expectedGPH, farm.expectedMinutes = nil, nil
                        local isInstance = farm.category == "dungeon" or farm.category == "raid"
                        if type(farm.instance) == "string" and isInstance then
                            farm.instance = { name = farm.instance, isRaid = farm.category == "raid" }
                        elseif type(farm.instance) ~= "table" then
                            farm.instance = nil
                        end
                    end
                end
            end,
        },
        defaults = {
            highlightThreshold = 2500,   -- gold
            highlightSound = "kit:UI_EPICLOOT_TOAST",
            specialSound = "kit:UI_LEGENDARY_LOOT_TOAST",   -- mounts and legendary items
            autoPauseMinutes = 0,        -- 0 = off
            hudLocked = false,
            farmHudAuto = false,         -- full-screen HUD shown by itself for farms with a route
            farmHudSide = "left",        -- its side panel: "left" or "right"
        },
        charDefaults = {},
    },
})
ns.Gatherer = Gatherer

-- No Mythic+ category: keys drop loot only at the end, they are never farm runs.
-- Public, read-only: stored session summaries since a time (Insights).
API.Gatherer = {
    -- key bindings: the full-screen farm HUD and its skip key
    ToggleFarmHUD = function()
        if ns.FarmHUD and not ns.FarmHUD.ToggleWithHint() and ns.Commands then ns.Commands.Run("hud") end
    end,
    SkipStop = function() if ns.FarmHUD then ns.FarmHUD.Skip() end end,
    Summaries = function(_, from)
        local list = {}
        local root = Gatherer.db and Gatherer.db.root
        for _, summaries in pairs(root and root.history or {}) do
            for _, s in ipairs(summaries) do
                if not from or (s.started or 0) >= from then list[#list + 1] = s end
            end
        end
        table.sort(list, function(a, b) return (a.started or 0) > (b.started or 0) end)
        return list
    end,
}

ns.CATEGORIES = { "gathering", "fishing", "openworld", "dungeon", "raid", "other" }

--- Localised name of a farm category id.
function ns.CategoryName(category)
    local L = ns.L
    if category == "gathering" then return L["Gathering"] end
    if category == "fishing" then return L["Fishing"] end
    if category == "openworld" then return L["Open World"] end
    if category == "dungeon" then return L["Dungeon"] end
    if category == "raid" then return L["Raid"] end
    return L["Other"]
end

--- Instance farms have a lockout.
function ns.IsInstanceCategory(category)
    return category == "dungeon" or category == "raid"
end

local PARTS = { "Farms", "Session", "NodeTracker", "Highlights", "Lockouts", "Strings", "HUD", "FarmHUD", "Commands",
    "GathererUI", "RouteView" }

function Gatherer:OnInit()
    local root = self.db.root
    for _, key in ipairs({ "farms", "history", "watchlist" }) do
        if type(root[key]) ~= "table" then root[key] = {} end
    end
    if type(root.nextFarmId) ~= "number" then root.nextFarmId = 1 end
end

function Gatherer:OnEnable()
    for _, part in ipairs(PARTS) do
        if ns[part] and ns[part].Enable then ns[part].Enable(self) end
    end
end

function Gatherer:OnDisable()
    for i = #PARTS, 1, -1 do
        local part = ns[PARTS[i]]
        if part and part.Disable then part.Disable(self) end
    end
end

function Gatherer:OnLogout()
    if ns.Session and ns.Session.OnLogout then ns.Session.OnLogout() end
end
