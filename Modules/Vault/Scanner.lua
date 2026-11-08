if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/Scanner.lua
-- Records every location with seenAt = time():
--   bags       Core bag snapshot after ITEMS_DELTA (debounced), at enable and logout
--   bank       CharacterBankTab_1..6 while the bank is open
--   warband    AccountBankTab_1..5 while the bank is open (needs the account inventory lock)
--   mail       attachments and attached gold while the mailbox is open (COD mails excluded)
--   auctions   active owned auctions (sold ones arrive as mail gold)
--   equipment  equipped items, all bound
-- plus the gold of the character and of the warband. Container scans run as jobs.
-- Warbound items whose data was not loaded during a scan count as tradable at
-- first; once the client knows their bind type, stored bank, warband and mail
-- snapshots are corrected without visiting the bank again. At enable every
-- stored snapshot is checked this way, which also repairs older ones.
local _, ns = ...

local Scanner = {}
ns.Scanner = Scanner

local API = ns.API
local ItemKey = API.ItemKey

local WOW_TOKEN = 122284
local BIND_OWNER = "Goblinomics_Vault.Scanner"
local vault
local bankOpen, mailOpen = false, false
local pending = {}   -- debounce flags per location
local knownIDs = {}  -- item ids whose bind type arrived since the last check

local BANK_BAGS, WARBAND_BAGS = {}, {}

