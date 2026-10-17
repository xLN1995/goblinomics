if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Professions.lua
-- Concentration and recipe cooldowns of every character, computed instead of polled.
--   concentration  read once (profession window, CURRENCY_DISPLAY_UPDATE, login) as
--                  { amount, max, cycleSec, perCycle, readAt }; the current value and
--                  the time it reaches the threshold follow from the recharge rate.
--                  Every expansion line with concentration is kept with its
--                  expansion; views and notices show the chosen one (Midnight by default).
--                  The currency of a profession line is only known once its window
--                  was open; after that the login reads it without a window.
--   cooldowns      recipes with a daily cooldown or charges, found when the
--                  profession window opens and after a craft; stored with the time
--                  they are ready (readyAt) and, for charges, when they are full.
--   known          the learned recipes per base profession (every expansion), taken
--                  from the same scan of the open window and kept up to date by
--                  NEW_RECIPE_LEARNED: { [baseProfessionID] = { recipes = { id, ... }, scannedAt } }.
-- Only the player's own profession window counts: a linked profession, a guild
-- recipe list or NPC crafting would otherwise land on this character.
-- Stored per character in the Workshop's character table (professions, cooldowns, known).
-- Idle cost: the events below and nothing else; notices plan their own timer.
local _, ns = ...

local Professions = {}
ns.Professions = Professions

local API = ns.API
local module
local scanning = false

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function Now() return GetServerTime and GetServerTime() or time() end

-- Current expansion ------------------------------------------------------------------
--- Localized name of the expansion whose concentration counts (Midnight), or nil.
local function CurrentExpansionName()
    local level = Enum and Enum.ExpansionLevel and Enum.ExpansionLevel.Midnight
    return level and _G["EXPANSION_NAME" .. level] or nil
end

--- Expansion of a stored cooldown; filled in from the recipe when an older entry lacks it.
local function CooldownExpansion(recipeID, cd)
    if not cd.expansion and C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoByRecipeID then
        local prof = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
        if prof and prof.expansionName then cd.expansion = prof.expansionName end
    end
    return cd.expansion
end

