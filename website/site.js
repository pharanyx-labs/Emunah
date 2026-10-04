// Emunah site: the mobile menu, the annotated screenshot, and the balance strip demo.
// Everything here is progressive: without JavaScript the pages read the same, the
// screenshot simply has no highlighting and the strip shows one still frame.

(function () {
  "use strict";

  // ------------------------------------------------------------ mobile menu
  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  // ------------------------------------------------- the annotated screenshot
  var frame = document.querySelector(".shot-frame");
  var legend = document.querySelectorAll(".shot-legend button");
  var caption = document.querySelector(".shot-caption");
  if (frame && legend.length) {
    var regions = frame.querySelectorAll(".shot-region");
    var current = null;
    var show = function (id) {
      current = id;
      if (id) frame.setAttribute("data-active", id); else frame.removeAttribute("data-active");
      regions.forEach(function (r) { r.classList.toggle("on", r.getAttribute("data-region") === id); });
      legend.forEach(function (b) {
        var on = b.getAttribute("data-region") === id;
        b.setAttribute("aria-pressed", on ? "true" : "false");
        if (on && caption) caption.textContent = b.getAttribute("data-caption") || "";
      });
      if (!id && caption) caption.textContent = caption.getAttribute("data-default") || "";
    };
    legend.forEach(function (b) {
      var id = b.getAttribute("data-region");
      b.addEventListener("click", function () { show(current === id ? null : id); });
      b.addEventListener("mouseenter", function () { show(id); });
      b.addEventListener("focus", function () { show(id); });
    });
    var list = document.querySelector(".shot-legend");
    if (list) list.addEventListener("mouseleave", function () { show(null); });
  }

  // ------------------------------------------------------ balance strip demo
  // The cells and marks are the client's own (ui/vitals.lua): ✓ ready, › sent and not yet
  // answered, seconds while recovering, ✕ shut by an affliction, – nothing to use.
  var strip = document.querySelector("[data-strip]");
  if (!strip) return;
  var log = document.querySelector("[data-strip-log]");
  var LABELS = ["BAL", "EQ", "HERB", "SALVE", "SIP", "PURG", "SMOKE", "FOCUS", "MOSS", "TREE"];
  var cells = {};
  LABELS.forEach(function (label) {
    var el = document.createElement("div");
    el.className = "cell";
    strip.appendChild(el);
    cells[label] = { el: el, state: "ready", until: 0 };
  });

  var MARK = { ready: "✓", flight: "›", locked: "✕", absent: "–" };
  var set = function (label, state, seconds) {
    var c = cells[label];
    c.state = state;
    c.until = state === "recover" ? Date.now() + seconds * 1000 : 0;
  };
  var paint = function () {
    var now = Date.now();
    LABELS.forEach(function (label) {
      var c = cells[label];
      if (c.state === "recover" && now >= c.until) c.state = "ready";
      var text = c.state === "recover"
        ? label + " " + Math.max(0, (c.until - now) / 1000).toFixed(1)
        : label + "<span class=\"mk\">" + MARK[c.state] + "</span>";
      if (c.el.innerHTML !== text) c.el.innerHTML = text;
      c.el.setAttribute("data-s", c.state);
    });
  };
  var say = function (html) { if (log) log.innerHTML = html; };

  var reset = function () {
    LABELS.forEach(function (l) { set(l, "ready"); });
    set("TREE", "absent");
  };

  // One fight, about eleven seconds long, then it starts again.
  var SCRIPT = [
    [0,    function () { reset(); say("Every balance is up. Nothing is afflicting you."); }],
    [1400, function () { set("EQ", "flight"); say("&gt; <b>angel sear 234015</b>"); }],
    [1800, function () { set("EQ", "recover", 2.5); say("Equilibrium used: 2.50s."); }],
    [3000, function () { set("HERB", "flight"); say("Paralysis lands.<br>&gt; <b>eat bloodroot</b>, on the herb balance only"); }],
    [3500, function () { set("HERB", "recover", 1.6); say("You eat a bloodroot leaf. Your muscles unlock."); }],
    [5400, function () {
      ["HERB", "SIP", "PURG", "MOSS"].forEach(function (l) { set(l, "locked"); });
      set("SALVE", "flight");
      say("Anorexia lands: herb, sip, purgative and moss are shut.<br>&gt; <b>apply epidermal to body</b>, the one balance it leaves open");
    }],
    [6200, function () {
      ["HERB", "SIP", "PURG", "MOSS"].forEach(function (l) { set(l, "ready"); });
      set("SALVE", "recover", 1.0);
      say("The salve cures the anorexia. Every lock lifts on the same prompt.");
    }],
    [8600, function () { say("Ready for the next one."); }],
    [11000, null],
  ];

  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced) {
    // One still frame that shows every state at once.
    reset();
    set("EQ", "recover", 2.5);
    ["HERB", "SIP", "PURG", "MOSS"].forEach(function (l) { set(l, "locked"); });
    set("SALVE", "flight");
    paint();
    LABELS.forEach(function (l) { if (cells[l].state === "recover") cells[l].el.textContent = l + " 2.5"; });
    say("Anorexia shuts herb, sip, purgative and moss; the epidermal that cures it is on its way on the salve balance.");
    return;
  }

  var timers = [];
  var ticker = null;
  var run = function () {
    stop();
    SCRIPT.forEach(function (step) {
      timers.push(setTimeout(function () {
        if (step[1]) { step[1](); paint(); } else run();
      }, step[0]));
    });
    ticker = setInterval(paint, 100);
  };
  var stop = function () {
    timers.forEach(clearTimeout);
    timers = [];
    if (ticker) clearInterval(ticker);
    ticker = null;
  };

  reset();
  paint();
  if ("IntersectionObserver" in window) {
    var playing = false;
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting && !playing) { playing = true; run(); }
        else if (!e.isIntersecting && playing) { playing = false; stop(); reset(); paint(); }
      });
    }, { threshold: 0.4 }).observe(strip);
  } else {
    run();
  }
})();
