--[[
Self-check for lib/ui/schema.lua.

Run from the addon root with a standalone Lua interpreter:
    lua tests/test_schema.lua

The schema is the contract in both directions: the browser draws what is in it,
and lib/core/webui.lua refuses to set anything that is not in it. A control that
goes missing here silently becomes an unreachable setting, so the visibility
rules are what this file actually tests.
]]--

package.path = './?.lua;' .. package.path
local schema = require('lib.ui.schema')

-- A White-Mage-shaped job def, small enough to reason about. `command` being a
-- function is what marks an ability as castable on someone else, exactly as
-- can_cast_on_party in lib/ui/components.lua tests it.
local function job_def()
    return {
        job_id = 3,
        job_name = 'White Mage',
        resource_type = 'mp',
        abilities = {
            heal = {
                { name = 'Cure', level = 1, cost = 8, command = function() end },
                { name = 'Cure IV', level = 41, cost = 88, command = function() end },
                { name = 'Cure V', level = 99, cost = 135, command = function() end },
            },
            heal_aoe = {
                { name = 'Curaga', level = 16, cost = 60, command = function() end },
            },
            buff = {
                { name = 'Protect', level = 7, group = 'Protect', command = function() end },
                { name = 'Protect II', level = 27, group = 'Protect', command = function() end },
                { name = 'Divine Seal', level = 50, command = 'ja' },
            },
            revive = {
                { name = 'Raise', level = 25, command = function() end },
            },
        },
    }
end

