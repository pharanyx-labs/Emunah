-- Generate website/commands.html from src/emunah/help.lua.
--
-- The client's `emhelp` and this page render the same table, so neither can describe a
-- command or a setting the other does not; test/run.lua checks the result stays in sync.
-- Regenerate after changing help.lua:
--
--     lua tools/build-commands-page.lua
--
-- The page's header, documentation menu and footer are not written here. They are taken
-- from website/getting-started.html, so the one generated page can never drift from the
-- hand-written ones around it: only the part between <!-- doc:start --> and
-- <!-- doc:end -->, the table of contents and the pager are this script's.
--
-- help.lua only touches the rest of Emunah when it renders, so loading it for its data
-- needs nothing more than a stand-in for the one table it reads at load time.

emunah = { ui = { theme = {} } }
local help = dofile("src/emunah/help.lua")

local function esc(text)
   return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- `backticks` in the help text become <code>, and the " -- " the client prints as a dash
-- becomes a real one.
local function prose(text)
   return (esc(text):gsub("`([^`]+)`", "<code>%1</code>"):gsub(" %-%- ", " &mdash; "))
end

local function read(path)
   local file = assert(io.open(path, "r"), "could not open " .. path)
   local text = file:read("*a")
   file:close()
   return text
end

--- Replace the first occurrence of `old` with `new`, literally. Fails loudly when the
--- template has changed shape, rather than writing a page with the wrong parts.
local function swap(text, old, new)
   local i, j = text:find(old, 1, true)
   assert(i, "template no longer contains: " .. old)
   return text:sub(1, i - 1) .. new .. text:sub(j + 1)
end

--- Replace everything from `open` to `close`, inclusive.
local function between(text, open, close, new)
   local i = assert(text:find(open, 1, true), "template has no " .. open)
   local _, j = text:find(close, i, true)
   assert(j, "template has no " .. close .. " after " .. open)
   return text:sub(1, i - 1) .. new .. text:sub(j + 1)
end

local out = {}
local function w(line) out[#out + 1] = line end

w([[<!-- doc:start -->
<p class="crumb"><a href="getting-started.html">Documentation</a> / Start</p>
<h1>Commands</h1>
<p class="lede">Everything Emunah does, one module at a time: the same text <code>emhelp</code> shows in the client, generated from the same table.</p>

<h2 id="using">Using it</h2>
<pre><code>emhelp                        <span class="c"># every module, and whether each is on</span>
emhelp curing                 <span class="c"># one module: its commands and every setting</span>
emset                         <span class="c"># status</span>
emset curing on               <span class="c"># a command</span>
emset curing.method minerals  <span class="c"># a setting</span></code></pre>
<p>There is one prefix, <code>emset</code>, and every setting can be set by name with <code>emset &lt;setting&gt; &lt;value&gt;</code>. In the client, <code>emhelp &lt;module&gt;</code> lists each setting with its current value, and clicking one changes it. The few words outside <code>emset</code> are listed under the module they belong to.</p>]])

for _, module in ipairs(help.modules) do
   w(string.format('\n<h2 id="%s">%s</h2>', module.id, esc(module.title)))
   w("<p>" .. prose(module.does) .. "</p>")
   for _, command in ipairs(module.commands) do
      w('<div class="cmd-block">')
      w('<span class="cmd-syntax">' .. esc(command.syntax) .. "</span>")
      w("<p>" .. prose(command.summary) .. "</p>")
      w("</div>")
   end
   local settings = help.settingsFor(module.id)
   if #settings > 0 then
      w('\n<div class="table-wrap"><table>')
      w("<thead><tr><th>Setting</th><th>Default</th><th>Meaning</th></tr></thead><tbody>")
      for _, spec in ipairs(settings) do
         w(string.format("<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>",
            esc(spec.key),
            esc(tostring(spec.default) .. (spec.unit and (" " .. spec.unit) or "")),
            prose(spec.detail or "")))
      end
      w("</tbody></table></div>")
   end
end

w([[
<p>Generated from <code>src/emunah/help.lua</code> by <code>tools/build-commands-page.lua</code>.</p>
<!-- doc:end -->]])

local toc = { '<aside class="toc" aria-label="On this page">', "  <h4>On this page</h4>",
   '  <a href="#using">Using it</a>' }
for _, module in ipairs(help.modules) do
   toc[#toc + 1] = string.format('  <a href="#%s">%s</a>', module.id, esc(module.title))
end
toc[#toc + 1] = "</aside>"

local page = read("website/getting-started.html")

local title = "Commands | Emunah"
local description = "Every Emunah command and setting, module by module: the same reference emhelp shows in the client."
page = page:gsub("<title>.-</title>", "<title>" .. title .. "</title>", 1)
page = page:gsub('(<meta name="description" content=")[^"]*', "%1" .. description, 1)
page = page:gsub('(<meta property="og:title" content=")[^"]*', "%1" .. title, 1)
page = page:gsub('(<meta property="og:description" content=")[^"]*', "%1" .. description, 1)
page = page:gsub('(<link rel="canonical" href="[^"]-/)getting%-started%.html', "%1commands.html", 1)

-- Which page is current: the header's Commands link, and Commands in both copies of the
-- documentation menu (the sidebar, and the one folded away for small screens).
page = swap(page, '<a href="getting-started.html" aria-current="page">Documentation</a>',
   '<a href="getting-started.html">Documentation</a>')
page = swap(page, '<a href="commands.html">Commands</a>\n',
   '<a href="commands.html" aria-current="page">Commands</a>\n')
for _ = 1, 2 do
   page = swap(page, '<li><a href="getting-started.html" aria-current="page">Getting started</a></li>',
      '<li><a href="getting-started.html">Getting started</a></li>')
   page = swap(page, '<li><a href="commands.html">Commands</a></li>',
      '<li><a href="commands.html" aria-current="page">Commands</a></li>')
end

page = between(page, "<!-- doc:start -->", "<!-- doc:end -->", table.concat(out, "\n"))
page = between(page, '<nav class="pager"', "</nav>", [[<nav class="pager" aria-label="Pages">
  <a href="getting-started.html"><small>Previous</small>Getting started</a>
  <a class="next" href="curing.html"><small>Next</small>Client-side curing</a>
</nav>]])
page = between(page, '<aside class="toc"', "</aside>", table.concat(toc, "\n"))

local file = assert(io.open("website/commands.html", "w"))
file:write(page)
file:close()
print("wrote website/commands.html")
