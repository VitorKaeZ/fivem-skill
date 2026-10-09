-- Port of https://springrts.com/wiki/Lua_Performance tests to Lua 5.4.
-- Each case: 5 runs, best time kept; % relative to the fastest case of the test.
local clock = os.clock
local N = 5000000
local RUNS = 5

local function measure(fn)
    local best = math.huge
    for _ = 1, RUNS do
        collectgarbage("collect")
        local t = clock()
        fn()
        local dt = clock() - t
        if dt < best then best = dt end
    end
    return best
end

local function test(name, cases)
    local results, fastest = {}, math.huge
    for i = 1, #cases do
        local dt = measure(cases[i][2])
        results[i] = dt
        if dt < fastest then fastest = dt end
    end
    print(("\n## %s"):format(name))
    for i = 1, #cases do
        print(("  %-34s %7.3fs  %4d%%"):format(cases[i][1], results[i], math.floor(results[i] / fastest * 100 + 0.5)))
    end
end

local sink

test("1 localize math.min", {
    { "global math.min", function() for i = 1, N do sink = math.min(i, 5) end end },
    { "local min", function() local min = math.min for i = 1, N do sink = min(i, 5) end end },
})

GlobalFn = function(a) return a end
test("1b global function (like a native wrapper)", {
    { "global GlobalFn", function() for i = 1, N do sink = GlobalFn(i) end end },
    { "local GlobalFn", function() local f = GlobalFn for i = 1, N do sink = f(i) end end },
})

local class = { test = function() return 1 end }
test("2 localized class method (3 calls)", {
    { "class.test() x3", function() for i = 1, N do local x = class.test() local y = class.test() local z = class.test() end end },
    { "local test = class.test", function() for i = 1, N do local t = class.test local x = t() local y = t() local z = t() end end },
})

local a4 = { 1, 2, 3, 4 }
test("3 unpack", {
    { "a[1],a[2],a[3],a[4]", function() local min = math.min for i = 1, N do sink = min(a4[1], a4[2], a4[3], a4[4]) end end },
    { "table.unpack(a)", function() local min, unpack = math.min, table.unpack for i = 1, N do sink = min(unpack(a4)) end end },
    { "custom unpack4", function()
        local min = math.min
        local function unpack4(t) return t[1], t[2], t[3], t[4] end
        for i = 1, N do sink = min(unpack4(a4)) end
    end },
})

test("4 max: math.max vs if", {
    { "math.max", function() local max, x = math.max, 0 for i = 1, N do x = max((i * 7919) % 1000, x) end sink = x end },
    { "if r > x", function() local x = 0 for i = 1, N do local r = (i * 7919) % 1000 if r > x then x = r end end sink = x end },
})

test("5 nil check vs or", {
    { "if y == nil", function() for i = 1, N do local y, x if i % 2 == 0 then y = 1 end if y == nil then x = 1 else x = y end sink = x end end },
    { "x = y or 1", function() for i = 1, N do local y if i % 2 == 0 then y = 1 end sink = y or 1 end end },
})

test("6 x^2 vs x*x (float x)", {
    { "x^2", function() local x = 1.5 for i = 1, N do sink = x ^ 2 end end },
    { "x*x", function() local x = 1.5 for i = 1, N do sink = x * x end end },
})

test("7 math.fmod vs %", {
    { "math.fmod", function() local fmod = math.fmod for i = 1, N do if fmod(i, 30) < 1 then sink = 1 end end end },
    { "%", function() for i = 1, N do if i % 30 < 1 then sink = 1 end end end },
})

local function func1(a, b, f) return f(a + b) end
local function func2(a) return a * 2 end
test("8 function created inside the loop", {
    { "closure per iteration", function() for i = 1, N do sink = func1(1, 2, function(a) return a * 2 end) end end },
    { "local function, reused", function() for i = 1, N do sink = func1(1, 2, func2) end end },
})

local arr = {}
for i = 1, 100 do arr[i] = i end
local M = N // 10
test("9 iterate array of 100 (x100k)", {
    { "pairs", function() for _ = 1, M do for _, v in pairs(arr) do sink = v end end end },
    { "ipairs", function() for _ = 1, M do for _, v in ipairs(arr) do sink = v end end end },
    { "for i = 1, 100", function() for _ = 1, M do for i = 1, 100 do sink = arr[i] end end end },
    { "for i = 1, #a", function() for _ = 1, M do for i = 1, #arr do sink = arr[i] end end end },
    { "local n = #a; for i = 1, n", function() for _ = 1, M do local n = #arr for i = 1, n do sink = arr[i] end end end },
})

local obj = { foo = 1 }
test("10 a['foo'] vs a.foo", {
    { "a['foo']", function() for i = 1, N do sink = obj["foo"] end end },
    { "a.foo", function() for i = 1, N do sink = obj.foo end end },
})

local items = {}
for i = 1, 100 do items[i] = { x = 0 } end
test("11 buffered table item (x100k)", {
    { "a[n].x = a[n].x + 1", function() for _ = 1, M do for n = 1, 100 do items[n].x = items[n].x + 1 end end end },
    { "local y = a[n]; y.x = y.x + 1", function() for _ = 1, M do for n = 1, 100 do local y = items[n] y.x = y.x + 1 end end end },
})

test("12 append 1M items", {
    { "table.insert(t, v)", function() local t, ins = {}, table.insert for i = 1, N do ins(t, i) end end },
    { "t[i] = v", function() local t = {} for i = 1, N do t[i] = i end end },
    { "t[#t + 1] = v", function() local t = {} for i = 1, N do t[#t + 1] = i end end },
    { "counter", function() local t, c = {}, 0 for i = 1, N do c = c + 1 t[c] = i end end },
})

test("12b table constructor", {
    { "{} then 3 assigns", function() for i = 1, N do local t = {} t[1] = 1 t[2] = 2 t[3] = 3 end end },
    { "{true,true,true} then assigns", function() for i = 1, N do local t = { true, true, true } t[1] = 1 t[2] = 2 t[3] = 3 end end },
    { "{1, 2, 3}", function() for i = 1, N do local t = { 1, 2, 3 } end end },
    { "{} then x/y/z fields", function() for i = 1, N do local t = {} t.x = 1 t.y = 2 t.z = 3 end end },
    { "{x=1, y=2, z=3}", function() for i = 1, N do local t = { x = 1, y = 2, z = 3 } end end },
})

test("13 new table vs shared constant (NOT equivalent: shared = same object)", {
    { "t[i] = {'abc','def','ghk'}", function() local t = {} for i = 1, N do t[i] = { "abc", "def", "ghk" } end end },
    { "t[i] = Cached (shared)", function() local t, c = {}, { "abc", "def", "ghk" } for i = 1, N do t[i] = c end end },
})

-- Extra, FiveM-relevant: garbage created per frame
test("X1 string building, 1000 parts (x1k)", {
    { "s = s .. part", function() for _ = 1, 1000 do local s = "" for i = 1, 1000 do s = s .. "ab" end sink = s end end },
    { "parts[n] = part; table.concat", function() for _ = 1, 1000 do local p = {} for i = 1, 1000 do p[i] = "ab" end sink = table.concat(p) end end },
})

print(("\n%s, %d runs per case, best kept"):format(_VERSION, RUNS))
