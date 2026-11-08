describe("Gatherer: lockouts", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local pns
    local RAID = { journalID = 1296, mapID = 2769, name = "Liberation of Undermine", isRaid = true }
    local DUNGEON = { journalID = 1269, mapID = 2652, name = "The Stonevault", isRaid = false }

    before_each(function()
        pns = select(2, load_gatherer({ before = function()
            WoWMock.journal = {
                { name = "The War Within",
                    raids = { { id = 1, name = "World Bosses", areaMapID = 0 },
                        { id = 1296, name = "Liberation of Undermine", mapID = 2769, encounters = 8 } },
                    dungeons = { { id = 1269, name = "The Stonevault", mapID = 2652, encounters = 4 } } },
                { name = "Midnight", raids = { { id = 1300, name = "The Voidspire", mapID = 2900, encounters = 6 } },
                    dungeons = {} },
            }
            WoWMock.journalTier = 2
            WoWMock.savedInstances = {
                { name = "Liberation of Undermine", mapID = 2769, difficulty = 15, reset = 2 * 86400 + 4 * 3600,
                    difficultyName = "Heroic", isRaid = true, numEncounters = 8, encounterProgress = 3 },
                { name = "The Stonevault", mapID = 2652, difficulty = 23, reset = 3600, difficultyName = "Mythic",
                    numEncounters = 4, encounterProgress = 4 },
                { name = "Old", mapID = 1, difficulty = 1, reset = 3600, locked = false },
            }
        end }))
    end)

    it("lists raids and dungeons per expansion, newest first, without world bosses", function()
        local raids = pns.Instances.Catalog(true)
        assert.equals("Midnight", raids[1].name)
        assert.equals("The War Within", raids[2].name)
        assert.equals(1, #raids[2].instances)
        assert.same({ journalID = 1296, mapID = 2769, name = "Liberation of Undermine", isRaid = true },
            raids[2].instances[1])
        local dungeons = pns.Instances.Catalog(false)
        assert.equals(1, #dungeons)
        assert.equals(2, WoWMock.journalTier)   -- the journal tier is restored
        assert.equals(8, pns.Instances.EncounterCount(1296))
    end)

    it("loads the Encounter Journal first and rebuilds the catalogue on every call", function()
        WoWMock.notLoaded.Blizzard_EncounterJournal = true
        pns.Instances.Catalog(true)
        assert.same({ "Blizzard_EncounterJournal" }, WoWMock.loadedAddOns)
        table.insert(WoWMock.journal[1].raids, { id = 1400, name = "Classic Raid", areaMapID = 0, mapID = 409 })
        local raids = pns.Instances.Catalog(true)
        assert.equals(2, #raids[2].instances)          -- no area map, but an instance map: kept
        assert.equals("Classic Raid", raids[2].instances[2].name)
    end)

    it("does not load the journal in combat", function()
        WoWMock.notLoaded.Blizzard_EncounterJournal = true
        WoWMock.combat = true
        pns.Instances.Catalog(false)
        assert.same({}, WoWMock.loadedAddOns)
    end)

    it("reports tiers and raw instance counts for diagnostics", function()
        local lines = pns.Instances.Report()
        assert.equals("journal loaded: true, tiers: 2", lines[1])
        assert.equals("1 The War Within: raids 1 (+1 skipped), dungeons 1 (+0 skipped)", lines[2])
    end)

    it("stores active lockouts with difficulty and map ID plus level and class", function()
        WoWMock.fire("UPDATE_INSTANCE_INFO")
        local c = GoblinomicsGathererDB.chars["xLN-Blackrock"]
        assert.equals(2, #c.lockouts)
        assert.equals(15, c.lockouts[1].difficultyID)
        assert.equals(2769, c.lockouts[1].mapID)
        assert.equals(WoWMock.now + 2 * 86400 + 4 * 3600, c.lockouts[1].resetAt)
        assert.equals(80, c.level)
        assert.equals("WARRIOR", c.class)
    end)

    it("builds the raid grid: progress per difficulty and who can still run it", function()
        WoWMock.fire("UPDATE_INSTANCE_INFO")
        local chars = GoblinomicsGathererDB.chars
        chars["Alt-Blackrock"] = { lockoutsScanned = 1, level = 80, class = "MAGE", lockouts = {
            { name = "Liberation of Undermine", mapID = 2769, difficultyID = 14, resetAt = WoWMock.now + 600, encounters = 8,
                progress = 8 },
            { name = "Liberation of Undermine", mapID = 2769, difficultyID = 16, resetAt = WoWMock.now - 1, progress = 1 },
        } }
        chars["Low-Blackrock"] = { lockoutsScanned = 1, level = 70, lockouts = {} }   -- below max level
        chars["Never-Blackrock"] = { level = 80 }                                      -- no lockout data
        local grid = pns.Lockouts.Grid({ instance = RAID })
        assert.equals(8, grid.total)
        local ids, free = {}, {}
        for _, col in ipairs(grid.columns) do ids[#ids + 1] = col.id; free[#free + 1] = col.free end
        assert.same({ 14, 15, 16 }, ids)
        assert.same({ 1, 2, 2 }, free)           -- Alt cleared Normal; xLN is 3/8 on Heroic
        assert.equals(2, #grid.rows)
        assert.equals("Alt-Blackrock", grid.rows[1].char)
        assert.equals(8, grid.rows[1].cells[14].progress)
        assert.is_nil(grid.rows[1].cells[16])     -- expired
        assert.equals(3, grid.rows[2].cells[15].progress)
        assert.equals("|cffd9463e8/8|r", pns.Lockouts.CellText(grid.rows[1].cells[14], 8))
        assert.equals("|cffffd1003/8|r", pns.Lockouts.CellText(grid.rows[2].cells[15], 8))
        assert.equals("|cff3fbf3f0/8|r", pns.Lockouts.CellText(nil, 8))
    end)

    it("shows Mythic for dungeons and matches older records by name", function()
        WoWMock.fire("UPDATE_INSTANCE_INFO")
        local grid = pns.Lockouts.Grid({ instance = DUNGEON })
        assert.equals(1, #grid.columns)
        assert.equals(23, grid.columns[1].id)
        assert.equals(0, grid.columns[1].free)
        local byName = pns.Lockouts.Grid({ instance = { name = "the stonevault", isRaid = false } })
        assert.equals(4, byName.rows[1].cells[23].progress)
        assert.is_nil(pns.Lockouts.Grid({ instance = nil }))
    end)

    it("asks again after a boss kill and when entering the world", function()
        local before = WoWMock.raidInfoRequests
        WoWMock.fire("BOSS_KILL", 1, "Boss")
        WoWMock.fire("BOSS_KILL", 1, "Boss")
        WoWMock.advance(2)
        assert.equals(before + 1, WoWMock.raidInfoRequests)
        WoWMock.fire("PLAYER_ENTERING_WORLD")
        WoWMock.advance(3)
        assert.equals(before + 2, WoWMock.raidInfoRequests)
    end)
end)

describe("Gatherer: instance choices on WoW: Forever", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("offers every raid in one flat list, sorted by name", function()
        local pns = select(2, load_gatherer({ client = "forever", before = function()
            WoWMock.journal = {
                { name = "The War Within",
                    raids = { { id = 1, name = "World Bosses", areaMapID = 0 },
                        { id = 1296, name = "Liberation of Undermine", mapID = 2769, encounters = 8 } },
                    dungeons = { { id = 1269, name = "The Stonevault", mapID = 2652, encounters = 4 } } },
                { name = "Midnight", raids = { { id = 1300, name = "The Voidspire", mapID = 2900, encounters = 6 } },
                    dungeons = {} },
            }
            WoWMock.journalTier = 2
        end }))
        pns.FarmEditor.Open(nil)
        pns.FarmEditor.Form().category = "raid"
        assert.same({ { value = "none", label = "None" }, { value = 1296, label = "Liberation of Undermine" },
            { value = 1300, label = "The Voidspire" } }, pns.FarmEditor.InstanceChoices())
    end)
end)
