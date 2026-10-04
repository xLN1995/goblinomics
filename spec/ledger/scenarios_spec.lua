-- M4 acceptance: every scenario books exactly the expected transactions, each money
-- movement once (no double booking between loot, vendor and mail).
local LINEN = "|cffffffff|Hitem:2589::::::::80:::::|h[Linen Cloth]|h|r"

local ns, lns, booked

local function money(delta)
    WoWMock.set_money(WoWMock.money + delta)
    WoWMock.fire("PLAYER_MONEY")
end

local function open(name) WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType[name]) end
local function close(name) WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType[name]) end

local function rule(field, pattern, tag)
    table.insert(GoblinomicsLedgerDB.settings.mailRules,
        { field = field, pattern = pattern, mode = "wildcard", category = "Mail", tag = tag })
end

local SCENARIOS = {
    { "repair all at a merchant", function()
        open("Merchant"); WoWMock.repairCost = 5000; RepairAllItems(); money(-5000)
    end, { { "Repair", "repair", -5000 } } },
    { "single item repair (durability change)", function()
        open("Merchant"); WoWMock.fire("UPDATE_INVENTORY_DURABILITY"); money(-300)
    end, { { "Repair", "repair", -300 } } },
    { "vendor sale", function() open("Merchant"); money(300) end, { { "Vendor", "sell", 300 } } },
    { "vendor purchase", function() open("Merchant"); money(-200) end, { { "Vendor", "buy", -200 } } },
    { "vendor buyback", function() open("Merchant"); money(-150) end, { { "Vendor", "buy", -150 } } },
    { "loot gold solo", function() WoWMock.fire("LOOT_READY"); money(55) end, { { "Loot", "money", 55 } } },
    { "autoloot: window closed before the money arrives", function()
        WoWMock.fire("LOOT_READY"); WoWMock.fire("LOOT_CLOSED"); money(80)
    end, { { "Loot", "money", 80 } } },
    { "loot gold with the chat line after the money", function()
        money(35); WoWMock.fire("CHAT_MSG_MONEY", "You loot 35 Copper")
    end, { { "Other", "unknown", 35 } } },
    { "loot gold share in a group", function()
        WoWMock.fire("CHAT_MSG_MONEY", "Your share of the loot is 20 Copper."); money(20)
    end, { { "Loot", "money", 20 } } },
    { "quest reward", function() WoWMock.fire("QUEST_TURNED_IN", 1, 100, 1000); money(1000) end, { { "Quest", "reward", 1000 } } },
    { "quest with gold cost", function() WoWMock.fire("QUEST_COMPLETE"); money(-500) end, { { "Quest", "cost", -500 } } },
    { "world quest (gold before QUEST_TURNED_IN)", function()
        money(2500); WoWMock.fire("QUEST_TURNED_IN", 70000, 100, 2500)
    end, { { "Other", "unknown", 2500 } } },
    { "auction sold (mail)", function()
        open("MailInfo")
        WoWMock.mail = { { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 9500,
            invoice = { type = "seller", itemName = "Linen Cloth", player = "Buyer", bid = 10000, count = 5 } } }
        TakeInboxMoney(1); money(9500)
    end, { { "AH", "sale", 9500 } } },
    { "auction commodity purchase with item and quantity", function()
        open("Auctioneer"); C_AuctionHouse.StartCommoditiesPurchase(2589, 10)
        WoWMock.fire("COMMODITY_PRICE_UPDATED", 700, 7000)
        C_AuctionHouse.ConfirmCommoditiesPurchase(2589, 10); money(-7000)
    end, { { "AH", "purchase", -7000 } }, { itemKey = "i:2589", quantity = 10 } },
    { "auction buyout of a single auction", function()
        open("Auctioneer")
        WoWMock.auctionInfo = { [12] = { itemLink = LINEN, quantity = 1, buyoutAmount = 3000 } }
        C_AuctionHouse.PlaceBid(12, 3000); money(-3000)
    end, { { "AH", "purchase", -3000 } }, { itemKey = "i:2589", quantity = 1 } },
    { "auction bid below buyout", function()
        open("Auctioneer")
        WoWMock.auctionInfo = { [13] = { itemLink = LINEN, quantity = 1, buyoutAmount = 9000 } }
        C_AuctionHouse.PlaceBid(13, 2000); money(-2000)
    end, { { "AH", "bid", -2000 } } },
    { "outbid refund by mail", function()
        open("MailInfo"); WoWMock.mail = { { sender = "Auction House", subject = "Outbid on Linen Cloth", money = 2000 } }
        TakeInboxMoney(1); money(2000)
    end, { { "AH", "refund", 2000 } } },
    { "auction deposit when posting", function()
        open("Auctioneer"); WoWMock.deposit = 120
        C_AuctionHouse.PostItem({ link = LINEN }, 2, 5, 0, 5000); money(-120)
    end, { { "AH", "deposit", -120 } } },
    { "auction cancel (no money movement)", function()
        open("Auctioneer"); WoWMock.auctions = { { auctionID = 7, itemLink = LINEN, itemID = 2589, quantity = 5 } }
        C_AuctionHouse.CancelAuction(7)
    end, {} },
    { "auction expired mail (item only)", function()
        open("MailInfo")
        WoWMock.mail = { { sender = "Auction House", subject = "Auction expired: Linen Cloth", items = { { LINEN, 5 } } } }
        AutoLootMailItem(1)
    end, {} },
    { "gold from an own alt", function()
        open("MailInfo"); WoWMock.mail = { { sender = "Alt", subject = "", money = 50000 } }
        TakeInboxMoney(1); money(50000)
    end, { { "Transfer", "alt", 50000 } } },
    { "gold to an own alt with postage", function()
        open("MailInfo"); WoWMock.sendMail = { money = 10000, price = 10030, cod = 0 }
        SendMail("Alt", "gold", ""); money(-10030)
    end, { { "Transfer", "alt", -10000 }, { "Mail", "postage", -30 } } },
    { "gold to another player", function()
        open("MailInfo"); WoWMock.sendMail = { money = 5000, price = 5030, cod = 0 }
        SendMail("Stranger", "gold", ""); money(-5030)
    end, { { "Mail", "out", -5000 }, { "Mail", "postage", -30 } } },
    { "postage only (items)", function()
        open("MailInfo"); WoWMock.sendMail = { money = 0, price = 60, cod = 0 }
        SendMail("Stranger", "items", ""); money(-60)
    end, { { "Mail", "postage", -60 } } },
    { "COD payment", function()
        open("MailInfo"); WoWMock.mail = { { sender = "Seller", subject = "COD", cod = 2500, items = { { LINEN, 1 } } } }
        TakeInboxItem(1, 1); money(-2500)
    end, { { "Mail", "cod", -2500 } } },
    { "boost mail GP191 by subject rule", function()
        rule("subject", "GP*", "Boosting"); open("MailInfo")
        WoWMock.mail = { { sender = "Booster", subject = "GP191", money = 100000 } }
        TakeInboxMoney(1); money(100000)
    end, { { "Mail", "in", 100000, "Boosting" } } },
    { "PayOut mail by sender rule", function()
        rule("sender", "PayOut*", "Boosting"); open("MailInfo")
        WoWMock.mail = { { sender = "PayOutBank", subject = "Week 38", money = 250000 } }
        TakeInboxMoney(1); money(250000)
    end, { { "Mail", "in", 250000, "Boosting" } } },
    { "open all: several auction sales arrive as one money change", function()
        open("MailInfo")
        WoWMock.mail = {
            { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 9500,
                invoice = { type = "seller", itemName = "Linen Cloth", player = "A", bid = 10000, count = 5 } },
            { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1900,
                invoice = { type = "seller", itemName = "Linen Cloth", player = "B", bid = 2000, count = 1 } },
            { sender = "Friend", subject = "Gift", money = 300 },
        }
        AutoLootMailItem(1); AutoLootMailItem(2); AutoLootMailItem(3); money(9500 + 1900 + 300)
    -- sales without an item key keep name and buyer apart instead of merging
    end, { { "AH", "sale", 9500 }, { "AH", "sale", 1900 }, { "Mail", "in", 300 } } },
    { "open all: expected sales that fit, the rest from the context", function()
        open("MailInfo")
        WoWMock.mail = {
            { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 9500,
                invoice = { type = "seller", itemName = "Linen Cloth", player = "A", bid = 10000, count = 5 } },
            { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1900,
                invoice = { type = "seller", itemName = "Linen Cloth", player = "B", bid = 2000, count = 1 } },
        }
        AutoLootMailItem(1); AutoLootMailItem(2); money(9500 + 1900 + 40)
    end, { { "AH", "sale", 9500 }, { "AH", "sale", 1900 }, { "Mail", "in", 40 } } },
    { "plain mail with gold", function()
        open("MailInfo"); WoWMock.mail = { { sender = "Friend", subject = "Gift", money = 777 } }
        AutoLootMailItem(1); money(777)
    end, { { "Mail", "in", 777 } } },
    { "warbank deposit", function()
        open("Banker"); C_Bank.DepositMoney(Enum.BankType.Account, 1000)
        money(-1000); WoWMock.warband = WoWMock.warband + 1000; WoWMock.fire("ACCOUNT_MONEY")
    end, { { "Transfer", "warbank", -1000 }, { "Transfer", "warband", 1000 } } },
    { "warbank withdrawal", function()
        open("Banker"); C_Bank.WithdrawMoney(Enum.BankType.Account, 500)
        money(500); WoWMock.warband = WoWMock.warband - 500; WoWMock.fire("ACCOUNT_MONEY")
    end, { { "Transfer", "warbank", 500 }, { "Transfer", "warband", -500 } } },
    { "trade gold in (money before completion)", function()
        WoWMock.fire("TRADE_SHOW"); WoWMock.trade.moneyIn = 20000; WoWMock.fire("TRADE_MONEY_CHANGED")
        money(20000); WoWMock.fire("UI_INFO_MESSAGE", 0, ERR_TRADE_COMPLETE); WoWMock.fire("TRADE_CLOSED")
    end, { { "Other", "trade", 20000 } } },
    { "trade gold out (completion before money)", function()
        WoWMock.fire("TRADE_SHOW"); SetTradeMoney(5000)
        WoWMock.fire("UI_INFO_MESSAGE", 0, ERR_TRADE_COMPLETE); WoWMock.fire("TRADE_CLOSED"); money(-5000)
    end, { { "Other", "trade", -5000 } } },
    { "flight master", function() open("TaxiNode"); money(-80) end, { { "Other", "taxi", -80 } } },
    { "flight master, map already closed when the gold is taken", function()
        open("TaxiNode"); WoWMock.taxiCost = 12000; TakeTaxiNode(3); close("TaxiNode"); money(-12000)
    end, { { "Other", "taxi", -12000 } } },
    { "trainer", function() open("Trainer"); money(-1000) end, { { "Other", "trainer", -1000 } } },
    { "transmogrification", function() open("Transmogrifier"); money(-2000) end, { { "Other", "transmog", -2000 } } },
    { "crafting order commission mail", function()
        open("MailInfo"); WoWMock.mail = { { sender = "Artisans Consortium", subject = "Order", money = 4000,
            craftingOrder = { commissionPaid = 4000, crafterName = "xLN" } } }
        TakeInboxMoney(1); money(4000)
    end, { { "Crafting", "commission", 4000 } } },
    { "crafting order fee", function() open("ProfessionsCustomerOrder"); money(-250) end, { { "Crafting", "fee", -250 } } },
    { "fulfilled crafting order (hook)", function()
        WoWMock.claimedOrder = { customerName = "Customer", tipAmount = 5000 }
        C_CraftingOrders.FulfillOrder(1, "", 0); money(4500)
    end, { { "Crafting", "commission", 4500 } } },
    { "fulfilled crafting order (profession window only)", function()
        WoWMock.fire("TRADE_SKILL_SHOW"); money(4500)
    end, { { "Crafting", "commission", 4500 } } },
    { "gold during Mythic+ (restricted replay)", function()
        local T = Enum.AddOnRestrictionType.ChallengeMode
        WoWMock.restricted[T] = true; WoWMock.fire("ADDON_RESTRICTION_STATE_CHANGED", T, 2)
        money(777)
        WoWMock.restricted[T] = nil; WoWMock.fire("ADDON_RESTRICTION_STATE_CHANGED", T, 0)
        WoWMock.flush()
    end, { { "Loot", "instance", 777 } } },
    { "unknown context", function() money(1) end, { { "Other", "unknown", 1 } } },
}

