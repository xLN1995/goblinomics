if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/ProfessionNotices.lua
-- Notices for concentration and recipe cooldowns of every character, each one
-- switchable in the settings:
--   toast    while you play, when a character's concentration reaches the
--            threshold or a cooldown is ready; one timer for the next due entry
--   login    the overview window (ProfessionPopup) when something is full or ready
--   tooltip  a line in the minimap / LDB tooltip: how many are due, the next one
-- An entry is toasted once per due time (root.professionNotices[id] = at).
local _, ns = ...

local Notices = {}
ns.ProfessionNotices = Notices

local OWNER = "Goblinomics_Workshop.Notices"
local module
local generation = 0

local function Settings() return module.db.settings end

local function Root()
    local root = module.db.root
    if type(root.professionNotices) ~= "table" then root.professionNotices = {} end
    return root
end

local function Label(d)
    local L = ns.L
    local what = d.label or (d.kind == "cooldown" and L["Cooldown"] or L["Concentration"])
    return ("%s (%s)"):format(d.name, what)
end

--- Entries due at or before now that were not toasted for this due time yet.
function Notices.Pending(root, settings, now)
    local out = {}
    local seen = root.professionNotices or {}
    for _, d in ipairs(ns.Professions.Due(root, settings, now)) do
        if d.at <= now and seen[d.id] ~= d.at then out[#out + 1] = d end
    end
    return out
end

local function Toast(d)
    local API, L = ns.API, ns.L
    local text = d.kind == "cooldown" and API.Lf("%s is ready", Label(d)) or API.Lf("%s is full", Label(d))
    API.UI:Toast({ title = L["Concentration & cooldowns"], text = text, icon = d.icon })
end

--- Toast what became due, then wait for the next entry (one timer).
function Notices.Check()
    if not module then return end
    local root, settings, now = Root(), Settings(), time()
    for _, d in ipairs(Notices.Pending(root, settings, now)) do
        if settings.notifyToast then Toast(d) end
        root.professionNotices[d.id] = d.at
    end
    Notices.Schedule()
end

function Notices.Schedule()
    if not module then return end
    generation = generation + 1
    local mine = generation
    local now = time()
    local nextAt
    for _, d in ipairs(ns.Professions.Due(Root(), Settings(), now)) do
        if d.at > now then nextAt = d.at break end
    end
    if not nextAt then return end
    module:After(math.max(1, nextAt - now), function()
        if mine == generation then Notices.Check() end
    end)
end

--- Is anything full or ready at time now?
function Notices.HasReady(root, settings, now)
    for _, d in ipairs(ns.Professions.Due(root, settings, now)) do
        if d.at <= now then return true end
    end
    return false
end

local function OnLogin()
    local root, settings, now = Root(), Settings(), time()
    if settings.notifyChat and Notices.HasReady(root, settings, now) then ns.ProfessionPopup.Open() end
    -- what is due already is shown in the overview; toasts are for what becomes due later
    for _, d in ipairs(Notices.Pending(root, settings, now)) do root.professionNotices[d.id] = d.at end
    Notices.Schedule()
end

--- Tooltip line: "Concentration & cooldowns: 2 ready, next in 3h 12m".
function Notices.TooltipText(root, settings, now)
    local API, L = ns.API, ns.L
    local due, nextAt = 0, nil
    for _, d in ipairs(ns.Professions.Due(root, settings, now)) do
        if d.at <= now then due = due + 1 elseif not nextAt then nextAt = d.at end
    end
    if due == 0 and not nextAt then return nil end
    local parts = {}
    if due > 0 then parts[#parts + 1] = API.Lf("%d ready", due) end
    if nextAt then parts[#parts + 1] = API.Lf("next in %s", API.Format:Remaining(nextAt - now)) end
    return L["Concentration & cooldowns"], table.concat(parts, ", ")
end

function Notices.Enable(m)
    module = m
    local API = ns.API
    API.On("WORKSHOP_PROFESSIONS", Notices.Schedule, OWNER)
    API.UI:RegisterTooltipProvider("workshop.professions", function(tt)
        if not Settings().notifyTooltip then return end
        local left, right = Notices.TooltipText(Root(), Settings(), time())
        if not left then return end
        tt:AddLine(" ")
        tt:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
    end)
    m:After(6, OnLogin)   -- after the stored currencies were read at login
end

function Notices.Disable()
    generation = generation + 1
    if ns.API then ns.API.Off("WORKSHOP_PROFESSIONS", OWNER) end
end
