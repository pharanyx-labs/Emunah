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

local M = {}

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
