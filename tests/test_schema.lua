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

-- Finding 1: Group/AOE Healing target rows (ui.render_heal_group_selection) --
-- config.lua:1130/1162 draw a Group/AOE Targets row inside these sections;
-- ME/P1-P5 default ON (state[key] ~= false in render_heal_group_selection).
-- This is KEY-level opt-out (schema.lua mode 'group_optout'): a slot is ON
-- unless ITS OWN key is explicitly false -- whether the sub-table exists at
-- all never matters. Contrast with wake below, which is TABLE-level opt-in.
local heal_targets = find_control(heal, function(c) return c.t == 'targets' and c.name == 'heal_group' end)
assert(heal_targets, 'Group Healing must have a heal_group targets row')
assert(heal_targets.label == 'Group Targets', 'Group Targets row mislabeled')
assert(table.concat(heal_targets.slots, ',') == '0,1,2', 'Group Targets slots follow party size, like a buff row')
assert(heal_targets.value['0'] == true and heal_targets.value['1'] == true and heal_targets.value['2'] == true,
    'ME/P1-P5 default ON for Group Targets')

local aoe = find_section(built, 'heal_aoe_enabled')
local aoe_targets = find_control(aoe, function(c) return c.t == 'targets' and c.name == 'heal_aoe_group' end)
assert(aoe_targets, 'AOE Healing must have a heal_aoe_group targets row')
assert(aoe_targets.label == 'AOE Targets', 'AOE Targets row mislabeled')
assert(aoe_targets.value['0'] == true, 'AOE Targets default ON')

-- Group Targets hides for an all-self-only heal set, same gate as Focus Healing.
local self_only_job = job_def()
for _, a in ipairs(self_only_job.abilities.heal) do a.self_only = true end
local self_only_heal = find_section(schema.build(self_only_job, {}, env()), 'heal_enabled')
assert(self_only_heal, 'Group Healing section still shows for self-only heals')
assert(not find_control(self_only_heal, function(c) return c.name == 'heal_group' end),
    'Group Targets must hide when every heal is self-only')

-- An explicit false turns off only that slot; make_group_filter never looks at
-- whether the sub-table exists, so an unset sibling stays ON even though
-- party_buffs.heal_group is now a non-empty table.
local heal_group_off = find_control(
    find_section(schema.build(job_def(), {}, env({ party_buffs = { heal_group = { [1] = false } } })), 'heal_enabled'),
    function(c) return c.name == 'heal_group' end)
assert(heal_group_off.value['0'] == true and heal_group_off.value['1'] == false and heal_group_off.value['2'] == true,
    'heal_group: an explicit false turns off only that slot; unset siblings stay ON')

local aoe_group_off = find_control(
    find_section(schema.build(job_def(), {}, env({ party_buffs = { heal_aoe_group = { [1] = false } } })), 'heal_aoe_enabled'),
    function(c) return c.name == 'heal_aoe_group' end)
assert(aoe_group_off.value['0'] == true and aoe_group_off.value['1'] == false and aoe_group_off.value['2'] == true,
    'heal_aoe_group: an explicit false turns off only that slot; unset siblings stay ON')

-- Finding 2 (fix pass 2): Sleep Removal is TABLE-level opt-in, not key-level
-- opt-out -- is_wake_allowed in lib/actions/status_removal.lua (~line 526):
--   if not wake_targets then return true end   -- sub-table absent: all ON
--   return wake_targets[key] == true            -- sub-table present: must be true
-- "Sub-table absent" and "sub-table present but this slot absent" are
-- different outcomes (all ON vs. this slot OFF); schema.lua's 'table_optin'
-- mode must tell them apart rather than collapsing both to nil via `or {}`.
local function wake_job_def()
    local jd = job_def()
    jd.abilities.heal[1].wakes = true
    return jd
end
local wake_built = schema.build(wake_job_def(), {}, env())
local wake_section = find_section(wake_built, 'wake_enabled')
assert(wake_section, 'Sleep Removal must show when a heal ability wakes')

