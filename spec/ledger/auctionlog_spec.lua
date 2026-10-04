local LINEN = "|cffffffff|Hitem:2589::::::::80:::::|h[Linen Cloth]|h|r"

describe("Ledger: auction log", function()
    local lns, A

    before_each(function()
        lns = select(2, load_ledger())
        A = lns.AuctionLog
        WoWMock.items[2589] = { name = "Linen Cloth", sellPrice = 13 }
    end)

    local function mailOpen()
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
    end

    it("logs posts from the hook with the item name and deposit", function()
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Auctioneer)
        WoWMock.deposit = 100
        C_AuctionHouse.PostItem({ link = LINEN }, 2, 5)
        assert.equals("i:2589", A.KeyForName("Linen Cloth"))
        assert.equals(1, A.Stats("i:2589").posted)
    end)

    describe("sales of items with the same name (qualities)", function()
        local Q1 = "|cffffffff|Hitem:3001::::::::80:::::|h[Ore]|h|r"
        local Q2 = "|cffffffff|Hitem:3002::::::::80:::::|h[Ore]|h|r"
        local events

        before_each(function()
            WoWMock.items[3001] = { name = "Ore" }
            WoWMock.items[3002] = { name = "Ore" }
            events = {}
            lns.API.On("LEDGER_AH_EVENT", function(_, p) events[#events + 1] = p end, "spec")
        end)

        local function sell(count, bid, consignment)
            mailOpen()
            WoWMock.mail = { { sender = "Auction House", subject = "Auction successful", money = bid - (consignment or 0),
                invoice = { type = "seller", itemName = "Ore", player = "Buyer", bid = bid, count = count,
                    consignment = consignment } } }
            TakeInboxMoney(1)
        end

        it("finds the quality through the posted unit price", function()
            A.Post("i:3001", 20, 0, Q1, 1000)
            A.Post("i:3002", 10, 0, Q2, 5000)
            sell(2, 10000, 500)
            local sale = events[#events]
            assert.equals("i:3002", sale.itemKey)
            assert.equals(9500, sale.net)
            assert.equals(5000, sale.unitPrice)
        end)

        it("falls back to the oldest open posting with that name", function()
            A.Post("i:3001", 5, 0, Q1, 1000)
            A.Post("i:3002", 5, 0, Q2, 5000)
            sell(1, 3000)
            assert.equals("i:3001", events[#events].itemKey)
        end)

        it("uses up postings, also through expired auctions", function()
            A.Post("i:3002", 2, 0, Q2, 5000)
            A.Post("i:3001", 2, 0, Q1, 5000)
            A.Expired("i:3002", 2)
            sell(1, 5000)
            assert.equals("i:3001", events[#events].itemKey)
        end)

        it("reads unit prices from the post hooks", function()
            WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Auctioneer)
            C_AuctionHouse.PostItem({ link = Q2 }, 2, 4, 0, 20000)
            C_AuctionHouse.PostCommodity({ link = Q1, itemID = 3001 }, 2, 10, 800)
            assert.equals(5000, GoblinomicsLedgerDB.ah.open.Ore[1].unit)
            assert.equals(800, GoblinomicsLedgerDB.ah.open.Ore[2].unit)
        end)
    end)

    describe("item auctions the log did not see posted (bags)", function()
        local BAG = "|cff1eff00|Hitem:222::::::::80:::::|h[Weavercloth Bag]|h|r"

        local function sellBag(buyer)
            mailOpen()
            WoWMock.mail = { { sender = "Auction House", subject = "Auction successful", money = 9500,
                invoice = { type = "seller", itemName = "Weavercloth Bag", player = buyer, bid = 10000, count = 1 } } }
            TakeInboxMoney(1)
        end

        it("resolves the key through the client's item cache by name", function()
            WoWMock.items[222] = { name = "Weavercloth Bag", link = BAG }
            assert.equals("i:222", A.KeyForSale("Weavercloth Bag", 1, 10000))
        end)

        it("keeps the item name next to the buyer when no key is known", function()
            local decision = lns.Monitors.MailDecision
            WoWMock.mail = { { invoice = { type = "seller", itemName = "Weavercloth Bag", player = "Buyer",
                bid = 10000, count = 1 } } }
            local d = decision(1, "Auction House", "Auction successful")
            assert.is_nil(d.itemKey)
            assert.equals("Weavercloth Bag (Buyer)", d.note)
            WoWMock.items[222] = { name = "Weavercloth Bag", link = BAG }
            d = decision(1, "Auction House", "Auction successful")
            assert.equals("i:222", d.itemKey)
            assert.equals("Buyer", d.note)
        end)

        it("logs an item posting by its item ID when the slot has no link any more", function()
            WoWMock.items[222] = { name = "Weavercloth Bag", cached = false }
            WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Auctioneer)
            C_AuctionHouse.PostItem({ itemID = 222 }, 2, 1, 0, 10000)
            assert.equals("i:222", A.KeyForName("Weavercloth Bag"))
            sellBag("Buyer")
            assert.equals(1, A.Stats("i:222").sold)
        end)
    end)

    it("links invoice sales to the item via the name and computes price and sale rate", function()
        A.Post("i:2589", 5, 100, LINEN)
        A.Post("i:2589", 5, 100, LINEN)
        A.Post("i:2589", 5, 100, LINEN)
        mailOpen()
        WoWMock.mail = { { sender = "Auction House", subject = "Auction successful", money = 9500,
            invoice = { type = "seller", itemName = "Linen Cloth", player = "Buyer", bid = 10000, count = 5 } } }
        TakeInboxMoney(1)
        A.Expired("i:2589", 5)
        A.Cancel("i:2589", 5)
        local s = A.Stats("i:2589")
        assert.equals(3, s.posted)
        assert.equals(1, s.sold)
        assert.equals(2000, s.averagePrice)
        assert.equals(1 / 3, s.saleRate)
        assert.equals(200, s.depositLost)
    end)

    it("logs expired auctions from mail and purchases from buyer invoices", function()
        A.Post("i:2589", 5, 50, LINEN)
        mailOpen()
        WoWMock.mail = {
            { sender = "Auction House", subject = "Auction expired: Linen Cloth", items = { { LINEN, 5 } } },
            { sender = "Auction House", subject = "Auction won", items = { { LINEN, 10 } },
                invoice = { type = "buyer", itemName = "Linen Cloth", bid = 3000, count = 10 } },
        }
        AutoLootMailItem(1)
        AutoLootMailItem(2)
        local s = A.Stats("i:2589")
        assert.equals(1, s.expired)
        assert.equals(50, s.depositLost)
        assert.equals(1, s.purchases)
        assert.equals(10, s.purchasedQuantity)
        assert.equals(300, s.averagePurchasePrice)
    end)

    it("limits statistics to a window in days and prunes old events", function()
        A.Sale("i:2589", "Linen Cloth", 1, 100)
        WoWMock.advance(40 * 86400)
        A.Sale("i:2589", "Linen Cloth", 1, 300)
        assert.equals(1, A.Stats("i:2589", 30).sold)
        assert.equals(2, A.Stats("i:2589").sold)
        assert.equals(WoWMock.now, A.Stats("i:2589").lastSale)
        local public = Goblinomics.API.v1.Ledger:AuctionStats("i:2589", 30)
        assert.equals(1, public.sold)
        assert.equals(WoWMock.now, public.lastSale)
        assert.is_nil(Goblinomics.API.v1.Ledger:AuctionStats("i:1"))
        A.Prune(30)
        assert.equals(1, A.Stats("i:2589").sold)
    end)

    it("records cancels from the hook", function()
        A.Post("i:2589", 5, 100, LINEN)
        WoWMock.auctions = { { auctionID = 9, itemLink = LINEN, itemID = 2589, quantity = 5 } }
        C_AuctionHouse.CancelAuction(9)
        assert.equals(1, A.Stats("i:2589").cancelled)
    end)
end)
