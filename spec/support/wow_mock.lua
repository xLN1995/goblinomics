-- Minimal WoW API mock for busted. Only what the tested code touches; extend on demand.
-- Returns a `mock` table with helpers; installs the WoW globals into _G.
local mock = {}

local frames = {}

local TEXT_ONLY = { SetJustifyH = true, SetJustifyV = true, SetWordWrap = true, SetMaxLines = true, SetSpacing = true,
    GetStringWidth = true, SetFontObject = true }

local function NewFrame(frameType, name, parent, template)
    local frame = {
        _type = frameType, _name = name, _parent = parent, _template = template,
        _events = {}, _scripts = {}, _shown = false, _points = {},
    }
    function frame:RegisterEvent(event) self._events[event] = true end
    function frame:UnregisterEvent(event) self._events[event] = nil end
    function frame:UnregisterAllEvents() self._events = {} end
    function frame:IsEventRegistered(event) return self._events[event] == true end
    function frame:SetScript(handler, fn) self._scripts[handler] = fn end
    function frame:GetScript(handler) return self._scripts[handler] end
    function frame:HookScript(handler, fn)
        local prev = self._scripts[handler]
        self._scripts[handler] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function frame:Show() self._shown = true end
    function frame:Hide() self._shown = false end
    function frame:IsShown() return self._shown end
    function frame:SetShown(on) self._shown = on and true or false end
    function frame:SetSize() end
    function frame:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function frame:ClearAllPoints() self._points = {} end
    function frame:SetAllPoints(target) self._allPoints = target or self._parent end
    function frame:SetParent(p) self._parent = p end
    function frame:GetName() return self._name end
    function frame:CreateFontString() return NewFrame("FontString", nil, self) end
    function frame:CreateTexture() return NewFrame("Texture", nil, self) end
    function frame:CreateLine() return NewFrame("Line", nil, self) end
    function frame:CreateAnimationGroup()
        local group = NewFrame("AnimationGroup", nil, self)
        function group:CreateAnimation() return NewFrame("Animation", nil, group) end
        return group
    end
    function frame:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    -- as in the client: colours are numbers, a table is an error (Usage: SetColorTexture(r, g, b [, a]))
    function frame:SetColorTexture(r, g, b)
        if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
            error("Usage: self:SetColorTexture(r, g, b [, a])", 2)
        end
    end
    function frame:SetText(text) self._text = text end
    function frame:GetText() return self._text end
    -- Any other widget method (SetFrameStrata, SetTextColor, ...) is a no-op, so UI
    -- code runs in specs; plain fields (lowercase) stay nil.
    setmetatable(frame, { __index = function(_, key)
        -- text methods exist only on font strings and edit boxes, as in the client
        if TEXT_ONLY[key] and frameType ~= "FontString" and frameType ~= "EditBox" then return nil end
        if type(key) == "string" and key:match("^%u") then return function() end end
    end })
    frames[#frames + 1] = frame
    if name then _G[name] = frame end
    return frame
end

local InstallHookables  -- defined below; recreates functions addons hook

function mock.reset()
    frames = {}
    mock.frames = frames
    mock.now = 1700000000
    mock.money = 0
    mock.secrets = setmetatable({}, { __mode = "k" })
    mock.restricted = {}
    mock.metadata = { Version = "@project-version@" }
    mock.timers = {}
    mock.locale = "enUS"
    mock.combat = false
    mock.loggedIn = false
    mock.chat = {}
    mock.errors = {}
    mock.bags = {}          -- bags[bag] = { numSlots = n, [slot] = { itemID, hyperlink, stackCount, isBound } }
    mock.warband = 0
    mock.warbandAccess = true
    mock.loot = {}          -- loot[slot] = { link = ..., sources = { guid, qty, ... } }
    mock.fishing = false
    mock.items = {}         -- items[itemID or itemString] = { name = ..., sellPrice = ... }
    mock.mail = {}          -- mail[i] = { sender, money, cod, items = { {link, count}, ... } }
    mock.auctions = {}      -- auctions[i] = { itemLink, itemID, quantity, status }
    mock.equipment = {}     -- equipment[slot] = link
    mock.itemRequests = {}
    -- professions: child lines of the open window, their concentration currency,
    -- currencies by id, recipe cooldowns { cd, isDay, charges, maxCharges }, spell charges
    mock.childProfessions = {}
    mock.concentrationIDs = {}
    mock.childSkillLine = 0
    mock.recipeIDs = {}
    mock.currencies = {}
    mock.recipeCooldowns = {}
    mock.spellCharges = {}
    mock.cooldownsSecret = false
    mock.profileStep = 0.01
    mock.player = { name = "xLN", realm = "Blackrock", guid = "Player-1-0000ABCD", class = "WARRIOR", faction = "Horde",
        level = 80 }
    _G.SlashCmdList = {}
    _G.Goblinomics = nil
    _G.GOBLINOMICS_CLIENT_BLOCKED = nil
    _G.GoblinomicsDB = nil
    _G.GoblinomicsVaultDB = nil
    _G.GoblinomicsLedgerDB = nil
    _G.GoblinomicsGathererDB = nil
    _G.GoblinomicsWorkshopDB = nil
    for i = 1, 4 do _G["SLASH_GOBLINOMICS" .. i] = nil end
    mock.repairCost = 0
    mock.durability = {}    -- durability[slot] = { current, max }
    mock.savedInstances = {} -- { name, id, reset, difficulty, locked, isRaid, difficultyName, ... }
    mock.sounds = {}
    mock.maxLevel = 80
    mock.journal = {}
    mock.warboundSlots = {}
    mock.recipes = {}        -- recipes[id] = { name, profession, qualityItemIDs, qualityIDs, isSalvage, schematic, outputs }
    mock.recraftRecipes = {} -- itemGUID -> recipeID
    mock.notLoaded = {}
    mock.lod = {}
    mock.loadedAddOns = {}
    mock.journalTier = 1
    mock.sendMail = { money = 0, price = 30, cod = 0 }
    mock.trade = { partner = "Trader", moneyIn = 0, moneyOut = 0 }
    mock.deposit = 0
    if InstallHookables then InstallHookables() end
end

--- Fire an event on every frame that registered it.
function mock.fire(event, ...)
    for i = 1, #frames do
        local frame = frames[i]
        local handler = frame._scripts.OnEvent
        if handler and frame._events[event] then
            handler(frame, event, ...)
        end
    end
end

--- Advance mocked time and run due C_Timer callbacks.
function mock.advance(seconds)
    mock.now = mock.now + seconds
    local due = {}
    for i = #mock.timers, 1, -1 do
        local t = mock.timers[i]
        if t.at <= mock.now then
            due[#due + 1] = t
            table.remove(mock.timers, i)
        end
    end
    table.sort(due, function(a, b) return a.at < b.at end)
    for i = 1, #due do due[i].fn() end
end

--- Run all timers due now, repeatedly (C_Timer.After(0) chains), up to n rounds.
function mock.flush(n)
    for _ = 1, n or 50 do
        local due = false
        for i = 1, #mock.timers do
            if mock.timers[i].at <= mock.now then due = true break end
        end
        if not due then return end
        mock.advance(0)
    end
end

function mock.set_money(copper) mock.money = copper end
function mock.set_secret(value) mock.secrets[value] = true end

-------------------------------------------------------------------------------
-- Globals
-------------------------------------------------------------------------------
_G.CreateFrame = NewFrame
_G.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
_G.CreateFont = function(name) return NewFrame("Font", name) end
-- ScrollBox lists: SetDataProvider initialises one row per element, so row
-- initialisers run in specs; box._data / box._rows keep the result.
_G.CreateScrollBoxListLinearView = function()
    local view = {}
    function view:SetElementExtent() end
    function view:SetElementInitializer(_, fn) self._init = fn end
    return view
end
_G.CreateScrollBoxLinearView = function() return { SetPanExtent = function() end } end
_G.CreateDataProvider = function(array) return { array = array } end
_G.ScrollBoxConstants = { RetainScrollPosition = 1, UpdateImmediately = 1 }
_G.ScrollUtil = {
    InitScrollBoxListWithScrollBar = function(box, _, view)
        function box:SetDataProvider(provider)
            self._data, self._rows = provider.array, {}
            for i, data in ipairs(provider.array) do
                local row = NewFrame("Button", nil, self)
                view._init(row, data)
                self._rows[i] = row
            end
        end
    end,
    InitScrollBoxWithScrollBar = function() end,
}
_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
_G.UISpecialFrames = {}
mock.cursor = { x = 0, y = 0 }
_G.GetCursorPosition = function() return mock.cursor.x, mock.cursor.y end
_G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
_G.UIParent = { GetName = function() return "UIParent" end }

_G.GetLocale = function() return mock.locale end
_G.GetBuildInfo = function() return "12.1.0", "69933", "Sep 20 2026", 120100 end
_G.GetMoney = function() return mock.money end
_G.GetTime = function() return mock.now end
_G.GetServerTime = function() return mock.now end
_G.time = function(t) if type(t) == "table" then return os.time(t) end return mock.now end

local profileClock = 0
_G.debugprofilestop = function()
    profileClock = profileClock + (mock.profileStep or 0.01)
    return profileClock
end
_G.debugstack = function() return "stack" end
_G.geterrorhandler = function()
    return function(err) mock.errors[#mock.errors + 1] = tostring(err) end
end
_G.securecallfunction = function(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then mock.errors[#mock.errors + 1] = tostring(err) end
end
_G.InCombatLockdown = function() return mock.combat end
_G.IsLoggedIn = function() return mock.loggedIn end
_G.UnitName = function() return mock.player.name end
_G.UnitGUID = function() return mock.player.guid end
_G.UnitClass = function() return "Warrior", mock.player.class end
_G.UnitFactionGroup = function() return mock.player.faction end
_G.GetNormalizedRealmName = function() return mock.player.realm end
_G.GetRealmName = function() return mock.player.realm end
_G.BreakUpLargeNumbers = function(n)
    local s = tostring(n)
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""))
end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) mock.chat[#mock.chat + 1] = msg end }
_G.GameTooltip = {
    lines = {},
    SetOwner = function(self, owner) self.lines, self.owner = {}, owner end,
    SetText = function(self, t) self.lines[#self.lines + 1] = t end,
    AddLine = function(self, t) self.lines[#self.lines + 1] = t end,
    AddDoubleLine = function(self, a, b) self.lines[#self.lines + 1] = a .. "=" .. b end,
    Show = function() end, Hide = function() end,
    IsOwned = function(self, owner) return self.owner == owner end,
}
_G.UpdateAddOnMemoryUsage = function() end
_G.GetAddOnMemoryUsage = function() return 512 end

-- Containers
_G.C_Container = {
    UseContainerItem = function() end,
    GetContainerNumSlots = function(bag) local b = mock.bags[bag]; return b and b.numSlots or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local b = mock.bags[bag]
        local s = b and b[slot]
        if not s then return nil end
        return { itemID = s.itemID, hyperlink = s.hyperlink, stackCount = s.stackCount, isBound = s.isBound or false,
            isLocked = s.isLocked or false }
    end,
}
_G.C_Item = {
    GetItemLink = function(location) return type(location) == "table" and location.link or nil end,
    GetItemID = function(location) return type(location) == "table" and location.itemID or nil end,
    GetItemInfo = function(query)
        local id = type(query) == "number" and query or tonumber(tostring(query):match("item:(%d+)"))
        local info = mock.items[query] or mock.items[id]
        if not info and not id then
            -- by name, like the client for items in its cache
            for _, v in pairs(mock.items) do
                if type(v) == "table" and v.name == query and v.cached ~= false then info = v; break end
            end
        end
        if not info then return nil end
        return info.name or "Item", info.link, info.quality or 1, nil, nil, nil, nil, nil, nil, nil, info.sellPrice or 0,
            info.classID, info.subclassID, info.bindType
    end,
    GetItemNameByID = function(id) local info = mock.items[id]; return info and info.name end,
    RequestLoadItemDataByID = function(id) mock.itemRequests[#mock.itemRequests + 1] = id end,
    GetItemIconByID = function(id) return 1000 + id end,
    IsBoundToAccountUntilEquip = function(loc) return mock.warboundSlots[(loc.bag or -1) .. ":" .. (loc.slot or -1)] == true end,
    DoesItemExist = function() return true end,
    GetItemInfoInstant = function(item)
        local id = type(item) == "number" and item or tonumber(tostring(item):match("item:(%d+)"))
        local info = id and mock.items[id]
        if not id then return nil end
        return id, nil, nil, nil, nil, info and info.classID or 7, info and info.subclassID or 0
    end,
    GetItemQualityByID = function(item)
        local id = type(item) == "number" and item or tonumber(tostring(item):match("item:(%d+)"))
        local info = id and mock.items[id]
        return info and info.quality
    end,
}
_G.GetInboxNumItems = function() return #mock.mail, #mock.mail end
_G.GetInboxHeaderInfo = function(i)
    local m = mock.mail[i]
    if not m then return nil end
    return nil, nil, m.sender or "Alt", m.subject or "Subject", m.money or 0, m.cod or 0, 30, m.items and #m.items > 0
end
_G.GetInboxInvoiceInfo = function(i)
    local inv = mock.mail[i] and mock.mail[i].invoice
    if not inv then return nil end
    return inv.type, inv.itemName, inv.player, inv.bid, inv.buyout, inv.deposit, inv.consignment, 0, 0, 0, inv.count
end
_G.ERR_TRADE_COMPLETE = "Trade complete."
_G.ERR_TRADE_CANCELLED = "Trade cancelled."
_G.GetUnitName = function() return mock.trade.partner end
_G.GetTargetTradeMoney = function() return mock.trade.moneyIn end
_G.GetPlayerTradeMoney = function() return mock.trade.moneyOut end
_G.GetRepairAllCost = function() return mock.repairCost, mock.repairCost > 0 end
_G.GetSendMailMoney = function() return mock.sendMail.money end
_G.GetSendMailPrice = function() return mock.sendMail.price end
_G.GetSendMailCOD = function() return mock.sendMail.cod end
_G.GetInboxItemLink = function(i, j) local m = mock.mail[i]; return m and m.items and m.items[j] and m.items[j][1] end
_G.GetInboxItem = function(i, j)
    local a = mock.mail[i] and mock.mail[i].items and mock.mail[i].items[j]
    if not a then return nil end
    return "Item", nil, nil, a[2] or 1
end
_G.ATTACHMENTS_MAX_RECEIVE = 16
_G.RETRIEVING_DATA = "Retrieving data"
_G.C_AuctionHouse = {
    queried = 0,
    QueryOwnedAuctions = function() _G.C_AuctionHouse.queried = _G.C_AuctionHouse.queried + 1 end,
    GetNumOwnedAuctions = function() return #mock.auctions end,
    GetOwnedAuctionInfo = function(i)
        local a = mock.auctions[i]
        return a and { itemLink = a.itemLink, itemKey = { itemID = a.itemID }, quantity = a.quantity or 1, status = a.status or 0 }
    end,
}
_G.GetInventoryItemLink = function(_, slot) return mock.equipment[slot] end
_G.GetInventoryItemDurability = function(slot)
    local d = mock.durability[slot]
    if not d then return nil end
    return d[1], d[2]
end
_G.RequestRaidInfo = function() mock.raidInfoRequests = (mock.raidInfoRequests or 0) + 1 end
_G.GetNumSavedInstances = function() return #mock.savedInstances end
_G.GetSavedInstanceInfo = function(i)
    local s = mock.savedInstances[i]
    if not s then return nil end
    return s.name, s.id or i, s.reset or 3600, s.difficulty or 1, s.locked ~= false, s.extended or false, 0,
        s.isRaid or false, s.maxPlayers or 5, s.difficultyName or "Normal", s.numEncounters or 1, s.encounterProgress or 1,
        false, s.mapID
end
_G.UnitLevel = function() return mock.player.level end
_G.GetMaxLevelForPlayerExpansion = function() return mock.maxLevel end
_G.GetDifficultyInfo = function(id)
    local names = { [1] = "Normal", [2] = "Heroic", [14] = "Normal", [15] = "Heroic", [16] = "Mythic", [17] = "Raid Finder",
        [23] = "Mythic", [3] = "10 Player", [4] = "25 Player" }
    return names[id]
end
-- Encounter Journal: mock.journal[tier] = { name, raids = { {id, name, areaMapID, mapID, encounters} }, dungeons = {...} }
_G.EJ_GetNumTiers = function() return #mock.journal end
_G.EJ_SelectTier = function(tier) mock.journalTier = tier end
_G.EJ_GetCurrentTier = function() return mock.journalTier end
_G.EJ_GetTierInfo = function(tier) return mock.journal[tier] and mock.journal[tier].name end
_G.EJ_GetInstanceByIndex = function(index, isRaid)
    local tier = mock.journal[mock.journalTier]
    local e = tier and tier[isRaid and "raids" or "dungeons"][index]
    if not e then return nil end
    return e.id, e.name, "", 0, 0, 0, 0, e.areaMapID or 1, "", false, e.mapID
end
_G.EJ_GetEncounterInfoByIndex = function(index, journalID)
    for _, tier in ipairs(mock.journal) do
        for _, list in ipairs({ tier.raids, tier.dungeons }) do
            for _, e in ipairs(list) do
                if e.id == journalID and index <= (e.encounters or 0) then return "Boss " .. index end
            end
        end
    end
    return nil
end
_G.PlaySound = function(id, channel) mock.sounds[#mock.sounds + 1] = { id, channel } end
_G.PlaySoundFile = function(file, channel) mock.sounds[#mock.sounds + 1] = { file, channel } end
_G.SOUNDKIT = { UI_EPICLOOT_TOAST = 31578, UI_LEGENDARY_LOOT_TOAST = 63971, RAID_WARNING = 8959, IG_MAINMENU_OPEN = 850 }

InstallHookables = function()
    _G.RepairAllItems = function() end
    _G.TakeInboxMoney = function() end
    _G.AutoLootMailItem = function() end
    _G.TakeInboxItem = function() end
    _G.SendMail = function() end
    _G.TakeTaxiNode = function() end
    _G.TaxiNodeCost = function() return mock.taxiCost or 0 end
    _G.TaxiNodeName = function() return "Orgrimmar" end
    _G.TaxiNodeGetType = function() return "REACHABLE" end
    _G.SetTradeMoney = function() end
    _G.C_CraftingOrders = {
        FulfillOrder = function() end,
        GetClaimedOrder = function() return mock.claimedOrder end,
    }
    _G.C_TradeSkillUI = {
        CraftRecipe = function() end,
        CraftEnchant = function() end,
        RecraftRecipe = function() end,
        RecraftRecipeForOrder = function() end,
        CraftSalvage = function() end,
        GetRecipeInfo = function(id)
            local r = mock.recipes[id]
            if not r then return nil end
            return { recipeID = id, name = r.name, isSalvageRecipe = r.isSalvage or false,
                isEnchantingRecipe = r.isEnchanting or false, qualityIDs = r.qualityIDs, maxQuality = r.maxQuality }
        end,
        GetProfessionInfoByRecipeID = function(id)
            local r = mock.recipes[id]
            return r and { professionID = r.professionID or 1, professionName = r.profession or "Alchemy",
                parentProfessionID = r.professionID or 1, parentProfessionName = r.profession or "Alchemy",
                expansionName = r.expansion } or nil
        end,
        GetRecipeSchematic = function(id) local r = mock.recipes[id]; return r and r.schematic end,
        GetRecipeQualityItemIDs = function(id) local r = mock.recipes[id]; return r and r.qualityItemIDs end,
        GetRecipeOutputItemData = function(id, _, _, qualityID)
            local r = mock.recipes[id]
            local link = r and r.outputs and r.outputs[qualityID]
            return link and { hyperlink = link } or nil
        end,
        GetOriginalCraftRecipeID = function(guid) return mock.recraftRecipes[guid] end,
        GetChildProfessionInfos = function() return mock.childProfessions end,
        GetConcentrationCurrencyID = function(id) return mock.concentrationIDs[id] or 0 end,
        GetProfessionChildSkillLineID = function() return mock.childSkillLine end,
        GetAllRecipeIDs = function() return mock.recipeIDs end,
        GetRecipeCooldown = function(id)
            local c = mock.recipeCooldowns[id]
            if not c then return nil, false, 0, 0 end
            return c[1], c[2], c[3], c[4]
        end,
    }
    _G.C_Secrets = { ShouldCooldownsBeSecret = function() return mock.cooldownsSecret end }
    _G.C_CurrencyInfo = { GetCurrencyInfo = function(id) return mock.currencies[id] end }
    _G.C_Spell = { GetSpellCharges = function(id) return mock.spellCharges[id] end }
    _G.C_Mail = { GetCraftingOrderMailInfo = function(i) return mock.mail[i] and mock.mail[i].craftingOrder end }
    _G.C_AuctionHouse = {
        queried = 0,
        QueryOwnedAuctions = function() _G.C_AuctionHouse.queried = _G.C_AuctionHouse.queried + 1 end,
        GetNumOwnedAuctions = function() return #mock.auctions end,
        GetOwnedAuctionInfo = function(i)
            local a = mock.auctions[i]
            return a and { auctionID = a.auctionID or i, itemLink = a.itemLink, itemKey = { itemID = a.itemID },
                quantity = a.quantity or 1, status = a.status or 0 }
        end,
        PostItem = function() end,
        PostCommodity = function() end,
        CancelAuction = function() end,
        PlaceBid = function() end,
        ConfirmCommoditiesPurchase = function() end,
        CalculateItemDeposit = function() return mock.deposit end,
        StartCommoditiesPurchase = function() end,
        GetAuctionInfoByID = function(id) return mock.auctionInfo and mock.auctionInfo[id] end,
        CalculateCommodityDeposit = function() return mock.deposit end,
    }
    local bank = _G.C_Bank or {}
    bank.FetchDepositedMoney = function() return mock.warband end
    bank.DepositMoney = function() end
    bank.WithdrawMoney = function() end
    _G.C_Bank = bank
end
_G.date = function(fmt, t) return os.date(fmt, t or mock.now) end
_G.C_Bank = { FetchDepositedMoney = function() return mock.warband end }
_G.C_PlayerInfo = { HasAccountInventoryLock = function() return mock.warbandAccess end }

-- Loot window
_G.GetNumLootItems = function() return #mock.loot end
_G.GetLootSlotLink = function(slot) return mock.loot[slot] and mock.loot[slot].link end
_G.GetLootSourceInfo = function(slot)
    local l = mock.loot[slot]
    if not l then return nil end
    return unpack(l.sources or {})
end
_G.IsFishingLoot = function() return mock.fishing end

_G.issecretvalue = function(v)
    return v ~= nil and mock.secrets[v] == true
end

_G.hooksecurefunc = function(tbl, name, fn)
    if type(tbl) == "string" then tbl, name, fn = _G, tbl, name end
    local orig = tbl[name]
    tbl[name] = function(...)
        local results = { orig(...) }
        fn(...)
        return unpack(results)
    end
end

_G.strsplit = function(delim, str, pieces)
    local result = {}
    for piece in (str .. delim):gmatch("(.-)" .. delim:gsub("%p", "%%%0")) do
        result[#result + 1] = piece
        if pieces and #result == pieces - 1 then
            result[#result + 1] = str:sub(#table.concat(result, delim) + 2)
            break
        end
    end
    return unpack(result)
end
_G.strjoin = function(delim, ...) return table.concat({ ... }, delim) end
_G.strmatch = string.match
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.strlower = string.lower
_G.strupper = string.upper
_G.format = string.format
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.tinsert = table.insert
_G.tremove = table.remove
_G.tContains = function(t, v) for _, x in pairs(t) do if x == v then return true end end return false end
_G.CopyTable = function(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = type(v) == "table" and _G.CopyTable(v) or v end
    return copy
end
_G.Mixin = function(obj, ...)
    for i = 1, select("#", ...) do
        for k, v in pairs((select(i, ...))) do obj[k] = v end
    end
    return obj
end

_G.C_Timer = {
    After = function(delay, fn) mock.timers[#mock.timers + 1] = { at = mock.now + delay, fn = fn } end,
    NewTicker = function(interval, fn, iterations)
        local ticker = { _cancelled = false }
        local count = 0
        local function tick()
            if ticker._cancelled then return end
            count = count + 1
            fn(ticker)
            if not iterations or count < iterations then
                mock.timers[#mock.timers + 1] = { at = mock.now + interval, fn = tick }
            end
        end
        mock.timers[#mock.timers + 1] = { at = mock.now + interval, fn = tick }
        function ticker:Cancel() self._cancelled = true end
        function ticker:IsCancelled() return self._cancelled end
        return ticker
    end,
}

_G.C_AddOns = {
    GetAddOnMetadata = function(_, field) return mock.metadata[field] end,
    IsAddOnLoaded = function(name) return mock.notLoaded[name] == nil end,
    IsAddOnLoadOnDemand = function(name) return mock.lod[name] == true end,
    LoadAddOn = function(name)
        mock.loadedAddOns[#mock.loadedAddOns + 1] = name
        mock.notLoaded[name] = nil
        return true
    end,
}

_G.EXPANSION_NAME0 = "Classic"
_G.EXPANSION_NAME1 = "The Burning Crusade"
_G.EXPANSION_NAME2 = "Wrath of the Lich King"
_G.EXPANSION_NAME10 = "The War Within"
_G.EXPANSION_NAME11 = "Midnight"
_G.EXPANSION_NAME12 = "Expansion 12"
_G.Enum = {
    ExpansionLevel = { WarWithin = 10, Midnight = 11 },
    BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
        CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8, CharacterBankTab_4 = 9,
        CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
        AccountBankTab_1 = 13, AccountBankTab_2 = 14, AccountBankTab_3 = 15, AccountBankTab_4 = 16, AccountBankTab_5 = 17 },
    AuctionStatus = { Active = 0, Sold = 1 },
    TooltipDataType = { Item = 0 },
    BankType = { Character = 0, Account = 2 },
    PlayerInteractionType = { TradePartner = 1, Merchant = 5, Banker = 8, Trainer = 7, TaxiNode = 11, MailInfo = 17,
        Auctioneer = 21, GuildBanker = 10, ItemUpgrade = 25, ProfessionsCustomerOrder = 55, AccountBanker = 63,
        Transmogrifier = 32, Barber = 30 },
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    CraftingOrderReagentSource = { Any = 0, Customer = 1, Crafter = 2 },
}

_G.C_RestrictedActions = {
    IsAddOnRestrictionActive = function(restrictionType) return mock.restricted[restrictionType] == true end,
    GetAddOnRestrictionState = function(restrictionType) return mock.restricted[restrictionType] and 2 or 0 end,
}

-- enUS GlobalStrings used by the chat parser
_G.LOOT_ITEM_SELF = "You receive loot: %s."
_G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
_G.LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
_G.LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
_G.LOOT_MONEY = "You loot %s"
_G.YOU_LOOT_MONEY = "You loot %s"
_G.GOLD_AMOUNT = "%d Gold"
_G.SILVER_AMOUNT = "%d Silver"
_G.COPPER_AMOUNT = "%d Copper"
_G.LOOT_ITEM_BONUS_ROLL_SELF = "You receive bonus loot: %s."
_G.LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE = "You receive bonus loot: %sx%d."
_G.LOOT_ITEM_CREATED_SELF = "You create: %s."
_G.LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
_G.AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
_G.AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
_G.AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
_G.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"

-- LibStub and CallbackHandler from the bundled copies.
if not _G.LibStub then
    assert(loadfile("Libs/LibStub/LibStub.lua"))()
end
assert(loadfile("Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua"))()
assert(loadfile("Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua"))()
-- The WoW client provides the bit library (LibSharedMedia uses it); plain Lua 5.1 does not.
if not _G.bit then
    local function op(a, b, f)
        local r, m = 0, 1
        while a > 0 or b > 0 do
            if f(a % 2, b % 2) then r = r + m end
            a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
        end
        return r
    end
    _G.bit = {
        band = function(a, b) return op(a, b, function(x, y) return x == 1 and y == 1 end) end,
        bor = function(a, b) return op(a, b, function(x, y) return x == 1 or y == 1 end) end,
        bxor = function(a, b) return op(a, b, function(x, y) return x ~= y end) end,
        lshift = function(a, n) return a * 2 ^ n end,
        rshift = function(a, n) return math.floor(a / 2 ^ n) end,
    }
end
_G.C_UIFileAsset = { IsKnownFile = function() return true end }
assert(loadfile("Libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"))()
assert(loadfile("Libs/LibDeflate/LibDeflate.lua"))()
assert(loadfile("Libs/LibSerialize/LibSerialize.lua"))()

InstallHookables()
mock.reset()
return mock