local function BuildBagLists()
    local e = Enum and Enum.BagIndex or {}
    for i = 1, 6 do
        local id = e["CharacterBankTab_" .. i]
        if id then BANK_BAGS[#BANK_BAGS + 1] = id end
    end
    for i = 1, 5 do
        local id = e["AccountBankTab_" .. i]
        if id then WARBAND_BAGS[#WARBAND_BAGS + 1] = id end
    end
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function CharLocations()
    return vault.db.char.locations
end

local function Changed()
    if ns.Networth then ns.Networth.Schedule() end
end

local function Store(target, items, bound, money)
    target.items = items
    target.bound = bound
    target.money = money
    target.seenAt = time()
end
Scanner.Store = Store

local function Debounce(key, delay, fn)
    if pending[key] then return end
    pending[key] = true
    vault:After(delay, function()
        pending[key] = nil
        fn()
    end)
end

local function Add(items, key, n)
    items[key] = (items[key] or 0) + n
end

--- items, bound for a list of container ids; nil when no container is readable.
local function ScanContainers(bags)
    local items, bound, readable = {}, {}, false
    for _, bag in ipairs(bags) do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if numSlots > 0 then readable = true end
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and (info.stackCount or 0) > 0 then
                local key = ItemKey.FromLink(info.hyperlink)
                if key then
                    Add(items, key, info.stackCount)
                    local isBound, unknownID = API.Bags:IsBound(info, bag, slot)
                    if isBound then Add(bound, key, info.stackCount) end
                    if unknownID then API.Bags:AwaitBindType(unknownID, BIND_OWNER) end
                end
            end
        end
        API.Yield()
    end
    if not readable then return nil end
    return items, bound
end
Scanner.ScanContainers = ScanContainers

-- Bags -------------------------------------------------------------------------
local function ScanBags()
    local snap = API.Bags:Snapshot()
    if not snap then return false end
    local locs = CharLocations()
    locs.bags = locs.bags or {}
    Store(locs.bags, snap.items, snap.bound)
    Changed()
    return true
end
Scanner.ScanBags = ScanBags

local bagAttempts = 0
local function WaitForBags()
    if ScanBags() or bagAttempts >= 20 then return end
    bagAttempts = bagAttempts + 1
    vault:After(1, WaitForBags)
end

-- Bank and warband ------------------------------------------------------------
local function HasWarbandAccess()
    if ns.API.Flavor.IsForever() then return false end   -- no warband bank there
    if C_PlayerInfo and C_PlayerInfo.HasAccountInventoryLock then
        return C_PlayerInfo.HasAccountInventoryLock() == true
    end
    return true
end

local function ScanBank()
    vault:RunJob("scanBank", function()
        local items, bound = ScanContainers(BANK_BAGS)
        if items then
            local locs = CharLocations()
            locs.bank = locs.bank or {}
            Store(locs.bank, items, bound)
        end
        if HasWarbandAccess() then
            local wItems, wBound = ScanContainers(WARBAND_BAGS)
            if wItems then
                local warband = vault.db.root.warband
                Store(warband, wItems, wBound)
                warband.seenBy = vault.db.charKey
            end
        end
        Scanner.UpdateWarbandGold()
        Changed()
    end)
end
Scanner.ScanBank = ScanBank

function Scanner.UpdateWarbandGold()
    if not (C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType) or not HasWarbandAccess() then
        return
    end
    local money = C_Bank.FetchDepositedMoney(Enum.BankType.Account)
    if type(money) == "number" and not IsSecret(money) then
        local warband = vault.db.root.warband
        warband.gold, warband.goldSeenAt = money, time()
    end
end

local isBankBag = {}

local function OnBagUpdate(_, bag)
    if bankOpen and isBankBag[bag] then
        Debounce("bank", 0.5, ScanBank)
    end
end

-- Mail --------------------------------------------------------------------------
local function ScanMail()
    local items, bound, money, incomplete = {}, {}, 0, false
    local count = GetInboxNumItems() or 0
    local maxAttachments = ATTACHMENTS_MAX_RECEIVE or 16
    for i = 1, count do
        local _, _, sender, _, gold, cod, _, hasItem = GetInboxHeaderInfo(i)
        if sender == nil or sender == RETRIEVING_DATA then
            incomplete = true
        elseif (cod or 0) == 0 then
            money = money + (gold or 0)
            if hasItem then
                for j = 1, maxAttachments do
                    local link = GetInboxItemLink(i, j)
                    if link then
                        local key = ItemKey.FromLink(link)
                        local n = select(4, GetInboxItem(i, j)) or 1
                        if key then
                            Add(items, key, n)
                            -- warbound items can be mailed between own characters
                            local warbound = API.Bags:WarboundState(link)
                            if warbound then Add(bound, key, n) end
                            if warbound == nil then
                                local id = ItemKey.ToItemID(key)
                                if id then API.Bags:AwaitBindType(id, BIND_OWNER) end
                            end
                        end
                    end
                end
            end
        end
    end
    local locs = CharLocations()
    locs.mail = locs.mail or {}
    Store(locs.mail, items, bound, money)
    Changed()
    if incomplete then
        Debounce("mail", 1, ScanMail)
    end
end
Scanner.ScanMail = ScanMail

local function OnMailUpdate()
    if mailOpen then Debounce("mail", 0.5, ScanMail) end
end

-- Auctions ------------------------------------------------------------------------
local function ScanAuctions()
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumOwnedAuctions) then return end
    local items = {}
    local active = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active or 0
    for i = 1, ah.GetNumOwnedAuctions() do
        local info = ah.GetOwnedAuctionInfo(i)
        local itemID = info and info.itemKey and info.itemKey.itemID
        if info and itemID ~= WOW_TOKEN and info.status == active then
            local key = info.itemLink and ItemKey.FromLink(info.itemLink) or (itemID and ("i:" .. itemID))
            if key then Add(items, key, info.quantity or 1) end
        end
    end
    local locs = CharLocations()
    locs.auctions = locs.auctions or {}
    Store(locs.auctions, items, {})
    Changed()
end
Scanner.ScanAuctions = ScanAuctions

local function OnAuctionHouseShow()
    if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
        pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    end
end

-- Equipment -----------------------------------------------------------------------
local function ScanEquipment()
    local items = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        local key = link and ItemKey.FromLink(link)
        if key then Add(items, key, 1) end
    end
    local bound = {}
    for key, n in pairs(items) do bound[key] = n end
    local locs = CharLocations()
    locs.equipment = locs.equipment or {}
    Store(locs.equipment, items, bound)
    Changed()
end
Scanner.ScanEquipment = ScanEquipment

-- Gold ----------------------------------------------------------------------------
local function UpdateGold(money)
    if type(money) ~= "number" or IsSecret(money) then return end
    local c = vault.db.char
    c.gold, c.goldSeenAt = money, time()
end

--- Character gold from the core money tracker once its login baseline exists
-- (GetMoney() can read 0 right after login); retried for up to 30 s.
local goldAttempts = 0
function Scanner.ReadGold()
    local money = API.PlayerMoney()
    if type(money) == "number" then
        UpdateGold(money)
        Changed()
        return
    end
    if goldAttempts < 30 then
        goldAttempts = goldAttempts + 1
        vault:After(1, Scanner.ReadGold)
    end
end

local function OnMoney(_, payload)
    if payload.scope == "player" then
        UpdateGold(payload.total)
    else
        local warband = vault.db.root.warband
        warband.gold, warband.goldSeenAt = payload.total, time()
    end
    Changed()
end

-- Bind types that arrive later ------------------------------------------------------
-- Stored snapshots that can hold warbound items (bags are rescanned by the core).
local function EachSnapshot(fn)
    local root = vault.db.root
    for _, c in pairs(root.chars or {}) do
        local locs = type(c) == "table" and c.locations
        if type(locs) == "table" then
            for _, id in ipairs({ "bank", "mail" }) do
                if type(locs[id]) == "table" then fn(locs[id]) end
            end
        end
    end
    if type(root.warband) == "table" then fn(root.warband) end
end

--- Marks the units of warbound items as bound. ids: set of item ids to check, or
-- nil for every item; items without loaded data are awaited.
function Scanner.ResolveBindings(ids)
    vault:RunJob("resolveBindings", function()
        local changed, count = false, 0
        EachSnapshot(function(loc)
            if type(loc.items) ~= "table" then return end
            for key, n in pairs(loc.items) do
                local id = ItemKey.ToItemID(key)
                if id and (ids == nil or ids[id]) and (loc.bound and loc.bound[key] or 0) < n then
                    local warbound = API.Bags:WarboundState(id)
                    if warbound then
                        loc.bound = loc.bound or {}
                        loc.bound[key] = n
                        changed = true
                    elseif warbound == nil then
                        API.Bags:AwaitBindType(id, BIND_OWNER)
                    end
                end
                count = count + 1
                if count % 100 == 0 then API.Yield() end
            end
        end)
        if changed then Changed() end
    end)
end

local function OnBindTypeKnown(itemID)
    if not vault then return end
    knownIDs[itemID] = true
    Debounce("bindings", 1, function()
        local ids = knownIDs
        knownIDs = {}
        Scanner.ResolveBindings(ids)
    end)
end

-- Interaction windows ------------------------------------------------------------
local interactionKind = {}

local function OnInteraction(event, interactionType)
    local kind = interactionKind[interactionType]
    if not kind then return end
    local open = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
    if kind == "bank" then
        bankOpen = open
        if open then
            ScanBank()
        elseif ns.Networth then
            ns.Networth.RecordDay()
        end
    elseif kind == "mail" then
        mailOpen = open
        if open then Debounce("mail", 0.5, ScanMail) end
    end
end

function Scanner.Enable(module)
    vault = module
    if #BANK_BAGS == 0 then BuildBagLists() end
    for _, bag in ipairs(BANK_BAGS) do isBankBag[bag] = true end
    for _, bag in ipairs(WARBAND_BAGS) do isBankBag[bag] = true end
    local types = Enum and Enum.PlayerInteractionType or {}
    if types.Banker then interactionKind[types.Banker] = "bank" end
    if types.AccountBanker then interactionKind[types.AccountBanker] = "bank" end
    if types.MailInfo then interactionKind[types.MailInfo] = "mail" end

    module:On("ITEMS_DELTA", function() Debounce("bags", 2, ScanBags) end)
    module:On("MONEY_DELTA", OnMoney)
    module:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnInteraction)
    module:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", OnInteraction)
    module:RegisterEvent("BAG_UPDATE", OnBagUpdate)
    module:RegisterEvent("MAIL_INBOX_UPDATE", OnMailUpdate)
    module:RegisterEvent("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
    module:RegisterEvent("OWNED_AUCTIONS_UPDATED", function() Debounce("auctions", 0.5, ScanAuctions) end)
    module:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() Debounce("equipment", 1, ScanEquipment) end)

    API.Bags:OnBindTypeKnown(BIND_OWNER, OnBindTypeKnown)
    Scanner.ReadGold()
    Scanner.UpdateWarbandGold()
    ScanEquipment()
    module:After(5, ScanEquipment)   -- item links can be missing right after login
    bagAttempts = 0
    WaitForBags()
    Scanner.ResolveBindings()
end

function Scanner.Disable()
    goldAttempts = 0
    bankOpen, mailOpen = false, false
    for k in pairs(pending) do pending[k] = nil end
    knownIDs = {}
end

function Scanner.OnLogout()
    -- never GetMoney() here: the client reports 0 while logging out
    local money = API.PlayerMoney()
    if type(money) == "number" then UpdateGold(money) end
    ScanBags()
end
