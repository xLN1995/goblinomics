local ORE = "|cffffffff|Hitem:3001::::::::80:::::|h[Ore]|h|r"

describe("Flips: lots from purchases and auctions", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local fns, lns, A, Flips

    before_each(function()
        fns, lns = select(2, load_flips())
        WoWMock.items[3001] = { name = "Ore" }
        A = lns.AuctionLog
        Flips = fns.API.Flips
    end)

    local function buy(key, qty, total, char)
        lns.Store.Add({ time = WoWMock.now, char = char or "xLN-Blackrock", category = "AH", sub = "purchase",
            amount = -total, itemKey = key, quantity = qty })
    end

    local function lots() return GoblinomicsFlipsDB.lots end

    it("keeps a purchase as candidate until the item is posted", function()
        buy("i:3001", 10, 1000)
        assert.equals(1, #lots())
        assert.equals("candidate", lots()[1].state)
        assert.is_nil(Flips:ItemStats("i:3001"))   -- not a flip yet
        A.Post("i:3001", 10, 50, ORE, 150)
        assert.equals("active", lots()[1].state)
        assert.equals(10, Flips:ItemStats("i:3001").openQty)
    end)

    it("matches sales FIFO across lots with different prices, partial sales keep the lot open", function()
        buy("i:3001", 10, 1000)     -- 100 each
        buy("i:3001", 10, 2000)     -- 200 each
        A.Post("i:3001", 20, 0, ORE, 300)
        WoWMock.advance(3600)
        A.Sale("i:3001", "Ore", 15, 4500, 4275)
        assert.equals("closed", lots()[1].state)
        assert.equals("active", lots()[2].state)
        assert.equals(5, lots()[2].remaining)
        local s = Flips:ItemStats("i:3001")
        assert.equals(15, s.soldQty)
        assert.equals(10 * 100 + 5 * 200, s.cost)
        assert.equals(4275, s.revenue)
        assert.equals(4275 - 2000, s.profit)
        assert.equals(3600, s.holdTime)
        assert.equals(5, s.openQty)
        assert.equals(1000, s.openCost)
    end)

    it("ignores units without a lot (crafted or farmed stock)", function()
        buy("i:3001", 2, 200)
        A.Post("i:3001", 10, 0, ORE, 300)
        A.Sale("i:3001", "Ore", 10, 3000, 2850)
        local s = Flips:ItemStats("i:3001")
        assert.equals(2, s.soldQty)
        assert.equals(570, s.revenue)        -- 2/10 of the net
        assert.equals(200, s.cost)
    end)

    it("counts lost deposits over repost cycles and the sale rate of flip postings", function()
        buy("i:3001", 5, 500)
        A.Post("i:3001", 5, 40, ORE, 300)
        A.Expired("i:3001", 5)
        A.Post("i:3001", 5, 40, ORE, 250)
        A.Cancel("i:3001", 5)
        A.Post("i:3001", 5, 40, ORE, 200)
        A.Sale("i:3001", "Ore", 5, 1000, 950)
        local s = Flips:ItemStats("i:3001")
        assert.equals(3, lots()[1].posts)
        assert.equals(1, s.expired)
        assert.equals(1, s.cancelled)
        assert.equals(80, s.depositLost)
        assert.equals(950 - 500 - 80, s.profit)
        assert.near(1 / 3, s.saleRate, 1e-9)
    end)

    it("lets candidates expire after candidateDays without a post", function()
        buy("i:3001", 5, 500)
        WoWMock.advance(15 * 86400)
        A.Post("i:3001", 5, 0, ORE, 300)
        assert.is_false(Flips:Claims("i:3001"))
        assert.is_nil(Flips:ItemStats("i:3001"))
        fns.Retention.Run()
        assert.equals(0, #lots())
    end)

    it("leaves ignored lots out and books write-offs as loss", function()
        buy("i:3001", 5, 500)
        buy("i:3001", 4, 800)
        A.Post("i:3001", 9, 0, ORE, 300)
        fns.Store.Ignore(lots()[1].id)
        A.Sale("i:3001", "Ore", 1, 300, 285)
        assert.equals(3, lots()[2].remaining)        -- the sale took the second lot
        fns.Store.WriteOff(lots()[2].id, "vendor")
        local s = Flips:ItemStats("i:3001")
        assert.equals(285 - 200 - 600, s.profit)
        assert.equals(0, s.openQty)
    end)

    it("summarises per character of the buyer and per day", function()
        buy("i:3001", 1, 100, "Alt-Blackrock")
        buy("i:3001", 1, 100)
        A.Post("i:3001", 2, 0, ORE, 300)
        A.Sale("i:3001", "Ore", 2, 600, 570)
        local alt = Flips:Summary({ char = "Alt-Blackrock" })
        assert.equals(1, alt.totals.soldQty)
        assert.equals(1, alt.totals.items)
        local all = Flips:Summary({ days = 7 })
        assert.equals(370, all.totals.profit)
        local daily = Flips:Daily(7)
        assert.equals(1, #daily)
        assert.equals(370, daily[1].profit)
    end)

    it("tags the Ledger booking of a flip sale", function()
        buy("i:3001", 2, 200)
        A.Post("i:3001", 2, 0, ORE, 300)
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
        WoWMock.mail = { { sender = "Auction House", subject = "Auction successful", money = 570,
            invoice = { type = "seller", itemName = "Ore", player = "Buyer", bid = 600, count = 2, consignment = 30 } } }
        TakeInboxMoney(1)
        WoWMock.set_money(WoWMock.money + 570)
        WoWMock.fire("PLAYER_MONEY")
        WoWMock.flush()
        local tagged
        for _, row in ipairs(lns.API.Ledger:Query({ category = "AH" })) do
            if row.sub == "sale" then tagged = row.tag end
        end
        assert.equals("Flip", tagged)
        assert.equals(570, Flips:ItemStats("i:3001").revenue)
    end)
end)

describe("Flips: retention and backfill", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("folds old closed lots into aggregates with the same totals", function()
        local _, fns, lns = load_flips()
        lns.Store.Add({ time = WoWMock.now, char = "xLN-Blackrock", category = "AH", sub = "purchase",
            amount = -1000, itemKey = "i:3001", quantity = 10 })
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        lns.AuctionLog.Sale("i:3001", "Ore", 10, 3000, 2850)
        local before = fns.API.Flips:Summary({}).totals
        WoWMock.advance(91 * 86400)
        fns.Retention.Run()
        assert.equals(0, #GoblinomicsFlipsDB.lots)
        local after = fns.API.Flips:Summary({}).totals
        assert.equals(before.profit, after.profit)
        assert.equals(before.soldQty, after.soldQty)
        assert.equals(before.holdTime, after.holdTime)
    end)

    it("replays the Ledger history once on the first enable", function()
        local _, fns, lns = load_flips()
        WoWMock.flush()
        lns.Store.Add({ time = WoWMock.now, char = "xLN-Blackrock", category = "AH", sub = "purchase",
            amount = -1000, itemKey = "i:3001", quantity = 10 })
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        lns.AuctionLog.Sale("i:3001", "Ore", 10, 3000, 2850)
        -- as if Flips had been switched on only now
        GoblinomicsFlipsDB.lots = {}
        GoblinomicsFlipsDB.backfilled = nil
        fns.Backfill.Run()
        WoWMock.flush()
        local s = fns.API.Flips:ItemStats("i:3001")
        assert.equals(10, s.soldQty)
        assert.equals(2850, s.revenue)              -- gross minus 5 % cut
        assert.equals(1850, s.profit)
        local stamp = GoblinomicsFlipsDB.backfilled
        fns.Backfill.Run()
        WoWMock.flush()
        assert.equals(stamp, GoblinomicsFlipsDB.backfilled)
        assert.equals(1, #GoblinomicsFlipsDB.lots)
    end)
end)
