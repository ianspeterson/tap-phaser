-- =====================================================================
-- TapPhaser Probe   v0.3.0   2026-10-11
-- Created by Ian Peterson
--
-- Diagnostic plugin for the tap-to-phaser project. It builds nothing you
-- keep: every probe makes scratch objects named "TAP PROBE TEMP" in the
-- 9901+ range and offers to delete them at the end.
--
--   1  Clock        what clocks exist and how fast Lua can poll
--   2  Tap capture  temp sequence -> you assign it to a key -> tap for N s.
--                   Captures the same taps three ways: Lua polling,
--                   object-change hooks, and a timecode recording.
--   3  Phaser time  writes Dimmer phasers on the selected fixture and
--                   measures the real output: what Width, Transition,
--                   Speed and Measure do to step length and cycle length.
--   4  Recipe       builds a phaser recipe in a scratch preset with the
--                   syntax from MA's own 2.5.1 tests and the ACT article,
--                   dumps its structure, and times it.
--
-- Everything is printed to Command Line History and appended to
--   <gma3_library>/TapPhaserProbe_log.txt   (object dumps go to the file only)
--
-- Run one probe directly:  Plugin "TapPhaser Probe" "2"
-- =====================================================================

local pluginName, componentName, signalTable, myHandle = select(1, ...)

local VERSION  = "0.3.0"
local PREFIX   = "[TapProbe] "
local LOGNAME  = "TapPhaserProbe_log.txt"
local TEMPNAME = "TAP PROBE TEMP"
local TIME_T   = 16777216      -- MA's internal 2^24 unit for times and values (from MA's own tests)
local SLOT_LO, SLOT_HI = 9901, 9990

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

