if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Util/ItemKey.lua
-- Normalises item links and item strings into a compact, stable key that follows
-- the TSM item-string convention so keys can be handed to TSM_API unchanged:
--
--   i:<itemID>                                   base item
--   i:<itemID>:<suffixID>                        old random-suffix items
--   i:<itemID>::<n>:<bonusID>...                 items with bonus IDs (sorted)
--   i:<itemID>::<n>:<bonus>...:<m>:<type>:<value> ... with price-relevant modifiers
--   p:<speciesID>:<level>:<quality>              caged battle pets
--
-- Modifier handling mirrors TSM (type 9 kept with its value, types 29/30 kept as
-- sorted extra-stat values). Bonus IDs are kept completely and sorted; TSM filters
-- them through its own data tables, which Goblinomics does not ship. A filter can
-- be installed with ItemKey.SetBonusFilter (M2 wires the TSM connector in).
--
-- Pure Lua, no WoW API. Covered by spec/core/itemkey_spec.lua.
local _, ns = ...

local ItemKey = {}
ns.ItemKey = ItemKey
if ns.API then ns.API.ItemKey = ItemKey end

local IMPORTANT_MODIFIER_TYPES = { [9] = true }
local EXTRA_STAT_MODIFIER_TYPES = { [29] = true, [30] = true }
local NUM_BONUS_IDS_FIELD = 13 -- item:itemID:enchant:gem1:gem2:gem3:gem4:suffix:unique:linkLevel:spec:mask:context:numBonusIDs

local bonusFilter = nil

--- Install a function(bonusIDs, itemID) -> bonusIDs that may drop or replace
-- entries before the key is built. Pass nil to remove it.
function ItemKey.SetBonusFilter(fn)
    bonusFilter = fn
end

local function SplitNumbers(body)
    local fields, n = {}, 0
    for field in (body .. ":"):gmatch("([^:]*):") do
        n = n + 1
        fields[n] = tonumber(field) or 0
    end
    return fields, n
end

local function BuildBonusPart(fields, itemID)
    local numBonus = fields[NUM_BONUS_IDS_FIELD] or 0
    if numBonus <= 0 then
        return "", NUM_BONUS_IDS_FIELD
    end
    local bonus, count = {}, 0
    local last = NUM_BONUS_IDS_FIELD + numBonus
    for i = NUM_BONUS_IDS_FIELD + 1, last do
        local id = fields[i]
        if id and id > 0 then
            count = count + 1
            bonus[count] = id
        end
    end
    if bonusFilter then
        bonus = bonusFilter(bonus, itemID) or bonus
        count = #bonus
    end
    if count == 0 then
        return "", last
    end
    table.sort(bonus)
    return count .. ":" .. table.concat(bonus, ":"), last
end

local function BuildModifierPart(fields, firstIndex)
    local numModifiers = fields[firstIndex] or 0
    if numModifiers <= 0 then
        return ""
    end
    local kept, extraValues, importantValue = {}, {}, {}
    for m = 0, numModifiers - 1 do
        local modType = fields[firstIndex + 1 + m * 2]
        local modValue = fields[firstIndex + 2 + m * 2]
        if modType and modValue and modValue ~= 0 then
            if IMPORTANT_MODIFIER_TYPES[modType] then
                kept[#kept + 1] = modType
                importantValue[modType] = modValue
            elseif EXTRA_STAT_MODIFIER_TYPES[modType] then
                kept[#kept + 1] = modType
                extraValues[#extraValues + 1] = modValue
            end
        end
    end
    if #kept == 0 then
        return ""
    end
    table.sort(kept)
    table.sort(extraValues)
    local parts, extraIndex = { #kept }, 0
    for i = 1, #kept do
        local modType = kept[i]
        parts[#parts + 1] = modType
        if EXTRA_STAT_MODIFIER_TYPES[modType] then
            extraIndex = extraIndex + 1
            parts[#parts + 1] = extraValues[extraIndex]
        else
            parts[#parts + 1] = importantValue[modType]
        end
    end
    return table.concat(parts, ":")
end

--- Normalise an item link, "item:..." string, battle pet link or existing key.
-- @return key string or nil when the input is not an item
function ItemKey.FromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    if link:match("^[ip]:%d+") then
        return link
    end

    local species, level, quality = link:match("battlepet:(%d+):(%d+):(%d+)")
    if species then
        return "p:" .. species .. ":" .. level .. ":" .. quality
    end
    species = link:match("battlepet:(%d+)")
    if species then
        return "p:" .. species
    end

    -- crafted items end in the crafter's GUID ("Player-581-0AF7409A"): any text
    -- up to |h, non-numeric fields count as 0
    local body = link:match("|Hitem:([^|]*)|h") or link:match("^item:([^|]*)$")
    if not body then
        return nil
    end
    local fields = SplitNumbers(body)
    local itemID = fields[1]
    if not itemID or itemID <= 0 then
        return nil
    end

    local suffix = fields[7] or 0
    local bonusPart, lastBonusIndex = BuildBonusPart(fields, itemID)
    local modifierPart = BuildModifierPart(fields, lastBonusIndex + 1)

    local key = "i:" .. itemID .. ":" .. (suffix ~= 0 and suffix or "") .. ":" .. bonusPart .. ":" .. modifierPart
    return (key:gsub(":+$", ""))
end

--- Item ID of a key ("i:..."), or nil for pets and invalid keys.
function ItemKey.ToItemID(key)
    if type(key) ~= "string" then
        return nil
    end
    return tonumber(key:match("^i:(%d+)"))
end

--- Base key without suffix, bonus IDs and modifiers ("i:123" or "p:456").
function ItemKey.Base(key)
    if type(key) ~= "string" then
        return nil
    end
    return key:match("^[ip]:%d+")
end

--- True for caged battle pet keys.
function ItemKey.IsPet(key)
    return type(key) == "string" and key:sub(1, 2) == "p:"
end

--- Inverse of FromLink: a client item string ("item:...") or battle pet string
-- for a key, so link-based APIs (Auctionator, C_Item.GetItemInfo) resolve the
-- exact variant. Round trip: FromLink(ToItemString(key)) == key.
function ItemKey.ToItemString(key)
    if type(key) ~= "string" then
        return nil
    end
    local species, rest = key:match("^p:(%d+)(.*)$")
    if species then
        return "battlepet:" .. species .. (rest or "")
    end
    if not key:match("^i:%d+") then
        return nil
    end
    local parts, n = {}, 0
    for field in (key:sub(3) .. ":"):gmatch("([^:]*):") do
        n = n + 1
        parts[n] = field
    end
    local itemID, suffix = parts[1], parts[2] or ""
    local numBonus = tonumber(parts[3]) or 0
    local fields = { itemID, "", "", "", "", "", suffix, "", "", "", "", "" }
    local index = 4
    local tail = {}
    if numBonus > 0 then
        tail[#tail + 1] = numBonus
        for _ = 1, numBonus do
            tail[#tail + 1] = parts[index]
            index = index + 1
        end
    end
    local numMods = tonumber(parts[index]) or 0
    if numMods > 0 then
        if numBonus == 0 then
            tail[#tail + 1] = 0
        end
        tail[#tail + 1] = numMods
        for i = 1, numMods * 2 do
            tail[#tail + 1] = parts[index + i]
        end
    end
    if #tail == 0 then
        tail[1] = ""
    end
    return "item:" .. table.concat(fields, ":") .. ":" .. table.concat(tail, ":")
end
