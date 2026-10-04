if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/Monitors.lua
-- "Hook, then confirm" monitors (Journalator pattern): hooksecurefunc on the
-- Blizzard function that starts an action announces the expected money change to
-- the classifier, which books the matching MONEY_DELTA. Hooks are permanent, so
-- every hook checks `active` (module enabled).
local _, ns = ...

local Monitors = {}
ns.Monitors = Monitors

local API = ns.API
local Classifier, Rules = ns.Classifier, ns.Rules
local ItemKey = API.ItemKey

local ledger
local active = false
local hooked = false
local trade = nil

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function Hook(tbl, name, fn)
    if tbl and type(tbl[name]) == "function" then
        if tbl == _G then hooksecurefunc(name, fn) else hooksecurefunc(tbl, name, fn) end
    end
end

-- Repair ----------------------------------------------------------------------------
local function OnRepairAll(guildBank)
    if not active or guildBank then return end
    local cost = GetRepairAllCost()
    if type(cost) == "number" and cost > 0 then
        Classifier.Expect("repair", -cost, { category = "Repair", sub = "repair" })
    end
end

local function OnDurability()
    if API.Context:IsOpen("merchant") then Classifier.MarkDurability() end
end

-- Mail --------------------------------------------------------------------------------
local function AuctionLog() return ns.AuctionLog end

local expiredPattern, outbidPattern

local function MailDecision(index, sender, subject)
    local invoiceType, itemName, player, bid, _, _, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType == "seller" then
        local key = AuctionLog() and AuctionLog().KeyForSale(itemName, count or 1, bid or 0)
        if AuctionLog() then
            AuctionLog().Sale(key, itemName, count or 1, bid or 0, (bid or 0) - (consignment or 0))
        end
        -- without a key the name stays in the note, else only the buyer would be left
        local note = player
        if not key and type(itemName) == "string" then note = player and (itemName .. " (" .. player .. ")") or itemName end
        return { category = "AH", sub = "sale", itemKey = key, quantity = count, note = note }
    end
    outbidPattern = outbidPattern or (AUCTION_OUTBID_MAIL_SUBJECT and API.ChatPattern.Build(AUCTION_OUTBID_MAIL_SUBJECT))
    if outbidPattern and type(subject) == "string" and subject:match(outbidPattern) then
        return { category = "AH", sub = "refund", note = sender }
    end
    local craft = C_Mail and C_Mail.GetCraftingOrderMailInfo and C_Mail.GetCraftingOrderMailInfo(index)
    if craft and (craft.commissionPaid or 0) > 0 then
        return { category = "Crafting", sub = "commission", note = craft.crafterName or sender }
    end
    if Rules.IsOwnCharacter(sender) then
        return { category = "Transfer", sub = "alt", note = sender }
    end
    local rule = Rules.MatchMail(ledger.db.settings.mailRules, sender, subject)
    if rule then
        return { category = rule.category or "Mail", sub = "in", tag = rule.tag, note = sender }
    end
    return { category = "Mail", sub = "in", note = sender }
end
Monitors.MailDecision = MailDecision

local function LogMailItems(index, attachIndex)
    local log = AuctionLog()
    if not log then return end
    local _, _, _, subject = GetInboxHeaderInfo(index)
    local invoiceType, _, _, bid, _, _, _, _, _, _, count = GetInboxInvoiceInfo(index)
    local link = GetInboxItemLink(index, attachIndex or 1)
    local key = link and ItemKey.FromLink(link)
    local n = select(4, GetInboxItem(index, attachIndex or 1)) or count or 1
    if invoiceType == "buyer" then
        log.Purchase(key, n, bid or 0)
    elseif type(subject) == "string" and key then
        expiredPattern = expiredPattern or (AUCTION_EXPIRED_MAIL_SUBJECT and API.ChatPattern.Build(AUCTION_EXPIRED_MAIL_SUBJECT))
        if expiredPattern and subject:match(expiredPattern) then
            log.Expired(key, n)
        end
    end
end

local function OnTakeMoney(index)
    if not active then return end
    local _, _, sender, subject, money = GetInboxHeaderInfo(index)
    if IsSecret(money) or type(money) ~= "number" or money <= 0 then return end
    Classifier.Expect("mailMoney", money, MailDecision(index, sender, subject))
end

local function OnTakeItems(index, attachIndex)
    if not active then return end
    local _, _, sender, _, _, cod = GetInboxHeaderInfo(index)
    if type(cod) == "number" and cod > 0 and not IsSecret(cod) then
        Classifier.Expect("mailCod", -cod, { category = "Mail", sub = "cod", note = sender })
    end
    LogMailItems(index, attachIndex)
end

local function OnAutoLoot(index)
    OnTakeMoney(index)
    OnTakeItems(index)
end

