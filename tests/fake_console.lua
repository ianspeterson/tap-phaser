-- =====================================================================
-- fake_console.lua - a stand-in grandMA3 for testing TapPhaser.lua offline.
--
-- It fakes the clock, the object tree, the command line, the dialogs and
-- the timecode, well enough to run the whole plugin from Start to Shape.
-- It also copies two quirks seen on a real 2.5.1 console:
--   * Set ... Property "TransX" 0 returns OK but changes nothing
--   * Curve "Snap" / "Linear" do set the transition
--
-- run_tests.py loads this file once per case and passes CFG:
--   exec        "" (press a key yourself) or an executor number as text
--   mode        1 Free, 2 BPM         bpm, grid, feel
--   hi, lo      High / Low as text    rel   true = Relative values
--   review      1 keep tail, 2 chop, 4 custom tail      customTail  text typed
--   direct      true: DataPool().Shapes:Create works (route 1)
--   taps        { {press, release}, ... } seconds after Record
--   endAt       seconds after Record when the plugin is run again
--   occupied    executor 202 already holds Sequence 5
--   pre         objects already in the show: { {kind, number, name}, ... }
--   otherTracks other playbacks get recorded into the timecode as well
--   sessions    { "record" } or { "record", "rerender" }
-- A passing run proves the plugin's logic, not that a real console agrees.
-- =====================================================================
local PLUGIN, LIBDIR, CFG = ...

