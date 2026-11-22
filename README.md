# Vamoose's Housing Decor Guide

**Every housing decoration in the game, in one addon.** Browse the full catalog
with 3D previews, see exactly where each piece comes from, track collection
progress across your whole account, plan and craft what you need, design rooms
before you build them, and place decor straight from the House Editor.

A World of Warcraft: Midnight addon for the housing system.

## Install

- **CurseForge:** https://www.curseforge.com/wow/addons/housing-decor-guide
- **Manual:** download a zip from [Releases](../../releases), extract into
  `World of Warcraft/_retail_/Interface/AddOns/`.

No dependencies. TradeSkillMaster, Auctionator, and TomTom are optional enhancers.

## What it does

Open with `/hdg` (or the minimap button / addon compartment icon). A left
sidebar groups everything into hubs:

### The Decor Catalog

- Every piece from the in-game Housing Catalog in one searchable list --
  favorites, a collected check, a craftable-recipe star, and dye-variant color
  dots at a glance.
- Filter menus above the list: Collection, Type, Room, Sits on, Size, Source
  (vendor / quest / achievement / reputation / crafted / ..., and crafted by
  profession), Expansion and Holiday, then Colour, Material, Shape, Motif, Mood,
  Style, Culture and Place. Tick any number of values in any number of menus,
  with a live "collected / shown" readout and one-click Clear all.
- Best first ranks the decor by how many of your ticked filters it fits; Every
  filter lists only the decor that fits them all. Find similar starts from the
  selected piece.
- **Uncollected** toggle to focus on what you're missing; **Destroy Decor**
  toggle to clear stored duplicates (with a confirmed destroy dialog).
- 3D model preview of any piece -- rotate, zoom, swap the backdrop, and preview
  specific dye variants.
- Rich detail card: category breadcrumb, size, source, owned/stored/placed
  counts, first-acquisition House XP bonus, and style/faction tags.
- Private notes per item and a one-click **+ Wishlist** to your active shopping list.

### Acquire -- where every piece comes from

- **Shop by Vendor:** browse every decor vendor (searchable; filter by faction,
  expansion, zone, reputation, or source). Each shows what they sell -- items
  *and* recipe scrolls -- with costs, payment options, and live **[QUEST] / [ACH]
  / [REP]** gate chips that brighten as you meet them. Map thumbnail plus
  **Waypoint** / **Map** buttons; **Map N Vendors** pins a whole filtered list.
- **Find Decor:** search any piece and see exactly how to get it -- a typed
  source line with reputation faction *and your live progress*, a clickable
  achievement link, the alt who completed the quest (account-wide), craft/drop
  tags, and an "Available from" list of every vendor that sells it.

### Crafting

- **Recipes** -- browse craftable decor across professions and expansions; filter
  by Known / Ready / Unknown. Queue crafts, preview the result in 3D, and see a
  materials panel (totals or per-recipe, direct or fully raw) with an AH cost estimate.
- **Warehouse** -- track lumber and every reagent (bag / bank / warband bank,
  separately), how much your queue *and* all uncollected recipes need, and a
  "Used In" cross-reference. Auto-pops when you harvest lumber.
- **Trainers** -- a profession-trainer directory by expansion and faction, each
  with location, coordinates, and a one-click waypoint.
- **Alts** -- an account-wide grid of your best skill in every profession across
  every expansion, with decor-recipe completeness so you know which alt to log in.

### Lumber Tracker & Radar

A standalone window with a live circular radar that plots nearby lumber nodes as
blips around you (with your facing and the cardinal directions), built from the
spots recorded each time you harvest. Start a farming session to track how much
you've gathered and your rate, and see your stock versus what your craft queue
still needs per lumber type.

### Mogul -- make gold (or finish your collection)

- **Goblin** -- a profit table for every craftable: material cost, sell price,
  profit, margin %, and gold-per-lumber, sortable and filterable. Prices from TSM,
  Auctionator, a live AH scan, or vendor fallback.
- **Optimizer** -- ranks recipes by profit *or* by new appearances for
  collection; scope to one character or the whole account, then Queue All or push
  the shopping list to Auctionator.

### Styles -- organize and design

- **Browse** -- all your sets in one place: My Styles, Smart Sets, Shopping Lists,
  Snapshots, plus pre-authored Room Concepts and Useful Collections.
- **Style Curator** -- a workspace to file your decor into named styles, with
  single-step undo and a coverage bar.
- **Smart Sets** -- build filter-based sets from a deep tag taxonomy (room, mood,
  material, color, culture, motif, season, ...); mark tags Signature / Accent /
  Clashing and watch a live, scored preview.
- **Snapshots** -- capture everything you've placed in a house as a saved set.
- **Import** -- paste a Wowhead URL, item IDs, or any list of numbers to build a
  shopping list instantly.

### Projects -- plan your house before you build

- **Architect** -- a drag-and-drop blueprint canvas: lay out rooms across floors,
  watch live budget bars, and assign decor "crates" to each room.
- **Layouts** -- manage saved versions, load into the Architect, and share a
  layout as a compact code (or import one).
- **Move Planner** -- moving plots? Get the exact rotation your house and yard
  need, with neighborhood maps and door-facing diagrams.

### House -- your collection at a glance

A personal dashboard: decorator profile with house level, favor, and Collector
title progress; collection donuts by source and expansion; "close to complete"
and themed-set progress; House-XP hot picks; lumber wallet and decor currencies;
favorites, recent activity, and top uncollected-from vendors. Fully customizable
-- toggle and drag-reorder every widget.

### Right inside the House Editor

A companion window injects into Blizzard's House Editor so you can place decor
with one click -- browse by your styles, shopping lists, snapshots, room
concepts, or what you've placed recently. Indoor/outdoor filtering,
placement-cost display, and dye variants handled for you.

### Tools

- **Shopping** -- a floating, multi-list shopping manager grouped by zone and
  vendor, with "Waypoint All" and share/import codes.
- **Zone alerts** -- entering a zone with a relevant decor vendor can pop a
  window, ping chat, and play a sound (each toggle optional).
- **Your Data** -- collection KPIs, achievement progress, and full
  crafting/farming history.
- **Config** -- multiple color themes with a live preview, UI scaling, and
  account profiles.

## Integrations (all optional)

- **TradeSkillMaster / Auctionator** for pricing (and push shopping lists into Auctionator)
- **TomTom** for waypoints (falls back to Blizzard's native pin)
- **Wowhead / wowdb** build import

## Requirements

- World of Warcraft Retail **12.1.0 (Midnight)**

## Links

- **Discord:** https://discord.gg/RWZaxJaHFP
- **Issues / requests:** [open an issue](../../issues) or post in Discord

## Name & branding

The **code** in this repository is free to use, modify, and redistribute under the
[MIT License](LICENSE). The **"Vamoose" name, the addon name ("Vamoose's Housing Decor
Guide"), and the logo/artwork are not** -- they identify the official addon and aren't
granted by the code license.

If you fork or redistribute:
- **Rename** your version and use your own branding. Don't ship it under the Vamoose
  name or present it as the official Housing Decor Guide.
- Don't re-upload it to CurseForge, Wago, or elsewhere as if it were this addon.
- A credit/link back is appreciated but not required (the MIT notice already covers
  attribution).

This is the normal open-source split: the license covers the code; the name and identity
stay with the project.

## License

MIT -- see [LICENSE](LICENSE).
