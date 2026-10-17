if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/ChangelogData.lua
-- Release notes shown in the "What's new" window (Core/UI/Changelog.lua), newest
-- first. Every entry mirrors a section of CHANGELOG.md with the same wording:
-- items are the bullet points joined to one line, without Markdown marks. The
-- top entry is "unreleased" until the release gives it a version and a date.
--   { version, date, intro, modules = { { addon, text } },
--     sections = { { title, items = { "..." } } } }
-- modules are new official addons (CHANGELOG.md "### New modules", one bullet
-- "Folder_Name: text" each); the window shows whether they are installed.
local _, ns = ...

ns.CHANGELOG = {
    {
        version = "unreleased",
        sections = {
            { title = "Fixed", items = {
                "The farm editor no longer picks the zone you stand in for a new farm; the zone is only the one you choose.",
                "The farm HUD shows only inside the farm's zone and no longer guides you along a route in a neighbouring zone.",
                "A running farm session ends when you log out or close the game and is saved with the time up to the logout; a /reload keeps it running.",
            } },
        },
    },
    {
        version = "1.1.0",
        date = "2026-10-14",
        modules = {
            { addon = "Goblinomics_Connector_GatherMate2", text = "Brings the gathering nodes GatherMate2 knows into your Gatherer farms, so you can pick a zone and its nodes." },
        },
        sections = {
            { title = "Added", items = {
                "A \"What's new\" window opens once after each update with the changes since the version you played last, including new modules and connectors and whether you have them installed. The main window has a footer now with the current version and a \"Changelog\" button that opens it again; so does /gob changelog.",
                "Gathering and fishing farms can have a zone and the nodes you farm there, several at once (for example ore and herbs). With GatherMate2 installed the farm editor lists the zones by expansion and the known nodes of a zone with their count.",
                "Sessions count the nodes you gather. The summary and the farm show nodes per hour and gold per node, averaged over your own runs. A farm without a run shows only how many nodes are known, without a gold estimate.",
                "\"From nodes\" in the farm editor adds the rare finds of the chosen nodes as expected highlights, learned from what those nodes gave you.",
                "Gathering farms with a zone and nodes can get a flight route. \"Create route...\" in the farm editor groups the nodes into stops that cover everything within half the minimap's view, leaves out stops far off the round, skips stops the round already passes closely and smooths sharp turns. A preview shows the round on the zone map with its length, an estimated lap time and how many nodes were left out. The route is saved with the farm and marked as out of date when the zone or the nodes change.",
                "A full-screen farm HUD for farms with a route: a radar around you, turned with your view, shows the farm's nodes, the stops and lines along the next three stops; nodes turn grey once mined or found empty on this lap. Under it the minimap's tracking points appear enlarged, so you see which nodes stand right now (needs Find Herbs or Find Minerals; can be switched off). A side panel at the session window's place (dragging either moves both) shows time, gold, nodes, your best items and the distance and time to the next three stops. You join the round at the nearest stop; reaching one of the next stops moves on. Switch it with the HUD button in the session window, a key binding or /gob farm hud, skip a stop with another key or /gob farm skip. It can also show up by itself (setting, off by default) and hides in combat, in instances and outside the farm's zone.",
            } },
            { title = "Changed", items = {
                "Lines, points and areas in the charts, the cash flow diagram and the small arrows are drawn with smooth edges now instead of pixel steps.",
                "After login, concentration and cooldowns are no longer listed in chat. A small window opens instead, with every character's concentration as a bar and its recipe cooldowns (ready, or the time left). It only opens when something is full or ready, and it waits until you are out of combat. /gob conc opens and closes it at any time.",
            } },
        },
    },
    {
        version = "1.0.2",
        date = "2026-10-04",
        sections = {
            { title = "Fixed", items = {
                "The Salvage list shows one row per disenchanted item. Copies of the same item with different stats (for example several Courtly Wrists) were listed separately.",
            } },
        },
    },
    {
        version = "1.0.1",
        date = "2026-10-04",
        sections = {
            { title = "Added", items = {
                "Disenchanting is tracked in the Workshop under Salvage. For each disenchanted item you see how often you disenchanted it, what it cost you (what you paid for it, its crafting cost, or else its market price), the dust and shards it gave, and, once those are sold, the income and profit.",
            } },
            { title = "Fixed", items = {
                "Auction sales of single items such as bags now show the item in the Ledger, not only the buyer, even when Goblinomics did not see the auction being posted. If the item can't be identified at all, its name still appears next to the buyer.",
                "Crafted items sold that way now count towards their recipe in the Workshop (revenue and profit), also when the sold copy has other bonus IDs than the crafted one.",
                "Several such sales taken at once no longer merge into one Ledger row with the first buyer's name.",
                "Existing sales are repaired once after the update where the auction log still knows the item.",
                "Items crafted by players (their link names the crafter) were not recognised at all: they were missing from bag tracking, auction postings and the Workshop's sale matching. They are now read like any other item.",
            } },
        },
    },
    {
        version = "1.0.0",
        date = "2026-10-04",
        intro = "The first stable release. Thanks to everyone who tested the betas.",
        sections = {
            { title = "Changed", items = {
                "Speculative items now start at 1000 gold per item. A cheap item that rarely sells no longer clutters the Speculative tab, the bag marks or the speculative share of your wealth. The amount can be changed under Settings > Prices.",
            } },
            { title = "Added", items = {
                "Market Pulse, a new \"Market\" tab in the Workshop: a board of the products you choose, no market scan. Put an item on it with \"+ Market\" next to a recipe in the profession window, or with \"Add item\" (shift-click or item ID). For each item you see your stock, its market price, a price trend with a small chart, your own sale rate and average sale price. Goblinomics keeps the price of these items once a day, so the chart grows over time; with TSM the trend works from day one. Items you have in stock that drop by 15 % or more are flagged, and you get a toast and a chat line about it (both can be switched off, the threshold is adjustable).",
            } },
            { title = "Fixed", items = {
                "Items from disenchanting no longer count as farmed loot in a Gatherer session. Loot from boxes and other opened items still counts.",
            } },
        },
    },
    {
        version = "0.9.2-beta",
        date = "2026-09-30",
        sections = {
            { title = "Added", items = {
                "Concentration and recipe cooldowns for all your characters, in a new \"Concentration & cooldowns\" view in the Workshop and a dashboard card. Goblinomics reads a character's concentration when you log in or open a profession window and works out from the recharge rate when it's full again, so you don't have to log in every alt to check. Cooldowns such as transmutes show when they're ready, recipes with charges show how many are back. Concentration and cooldowns have their own page each, and both can be filtered by expansion (the current one by default).",
                "Notices when a character's concentration is full (or reaches your own threshold) or a cooldown is ready: a toast while you play, a chat line after login and a line in the minimap tooltip. Each can be switched off, and single characters can be left out.",
            } },
            { title = "Changed", items = {
                "The Workshop is easier to read. Sub-tabs at the top (Overview, Recipes, Crafting orders, Salvage, Concentration & cooldowns) replace the long list on the left. Recipes are a table you can sort and search, and a click opens the details. Crafting orders and salvaged items open their details the same way; \"count an order without own cost\" is a button there now instead of a hidden right-click. The overview shows the important numbers in a few cards.",
                "Hovering a profession or cooldown shows the exact time it's full or ready, how fast it recharges and what the current concentration is worth in gold.",
            } },
        },
    },
    {
        version = "0.9.1-beta",
        date = "2026-09-28",
        sections = {
            { title = "Added", items = {
                "The Vault tab shows what your wealth is made of. Click a character or the warband bank and its items unfold below it, the most valuable first, with quantity, where they lie and what they're worth. Hover an item to see how it splits across bags, bank, mail and auctions; shift-click links it.",
            } },
            { title = "Changed", items = {
                "Speculative items need a sale rate, and only TSM has one. Without TSM the Speculative tab, the speculative share in the wealth and the related settings are hidden now instead of showing zero. Install TSM and they come back.",
            } },
            { title = "Fixed", items = {
                "Warbound items could count towards your wealth when the game hadn't loaded their data yet during a scan, typically in the warband bank right after logging in. Goblinomics now waits for the data and corrects the bank, warband bank and mailbox figures on its own, without another visit. Older saved figures are checked once when you log in.",
            } },
        },
    },
    {
        version = "0.9.0-beta",
        date = "2026-09-26",
        intro = "The first public beta. Everything is new, so here's a tour instead of a diff.",
        sections = {
            { title = "Vault and the Jealousmeter", items = {
                "Your wealth is one number: gold on every character and in the warband bank, your active auctions, and every item you could sell. Items are valued at their market price, or at the vendor price if they can't go to the auction house. Soulbound, warbound and equipped gear isn't counted.",
                "Items that barely sell show up separately as \"speculative\", so a stack of something nobody buys doesn't inflate your wealth. There's a tab that shows where each of them sits.",
                "Gallywix watches your wealth and gets more jealous with every level. Past the gold cap he gets fancy frames. The bar shows how much gold the next marks need.",
                "Gold goals: a wealth target with a forecast, or saving up for a purchase.",
            } },
            { title = "Ledger", items = {
                "Every change to your gold lands in one category: auction house, vendor, repairs, quests, loot, crafting, mail or other. Sending gold to your own alts or the warband bank is neutral.",
                "Rules for mail (boosting payments, for example), trade partners it remembers, and a small popup after trades.",
                "An auction house log with sale rate, average prices and the deposits you lost.",
                "Single bookings are kept for 90 days, daily totals after that.",
            } },
            { title = "Gatherer", items = {
                "Farm sessions with a small HUD, gold per hour, auto-pause and a summary at the end.",
                "Alerts for valuable loot, your expected highlights and a watchlist.",
                "Farm statistics and raid/dungeon lockouts for all characters. Farms and watchlists can be shared as strings.",
            } },
            { title = "Workshop", items = {
                "Each craft remembers which reagents went in and what you paid for them. Intermediates you crafted yourself count at their craft cost. Multicraft, resourcefulness and concentration are handled.",
                "Profit per recipe and quality, compared with what actually sold. Crafting orders with commission and rewards, salvaging, and what a point of concentration is worth to you.",
            } },
            { title = "Dashboard and Insights", items = {
                "The dashboard covers 1 to 365 days: wealth, net income, where most gold came from, the most expensive expense, gold per character, a calendar heatmap, records and streaks, plus cards from every module and a comment from Gallywix.",
                "Insights loads when you open it: history charts, a cash flow diagram, and daily and weekly reports.",
            } },
            { title = "Everything else", items = {
                "Import your TSM Accounting or Journalator history without duplicates, and undo it if something looks off (/gob import).",
                "Link several WoW accounts into one wealth figure.",
                "A setup window on first login (/gob setup) for price source and modules.",
                "Settings with an explanation next to every option. Modules you switch off disappear everywhere.",
                "Prices come from TradeSkillMaster, Auctionator or vendor prices; CraftSim can provide craft costs.",
                "English and German. Other languages are welcome through CurseForge.",
            } },
        },
    },
}
