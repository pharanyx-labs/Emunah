--- Reasons to touch the Tree of Life while other cures still work.
---
--- The tattoo costs no balance and no equilibrium, only its own tree balance, and it
--- clears one affliction at random (Anzerloi, 2026-10-22, after the arena at 16:38).
--- HELP TATTOOS TREE: "capable of healing nearly any affliction." Which one it picks is
--- not a mapping we have, so nothing here names an affliction as cured. A function says
--- the state is one where spending the tattoo now is worth the long balance.
---
--- The engine still has the last resort: an affliction nothing else can cure, dwelt on
--- for TREE_DWELL. These fire earlier, on the same prompt as the eat, because the tattoo
--- does not use herb balance. Paralysis, a numb arm, an entanglement and both arms
--- broken still refuse the touch; the engine asks that before it sends.
---
--- Adding one is a row in M.FUNCTIONS. The first whose `when` is true wins, and one
--- touch is the whole answer for the prompt.
---
--- The rest are the reference system's tree scenarios [reference: its tree table], ported
--- 2026-10-23 when the user saw the tattoo never touched. `any2affs` ships switched off
--- there; here it is on, because it is what spends the tattoo in an ordinary fight.

local M = {}

--- What the tattoo can cure [reference: treecurables], in afflist's names.
M.CURABLE = {}
for _, name in ipairs({ "ablaze", "addiction", "aeon", "agoraphobia", "anorexia", "asthma",
   "blackout", "claustrophobia", "clumsiness", "confusion", "crippledleftarm",
   "crippledleftleg", "crippledrightarm", "crippledrightleg", "darkshade", "deadening",
   "dementia", "disloyalty", "disrupt", "dissonance", "dizziness", "epilepsy", "fear",
   "generosity", "haemophilia", "hallucinations", "healthleech", "hellsight", "hypersomnia",
   "hypochondria", "illness", "impatience", "inlove", "itching", "justice", "lethargy",
   "loneliness", "madness", "masochism", "pacifism", "paralysis", "paranoia", "peace",
   "recklessness", "relapsing", "selarnia", "sensitivity", "shyness", "slickness",
   "stupidity", "stuttering", "unknownany", "unknowncrippledarm", "unknowncrippledleg",
   "unknownmental", "vertigo", "voyria", "weakness", "hamstring", "shivering", "frozen",
   "skullfractures", "crackedribs", "wristfractures", "torntendons", "depression",
   "parasite", "retribution", "shadowmadness", "timeloop", "degenerate", "deteriorate" }) do
   M.CURABLE[name] = true
end

local function canonical(name)
   local aliases = emunah.curing.afflist and emunah.curing.afflist.ALIASES
   return aliases and aliases[name] or name
end

--- How many tracked afflictions the tattoo can cure.
function M.curableCount(tracked)
   local n = 0
   for name in pairs(tracked) do
      if M.CURABLE[canonical(name)] then n = n + 1 end
   end
   return n
end

local SIDES = { "leftarm", "rightarm", "leftleg", "rightleg" }

--- A limb crippled and no worse.
local function crippledOnly(tracked, limb)
   return tracked["crippled" .. limb] ~= nil and tracked["mangled" .. limb] == nil
      and tracked["mutilated" .. limb] == nil
end

--- Limbs crippled, mangled or mutilated [reference: countbrokenlimbs].
local function brokenLimbs(tracked)
   local n = 0
   for _, limb in ipairs(SIDES) do
      if tracked["crippled" .. limb] or tracked["mangled" .. limb]
         or tracked["mutilated" .. limb] then
         n = n + 1
      end
   end
   return n
end

local function offBalance(vector)
   local have = emunah.have
   return have ~= nil and not have.balance(vector)
end

local function locked(name)
   local watch = emunah.watch
   if not (watch and watch.locks) then return false end
   for _, lock in ipairs(watch.locks()) do
      if lock == name then return true end
   end
   return false
end

M.FUNCTIONS = {
   -- ASTHMA, SLICKNESS, IMPATIENCE. Smoke, salve and focus are shut. The eats that
   -- remain are a gamble (goldenseal is impatience or stupidity, 50/50, once the head
   -- break has landed), and the next hits are anorexia and then paralysis. Paralysis
   -- shuts the tattoo. In the arena (2026-10-22, 16:39:59.59 to 16:40:02.15) the
   -- goldenseal was chosen and anorexia refused it 1.9s later; the tattoo was never
   -- touched, and paralysis arrived 0.6s after the refusal. Waiting until nothing else
   -- can cure something misses that window. His ruling the same afternoon: use it
   -- while the momentum is building, on its own balance.
   {
      id = "forming-lock",
      because = "Asthma, slickness and impatience are up -- touching the tree.",
      when = function(tracked)
         return tracked.asthma ~= nil and tracked.slickness ~= nil
            and tracked.impatience ~= nil
      end,
   },
   {
      id = "hardlock",
      because = "A hard lock -- touching the tree.",
      when = function() return locked("hard") or locked("true") end,
   },
   {
      id = "blackout",
      because = "Blackout -- touching the tree.",
      when = function(tracked) return tracked.blackout ~= nil end,
   },
   {
      id = "aeon",
      because = "Aeon with asthma -- touching the tree.",
      when = function(tracked) return tracked.aeon ~= nil and tracked.asthma ~= nil end,
   },
   {
      id = "maybevivi",
      because = "Three limbs broken -- touching the tree before a vivisect.",
      when = function(tracked)
         local any = false
         for _, limb in ipairs(SIDES) do
            if tracked["crippled" .. limb] then any = true end
         end
         return any and brokenLimbs(tracked) >= 3
      end,
   },
   {
      id = "crippledandprone",
      because = "Both legs crippled -- touching the tree.",
      when = function(tracked)
         return crippledOnly(tracked, "leftleg") and crippledOnly(tracked, "rightleg")
            and (tracked.prone ~= nil or offBalance("salve"))
      end,
   },
   {
      id = "getupfaster",
      because = "Prone with a crippled leg, off salve -- touching the tree.",
      when = function(tracked)
         return (crippledOnly(tracked, "leftleg") or crippledOnly(tracked, "rightleg"))
            and tracked.prone ~= nil and offBalance("salve")
      end,
   },
   {
      id = "curearmsfaster",
      because = "A crippled arm, off salve -- touching the tree.",
      when = function(tracked)
         return (crippledOnly(tracked, "leftarm") or crippledOnly(tracked, "rightarm"))
            and offBalance("salve")
      end,
   },
   {
      id = "fractures",
      because = "Fractures, off the sip -- touching the tree.",
      when = function(tracked)
         return (tracked.skullfractures or tracked.crackedribs or tracked.wristfractures
            or tracked.torntendons) ~= nil and offBalance("elixir")
      end,
   },
   {
      id = "any2affs",
      because = "Two afflictions the tree can cure -- touching it.",
      when = function(tracked) return M.curableCount(tracked) >= 2 end,
   },
}

--- The first function this state calls for, or nil.
function M.match(tracked)
   tracked = tracked or {}
   for index = 1, #M.FUNCTIONS do
      local fn = M.FUNCTIONS[index]
      if fn.when(tracked) then return fn end
   end
   return nil
end

return M
