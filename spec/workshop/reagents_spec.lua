local fake = require("spec.support.sources")

describe("Workshop: recipes and reagents", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local wns

    before_each(function()
        local ns
        ns, wns = load_workshop({ before = function()
            WoWMock.recipes[100] = {
                name = "Potion", profession = "Alchemy", qualityItemIDs = { 501, 502 },
                schematic = { reagentSlotSchematics = {
                    { reagentType = 1, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 11 } } },
                    { reagentType = 1, dataSlotIndex = 2, quantityRequired = 2,
                        reagents = { { itemID = 21 }, { itemID = 22 } } },               -- quality tiers
                    { reagentType = 0, dataSlotIndex = 3, quantityRequired = 1, reagents = { { itemID = 31 } } },
                } },
            }
            WoWMock.recipes[200] = { name = "Sword", profession = "Blacksmithing", qualityIDs = { 7, 8, 9 },
                outputs = { [8] = "|cffffffff|Hitem:600::::::::80:::::|h[Sword]|h|r" } }
            WoWMock.recipes[300] = { name = "Milling", isSalvage = true, profession = "Inscription",
                schematic = { quantityMax = 5, reagentSlotSchematics = {} } }
        end })
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:11"] = 100, ["i:21"] = 1000, ["i:22"] = 2000 } }))
        WoWMock.items[31] = { sellPrice = 50 }
    end)

    it("reads recipe facts and the output item per quality", function()
        local info = wns.Recipes.Info(100)
        assert.equals("Potion", info.name)
        assert.equals("Alchemy", info.profession)
        assert.equals("i:502", wns.Recipes.QualityItemKey(100, 2))
        assert.equals("i:600", wns.Recipes.QualityItemKey(200, 2))
        assert.is_nil(wns.Recipes.QualityItemKey(200, 5))
        assert.is_true(wns.Recipes.Info(300).isSalvage)
    end)

    it("rebuilds consumption from the nested call table plus uncovered basic slots", function()
        local consumed = wns.Reagents.Consumed({ recipeID = 100, reagents = {
            { reagent = { itemID = 21 }, quantity = 1, dataSlotIndex = 2 },
            { reagent = { itemID = 22 }, quantity = 1, dataSlotIndex = 2 },
        } }, 4)
        assert.same({ ["i:11"] = 12, ["i:21"] = 4, ["i:22"] = 4 }, consumed)   -- optional slot 3 not chosen
    end)

    it("keeps basic slots whose dataSlotIndex repeats a quality slot's index", function()
        -- in game (recipe 1291694) dataSlotIndex restarts per slot data type: the
        -- basic reagents without quality tiers share indexes 1 and 2 with quality reagents
        WoWMock.recipes[400] = { name = "Enchant", profession = "Enchanting",
            schematic = { reagentSlotSchematics = {
                { reagentType = 1, dataSlotIndex = 1, quantityRequired = 5, reagents = { { itemID = 41 } } },
                { reagentType = 1, dataSlotIndex = 2, quantityRequired = 4, reagents = { { itemID = 42 } } },
                { reagentType = 1, dataSlotIndex = 1, quantityRequired = 20,
                    reagents = { { itemID = 43 }, { itemID = 44 } } },
                { reagentType = 1, dataSlotIndex = 2, quantityRequired = 10,
                    reagents = { { itemID = 45 }, { itemID = 46 } } },
            } } }
        local consumed = wns.Reagents.Consumed({ recipeID = 400, reagents = {
            { reagent = { itemID = 43 }, quantity = 20, dataSlotIndex = 1 },
            { reagent = { itemID = 46 }, quantity = 10, dataSlotIndex = 2 },
        } }, 1)
        assert.same({ ["i:41"] = 5, ["i:42"] = 4, ["i:43"] = 20, ["i:46"] = 10 }, consumed)
    end)

    it("uses the salvage quantity and removes customer reagents of an order", function()
        assert.same({ ["i:900"] = 15 }, wns.Reagents.Consumed({ recipeID = 300, salvageItemID = 900 }, 3))
        local order = { reagents = {
            { source = 0, reagentInfo = { reagent = { itemID = 11 }, quantity = 3 } },
            { source = 2, reagentInfo = { reagent = { itemID = 21 }, quantity = 2 } },  -- crafter supplied
        } }
        local consumed = wns.Reagents.Consumed({ recipeID = 100, reagents = {
            { reagent = { itemID = 21 }, quantity = 2, dataSlotIndex = 2 } } }, 1, order)
        assert.same({ ["i:21"] = 2 }, consumed)
    end)

    it("leaves out whole customer slots, whatever quality the customer supplied", function()
        -- the client drops customer slots from the call; the schematic would fill in quality 1
        local order = { reagents = {
            { source = 0, slotIndex = 1, reagentInfo = { reagent = { itemID = 11 }, quantity = 3 } },
            { source = 0, slotIndex = 2, reagentInfo = { reagent = { itemID = 22 }, quantity = 2 } },
        } }
        assert.same({}, wns.Reagents.Consumed({ recipeID = 100, reagents = {} }, 1, order))
        -- the call still lists the customer's quality 2 item
        assert.same({}, wns.Reagents.Consumed({ recipeID = 100, reagents = {
            { reagent = { itemID = 22 }, quantity = 2, dataSlotIndex = 2 } } }, 1, order))
        -- only the item is known (no slot index): the quality variant still marks the slot
        local byItem = { reagents = { { source = 0, reagentInfo = { reagent = { itemID = 22 }, quantity = 2 } } } }
        assert.same({ ["i:11"] = 3 }, wns.Reagents.Consumed({ recipeID = 100, reagents = {} }, 1, byItem))
        -- every order reagent is the customer's, whatever its source value
        local unknownSource = { reagents = { { source = 7, slotIndex = 2, reagentInfo = { reagent = { itemID = 22 }, quantity = 2 } } } }
        assert.same({ ["i:11"] = 3 }, wns.Reagents.Consumed({ recipeID = 100, reagents = {
            { reagent = { itemID = 22 }, quantity = 2, dataSlotIndex = 2 } } }, 1, unknownSource))
    end)

    it("normalises the known reagent shapes", function()
        assert.equals(5, (wns.Reagents.Entry({ reagent = { itemID = 5 }, quantity = 1 })))
        assert.equals(6, (wns.Reagents.Entry({ reagentInfo = { reagent = { reagent = { itemID = 6 } }, quantity = 2 } })))
        assert.equals(7, (wns.Reagents.Entry({ itemID = 7, quantity = 1 })))
        assert.is_nil((wns.Reagents.Entry({ reagent = { itemID = 0 } })))
    end)

    it("counts resourcefulness once per operation and prices the reagents", function()
        local returned = wns.Reagents.Returned({
            { operationID = 1, resourcesReturned = { { reagent = { itemID = 11 }, quantity = 2 } } },
            { operationID = 1, resourcesReturned = { { reagent = { itemID = 11 }, quantity = 2 } } },
            { operationID = 2, resourcesReturned = { { reagent = { itemID = 21 }, quantity = 1 } } },
        })
        assert.same({ ["i:11"] = 2, ["i:21"] = 1 }, returned)
        local lines, total, saved, incomplete = wns.Reagents.Cost({ ["i:11"] = 12, ["i:21"] = 4, ["i:31"] = 1,
            ["i:99"] = 1 }, returned)
        assert.equals(12 * 100 + 4 * 1000 + 50 - saved, total)
        assert.equals(2 * 100 + 1000, saved)
        assert.is_true(incomplete)                -- i:99 has no price
        assert.equals("i:21", lines[1].key)
    end)

    it("values resourcefulness returns fully, even when they were not counted as consumed", function()
        local _, total, saved = wns.Reagents.Cost({ ["i:11"] = 3 }, { ["i:11"] = 1, ["i:21"] = 1 })
        assert.equals(1100, saved)
        assert.equals(300 - 1100, total)
    end)
end)