-- Professions name their expansion lines after the region ("Khaz Algar", "Dragon
-- Isles", "Pandaria"), not after the expansion. Their order comes from the game: the
-- child lines of a profession window, stored oldest first in root.expansionOrder.

--- Store the expansion order of a profession window's child lines (oldest first).
-- The window opens on the newest line; that tells the direction of the list.
function Professions.LearnOrder(root, children, openLine)
    local names = {}
    local openIndex
    for _, info in ipairs(children or {}) do
        if info.expansionName then names[#names + 1] = info.expansionName end
        if openLine and info.professionID == openLine then openIndex = #names end
    end
    if #names < 2 then return end
    local current = CurrentExpansionName()
    local newestFirst = openIndex == 1
    for i, name in ipairs(names) do
        if current and name == current then newestFirst = i == 1 end
    end
    if newestFirst then
        local reversed = {}
        for i = #names, 1, -1 do reversed[#reversed + 1] = names[i] end
        names = reversed
    end
    if #names >= #(root.expansionOrder or {}) then root.expansionOrder = names end
end

--- Order of an expansion name (newest highest); unknown names last.
local function ExpansionLevel(root, name)
    for i, n in ipairs(root and root.expansionOrder or {}) do
        if n == name then return 100 + i end
    end
    for level = 30, 0, -1 do
        if _G["EXPANSION_NAME" .. level] == name then return level end
    end
    return -1
end

--- The current expansion as professions name it: the newest learned line, else the client's name.
function Professions.CurrentExpansion(root)
    local order = root and root.expansionOrder
    if order and #order > 0 then return order[#order] end
    return CurrentExpansionName()
end

--- The expansion filter for concentration and cooldowns: nil / "current" means the
-- current expansion, "all" everything, otherwise an expansion name.
function Professions.ExpansionFilter(settings, root)
    local value = settings and settings.professionsExpansion
    if value == nil or value == "current" then return Professions.CurrentExpansion(root) or "all" end
    return value
end

--- Expansions to choose from, newest first: the order the profession windows showed,
-- plus names of stored entries; before any window was open the client's names.
function Professions.Expansions(root)
    local seen, list = {}, {}
    local function Add(name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    for _, name in ipairs(root and root.expansionOrder or {}) do Add(name) end
    for _, c in pairs(root and root.chars or {}) do
        if type(c) == "table" then
            for recipeID, cd in pairs(c.cooldowns or {}) do Add(CooldownExpansion(recipeID, cd)) end
            for _, p in pairs(c.professions or {}) do Add(p.expansion) end
        end
    end
    if #list == 0 then
        -- the client also names coming expansions ("Expansion 12"): only up to the current one
        local current = GetServerExpansionLevel and GetServerExpansionLevel()
            or (Enum and Enum.ExpansionLevel and Enum.ExpansionLevel.Midnight) or 30
        for level = 0, current do Add(_G["EXPANSION_NAME" .. level]) end
    end
    table.sort(list, function(a, b)
        local x, y = ExpansionLevel(root, a), ExpansionLevel(root, b)
        if x ~= y then return x > y end
        return a < b
    end)
    return list
end

--- Expansion of a profession line; lines stored before it was kept belong to the current one.
function Professions.LineExpansion(p, root)
    return p.expansion or Professions.CurrentExpansion(root)
end

-- Pure computation --------------------------------------------------------------------
--- Concentration at time now from a stored reading.
function Professions.Current(p, now)
    if not p or not p.amount then return nil end
    local max = p.max or 1000
    if not p.cycleSec or p.cycleSec <= 0 then return math.min(max, p.amount) end
    local cycles = math.floor(math.max(0, (now or Now()) - (p.readAt or 0)) / p.cycleSec)
    return math.min(max, p.amount + cycles * (p.perCycle or 1))
end

--- Time the stored reading reaches threshold (default: max); readAt when it already has.
function Professions.FullAt(p, threshold)
    if not p or not p.amount then return nil end
    local target = math.min(threshold or p.max or 1000, p.max or 1000)
    if p.amount >= target then return p.readAt end
    if not p.cycleSec or p.cycleSec <= 0 then return nil end
    return p.readAt + math.ceil((target - p.amount) / (p.perCycle or 1)) * p.cycleSec
end

--- Charges of a stored cooldown at time now, the time the next charge (or the
-- daily cooldown) is ready and the time all charges are back.
function Professions.CooldownState(cd, now)
    now = now or Now()
    if not cd.maxCharges or cd.maxCharges <= 1 then
        return (cd.readyAt or 0) <= now and 1 or 0, cd.readyAt, cd.readyAt
    end
    local max, charges, nextAt, per = cd.maxCharges, cd.charges or 0, cd.readyAt, cd.perCharge or 0
    if charges >= max or not nextAt then return max, nil, nil end
    local fullAt = nextAt + (max - charges - 1) * per
    if now >= nextAt then
        local gained = per > 0 and (1 + math.floor((now - nextAt) / per)) or (max - charges)
        charges = math.min(max, charges + gained)
        nextAt = charges < max and (nextAt + gained * per) or nil
    end
    return charges, nextAt, fullAt
end

-- Reading -----------------------------------------------------------------------------
local function Char() return module and module.db.char end

--- Read the currency of one stored profession line; true when it changed.
local function ReadCurrency(p)
    if not (p.currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return false end
    local info = C_CurrencyInfo.GetCurrencyInfo(p.currencyID)
    if not info or IsSecret(info.quantity) or type(info.quantity) ~= "number" then return false end
    p.amount = info.quantity
    p.max = (info.maxQuantity and info.maxQuantity > 0) and info.maxQuantity or 1000
    local ms = info.rechargingCycleDurationMS
    p.cycleSec = (type(ms) == "number" and ms > 0) and ms / 1000 or p.cycleSec
    local per = info.rechargingAmountPerCycle
    p.perCycle = (type(per) == "number" and per > 0) and per or (p.perCycle or 1)
    p.readAt = Now()
    return true
end

local function Changed()
    API.Emit("WORKSHOP_PROFESSIONS", {})
end

--- The open window shows the player's own profession and its data is ready (Blizzard's
-- local crafting mode: not NPC crafting, not a guild or linked list; no runeforging).
function Professions.IsOwnWindow()
    local ts = C_TradeSkillUI
    if not ts then return false end
    local function Is(name) return ts[name] ~= nil and ts[name]() == true end
    if ts.IsTradeSkillReady and not ts.IsTradeSkillReady() then return false end
    return not (Is("IsDataSourceChanging") or Is("IsNPCCrafting") or Is("IsRuneforging")
        or Is("IsTradeSkillLinked") or Is("IsTradeSkillGuild") or Is("IsTradeSkillGuildMember"))
end

--- Base profession (e.g. 171 Alchemy) of the open window, or nil.
local function OpenBaseProfession()
    local ts = C_TradeSkillUI
    local info = ts and ts.GetBaseProfessionInfo and ts.GetBaseProfessionInfo()
    return info and info.professionID or nil
end

--- Profession lines of the current expansion from the open profession window.
function Professions.ReadWindow()
    local c = Char()
    local ts = C_TradeSkillUI
    if not c or not ts or not ts.GetChildProfessionInfos or not ts.GetConcentrationCurrencyID then return end
    c.professions = c.professions or {}
    local changed = false
    local children = ts.GetChildProfessionInfos() or {}
    Professions.LearnOrder(module.db.root, children, ts.GetProfessionChildSkillLineID and ts.GetProfessionChildSkillLineID())
    for _, info in ipairs(children) do
        local id = info.professionID
        local runeforging = id == ns.Recipes.RUNEFORGING or info.parentProfessionID == ns.Recipes.RUNEFORGING
        if id and not runeforging then
            local currencyID = ts.GetConcentrationCurrencyID(id)
            if currencyID and currencyID ~= 0 then
                local p = c.professions[id] or {}
                p.name = info.parentProfessionName or info.professionName
                p.expansion = info.expansionName or p.expansion
                p.currencyID = currencyID
                p.icon = ts.GetTradeSkillTexture and ts.GetTradeSkillTexture(info.parentProfessionID or id) or p.icon
                c.professions[id] = p
                if ReadCurrency(p) then changed = true end
            end
        end
    end
    if changed then Changed() end
end

--- Every stored currency of this character, without a window (login).
function Professions.ReadStored()
    local c = Char()
    if not c or type(c.professions) ~= "table" then return end
    local changed = false
    for _, p in pairs(c.professions) do
        if ReadCurrency(p) then changed = true end
    end
    if changed then Changed() end
end

local function OnCurrency(_, currencyID)
    local c = Char()
    if not c or type(c.professions) ~= "table" then return end
    for _, p in pairs(c.professions) do
        if p.currencyID == currencyID and ReadCurrency(p) then Changed() return end
    end
end

-- Cooldowns ---------------------------------------------------------------------------
local function CooldownsSecret()
    return C_Secrets and C_Secrets.ShouldCooldownsBeSecret and C_Secrets.ShouldCooldownsBeSecret() == true
end

--- Read one recipe's cooldown into the character's list; true when it has one.
function Professions.ReadCooldown(recipeID)
    local c = Char()
    local ts = C_TradeSkillUI
    if not c or not ts or not ts.GetRecipeCooldown or CooldownsSecret() or ns.Recipes.IsIgnored(recipeID) then return false end
    local cd, isDay, charges, maxCharges = ts.GetRecipeCooldown(recipeID)
    if IsSecret(cd) or IsSecret(charges) then return false end
    cd, charges, maxCharges = cd or 0, charges or 0, maxCharges or 0
    local entry = c.cooldowns and c.cooldowns[recipeID]
    if not (isDay or maxCharges > 0 or cd > 0) then
        -- ready again: keep known cooldown recipes, their time has passed
        if entry then entry.readyAt, entry.charges = Now(), entry.maxCharges end
        return entry ~= nil
    end
    c.cooldowns = c.cooldowns or {}
    entry = entry or {}
    local info = ts.GetRecipeInfo and ts.GetRecipeInfo(recipeID)
    entry.name = info and info.name or entry.name
    entry.icon = info and info.icon or entry.icon
    local prof = ts.GetProfessionInfoByRecipeID and ts.GetProfessionInfoByRecipeID(recipeID)
    if prof then
        entry.expansion = prof.expansionName or entry.expansion
        entry.profession = prof.parentProfessionName or prof.professionName or entry.profession
    end
    entry.isDay = isDay and true or nil
    entry.maxCharges = maxCharges > 1 and maxCharges or nil
    entry.charges = maxCharges > 1 and charges or nil
    if maxCharges > 1 and C_Spell and C_Spell.GetSpellCharges then
        local sc = C_Spell.GetSpellCharges(recipeID)
        if sc and type(sc.cooldownDuration) == "number" and not IsSecret(sc.cooldownDuration) then
            entry.perCharge = sc.cooldownDuration
        end
    end
    entry.readyAt = Now() + cd
    c.cooldowns[recipeID] = entry
    return true
end

--- Refresh the known cooldown recipes of this character (login, after crafts).
function Professions.ReadStoredCooldowns()
    local c = Char()
    if not c or type(c.cooldowns) ~= "table" then return end
    for recipeID in pairs(c.cooldowns) do Professions.ReadCooldown(recipeID) end
    Changed()
end

--- Look through the recipes of the open profession (every expansion): keep the learned
-- ones per base profession and read their cooldowns (a job).
function Professions.ScanRecipes()
    local ts = C_TradeSkillUI
    if scanning or not module or not ts or not ts.GetAllRecipeIDs then return end
    local base = OpenBaseProfession()
    scanning = true
    module:RunJob("recipeScan", function()
        local found, learned = false, {}
        for i, recipeID in ipairs(ts.GetAllRecipeIDs() or {}) do
            local info = ts.GetRecipeInfo and ts.GetRecipeInfo(recipeID)
            if info and info.learned == true and not info.isDummyRecipe then learned[#learned + 1] = recipeID end
            if info and info.learned ~= false and Professions.ReadCooldown(recipeID) then found = true end
            if i % 50 == 0 then API.Yield() end
        end
        scanning = false
        local c = Char()
        -- an empty list right after opening is no answer; keep what is known
        if c and base and #learned > 0 then
            table.sort(learned)
            c.known = c.known or {}
            c.known[base] = { recipes = learned, scannedAt = Now() }
        end
        if found then Changed() end
    end)
end

--- A recipe just learned: add it to its base profession's list.
local function OnRecipeLearned(_, recipeID)
    local c = Char()
    local ts = C_TradeSkillUI
    if not c or IsSecret(recipeID) or type(recipeID) ~= "number" or not (ts and ts.GetProfessionInfoByRecipeID) then return end
    local prof = ts.GetProfessionInfoByRecipeID(recipeID)
    local base = prof and (prof.parentProfessionID or prof.professionID)
    if not base then return end
    c.known = c.known or {}
    local entry = c.known[base] or { recipes = {} }
    for _, id in ipairs(entry.recipes) do
        if id == recipeID then return end
    end
    entry.recipes[#entry.recipes + 1] = recipeID
    table.sort(entry.recipes)
    c.known[base] = entry
end

-- Overview over all characters ------------------------------------------------------------
--- Characters with at least one profession line or cooldown, sorted by the time
-- their first entry is due. { { key, name, class, professions = { { id, name, icon,
-- current, max, fullAt, readAt } }, cooldowns = { { recipeID, name, icon, charges,
-- maxCharges, readyAt, fullAt, count } }, dueAt } }. Shared cooldowns (same ready
-- time, e.g. transmutes) are merged into one entry with count > 1.
function Professions.Overview(root, settings, now)
    now = now or Now()
    settings = settings or {}
    local threshold = settings.concentrationThreshold or 1000
    local hidden = settings.professionsHidden or {}
    local list = {}
    for charKey, c in pairs(root.chars or {}) do
        if type(c) == "table" and not hidden[charKey] and (next(c.professions or {}) or next(c.cooldowns or {})) then
            local e = { key = charKey, name = c.name or charKey:match("^([^%-]+)") or charKey, class = c.class,
                professions = {}, cooldowns = {} }
            local expansion = Professions.ExpansionFilter(settings, root)
            for id, p in pairs(c.professions or {}) do
              -- lines stored before the expansion was kept belong to the current expansion
              if expansion == "all" or Professions.LineExpansion(p, root) == expansion then
                e.professions[#e.professions + 1] = { id = id, name = p.name, icon = p.icon,
                    expansion = Professions.LineExpansion(p, root), cycleSec = p.cycleSec, perCycle = p.perCycle or 1,
                    current = Professions.Current(p, now), max = p.max or 1000, readAt = p.readAt,
                    fullAt = Professions.FullAt(p, threshold) }
              end
            end
            table.sort(e.professions, function(a, b) return (a.name or "") < (b.name or "") end)
            local groups = {}
            for recipeID, cd in pairs(c.cooldowns or {}) do
              if expansion == "all" or CooldownExpansion(recipeID, cd) == expansion then
                local charges, readyAt, fullAt = Professions.CooldownState(cd, now)
                local group = not cd.maxCharges and readyAt and ((cd.expansion or "") .. ":" .. math.floor(readyAt / 5)) or nil
                local merged = group and groups[group]
                if merged then
                    merged.count = merged.count + 1
                    if (cd.name or "") < (merged.name or "") then merged.name, merged.icon = cd.name, cd.icon end
                else
                    local entry = { recipeID = recipeID, name = cd.name, icon = cd.icon, charges = charges,
                        maxCharges = cd.maxCharges, readyAt = readyAt, fullAt = fullAt, count = 1,
                        expansion = cd.expansion, profession = cd.profession }
                    e.cooldowns[#e.cooldowns + 1] = entry
                    if group then groups[group] = entry end
                end
              end
            end
            table.sort(e.cooldowns, function(a, b)
                if (a.readyAt or 0) ~= (b.readyAt or 0) then return (a.readyAt or 0) < (b.readyAt or 0) end
                return (a.name or "") < (b.name or "")
            end)
            for _, p in ipairs(e.professions) do
                if p.fullAt and (not e.dueAt or p.fullAt < e.dueAt) then e.dueAt = p.fullAt end
            end
            for _, cd in ipairs(e.cooldowns) do
                if cd.readyAt and (not e.dueAt or cd.readyAt < e.dueAt) then e.dueAt = cd.readyAt end
            end
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b)
        if (a.dueAt or math.huge) ~= (b.dueAt or math.huge) then return (a.dueAt or math.huge) < (b.dueAt or math.huge) end
        return a.name < b.name
    end)
    return list
end

--- Due entries over all characters, earliest first: { { char, name, class, kind =
-- "concentration"|"cooldown", label, icon, at } } (at <= now: already full / ready).
function Professions.Due(root, settings, now)
    local out = {}
    for _, e in ipairs(Professions.Overview(root, settings, now)) do
        for _, p in ipairs(e.professions) do
            if p.fullAt then
                out[#out + 1] = { char = e.key, name = e.name, class = e.class, kind = "concentration",
                    label = p.name, icon = p.icon, at = p.fullAt, id = "c:" .. e.key .. ":" .. p.id }
            end
        end
        for _, cd in ipairs(e.cooldowns) do
            if cd.readyAt then
                out[#out + 1] = { char = e.key, name = e.name, class = e.class, kind = "cooldown",
                    label = cd.name, icon = cd.icon, at = cd.readyAt, count = cd.count,
                    id = "r:" .. e.key .. ":" .. cd.recipeID }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id
    end)
    return out
end

-- Events ------------------------------------------------------------------------------------
-- The window fires TRADE_SKILL_LIST_UPDATE often: read once per opening and base
-- profession (the recipe list already covers every expansion line).
local pendingRead, scannedProfessions = false, {}
local function OnTradeSkill()
    if pendingRead then return end
    pendingRead = true
    module:After(0.5, function()
        pendingRead = false
        if ns.ProfessionButton then ns.ProfessionButton.Attach() end
        if not Professions.IsOwnWindow() then return end  -- not ready yet: the next update comes
        Professions.ReadWindow()
        local base = OpenBaseProfession() or 0
        if not scannedProfessions[base] then
            scannedProfessions[base] = true
            Professions.ScanRecipes()
        end
    end)
end

local function OnTradeSkillClose()
    for k in pairs(scannedProfessions) do scannedProfessions[k] = nil end
end

-- After a craft (the tracker's record) the recipe may have a new cooldown.
local function OnCrafted(record)
    local recipeID = type(record) == "table" and record.recipe
    if recipeID then
        module:After(1, function()
            if Professions.ReadCooldown(recipeID) then Changed() end
        end)
    end
end

function Professions.Enable(m)
    module = m
    local c = m.db.char
    c.name = UnitName and UnitName("player") or c.name
    c.class = UnitClass and select(2, UnitClass("player")) or c.class
    m:RegisterEvent("TRADE_SKILL_SHOW", OnTradeSkill)
    m:RegisterEvent("TRADE_SKILL_LIST_UPDATE", OnTradeSkill)
    m:RegisterEvent("TRADE_SKILL_CLOSE", OnTradeSkillClose)
    m:RegisterEvent("CURRENCY_DISPLAY_UPDATE", OnCurrency)
    m:RegisterEvent("NEW_RECIPE_LEARNED", OnRecipeLearned)
    API.On("WORKSHOP_CRAFT", OnCrafted, "Goblinomics_Workshop.Professions")
    m:After(3, function()
        Professions.ReadStored()
        Professions.ReadStoredCooldowns()
    end)
end

function Professions.Disable()
    scanning, pendingRead = false, false
    OnTradeSkillClose()
end
