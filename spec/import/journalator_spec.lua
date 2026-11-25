-- M8: Journalator archive into the Ledger; TSM followed by Journalator without duplicates.
describe("Import: Journalator", function()
    after_each(function()
        _G.JOURNALATOR_ARCHIVE, _G.TradeSkillMasterDB = nil, nil
        assert.same({}, WoWMock.errors)
    end)

    local LINK = "|cffffffff|Hitem:2589::::::::80:::::|h[Linen Cloth]|h|r"
    local _, ins, mods
    local now

    local function encode(sections)
        local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
        return LD:EncodeForPrint(LD:CompressDeflate(LS:Serialize(sections)))
    end

    before_each(function()
        _, ins, mods = load_import({ before = function(core)
            core.coreDB.root.chars["Alt-Blackrock"] = { name = "Alt" }
        end })
        now = WoWMock.now
        local src = { character = "xLN", realm = "Blackrock", faction = "Horde" }
        local function at(offset) return now + offset end
        _G.JOURNALATOR_ARCHIVE = { stores = { SometimesLocked = {
            ["Logs-1"] = { timestamp = 1, version = 1, data = encode({
                Invoices = {
                    { invoiceType = "seller", itemName = "Linen Cloth", itemLink = LINK, playerName = "Buyer", value = 10000,
                        consignment = 500, deposit = 60, count = 5, time = at(-86400), source = src },
                    { invoiceType = "buyer", itemName = "Linen Cloth", itemLink = LINK, value = 3000, count = 10,
                        time = at(-3 * 86400), source = src },
                },
                Posting = { { itemName = "Linen Cloth", itemLink = LINK, count = 5, deposit = 60, buyout = 10000,
                    time = at(-2 * 86400), source = src } },
                Failures = { { failedType = "expired", itemName = "Linen Cloth", itemLink = LINK, count = 3,
                    time = at(-50000), source = src } },
            }) },
            ["Logs-2"] = { timestamp = 2, version = 1, data = encode({
                Vendoring = {
                    { vendorType = "sell", unitPrice = 5, count = 20, itemLink = LINK, time = at(-40000), source = src },
                    -- Journalator calls vendor buys "purchase" and "buyback"; the unit price
                    -- is price / stack size and can be fractional
                    { vendorType = "purchase", unitPrice = 2500 / 3, count = 4, itemLink = LINK, time = at(-39000),
                        source = src },
                    { vendorType = "buyback", unitPrice = 5, count = 20, itemLink = LINK, time = at(-38000), source = src },
                },
                VendorRepairs = { { money = 20484, time = at(-5000), source = src } },
                Questing = { { rewardMoney = 341600, questName = "Arena", time = at(-4800), source = src } },
                LootContainers = { { money = 55, time = at(-4700), source = src }, { money = 0, time = at(-4600), source = src } },
                BasicMailReceived = { { money = 5000, sender = "Alt", time = at(-4500), source = src },
                    { money = 777, sender = "Friend", time = at(-4400), source = src } },
                BasicMailSent = { { money = 5000, sendCost = 30, recipient = "Alt", time = at(-4300), source = src } },
                Trades = { { moneyIn = 0, moneyOut = 5000000, player = "Piluya", time = at(-4200), source = src } },
                Fulfilling = { { tipAmount = 1256049, consortiumCut = 62802, playerName = "Decimus", time = at(-4100), source = src } },
                CraftingOrdersPlaced = { { postingFee = 200000, tipAmount = 5000000, time = at(-4000), source = src } },
                Taxis = { { money = 48000, time = at(-3900), source = src } },
                TrainingCosts = { { money = 2000000, time = at(-3800), source = src } },
            }) },
            ["22612386-meta"] = { timestamp = 3, version = 1, data = encode({ index = true }) },
        } } }
    end)

    local function build()
        local batch
        ins.Journalator.Read(function(b) batch = b end)
        WoWMock.flush(20)
        return batch
    end

    it("decodes every log store in a job and maps every section", function()
        assert.is_true(ins.Journalator.Available())
        assert.equals(2, #ins.Journalator.Stores(_G.JOURNALATOR_ARCHIVE))
        local batch = build()
        local by = {}
        for _, e in ipairs(batch.entries) do by[e.category .. "/" .. e.sub .. "/" .. e.amount] = e end
        assert.is_table(by["AH/sale/9560"])                         -- value - consignment + deposit
        assert.equals("i:2589", by["AH/sale/9560"].itemKey)
        assert.equals("xLN-Blackrock", by["AH/sale/9560"].char)
        assert.is_table(by["AH/purchase/-3000"])
        assert.is_table(by["AH/deposit/-60"])
        assert.is_table(by["Vendor/sell/100"])
        assert.is_table(by["Vendor/buy/-3333"])                     -- purchase, rounded to copper
        assert.is_table(by["Vendor/buy/-100"])                      -- buyback
        assert.is_table(by["Repair/repair/-20484"])
        assert.is_table(by["Quest/reward/341600"])
        assert.is_table(by["Loot/money/55"])
        assert.is_table(by["Transfer/alt/5000"])
        assert.is_table(by["Mail/in/777"])
        assert.is_table(by["Transfer/alt/-5000"])
        assert.is_table(by["Mail/postage/-30"])
        assert.is_table(by["Other/trade/-5000000"])
        assert.is_table(by["Crafting/commission/1193247"])
        assert.is_table(by["Crafting/fee/-5200000"])
        assert.is_table(by["Other/taxi/-48000"])
        assert.is_table(by["Other/trainer/-2000000"])
        assert.equals(18, #batch.entries)                           -- loot without money is skipped
        local kinds = {}
        for _, e in ipairs(batch.events) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
        assert.same({ sale = 1, purchase = 1, post = 1, expired = 1 }, kinds)
    end)

    it("adds nothing TSM already imported", function()
        _G.TradeSkillMasterDB = {
            ["r@Blackrock@internalData@csvSales"] = "itemString,stackSize,quantity,price,otherPlayer,player,time,source\n"
                .. "i:2589,5,5,1900,Buyer,xLN," .. (now - 86400) .. ",Auction",
            ["r@Blackrock@internalData@csvExpense"] = "type,amount,otherPlayer,player,time\n"
                .. "Repair Bill,20484,Merchant,xLN," .. (now - 5000),
        }
        local results
        ins.Import.RunAll(function(r) results = r end)
        WoWMock.flush(20)
        assert.equals(2, results.tsm.added)
        assert.equals(16, results.journalator.added)
        assert.equals(2, results.journalator.duplicates)
        assert.equals(2, #ins.Import.List())
        local sales = 0
        for _, r in ipairs(mods.ledger.Store.Query({ category = "AH" })) do if r.sub == "sale" then sales = sales + 1 end end
        assert.equals(1, sales)
    end)
end)
