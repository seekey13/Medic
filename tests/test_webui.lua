--[[
Self-check for the request channel in lib/core/webui.lua.

Run from the addon root with a standalone Lua interpreter:
    lua tests/test_webui.lua

request.txt is written by a web page and drives real settings changes and real
game commands, so every field is checked before any handler sees it. Nothing
here touches AshitaCore.
]]--

package.path = './?.lua;' .. package.path
local webui = require('lib.core.webui')

local NOW = 1000000

local function accepts(text, why)
    local req, err = webui.parse_request(text, NOW)
    assert(req, (why or 'rejected a valid request') .. ': ' .. tostring(err))
    return req
end

local function rejects(text, why)
    local req, err = webui.parse_request(text, NOW)
    assert(req == nil, 'accepted ' .. (why or 'an invalid request'))
    assert(type(err) == 'string' and #err > 0, 'rejection carried no reason')
end

-- Envelope -----------------------------------------------------------------
rejects('', 'an empty file')
rejects('set|heal_threshold|75', 'a request with no id')
rejects('id|abc\nset|heal_threshold|75', 'a request with no ts')
rejects('id|a/b\nts|' .. NOW, 'a path-ish id')
rejects('id|' .. string.rep('x', 65) .. '\nts|' .. NOW, 'an over-long id')
rejects('id|abc\nts|not-a-number', 'a non-numeric ts')
rejects('id|abc\nts|' .. (NOW - 7200), 'an expired request')
-- A clock a little ahead is normal drift between browser and game client,
-- which share a machine; a clock hours ahead would never age out.
accepts('id|abc\nts|' .. (NOW + 60), 'a slightly future ts')
rejects('id|abc\nts|' .. (NOW + 600), 'a far-future ts')
rejects('id|abc\nts|' .. NOW .. '\nexec|format c:', 'an unknown verb')

-- Ops ----------------------------------------------------------------------
local req = accepts('id|abc\nts|' .. NOW
    .. '\nset|heal_threshold|75'
    .. '\nability|Cure IV|off'
    .. '\ngroup|Protect|on'
    .. '\nbuff|Protect V|1|on'
    .. '\ncmd|start')
assert(req.id == 'abc', 'id lost')
assert(#req.ops == 5, 'expected 5 ops, got ' .. #req.ops)
assert(req.ops[1][2] == 'heal_threshold' and req.ops[1][3] == '75', 'set op malformed')
assert(req.ops[4][2] == 'Protect V' and req.ops[4][3] == '1', 'buff op malformed')

-- Blank lines and CRLF: the browser writes \n, but a hand-edited file will not.
local crlf = accepts('id|abc\r\nts|' .. NOW .. '\r\n\r\ncmd|stop\r\n', 'a CRLF file')
assert(#crlf.ops == 1 and crlf.ops[1][2] == 'stop', 'CRLF op lost')

-- Applying -----------------------------------------------------------------
local function ctx()
    local calls = { ability = {}, buff = {}, command = {}, saves = 0 }
    local settings = { heal_threshold = 75, heal_enabled = false, risk_tier = 'medium' }
    return {
        settings = settings,
        calls = calls,
        index = {
            set = {
                heal_threshold = { t = 'slider', key = 'heal_threshold', min = 1, max = 100 },
                heal_enabled = { t = 'check', key = 'heal_enabled' },
                risk_tier = { t = 'combo', key = 'risk_tier',
                              options = { 'lowest', 'medium', 'highest' } },
            },
            ability = { ['Cure IV'] = { group = false }, ['Protect'] = { group = true } },
            targets = { ['Protect V'] = { group = false, slots = { ['0'] = true, ['1'] = true } } },
        },
        toggles = {
            ability = function(name, is_group, on)
                calls.ability[#calls.ability + 1] = { name, is_group, on }
            end,
            buff = function(name, is_group, slot, on)
                calls.buff[#calls.buff + 1] = { name, is_group, slot, on }
            end,
            command = function(word) calls.command[#calls.command + 1] = word end,
            save = function() calls.saves = calls.saves + 1 end,
        },
    }
end

local c = ctx()
local result = webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|40'), c)
assert(result.ok and result.applied == 1, 'slider set failed: ' .. tostring(result.err))
assert(c.settings.heal_threshold == 40, 'slider value not written')
assert(c.calls.saves == 1, 'settings were not saved')

-- Sliders clamp rather than refuse: the browser and the addon can disagree about
-- a range for one poll after a job change, and clamping is the harmless answer.
c = ctx()
webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|9999'), c)
assert(c.settings.heal_threshold == 100, 'slider did not clamp to max')
c = ctx()
webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|0'), c)
assert(c.settings.heal_threshold == 1, 'slider did not clamp to min')

-- Types are enforced per control, so a string can never land in a number key.
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|lots'), c).ok,
    'a non-numeric slider value was accepted')
assert(c.settings.heal_threshold == 75, 'a rejected request still changed a setting')

c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_enabled|true'), c).ok)
assert(c.settings.heal_enabled == true, 'checkbox not written')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_enabled|1'), c).ok,
    'a checkbox took something other than true/false')

c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|risk_tier|highest'), c).ok)
assert(c.settings.risk_tier == 'highest', 'combo not written')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|risk_tier|reckless'), c).ok,
    'a combo took a value outside its options')

-- Anything not in the schema right now is not settable right now.
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|automation_enabled|true'), c).ok,
    'a key outside the schema was accepted')

-- Abilities and groups go through the addon's own toggles, never straight to
-- settings: that is what keeps the song limit and the disabled_ sync honest.
c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\nability|Cure IV|off'), c).ok)
assert(c.calls.ability[1][1] == 'Cure IV' and c.calls.ability[1][2] == false
    and c.calls.ability[1][3] == false, 'ability toggle args wrong')
assert(c.settings.disabled_Cure_IV == nil, 'apply wrote the disabled_ key behind the toggle')

c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\ngroup|Protect|on'), c).ok)
assert(c.calls.ability[1][2] == true and c.calls.ability[1][3] == true, 'group toggle args wrong')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\ngroup|Cure IV|on'), c).ok,
    'a single ability was accepted as a group')

c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\nbuff|Protect V|1|on'), c).ok)
assert(c.calls.buff[1][3] == 1, 'ME/P1-P5 slots reach the toggle as numbers')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nbuff|Protect V|4|on'), c).ok,
    'a slot outside the row was accepted')

c = ctx()
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\ncmd|start'), c).ok)
assert(c.calls.command[1] == 'start', 'command not dispatched')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\ncmd|reload'), c).ok,
    'an unknown command was accepted')

-- A request that is wrong halfway through changes nothing at all.
c = ctx()
local mixed = webui.apply(accepts('id|a\nts|' .. NOW
    .. '\nset|heal_threshold|40\nset|risk_tier|reckless'), c)
assert(not mixed.ok, 'a half-invalid request was accepted')
assert(c.settings.heal_threshold == 75, 'the valid half of a rejected request was applied')

-- Response -----------------------------------------------------------------
local ok_body = webui.format_response('abc', { ok = true, applied = 2 })
assert(ok_body:find('id|abc', 1, true), 'response lost the id')
assert(ok_body:find('ok|1', 1, true), 'success not marked')
local err_body = webui.format_response('abc', { ok = false, err = 'nope' })
assert(err_body:find('ok|0', 1, true) and err_body:find('err|nope', 1, true),
    'failure not reported')

print('test_webui.lua: OK')
