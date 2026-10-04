-- Schema 2 repair: auction sales that "open all" booked as Mail before the
-- classifier fix are split back into AH/sale bookings (in-game finding, M7).
describe("Ledger: repair of merged mail bookings", function()
    local lns

    before_each(function() lns = select(2, load_ledger()) end)

    local function root(tx, events, deposits)
        return { tx = { ["2026-09-25"] = tx }, ah = { events = events, deposits = deposits or {} } }
    end

    it("splits a Mail booking into the logged sales and keeps other mail gold", function()
        local r = root({
            { 1000, 1, "AH", "sale", 9500, "i:1", 5, nil, "Buyer" },
            { 1001, 1, "Mail", "in", 9500 + 1900 + 50 + 5000, nil, nil, nil, nil, 3 },
        }, {
            { 1000, "sale", "i:1", 5, 10000, 0, "Linen" },   -- already booked
            { 1000, "sale", "i:2", 1, 2000, 0, "Silk" },
            { 1000, "sale", "i:3", 2, 10000, 0, "Wool" },
        }, { ["i:2"] = 50 })
        assert.equals(1, lns.Repair.MergedMail(r))
        local list = r.tx["2026-09-25"]
        assert.equals(4, #list)
        assert.same({ "AH", "sale", 1900 + 50, "i:2" }, { list[2][3], list[2][4], list[2][5], list[2][6] })
        assert.same({ "AH", "sale", 9500, "i:3" }, { list[3][3], list[3][4], list[3][5], list[3][6] })
        assert.same({ "Mail", "in", 5000 }, { list[4][3], list[4][4], list[4][5] })
        local total = 0
        for i = 2, 4 do total = total + list[i][5] end
        assert.equals(9500 + 1900 + 50 + 5000, total)
    end)

    it("spreads a small rest over the sales and leaves mail with a sender alone", function()
        local r = root({
            { 2000, 1, "Mail", "in", 9530 },
            { 2000, 1, "Mail", "in", 700, nil, nil, nil, "Friend" },
        }, { { 1990, "sale", "i:3", 2, 10000, 0, "Wool" } })
        assert.equals(1, lns.Repair.MergedMail(r))
        local list = r.tx["2026-09-25"]
        assert.same({ "AH", "sale", 9530 }, { list[1][3], list[1][4], list[1][5] })
        assert.same({ "Mail", "in", 700 }, { list[2][3], list[2][4], list[2][5] })
    end)

    it("runs as the latest schema migration", function()
        assert.equals(3, GoblinomicsLedgerDB._schema)
    end)
end)

-- Schema 3 repair: auction sales without an item key showed the buyer only.
describe("Ledger: repair of sales without an item key", function()
    local lns

    before_each(function()
        lns = select(2, load_ledger())
        WoWMock.items[222] = { name = "Weavercloth Bag", link = "|cff1eff00|Hitem:222::::::::80:::::|h[Weavercloth Bag]|h|r" }
    end)

    local function root(tx, events, names)
        return { tx = { ["2026-10-01"] = tx }, ah = { events = events, deposits = {}, names = names or {} } }
    end

    it("takes the key from the logged sale's name (posting log, else item cache)", function()
        local r = root({
            { 1000, 1, "AH", "sale", 9500, nil, 1, nil, "Buyer" },
            { 2000, 1, "AH", "sale", 4750, nil, 1, nil, "Other" },
        }, {
            { 1000, "sale", nil, 1, 10000, 0, "Linen Cloth" },
            { 1999, "sale", nil, 1, 5000, 0, "Weavercloth Bag" },
        }, { ["Linen Cloth"] = "i:2589" })
        assert.equals(2, lns.Repair.SaleKeys(r))
        local list = r.tx["2026-10-01"]
        assert.equals("i:2589", list[1][6])
        assert.equals("i:222", list[2][6])
        assert.equals("i:222", r.ah.events[2][3])
    end)

    it("puts the name into the note when no key is known", function()
        local r = root({ { 1000, 1, "AH", "sale", 9500, nil, 1, nil, "Buyer" } },
            { { 1000, "sale", nil, 1, 10000, 0, "Unknown Thing" } })
        assert.equals(1, lns.Repair.SaleKeys(r))
        assert.equals("Unknown Thing (Buyer)", r.tx["2026-10-01"][1][9])
    end)

    it("repairs merged sales only when all of them have the same name", function()
        local r = root({
            { 1050, 1, "AH", "sale", 14250, nil, 1, nil, "A", 2 },
            { 3050, 1, "AH", "sale", 14250, nil, 1, nil, "C", 2 },
        }, {
            { 1000, "sale", nil, 1, 10000, 0, "Weavercloth Bag" },
            { 1040, "sale", nil, 1, 5000, 0, "Weavercloth Bag" },
            { 3000, "sale", nil, 1, 10000, 0, "Weavercloth Bag" },
            { 3040, "sale", nil, 1, 5000, 0, "Linen Cloth" },
        })
        assert.equals(1, lns.Repair.SaleKeys(r))
        local list = r.tx["2026-10-01"]
        assert.same({ "i:222", 2 }, { list[1][6], list[1][7] })
        assert.is_nil(list[2][6])
        assert.equals("C", list[2][9])
    end)
end)
