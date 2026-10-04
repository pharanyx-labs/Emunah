--- Shops: parses `WARES` into clickable listings, and buys from them by replica number.
---
--- WHAT THIS DOES
--- --------------
--- `WARES` (or a denizen's own listing) prints a proprietor line, then one row per item:
---
---   Proprietor: Seraph Myrddin D'Ischai, Page of Aeowynn.
---   --------(Item)------(Description)------------------------------(Stock)--(Price)
---             tun115258 an elixir of mana (refill only)             53     100gp
---         goldink386609 gold inks                                  222     350gp ea
---
--- Each row grows a clickable action line directly underneath, e.g.:
---
---   Proprietor: Seraph Myrddin D'Ischai, Page of Aeowynn.
---   --------(Item)------(Description)------------------------------(Stock)--(Price)
---             tun115258 an elixir of mana (refill only)             53     100gp
---                  [ fill rift -- 100gp ]
---         goldink386609 gold inks                                  222     350gp ea
---                  [ buy 1 -- 350gp | menu ]
---
--- The clickable line does not repeat the id or description above it -- just an action. A
--- click buys one (or fills the rift, for a tun); a "| menu" tail, present only when a real
--- choice of quantity exists ("gp ea" items), opens quantities of 1/10/100 instead. This is
--- NOT relinked in place over the raw row (unlike `ih.lua`/`roompanel.lua`) -- see the
--- comment on render() below for why: WARES prints many rows in one packet, and
--- deleteLine() corrupts exactly that case.
---
--- GROUNDING: see `docs/game/sustenance.md` ("Shops") and `docs/game/help/shops.txt`
--- (`HELP SHOPS`, verbatim) for what is actually confirmed here, and what is not. Two
--- things in particular are the user's own word, not a HELP file or a transcript, and nothing
--- else in this module is more certain than they are:
---
---   1. Tuns (`tun<repnum>`) are bought with `FILL RIFT WITH <repnum>`, one at a time --
---      never `BUY`, never a quantity.
---   2. Paying requires the gold to be pulled out of its container by replica number first:
---      `get <n> gold from backpack452292`, not `get gold from pack`.
---
--- What is NOT established -- BUY's balance cost, what it prints on success or refusal, and
--- how credit/crown purchases work -- is handled by not guessing: no trigger waits on a
--- confirmation string that has never been seen, and only `gp` prices are automated. See
--- `M.purchase()`.

local M = {}

local log = emunah.log

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Every item seen this session, flat by replica number. Replica numbers are unique
--- (see loot.lua), so one map serves every shop rather than nesting by proprietor.
M.items = {}

--- Proprietor names, in first-seen order, for `emunah shop` to list recent shops.
M.shopOrder = {}
local seenShop = {}

--- The shop the last `Proprietor:` line named, and the `[-[ Category ]-]` header most
--- recently seen within it.
M.current = nil
M.currentCategory = nil

--- Purchases made this session. In memory only, on purpose -- a persisted, ever-growing
--- receipt log is not worth the config file bloat for something meaningful only within a
--- sitting. `emunah shop spent` reads this.
M.ledger = { total = 0, count = 0, log = {} }

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

local function startShop(name)
   name = tostring(name or ""):gsub("%.$", "")
   if name == "" then return end

   -- A fresh listing supersedes whatever this shop showed last time -- stock and prices
   -- move, and a stale row would otherwise linger claiming an old stock count.
   for id, item in pairs(M.items) do
      if item.shop == name then M.items[id] = nil end
   end

   M.current = name
   M.currentCategory = nil
   if not seenShop[name] then
      seenShop[name] = true
      table.insert(M.shopOrder, name)
   end
end

local function upsert(id, desc, stock, price, currency, bulk)
   local item = {
      id = id,
      desc = (desc or ""):gsub("%s+$", ""),
      category = M.currentCategory,
      stock = tonumber(stock) or 0,
      price = tonumber(price) or 0,
      currency = currency,
      bulk = bulk and true or false,
      tun = id:match("^tun%d") ~= nil,
      shop = M.current,
      seenAt = emunah.util.now(),
   }
   M.items[id] = item
   return item
end

--- A single item's replica number, or nil.
function M.find(repnum)
   return M.items[tostring(repnum or "")]
end

--- An item by the number alone -- `476321` for `goldink476321` -- as typed in
--- `buy 50 476321`. The game itself wants the whole name (HELP SHOPS: "Use the full name,
--- with number"), which is exactly what this recovers from the WARES listing.
function M.findByNumber(number)
   number = tostring(number or "")
   if number == "" then return nil end
   local found = M.items[number]
   if found then return found end
   for id, item in pairs(M.items) do
      if id:match("(%d+)$") == number and id:sub(-#number - 1, -#number - 1):match("%a") then
         return item
      end
   end
   return nil
end

--- Every item belonging to a shop (default: the most recently seen one), sorted by
--- category then replica number so a redraw is stable.
function M.list(shopName)
   shopName = shopName or M.current
   local out = {}
   for _, item in pairs(M.items) do
      if item.shop == shopName then table.insert(out, item) end
   end
   table.sort(out, function(a, b)
      if a.category ~= b.category then return tostring(a.category) < tostring(b.category) end
      return a.id < b.id
   end)
   return out
end

-- ---------------------------------------------------------------------------
-- Rendering: relink each row in place
-- ---------------------------------------------------------------------------

--- Lua source for a click: evaluated fresh by Mudlet when the link fires, exactly like
--- ih.lua's toggleWanted links -- not a function reference.
local function commandFor(id, qty, mode)
   return string.format("emunah.shop.purchase(%q, %d, %q)", id, qty, mode)
end

local function priceText(item)
   return string.format("%d%s%s", item.price, item.currency, item.bulk and " ea" or "")
end

--- Indent for the clickable line, so it sits under the item id column of the raw row
--- above it without repeating any of that row's own text.
local ID_WIDTH = 16

local function render(item)
   -- NOT deleteLine() + re-echo. WARES prints many rows in one packet, and deleting the
   -- current line while Mudlet is still working through lines that arrived in the same
   -- packet shifts the buffer under it -- pipes.lua hit exactly this (see its header
   -- comment) and its fix was the same one applied here: stop deleting, print the
   -- clickable version as its own line instead. Reported in play as the category header
   -- and the first row of a shop fusing onto one line, which is that bug wearing a
   -- different costume.
   --
   -- This means the raw row from the game and our clickable copy are two lines, not one --
   -- an accepted tradeoff, not an oversight (see the header comment above). The clickable
   -- line does NOT repeat the id/description, though -- it used to (both a %-16s id column
   -- and a %-46s description column), and reported back as showing the description twice.
   -- The raw row above it already has both; this line only needs to be something to click.
   --
   -- The trailing boolean on both calls below is `useCurrentFormat`, per Mudlet's own
   -- source (TLuaInterpreterUI.cpp) -- it keeps our explicit colour tags rather than
   -- Mudlet's default link styling. It does NOT select left-click-vs-menu behaviour,
   -- despite an earlier version of this file calling it "singleClick"; that was always
   -- this module's own guess, not anything Mudlet documents.
   --
   -- Real click behaviour, confirmed against Mudlet's own source
   -- (TTextEdit.cpp: mousePressEvent/mouseReleaseEvent), not guessed:
   --   * Left-click ALWAYS runs commands[1], for a plain link or a popup alike -- there is
   --     no functional difference between the two on left-click.
   --   * Right-click only opens a menu when `#commands > 1` (or there is one extra hint
   --     beyond the commands, for a menu title) -- TTextEdit.cpp's own condition is
   --     `command.size() > 1 || hint.size() > command.size()`. With exactly one command,
   --     right-click shows NOTHING at all.
   -- A tun (one buyable quantity, ever) or a plain "buy 1" item therefore has no real menu
   -- to offer: right-clicking one showed nothing, and left-clicking its "| menu" tag ran
   -- the exact same command as the row's own link, since both were commands[1] of a
   -- single-entry list -- reported back as "menu does the same as left-clicking", which is
   -- exactly what it was doing. So a "| menu" tag is only attached below when there is an
   -- actual choice to make: bulk ("... ea") items, buyable 1, 10 or 100 at a time.
   local defaultMode = item.tun and "fill" or "buy"
   local defaultLabel = item.tun and "fill rift" or "buy 1"
   local defaultHint = item.tun
      and string.format("Click to fill your rift with %s (%s).", item.desc, priceText(item))
      or string.format("Click to buy %s (%s).", item.desc, priceText(item))
   local indent = string.rep(" ", ID_WIDTH)

   if item.bulk then
      cechoLink(string.format("\n%s<ansi_light_black>[<ansi_light_blue>buy 1<ansi_light_black> -- %s",
            indent, priceText(item)),
         commandFor(item.id, 1, "buy"), "Buy 1 -- " .. priceText(item), true)

      local commands, hints = {}, {}
      for _, qty in ipairs({ 1, 10, 100 }) do
         local capped = (item.stock and item.stock > 0) and math.min(qty, item.stock) or qty
         table.insert(commands, commandFor(item.id, capped, "buy"))
         table.insert(hints, string.format("Buy %d -- %d%s",
            capped, capped * item.price, item.currency))
      end
      cechoPopup(" <ansi_light_black>| menu]<reset>\n", commands, hints, true)
   else
      cechoLink(string.format("\n%s<ansi_light_black>[<ansi_light_blue>%s<ansi_light_black> -- %s]<reset>\n",
            indent, defaultLabel, priceText(item)),
         commandFor(item.id, 1, defaultMode), defaultHint, true)
   end
end

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- The pack gold is paid out of: `pack.id`, the same one loot stows it in.
local function stowContainer()
   return (emunah.loot and emunah.loot.pack and emunah.loot.pack()) or "backpack452292"
end

--- How long gold taken out to pay with is ours to spend, before loot may put any of it
--- back. Covers the GET, the BUY and both round trips with room to spare; a refused BUY
--- leaves its gold loose, and when this lapses loot.stowGold() returns it to the pack.
M.PAY_WINDOW = 3.0

--- Is a purchase holding gold out of the pack right now? loot.stowGold() asks.
function M.paying()
   return emunah.timers.active("shop.paying")
end

local function holdGold()
   emunah.timers.start("shop.paying", M.PAY_WINDOW, function()
      local loot = emunah.loot
      if loot and loot.stowGold then loot.stowGold() end
   end)
end

--- Refuse any single click whose cost exceeds this, rather than send it. nil = no cap.
function M.confirmAbove()
   return emunah.config.get("shop.confirmAbove", nil)
end

function M.setConfirmAbove(gp)
   gp = tonumber(gp)
   emunah.config.set("shop.confirmAbove", gp)
   emunah.config.save()
   return gp
end

function M.cost(item, qty)
   return (item.price or 0) * (tonumber(qty) or 1)
end

--- Compare Char.Status.gold before and after a purchase, since nothing here waits on a
--- BUY confirmation message -- see the module header. A mismatch does not undo anything,
--- it only says so, because a wrong guess about what to send next is worse than a log line.
local function verify(before, expectedCost, label)
   if before == nil then return end
   emunah.timers.stop("shop.verify")
   emunah.timers.start("shop.verify", 2.0, function()
      local status = emunah.gmcp and emunah.gmcp.status
      local after = status and status.gold()
      if after == nil then return end
      local delta = before - after
      if delta ~= expectedCost then
         log.warn("Shop: expected %s to cost %dgp, gold changed by %dgp instead -- check it landed.",
            label, expectedCost, delta)
      end
   end)
end

function M.record(item, qty, cost)
   M.ledger.total = M.ledger.total + cost
   M.ledger.count = M.ledger.count + 1
   table.insert(M.ledger.log, 1, {
      time = emunah.util.now(), id = item.id, desc = item.desc, qty = qty, cost = cost,
   })
   for i = #M.ledger.log, 51, -1 do table.remove(M.ledger.log) end
   log.info("Shop: bought %s x%d for %dgp (%dgp spent this session).",
      item.desc, qty, cost, M.ledger.total)
   emunah.event.raise("shop.purchased", item.id, qty, cost)
end

--- Buy (or fill-rift) an item by replica number.
--- @param repnum string
--- @param qty number|nil defaults to 1; forced to 1 for tuns
--- @param mode string|nil "buy" or "fill"; defaults from the item itself
function M.purchase(repnum, qty, mode)
   local item = M.find(repnum)
   if not item then
      log.warn("Shop: %s is not a known item -- WARES the shop first.", tostring(repnum))
      return false
   end
   if item.currency ~= "gp" then
      log.warn("Shop: %s is priced in %s, not gold -- buying that is not automated.",
         item.id, tostring(item.currency))
      return false
   end

   qty = tonumber(qty) or 1
   if item.tun then qty = 1 end
   if item.stock and item.stock > 0 and qty > item.stock then qty = item.stock end
   if qty < 1 then return false end

   local cost = M.cost(item, qty)
   local cap = M.confirmAbove()
   if cap and cost > cap then
      log.warn("Shop: %s would cost %dgp, over the %dgp confirm limit -- not sent. "
         .. "Raise it with `emset shop.confirmAbove <gp>` or buy it by hand.", item.id, cost, cap)
      return false
   end

   local container = stowContainer()
   local status = emunah.gmcp and emunah.gmcp.status
   local before = status and status.gold()

   -- GET's cost here matches the one already confirmed for floor pickups (loot.take()):
   -- balance, equilibrium, standing. Whether a container GET costs the same has not been
   -- separately observed -- see docs/game/sustenance.md.
   -- Held BEFORE the GET goes out: its Char.Items.Add arrives with the reply, and loot
   -- answers that with a PUT unless the gold is already spoken for.
   holdGold()
   if not emunah.act.send(string.format("get %d gold from %s", cost, container),
         { standing = true, bal = true, eq = true }) then
      emunah.timers.stop("shop.paying")
      return false
   end

   -- BUY's own cost has never been observed, so nothing beyond the base gate is declared --
   -- same reasoning as loot.stowGold()'s PUT. Fired once, immediately after the GET, on
   -- the assumption (confirmed for every other command in Emunah) that a MUD server
   -- processes lines from one connection in the order they arrive.
   local verb = (mode == "fill" or item.tun)
      and ("fill rift with " .. item.id)
      or (qty > 1 and string.format("buy %d %s", qty, item.id) or ("buy " .. item.id))
   emunah.act.send(verb, {})

   M.record(item, qty, cost)
   verify(before, cost, item.desc)
   return true
end

--- `buy 50 476321`: a quantity and the bare number of something WARES listed.
---
--- The game would refuse that as typed -- HELP SHOPS wants the full name with its number
--- -- so this recovers the name from the listing and buys through M.purchase(), gold and
--- all. Only a number from a listing seen this session can be bought this way; anything
--- else is refused here rather than guessed at.
function M.buyByNumber(qty, number)
   qty = tonumber(qty) or 1
   local item = M.findByNumber(number)
   if not item then
      log.warn("Shop: nothing numbered %s in a WARES listing this session -- WARES first.",
         tostring(number))
      return false
   end
   if item.tun and qty > 1 then
      log.warn("Shop: %s is a tun, and tuns fill the rift one at a time -- filling once.",
         item.id)
   elseif item.stock and item.stock > 0 and qty > item.stock then
      log.warn("Shop: only %d of %s in stock -- buying %d.", item.stock, item.id, item.stock)
   end
   return M.purchase(item.id, qty)
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------

local function registry()
   emunah._persist = emunah._persist or {}
   emunah._persist.shopTriggers = emunah._persist.shopTriggers or {}
   return emunah._persist.shopTriggers
end

--- Remove every trigger this module owns, so a reload does not stack duplicates -- same
--- problem, and same fix, as ih.lua and pipes.lua.
function M.killAll()
   local reg = registry()
   local n = 0
   for _, id in ipairs(reg) do
      if killTrigger(id) then n = n + 1 end
   end
   emunah._persist.shopTriggers = {}
   return n
end

M.killAll()

local function keep(id)
   if id then table.insert(registry(), id) end
end

keep(tempRegexTrigger([[^Proprietor:\s*(.+)$]], function()
   startShop(matches[2])
end))

keep(tempRegexTrigger([[^\[-\[\s*(.+?)\s*\]-\]$]], function()
   M.currentCategory = matches[2]
end))

-- A second, plainer bracket style ("[Elixirs]", no dashes) confirmed live -- the header
-- shape is evidently shop-specific, not a single fixed format. Restricted to word
-- characters and spaces rather than "anything but a bracket", which sidesteps writing a
-- negated character class through the PCRE-to-Lua-pattern translator (see the note above
-- on `|` and `{n,}`) for a case category names have no reason to need.
keep(tempRegexTrigger([[^\[([\w ]+)\]$]], function()
   M.currentCategory = matches[2]
end))

-- Two patterns, not one with an optional "ea" group: a quantifier cannot follow a capture
-- group in the Lua patterns test/mock_mudlet.lua translates PCRE into (see pipes.lua's own
-- note on `|` and `{n,}` for the same reason), so "optional trailing ea" has to be two
-- anchored alternatives rather than one clever regex. Each line satisfies exactly one --
-- a bulk row's " ea" leaves the plain pattern's `\s*$` unsatisfied, and vice versa.
--
-- Guarded on M.current so an unrelated table elsewhere in the game's output (this shape is
-- generic: word-token, gap, two numbers) is never mistaken for a shop row.
keep(tempRegexTrigger([[^\s*(\w+):?\s+(.*?)\s\s+(\d+)\s+(\d+)([a-z][a-z]) ea\s*$]], function()
   if not M.current then return end
   render(upsert(matches[2], matches[3], matches[4], matches[5], matches[6], true))
end))

keep(tempRegexTrigger([[^\s*(\w+):?\s+(.*?)\s\s+(\d+)\s+(\d+)([a-z][a-z])\s*$]], function()
   if not M.current then return end
   render(upsert(matches[2], matches[3], matches[4], matches[5], matches[6], false))
end))

return M
