describe("M7 Insights", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("is a load-on-demand tab: the core registers a placeholder that loads the addon", function()
        local ns = load_core({ boot = false })
        assert.is_nil(ns.UI.GetTab("insights"))                  -- not load-on-demand in this client
        WoWMock.reset()
        WoWMock.lod.Goblinomics_Insights = true
        WoWMock.notLoaded.Goblinomics_Insights = true
        local ns2 = {}
        for _, file in ipairs(toc_files("Goblinomics.toc")) do
            if not file:match("^Libs/") then load_addon_file(file, "Goblinomics", ns2) end
        end
        local tab = ns2.UI.GetTab("insights")
        assert.equals("Goblinomics_Insights", tab.loadAddon)
        assert.is_true(ns2.UI.EnsureTabLoaded(tab))
        assert.same({ "Goblinomics_Insights" }, WoWMock.loadedAddOns)
    end)

    describe("with data", function()
        local ns, ins, mods

        local function book(offsetDays, category, amount, extra)
            local e = { time = WoWMock.now + offsetDays * 86400, char = extra and extra.char or "xLN-Blackrock",
                category = category, sub = extra and extra.sub or "x", amount = amount }
            for k, v in pairs(extra or {}) do e[k] = v end
            return mods.ledger.Store.Add(e)
        end

        before_each(function()
            ns, ins, mods = load_insights()
            book(0, "AH", 50000, { sub = "sale", itemKey = "i:1", quantity = 2 })
            book(0, "Mail", 80000, { tag = "Boosting", char = "Alt-Blackrock" })
            book(-1, "Repair", -4000)
            book(-1, "Transfer", -30000, { sub = "warbank" })
            book(-1, "Transfer", 30000, { sub = "warband" })
            book(-2, "AH", -25000, { sub = "purchase", itemKey = "i:2", quantity = 3 })
        end)

        it("replaces the placeholder tab on load", function()
            assert.is_nil(ns.UI.GetTab("insights").loadAddon)
        end)

        it("sums income and expenses per day, without transfers", function()
            local days = ins.Data.Days(7)
            assert.equals(7, #days)
            assert.equals(130000, days[7].income)
            assert.equals(-4000, days[6].expense)
            local alt = ins.Data.Days(7, "Alt-Blackrock")
            assert.equals(80000, alt[7].income)
        end)

        it("lists top incomes and expenses, auction house by item", function()
            local incomes, expenses = ins.Data.Top(7)
            assert.equals("Boosting", incomes[1].label)
            assert.equals("i:1", incomes[2].itemKey)
            assert.equals("i:2", expenses[1].itemKey)
            assert.equals(-25000, expenses[1].amount)
        end)

        it("builds the cash flow: sources to characters to sinks, deposits to the warband bank", function()
            local flow = ins.Data.Flow(7)
            local sources, sinks = {}, {}
            for _, s in ipairs(flow.sources) do sources[s.label] = s.amount end
            for _, s in ipairs(flow.sinks) do sinks[s.label] = s.amount end
            assert.equals(80000, sources.Boosting)
            assert.equals(50000, sources["Auction House"])
            assert.is_nil(sources["Warband bank"])                  -- the warband side is not a source
            assert.equals(30000, sinks["Warband bank"])
            assert.equals(80000, sinks.Kept)                        -- xLN spent more than he earned; Alt keeps 80,000
        end)

        it("cancels both sides of older warband transfers", function()
            book(-3, "Transfer", -7000, { sub = "warbank" })
            book(-3, "Transfer", 7000, { sub = "warbank" })
            local flow = ins.Data.Flow(7)
            for _, s in ipairs(flow.sinks) do
                if s.label == "Warband bank" then assert.equals(30000, s.amount) end
            end
        end)

        it("reports a day and a week", function()
            local day = ins.Data.Report("day", 0)
            assert.equals(130000, day.income)
            assert.equals("Boosting", day.incomes[1].label)
            local yesterday = ins.Data.Report("day", 1)
            assert.equals(-4000, yesterday.net)
            local week = ins.Data.Report("week", 0)
            assert.is_true(week.to - week.from >= 6 * 86400)
        end)

        it("compares the period with the same number of days before", function()
            book(-9, "Quest", 20000)
            local p = ins.Data.Period(7)
            assert.equals(130000, p.income)
            assert.equals(-29000, p.expense)
            assert.equals(20000, p.prev.income)
            assert.equals(0, p.prev.expense)
            assert.equals(550, ins.Data.Change(130000, 20000))
            assert.is_nil(ins.Data.Change(5, 0))
            local alt = ins.Data.Period(7, "Alt-Blackrock")
            assert.equals(80000, alt.income)
        end)

        it("splits a day into hours and lists its bookings newest first", function()
            local from = ins.Data.DayStart(WoWMock.now)
            local hours = ins.Data.Hours(from)
            assert.equals(24, #hours)
            local hour = tonumber(os.date("%H", WoWMock.now)) + 1
            assert.equals(130000, hours[hour].income)
            local list = ins.Data.DayBookings(from)
            assert.equals(2, #list)
            assert.is_true(list[1].time >= list[2].time)
            assert.equals(1, #ins.Data.DayBookings(from, "Alt-Blackrock"))
        end)

        it("reports per character with the previous period and the days of a week", function()
            local alt = ins.Data.Report("day", 0, "Alt-Blackrock")
            assert.equals(80000, alt.income)
            assert.is_nil(alt.wealthChange)
            local day = ins.Data.Report("day", 0)
            assert.equals(-4000, day.previous.net)
            assert.equals(24, #day.hours)
            local week = ins.Data.Report("week", 0)
            assert.equals(7, #week.days)
            assert.is_table(week.previous)
            assert.is_nil(week.previous.previous)
        end)

        it("draws the cash flow on one scale with stacked bands", function()
            local S = ins.Sankey
            local flow = ins.Data.Flow(7)
            local layout = S.Layout(flow, 700, 300)
            local k = layout.scale
            for _, column in ipairs(layout.columns) do
                for _, b in ipairs(column) do assert.is_near(b.value * k, b.height, 1e-9) end
            end
            -- bands leave every block without gaps or overlaps, in the order of their targets
            local out = {}
            for _, band in ipairs(layout.bands) do
                assert.is_near(band.amount * k, band.thickness, 1e-9)
                local list = out[band.from] or {}
                out[band.from] = list
                list[#list + 1] = band
            end
            for block, list in pairs(out) do
                local y = block.y
                for _, band in ipairs(list) do
                    assert.is_near(y, band.y0, 1e-9)
                    y = y + band.thickness
                end
                assert.is_true(y <= block.y + block.height + 1e-9)
            end
            local stripes = S.Stripes(layout.bands[1])
            assert.is_true(#stripes > 1 and #stripes <= 60)
            assert.is_near(layout.bands[1].y0, stripes[1].y, math.abs(layout.bands[1].y1 - layout.bands[1].y0) * 0.05 + 1e-9)
            -- each stripe's right edge meets the next one's left edge: no steps
            for i = 1, #stripes - 1 do assert.is_near(stripes[i].yEnd, stripes[i + 1].y, 1e-9) end
            assert.is_near(layout.bands[1].y1, stripes[#stripes].yEnd, 1e-9)
        end)

        it("bundles more than seven sources into others", function()
            local flow = { sources = {}, chars = { { label = "xLN", char = "xLN-Blackrock", income = 0, outgo = 0 } },
                sinks = {}, links = {} }
            for i = 1, 10 do
                flow.sources[i] = { label = "S" .. i, amount = 100 - i }
                flow.links[i] = { from = "S" .. i, to = "xLN", amount = 100 - i }
                flow.chars[1].income = flow.chars[1].income + 100 - i
            end
            flow.chars[1].outgo = flow.chars[1].income
            flow.sinks[1] = { label = "Kept", amount = flow.chars[1].income }
            flow.links[11] = { from = "xLN", to = "Kept", amount = flow.chars[1].income }
            local layout = ins.Sankey.Layout(flow, 700, 300)
            local sources = layout.columns[1]
            assert.equals(7, #sources)
            assert.equals("Others (4)", sources[7].label)
            assert.equals(93 + 92 + 91 + 90, sources[7].value)
            local into = 0
            for _, band in ipairs(layout.bands) do if band.to.column == 2 then into = into + band.amount end end
            assert.equals(flow.chars[1].income, into)
        end)

        it("builds every page", function()
            local tab = ns.UI.GetTab("insights")
            tab.build(CreateFrame("Frame"))
            tab.onShow()
            local UI = ins.InsightsUI
            assert.is_table(UI.Page("history"))
            UI.state.page = "flow"; UI.Refresh()
            assert.is_table(UI.Page("flow").flow)
            UI.state.page = "reports"; UI.Refresh()
            local reports = UI.Page("reports")
            assert.equals("day", reports.report.kind)
            assert.equals(2, reports.bookingCount)
            UI.state.reportKind = "week"; UI.Refresh()
            assert.equals(7, #reports.chartData)
            UI.state.char = "Alt-Blackrock"; UI.state.page = "history"; UI.Refresh()
            assert.equals(80000, UI.Page("history").period.income)
            tab.onHide()
        end)
    end)
end)
