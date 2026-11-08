-- WoW: Forever (interface 16xxx, project Camelot) passes the client gate like
-- Midnight 12.1+; clients before 12.1 stay blocked. Core/Flavor.lua tells the
-- core and the modules which client runs.
describe("Core: client gate and flavor", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("runs on Midnight 12.1 as retail", function()
        local ns = load_core()
        assert.is_nil(GOBLINOMICS_CLIENT_BLOCKED)
        assert.equals("retail", ns.Flavor.id)
        assert.is_true(ns.API.Flavor.IsRetail())
        assert.is_false(ns.API.Flavor.IsForever())
    end)

    it("runs on WoW: Forever and reports the flavor", function()
        local ns = load_core({ client = "forever" })
        assert.is_nil(GOBLINOMICS_CLIENT_BLOCKED)
        assert.is_table(Goblinomics)
        assert.equals("forever", ns.Flavor.id)
        assert.is_true(ns.API.Flavor.IsForever())
        assert.is_false(ns.API.Flavor.IsRetail())
    end)

    it("recognises Forever by the interface range alone", function()
        local ns = load_core({ client = 16001 })
        assert.is_nil(GOBLINOMICS_CLIENT_BLOCKED)
        assert.is_true(ns.Flavor.IsForever())
    end)

    it("blocks the suite on a client before 12.1", function()
        local ns = load_core({ client = 110007 })
        assert.is_true(GOBLINOMICS_CLIENT_BLOCKED)
        assert.is_nil(Goblinomics)
        assert.is_nil(ns.Flavor)
    end)

    it("stays blocked on an old client that knows no Camelot constant", function()
        local ns = load_core({ client = 110007, prepare = function()
            _G.WOW_PROJECT_CAMELOT = nil
            _G.WOW_PROJECT_ID = nil
        end })
        assert.is_true(GOBLINOMICS_CLIENT_BLOCKED)
        assert.is_nil(ns.Flavor)
    end)
end)