-- Readout settings decide how plain numbers in commands are read, so log them.
local function logReadouts()
    local ok, prof = pcall(CurrentProfile)
    if not ok or prof == nil then log("CurrentProfile() not readable") return end
    local found = {}
    for _, p in ipairs(props(prof)) do
        if p[1]:lower():find("readout", 1, true) then found[#found + 1] = p[1] .. "=" .. p[2] end
    end
    log("user profile readouts: %s", #found > 0 and table.concat(found, "   ") or "(no property with 'readout' in its name)")
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

local function confirmDelete(what, commands)
    local ok, yes = pcall(Confirm, "TapPhaser Probe", "Delete the scratch objects?\n\n" .. what ..
        "\n\nNo = keep them so you can look at them.", nil, false)
    if ok and yes then
        for _, c in ipairs(commands) do run("%s", c) end
    else
        log("kept: %s", what)
    end
end

local function logApi()
    local names = { "Time", "Timer", "HookObjectChange", "UnHook", "Unhook", "CmdObj", "CurrentExecPage",
        "GetExecutor", "GetUIChannel", "GetRTChannel", "GetDMXValue", "GetProgPhaser", "SetProgPhaser",
        "GetProgPhaserValue", "SetProgPhaserValue", "GetPresetData", "SampleOutput", "SelectedSequence",
        "SelectedTimecode", "HandleToInt", "GetButton", "SelectionTable" }
    local have, missing = {}, {}
    for _, n in ipairs(names) do
        if apiHas(n) then have[#have + 1] = n else missing[#missing + 1] = n end
    end
    log("API present: %s", table.concat(have, " "))
    log("API MISSING: %s", #missing > 0 and table.concat(missing, " ") or "(none)")
end

-- ---------------------------------------------------------------------
-- PROBE 1: environment and clock
-- ---------------------------------------------------------------------
local function probeClock()
    log("=== PROBE 1: environment and clock ===")
    for _, f in ipairs({ "Version", "HostType", "HostSubType", "HostOS" }) do
        if apiHas(f) then
            local ok, v = pcall(_G[f])
            log("%s() = %s", f, ok and tostring(v) or "<err>")
        end
    end

    logApi()
    logReadouts()

    local function ms()
        local ok, v = pcall(function() return tonumber(Root().StationSettings.TimeConfig.localtimems) end)
        return ok and v or nil
    end
    local tA, msA = now(), ms()
    log("clock used for timing: %s   localtimems readable: %s", clockName, tostring(msA ~= nil))

    local modes = {
        { "yield(0.001)",   0.001 },
        { "yield(0.005)",   0.005 },
        { "yield(0.02)",    0.02 },
        { "yield({rt=1})",  { rt = 1 } },
        { "yield({ui=1})",  { ui = 1 } },
    }
    log("poll interval actually achieved, in ms (120 yields each):")
    for _, m in ipairs(modes) do
        local ok, e = pcall(function()
            local d = {}
            local prev = now()
            for _ = 1, 120 do
                coroutine.yield(m[2])
                local t = now()
                d[#d + 1] = (t - prev) * 1000
                prev = t
            end
            table.sort(d)
            log("  %-15s min=%7.2f  median=%7.2f  p95=%7.2f  max=%7.2f", m[1],
                d[1], d[(#d + 1) // 2], d[math.ceil(#d * 0.95)], d[#d])
        end)
        if not ok then err("  %s failed: %s", m[1], tostring(e)) end
    end

    local tB, msB = now(), ms()
    if msA and msB then
        log("elapsed: %s %.3f s   localtimems %.3f s", clockName, tB - tA, (msB - msA) / 1000)
    end
end

-- ---------------------------------------------------------------------
-- PROBE 2: tap capture
-- ---------------------------------------------------------------------
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

local function collectTimed(o, path, out, depth)
    if depth > 8 then return end
    local raw = tonumber(prop(o, "RawTime"))
    if raw ~= nil and cls(o) ~= "Timecode" then out[#out + 1] = { path = path, obj = o, raw = raw } end
    for i = 1, count(o) do
        local k = child(o, i)
        if k ~= nil then collectTimed(k, path .. "." .. i, out, depth + 1) end
    end
end

-- A stop the user can't miss: popup as well as the red line.
local function stop(f, ...)
    local s = fmt(f, ...)
    err("%s", s)
    pcall(MessageBox, { title = "TapPhaser Probe stopped", message = s, commands = { { value = 1, name = "OK" } } })
end

local function probeTap()
    log("=== PROBE 2: tap capture ===")
    local res = MessageBox({
        title = "Tap capture probe",
        message = "EXECUTOR = the key you want to tap on (current page), e.g. 201.\n" ..
                  "  - empty executor: the probe puts a temp sequence there, key = Flash\n" ..
                  "  - executor with a sequence: the probe watches that one as it is\n" ..
                  "  - leave blank: the probe leaves 'Assign Sequence N At' in the\n" ..
                  "    command line and you press the executor key yourself\n\n" ..
                  "Recording runs for the seconds below and starts when the temp\n" ..
                  "sequence's label reads TAP NOW. Mix short taps and long holds.",
        commands = { { value = 1, name = "Start" }, { value = 0, name = "Cancel" } },
        inputs = {
            { name = "Executor", value = "", whiteFilter = "0123456789" },
            { name = "Seconds", value = "12", whiteFilter = "0123456789" },
        },
    })
    log("dialog returned: %s", kv(res, 3))
    if type(res) ~= "table" or res.result ~= 1 then log("cancelled") return end
    local execNo = tonumber(inputOf(res, "Executor", ""))
    local dur = tonumber(inputOf(res, "Seconds", "12")) or 12
    if dur < 3 then dur = 3 end
    if dur > 60 then dur = 60 end

    local seq, ex, seqNo, macNo, tcNo
    local own = false                     -- true when the sequence is the probe's temp one

    local function makeTempSequence()
        seqNo = freeNumber("Sequence %d")
        if not seqNo then stop("No free sequence slot in %d-%d.", SLOT_LO, SLOT_HI) return false end
        run("Store Sequence %d Cue 1 /NoConfirm", seqNo)
        seq = handleOf("Sequence " .. seqNo)
        if seq == nil then
            run("Store Sequence %d", seqNo)
            seq = handleOf("Sequence " .. seqNo)
        end
        if seq == nil then
            stop("Could not create Sequence %d.\nPut any sequence on an executor yourself, set its key to Flash,\nand run this probe again with that executor number.", seqNo)
            return false
        end
        own = true
        run('Label Sequence %d "%s"', seqNo, TEMPNAME)
        log("temp sequence %d: children=%d (cues start after OffCue/CueZero)", seqNo, count(seq))
        return true
    end

    local function cleanupEarly()
        local what, cmds = {}, {}
        if macNo then what[#what + 1] = "Macro " .. macNo cmds[#cmds + 1] = "Delete Macro " .. macNo .. " /NoConfirm" end
        if own and seqNo then what[#what + 1] = "Sequence " .. seqNo cmds[#cmds + 1] = "Delete Sequence " .. seqNo .. " /NoConfirm" end
        if #cmds > 0 then confirmDelete(table.concat(what, ", "), cmds) end
    end

    if execNo then
        -- executor number given ----------------------------------------------------
        ex = execByNumber(execNo)
        if ex ~= nil then
            seq = assignedOf(ex)
            log("executor %d holds: %s", execNo, seq ~= nil and (cls(seq) .. " " .. addr(seq)) or "nothing readable")
        end
        if seq == nil then
            if not makeTempSequence() then return end
            run("Assign Sequence %d At Executor %d", seqNo, execNo)
            coroutine.yield(0.3)
            ex = execByNumber(execNo) or findExecFor(seq)
            if ex == nil then
                log("the assignment is not visible from Lua - carrying on with the sequence only")
            end
        end
    else
        -- blank: prefill the command line (macro line with Execute = No, MA's own method) ----
        if not makeTempSequence() then return end
        local want = "Assign Sequence " .. seqNo .. " At"
        macNo = freeNumber("Macro %d")
        if macNo then
            run("Store Macro %d", macNo)
            local mac = handleOf("Macro " .. macNo)
            if mac ~= nil then
                run('Label Macro %d "%s"', macNo, TEMPNAME)
                local okl, line = pcall(function() return mac:Append() end)
                if okl and line ~= nil then
                    local ok1, e1 = pcall(function() line.Command = want end)
                    local ok2, e2 = pcall(function() line.Execute = false end)
                    if not ok2 then ok2, e2 = pcall(function() line.Execute = "No" end) end
                    log("macro line: set Command %s, set Execute=No %s   readback Command='%s' Execute=%s",
                        ok1 and "ok" or ("FAIL " .. tostring(e1)), ok2 and "ok" or ("FAIL " .. tostring(e2)),
                        tostring(prop(line, "Command")), tostring(prop(line, "Execute")))
                    flog("macro line properties:")
                    for _, p in ipairs(props(line)) do flog("    %s = %s", p[1], p[2]) end
                    run("Go+ Macro %d", macNo)
                else
                    err("could not append a macro line: %s", tostring(line))
                end
            end
        end
        coroutine.yield(0.3)
        local okc, text = pcall(function() return CmdObj().CmdText end)
        log("command line after macro: '%s'", okc and tostring(text) or "<CmdObj().CmdText unreadable>")
        local prefilled = okc and tostring(text):find("Assign", 1, true) ~= nil
        if not prefilled then
            local okw, ew = pcall(function() CmdObj().CmdText = want .. " " end)
            coroutine.yield(0.3)
            local okr, text2 = pcall(function() return CmdObj().CmdText end)
            log("direct CmdObj().CmdText write: %s   command line now: '%s'",
                okw and "no error" or ("FAIL " .. tostring(ew)), okr and tostring(text2) or "?")
            prefilled = okr and tostring(text2):find("Assign", 1, true) ~= nil
        end
        log("PREFILL %s. Now press the executor key you want to tap on (waiting 45 s)%s",
            prefilled and "WORKED" or "DID NOT WORK",
            prefilled and "" or " - type  " .. want .. "  yourself, then press the key")

        -- wait for the assignment. No Cmd() here: it could wipe the command line.
        local tw = now()
        while now() - tw < 45 do
            ex = findExecFor(seq)
            if ex ~= nil then break end
            coroutine.yield(0.1)
        end
        if ex ~= nil then
            log("assignment seen after %.1f s", now() - tw)
        else
            log("assignment not seen within 45 s")
            local s = TextInput("Which executor did you put Sequence " .. seqNo .. " on? (blank = stop)", "")
            execNo = tonumber(s or "")
            if not execNo then
                stop("No executor chosen, so there is nothing to tap on.")
                cleanupEarly()
                return
            end
            ex = execByNumber(execNo)
            if ex == nil or assignedOf(ex) == nil then
                run("Assign Sequence %d At Executor %d", seqNo, execNo)
                coroutine.yield(0.3)
                ex = execByNumber(execNo) or findExecFor(seq)
            end
        end
    end

    if seq == nil then
        stop("Nothing to watch: no sequence could be created or found.")
        cleanupEarly()
        return
    end

    -- executor facts ------------------------------------------------------
    for _, en in ipairs({ "AssignmentButtonFunctions", "AssignmentButtonFunctionsTimecode" }) do
        local t = Enums and Enums[en]
        if type(t) == "table" then
            local keys = {}
            for k, v in pairs(t) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
            table.sort(keys)
            flog("Enums.%s (%d): %s", en, #keys, table.concat(keys, "  "))
            log("Enums.%s: %d entries, Flash=%s Temp=%s Swop=%s", en, #keys,
                tostring(t.Flash), tostring(t.Temp), tostring(t.Swop))
        else
            log("Enums.%s = %s", en, type(t))
        end
    end
    log("watching: %s <%s> '%s'", addr(seq), cls(seq), tostring(prop(seq, "Name")))
    if ex ~= nil then
        log("executor: addr=%s  class=%s  No=%s  Index=%s  Key='%s'",
            addr(ex), cls(ex), tostring(prop(ex, "No")), tostring(select(2, pcall(function() return ex:Index() end))),
            tostring(prop(ex, "Key")))
        flog("executor properties:")
        for _, p in ipairs(props(ex)) do flog("    %s = %s", p[1], p[2]) end
        if own then
            local okk, ek = pcall(function() ex.Key = "Flash" end)
            log("set Key = Flash: %s   readback Key='%s'", okk and "no error" or ("FAIL " .. tostring(ek)),
                tostring(prop(ex, "Key")))
        else
            log("your own sequence: Key left as it is ('%s'). Use Flash or Temp for a press/release test.",
                tostring(prop(ex, "Key")))
        end
    elseif own and execNo then
        run('Set Executor %d Property "Key" "Flash"', execNo)
    end

    -- timecode recording in parallel -----------------------------------------
    local tc, tRec
    tcNo = freeNumber("Timecode %d")
    if tcNo then
        run("Store Timecode %d", tcNo)
        tc = handleOf("Timecode " .. tcNo)
        if tc ~= nil then
            run('Label Timecode %d "%s"', tcNo, TEMPNAME)
            run('Set Timecode %d Property "Duration" "%d"', tcNo, dur + 15)
            run("Record Timecode %d", tcNo)
            tRec = now()
            coroutine.yield(0.2)
            log("timecode %d after Record: IsRunningPlayback=%s", tcNo,
                tostring(select(2, pcall(function() return tc:IsRunningPlayback() end))))
        end
    end

    -- signals to poll -----------------------------------------------------------
    local signals = {}
    local function addSignal(name, fn)
        local ok, v = pcall(fn)
        if ok then
            signals[#signals + 1] = { name = name, fn = fn }
            log("signal %-18s available, idle value = %s", name, tostring(v))
        else
            log("signal %-18s NOT available (%s)", name, tostring(v))
        end
    end
    addSignal("IsRunningPlayback", function() return seq:IsRunningPlayback() end)
    addSignal("HasActivePlayback", function() return seq:HasActivePlayback() end)
    addSignal("CurrentChild", function()
        local c = seq:CurrentChild()
        if c == nil then return "nil" end
        return tostring(prop(c, "Name")) .. "#" .. tostring(select(2, pcall(function() return c:Index() end)))
    end)

    -- hooks ---------------------------------------------------------------------
    local events, hookIds, hookCount, t0 = {}, {}, 0, now()
    if apiHas("HookObjectChange") and myHandle ~= nil then
        local okp, plug = pcall(function() return myHandle:Parent() end)
        local function hook(label, obj)
            local okh, id = pcall(HookObjectChange, function(...)
                hookCount = hookCount + 1
                if hookCount <= 80 then
                    local parts = {}
                    for i = 1, math.min(select("#", ...), 3) do parts[#parts + 1] = show((select(i, ...))) end
                    events[#events + 1] = { t = now() - t0, sig = "hook:" .. label, val = table.concat(parts, " , ") }
                end
            end, obj, okp and plug or myHandle)
            log("HookObjectChange on %s: %s", label, okh and ("id " .. tostring(id)) or ("FAIL " .. tostring(id)))
            if okh and id ~= nil then hookIds[#hookIds + 1] = id end
        end
        hook("sequence", seq)
        if ex ~= nil then hook("executor", ex) end
    else
        log("hooks skipped (HookObjectChange=%s, myHandle=%s)", tostring(apiHas("HookObjectChange")), tostring(myHandle))
    end

    -- record ----------------------------------------------------------------------
    if own then pcall(function() seq.Name = "TAP NOW" end) end
    log(">>> TAP NOW for %d seconds <<<", dur)
    t0 = now()
    local last, polls, maxGap, prevT = {}, 0, 0, t0
    while true do
        local t = now()
        if t - t0 >= dur then break end
        polls = polls + 1
        if t - prevT > maxGap then maxGap = t - prevT end
        prevT = t
        for _, s in ipairs(signals) do
            local ok, v = pcall(s.fn)
            if not ok then v = "<err>" end
            if last[s.name] == nil then
                last[s.name] = v
            elseif v ~= last[s.name] then
                events[#events + 1] = { t = t - t0, sig = s.name, val = v }
                last[s.name] = v
            end
        end
        coroutine.yield(0.005)
    end
    local tEnd = now()
    if own then pcall(function() seq.Name = TEMPNAME end) end
    log(">>> done <<<   polls=%d  avg interval=%.2f ms  worst gap=%.2f ms  hook callbacks=%d",
        polls, (tEnd - t0) / math.max(polls, 1) * 1000, maxGap * 1000, hookCount)

    for _, id in ipairs(hookIds) do
        local oku = pcall(function() return UnHook(id) end)
        if not oku then pcall(function() return Unhook(id) end) end
    end
    if tc ~= nil then run("Off Timecode %d", tcNo) end
    coroutine.yield(0.3)

    -- report: raw events ------------------------------------------------------------
    table.sort(events, function(a, b) return a.t < b.t end)
    log("--- %d change events (first 60 here, all in the log file) ---", #events)
    for i, e in ipairs(events) do
        local line = fmt("  t=%8.3f  %-18s %s", e.t, e.sig, tostring(e.val))
        if i <= 60 then log("%s", line) else flog("%s", line) end
    end

    -- report: taps from the first boolean signal that moved -----------------------------
    for _, name in ipairs({ "IsRunningPlayback", "HasActivePlayback" }) do
        local taps, onAt = {}, nil
        for _, e in ipairs(events) do
            if e.sig == name then
                if isOn(e.val) then
                    onAt = e.t
                elseif onAt then
                    taps[#taps + 1] = { on = onAt, off = e.t }
                    onAt = nil
                end
            end
        end
        log("--- taps seen by polling %s: %d ---", name, #taps)
        for i, tp in ipairs(taps) do
            local gap = taps[i + 1] and (taps[i + 1].on - tp.off) or nil
            log("  tap %2d  press=%7.3f  release=%7.3f  dwell=%6.3f  gap after=%s", i, tp.on, tp.off,
                tp.off - tp.on, gap and string.format("%6.3f", gap) or "  -")
        end
    end

    -- report: timecode -------------------------------------------------------------------
    if tc ~= nil then
        local list = {}
        collectTimed(tc, "tc", list, 0)
        table.sort(list, function(a, b) return a.raw < b.raw end)
        log("--- timecode %d: %d timed objects (times in s; 'poll t' is the same moment on the polling clock) ---",
            tcNo, #list)
        outline(tc, "Timecode " .. tcNo, 4)
        local shift = t0 - (tRec or t0)
        for i, e in ipairs(list) do
            local o = e.obj
            local line = fmt("  %-14s <%s>  t=%8.3f  poll t=%8.3f  Token=%s  Name='%s'", e.path, cls(o),
                e.raw / TIME_T, e.raw / TIME_T - shift, tostring(prop(o, "Token")), tostring(prop(o, "Name")))
            if i <= 60 then log("%s", line) else flog("%s", line) end
        end
        if #list == 0 then
            log("  no events recorded. Next try: Select the timecode first, or check its record settings.")
        end
        flog("timecode tree:")
        dumpTree(tc, "Timecode " .. tcNo, 6)
    end

    -- cleanup -------------------------------------------------------------------------------
    local what, cmds = {}, {}
    if tcNo and tc ~= nil then what[#what + 1] = "Timecode " .. tcNo cmds[#cmds + 1] = "Delete Timecode " .. tcNo .. " /NoConfirm" end
    if macNo then what[#what + 1] = "Macro " .. macNo cmds[#cmds + 1] = "Delete Macro " .. macNo .. " /NoConfirm" end
    if own and seqNo then what[#what + 1] = "Sequence " .. seqNo cmds[#cmds + 1] = "Delete Sequence " .. seqNo .. " /NoConfirm" end
    if #cmds > 0 then confirmDelete(table.concat(what, ", "), cmds) end
end

-- ---------------------------------------------------------------------
-- Output sampling (shared by probes 3 and 4)
-- ---------------------------------------------------------------------
-- Flicker Generator syntax (proven on this console) for a programmer Dimmer phaser.
local function writePhaser(c)
    run("Delete Step 1 Thru Attribute 'Dimmer'")
    for i, v in ipairs(c.vals) do run("Step %d Attribute 'Dimmer' At Absolute %d", i, v) end
    if c.widths then
        for i, w in ipairs(c.widths) do run("Step %d Attribute 'Dimmer' Width %d", i, w) end
    end
    for i, t in ipairs(c.trans) do run("Step %d Attribute 'Dimmer' Transition %d", i, t) end
    run("Step 1 Attribute 'Dimmer' Speed %g", c.speed)
    if c.measure then run("Step 1 Attribute 'Dimmer' Measure %g", c.measure) end
end

local function clearPhaser()
    run("Delete Step 1 Thru Attribute 'Dimmer'")
    run("Off Attribute 'Dimmer'")
    run("Step 1")
end

-- every numeric leaf of a table as path -> value (tables only, three levels)
local function flatten(t, prefix, out, depth)
    if type(t) ~= "table" or depth > 3 then return end
    for k, v in pairs(t) do
        local path = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
        if type(v) == "number" then
            out[path] = v
        elseif type(v) == "table" then
            flatten(v, path, out, depth + 1)
        end
    end
end

-- Finds a way to read the Dimmer output of the first selected fixture WITHOUT
-- asking anything: it runs a 2-step calibration phaser and watches which
-- numbers actually move. Returns reader(), description, uiChannel, kind.
--   kind "value" = real output level     kind "dmx" = DMX output
--   kind "phase" = only the phaser's clock moves (cycle length, not step lengths)
-- The calibration phaser is left running; the caller replaces or clears it.
local function makeDimmerReader()
    local sub = SelectionFirst()
    if sub == nil then return nil, "nothing selected" end
    local oka, attr = pcall(GetAttributeIndex, "Dimmer")
    if not oka or attr == nil then return nil, "no Dimmer attribute index" end
    local oku, ui = pcall(GetUIChannelIndex, sub, attr)
    ui = oku and tonumber(ui) and math.floor(tonumber(ui)) or nil
    if ui == nil then return nil, "the first selected fixture has no Dimmer channel" end
    log("first selected subfixture index=%s  Dimmer attr index=%s  UI channel=%s", tostring(sub), tostring(attr), tostring(ui))

    local rtIndex, coarse
    if apiHas("GetUIChannel") and apiHas("GetRTChannel") then
        local ok, uc = pcall(GetUIChannel, ui)
        if ok and uc ~= nil then
            if type(uc) == "table" then flog("GetUIChannel(%d) = %s", ui, kv(uc, 2)) end
            local okr, r = pcall(function() return uc.rt_index end)
            if okr then rtIndex = r end
        end
    end
    if rtIndex ~= nil then
        local ok, rt = pcall(GetRTChannel, rtIndex)
        if ok and type(rt) == "table" then
            flog("GetRTChannel(%s) before = %s", tostring(rtIndex), kv(rt, 3))
            if type(rt.patch) == "table" then coarse = tonumber(rt.patch.coarse) end
        end
    end

    log("--- calibration: 2-step phaser, watching which readings move ---")
    run("Attribute 'Dimmer'")
    writePhaser({ vals = { 100, 0 }, trans = { 0, 0 }, speed = 60 })
    coroutine.yield(0.3)

    local cands, order = {}, {}
    local function note(name, v)
        local c = cands[name]
        if not c then
            c = { n = 0, nils = 0 }
            cands[name] = c
            order[#order + 1] = name
        end
        if type(v) == "number" then
            c.n = c.n + 1
            if not c.lo or v < c.lo then c.lo = v end
            if not c.hi or v > c.hi then c.hi = v end
        else
            c.nils = c.nils + 1
        end
    end
    local dmx = {}
    if apiHas("GetDMXValue") and coarse then
        local c = coarse
        dmx = {
            { "dmx abs " .. c,       function() return GetDMXValue(c) end },
            { "dmx abs " .. (c + 1), function() return GetDMXValue(c + 1) end },
            { fmt("dmx %d.%d", c // 512 + 1, c % 512 + 1),
                function() return GetDMXValue(c % 512 + 1, c // 512 + 1, false) end },
            { fmt("dmx %d.%d", (c - 1) // 512 + 1, (c - 1) % 512 + 1),
                function() return GetDMXValue((c - 1) % 512 + 1, (c - 1) // 512 + 1, false) end },
        }
    end
    local t0 = now()
    while now() - t0 < 2.4 do
        if rtIndex ~= nil then
            local ok, rt = pcall(GetRTChannel, rtIndex)
            if ok and type(rt) == "table" then
                local flat = {}
                flatten(rt, "", flat, 0)
                for path, v in pairs(flat) do note("rt " .. path, v) end
            end
        end
        for _, d in ipairs(dmx) do
            local ok, v = pcall(d[2])
            note(d[1], ok and v or nil)
        end
        coroutine.yield(0.005)
    end
    if rtIndex ~= nil then
        local ok, rt = pcall(GetRTChannel, rtIndex)
        if ok and type(rt) == "table" then flog("GetRTChannel(%s) while running = %s", tostring(rtIndex), kv(rt, 3)) end
    end

    table.sort(order)
    local moving = {}
    for _, name in ipairs(order) do
        local c = cands[name]
        local moves = c.lo ~= nil and c.hi > c.lo
        flog("  candidate %-34s readings=%d nil=%d  min=%s max=%s%s", name, c.n, c.nils,
            tostring(c.lo), tostring(c.hi), moves and "   MOVES" or "")
        if moves then moving[#moving + 1] = name end
    end
    log("readings that move: %s", #moving > 0 and table.concat(moving, " | ") or "NONE")

    local function rtReader(path)
        local keys = {}
        for k in path:gmatch("[^%.]+") do keys[#keys + 1] = k end
        return function()
            local v = GetRTChannel(rtIndex)
            for _, k in ipairs(keys) do
                if type(v) ~= "table" then return nil end
                v = v[k]
            end
            return v
        end
    end
    local function pick(test)
        for _, name in ipairs(moving) do if test(name) then return name end end
    end
    local name = pick(function(n) return n == "rt info.value_before_master" end)
        or pick(function(n) return n == "rt info.value_after_master" end)
        or pick(function(n) return n:sub(1, 3) == "rt " and n:find("value", 1, true) ~= nil end)
    if name then return rtReader(name:sub(4)), "GetRTChannel " .. name:sub(4), ui, "value" end
    name = pick(function(n) return n:sub(1, 4) == "dmx " and (cands[n].hi - cands[n].lo) >= 100 end)
    if name then
        for _, d in ipairs(dmx) do
            if d[1] == name then return d[2], "GetDMXValue " .. name:sub(5), ui, "dmx" end
        end
    end
    name = pick(function(n) return n:sub(1, 3) == "rt " and n:find("phaser_time", 1, true) ~= nil end)
        or pick(function(n) return n:sub(1, 3) == "rt " end)
    if name then return rtReader(name:sub(4)), "GetRTChannel " .. name:sub(4), ui, "phase" end
    return nil, "no reading moved while the calibration phaser ran (grand master down, or the fixture is not outputting?)"
end

local function sample(reader, seconds)
    local s = {}
    local t0 = now()
    while true do
        local t = now() - t0
        if t >= seconds then break end
        local ok, v = pcall(reader)
        if ok and type(v) == "number" then s[#s + 1] = { t = t, v = v } end
        coroutine.yield(0.005)
    end
    return s
end

-- Turns samples into: run lengths above/below the midpoint, and 10-90% edge times.
local function analyze(s)
    if #s < 10 then return { "too few samples (" .. #s .. ")" } end
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(s) do
        if p.v < lo then lo = p.v end
        if p.v > hi then hi = p.v end
    end
    local out = { fmt("samples=%d every %.1f ms   min=%.4g max=%.4g", #s,
        (s[#s].t - s[1].t) / (#s - 1) * 1000, lo, hi) }
    if hi - lo <= 0.02 * math.max(math.abs(hi), math.abs(lo), 1e-9) then
        out[#out + 1] = "FLAT - no movement seen on the output"
        return out
    end
    local mid = (lo + hi) / 2
    local runs, state, t0 = {}, s[1].v > mid, s[1].t
    for i = 2, #s do
        local st = s[i].v > mid
        if st ~= state then
            local tc = (s[i - 1].t + s[i].t) / 2
            runs[#runs + 1] = { hi = state, d = tc - t0 }
            state, t0 = st, tc
        end
    end
    table.remove(runs, 1)          -- first run is partial
    local parts, sumH, nH, sumL, nL = {}, 0, 0, 0, 0
    for i, r in ipairs(runs) do
        if i <= 12 then parts[#parts + 1] = fmt("%s%.3f", r.hi and "H" or "L", r.d) end
        if r.hi then sumH, nH = sumH + r.d, nH + 1 else sumL, nL = sumL + r.d, nL + 1 end
    end
    out[#out + 1] = "runs above/below midpoint (s): " .. (#parts > 0 and table.concat(parts, "  ") or "(none complete)")
    if nH > 0 and nL > 0 then
        out[#out + 1] = fmt("mean HIGH=%.3f s (%d)   mean LOW=%.3f s (%d)   HIGH+LOW=%.3f s",
            sumH / nH, nH, sumL / nL, nL, sumH / nH + sumL / nL)
    end
    local l10, l90 = lo + (hi - lo) * 0.1, lo + (hi - lo) * 0.9
    local rise, nR, fall, nF, from, tLeft = 0, 0, 0, 0, nil, nil
    for _, p in ipairs(s) do
        local zone = (p.v <= l10 and "lo") or (p.v >= l90 and "hi") or nil
        if zone then
            if from and zone ~= from then
                if from == "lo" then rise, nR = rise + (p.t - tLeft), nR + 1
                else fall, nF = fall + (p.t - tLeft), nF + 1 end
            end
            from, tLeft = zone, p.t
        end
    end
    if nR > 0 and nF > 0 then
        out[#out + 1] = fmt("10-90%% edge time: rise=%.3f s (%d)   fall=%.3f s (%d)", rise / nR, nR, fall / nF, nF)
    end
    return out
end

-- ---------------------------------------------------------------------
-- PROBE 3: programmer phaser timing
-- ---------------------------------------------------------------------
local function readbackPhaser(ui, nSteps)
    if apiHas("GetProgPhaser") then
        local ok, ph = pcall(GetProgPhaser, ui, false)
        log("    GetProgPhaser = %s", ok and kv(ph, 2) or ("<err " .. tostring(ph) .. ">"))
    end
    for i = 0, nSteps - 1 do
        local ok, v = pcall(GetProgPhaserValue, ui, i)
        log("    step index %d = %s", i, ok and kv(v, 2) or ("<err " .. tostring(v) .. ">"))
    end
end

local function probePhaserTiming()
    log("=== PROBE 3: programmer phaser timing ===")
    if SelectionFirst() == nil then
        err("select ONE spare fixture that has a dimmer, then run this probe again")
        return
    end
    local ok, yes = pcall(Confirm, "Phaser timing probe",
        "Writes Dimmer phasers into the programmer for the current selection and\n" ..
        "watches the output for about 50 seconds. The fixture will flash.\n\n" ..
        "Afterwards the Dimmer is knocked out of the programmer for the selection.\n" ..
        "Speed is sent as plain numbers (60 / 120) in whatever your Speed readout is.", nil, true)
    if not (ok and yes) then log("cancelled") return end

    logApi()
    logReadouts()
    local reader, desc, ui, kind = makeDimmerReader()
    if not reader then
        clearPhaser()
        stop("Cannot read the output:\n%s", tostring(desc))
        return
    end
    log("reading output through %s  (%s)", desc, kind)
    if kind == "phase" then
        log("NOTE: only the phaser clock is readable, so HIGH+LOW below is the cycle length; step lengths are not visible")
    end

    local CASES = {
        { id = "A", note = "2 steps 100/0, widths untouched, trans 0, speed 60", vals = { 100, 0 }, trans = { 0, 0 }, speed = 60 },
        { id = "B", note = "widths 50/100", vals = { 100, 0 }, widths = { 50, 100 }, trans = { 0, 0 }, speed = 60 },
        { id = "C", note = "widths 100/300", vals = { 100, 0 }, widths = { 100, 300 }, trans = { 0, 0 }, speed = 60 },
        { id = "D", note = "widths 25/25", vals = { 100, 0 }, widths = { 25, 25 }, trans = { 0, 0 }, speed = 60 },
        { id = "E", note = "4 steps 100/0/100/0, widths 100", vals = { 100, 0, 100, 0 }, widths = { 100, 100, 100, 100 }, trans = { 0, 0, 0, 0 }, speed = 60 },
        { id = "G", note = "2 steps, widths 100/100, trans 100/100", vals = { 100, 0 }, widths = { 100, 100 }, trans = { 100, 100 }, speed = 60 },
        { id = "H", note = "2 steps, widths 100/100, speed 120", vals = { 100, 0 }, widths = { 100, 100 }, trans = { 0, 0 }, speed = 120 },
        { id = "I", note = "2 steps, widths 100/100, speed 60, measure 2", vals = { 100, 0 }, widths = { 100, 100 }, trans = { 0, 0 }, speed = 60, measure = 2 },
        { id = "F", note = "4 steps 100/0/100/0, widths 50/150/50/150", vals = { 100, 0, 100, 0 }, widths = { 50, 150, 50, 150 }, trans = { 0, 0, 0, 0 }, speed = 60 },
    }
    for _, c in ipairs(CASES) do
        log("--- case %s: %s ---", c.id, c.note)
        writePhaser(c)
        coroutine.yield(0.4)
        readbackPhaser(ui, #c.vals)
        for _, line in ipairs(analyze(sample(reader, 4.5))) do log("    %s", line) end
    end

    -- case F is still in the programmer: can it be stored straight into a Shape?
    log("--- store the case F phaser as a Shape ---")
    local shapeNo = freeNumber("Shape %d")
    local shape
    if shapeNo then
        run("Store Shape %d /NoConfirm", shapeNo)
        shape = handleOf("Shape " .. shapeNo)
        if shape ~= nil then
            run('Label Shape %d "%s"', shapeNo, TEMPNAME)
            outline(shape, "Shape " .. shapeNo, 4)
            flog("shape tree:")
            dumpTree(shape, "Shape " .. shapeNo, 6)
        else
            err("Shape %d not found after Store", shapeNo)
        end
    end

    log("--- cleanup ---")
    clearPhaser()
    if shape ~= nil then
        confirmDelete("Shape " .. shapeNo, { "Delete Shape " .. shapeNo .. " /NoConfirm" })
    end
end

-- ---------------------------------------------------------------------
-- PROBE 4: phaser recipe build
-- ---------------------------------------------------------------------
local function probeRecipe()
    log("=== PROBE 4: phaser recipe build ===")
    local ok, yes = pcall(Confirm, "Recipe build probe",
        "Makes a scratch Dimmer preset (1.99xx) holding a 4-step phaser recipe,\n" ..
        "edits it with the syntax from MA's own tests and the ACT article, and dumps it.\n\n" ..
        "If a fixture is selected, the preset is also called on it for 5 seconds\n" ..
        "to time the result (the fixture will flash).", nil, true)
    if not (ok and yes) then log("cancelled") return end

    local n = freeNumber("Preset 1.%d")
    if not n then err("no free Dimmer preset slot in %d-%d", SLOT_LO, SLOT_HI) return end
    local P = "Preset 1." .. n
    local L = P .. ".1"

    log("--- create ---")
    run("Store %s /NoConfirm", P)
    if handleOf(P) == nil then err("%s was not created - stopping", P) return end
    run('Label %s "%s"', P, TEMPNAME)
    run('Store Type "PhaserRecipe" %s', L)
    run('Set %s.1.1 Property "ValueAbsolute" 100', L)
    run('Set %s.1.2 Property "ValueAbsolute" 0', L)
    run('Set %s Property "LinkSteps" 0', L)
    run('Assign Attribute "Dimmer" At %s.1.1.1', L)
    run('Assign Attribute "Dimmer" At %s.1.2.1', L)

    log("--- add steps 3 and 4 (value source 1) ---")
    run("Store %s.2.1.3 /NoConfirm", L)
    run("Store %s.2.1.4 /NoConfirm", L)
    run('Set %s.2.1.3 Property "ValueAbsolute" 100', L)
    run('Set %s.2.1.4 Property "ValueAbsolute" 0', L)

    log("--- step properties, one command each (step-level address .1.<step>) ---")
    local widths = { 50, 150, 50, 150 }
    for i = 1, 4 do run('Set %s.1.%d Property "WidthX" %d', L, i, widths[i]) end
    for i = 1, 4 do run('Set %s.1.%d Property "TransX" 0', L, i) end
    run('Set %s.1.1 Property "Curve" "Snap"', L)
    run('Set %s.1.2 Property "Curve" "Ease In and Out"', L)
    run('Set %s.1.1 Property "AccelX" 0', L)
    run('Set %s.1.1 Property "DecelX" 0', L)

    log("--- ACT article address form ---")
    run('Set %s."PhaserRecipeSteps".3.1 Property "Curve" "Snap"', L)
    run('Set %s."PhaserRecipeSteps".4.1 Property "Curve" "Linear"', L)

    log("--- line properties ---")
    run('Set %s Property "SpeedX" 60', L)
    run('Set %s Property "PlaybackNShot" -1', L)

    log("--- structure ---")
    local h = handleOf(P)
    if h ~= nil then
        outline(h, P, 5)
        flog("preset tree:")
        dumpTree(h, P, 7)
        if apiHas("GetPresetData") then
            local okd, d = pcall(GetPresetData, h)
            flog("GetPresetData = %s", okd and kv(d, 7) or ("<err " .. tostring(d) .. ">"))
            log("GetPresetData: %s", okd and kv(d, 1) or ("<err " .. tostring(d) .. ">"))
        end
    end

    if SelectionFirst() ~= nil then
        log("--- timing on the selected fixture ---")
        local reader, desc, ui, kind = makeDimmerReader()
        clearPhaser()                                   -- remove the calibration phaser
        if reader then
            log("reading output through %s  (%s)", desc, kind)
            run("At %s", P)
            coroutine.yield(0.5)
            readbackPhaser(ui, 4)
            for _, line in ipairs(analyze(sample(reader, 5))) do log("    %s", line) end
            clearPhaser()
        else
            err("cannot read the output: %s", tostring(desc))
        end
    else
        log("nothing selected - timing skipped")
    end

    confirmDelete(P, { "Delete " .. P .. " /NoConfirm" })
end

-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------
local PROBES = { probeClock, probeTap, probePhaserTiming, probeRecipe }

local busySince = nil      -- module state survives between launches: used to block a second launch

function Main(display_handle, args)
    if busySince and (now() - busySince) < 180 then
        pcall(MessageBox, { title = "TapPhaser Probe", commands = { { value = 1, name = "OK" } },
            message = "A probe is still running from the last launch.\nLet it finish, then start the plugin again." })
        return
    end
    busySince = now()
    buf = {}
    flog("")
    flog("===== TapPhaser Probe %s   %s =====", VERSION, os.date("%Y-%m-%d %H:%M:%S"))
    local direct = tonumber(args)
    local trace = (debug and debug.traceback) or function(e) return e end
    while true do
        local choice = direct
        if not choice then
            local res = MessageBox({
                title = "TapPhaser Probe " .. VERSION,
                message = "1 Clock: nothing needed, 10 seconds.\n" ..
                          "2 Tap: you assign a temp sequence to a key and tap on it.\n" ..
                          "3 Phaser timing: select ONE spare dimmable fixture first.\n" ..
                          "4 Recipe: select a spare fixture first if you want it timed.\n\n" ..
                          "Results go to Command Line History and\n" .. tostring(logPath()),
                commands = {
                    { value = 1, name = "1 Clock" },
                    { value = 2, name = "2 Tap" },
                    { value = 3, name = "3 Phaser timing" },
                    { value = 4, name = "4 Recipe" },
                    { value = 0, name = "Close" },
                },
            })
            choice = (type(res) == "table" and res.success ~= false and tonumber(res.result)) or 0
        end
        local fn = PROBES[choice]
        if not fn then break end
        busySince = now()
        local ok, e = xpcall(fn, trace)
        if not ok then err("probe %d crashed: %s", choice, tostring(e)) end
        flush()
        if direct then break end
    end
    busySince = nil
end

return Main