local function OnSendMail(recipient)
    if not active then return end
    -- GetSendMailPrice() already includes the attached gold (TSM, Journalator).
    local money = GetSendMailMoney() or 0
    local total = GetSendMailPrice() or 0
    local price = total - money
    if total <= 0 then return end
    local own = Rules.IsOwnCharacter(recipient)
    Classifier.Expect("mailSend", -total, { split = {
        { category = own and "Transfer" or "Mail", sub = own and "alt" or "out", amount = -money, note = recipient },
        { category = "Mail", sub = "postage", amount = -price, note = recipient },
    } })
end

-- Auction house ------------------------------------------------------------------------
local function KeyFromLocation(location)
    local link = C_Item and C_Item.GetItemLink and C_Item.GetItemLink(location)
    return link and ItemKey.FromLink(link), link
end

local function OnPostItem(location, duration, quantity, _, buyout)
    if not active then return end
    local deposit = C_AuctionHouse.CalculateItemDeposit(location, duration, quantity) or 0
    local key, link = KeyFromLocation(location)
    local itemID = not key and C_Item.GetItemID and C_Item.GetItemID(location)
    key = key or (itemID and ("i:" .. itemID))
    if deposit > 0 then
        Classifier.Expect("ahDeposit", -deposit, { category = "AH", sub = "deposit", itemKey = key, quantity = quantity })
    end
    local unit = (type(buyout) == "number" and buyout > 0 and (quantity or 1) > 0) and buyout / (quantity or 1) or nil
    if AuctionLog() then AuctionLog().Post(key, quantity or 1, deposit, link, unit) end
end

local function OnPostCommodity(location, duration, quantity, unitPrice)
    if not active then return end
    local itemID = C_Item.GetItemID and C_Item.GetItemID(location)
    local deposit = itemID and C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity) or 0
    local key, link = KeyFromLocation(location)
    key = key or (itemID and ("i:" .. itemID))
    if deposit > 0 then
        Classifier.Expect("ahDeposit", -deposit, { category = "AH", sub = "deposit", itemKey = key, quantity = quantity })
    end
    local unit = type(unitPrice) == "number" and unitPrice or nil
    if AuctionLog() then AuctionLog().Post(key, quantity or 1, deposit, link, unit) end
end

-- Purchases: item and quantity are known at the moment of buying.
local commodity = nil   -- { itemID, quantity, total }

local function OnStartCommoditiesPurchase(itemID, quantity)
    if not active then return end
    commodity = { itemID = itemID, quantity = quantity }
end

local function OnCommodityPrice(_, _, totalPrice)
    if commodity and type(totalPrice) == "number" and not IsSecret(totalPrice) then
        commodity.total = totalPrice
    end
end

local function OnConfirmCommoditiesPurchase(itemID, quantity)
    if not active then return end
    local c = commodity
    commodity = nil
    local qty = quantity or (c and c.quantity) or 1
    -- exact total when the price update arrived, otherwise any outgoing amount
    local amount = (c and c.itemID == itemID and c.total) and -c.total or "negative"
    Classifier.Expect("ahPurchase", amount,
        { category = "AH", sub = "purchase", itemKey = itemID and ("i:" .. itemID) or nil, quantity = qty })
end

local function OnPlaceBid(auctionID, bidAmount)
    if not active or type(bidAmount) ~= "number" then return end
    local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
    local key, qty, buyout
    if info then
        key = info.itemLink and ItemKey.FromLink(info.itemLink) or (info.itemKey and info.itemKey.itemID and ("i:" .. info.itemKey.itemID))
        qty = info.quantity or 1
        buyout = info.buyoutAmount
    end
    local isBuyout = buyout == nil or bidAmount >= buyout
    Classifier.Expect("ahPurchase", -bidAmount,
        { category = "AH", sub = isBuyout and "purchase" or "bid", itemKey = key, quantity = qty })
end

local function OnCancelAuction(auctionID)
    if not active or not AuctionLog() then return end
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and info.auctionID == auctionID then
            local key = info.itemLink and ItemKey.FromLink(info.itemLink) or (info.itemKey and ("i:" .. info.itemKey.itemID))
            AuctionLog().Cancel(key, info.quantity or 1)
            return
        end
    end
end

-- Flight master: the taxi map closes before the gold is taken, so the context is
-- gone when PLAYER_MONEY fires; the hook announces the cost (Journalator pattern).
local function OnTakeTaxiNode(slot)
    if not active or not TaxiNodeCost then return end
    if TaxiNodeGetType and TaxiNodeGetType(slot) ~= "REACHABLE" then return end
    local cost = TaxiNodeCost(slot)
    if type(cost) ~= "number" or cost <= 0 then return end
    Classifier.Expect("taxi", -cost, { category = "Other", sub = "taxi", note = TaxiNodeName and TaxiNodeName(slot) or nil })
end