local T = 500.0
OUT = {}
local function out(s) OUT[#OUT + 1] = s end
Printf    = function(f, ...) out(string.format(f, ...)) end
ErrPrintf = function(f, ...) out("RED " .. string.format(f, ...)) end
Time      = function() return T end
Enums = { PathType = { Library = 1 }, Roles = { Default = 0, Display = 1 } }
GetPath = function() return LIBDIR end
GetPathSeparator = function() return "/" end
local VARS = {}
UserVars = function() return "uv" end
GetVar = function(_, n) return VARS[n] end
SetVar = function(_, n, v) VARS[n] = v end

local REG, nextId = {}, 1
function H(class, name, props)
    local o = { __class = class, __props = props or {}, __kids = {}, __id = nextId }
    nextId = nextId + 1
    o.__props.Name = name
    local m = {}
    function m.Count(self) return #self.__kids end
    function m.Ptr(self, i) return self.__kids[i] end
    function m.GetClass(self) return self.__class end
    function m.ToAddr(self) return self.__addr or (self.__class .. " ?") end
    function m.Addr(self) return tostring(self.__id) end
    function m.Index(self) return self.__index or 1 end
    function m.PropertyCount(self) local n = 0 for _ in pairs(self.__props) do n = n + 1 end return n end
    function m.PropertyName(self, i)
        local keys = {} for k in pairs(self.__props) do keys[#keys + 1] = k end table.sort(keys) return keys[i + 1]
    end
    function m.Get(self, k) return self.__props[k] end
    function m.Append(self) local k = H("MacroLine", "") self.__kids[#self.__kids + 1] = k return k end
    function m.Children(self) return self.__kids end
    return setmetatable(o, {
        __index = function(t, k)
            if type(k) == "number" then return rawget(t, "__kids")[k] end
            local extra = rawget(t, "__methods")
            if extra and extra[k] then return extra[k] end
            if m[k] then return m[k] end
            return rawget(t, "__props")[k]
        end,
        __newindex = function(t, k, v)
            if k:sub(1, 2) == "__" then rawset(t, k, v) else rawget(t, "__props")[k] = v if SWITCH_FIX then SWITCH_FIX(t) end end
        end,
    })
end
HandleToInt = function(h) return h.__id end
SWITCH_FIX = function(o) if o.__class == "Timecode" and o.__props.SwitchOff == false then o.__props.SwitchOff = CFG.stubborn and "Playbacks Off" or "Keep Playbacks" end end
local ATTR = H("Attribute", "Dimmer") ATTR.__addr = "Attribute 1"
REG['Attribute "Dimmer"'] = ATTR
ObjectList = function(a) local h = REG[a] if h then return { h } end return {} end

-- executors ---------------------------------------------------------------
local ASSIGN, EX, pendingPress = {}, {}, nil
local function execObj(n)
    if not EX[n] then
        local e = H("Executor", "Exec " .. n, { No = n, Key = "Go+" })
        e.__addr = "Page 1." .. n
        e.__methods = { GetAssignedObj = function() return ASSIGN[n] end }
        EX[n] = e
    end
    return EX[n]
end
local page = H("Page", "Page 1")
page.__methods = { Children = function()
    if pendingPress and T >= pendingPress.at then
        ASSIGN[202] = pendingPress.seq
        pendingPress = nil
    end
    local l = {}
    for n in pairs(ASSIGN) do l[#l + 1] = execObj(n) end
    return l
end }
CurrentExecPage = function() return page end
GetExecutor = function(n) if ASSIGN[n] then return execObj(n) end return nil end
if CFG.occupied then
    local s5 = H("Sequence", "My Seq") s5.__addr = "Sequence 5"
    REG["Sequence 5"] = s5
    ASSIGN[202] = s5
    execObj(202).Key = "Toggle"
end
local CMDLINE = H("CmdLine", "cmd", { CmdText = "" })
CmdObj = function() return CMDLINE end

-- shapes ---------------------------------------------------------------------
local function newStep(v)
    local st = H("PhaserRecipeStep", "Step")
    local vs = H("PhaserRecipeValueSource", "Value Source 1",
        { ValueAbsolute = v or (CFG.absDefault and 0 or nil), WidthX = 100, TransX = 100, AccelX = 0, DecelX = 0 })
    st.__kids[1] = vs
    return st
end
local function newShape(n, nSteps)
    local sh = H("Shape", "Shape " .. n) sh.__addr = "Shape " .. n
    local rec = H("PhaserRecipe", "PhaserRecipe 1", { Measure = "" })
    local steps = H("PhaserRecipeSteps", "PhaserRecipeSteps")
    for i = 1, nSteps do steps.__kids[i] = newStep() end
    rec.__kids[1] = steps
    sh.__kids[1] = rec
    REG["Shape " .. n] = sh
    return sh
end
local shapesPool = H("Shapes", "Shapes")
shapesPool.__methods = { Create = function(self, n)
    if not CFG.direct then error("Create not supported (fake)") end
    return newShape(n, 2)
end }
local function poolOf(kind, extra)
    local t = extra or {}
    return setmetatable(t, { __index = function(_, k)
        if type(k) == "number" then return REG[kind .. " " .. k] end
        return nil
    end })
end
local seqPool, macPool = poolOf("Sequence"), poolOf("Macro")
local tcPool = poolOf("Timecode", { Children = function()
    local l = {}
    for k, v in pairs(REG) do if v.__class == "Timecode" then l[#l + 1] = v end end
    return l
end })
local shapeIndex = setmetatable({}, { __index = function(_, k)
    if type(k) == "number" then return REG["Shape " .. k] end
    return shapesPool[k]
end })
DataPool = function() return { Shapes = shapeIndex, Sequences = seqPool, Macros = macPool, Timecodes = tcPool } end
-- things that were in the show before the plugin ran
for _, pre in ipairs(CFG.pre or {}) do
    local o = H(pre[1], pre[3], { No = pre[2] }) o.__addr = pre[1] .. " " .. pre[2]
    if pre[1] == "Timecode" then o.__methods = { IsRunningPlayback = function() return pre[4] == true end } end
    REG[pre[1] .. " " .. pre[2]] = o
end

-- programmer phaser (route 2) ---------------------------------------------------
local PH = { steps = {} }
SelectionFirst = function() if CFG.noSelection then return nil end return 7 end

-- timecode --------------------------------------------------------------------------
local recStart
local function makeTimecode(n)
    local tc = H("Timecode", "Timecode " .. n, { Cursor = 0, No = tonumber(n), SwitchOff = CFG.switchOff or "Playbacks Off" }) tc.__addr = "Timecode " .. n
    tc.__methods = { IsRunningPlayback = function() return recStart ~= nil end }
    local tg = H("TrackGroup", "TG") local mk = H("MarkerTrack", "Marker")
    local tr = H("Track", "Seq") local rng = H("TimeRange", "R") local sub = H("CmdSubTrack", "S")
    tc.__kids = { tg } tg.__kids = { mk, tr } tr.__kids = { rng } rng.__kids = { sub }
    tc.__track, tc.__sub = tr, sub
    REG["Timecode " .. n] = tc
    return tc
end

CMDS = {}
local seqH
Cmd = function(c)
    CMDS[#CMDS + 1] = c
    local n, a, b
    n = c:match("^Store Sequence (%d+)")
    if n then
        seqH = H("Sequence", "Sequence " .. n) seqH.__addr = "Sequence " .. n
        REG["Sequence " .. n] = seqH
        return "OK"
    end
    a, n, b = c:match('^Label (%a+) (%d+) "(.-)"')
    if a then
        if not REG[a .. " " .. n] then return "Illegal object" end
        REG[a .. " " .. n].Name = b
        return "OK"
    end
    n = c:match('^Set Timecode (%d+) Property "SwitchOff" "Keep Playbacks"')
    if n then REG["Timecode " .. n].SwitchOff = "Keep Playbacks" return "OK" end
    n = c:match("^Store Macro (%d+)")
    if n then local m = H("Macro", "Macro " .. n) m.__addr = "Macro " .. n REG["Macro " .. n] = m return "OK" end
    n = c:match("^Go%+ Macro (%d+)")
    if n then
        CMDLINE.CmdText = REG["Macro " .. n].__kids[1].Command .. " "
        pendingPress = { at = T + 1.0, seq = seqH }
        return "OK"
    end
    a, b = c:match("^Assign Sequence (%d+) At Executor (%d+)")
    if a then ASSIGN[tonumber(b)] = REG["Sequence " .. a] return "OK" end
    n = c:match("^Store Timecode (%d+)")
    if n then makeTimecode(n).__track.Target = seqH return "OK" end
    n = c:match("^Record Timecode (%d+)")
    if n then recStart = T return "OK" end
    n = c:match("^Off Timecode (%d+)")
    if n then
        local tc = REG["Timecode " .. n]
        local function ev(t, on)
            tc.__sub.__kids[#tc.__sub.__kids + 1] = H("CmdEvent", on and "Flash" or "Flash(Release)",
                { RawTime = math.floor(t * 16777216 + 0.5), Status = on and "On" or "Off", Token = 1 })
        end
        if CFG.otherTracks then                 -- two other playbacks touched during the take
            local tg = tc[1]
            for i, nm in ipairs({ "Main Cue List", "Bump FX" }) do
                local tr = H("Track", nm) local rng = H("TimeRange", "R") local sub = H("CmdSubTrack", "S")
                tr.Target = H("Sequence", nm)
                tr.__kids = { rng } rng.__kids = { sub }
                for j = 1, 4 do
                    sub.__kids[j] = H("CmdEvent", i == 1 and "Go+" or (j % 2 == 1 and "Flash" or "Flash(Release)"),
                        { RawTime = math.floor((0.3 + j * 0.37 + i * 0.11) * 16777216), Status = (j % 2 == 1) and "On" or "Off", Token = 3 })
                end
                tg.__kids[#tg.__kids + 1] = tr
            end
            if CFG.noTarget then tc.__track.Target = nil end
        end
        if CFG.stray then ev(0.05, false) end
        for _, w in ipairs(CFG.taps) do ev(w[1], true) if w[2] then ev(w[2], false) end end
        return "OK"
    end
    a, n = c:match('^Delete (%a+) (%d+) /NoConfirm')
    if a then
        local obj = REG[a .. " " .. n]
        for k, v in pairs(ASSIGN) do if v == obj then ASSIGN[k] = nil end end
        REG[a .. " " .. n] = nil
        return "OK"
    end
    -- shape editing ------------------------------------------------------------
    a, b = c:match('^Store Shape (%d+)%.1%.2%.1%.(%d+) /NoConfirm')
    if a then
        local steps = REG["Shape " .. a][1][1]
        if tonumber(b) ~= #steps.__kids + 1 then return "Illegal object" end
        steps.__kids[#steps.__kids + 1] = newStep()
        steps.__kids[#steps.__kids][1].Attributes = steps.__kids[1][1].Attributes
        return "OK"
    end
    a, b = c:match('^Assign Attribute "Dimmer" At Shape (%d+)%.1%.1%.(%d+)%.1')
    if a then REG["Shape " .. a][1][1][tonumber(b)][1].Attributes = ATTR return "OK" end
    a, b = c:match('^Set Shape (%d+)%.1%.1%.(%d+) Property ')
    if a then
        local vs = REG["Shape " .. a][1][1][tonumber(b)]
        if not vs then return "Illegal object" end
        vs = vs[1]
        -- like the real console: an unquoted "TransX" 0 says OK but changes nothing
        for k, q, v in c:gmatch('"(%a+)" ("?)([%-%d%.]+)"?') do
            if not (k == "TransX" and tonumber(v) == 0 and q == "" and not CFG.transZeroWorks) then vs[k] = tonumber(v) end
        end
        if c:find('"RawValueAbs" "None"', 1, true) and not CFG.absSticky then vs.ValueAbsolute = nil end
        local curve = c:match('"Curve" "([%a ]+)"')
        if curve == "Snap" then vs.TransX = 0 elseif curve == "Linear" then vs.TransX, vs.AccelX, vs.DecelX = 100, 0, 0 end
        return "OK"
    end
    a = c:match('^Set Shape (%d+)%.1 Property ')
    if a then
        local rec = REG["Shape " .. a][1]
        for k, v in c:gmatch('"(%a+)" "?([%-%d%.]+)"?') do rec[k] = tonumber(v) end
        return "OK"
    end
    a, b = c:match('^Label Shape (%d+) "(.-)"')
    if a then REG["Shape " .. a].Name = b return "OK" end
    -- route 2 ----------------------------------------------------------------------
    if c:match("^Delete Step") then PH = { steps = {} } return "OK" end
    a, b = c:match("^Step (%d+) Attribute 'Dimmer' At Absolute ([%-%d%.]+)")
    if a then PH.steps[tonumber(a)] = { v = tonumber(b), width = 100, trans = 100, accel = 0, decel = 0 } return "OK" end
    a, b = c:match("^Step (%d+) Attribute 'Dimmer' At Relative ([%-%d%.]+)")
    if a then PH.steps[tonumber(a)] = { v = tonumber(b), rel = true, width = 100, trans = 100, accel = 0, decel = 0 } return "OK" end
    for _, key in ipairs({ "Width", "Transition", "Accel", "Decel" }) do
        a, b = c:match("^Step (%d+) Attribute 'Dimmer' " .. key .. " ([%-%d%.]+)")
        if a then
            PH.steps[tonumber(a)][({ Width = "width", Transition = "trans", Accel = "accel", Decel = "decel" })[key]] = tonumber(b)
            return "OK"
        end
    end
    b = c:match("^Step 1 Attribute 'Dimmer' Speed ([%d%.]+)")
    if b then PH.speed = tonumber(b) return "OK" end
    b = c:match("^Step 1 Attribute 'Dimmer' Measure ([%d%.]+)")
    if b then PH.measure = tonumber(b) return "OK" end
    n = c:match("^Store Shape (%d+) /NoConfirm")
    if n then
        local sh = newShape(n, 0)
        for i, s in ipairs(PH.steps) do
            local st = newStep(s.v)
            local vs = st[1]
            if s.rel then vs.ValueAbsolute, vs.ValueRelative = nil, s.v end
            vs.WidthX, vs.TransX, vs.AccelX, vs.DecelX, vs.Attributes = s.width, s.trans, s.accel, s.decel, ATTR
            sh[1][1].__kids[i] = st
        end
        sh[1].Measure, sh[1].SpeedX = PH.measure, PH.speed
        return "OK"
    end
    return "Ok"
end

-- dialogs -----------------------------------------------------------------------------
local sessionKind
DIALOGS = {}
MessageBox = function(t)
    DIALOGS[#DIALOGS + 1] = t.title .. " :: " .. tostring(t.message):gsub("\n", " / ")
    if t.selectors then
        return { success = true, result = sessionKind == "rerender" and 2 or 1,
            inputs = { Executor = CFG.exec or "", BPM = tostring(CFG.bpm or 120), ["Shape number"] = CFG.shape or "", Name = "",
                       High = CFG.hi or "100", Low = CFG.lo or "0" },
            selectors = { Mode = CFG.mode or 1, Grid = CFG.grid or 3, Feel = sessionKind == "rerender" and 4 or (CFG.feel or 1),
                          Values = CFG.rel and 2 or 1 } }
    end
    if t.title:find("ready", 1, true) then return { success = true, result = 1 } end
    if t.title:find("your take", 1, true) then
        local typed = CFG.customTail or t.inputs[1].value
        if CFG.customTail == "" then                -- first answer is bad, the second one is fine
            REVIEWS = (REVIEWS or 0) + 1
            if REVIEWS > 1 then typed = "0.25" end
        end
        return { success = true, result = CFG.review or 1, inputs = { ["Custom tail"] = typed } }
    end
    if t.title:find("done", 1, true) then return { success = true, result = 1 } end
    return { success = true, result = 1 }
end
Confirm = function() return CFG.confirm ~= false end
TextInput = function() return nil end

-- run -----------------------------------------------------------------------------------
local src = assert(io.open(PLUGIN)):read("a")
local chunk = assert(load(src, "@TapPhaser.lua"))
local comp = H("Comp", "c") comp.__parent = H("Plugin", "p")
local main = chunk("Tap Phaser", "TapPhaser", {}, comp)

local seed = 4242
local function jitter() seed = (seed * 1103515245 + 12345) % 2147483648 return (seed / 2147483648) * 0.004 end
local function runSession(kind)
    sessionKind = kind
    recStart = nil
    local co = coroutine.create(function() main("display", nil) end)
    local steps, ended = 0, false
    while coroutine.status(co) ~= "dead" do
        local ok, arg = coroutine.resume(co)
        if not ok then error("PLUGIN ERROR: " .. tostring(arg)) end
        T = T + (type(arg) == "number" and arg or 0.016) + jitter()
        if recStart and not ended and T >= recStart + CFG.endAt then
            ended = true
            main("display", nil)                 -- second launch = END
        end
        steps = steps + 1
        if steps > 200000 then error("runaway") end
    end
end
for _, kind in ipairs(CFG.sessions or { "record" }) do runSession(kind) end

-- result ---------------------------------------------------------------------------------
RESULT = { shapes = {}, assign = {}, reg = {} }
for k, v in pairs(REG) do
    RESULT.reg[#RESULT.reg + 1] = k
    if v.__class == "Shape" and v[1] == nil then
        RESULT.shapes[#RESULT.shapes + 1] = k .. " '" .. tostring(v.Name) .. "' (was there before, untouched)"
    elseif v.__class == "Shape" then
        local rec = v[1]
        local s = { name = v.Name, measure = rec.Measure, speed = rec.SpeedX, steps = {} }
        for i, st in ipairs(rec[1].__kids) do
            local vs = st[1]
            s.steps[i] = string.format("%s%s/%.1f/%g/%g/%g", vs.ValueAbsolute and ("A" .. string.format("%g", vs.ValueAbsolute)) or "",
                vs.ValueRelative and ("R" .. string.format("%g", vs.ValueRelative)) or "", vs.WidthX, vs.TransX, vs.AccelX, vs.DecelX)
        end
        RESULT.shapes[#RESULT.shapes + 1] = k .. " '" .. tostring(s.name) .. "' measure=" .. tostring(s.measure) ..
            " speed=" .. tostring(s.speed) .. " steps: " .. table.concat(s.steps, "  ")
    end
end
for n, o in pairs(ASSIGN) do RESULT.assign[#RESULT.assign + 1] = n .. "=" .. o:ToAddr() .. " key=" .. tostring(execObj(n).Key) end
table.sort(RESULT.reg) table.sort(RESULT.shapes) table.sort(RESULT.assign)
return table.concat(OUT, "\n") .. "\n\nDIALOGS:\n" .. table.concat(DIALOGS, "\n") ..
    "\n\nSHAPES:\n" .. table.concat(RESULT.shapes, "\n") ..
    "\nEXECUTORS: " .. table.concat(RESULT.assign, " ; ") ..
    "\nOBJECTS LEFT: " .. table.concat(RESULT.reg, ", ")