-- Case 1: sub-table entirely absent -- every slot ON.
local wake_row = find_control(wake_section, function(c) return c.name == 'wake' end)
assert(wake_row, 'Sleep Removal targets row missing')
assert(wake_row.value['1'] == true and wake_row.value['2'] == true,
    'Sleep Removal targets must default ON when party_buffs.wake is entirely unset')

-- Case 2: sub-table present with only slot 1 explicitly true -- slot 2, which
-- has no entry of its own, must read OFF now that the table exists at all.
-- This is the exact repro from the finding: a party member with no entry in
-- a non-empty wake table is silently OFF in game, and the schema must agree.
local wake_partial_row = find_control(
    find_section(schema.build(wake_job_def(), {}, env({ party_buffs = { wake = { [1] = true } } })), 'wake_enabled'),
    function(c) return c.name == 'wake' end)
assert(wake_partial_row.value['1'] == true and wake_partial_row.value['2'] == false,
    'wake: once the sub-table exists, a slot with no entry of its own is OFF')

-- Case 3: sub-table present with slot 1 explicitly false -- OFF, and slot 2
-- (unset, same non-empty table) is OFF too, unlike heal_group/heal_aoe_group above.
local wake_off_row = find_control(
    find_section(schema.build(wake_job_def(), {}, env({ party_buffs = { wake = { [1] = false } } })), 'wake_enabled'),
    function(c) return c.name == 'wake' end)
assert(wake_off_row.value['1'] == false and wake_off_row.value['2'] == false,
    'wake: an explicitly false slot is OFF, and an unset sibling is OFF too once the table exists')

-- Finding 3: Pianissimo/1 Shadow/Song Duration globals ------------------------
-- panel.lua draws all three unconditionally (lines 467-516); they are
-- persisted functional settings, so the web gear panel must expose them too.
local pian = find_global(built, 'pianissimo_fast_casting')
assert(pian and pian.t == 'check' and pian.value == false, 'Pianissimo Fast Casting missing from globals')
local shadow = find_global(built, 'cast_with_1_shadow')
assert(shadow and shadow.t == 'check' and shadow.value == false, 'Cast with 1 Shadow missing from globals')
local song = find_global(built, 'song_duration')
assert(song and song.t == 'slider' and song.min == 0 and song.max == 999 and song.value == 0,
    'Song Duration (s) missing or has the wrong range/default')

-- Order matches the panel exactly (panel.lua:440-562): Multisend Follow, Hold
-- AOE for Group, Pianissimo Fast Casting, Cast with 1 Shadow, then the
-- potency/duration row (Cure Potency, Waltz Potency, Song Duration), THEN AFK
-- Sleep and its Timeout, then UI Opacity. Pin the whole relative order (not
-- just local adjacency) -- an adjacency-only check would still pass if the
-- AFK pair and the potency block were swapped as whole blocks.
local function global_index(b, key)
    for i, c in ipairs(b.globals) do
        if c.key == key then return i end
    end
    return nil
end
local panel_order_keys = {
    'multisend_follow', 'hold_aoe_for_group', 'pianissimo_fast_casting', 'cast_with_1_shadow',
    'cure_potency', 'waltz_potency', 'song_duration', 'afk_enabled', 'afk_timeout', 'ui_opacity',
}
local prev_key, prev_i = nil, nil
for _, key in ipairs(panel_order_keys) do
    local i = global_index(built, key)
    assert(i, key .. ' missing from globals')
    if prev_i then
        assert(i > prev_i, key .. ' must come after ' .. prev_key .. ', matching panel.lua order')
    end
    prev_key, prev_i = key, i
end

-- Finding 5: party_options must use the real player name, never 'ME' ---------
-- render_party_dropdown inserts common.get_party_member_name(0); a saved
-- focus_target is matched against real party names elsewhere, so the literal
-- string 'ME' can never be selected and must never appear as an option.
local named = schema.build(job_def(), {}, env({ player_name = 'Seekey' }))
local focus_target = find_control(find_section(named, 'focus_enabled'),
    function(c) return c.key == 'focus_target' end)
