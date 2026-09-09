--[[
    Rune action module -- Rune Fencer rune upkeep.

    Runes (Ignis .. Tenebrae) are eight status effects sharing one 5-second
    recast (recastId 10); more than one stands at a time -- 1 rune at RUN 1, 2 at
    35, 3 at 65. Swipe and Lunge eat them all. Sidekick fires neither (they are
    damage); it only puts the runes back.

    Two kinds of row, both configured at the top of the UI's Buffs section --
    which is why buff_enabled gates the whole module. Idle Runes holds the slots
    normally; a rune-consuming JA row (Vallation 10, Valiance 50, Pflug 40) takes
    them over as soon as its own recast is ready, swaps in its own set, fires,
    and hands them back. Out of combat the row still claims the slots and puts its
    runes up -- the prep is free -- but the ability itself is held until
    is_combat(), so a 300s recast is never spent on nothing.

    Vallation and Valiance are mutually exclusive server-side: Vallation strips a
    standing Valiance (delStatusEffectSilent), and Valiance is a no-op on the
    caster while Vallation stands but spends its 300s recast anyway. Liement (537)
    no-ops both. Handled by blocked_by in the job file plus
    action_core.filter_self_buff_blocked below; see CHANGELOG 2.8.0 for the detail.

    The settings-key helpers are exported because lib/ui/config.lua draws the same
    rows and must agree on every key (as it already does with roll's reset_state).
]]--

local rune = {}

local common      = require('lib.core.common')
local action_core = require('lib.core.action_core')

-- ============================================================================
-- Level math and settings keys (shared with lib/ui/config.lua)
-- ============================================================================

-- Rune slots by RUN level. The count follows the RUN level itself, main or sub,
-- so a 37 subjob gets two and a 99 main gets three.
function rune.max_runes(level)
    level = level or 0
    if level >= 65 then return 3 end
    if level >= 35 then return 2 end
    return 1
end

-- The level governing this ability's rune count. merge_abilities stamps
-- is_main_job on every copy, so a subjob RUN reads the (capped) sub level.
function rune.run_level(ability, main_level, sub_level)
    if ability and ability.is_main_job == false then
        return sub_level or 0
    end
    return main_level or 0
end

-- Settings key prefix for a row: Vallation reads rune_vallation_*, the idle row
-- passes the literal 'idle'. Spaces to underscores, matching common.lua's
-- disabled_<name> convention. Parenthesized because gsub returns (string, count)
-- and the count would otherwise leak to the caller.
function rune.setting_prefix(ability)
    return (ability.name:lower():gsub(' ', '_'))
end

function rune.enable_key(prefix)
    return 'rune_' .. prefix .. '_enabled'
end

function rune.slot_key(prefix, index)
    return string.format('rune_%s_%d', prefix, index)
end

-- ============================================================================
-- Rune selection
-- ============================================================================

-- The runes a row wants, in slot order, capped at the level's rune count. An
-- unset slot is skipped, not treated as the end of the list -- slot 3 still
-- counts when slot 2 reads None. Duplicates are kept: the same rune twice means
-- "keep two up", which first_missing_stack understands.
function rune.desired_runes(settings, prefix, available, max_runes)
    local desired = {}
    for i = 1, max_runes do
        local name = settings[rune.slot_key(prefix, i)]
        if name then
            for _, ability in ipairs(available) do
                if ability.name == name then
                    table.insert(desired, ability)
                    break
                end
            end
        end
    end
    return desired
end

-- ============================================================================
-- Upkeep
-- ============================================================================

function rune.execute(settings, job_def, main_level, sub_level, player_resource)
    -- The rune rows live inside the UI's Buffs section, so its switch governs
    -- them. nil reads as disabled, matching buff.lua and ui.begin_section's
    -- default -- `== false` would run upkeep behind a closed section.
    if not settings.buff_enabled then
        return nil
    end

    -- 'rune' is deliberately absent from automation.lua's REST_BREAKING, so
    -- nothing clears common.is_resting() for us: firing here would stand the
    -- player up mid-rest and stall MP recovery until they moved.
    if common.is_resting() then
        return nil
    end

    local abilities = job_def and job_def.abilities
    if not abilities or not abilities.rune then
        return nil
    end

    local available = common.filter_abilities_by_level(abilities.rune, settings, main_level, sub_level, job_def)
    if #available == 0 then
        return nil
    end

    -- available[1] is arbitrary post-sort, but is_main_job is uniform across the
    -- category (RUN can't be main and sub at once), so any element will do.
    local max_runes = rune.max_runes(rune.run_level(available[1], main_level, sub_level))
    local player_buffs = (common.game_state.player or {}).buffs or {}

    -- Rune-consuming JAs first, in job-file order (Vallation, Valiance, Pflug).
    -- is_ability_recast_zero, NOT is_usable: this only decides whether the row
    -- takes the slots over, and is_usable's post-recast delay is consuming --
    -- asking with it here would leave the try_use below nothing to consume and
    -- the JA would never fire.
    local ja_list = common.filter_abilities_by_level(abilities.rune_ja or {}, settings, main_level, sub_level, job_def)
    -- try_use does not check blocked_by, so every caller filters explicitly
    -- first (same as pet.lua's Overload handling). Runes carry no blocked_by,
    -- so `available` is untouched.
    ja_list = action_core.filter_self_buff_blocked(ja_list, player_buffs)
    for _, ja in ipairs(ja_list) do
        local prefix = rune.setting_prefix(ja)
        if settings[rune.enable_key(prefix)] ~= false
            and action_core.is_ability_recast_zero(ja.recast_id) then
            local desired = rune.desired_runes(settings, prefix, available, max_runes)
            -- A row with no runes picked claims nothing: fall through.
            if #desired > 0 then
                local missing = action_core.first_missing_stack(desired, player_buffs)
                if missing then
                    -- One rune per tick; try_use covers the shared recast-10
                    -- timer and the Amnesia block on /ja.
                    return action_core.try_use(missing, job_def, settings, nil,
                        string.format('%s: %s', ja.name, missing.name))
                end
                -- Runes are prepped in or out of combat; the JA only fires in
                -- combat. Out of combat the row keeps the slots -- return
                -- rather than fall through, or idle upkeep would swap its set
                -- straight back out.
                if not common.is_combat() then
                    return nil
                end
                return action_core.try_use(ja, job_def, settings, nil, ja.name)
            end
        end
    end

    -- Idle upkeep: whatever the player wants standing the rest of the time.
    if settings[rune.enable_key('idle')] == false then
        return nil
    end

    local desired = rune.desired_runes(settings, 'idle', available, max_runes)
    if #desired == 0 then
        return nil
    end

    local missing = action_core.first_missing_stack(desired, player_buffs)
    if not missing then
        return nil
    end

    return action_core.try_use(missing, job_def, settings, nil, 'Rune: ' .. missing.name)
end

return rune
