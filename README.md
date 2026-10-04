# Goblinomics

**Track. Analyze. Profit. Make Gallywix Jealous.**

I wanted one addon that tells me three things: how much I'm actually worth across
all my characters, where my gold comes from (and where it goes), and which farm or
craft is worth my time. Nothing I tried did all three without scanning the auction
house itself, so I built Goblinomics. It takes its prices from TradeSkillMaster or
Auctionator, keeps everything in your SavedVariables, and sends nothing anywhere.

And yes, there's a goblin who gets more jealous the richer you are.

Current version: **1.0.2**. If something breaks or looks wrong, please tell me
about it.

## Installing

The easy way is the CurseForge app: search for Goblinomics and install it. It
comes as several folders (core plus modules and connectors), and the app handles
all of them.

By hand: extract every `Goblinomics*` folder from the zip into
`World of Warcraft/_retail_/Interface/AddOns/`, then restart the game completely.
A `/reload` is not enough for new addon folders.

You need WoW Retail 12.1 or newer. Install **TradeSkillMaster or Auctionator** as
well, otherwise Goblinomics only knows vendor prices and your wealth will look
sad. CraftSim is optional and helps with craft costs.

## First steps

On your first login a small setup window asks which price source to use and
which modules you want. Afterwards, visit the bank, your mailbox and the auction
house once on each character. That's how Goblinomics learns what you own.

`/gob` opens the main window. So do the minimap button, the addon compartment and
a key binding if you set one.

What's inside:

- **Vault** adds up gold, auctions and sellable items of every character plus the
  warband bank into one number, and puts Gallywix on top of it.
- **Ledger** books every copper that comes in or goes out into a category. Moving
  gold between your own characters doesn't count as income.
- **Gatherer** tracks farm sessions and tells you your gold per hour.
- **Workshop** knows what your reagents really cost you and what each craft earns.
  Milling, prospecting and disenchanting show up under Salvage: what went in,
  what came out, and what the dust or pigments brought in once sold.
- **Dashboard** and **Insights** show it all over time: charts, a cash flow
  diagram, daily and weekly reports.
- **Import** pulls in your old TSM Accounting or Journalator history.
- **Account link** is for people with more than one WoW account.

Don't need one of them? Switch it off in the settings and it disappears.

The [wiki](https://github.com/xLN1995/goblinomics/wiki) explains each module,
the settings and the slash commands in more detail.

## Found a bug?

Open an [issue](https://github.com/xLN1995/goblinomics/issues). The most useful
things to include are the Lua error (BugSack makes that easy) and the output of
`/gob status`. If the game stutters, `/gob perf` helps me find out why.

## Working on the code

The repository root is the core addon. `Modules/` and `Connectors/` become their
own addon folders when the BigWigs packager builds a release (see `.pkgmeta`).

```sh
tools/link-dev.sh        # symlink the addon folders into your AddOns directory
tools/test.sh            # busted specs, Lua 5.1 in Docker
tools/lint.sh            # luacheck
tools/package.sh         # build a release zip into release/ without uploading
tools/locale-export.sh   # every phrase as a list for translators
```

`link-dev.sh` guesses the AddOns path. If yours is somewhere else, set
`WOW_ADDONS=/path/to/Interface/AddOns`. Tests and lint only need Docker.

Other addons can read Goblinomics data through `Goblinomics.API.v1`. The wiki has
a page for addon authors. Translations are welcome as pull requests against
`Locales/`; the "Translating" page in the wiki explains how.

## License

Copyright 2026 xLN. Goblinomics is licensed under the [Mozilla Public License 2.0](LICENSE).

In plain words: you're welcome to write your own modules or addons on top of
`Goblinomics.API.v1` and release them under any licence you like, closed source
included. They live in their own files, so the MPL doesn't reach them. If you
change files of Goblinomics itself and share the result, those files stay under
the MPL and their source has to be available. And please give a fork its own name:
the licence doesn't grant any rights to the name "Goblinomics".

The bundled libraries in `Libs/` keep their own licences, listed in
`Libs/README.md`.
