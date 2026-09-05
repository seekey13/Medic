--[[
    Web UI schema

    The config window as data: the same sections, in the same order, with the
    same enable keys, defaults and visibility rules that lib/ui/config.lua
    renders with ImGui. lib/core/webui.lua encodes this into state.json for the
    web app to draw, and validates incoming edits against it -- a control that is
    not in the schema right now is not settable right now, which is the same
    answer the in-game window gives by simply not drawing it.

    Nothing here touches AshitaCore or imgui: everything the game knows arrives
    in `env`, so tests/test_schema.lua can drive it with a hand-built job def.
]]--

local schema = {}

-- ============================================================================
-- Controls
-- ============================================================================

local function check(key, label, value)
    return { t = 'check', key = key, label = label, value = value and true or false }
end

local function slider(key, label, value, min, max)
    return { t = 'slider', key = key, label = label,
             value = math.floor(tonumber(value) or min), min = min, max = max }
end

-- `options` is always non-empty (callers put 'None' in it when the setting is
-- clearable), so it never encodes as an empty table -- which JSON would write as
-- an object and the reader would fail to iterate.
local function combo(key, label, value, options)
    return { t = 'combo', key = key, label = label,
             value = value or options[1], options = options }
end

-- ============================================================================
-- Ability gating (mirrors can_use_ability / is_subjob_duplicate in config.lua)
-- ============================================================================

local function level_ok(ability, env)
    if not ability then return false end
    -- can_use_ability tests "no level field" before main_job_only -- an ability
    -- with no level is always usable, even a main_job_only one on a subjob.
    if not ability.level then return true end
    if ability.main_job_only and ability.is_main_job == false then return false end
    if ability.is_main_job == false then
        return (env.sub_level or 0) >= ability.level
    end
    return (env.main_level or 0) >= ability.level
end

local function is_subjob_duplicate(job_def, ability)
    if ability.is_main_job ~= false then return false end
    if not job_def or not job_def.abilities then return false end
    for _, abilities in pairs(job_def.abilities) do
        if type(abilities) == 'table' then
            for _, other in ipairs(abilities) do
                if other.name == ability.name and other.is_main_job ~= false then
                    return true
                end
            end
        end
    end
    return false
end

local function usable(job_def, ability, env)
    return level_ok(ability, env) and not is_subjob_duplicate(job_def, ability)
end

-- has_usable_abilities in config.lua checks the level only, not the subjob
-- duplicate -- a section whose every row is a duplicate still opens there, so
-- match it rather than being cleverer.
local function any_usable(list, env)
    if not list then return false end
    for _, a in ipairs(list) do
        if level_ok(a, env) then return true end
    end
    return false
end

-- ============================================================================
-- Ability rows
-- ============================================================================

local function ability_setting_key(name, is_group)
    if is_group then return 'disabled_group_' .. name end
    return 'disabled_' .. name:gsub(' ', '_')
end

local function ability_enabled(settings, name, is_group)
    local key = ability_setting_key(name, is_group)
    if settings[key] == nil then return true end
    return not settings[key]
end

-- can_cast_on_party: an ability whose command is a closure takes a target.
local function is_party_target(ability)
    return type(ability.command) == 'function'
end

