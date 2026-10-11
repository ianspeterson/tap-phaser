-- =====================================================================
-- Tap Phaser   v1.0.2   2026-10-11
-- Created by Ian Peterson
--
-- Tap a rhythm on an executor key; get it back as a Shape (a phaser
-- recipe you can assign to any recipe line or call on a selection).
--
--   1. Start: pick an empty executor (or leave blank and press a key
--      when "Assign Sequence N At" appears in the command line).
--   2. Record, then tap. Presses, releases and hold times are captured
--      by a temp timecode, so they are frame accurate.
--   3. Run the plugin again to END. Choose Keep tail or Chop.
--   4. The Shape is written and read back to check it.
--
-- Free mode keeps your timing. BPM mode snaps presses and releases to a
-- grid at the tempo you type. Feel sets the transitions (Snap, Pluck,
-- Swell, Smooth). "Re-render last take" rebuilds the Shape from the last
-- take with different settings, without tapping again.
--
-- Temp objects are named "TAP PHASER TEMP", live in 9901+, and are
-- removed when the take ends. Log: <gma3_library>/TapPhaser_log.txt
-- =====================================================================

local pluginName, componentName, signalTable, myHandle = select(1, ...)

local VERSION  = "1.0.2"
local PREFIX   = "[TapPhaser] "
local LOGNAME  = "TapPhaser_log.txt"
local TEMPNAME = "TAP PHASER TEMP"
local RECNAME  = "TAP - plugin again = END"   -- the temp sequence's label while recording
local TIME_T   = 16777216      -- MA's internal 2^24 unit for times
local SLOT_LO, SLOT_HI = 9901, 9990
local MAX_REC  = 120           -- seconds; a take ends by itself after this

-- ---------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------
local buf = {}

local function fmt(f, ...)
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, f, ...)
    if ok then return s end
    return tostring(f) .. "  <format error: " .. tostring(s) .. ">"
end

