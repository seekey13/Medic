--[[
Self-check for lib/core/json.lua.

Run from the addon root with a standalone Lua interpreter:
    lua tests/test_json.lua

state.json is written every time the config changes, and the writer skips the
disk when the encoded string has not moved -- so byte-stability across two
encodes of equal data is a correctness property here, not a nicety.
]]--

package.path = './?.lua;' .. package.path
local json = require('lib.core.json')

local function eq(actual, expected, why)
    assert(actual == expected,
        (why or 'mismatch') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual))
end

-- Scalars
eq(json.encode(true), 'true', 'boolean true')
eq(json.encode(false), 'false', 'boolean false')
eq(json.encode(75), '75', 'integer')
eq(json.encode('hi'), '"hi"', 'plain string')
eq(json.encode(nil), 'null', 'nil')

-- Strings the game actually produces: quotes and apostrophes in item names,
-- and control characters that would otherwise make the file unparseable.
eq(json.encode('Ni\'ll'), '"Ni\'ll"', 'apostrophe passes through')
eq(json.encode('say "hi"'), '"say \\"hi\\""', 'quote escaped')
eq(json.encode('a\\b'), '"a\\\\b"', 'backslash escaped')
eq(json.encode('a\nb'), '"a\\nb"', 'newline escaped')
eq(json.encode(string.char(1)), '"\\u0001"', 'control character escaped')

-- Arrays
eq(json.encode({ 1, 2, 3 }), '[1,2,3]', 'number array')
eq(json.encode({ 'a', 'b' }), '["a","b"]', 'string array')

-- Objects: keys sorted, so two encodes of equal data are byte-identical.
eq(json.encode({ b = 2, a = 1 }), '{"a":1,"b":2}', 'object keys sorted')
eq(json.encode({ ['0'] = true, ['1'] = false }), '{"0":true,"1":false}', 'string-number keys')
eq(json.encode({}), '{}', 'empty table is an object')

local once = json.encode({ z = { 1, 2 }, a = 'x', m = true })
local twice = json.encode({ m = true, a = 'x', z = { 1, 2 } })
eq(once, twice, 'equal tables encode identically regardless of insert order')

-- NaN and the infinities are not JSON; null keeps the file parseable.
eq(json.encode(0 / 0), 'null', 'NaN')
eq(json.encode(math.huge), 'null', 'infinity')

print('test_json.lua: OK')
