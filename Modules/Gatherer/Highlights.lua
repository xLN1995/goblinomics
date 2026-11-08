if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Highlights.lua
-- Loot highlights during a running session: an item stack worth at least the
-- threshold (farm override or setting, default 2,500 g, 5 g on WoW: Forever), one of the farm's
-- expected highlights or an item on the global watchlist shows a toast, with an
-- optional sound. Mounts and legendary items always trigger a highlight,
-- whatever their value and the threshold. During the
-- restricted mode the core queues the toasts and shows them afterwards.
local _, ns = ...

local Highlights = {}
ns.Highlights = Highlights

local COPPER_PER_GOLD = 10000
local MAX_KEPT = 20   -- highlights remembered per session for the tab

local module

--- Effective threshold in copper for a farm (nil = setting); 0 = off.
function Highlights.Threshold(farm)
    local gold = (farm and farm.highlightThreshold) or module.db.settings.highlightThreshold or 0
    return gold * COPPER_PER_GOLD
end

--- Is the item one of the farm's expected highlights?
function Highlights.IsExpected(key, farm)
    return farm ~= nil and farm.expectedHighlights ~= nil and tContains(farm.expectedHighlights, key)
end

--- Is the item on the global watchlist (farm = nil) or expected for the farm?
function Highlights.IsWatched(key, farm)
    if module.db.root.watchlist[key] then return true end
    return Highlights.IsExpected(key, farm)
end

--- Add or remove an item on the global watchlist.
function Highlights.SetWatched(key, on)
    module.db.root.watchlist[key] = on and true or nil
    ns.API.Emit("GATHERER_FARMS", { action = "watchlist" })
end

--- Sorted item keys of the global watchlist.
function Highlights.Watchlist()
    local keys = {}
    for key in pairs(module.db.root.watchlist) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function Icon(key)
    local id = tonumber(key:match("^i:(%d+)"))
    return id and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or nil
end

local LEGENDARY = Enum and Enum.ItemQuality and Enum.ItemQuality.Legendary or 5
local MISC_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Miscellaneous or 15
local MOUNT_SUBCLASS = Enum and Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.Mount or 5
local LEGENDARY_COLOR = "|cffff8000"

--- Mount items: the mount journal knows the item, or class Miscellaneous / Mount.
function Highlights.IsMount(link, key)
    local id = key and tonumber(key:match("^i:(%d+)"))
    if id and C_MountJournal and C_MountJournal.GetMountFromItem and C_MountJournal.GetMountFromItem(id) then
        return true
    end
    local item = link or id
    if not item or not C_Item.GetItemInfoInstant then return false end
    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(item)
    return classID == MISC_CLASS and subclassID == MOUNT_SUBCLASS
end

--- Legendary quality from the item data, or from the link colour when uncached.
function Highlights.IsLegendary(link, key)
    local item = link or (key and tonumber(key:match("^i:(%d+)")))
    local quality = item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(item)
    if quality then return quality == LEGENDARY end
    return type(link) == "string" and link:sub(1, #LEGENDARY_COLOR):lower() == LEGENDARY_COLOR
end

Highlights.DEFAULT_SOUND = "kit:UI_EPICLOOT_TOAST"
Highlights.DEFAULT_SPECIAL_SOUND = "kit:UI_LEGENDARY_LOOT_TOAST"

--- Sound value for a highlight (special = mount or legendary item).
function Highlights.Sound(special)
    local settings = module.db.settings
    local Sounds = ns.API.Sounds
    local sound = special and Sounds:Resolve(settings.specialSound, Highlights.DEFAULT_SPECIAL_SOUND)
        or Sounds:Resolve(settings.highlightSound, Highlights.DEFAULT_SOUND)
    return sound ~= "none" and sound or nil
end

--- Called by the session for every counted loot event.
function Highlights.OnLoot(p)
    local session = ns.Session.Active()
    if not session then return end
    local farm = session.farmId and ns.Farms.Get(session.farmId) or nil
    local value = ns.API.Value:Evaluate(p.itemKey, { quantity = p.quantity }).total
    local threshold = Highlights.Threshold(farm)
    local expected = Highlights.IsExpected(p.itemKey, farm)
    local watched = expected or module.db.root.watchlist[p.itemKey] == true
    local mount = Highlights.IsMount(p.link, p.itemKey)
    local legendary = not mount and Highlights.IsLegendary(p.link, p.itemKey)
    if not (watched or mount or legendary) and (threshold <= 0 or value < threshold) then return end

    local L = ns.L
    local list = session.highlights or {}
    session.highlights = list
    table.insert(list, 1, { key = p.itemKey, quantity = p.quantity, value = value, time = p.time or time() })
    for i = #list, MAX_KEPT + 1, -1 do list[i] = nil end

    local text = (p.link or ns.Valuation.ItemName(p.itemKey)) .. ns.API.ItemMarks:Inline(p.itemKey)
    if p.quantity > 1 then text = text .. " x" .. p.quantity end
    if value > 0 then text = text .. "  " .. ns.API.Money.Format(value, { abbreviate = true }) end
    ns.API.UI:Toast({
        title = (mount and L["Mount looted!"]) or (legendary and L["Legendary looted!"])
            or (expected and L["Expected highlight looted"])
            or (watched and L["Watchlist item looted"] or L["Valuable loot"]),
        text = text,
        icon = Icon(p.itemKey),
        sound = Highlights.Sound(mount or legendary),
    })
end

function Highlights.Enable(m)
    module = m
end