assert(focus_target, 'Focus Target control missing')
local focus_opts = table.concat(focus_target.options, ',')
assert(focus_opts:find('Seekey', 1, true), 'Focus Target options must include the real player name')
assert(not focus_opts:find('ME', 1, true), 'Focus Target options must never contain the literal ME')

-- No env.player_name: omit the player entry, don't fall back to a placeholder.
local unnamed_focus_target = find_control(find_section(built, 'focus_enabled'),
    function(c) return c.key == 'focus_target' end)
assert(table.concat(unnamed_focus_target.options, ',') == 'None,Butt,Mule',
    'a missing env.player_name must omit the player entry, not fall back to ME')

-- Finding 6: Geo control order -------------------------------------------
-- Real order (config.lua:1476-1594): Geo-bt rows -> Full Circle -> Distance
-- slider -> Timer slider (GEO only) -> Blaze of Glory -> Entrust. Blaze of
-- Glory must NOT be bundled with Full Circle ahead of the sliders.
local function geo_job_def()
    local jd = job_def()
    jd.job_id = 21
    jd.abilities.geo = {
        { name = 'Geo-Frailty', level = 1, command = function() end },
        { name = 'Blaze of Glory', level = 1, command = 'ja' },
        { name = 'Entrust', level = 1, command = 'ja' },
    }
    table.insert(jd.abilities.buff, { name = 'Indi-Frailty', level = 1, group = 'Indi', command = function() end })
    return jd
end
local geo = find_section(schema.build(geo_job_def(), {}, env()), 'geo_enabled')
assert(geo, 'Geo section missing')
local function control_index(section, predicate)
    for i, c in ipairs(section.controls) do
        if predicate(c) then return i end
    end
    return nil
end
local i_full_circle = control_index(geo, function(c) return c.name == 'Geo-Frailty' end)
local i_distance = control_index(geo, function(c) return c.key == 'geo_distance_threshold' end)
local i_timer = control_index(geo, function(c) return c.key == 'geo_bt_timer' end)
local i_blaze = control_index(geo, function(c) return c.name == 'Blaze of Glory' end)
local i_entrust = control_index(geo, function(c) return c.name == 'Entrust' end)
assert(i_full_circle and i_distance and i_timer and i_blaze and i_entrust,
    'Geo controls missing for order check')
assert(i_full_circle < i_distance, 'Full Circle must precede the sliders')
assert(i_distance < i_timer, 'Distance slider must precede the Timer slider')
assert(i_timer < i_blaze, 'Blaze of Glory must render after the sliders, not bundled with Full Circle')
assert(i_blaze < i_entrust, 'Blaze of Glory must render before Entrust')

-- Finding 7: level_ok must test "no level" before main_job_only --------------
-- can_use_ability (config.lua:61-78) returns true for a level-less ability
-- before it ever looks at main_job_only, so a main_job_only subjob ability
-- with no level field must still be usable.
local weird_job = job_def()
table.insert(weird_job.abilities.buff,
    { name = 'Weird Buff', main_job_only = true, is_main_job = false, command = function() end })
local weird_buffs = find_section(schema.build(weird_job, {}, env()), 'buff_enabled')
assert(find_control(weird_buffs, function(c) return c.name == 'Weird Buff' end),
    'a level-less ability must be usable even when main_job_only marks it subjob-only')

-- Finding 8: a stale selected_<group> falls back to the highest tier ---------
-- get_selected_ability_for_group (components.lua:339-370) validates the saved
-- tier name and falls back to the highest when it is stale; schema.lua must
-- do the same instead of passing the stale name straight through, and must
-- stay pure (never write back to the settings table it was given).
local stale_settings = { selected_Protect = 'Nonexistent Tier' }
local stale_buffs = find_section(schema.build(job_def(), stale_settings, env()), 'buff_enabled')
local stale_tier = find_control(stale_buffs, function(c) return c.key == 'selected_Protect' end)
assert(stale_tier and stale_tier.value == 'Protect II',
    'a stale selected_Protect must fall back to the highest tier, not pass the stale name through')
assert(stale_settings.selected_Protect == 'Nonexistent Tier',
    'schema.build must never mutate the settings table it was given')

print('test_schema.lua: OK')
