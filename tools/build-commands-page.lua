-- Generate website/commands.html from src/emunah/help.lua.
--
-- The client's `emhelp` and this page render the same table, so neither can describe a
-- command or a setting the other does not; test/run.lua checks the result stays in sync.
-- Regenerate after changing help.lua:
--
--     lua tools/build-commands-page.lua
--
-- help.lua only touches the rest of Emunah when it renders, so loading it for its data
-- needs nothing more than a stand-in for the one table it reads at load time.

emunah = { ui = { theme = {} } }
local help = dofile("src/emunah/help.lua")

local function esc(text)
   return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- `backticks` in the help text become <code>.
local function prose(text)
   return (esc(text):gsub("`([^`]+)`", "<code>%1</code>"))
end

local out = {}
local function w(line) out[#out + 1] = line end

w([[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Command Reference — Emunah</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="layout">
<nav class="sidebar">
  <div class="brand"><span class="glyph">&gt;</span><span class="brand-name">emunah</span></div>
  <p class="tagline">An Achaea system for Mudlet</p>
  <ul>
    <li><a href="index.html">Overview</a></li>
    <li><a href="getting-started.html">Getting Started</a></li>
    <li><a href="commands.html" class="active">Command Reference</a></li>
    <li><a href="api.html">Lua API</a></li>
  </ul>
  <div class="nav-group-title">How it works</div>
  <ul>
    <li><a href="curing.html">Curing Engine</a></li>
    <li><a href="combat.html">Combat &amp; PvP</a></li>
    <li><a href="people.html">People &amp; Names</a></li>
    <li><a href="sustenance.html">Sustenance &amp; Economy</a></li>
    <li><a href="interface.html">Interface</a></li>
    <li><a href="architecture.html">Architecture</a></li>
    <li><a href="performance.html">Performance</a></li>
  </ul>
  <div class="nav-group-title">Project</div>
  <ul>
    <li><a href="roadmap.html">Roadmap</a></li>
  </ul>
</nav>
<main class="with-toc ref">
<div class="content">

<h1>Command Reference</h1>
<p class="lede">
Everything Emunah does, one module at a time &mdash; the same text <code>emhelp</code> shows in
the client.
</p>

<h2 id="using">Using it</h2>
<pre><code>emhelp                        # the modules, and whether each is on
emhelp curing                 # one module: what it does, its commands, its settings
emset                         # status
emset curing on               # a command
emset curing.method minerals  # a setting</code></pre>
<p>
There is one prefix, <code>emset</code>. Every setting can be set by name with
<code>emset &lt;setting&gt; &lt;value&gt;</code>; in the client, <code>emhelp &lt;module&gt;</code>
lists them with their current values, and clicking one changes it. The only words outside
<code>emset</code> are <code>emhelp</code>, <code>emreload</code> (which works even if the
command module failed to load) and <code>sleep</code> (which is the game's SLEEP, marked as
yours so Emunah does not wake you out of it).
</p>
]])

for _, module in ipairs(help.modules) do
   w(string.format('\n<h2 id="%s">%s</h2>', module.id, esc(module.title)))
   w("<p>" .. prose(module.does) .. "</p>")
   for _, command in ipairs(module.commands) do
      w('\n<div class="cmd-block">')
      w('<span class="cmd-syntax">' .. esc(command.syntax) .. "</span>")
      w("<p>" .. prose(command.summary) .. "</p>")
      w("</div>")
   end
   local settings = help.settingsFor(module.id)
   if #settings > 0 then
      w("\n<table><thead><tr><th>Setting</th><th>Default</th><th>Meaning</th></tr></thead><tbody>")
      for _, spec in ipairs(settings) do
         w(string.format("<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>",
            esc(spec.key),
            esc(tostring(spec.default) .. (spec.unit and (" " .. spec.unit) or "")),
            prose(spec.detail or "")))
      end
      w("</tbody></table>")
   end
end

w([[

<footer>
Generated from <code>src/emunah/help.lua</code> by <code>tools/build-commands-page.lua</code>.
See <a href="curing.html">Curing Engine</a> for what the curing commands are driving.
</footer>

<div class="page-nav">
  <div><span class="dir">Back</span><a href="getting-started.html">&larr; Getting Started</a></div>
  <div class="next"><span class="dir">Next</span><a href="api.html">Lua API &rarr;</a></div>
</div>

</div>
<div class="toc">
  <div class="toc-title">On this page</div>
  <a href="#using">Using it</a>]])
for _, module in ipairs(help.modules) do
   w(string.format('  <a href="#%s">%s</a>', module.id, esc(module.title)))
end
w([[</div>
</main>
</div>
</body>
</html>]])

local file = assert(io.open("website/commands.html", "w"))
file:write(table.concat(out, "\n"), "\n")
file:close()
print("wrote website/commands.html")
