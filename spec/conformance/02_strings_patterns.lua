-- patterns
assert(("hello world"):find("world") == 7)
assert(("hello"):find("l+", 1, true) == nil)
local s, e, c1, c2 = ("key=value"):find("(%w+)=(%w+)")
assert(s == 1 and e == 9 and c1 == "key" and c2 == "value")
assert(("2024-01-15"):match("(%d+)-(%d+)-(%d+)") == "2024")
local d, m = ("15/06"):match("(%d+)/(%d+)")
assert(d == "15" and m == "06")
-- classes, quantifiers
assert(("   x"):match("%s*(%a)") == "x")
assert(("abc123"):match("%a+") == "abc")
assert(("abc123"):match("%d-$") == "123")
assert(("hello"):gsub("l", "L") == "heLLo")
assert(("hello world"):gsub("(%w+)", "<%1>") == "<hello> <world>")
assert(("abc"):gsub("", "-") == "-a-b-c-")
assert(("x=1, y=2"):gsub("(%w+)=(%w+)", "%2=%1") == "1=x, 2=y")
local n = 0
local _ = ("a b c"):gsub("%a", function(w) n = n + 1 end)
assert(n == 3)
local counts = setmetatable({}, {__index = function() return 0 end})
local _ = ("the quick and the lazy and the dog"):gsub("%w+", function(w)
  counts[w] = counts[w] + 1
end)
assert(counts["the"] == 3 and counts["and"] == 2)
-- gmatch
local words = {}
for w in ("one two three"):gmatch("%a+") do words[#words+1] = w end
assert(#words == 3 and words[3] == "three")
-- %b and frontier and backref
assert(("(a(b)c) tail"):match("%b()") == "(a(b)c)")
assert(("THE (quick) fox"):find("%f[%a]%a+") == 1)
assert(("hello hello"):match("(%a+) %1") == "hello")
assert(("abc"):find("%a") == 1)
-- anchors
assert(("abc"):match("^ab") == "ab")
assert(("abc"):match("^bc") == nil)
assert(("abc"):match("c$") == "c")
-- string basics
assert(("Hello"):upper() == "HELLO" and ("Hello"):lower() == "hello")
assert(("abc"):rep(3, "-") == "abc-abc-abc")
assert(("abc"):reverse() == "cba")
assert(("  trim  "):match("^%s*(.-)%s*$") == "trim")
assert(#("hello") == 5)
assert(string.sub("hello", -3) == "llo")
assert(string.sub("hello", 2, 3) == "el")
assert(string.byte("A") == 65)
assert(string.char(72, 105) == "Hi")
-- format
assert(string.format("%d %s %5.2f", 42, "x", 3.14159) == "42 x  3.14")
assert(string.format("%q", 'a"b\n') == "\"a\\\"b\\n\"")
assert(string.format("%x", 255) == "ff")
assert(string.format("[%5s]", "ab") == "[   ab]")
assert(string.format("[%-5d]", 42) == "[42   ]")
assert(("%s"):format(1.5) == "1.5")
assert(tostring(1/0) == "inf" and tostring(3) == "3" and tostring(0.5) == "0.5")
assert(tonumber("0x10") == 16 and tonumber("  10 ") == 10)
assert(tonumber("ff", 16) == 255)
print("smoke3 OK")