local function flog(f, ...)              -- log file only
    buf[#buf + 1] = fmt(f, ...)
end

local function log(f, ...)               -- command line history + file
    local s = fmt(f, ...)
    buf[#buf + 1] = s
    Printf("%s", PREFIX .. s)
end

local function err(f, ...)
    local s = fmt(f, ...)
    buf[#buf + 1] = "!! " .. s
    ErrPrintf("%s", PREFIX .. s)
end

local function logPath()
    local ok, dir = pcall(function() return GetPath(Enums.PathType.Library) end)
    if not ok or type(dir) ~= "string" or dir == "" then return nil end
    local sep = "/"
    local oks, s = pcall(GetPathSeparator)
    if oks and type(s) == "string" and s ~= "" then sep = s end
    return dir .. sep .. LOGNAME
end

local function flush()
    local p = logPath()
    if not p then
        ErrPrintf("%s", PREFIX .. "no library path - log file not written")
        buf = {}
        return
    end
    local f, e = io.open(p, "a")
    if not f then
        ErrPrintf("%s", PREFIX .. "cannot open " .. p .. ": " .. tostring(e))
        buf = {}
        return
    end
    f:write(table.concat(buf, "\n"), "\n")
    f:close()
    buf = {}
    Printf("%s", PREFIX .. "log appended to " .. p)
end

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------
local function cmd_ok(r)
    return r ~= nil and string.find(string.upper(tostring(r)), "OK", 1, true) ~= nil
end

local function run(f, ...)
    local c = fmt(f, ...)
    local okc, r = pcall(Cmd, c)
    local good = okc and cmd_ok(r)
    if good then
        log("ok    %s", c)
    else
        err("FAIL  %s   -> %s", c, tostring(r))
    end
    return good, r
end

local clockName = "os.clock"
local function now()
    if type(Time) == "function" then
        local ok, t = pcall(Time)
        if ok and type(t) == "number" then clockName = "Time()" return t end
    end
    local ok, ms = pcall(function() return Root().StationSettings.TimeConfig.localtimems end)
    if ok and tonumber(ms) then clockName = "localtimems" return tonumber(ms) / 1000 end
    clockName = "os.clock"
    return os.clock()
end

local function apiHas(name)
    local ok, v = pcall(function() return _G[name] end)
    return ok and type(v) == "function"
end

local function show(v)
    if type(v) == "userdata" then
        local ok, a = pcall(function() return v:ToAddr() end)
        if ok and a then return "#[" .. tostring(a) .. "]" end
    end
    return tostring(v)
end

local function count(o)
    local ok, n = pcall(function() return o:Count() end)
    return (ok and tonumber(n)) or 0
end

local function child(o, i)
    local ok, c = pcall(function() return o[i] end)
    if ok and c ~= nil then return c end
    ok, c = pcall(function() return o:Ptr(i) end)
    if ok then return c end
    return nil
end

local function prop(o, name)
    local ok, v = pcall(function() return o[name] end)
    if ok then return v end
    return nil
end

local function cls(o)
    local ok, c = pcall(function() return o:GetClass() end)
    return ok and tostring(c) or "?"
end

local function addr(o)
    local ok, a = pcall(function() return o:ToAddr() end)
    return ok and tostring(a) or "?"
end

local function same(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local ok, r = pcall(function() return HandleToInt(a) == HandleToInt(b) end)
    if ok and r then return true end
    ok, r = pcall(function() return a:Addr() == b:Addr() end)
    return (ok and r) and true or false
end

local function handleOf(address)
    local ok, list = pcall(ObjectList, address)
    if ok and type(list) == "table" then return list[1] end
    return nil
end

-- First free number in the 9901+ range. pattern e.g. "Sequence %d" or "Preset 1.%d".
local function freeNumber(pattern)
    for n = SLOT_LO, SLOT_HI do
        if handleOf(string.format(pattern, n)) == nil then return n end
    end
    return nil
end

local function isOn(v)
    return v == true or v == 1 or v == "Yes" or v == "true"
end

local function inputOf(res, name, default)
    if type(res) ~= "table" or type(res.inputs) ~= "table" then return default end
    local v = res.inputs[name]
    if v == nil then
        for _, item in ipairs(res.inputs) do
            if type(item) == "table" and item.name == name then v = item.value end
        end
    end
    if v == nil then return default end
    return tostring(v)
end

-- name/value list of every property; shows the display text and the raw value when they differ
local function props(o)
    local list = {}
    local ok, n = pcall(function() return o:PropertyCount() end)
    if not ok or not tonumber(n) then return list end
    local role = Enums and Enums.Roles and Enums.Roles.Display
    for i = 0, n - 1 do
        local okn, nm = pcall(function() return o:PropertyName(i) end)
        if okn and nm then
            local okv, v = pcall(function() return o:Get(nm) end)
            local s = okv and show(v) or "<err>"
            if role ~= nil then
                local okd, d = pcall(function() return o:Get(nm, role) end)
                if okd and d ~= nil and tostring(d) ~= s then
                    s = tostring(d) .. "   (raw " .. s .. ")"
                end
            end
            list[#list + 1] = { tostring(nm), s }
        end
    end
    return list
end

-- Object tree to the log file. The first object of each class prints every
-- property; later ones print only what differs from that first one.
local function dumpTree(o, label, maxDepth, baseline, depth)
    depth = depth or 0
    baseline = baseline or {}
    local ind = string.rep("  ", depth)
    local c = cls(o)
    local n = count(o)
    flog("%s%s  <%s> '%s'  children=%d  addr=%s", ind, label, c, tostring(prop(o, "Name")), n, addr(o))
    local pl = props(o)
    local base = baseline[c]
    if not base then
        base = {}
        baseline[c] = base
        for _, p in ipairs(pl) do
            base[p[1]] = p[2]
            flog("%s    %s = %s", ind, p[1], p[2])
        end
    else
        local diffs = 0
        for _, p in ipairs(pl) do
            if base[p[1]] ~= p[2] then
                diffs = diffs + 1
                flog("%s    %s = %s", ind, p[1], p[2])
            end
        end
        if diffs == 0 then flog("%s    (same as first <%s>)", ind, c) end
    end
    if depth < maxDepth then
        for i = 1, math.min(n, 40) do
            local k = child(o, i)
            if k ~= nil then dumpTree(k, tostring(i), maxDepth, baseline, depth + 1) end
        end
    end
end

-- Just class/name/child counts, to the command line as well.
local function outline(o, label, maxDepth, depth)
    depth = depth or 0
    local n = count(o)
    log("%s%s <%s> '%s' children=%d", string.rep("  ", depth), label, cls(o), tostring(prop(o, "Name")), n)
    if depth < maxDepth then
        for i = 1, math.min(n, 12) do
            local k = child(o, i)
            if k ~= nil then outline(k, tostring(i), maxDepth, depth + 1) end
        end
    end
end

-- Lua table on one line: k=v, k=v (sorted keys, nested tables to maxDepth)
local function kv(t, maxDepth, depth)
    depth = depth or 0
    if type(t) ~= "table" then return show(t) end
    if depth >= (maxDepth or 1) then return "{...}" end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "number" and v ~= math.floor(v) then v = string.format("%.4g", v) end
        parts[#parts + 1] = tostring(k) .. "=" .. kv(v, maxDepth, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Existing executors of the current page. Pages can be sparse, so prefer Children().
local function pageExecs()
    if not apiHas("CurrentExecPage") then return {} end
    local ok, page = pcall(CurrentExecPage)
    if not ok or page == nil then return {} end
    local okc, kids = pcall(function() return page:Children() end)
    if okc and type(kids) == "table" and #kids > 0 then return kids end
    local list = {}
    for i = 1, 1000 do
        local okk, k = pcall(function() return page:Ptr(i) end)
        if okk and k ~= nil then list[#list + 1] = k end
    end
    return list
end

local function assignedOf(ex)
    local ok, a = pcall(function() return ex:GetAssignedObj() end)
    if ok and a ~= nil then return a end
    return prop(ex, "Object")
end

local function findExecFor(seq)
    for _, ex in ipairs(pageExecs()) do
        local a = assignedOf(ex)
        if a ~= nil and same(a, seq) then return ex end
    end
    return nil
end

-- Executor by number on the current page; says in the log which lookup worked.
local function execByNumber(n)
    local okg, g = pcall(GetExecutor, n)
    log("GetExecutor(%d) -> %s", n, okg and (g ~= nil and (cls(g) .. " " .. addr(g)) or "nil") or ("error " .. tostring(g)))
    if okg and g ~= nil then return g end
    local execs = pageExecs()
    for _, ex in ipairs(execs) do
        local no = tonumber(prop(ex, "No"))
        local oki, idx = pcall(function() return ex:Index() end)
        if no == n or (oki and tonumber(idx) == n) then
            log("found executor %d by scanning the page (%d executors exist on it)", n, #execs)
            return ex
        end
    end
    log("executor %d is empty on the current page (%d executors exist on it)", n, #execs)
    return nil
end

-- A stop the user can't miss: popup as well as the red line.
local function stop(f, ...)
    local s = fmt(f, ...)
    err("%s", s)
    pcall(MessageBox, { title = "Tap Phaser stopped", message = s, commands = { { value = 1, name = "OK" } } })
end


-- ---------------------------------------------------------------------
-- Tap Phaser specifics
-- ---------------------------------------------------------------------
local GRID_BEATS = { 1, 0.5, 0.25, 1 / 3, 1 / 6 }
local GRID_NAME  = { "1/4", "1/8", "1/16", "1/8 T", "1/16 T" }
local FEEL_NAME  = { "Snap", "Pluck", "Swell", "Smooth" }
-- Per feel: transition / accel / decel for the "on" steps and the "off" steps.
-- Transition is a percentage of the step's own width (MA manual).
local FEEL = {
    { on = { 0, 0, 0 },         off = { 0, 0, 0 } },            -- Snap: hard on, hard off
    { on = { 0, 0, 0 },         off = { 100, 0, 0 } },          -- Pluck: hard on, fades out over the gap
    { on = { 100, 0, 0 },       off = { 0, 0, 0 } },            -- Swell: fades in over the hold, hard off
    { on = { 100, -100, -100 }, off = { 100, -100, -100 } },    -- Smooth: eased both ways
}

-- Module state survives between launches of the loaded plugin. That is what
-- lets a second launch act as the END button while the first one records.
local S = { phase = nil, since = 0, endAt = nil, last = nil }

-- quiet run: log file only, red line if it fails
local function runq(f, ...)
    local c = fmt(f, ...)
    local okc, r = pcall(Cmd, c)
    local good = okc and cmd_ok(r)
    if good then flog("ok    %s", c) else err("FAIL  %s   -> %s", c, tostring(r)) end
    return good, r
end

local function notice(title, f, ...)
    local s = fmt(f, ...)
    log("%s", (s:gsub("\n", " | ")))
    pcall(MessageBox, { title = title, message = s, commands = { { value = 1, name = "OK" } } })
end

local function getVar(name)
    local ok, v = pcall(function() return GetVar(UserVars(), name) end)
    if ok and v ~= nil and tostring(v) ~= "" then return tostring(v) end
    return nil
end

local function setVar(name, value)
    pcall(function() SetVar(UserVars(), name, tostring(value)) end)
end

local function selOf(res, name, default)
    if type(res) ~= "table" or type(res.selectors) ~= "table" then return default end
    local v = res.selectors[name]
    if type(v) == "table" then v = v.selectedValue or v.value end
    if v == nil then
        for _, item in ipairs(res.selectors) do
            if type(item) == "table" and item.name == name then v = item.selectedValue or item.value end
        end
    end
    return tonumber(v) or default
end

local function firstFree(pattern, lo, hi)
    for n = lo, hi do
        if handleOf(string.format(pattern, n)) == nil then return n end
    end
    return nil
end

local function disp(o, name)
    local role = Enums and Enums.Roles and Enums.Roles.Display
    local ok, v = pcall(function() return o:Get(name, role) end)
    if ok and v ~= nil then return tostring(v) end
    return tostring(prop(o, name))
end

-- A temp slot counts as free only if neither the command line nor the pool can see an object there.
local function slotFree(kind, n)
    if handleOf(kind .. " " .. n) ~= nil then return false end
    local ok, o = pcall(function() return DataPool()[kind .. "s"][n] end)
    if ok and o ~= nil then return false end
    return true
end

local function freeTempSlot(kind)
    for n = SLOT_LO, SLOT_HI do
        if slotFree(kind, n) then return n end
    end
    return nil
end

-- Temp objects are recognised by their name, never by their number alone.
local function isOurs(address)
    local h = handleOf(address)
    if h == nil then return false end
    local n = tostring(prop(h, "Name"))
    return n == TEMPNAME or n == RECNAME
end

local function deleteOurs(address)
    if handleOf(address) == nil then return end
    if isOurs(address) then
        runq("Delete %s /NoConfirm", address)
    else
        log("left %s alone: it no longer carries the temp name, so it may not be ours", address)
    end
end

-- Leftovers from a run that was killed mid-take. Asked about, never deleted silently.
local function sweepLeftovers()
    local found = {}
    for n = SLOT_LO, SLOT_HI do
        for _, kind in ipairs({ "Timecode", "Macro", "Sequence" }) do
            if isOurs(kind .. " " .. n) then found[#found + 1] = kind .. " " .. n end
        end
    end
    if #found == 0 then return end
    log("leftover temp objects: %s", table.concat(found, ", "))
    local ok, yes = pcall(Confirm, "Tap Phaser", "Found temp objects left by an earlier run:\n\n" ..
        table.concat(found, ", ") .. "\n\nDelete them?\n(Say No if someone else is tapping a take right now.)", nil, false)
    if ok and yes then
        for _, a in ipairs(found) do deleteOurs(a) end
    end
end

-- A take as text, so "Re-render last take" survives a plugin reload.
local function encodeTake(take)
    local t0 = take.taps[1].on
    local parts = {}
    for _, tp in ipairs(take.taps) do
        parts[#parts + 1] = fmt("%d:%d", math.floor((tp.on - t0) * 1000 + 0.5), math.floor((tp.off - t0) * 1000 + 0.5))
    end
    return table.concat(parts, ",") .. "|" .. tostring(math.floor((take.endT - t0) * 1000 + 0.5))
end

local function decodeTake(s)
    if type(s) ~= "string" then return nil end
    local body, e = s:match("^(.-)|(%d+)$")
    if not body then return nil end
    local taps = {}
    for a, b in body:gmatch("(%d+):(%d+)") do taps[#taps + 1] = { on = tonumber(a) / 1000, off = tonumber(b) / 1000 } end
    if #taps == 0 then return nil end
    return { taps = taps, endT = tonumber(e) / 1000 }
end

-- ---------------------------------------------------------------------
-- Taps -> phaser steps
-- ---------------------------------------------------------------------
-- opt: mode (1 Free, 2 BPM), bpm, grid, feel, tail (true = keep the tail), hi, lo
-- Result: steps { v, w (beats), width (%), trans, accel, decel }, beats, bpm, seconds.
-- Width is a step's length as a percentage of one beat, and Measure is set to
-- the sum of the widths, so the manual's two rules can never disagree.
local function buildSteps(take, opt)
    local taps = take.taps
    local t0 = taps[1].on
    local bpm = (opt.mode == 2) and opt.bpm or 60
    local k = bpm / 60                                  -- beats per second
    local P, R = {}, {}
    for i, tp in ipairs(taps) do
        P[i] = (tp.on - t0) * k
        R[i] = (tp.off - t0) * k
    end
    local E = (take.endT - t0) * k
    local merged = 0

    if opt.mode == 2 then
        local g = GRID_BEATS[opt.grid] or 0.25
        local function q(x) return math.floor(x / g + 0.5) * g end
        local NP, NR = {}, {}
        for i = 1, #P do
            local p, r = q(P[i]), q(R[i])
            if #NP > 0 and p <= NP[#NP] + 1e-9 then
                if r > NR[#NR] then NR[#NR] = r end      -- same grid point as the tap before it
                merged = merged + 1
            else
                NP[#NP + 1], NR[#NR + 1] = p, r
            end
        end
        for i = 1, #NP do
            if NR[i] < NP[i] + g then NR[i] = NP[i] + g end                         -- at least one grid unit long
            if NP[i + 1] and NR[i] > NP[i + 1] - g / 2 then NR[i] = NP[i + 1] - g / 2 end   -- keep hits apart
        end
        P, R = NP, NR
        if opt.tail then
            E = math.floor(E + 0.5)                                                 -- whole beats
            if E < R[#R] then E = math.ceil(R[#R] - 1e-9) end
            if E < 1 then E = 1 end
        else
            E = R[#R]
        end
    else
        if not opt.tail or E < R[#R] then E = R[#R] end
    end

    local hi, lo = opt.hi or 100, opt.lo or 0
    local steps = {}
    local function push(v, w)
        local cont = false
        while w > 30 do                                  -- width tops out at 3200 %
            steps[#steps + 1] = { v = v, w = 30, cont = cont }
            w = w - 30
            cont = true
        end
        steps[#steps + 1] = { v = v, w = w, cont = cont }
    end
    for i = 1, #P do
        push(hi, R[i] - P[i])
        local off = (P[i + 1] or E) - R[i]
        if off > 1e-6 then push(lo, off) end
    end
    if #steps < 2 then steps[#steps + 1] = { v = lo, w = 0 } end

    local f = FEEL[opt.feel] or FEEL[1]
    local total = 0
    for _, s in ipairs(steps) do
        local e = (s.v == hi) and f.on or f.off
        if s.cont then e = { 0, 0, 0 } end
        s.trans, s.accel, s.decel = e[1], e[2], e[3]
        s.width = s.w * 100
        total = total + s.w
    end
    return { steps = steps, beats = total, bpm = bpm, taps = #P, merged = merged, seconds = total / k }
end

-- ---------------------------------------------------------------------
-- Writing the Shape
-- ---------------------------------------------------------------------
local function shapeSteps(shapeNo)
    local sh = handleOf("Shape " .. shapeNo)
    if sh == nil then return nil end
    local recipe = child(sh, 1)
    if recipe == nil then return sh, nil, nil end
    return sh, recipe, child(recipe, 1)
end

-- Reads the finished Shape back and compares it with the plan.
local function verifyShape(shapeNo, plan, attrName)
    local sh, recipe, steps = shapeSteps(shapeNo)
    if sh == nil then return false, "the shape does not exist" end
    if steps == nil then return false, "the shape has no phaser steps" end
    local n = count(steps)
    if n ~= #plan.steps then return false, fmt("the shape has %d steps, expected %d", n, #plan.steps) end
    local attr = handleOf('Attribute "' .. attrName .. '"')
    for i, want in ipairs(plan.steps) do
        local st = child(steps, i)
        if st == nil then return false, fmt("step %d is missing", i) end
        if count(st) ~= 1 then
            return false, fmt("step %d has %d value sources - other programmer values got into the shape", i, count(st))
        end
        local vs = child(st, 1)
        local v, w, t = tonumber(prop(vs, "ValueAbsolute")), tonumber(prop(vs, "WidthX")), tonumber(prop(vs, "TransX"))
        if not v or math.abs(v - want.v) > 0.6 then return false, fmt("step %d value is %s, expected %g", i, tostring(v), want.v) end
        if not w or math.abs(w - want.width) > 0.15 + want.width * 0.002 then
            return false, fmt("step %d width is %s, expected %.3f", i, tostring(w), want.width)
        end
        if not t or math.abs(t - want.trans) > 1 then return false, fmt("step %d transition is %s, expected %g", i, tostring(t), want.trans) end
        local ac, de = tonumber(prop(vs, "AccelX")), tonumber(prop(vs, "DecelX"))
        if ac and math.abs(ac - want.accel) > 1 then return false, fmt("step %d accel is %s, expected %g", i, tostring(ac), want.accel) end
        if de and math.abs(de - want.decel) > 1 then return false, fmt("step %d decel is %s, expected %g", i, tostring(de), want.decel) end
        local a = prop(vs, "Attributes")
        if attr ~= nil and a ~= nil and not same(a, attr) then
            return false, fmt("step %d is on %s, expected %s", i, show(a), attrName)
        end
    end
    local m = tonumber(prop(recipe, "Measure"))
    if not m or math.abs(m - plan.beats) > 0.01 then
        return true, fmt("steps are right, but Measure reads %s (wanted %.3f)", tostring(prop(recipe, "Measure")), plan.beats)
    end
    return true, nil
end

-- Route 1: make an empty Shape and write its steps directly. Leaves the programmer alone.
local function renderDirect(shapeNo, plan, attrName)
    log("--- route 1: write the Shape directly ---")
    local okc, made = pcall(function() return DataPool().Shapes:Create(shapeNo) end)
    log("DataPool().Shapes:Create(%d) -> %s", shapeNo,
        okc and (made ~= nil and ("<" .. cls(made) .. ">") or "nil") or ("error " .. tostring(made)))
    coroutine.yield(0.1)
    local sh, recipe, steps = shapeSteps(shapeNo)
    if sh == nil then return false, "an empty Shape could not be created" end
    local R = "Shape " .. shapeNo .. ".1"
    if recipe == nil then
        runq('Store Type "PhaserRecipe" %s', R)
        sh, recipe, steps = shapeSteps(shapeNo)
    end
    if recipe == nil or steps == nil then return false, "the new Shape has no phaser recipe inside" end
    local have, K = count(steps), #plan.steps
    log("new shape: <%s> with %d steps to start with, plan needs %d", cls(recipe), have, K)
    if have > K then return false, fmt("the new shape already has %d steps", have) end

    -- same order as the build that worked in a preset: values, LinkSteps, attribute, then more steps
    -- one property: plain number first (the form the probe proved), quoted as a second try
    local function setProp(target, name, value)
        if runq('Set %s Property "%s" %s', target, name, value) then return true end
        return runq('Set %s Property "%s" "%s"', target, name, value)
    end
    for i = 1, have do setProp(fmt("%s.1.%d", R, i), "ValueAbsolute", fmt("%g", plan.steps[i].v)) end
    runq('Set %s Property "LinkSteps" 0', R)
    for i = 1, have do runq('Assign Attribute "%s" At %s.1.%d.1', attrName, R, i) end
    for i = have + 1, K do
        if not runq("Store %s.2.1.%d /NoConfirm", R, i) then
            if not runq('Insert %s."PhaserRecipeSteps".%d', R, i) then
                return false, fmt("step %d could not be added", i)
            end
        end
    end
    for i, s in ipairs(plan.steps) do
        local target = fmt("%s.1.%d", R, i)
        if not runq('Set %s Property "ValueAbsolute" %g "WidthX" %.3f', target, s.v, s.width) then
            setProp(target, "ValueAbsolute", fmt("%g", s.v))
            setProp(target, "WidthX", fmt("%.3f", s.width))
        end
        -- A plain "TransX" 0 returns OK on this console but does not stick; the Curve
        -- presets do (Snap = transition 0, Linear = transition 100, accel/decel 0).
        if s.trans <= 0 then
            runq('Set %s Property "Curve" "Snap"', target)
        elseif s.trans >= 100 then
            runq('Set %s Property "Curve" "Linear"', target)
        else
            setProp(target, "TransX", fmt("%g", s.trans))
        end
        if s.accel ~= 0 then setProp(target, "AccelX", fmt("%g", s.accel)) end
        if s.decel ~= 0 then setProp(target, "DecelX", fmt("%g", s.decel)) end
    end
    setProp(R, "SpeedX", fmt("%g", plan.bpm))
    setProp(R, "Measure", fmt("%.4f", plan.beats))
    coroutine.yield(0.1)

    -- repair pass: any transition that still reads wrong gets the other spellings
    local _, _, now2 = shapeSteps(shapeNo)
    local repaired = 0
    for i, s in ipairs(plan.steps) do
        local st = now2 and child(now2, i)
        local vs = st and child(st, 1)
        local t = vs and tonumber(prop(vs, "TransX"))
        if t and math.abs(t - s.trans) > 1 then
            repaired = repaired + 1
            runq('Set %s.1.%d Property "TransX" "%g"', R, i, s.trans)
            t = tonumber(prop(vs, "TransX"))
            if t and math.abs(t - s.trans) > 1 then
                runq('Set %s.1.%d.1 Property "TransX" %g', R, i, s.trans)
            end
        end
    end
    if repaired > 0 then
        log("%d step transitions needed a second try", repaired)
        coroutine.yield(0.1)
    end
    return true
end

-- Route 2: the way the timing probe proved on this console. Writes a
-- programmer phaser on the selected fixture (Flicker Generator syntax),
-- stores that as the Shape, then knocks the attribute out again.
local function renderViaProgrammer(shapeNo, plan, attrName)
    log("--- route 2: programmer phaser, then Store Shape ---")
    if SelectionFirst() == nil then return false, "it needs one selected fixture that has a " .. attrName end
    runq("Attribute '%s'", attrName)
    runq("Delete Step 1 Thru Attribute '%s'", attrName)
    for i, s in ipairs(plan.steps) do runq("Step %d Attribute '%s' At Absolute %g", i, attrName, s.v) end
    for i, s in ipairs(plan.steps) do runq("Step %d Attribute '%s' Width %.3f", i, attrName, s.width) end
    for i, s in ipairs(plan.steps) do runq("Step %d Attribute '%s' Transition %g", i, attrName, s.trans) end
    for i, s in ipairs(plan.steps) do
        if s.accel ~= 0 then runq("Step %d Attribute '%s' Accel %g", i, attrName, s.accel) end
        if s.decel ~= 0 then runq("Step %d Attribute '%s' Decel %g", i, attrName, s.decel) end
    end
    runq("Step 1 Attribute '%s' Speed %g", attrName, plan.bpm)
    runq("Step 1 Attribute '%s' Measure %.4f", attrName, plan.beats)
    coroutine.yield(0.2)
    local okStore = runq("Store Shape %d /NoConfirm", shapeNo)
    runq("Delete Step 1 Thru Attribute '%s'", attrName)
    runq("Off Attribute '%s'", attrName)
    runq("Step 1")
    if not okStore then return false, "Store Shape failed" end
    return true
end

-- Returns: exists, verified, note
local function render(shapeNo, name, plan, attrName)
    if not slotFree("Shape", shapeNo) then          -- never write into, or delete, a shape that was already there
        return false, false, fmt("Shape %d already exists", shapeNo)
    end
    local ok, why = renderDirect(shapeNo, plan, attrName)
    local good, note = false, why
    if ok then good, note = verifyShape(shapeNo, plan, attrName) end
    log("route 1: %s", good and ("VERIFIED" .. (note and (" - " .. note) or "")) or ("not usable - " .. tostring(note)))
    if not good then
        if handleOf("Shape " .. shapeNo) ~= nil then runq("Delete Shape %d /NoConfirm", shapeNo) end
        ok, why = renderViaProgrammer(shapeNo, plan, attrName)
        if ok then good, note = verifyShape(shapeNo, plan, attrName) else good, note = false, why end
        log("route 2: %s", good and ("VERIFIED" .. (note and (" - " .. note) or "")) or ("not verified - " .. tostring(note)))
    end
    local sh = handleOf("Shape " .. shapeNo)
    if sh ~= nil then
        runq('Label Shape %d "%s"', shapeNo, name)
        flog("shape tree:")
        dumpTree(sh, "Shape " .. shapeNo, 6)
    end
    return sh ~= nil, good, note
end

-- ---------------------------------------------------------------------
-- The tap key: temp sequence on an executor, key = Flash
-- ---------------------------------------------------------------------
local function teardown(ctx)
    if ctx.tcNo then deleteOurs("Timecode " .. ctx.tcNo) ctx.tcNo = nil end
    if ctx.macNo then deleteOurs("Macro " .. ctx.macNo) ctx.macNo = nil end
    if ctx.seqNo then deleteOurs("Sequence " .. ctx.seqNo) ctx.seqNo = nil end
    if ctx.prev then                                  -- the key held something before: put it back
        if run("Assign %s At Executor %d", ctx.prev.addr, ctx.prev.no) then
            coroutine.yield(0.2)
            local ex = execByNumber(ctx.prev.no)
            if ex ~= nil and ctx.prev.key then pcall(function() ex.Key = ctx.prev.key end) end
        end
    end
    log("temp objects removed")
end

local function setupKey(execNo)
    local ctx = {}
    S.ctx = ctx
    ctx.seqNo = freeTempSlot("Sequence")
    if not ctx.seqNo then stop("No free sequence slot in %d-%d.", SLOT_LO, SLOT_HI) return nil end
    log("temp sequence slot: %d", ctx.seqNo)
    run("Store Sequence %d Cue 1 /NoConfirm", ctx.seqNo)
    ctx.seq = handleOf("Sequence " .. ctx.seqNo)
    if ctx.seq == nil then
        run("Store Sequence %d", ctx.seqNo)
        ctx.seq = handleOf("Sequence " .. ctx.seqNo)
    end
    if ctx.seq == nil then
        ctx.seqNo = nil
        stop("Could not create the temp sequence.")
        return nil
    end
    run('Label Sequence %d "%s"', ctx.seqNo, TEMPNAME)

    if execNo then
        local ex = execByNumber(execNo)
        local held = ex and assignedOf(ex)
        if held ~= nil then
            stop("Executor %d already holds %s.\nPick an empty executor, or leave Executor blank and press the key yourself.",
                execNo, addr(held))
            teardown(ctx)
            return nil
        end
        run("Assign Sequence %d At Executor %d", ctx.seqNo, execNo)
        coroutine.yield(0.3)
        ctx.ex = execByNumber(execNo) or findExecFor(ctx.seq)
        ctx.execNo = execNo
    else
        -- remember what every executor holds, so a key that was in use can be given back
        local before = {}
        for _, ex in ipairs(pageExecs()) do
            local a, no = assignedOf(ex), tonumber(prop(ex, "No"))
            if a ~= nil and no then before[no] = { no = no, addr = addr(a), key = prop(ex, "Key") } end
        end
        -- leave "Assign Sequence N At" in the command line: macro line with Execute = No
        local want = "Assign Sequence " .. ctx.seqNo .. " At"
        ctx.macNo = freeTempSlot("Macro")
        if ctx.macNo then
            run("Store Macro %d", ctx.macNo)
            local mac = handleOf("Macro " .. ctx.macNo)
            if mac ~= nil then
                run('Label Macro %d "%s"', ctx.macNo, TEMPNAME)
                local okl, line = pcall(function() return mac:Append() end)
                if okl and line ~= nil then
                    pcall(function() line.Command = want end)
                    if not pcall(function() line.Execute = false end) then pcall(function() line.Execute = "No" end) end
                    run("Go+ Macro %d", ctx.macNo)
                end
            else
                ctx.macNo = nil
            end
        end
        coroutine.yield(0.3)
        local okc, text = pcall(function() return CmdObj().CmdText end)
        local filled = okc and tostring(text):find("Assign", 1, true) ~= nil
        log("command line: '%s'%s", okc and tostring(text) or "?", filled and "" or "   (type  " .. want .. "  yourself)")
        log("waiting for you to press an executor key (60 s)...")
        local tw = now()
        while now() - tw < 60 do                       -- no Cmd() in here: it could wipe the command line
            ctx.ex = findExecFor(ctx.seq)
            if ctx.ex ~= nil then break end
            coroutine.yield(0.1)
        end
        if ctx.ex == nil then
            stop("No executor key was pressed within 60 seconds.")
            teardown(ctx)
            return nil
        end
        ctx.execNo = tonumber(prop(ctx.ex, "No"))
        if ctx.execNo and before[ctx.execNo] then
            ctx.prev = before[ctx.execNo]
            log("executor %d held %s - it will be put back afterwards", ctx.execNo, ctx.prev.addr)
        end
    end

    if ctx.ex ~= nil then
        local okk = pcall(function() ctx.ex.Key = "Flash" end)
        log("tap key: executor %s, Key='%s'%s", tostring(ctx.execNo), tostring(prop(ctx.ex, "Key")), okk and "" or "  (setting Key failed)")
    elseif ctx.execNo then
        run('Set Executor %d Property "Key" "Flash"', ctx.execNo)
    end
    return ctx
end

-- ---------------------------------------------------------------------
-- Recording one take with a temp timecode
-- ---------------------------------------------------------------------
local function collectEvents(o, out, depth)
    if depth > 8 then return end
    if cls(o) == "CmdEvent" then
        local raw = tonumber(prop(o, "RawTime"))
        if raw then
            local status, name = tostring(prop(o, "Status")), tostring(prop(o, "Name"))
            local on
            if status == "On" then on = true
            elseif status == "Off" then on = false
            else on = name:find("Release", 1, true) == nil end
            out[#out + 1] = { t = raw / TIME_T, on = on, name = name, status = status }
        end
        return
    end
    for i = 1, count(o) do
        local k = child(o, i)
        if k ~= nil then collectEvents(k, out, depth + 1) end
    end
end

-- Is this timecode track the one that recorded OUR temp sequence?
local function isOurTrack(track, seq, seqNo)
    local target = prop(track, "Target")
    if target ~= nil and same(target, seq) then return true, "target" end
    local pat = "Sequence " .. seqNo .. "%f[%D]"
    for _, name in ipairs({ "Target", "Object", "Name" }) do
        local d = disp(track, name)
        if d:find(pat) or d:find(TEMPNAME, 1, true) or d:find(RECNAME, 1, true) then return true, "label " .. name end
    end
    return false
end

-- Only the track that recorded our own sequence. Anything else that ran or was
-- touched during the take sits in other tracks of the temp timecode and is ignored.
-- Returns events (or nil when our track cannot be identified), and a note.
local function ourEvents(tc, seq, seqNo)
    local own, others, otherTracks, candidates = {}, 0, 0, {}
    for g = 1, count(tc) do
        local tg = child(tc, g)
        for t = 1, tg and count(tg) or 0 do
            local track = child(tg, t)
            if track ~= nil then
                local evs = {}
                collectEvents(track, evs, 0)
                local mine, how = isOurTrack(track, seq, seqNo)
                if mine then
                    flog("  track %d.%d '%s': ours (%s), %d events", g, t, tostring(prop(track, "Name")), how, #evs)
                    for _, e in ipairs(evs) do own[#own + 1] = e end
                elseif #evs > 0 then
                    flog("  track %d.%d '%s': not ours, %d events ignored", g, t, tostring(prop(track, "Name")), #evs)
                    others, otherTracks = others + #evs, otherTracks + 1
                    candidates[#candidates + 1] = evs
                end
            end
        end
    end
    if #own == 0 and otherTracks == 1 then
        -- exactly one track recorded anything, so it can only be the tap key
        log("the tap track carried no recognisable label; it is the only track, so it is used")
        own, others, otherTracks = candidates[1], 0, 0
    elseif #own == 0 and otherTracks > 1 then
        return nil, fmt("%d tracks were recorded and none could be identified as the tap key", otherTracks)
    end
    -- the tap key only ever sends Flash on and Flash off
    local taps = {}
    for _, e in ipairs(own) do
        if e.name:find("Flash", 1, true) or e.status == "On" or e.status == "Off" then taps[#taps + 1] = e end
    end
    table.sort(taps, function(x, y) return x.t < y.t end)
    local note = nil
    if otherTracks > 0 then
        note = fmt("%d events from %d other playbacks were recorded during the take and ignored", others, otherTracks)
        log("%s", note)
    end
    return taps, note
end

-- Timecodes that are running right now (other than ours). If one of them is
-- recording, the taps would land in it as well.
local function otherRunningTimecodes(exceptNo)
    local list = {}
    local ok, kids = pcall(function() return DataPool().Timecodes:Children() end)
    if not ok or type(kids) ~= "table" then return list end
    for _, tc in ipairs(kids) do
        local no = tonumber(prop(tc, "No"))
        local okr, running = pcall(function() return tc:IsRunningPlayback() end)
        if okr and running and no ~= exceptNo then
            list[#list + 1] = fmt("Timecode %s '%s'", tostring(no), tostring(prop(tc, "Name")))
        end
    end
    return list
end

-- Returns take { taps = { {on, off}, ... }, endT }  (seconds on the timecode clock), or nil.
local function recordTake(ctx)
    local tcNo = freeTempSlot("Timecode")
    if not tcNo then stop("No free timecode slot in %d-%d.", SLOT_LO, SLOT_HI) return nil end
    run("Store Timecode %d", tcNo)
    local tc = handleOf("Timecode " .. tcNo)
    if tc == nil then stop("Could not create the temp timecode.") return nil end
    ctx.tcNo = tcNo
    run('Label Timecode %d "%s"', tcNo, TEMPNAME)
    run('Set Timecode %d Property "Duration" "%d"', tcNo, MAX_REC + 30)

    -- Stopping this timecode must never switch off playbacks it happened to record.
    pcall(function() tc.SwitchOff = false end)
    if disp(tc, "SwitchOff") ~= "Keep Playbacks" then
        runq('Set Timecode %d Property "SwitchOff" "Keep Playbacks"', tcNo)
    end
    local keeps = disp(tc, "SwitchOff")
    log("temp timecode %d: SwitchOff = '%s'", tcNo, keeps)
    local warn = ""
    if keeps ~= "Keep Playbacks" then
        warn = warn .. "\n\nWARNING: this timecode could not be set to keep playbacks. Anything else\n" ..
               "you trigger during the take may be switched off when the take ends."
    end
    local running = otherRunningTimecodes(tcNo)
    if #running > 0 then
        log("other timecodes running: %s", table.concat(running, ", "))
        warn = warn .. "\n\nNOTE: " .. table.concat(running, ", ") .. (#running == 1 and " is" or " are") ..
               " running.\nIf it is recording, your taps will be recorded there too."
    end

    local res = MessageBox({
        title = "Tap Phaser - ready",
        message = fmt("Tap key: executor %s (Flash).\n\nPress Record, then tap your rhythm. The loop starts on your first press.\n\n" ..
                      "To END: run this plugin again.\nThe pause between your last release and End is the tail;\n" ..
                      "you choose afterwards whether to keep it.\n\nOther playbacks can keep running; only this key is read.\n" ..
                      "Recording stops by itself after %d seconds.%s",
                      tostring(ctx.execNo or "?"), MAX_REC, warn),
        commands = { { value = 1, name = "Record" }, { value = 0, name = "Cancel" } },
    })
    if type(res) ~= "table" or res.result ~= 1 then
        log("cancelled before recording")
        return nil
    end

    run("Record Timecode %d", tcNo)
    local tRec = now()
    S.endAt = nil
    S.phase = "recording"
    pcall(function() ctx.seq.Name = RECNAME end)
    log(">>> recording - run the plugin again to END <<<")
    while S.endAt == nil and now() - tRec < MAX_REC do coroutine.yield(0.03) end
    local endClock = S.endAt or now()
    S.phase, S.since = "busy", now()
    local cursor = prop(tc, "Cursor")
    pcall(function() ctx.seq.Name = TEMPNAME end)
    run("Off Timecode %d", tcNo)
    coroutine.yield(0.25)

    local endT = endClock - tRec
    log("END %.3f s after Record (timecode cursor read: %s)", endT, tostring(cursor))
    local evs, note = ourEvents(tc, ctx.seq, ctx.seqNo)
    if evs == nil then
        flog("timecode tree (track could not be identified):")
        dumpTree(tc, "Timecode " .. tcNo, 4)
        deleteOurs("Timecode " .. tcNo)
        ctx.tcNo = nil
        notice("Tap Phaser", "The take could not be read:\n%s.\n\nNothing was written. The details are in the log.", tostring(note))
        return { taps = {}, endT = endT, unreadable = true }
    end
    local taps, open, strays = {}, nil, 0
    for _, e in ipairs(evs) do
        flog("  event t=%8.3f  %s  (%s / %s)", e.t, e.on and "PRESS  " or "RELEASE", e.name, e.status)
        if e.on then
            open = e.t
        elseif open then
            taps[#taps + 1] = { on = open, off = math.max(e.t, open + 0.001) }
            open = nil
        else
            strays = strays + 1                       -- a release with no press: the key used to assign
        end
    end
    if open then taps[#taps + 1] = { on = open, off = math.max(endT, open + 0.02) } end
    if #taps > 0 and endT < taps[#taps].off then endT = taps[#taps].off end
    log("%d events -> %d taps (%d stray releases ignored)", #evs, #taps, strays)
    for i, tp in ipairs(taps) do
        local gap = taps[i + 1] and (taps[i + 1].on - tp.off) or (endT - tp.off)
        log("  tap %2d  press=%7.3f  hold=%6.3f  then %6.3f s%s", i, tp.on - taps[1].on, tp.off - tp.on, gap,
            taps[i + 1] and "" or " (tail)")
    end
    deleteOurs("Timecode " .. tcNo)
    ctx.tcNo = nil
    return { taps = taps, endT = endT, note = note }
end

-- ---------------------------------------------------------------------
-- Dialogs
-- ---------------------------------------------------------------------
local function loadSettings()
    return {
        exec = getVar("TapPhaser_exec") or "",
        mode = tonumber(getVar("TapPhaser_mode")) or 1,
        bpm  = tonumber(getVar("TapPhaser_bpm")) or 120,
        grid = tonumber(getVar("TapPhaser_grid")) or 3,
        feel = tonumber(getVar("TapPhaser_feel")) or 1,
    }
end

local function askParams(st)
    local res = MessageBox({
        title = "Tap Phaser " .. VERSION,
        message = "Tap a rhythm on an executor key and get it back as a Shape.\n\n" ..
                  "EXECUTOR: an EMPTY executor on this page to tap on.\n" ..
                  "Blank = 'Assign Sequence N At' appears in the command line\n" ..
                  "and you press the key yourself.\n\n" ..
                  "FREE keeps your timing exactly. BPM snaps it to the grid at that tempo.\n" ..
                  "SHAPE NUMBER blank = first free one.\n\n" ..
                  "Whatever is in the programmer is what flashes while you tap.",
        commands = {
            { value = 1, name = "Start" },
            { value = 2, name = "Re-render last take" },
            { value = 0, name = "Cancel" },
        },
        inputs = {
            { name = "Executor", value = st.exec, whiteFilter = "0123456789" },
            { name = "BPM", value = fmt("%g", st.bpm), whiteFilter = "0123456789." },
            { name = "Shape number", value = "", whiteFilter = "0123456789" },
            { name = "Name", value = "" },
        },
        selectors = {
            { name = "Mode", type = 1, selectedValue = st.mode, values = { ["Free"] = 1, ["BPM"] = 2 } },
            { name = "Grid", type = 0, selectedValue = st.grid,
              values = { ["1/4"] = 1, ["1/8"] = 2, ["1/16"] = 3, ["1/8 T"] = 4, ["1/16 T"] = 5 } },
            { name = "Feel", type = 0, selectedValue = st.feel,
              values = { ["Snap"] = 1, ["Pluck"] = 2, ["Swell"] = 3, ["Smooth"] = 4 } },
        },
    })
    flog("params dialog returned: %s", kv(res, 3))
    if type(res) ~= "table" or res.success == false then return nil end
    local choice = tonumber(res.result) or 0
    if choice == 0 then return nil end
    local opt = {
        choice  = choice,
        execNo  = tonumber(inputOf(res, "Executor", "")),
        bpm     = tonumber(inputOf(res, "BPM", "")) or st.bpm,
        shapeNo = tonumber(inputOf(res, "Shape number", "")),
        name    = inputOf(res, "Name", ""),
        mode    = selOf(res, "Mode", st.mode),
        grid    = selOf(res, "Grid", st.grid),
        feel    = selOf(res, "Feel", st.feel),
        hi = 100, lo = 0,
    }
    if opt.bpm < 20 then opt.bpm = 20 end
    if opt.bpm > 400 then opt.bpm = 400 end
    if not GRID_BEATS[opt.grid] then opt.grid = 3 end
    if not FEEL[opt.feel] then opt.feel = 1 end
    if opt.mode ~= 2 then opt.mode = 1 end
    setVar("TapPhaser_exec", opt.execNo or "")
    setVar("TapPhaser_mode", opt.mode)
    setVar("TapPhaser_bpm", opt.bpm)
    setVar("TapPhaser_grid", opt.grid)
    setVar("TapPhaser_feel", opt.feel)
    return opt
end

-- 1 = keep tail, 2 = chop, 3 = retake, 0 = cancel
local function review(take, opt, allowRetake)
    local keep = buildSteps(take, { mode = opt.mode, bpm = opt.bpm, grid = opt.grid, feel = opt.feel, tail = true })
    local chop = buildSteps(take, { mode = opt.mode, bpm = opt.bpm, grid = opt.grid, feel = opt.feel, tail = false })
    local function len(p)
        if opt.mode == 2 then return fmt("%.2f beats at %g BPM (%.2f s)", p.beats, p.bpm, p.seconds) end
        return fmt("%.2f s", p.seconds)
    end
    local msg = fmt("%d taps recorded%s.\n\nKEEP TAIL: loop is %s\nCHOP at the last release: loop is %s%s",
        #take.taps, keep.merged > 0 and fmt(" (%d landed on the same grid point and were merged)", keep.merged) or "",
        len(keep), len(chop), take.note and ("\n\n(" .. take.note .. ")") or "")
    local commands = { { value = 1, name = "Keep tail" }, { value = 2, name = "Chop" } }
    if allowRetake then commands[#commands + 1] = { value = 3, name = "Retake" } end
    commands[#commands + 1] = { value = 0, name = "Cancel" }
    local res = MessageBox({ title = "Tap Phaser - your take", message = msg, commands = commands })
    if type(res) ~= "table" or res.success == false then return 0 end
    return tonumber(res.result) or 0
end

-- ---------------------------------------------------------------------
-- One session
-- ---------------------------------------------------------------------
local function session()
    local opt = askParams(loadSettings())
    if not opt then log("cancelled") return end
    log("mode=%s  bpm=%g  grid=%s  feel=%s  executor=%s  shape=%s", opt.mode == 2 and "BPM" or "Free", opt.bpm,
        GRID_NAME[opt.grid], FEEL_NAME[opt.feel], tostring(opt.execNo or "blank"), tostring(opt.shapeNo or "first free"))

    local take
    if opt.choice == 2 then
        take = S.last or decodeTake(getVar("TapPhaser_take"))
        if not take then stop("There is no earlier take to re-render.") return end
        local c = review(take, opt, false)
        if c ~= 1 and c ~= 2 then log("cancelled") return end
        opt.tail = (c == 1)
    else
        sweepLeftovers()
        local ctx = setupKey(opt.execNo)
        if not ctx then return end
        while true do
            take = recordTake(ctx)
            if not take then break end
            if #take.taps == 0 then
                local what = take.unreadable and "That take could not be used." or "No taps were recorded."
                take = nil
                local okc, again = pcall(Confirm, "Tap Phaser", what .. "\n\nTry again?", nil, false)
                if not (okc and again) then break end
            else
                S.last = take
                setVar("TapPhaser_take", encodeTake(take))
                local c = review(take, opt, true)
                if c == 1 or c == 2 then
                    opt.tail = (c == 1)
                    break
                elseif c ~= 3 then
                    take = nil
                    break
                end
            end
        end
        teardown(ctx)
        S.ctx = nil
        if not take then log("no take - nothing written") return end
    end

    local plan = buildSteps(take, opt)
    log("plan: %d steps, loop %.3f beats at %g BPM = %.3f s  (%s)", #plan.steps, plan.beats, plan.bpm, plan.seconds,
        opt.tail and "tail kept" or "chopped")
    for i, s in ipairs(plan.steps) do
        flog("  step %2d  value=%3g  width=%8.3f %%  (%.3f s)  trans=%g accel=%g decel=%g", i, s.v, s.width,
            s.w * 60 / plan.bpm, s.trans, s.accel, s.decel)
    end

    local shapeNo = opt.shapeNo
    if shapeNo then
        if handleOf("Shape " .. shapeNo) ~= nil then
            local okc, yes = pcall(Confirm, "Tap Phaser", fmt("Shape %d already exists.\n\nReplace it?", shapeNo), nil, false)
            if not (okc and yes) then log("kept the existing shape - nothing written") return end
            run("Delete Shape %d /NoConfirm", shapeNo)
            coroutine.yield(0.1)
        end
    else
        for n = 1, 9999 do
            if slotFree("Shape", n) then shapeNo = n break end
        end
        if not shapeNo then stop("No free Shape slot.") return end
    end
    local name = (opt.name ~= "" and opt.name) or ("Tap " .. os.date("%H%M%S"))
    name = name:gsub('"', "'")

    local exists, good, note = render(shapeNo, name, plan, "Dimmer")
    if not exists then
        stop("The Shape could not be written:\n%s\n\nYour take is kept. Select one fixture with a dimmer, clear the\nprogrammer, and use 'Re-render last take'.", tostring(note))
        return
    end
    local msg = fmt("Shape %d '%s'\n%d steps, loop %s\n\n%s", shapeNo, name, #plan.steps,
        opt.mode == 2 and fmt("%.2f beats at %g BPM", plan.beats, plan.bpm) or fmt("%.2f s", plan.seconds),
        good and (note and ("Checked - " .. note) or "Checked: the shape reads back exactly as planned.")
             or ("Written, but it reads back differently:\n" .. tostring(note)))
    log("%s", (msg:gsub("\n", " | ")))
    local res = MessageBox({ title = "Tap Phaser - done", message = msg .. "\n\nCall it on your current selection now?",
        commands = { { value = 1, name = "Call on selection" }, { value = 0, name = "Close" } } })
    if type(res) == "table" and res.result == 1 then
        if SelectionFirst() == nil then
            notice("Tap Phaser", "Nothing is selected, so the shape was not called.")
        else
            run("At Shape %d", shapeNo)
        end
    end
end

-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------
function Main(display_handle, args)
    if S.phase == "recording" then           -- second launch while recording = END
        S.endAt = now()
        return
    end
    if S.phase ~= nil and (now() - S.since) < 240 then
        pcall(MessageBox, { title = "Tap Phaser", commands = { { value = 1, name = "OK" } },
            message = "Tap Phaser is still finishing the last take.\nGive it a moment, then start it again." })
        return
    end
    S.phase, S.since, S.endAt = "busy", now(), nil
    buf = {}
    flog("")
    flog("===== Tap Phaser %s   %s =====", VERSION, os.date("%Y-%m-%d %H:%M:%S"))
    local trace = (debug and debug.traceback) or function(e) return e end
    local ok, e = xpcall(session, trace)
    if not ok then
        err("crashed: %s", tostring(e))
        if S.ctx then pcall(teardown, S.ctx) end
        pcall(MessageBox, { title = "Tap Phaser crashed", commands = { { value = 1, name = "OK" } },
            message = "Something went wrong. The details are in the log file:\n" .. tostring(logPath()) })
    end
    S.phase, S.ctx = nil, nil
    flush()
end

return Main
