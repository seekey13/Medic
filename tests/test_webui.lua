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
-- A second id or ts line means two requests got concatenated; silently
-- keeping the last value would apply an envelope that was never written as
-- such, so this rejects rather than picking a winner.
rejects('id|abc\nid|def\nts|' .. NOW, 'a duplicate id line')
rejects('id|abc\nts|' .. NOW .. '\nts|' .. NOW, 'a duplicate ts line')
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
    local settings = { heal_threshold = 75, heal_enabled = false, risk_tier = 'medium',
                        focus_target = 'Alice' }
    return {
        settings = settings,
        calls = calls,
        index = {
            set = {
                heal_threshold = { t = 'slider', key = 'heal_threshold', min = 1, max = 100 },
                heal_enabled = { t = 'check', key = 'heal_enabled' },
                risk_tier = { t = 'combo', key = 'risk_tier',
                              options = { 'lowest', 'medium', 'highest' } },
                -- Unlike risk_tier, this combo can be cleared: 'None' is one
                -- of its real options, the way a clearable target picker's is.
                focus_target = { t = 'combo', key = 'focus_target',
                                 options = { 'None', 'Alice', 'Bob' } },
            },
            -- 'Utsusemi' stands in for a real self-cast group (Ninja's
            -- Utsusemi tiers, Black Mage's spikes, Scholar's arts/storm):
            -- schema.index only files a grouped row under idx.ability when
            -- its representative ability has a plain string command, i.e. it
            -- cannot target someone else. A party-targetable ability like
            -- Protect (command is a closure) is filed under idx.targets
            -- instead, even when grouped -- see is_party_target/ability_row
            -- in lib/ui/schema.lua. 'Protect' here would misrepresent that.
            ability = { ['Cure IV'] = { group = false }, ['Utsusemi'] = { group = true } },
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

-- tonumber is too permissive for an untrusted field to ride on directly:
-- hex, scientific notation and floats must all be rejected even though
-- tonumber would happily parse each of them.
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|0x10'), c).ok,
    'a hex slider value was accepted')
assert(c.settings.heal_threshold == 75, 'a rejected hex value still changed a setting')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|1e400'), c).ok,
    'a scientific-notation slider value was accepted')
assert(c.settings.heal_threshold == 75, 'a rejected scientific-notation value still changed a setting')
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|heal_threshold|1.0'), c).ok,
    'a float slider value was accepted')
assert(c.settings.heal_threshold == 75, 'a rejected float value still changed a setting')

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

-- 'None' is only special when the combo actually lists it as an option; a
-- combo that does not (risk_tier) rejects it exactly like any other unknown
-- value rather than nulling the setting out.
c = ctx()
assert(not webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|risk_tier|None'), c).ok,
    'None was accepted by a combo that does not list it as an option')
assert(c.settings.risk_tier == 'medium', 'a rejected None still cleared a setting')

-- A combo that does list 'None' (focus_target) maps it to nil rather than
-- storing the literal string, which would leave the setting pointed at a
-- character actually named None.
c = ctx()
local none_result = webui.apply(accepts('id|a\nts|' .. NOW .. '\nset|focus_target|None'), c)
assert(none_result.ok, 'a listed None option was rejected: ' .. tostring(none_result.err))
assert(c.settings.focus_target == nil, 'None did not clear the setting')

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
assert(webui.apply(accepts('id|a\nts|' .. NOW .. '\ngroup|Utsusemi|on'), c).ok)
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

-- The same atomicity has to hold for the side-effecting verbs, not only for
-- plain settings: webui.apply plans every op (plan_op) before its second pass
-- touches ctx.toggles, so a cmd/ability/buff toggle must never fire just
-- because it happened to come before a later op that turns out invalid.
c = ctx()
local mixed_cmd = webui.apply(accepts('id|a\nts|' .. NOW
    .. '\ncmd|start\nset|risk_tier|reckless'), c)
assert(not mixed_cmd.ok, 'a request with a valid cmd followed by an invalid op was accepted')
assert(#c.calls.command == 0 and #c.calls.ability == 0 and #c.calls.buff == 0
    and c.calls.saves == 0, 'cmd fired before the rest of the request was found invalid')

c = ctx()
local mixed_ability = webui.apply(accepts('id|a\nts|' .. NOW
    .. '\nability|Cure IV|off\nset|risk_tier|reckless'), c)
assert(not mixed_ability.ok, 'a request with a valid ability toggle followed by an invalid op was accepted')
assert(#c.calls.command == 0 and #c.calls.ability == 0 and #c.calls.buff == 0
    and c.calls.saves == 0, 'ability toggle fired before the rest of the request was found invalid')

c = ctx()
local mixed_buff = webui.apply(accepts('id|a\nts|' .. NOW
    .. '\nbuff|Protect V|1|on\nset|risk_tier|reckless'), c)
assert(not mixed_buff.ok, 'a request with a valid buff toggle followed by an invalid op was accepted')
assert(#c.calls.command == 0 and #c.calls.ability == 0 and #c.calls.buff == 0
    and c.calls.saves == 0, 'buff toggle fired before the rest of the request was found invalid')

-- Response -----------------------------------------------------------------
-- Whole-line comparison rather than string.find: a plain substring search
-- would let a regressed 'ok|10' still satisfy a check for 'ok|1', or an
-- 'err|nopeXYZ' still satisfy a check for 'err|nope'.
local function lines_of(text)
    local out = {}
    for line in text:gmatch('[^\n]+') do out[#out + 1] = line end
    return out
end

local ok_lines = lines_of(webui.format_response('abc', { ok = true, applied = 2 }))
assert(ok_lines[1] == 'id|abc', 'response lost the id')
assert(ok_lines[2] == 'ok|1', 'success not marked')
assert(ok_lines[3] == 'msg|Applied 2 change(s)', 'success message wrong')

local err_lines = lines_of(webui.format_response('abc', { ok = false, err = 'nope' }))
assert(err_lines[1] == 'id|abc', 'error response lost the id')
assert(err_lines[2] == 'ok|0', 'failure not marked')
assert(err_lines[3] == 'err|nope', 'failure reason wrong')

print('test_webui.lua: OK')