-- ME/P1-P5, plus the bard area slot 'A' on songs. Strings throughout, so the
-- encoder can never mistake a target map for a JSON array.
local function target_slots(ability, env)
    local slots = {}
    if ability and ability.magic == 'song' then slots[#slots + 1] = 'A' end
    slots[#slots + 1] = '0'
    for i = 1, math.min((env.party_size or 1) - 1, 5) do
        slots[#slots + 1] = tostring(i)
    end
    return slots
end

-- The live party_buffs table is keyed by NUMBER for ME/P1-P5 and by the string
-- 'A' for the area slot; the wire is strings for both.
--
-- `mode` picks which of three real readers of this same party_buffs table a
-- row mirrors. They disagree on what an *unset slot* means, and one of them
-- also disagrees on what an *entirely absent sub-table* means, so a single
-- boolean cannot express all three -- hence a mode string instead:
--
--   nil (default)   -- a plain buff/debuff target row (Buffs, Debuff Removal).
--                       No real reader opts these in for you; unset is OFF
--                       whether or not the sub-table exists.
--   'group_optout'  -- heal_group / heal_aoe_group. make_group_filter in
--                       lib/actions/heal.lua returns
--                       `not (targets ~= nil and targets[key] == false)`:
--                       a slot is ON unless its OWN key is explicitly false --
--                       the sub-table's existence never matters. KEY-level
--                       opt-out.
--   'table_optin'   -- wake (Sleep Removal). is_wake_allowed in
--                       lib/actions/status_removal.lua (~line 526) returns
--                       true for every slot when party_buffs.wake is
--                       entirely absent, but once that sub-table exists at
--                       all, only a slot explicitly set to true stays on --
--                       an unset slot in a *present* table is OFF. TABLE-level
--                       opt-in: the absent/present distinction on the whole
--                       sub-table, not just on one slot, is what flips the
--                       default, so it must be read without an `or {}`
--                       fallback that would erase that distinction.
local function target_values(env, name, slots, mode)
    -- Deliberately no `or {}` here: for 'table_optin', "sub-table absent"
    -- (live == nil) and "sub-table present but this slot absent" are
    -- different states, and collapsing them with a fallback table would
    -- make both read as nil downstream, same as the bug this fixes.
    local live = env.party_buffs and env.party_buffs[name]
    local out = {}
    for _, slot in ipairs(slots) do
        local raw
        if live then
            raw = (slot == 'A') and live['A'] or live[tonumber(slot)]
        end
        if mode == 'group_optout' then
            out[slot] = raw ~= false
        elseif mode == 'table_optin' then
            out[slot] = (live == nil) or (raw == true)
        else
            out[slot] = raw == true
        end
    end
    return out
end

local function ability_row(settings, env, name, is_group, ability)
    if is_party_target(ability) then
        local slots = target_slots(ability, env)
        return { t = 'targets', name = name, label = name, group = is_group,
                 slots = slots, value = target_values(env, name, slots) }
    end
    return { t = 'ability', name = name, label = name, group = is_group,
             value = ability_enabled(settings, name, is_group) }
end

local function group_tiers(job_def, group, env)
    local tiers = {}
    for _, abilities in pairs(job_def.abilities) do
        if type(abilities) == 'table' then
            for _, a in ipairs(abilities) do
                if a.group == group and usable(job_def, a, env)
                    and (not env.has_spell or env.has_spell(a)) then
                    tiers[#tiers + 1] = a
                end
            end
        end
    end
    table.sort(tiers, function(a, b) return (a.level or 0) < (b.level or 0) end)
    return tiers
end

-- Mirrors ui.ability_checkbox: one plain row per ability, groups ignored.
local function emit_checks(out, job_def, list, settings, env)
    if not list then return end
    for _, a in ipairs(list) do
        if usable(job_def, a, env) then
            out[#out + 1] = { t = 'ability', name = a.name, label = a.name,
                              group = false, value = ability_enabled(settings, a.name, false) }
        end
    end
end

-- Mirrors ui.render_ability: a grouped ability collapses to one row plus a tier
-- dropdown, and a row that can target someone else becomes ME/P1-P5 buttons.
local function emit_rows(out, job_def, list, settings, env, filter)
    if not list then return end
    local seen = {}
    for _, a in ipairs(list) do
        if usable(job_def, a, env) and (not filter or filter(a)) then
            local group = a.group
            if group and not settings['ungrouped_' .. group] then
                if not seen[group] then
                    seen[group] = true
                    local tiers = group_tiers(job_def, group, env)
                    if #tiers > 0 then
                        out[#out + 1] = ability_row(settings, env, group, true, a)
                        local names = {}
                        for i, tier in ipairs(tiers) do names[i] = tier.name end
                        -- get_selected_ability_for_group falls back to the highest
                        -- tier when the saved name is stale (job/level change moved
                        -- it out of range); match that instead of passing a name
                        -- through that may no longer be in `names` at all. Pure --
                        -- unlike the real function, never writes back to settings.
                        local saved = settings['selected_' .. group]
                        local saved_is_valid = false
                        if saved then
                            for _, name in ipairs(names) do
                                if name == saved then saved_is_valid = true break end
                            end
                        end
                        out[#out + 1] = combo('selected_' .. group, group .. ' tier',
                            saved_is_valid and saved or names[#names], names)
                    end
                end
            else
                out[#out + 1] = ability_row(settings, env, a.name, false, a)
            end
        end
    end
end

-- ============================================================================
-- Sections
-- ============================================================================

local function section_enabled(settings, key, default)
    local value = settings[key]
    if value == nil then value = default end
    return value and true or false
end

local function add_section(out, settings, label, key, default, controls)
    out[#out + 1] = {
        label = label,
        key = key,
        enabled = section_enabled(settings, key, default),
        controls = controls,
    }
end

-- 'None' plus every P1-P5 name, plus tracked targets when the dropdown offers
-- them. include_player puts the player's own name at the front, as
-- render_party_dropdown does -- it inserts common.get_party_member_name(0),
-- a real character name, never the literal string 'ME'. resolve_focus_target
-- matches settings.focus_target against real party names, so a literal 'ME'
-- would never match and a saved Focus Target would show as unselected.
-- When env.player_name is missing or empty (not yet supplied, or the name
-- read failed), omit the player entry entirely rather than falling back to
-- a placeholder that could falsely match a real party member later.
local function party_options(env, include_player, include_tracked)
    local options = { 'None' }
    if include_player and env.player_name and env.player_name ~= '' then
        options[#options + 1] = env.player_name
    end
    for _, name in ipairs(env.party_names or {}) do options[#options + 1] = name end
    if include_tracked then
        for _, name in ipairs(env.tracked_names or {}) do options[#options + 1] = name end
    end
    return options
end

local function has_non_self_heal(list)
    for _, a in ipairs(list or {}) do
        if not a.self_only then return true end
    end
    return false
end

--- Build the whole window as data.
function schema.build(job_def, settings, env)
    settings = settings or {}
    env = env or {}
    local abilities = (job_def and job_def.abilities) or {}
    local sections = {}

    -- Auto Follow -- hidden in Multisend mode, exactly as config.lua hides it.
    if not settings.multisend_follow then
        add_section(sections, settings, 'Auto Follow', 'follow_enabled', false, {
            combo('follow_target', 'Follow Target', settings.follow_target,
                party_options(env, false, true)),
            slider('follow_distance', 'Distance (yalms)', settings.follow_distance or 5, 1, 15),
        })
    end

    -- Pet Control -- gated on the ability lists, never on job_id, so a subjob
    -- PUP still gets maneuvers.
    local pet_control_list = abilities.pet_control
    local maneuver_list = abilities.maneuver
    local has_pet_control = any_usable(pet_control_list, env)
    local has_maneuver = any_usable(maneuver_list, env)
    if has_pet_control or has_maneuver then
        local controls = {}
        if has_pet_control then
            -- Labelled with the job's own ability name (Deploy / Assault / Fight).
            controls[#controls + 1] = check('pet_control_enabled', pet_control_list[1].name,
                settings.pet_control_enabled)
            controls[#controls + 1] = combo('pet_control_target', 'Target',
                settings.pet_control_target or '<t>', { '<t>', '<bt>' })
        end
        if has_maneuver then
            local names = { 'None' }
            for _, a in ipairs(maneuver_list) do
                if usable(job_def, a, env) then names[#names + 1] = a.name end
            end
            controls[#controls + 1] = check('maneuver_enabled', 'Maneuver',
                settings.maneuver_enabled ~= false)
            for slot = 1, 3 do
                local key = 'maneuver' .. slot .. '_name'
                controls[#controls + 1] = combo(key, 'Maneuver ' .. slot, settings[key], names)
            end
        end
        add_section(sections, settings, 'Pet Control', 'pet_enabled', true, controls)
    end

    -- Focus Healing
    if any_usable(abilities.heal, env) and has_non_self_heal(abilities.heal) then
        add_section(sections, settings, 'Focus Healing', 'focus_enabled', false, {
            combo('focus_target', 'Focus Target', settings.focus_target,
                party_options(env, true, true)),
            slider('focus_threshold', 'Focus (HP%)', settings.focus_threshold or 85, 1, 100),
        })
    end

    -- Group Healing (Critical HP lives inside it, as in the window)
    if any_usable(abilities.heal, env) then
        local controls = {
            slider('heal_threshold', 'Group (HP%)', settings.heal_threshold or 75, 1, 100),
        }
        -- Group Targets buttons only make sense when a heal can target someone
        -- else; hidden for a self-only heal set, same gate as Focus Healing.
        if has_non_self_heal(abilities.heal) then
            local slots = target_slots(nil, env)
            controls[#controls + 1] = { t = 'targets', name = 'heal_group', label = 'Group Targets',
                group = false, slots = slots, value = target_values(env, 'heal_group', slots, 'group_optout') }
        end
        emit_checks(controls, job_def, abilities.heal, settings, env)
        if any_usable(abilities.critical, env) then
            controls[#controls + 1] = slider('critical_threshold', 'Critical (HP%)',
                settings.critical_threshold or 30, 1, 50)
            emit_checks(controls, job_def, abilities.critical, settings, env)
        end
        add_section(sections, settings, 'Group Healing', 'heal_enabled', false, controls)
    end

    -- AOE Healing
    if any_usable(abilities.heal_aoe, env) then
        local controls = {
            slider('heal_aoe_threshold', 'AOE (HP%)', settings.heal_aoe_threshold or 70, 1, 100),
        }
        -- Unlike Group Healing, no non-self-heal gate: AOE heals always hit
        -- others, so config.lua draws this unconditionally.
        do
            local slots = target_slots(nil, env)
            controls[#controls + 1] = { t = 'targets', name = 'heal_aoe_group', label = 'AOE Targets',
                group = false, slots = slots, value = target_values(env, 'heal_aoe_group', slots, 'group_optout') }
        end
        emit_checks(controls, job_def, abilities.heal_aoe, settings, env)
        add_section(sections, settings, 'AOE Healing', 'heal_aoe_enabled', false, controls)
    end

    -- Pet Healing
    if any_usable(abilities.heal_pet, env) then
        local controls = {
            slider('heal_pet_threshold', 'Pet (HP%)', settings.heal_pet_threshold or 50, 1, 100),
        }
        emit_checks(controls, job_def, abilities.heal_pet, settings, env)
        add_section(sections, settings, 'Pet Healing', 'heal_pet_enabled', false, controls)
    end

    -- Sleep Removal -- hidden while solo: you cannot cure your own Sleep, so with
    -- no P1..P5 to scan the whole section is dead UI.
    local has_wake = false
    for _, a in ipairs(abilities.heal or {}) do
        if a.wakes and level_ok(a, env) then has_wake = true break end
    end
    if has_wake and (env.party_size or 1) > 1 then
        local slots = {}
        for i = 1, math.min((env.party_size or 1) - 1, 5) do slots[#slots + 1] = tostring(i) end
        add_section(sections, settings, 'Sleep Removal', 'wake_enabled', false, {
            { t = 'targets', name = 'wake', label = 'Sleep Targets', group = false,
              slots = slots, value = target_values(env, 'wake', slots, 'table_optin') },
        })
    end

    -- Debuff Removal
    if any_usable(abilities.debuff_removal, env) then
        local controls = {}
        emit_rows(controls, job_def, abilities.debuff_removal, settings, env)
        add_section(sections, settings, 'Debuff Removal', 'debuff_removal_enabled', false, controls)
    end

    -- Pet Debuff Removal
    if any_usable(abilities.pet_debuff_removal, env) then
        local controls = {}
        emit_checks(controls, job_def, abilities.pet_debuff_removal, settings, env)
        add_section(sections, settings, 'Pet Debuff Removal', 'pet_debuff_removal_enabled',
            false, controls)
    end

    -- Item Debuff Removal -- hidden until inventory reads, same as the window.
    if env.item_inventory_loaded then
        local controls = {}
        for _, entry in ipairs(env.item_removals or {}) do
            controls[#controls + 1] = check(entry.key, entry.label, entry.value)
        end
        add_section(sections, settings, 'Item Debuff Removal', 'item_removal_enabled',
            false, controls)
    end

    -- Resting (MP jobs only)
    if job_def and job_def.resource_type == 'mp' then
        add_section(sections, settings, 'Resting', 'rest_enabled', false, {
            slider('rest_timer', 'Timer (seconds)', settings.rest_timer or 5, 1, 20),
            slider('rest_distance', 'Distance (yalms)', settings.rest_distance or 7, 1, 15),
        })
    end

    -- Resource Recovery
    local has_tp = any_usable(abilities.recover_tp, env)
    local has_mp = any_usable(abilities.recover_mp, env)
    local has_party_mp = any_usable(abilities.recover_party_mp, env)
    if has_tp or has_mp or has_party_mp then
        local controls = {}
        if has_tp then
            controls[#controls + 1] = slider('recover_tp_threshold', 'Self Recover (TP)',
                settings.recover_tp_threshold or 500, 100, 3000)
            emit_checks(controls, job_def, abilities.recover_tp, settings, env)
        end
        if has_mp then
            controls[#controls + 1] = slider('recover_mp_threshold', 'Self Recover (MP%)',
                settings.recover_mp_threshold or 30, 1, 100)
            emit_checks(controls, job_def, abilities.recover_mp, settings, env)
            local has_min_tp = false
            for _, a in ipairs(abilities.recover_mp) do
                if usable(job_def, a, env) and a.min_tp ~= nil then has_min_tp = true break end
            end
            if has_min_tp then
                controls[#controls + 1] = slider('chivalry_min_tp', 'Chivalry Min TP',
                    settings.chivalry_min_tp or 3000, 0, 3000)
            end
        end
        if has_party_mp then
            -- Party-only: Devotion resolves by P1-P5 index in recover.lua, so
            -- tracked and alliance targets would never match.
            controls[#controls + 1] = combo('focus_recovery_target', 'Recovery Target',
                settings.focus_recovery_target, party_options(env, false, false))
            if settings.focus_recovery_target then
                controls[#controls + 1] = slider('focus_recovery_threshold',
                    'Target Recover (MP%)', settings.focus_recovery_threshold or 30, 1, 100)
            end
            emit_checks(controls, job_def, abilities.recover_party_mp, settings, env)
        end
        add_section(sections, settings, 'Resource Recovery', 'recover_enabled', false, controls)
    end

    -- Rolls (Corsair). Rolls unlock individually, so has_spell decides, not level.
    if any_usable(abilities.roll, env) then
        local names = { 'None' }
        for _, a in ipairs(abilities.roll) do
            if usable(job_def, a, env) and (not env.has_spell or env.has_spell(a)) then
                names[#names + 1] = a.name
            end
        end
        local controls = { combo('roll1_name', 'Roll 1', settings.roll1_name, names) }
        -- Corsair as a subjob keeps one roll up, so slot 2 does not exist there.
        local cor_is_sub = abilities.roll[1] and abilities.roll[1].is_main_job == false
        if not cor_is_sub then
            controls[#controls + 1] = combo('roll2_name', 'Roll 2', settings.roll2_name, names)
        end
        controls[#controls + 1] = combo('risk_tier', 'Risk Tier', settings.risk_tier or 'medium',
            { 'lowest', 'medium', 'highest' })
        add_section(sections, settings, 'Rolls', 'roll_enabled', true, controls)
    end

    -- Buffs
    if any_usable(abilities.buff, env) then
        local controls = {}
        emit_rows(controls, job_def, abilities.buff, settings, env)
        add_section(sections, settings, 'Buffs', 'buff_enabled', false, controls)
    end

    -- Geo
    if any_usable(abilities.geo, env) then
        local controls = {}
        emit_rows(controls, job_def, abilities.geo, settings, env,
            function(a) return a.group == 'Geo-bt' end)
        -- Full Circle: every ungrouped geo ability except Entrust and Blaze of
        -- Glory, which get their own placement below (mirrors config.lua's
        -- explicit exclusion of both names from this loop).
        emit_rows(controls, job_def, abilities.geo, settings, env,
            function(a) return a.group == nil and a.name ~= 'Entrust' and a.name ~= 'Blaze of Glory' end)
        controls[#controls + 1] = slider('geo_distance_threshold', 'Distance (yalms)',
            settings.geo_distance_threshold or 10, 7, 30)
        if job_def.job_id == 21 then
            controls[#controls + 1] = slider('geo_bt_timer', 'Timer (seconds)',
                settings.geo_bt_timer or 5, 1, 20)
        end
        -- Blaze of Glory is a precast for the NEXT Geo spell, not part of the
        -- Full Circle distance logic, so it renders after those sliders --
        -- job-independent (not gated on job_id == 21), same as config.lua.
        emit_rows(controls, job_def, abilities.geo, settings, env,
            function(a) return a.name == 'Blaze of Glory' end)
        if job_def.job_id == 21 then
            local indi = {}
            for _, a in ipairs(abilities.buff or {}) do
                if a.group == 'Indi' and usable(job_def, a, env)
                    and (not env.has_spell or env.has_spell(a)) then
                    indi[#indi + 1] = a.name
                end
            end
            if #indi > 0 then
                emit_rows(controls, job_def, abilities.geo, settings, env,
                    function(a) return a.name == 'Entrust' end)
                controls[#controls + 1] = combo('entrust_target', 'Entrust Target',
                    settings.entrust_target, party_options(env, false, false))
                table.insert(indi, 1, 'None')
                controls[#controls + 1] = combo('entrust_spell', 'Entrust Spell',
                    settings.entrust_spell, indi)
            end
        end
        add_section(sections, settings, 'Geo', 'geo_enabled', false, controls)
    end

    -- Revive
    if any_usable(abilities.revive, env) then
        local controls = {}
        emit_checks(controls, job_def, abilities.revive, settings, env)
        add_section(sections, settings, 'Revive', 'revive_enabled', false, controls)
    end

    -- ------------------------------------------------------------------
    -- Globals: the job-independent settings the in-game /sk panel owns.
    -- They are what the web app's gear panel draws, since it has no panel.
    -- ------------------------------------------------------------------
    local globals = {
        check('multisend_follow', 'Multisend Follow', settings.multisend_follow),
        check('hold_aoe_for_group', 'Hold AOE for Group', settings.hold_aoe_for_group),
        -- Pianissimo Fast Casting (BRD) and Cast with 1 Shadow (NIN): drawn
        -- unconditionally by the panel despite the job-specific comments, since
        -- it's a debug surface where a stable row beats one that reshuffles on
        -- job change. Persisted functional settings, so the gear panel owns them.
        check('pianissimo_fast_casting', 'Pianissimo Fast Casting', settings.pianissimo_fast_casting),
        check('cast_with_1_shadow', 'Cast with 1 Shadow', settings.cast_with_1_shadow),
        -- Potency/duration row, then AFK Sleep, then UI Opacity: panel.lua
        -- draws them in exactly this order (lines 488-562), not the order
        -- these settings were added to the addon.
        slider('cure_potency', 'Cure Potency +%', settings.cure_potency or 0, 0, 100),
        slider('waltz_potency', 'Waltz Potency +%', settings.waltz_potency or 0, 0, 100),
        -- Song Duration (BRD): 0 = memory-based recast (default), >0 = manual
        -- song timers. See lib/actions/buff.lua.
        slider('song_duration', 'Song Duration (s)', settings.song_duration or 0, 0, 999),
        check('afk_enabled', 'AFK Sleep', settings.afk_enabled ~= false),
        slider('afk_timeout', 'AFK Timeout (seconds)', settings.afk_timeout or 600, 60, 3600),
        slider('ui_opacity', 'UI Opacity', settings.ui_opacity or 100, 1, 100),
        check('load_stopped', 'Load stopped', settings.load_stopped),
        check('stop_after_zone', 'Stop after zone', settings.stop_after_zone),
        combo('display_mode', 'Section Display', settings.display_mode or 'headers',
            { 'headers', 'tabs' }),
    }
    -- Attack Range is only meaningful with Multisend follow on, which is the
    -- same condition config.lua draws it under.
    if settings.multisend_follow then
        table.insert(globals, 2, combo('attack_range', 'Attack Range',
            settings.attack_range or 'Off',
            { 'Off', 'Melee (3 yalms)', 'Ranged (15 yalms)' }))
    end

    return { sections = sections, globals = globals }
end

--- Flatten a built schema into the lookup lib/core/webui.lua validates against.
-- Section enable keys are folded in as synthetic checkboxes: they are ordinary
-- boolean settings, so the plain `set` verb covers them.
function schema.index(built)
    local idx = { set = {}, ability = {}, targets = {} }

    local function take(control)
        if control.t == 'check' or control.t == 'slider' or control.t == 'combo' then
            idx.set[control.key] = control
        elseif control.t == 'ability' then
            idx.ability[control.name] = { group = control.group }
        elseif control.t == 'targets' then
            local slots = {}
            for _, slot in ipairs(control.slots) do slots[slot] = true end
            idx.targets[control.name] = { group = control.group, slots = slots }
        end
    end

    for _, s in ipairs(built.sections) do
        idx.set[s.key] = { t = 'check', key = s.key, label = s.label, value = s.enabled }
        for _, control in ipairs(s.controls) do take(control) end
    end
    for _, control in ipairs(built.globals) do take(control) end

    return idx
end

return schema