local function env(overrides)
    local e = {
        main_level = 75, sub_level = 37,
        party_size = 3,
        party_names = { 'Butt', 'Mule' },
        tracked_names = {},
        party_buffs = {},
        item_removals = {},
        item_inventory_loaded = false,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

local function find_section(built, key)
    for _, s in ipairs(built.sections) do
        if s.key == key then return s end
    end
    return nil
end

local function find_control(section, predicate)
    for _, c in ipairs(section.controls) do
        if predicate(c) then return c end
    end
    return nil
end

-- Sections present, and in the window's own order -------------------------
local built = schema.build(job_def(), {}, env())
local order = {}
for _, s in ipairs(built.sections) do order[#order + 1] = s.key end
local joined = table.concat(order, ',')
assert(joined:find('follow_enabled,', 1, true) == 1, 'Auto Follow leads the window: ' .. joined)
assert(joined:find('focus_enabled,heal_enabled,heal_aoe_enabled', 1, true),
    'healing sections keep their order: ' .. joined)
assert(joined:find('buff_enabled', 1, true), 'Buffs section missing: ' .. joined)
assert(joined:find('revive_enabled', 1, true), 'Revive section missing: ' .. joined)
assert(not joined:find('roll_enabled', 1, true), 'Rolls must not show without roll abilities')
assert(not joined:find('geo_enabled', 1, true), 'Geo must not show without geo abilities')

-- Section enable defaults --------------------------------------------------
assert(find_section(built, 'heal_enabled').enabled == false, 'Group Healing defaults off')
local on = schema.build(job_def(), { heal_enabled = true }, env())
assert(find_section(on, 'heal_enabled').enabled == true, 'an explicit true is honoured')

-- Sliders carry the in-game range -----------------------------------------
local heal = find_section(built, 'heal_enabled')
local threshold = find_control(heal, function(c) return c.key == 'heal_threshold' end)
assert(threshold and threshold.t == 'slider', 'Group (HP%) slider missing')
assert(threshold.value == 75 and threshold.min == 1 and threshold.max == 100,
    'Group (HP%) default/range wrong')

-- Group Healing rows are plain checkboxes (ui.ability_checkbox), even though a
-- Cure can be cast on someone else.
local cure4 = find_control(heal, function(c) return c.name == 'Cure IV' end)
assert(cure4 and cure4.t == 'ability' and cure4.value == true, 'Cure IV row missing or off')
assert(not find_control(heal, function(c) return c.name == 'Cure V' end),
    'Cure V is level 99 and must be hidden at 75')

-- disabled_<name> inverts into the row's value
local off = schema.build(job_def(), { disabled_Cure_IV = true }, env())
assert(find_control(find_section(off, 'heal_enabled'),
    function(c) return c.name == 'Cure IV' end).value == false, 'disabled_ did not invert')

-- Buffs rows are ME/P1-P5 target rows (ui.render_ability) ------------------
local buffs = find_section(built, 'buff_enabled')
local protect = find_control(buffs, function(c) return c.name == 'Protect' end)
assert(protect and protect.t == 'targets', 'Protect should be a target row')
assert(protect.group == true, 'Protect is a grouped ability')
assert(table.concat(protect.slots, ',') == '0,1,2', 'a three-member party gives ME,P1,P2')
assert(protect.value['0'] == false, 'no party_buffs entry reads as off')
assert(not find_control(buffs, function(c) return c.name == 'Protect II' end),
    'a grouped tier must not get its own row')
local tier = find_control(buffs, function(c) return c.key == 'selected_Protect' end)
assert(tier and tier.t == 'combo', 'a grouped row needs a tier dropdown')
assert(table.concat(tier.options, ',') == 'Protect,Protect II', 'tiers listed low to high')

-- Divine Seal cannot be cast on anyone else, so it stays a plain row.
local seal = find_control(buffs, function(c) return c.name == 'Divine Seal' end)
assert(seal and seal.t == 'ability', 'a self-only ability should be a plain row')

-- Live party_buffs feed the target row; string keys on the wire ------------
local lit = schema.build(job_def(), {}, env({ party_buffs = { Protect = { [0] = true, [2] = true } } }))
local lit_protect = find_control(find_section(lit, 'buff_enabled'),
    function(c) return c.name == 'Protect' end)
assert(lit_protect.value['0'] == true and lit_protect.value['1'] == false
    and lit_protect.value['2'] == true, 'party_buffs did not reach the wire')

-- Party size shrinks the slot list ----------------------------------------
local solo = schema.build(job_def(), {}, env({ party_size = 1 }))
local solo_protect = find_control(find_section(solo, 'buff_enabled'),
    function(c) return c.name == 'Protect' end)
assert(table.concat(solo_protect.slots, ',') == '0', 'solo leaves only ME')

-- Multisend Follow hides the Auto Follow section, as the window does -------
assert(find_section(built, 'follow_enabled'), 'Auto Follow shows in native follow mode')
local ms = schema.build(job_def(), { multisend_follow = true }, env())
assert(not find_section(ms, 'follow_enabled'), 'Auto Follow hides in Multisend mode')

-- Globals ------------------------------------------------------------------
local function find_global(b, key)
    for _, c in ipairs(b.globals) do
        if c.key == key then return c end
    end
    return nil
end
assert(find_global(built, 'multisend_follow'), 'Multisend Follow missing from globals')
local afk = find_global(built, 'afk_timeout')
assert(afk and afk.min == 60 and afk.max == 3600 and afk.value == 600, 'AFK timeout range wrong')
assert(find_global(built, 'cure_potency').max == 100, 'Cure Potency range wrong')
assert(find_global(built, 'display_mode').t == 'combo', 'display_mode is a dropdown')

-- Attack Range is only offered in Multisend mode, same as the window -------
assert(not find_global(built, 'attack_range'), 'Attack Range hides in native follow mode')
assert(find_global(ms, 'attack_range'), 'Attack Range shows in Multisend mode')

-- Resting only exists on an MP job -----------------------------------------
assert(find_section(built, 'rest_enabled'), 'Resting shows for an MP job')
local tp_job = job_def()
tp_job.resource_type = 'tp'
assert(not find_section(schema.build(tp_job, {}, env()), 'rest_enabled'),
    'Resting must not show for a TP job')

-- Index: what webui.lua validates against ----------------------------------
local idx = schema.index(built)
assert(idx.set.heal_threshold, 'slider not indexed')
assert(idx.set.heal_enabled, 'section enable key not indexed')
assert(idx.set.multisend_follow, 'global not indexed')
assert(idx.ability['Cure IV'], 'checkbox row not indexed')
assert(idx.targets['Protect'] and idx.targets['Protect'].group == true, 'target row not indexed')
assert(idx.targets['Protect'].slots['2'] == true, 'target slot not indexed')
assert(idx.ability['Cure V'] == nil, 'an out-of-level ability must not be settable')

print('test_schema.lua: OK')