describe("Ledger acceptance scenarios", function()
    before_each(function()
        ns, lns = load_ledger({ before = function()
            GoblinomicsDB.chars["Alt-Blackrock"] = { name = "Alt" }
            WoWMock.warband = 1000000
        end })
        booked = {}
        ns.Bus.On("LEDGER_TRANSACTION", function(_, p) booked[#booked + 1] = p end, "Spec")
        WoWMock.flush()
    end)

    for i, s in ipairs(SCENARIOS) do
        it(("%02d %s"):format(i, s[1]), function()
            s[2]()
            assert.equals(#s[3], #booked, "number of bookings")
            for j, expected in ipairs(s[3]) do
                local b = booked[j]
                assert.same({ expected[1], expected[2], expected[3], expected[4] }, { b.category, b.sub, b.amount, b.tag })
            end
            if s[4] then
                assert.same({ s[4].itemKey, s[4].quantity }, { booked[1].itemKey, booked[1].quantity })
            end
        end)
    end

    it("reclassifies loot gold whose chat line arrives after the money", function()
        money(35)
        WoWMock.fire("CHAT_MSG_MONEY", "You loot 35 Copper")
        local row = lns.Store.Query({})[1]
        assert.same({ "Loot", "money" }, { row.category, row.sub })
    end)

    it("does not use a window that closed more than 2 s ago", function()
        WoWMock.fire("LOOT_READY"); WoWMock.fire("LOOT_CLOSED")
        WoWMock.advance(3)
        money(10)
        assert.same({ "Other", "unknown" }, { booked[1].category, booked[1].sub })
    end)

    it("reclassifies a world quest reward booked before QUEST_TURNED_IN", function()
        money(2500)
        WoWMock.fire("QUEST_TURNED_IN", 70000, 100, 2500)
        local row = lns.Store.Query({})[1]
        assert.same({ "Quest", "reward", 2500 }, { row.category, row.sub, row.amount })
        assert.equals(1, #booked)
    end)

    it("does not reclassify after the window or with a different amount", function()
        money(100)
        WoWMock.advance(6)
        WoWMock.fire("QUEST_TURNED_IN", 1, 0, 100)
        money(200)
        WoWMock.fire("QUEST_TURNED_IN", 2, 0, 999)
        local rows = lns.Store.Query({})
        assert.equals("Other", rows[1].category)
        assert.equals("Other", rows[2].category)
    end)

    it("covers at least 30 scenarios", function()
        assert.is_true(#SCENARIOS >= 30)
    end)

    it("attaches the sold item to the vendor booking", function()
        WoWMock.bags[0] = { numSlots = 2, [1] = { itemID = 2589, hyperlink = LINEN, stackCount = 5 } }
        lns = select(2, load_ledger({ before = function() end }))
        WoWMock.bags[0] = { numSlots = 2, [1] = { itemID = 2589, hyperlink = LINEN, stackCount = 5 } }
        WoWMock.flush()
        open("Merchant")
        WoWMock.bags[0][1] = nil
        WoWMock.fire("BAG_UPDATE", 0)
        money(300)
        WoWMock.flush()
        local row = lns.Store.Query({})[1]
        assert.same({ "Vendor", "sell", "i:2589", 5 }, { row.category, row.sub, row.itemKey, row.quantity })
        close("Merchant")
    end)
end)