-- Quests: world quests complete without a quest window and the client books the
-- gold before QUEST_TURNED_IN; a late event reclassifies the booking.
local function OnQuestTurnedIn(_, questID, _, money)
    if not active or IsSecret(money) or type(money) ~= "number" or money == 0 then return end
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID) or nil
    Classifier.Reclassify(money, { category = "Quest", sub = money > 0 and "reward" or "cost", note = title })
end

-- Crafting orders: the commission of a fulfilled order is paid at the profession
-- window (the amount is not known in advance, only the direction).
local function OnFulfillOrder()
    if not active then return end
    local order = C_CraftingOrders and C_CraftingOrders.GetClaimedOrder and C_CraftingOrders.GetClaimedOrder()
    local note = order and (order.customerName or order.outputItemHyperlink) or nil
    Classifier.Expect("craftCommission", "positive", { category = "Crafting", sub = "commission", note = note }, 15)
end

-- Loot gold: the "You loot ..." / "Your share ..." chat line comes after the money.
local function OnMoneyChat(_, message)
    if not active or IsSecret(message) then return end
    Classifier.Reclassify("positive", { category = "Loot", sub = "money" })
end

-- Warband bank -------------------------------------------------------------------------
local function IsAccount(bankType)
    return Enum and Enum.BankType and bankType == Enum.BankType.Account
end

local function OnDeposit(bankType, amount)
    if active and IsAccount(bankType) and type(amount) == "number" then
        Classifier.Expect("warbank", -amount, { category = "Transfer", sub = "warbank" })
    end
end

local function OnWithdraw(bankType, amount)
    if active and IsAccount(bankType) and type(amount) == "number" then
        Classifier.Expect("warbank", amount, { category = "Transfer", sub = "warbank" })
    end
end

-- Trade -----------------------------------------------------------------------------------
function Monitors.TradePartner()
    return trade and trade.partner
end

local function RefreshTradeMoney()
    if not trade then return end
    trade.moneyIn = GetTargetTradeMoney() or trade.moneyIn
    trade.moneyOut = (GetPlayerTradeMoney and GetPlayerTradeMoney()) or trade.moneyOut
end

local function OnTradeEvent(event, _, message)
    if event == "TRADE_SHOW" then
        trade = { partner = GetUnitName("NPC", true), moneyIn = 0, moneyOut = 0 }
    elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        RefreshTradeMoney()
    elseif event == "UI_INFO_MESSAGE" and trade then
        if IsSecret(message) then return end
        if message == ERR_TRADE_COMPLETE then
            local done = trade
            trade = nil
            Classifier.TradeComplete(done)
        elseif message == ERR_TRADE_CANCELLED then
            trade = nil
        end
    end
end

local function OnSetTradeMoney(copper)
    if active and trade and type(copper) == "number" then trade.moneyOut = copper end
end

function Monitors.Enable(module)
    ledger = module
    active = true
    if not hooked then
        hooked = true
        Hook(_G, "RepairAllItems", OnRepairAll)
        Hook(_G, "TakeInboxMoney", OnTakeMoney)
        Hook(_G, "TakeInboxItem", OnTakeItems)
        Hook(_G, "AutoLootMailItem", OnAutoLoot)
        Hook(_G, "SendMail", OnSendMail)
        Hook(_G, "TakeTaxiNode", OnTakeTaxiNode)
        Hook(_G, "SetTradeMoney", OnSetTradeMoney)
        if C_TradeInfo then Hook(C_TradeInfo, "SetTradeMoney", OnSetTradeMoney) end
        Hook(C_AuctionHouse, "PostItem", OnPostItem)
        Hook(C_AuctionHouse, "PostCommodity", OnPostCommodity)
        Hook(C_AuctionHouse, "CancelAuction", OnCancelAuction)
        Hook(C_AuctionHouse, "StartCommoditiesPurchase", OnStartCommoditiesPurchase)
        Hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", OnConfirmCommoditiesPurchase)
        Hook(C_AuctionHouse, "PlaceBid", OnPlaceBid)
        if C_CraftingOrders then Hook(C_CraftingOrders, "FulfillOrder", OnFulfillOrder) end
        Hook(C_Bank, "DepositMoney", OnDeposit)
        Hook(C_Bank, "WithdrawMoney", OnWithdraw)
    end
    module:RegisterEvent("UPDATE_INVENTORY_DURABILITY", OnDurability)
    module:RegisterEvent("MAIL_FAILED", function() Classifier.Cancel("mailSend") end)
    module:RegisterEvent("QUEST_TURNED_IN", OnQuestTurnedIn)
    module:RegisterEvent("CHAT_MSG_MONEY", OnMoneyChat)
    module:RegisterEvent("COMMODITY_PRICE_UPDATED", OnCommodityPrice)
    module:RegisterEvent("COMMODITY_PURCHASE_FAILED", function() Classifier.Cancel("ahPurchase") end)
    for _, event in ipairs({ "TRADE_SHOW", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE" }) do
        module:RegisterEvent(event, OnTradeEvent)
    end
end

function Monitors.Disable()
    active = false
    trade = nil
end
