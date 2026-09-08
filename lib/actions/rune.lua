--[[
    Rune action module -- Rune Fencer rune upkeep.

    Runes (Ignis .. Tenebrae) are eight separate status effects sharing one
    5-second recast (abilities.sql recastId 10), and more than one stands at a
    time: 1 rune at RUN 1, 2 at 35, 3 at 65. Swipe and Lunge eat every rune the
    player is holding. Sidekick fires neither -- they are damage, and this addon
    does not automate damage -- but it does put the runes back afterwards, which
    is the whole job of this module.

    Two kinds of row feed it, both configured at the top of the UI's Buffs
    section (which is why buff_enabled gates the whole module):

      * Idle Runes -- the set to keep standing when nothing else wants the slots.
      * One row per rune-consuming JA (Vallation 10, Valiance 50, Pflug 40), each
        with its own set. A JA row wins over Idle Runes as soon as its own recast
        is ready: the runes are swapped over to that row's set and then the JA
        fires. Once it has fired the recast is running again and Idle Runes takes
        the slots back. The JAs are combat_only in the job file, so out of combat
        no row competes with Idle at all.

    Rune names are unhelpful at a glance, so neither this module nor the UI ever
    asks the user for one: a row picks by the field it cares about -- the element
    the rune adds (Idle), the element it resists (Vallation/Valiance), or the
    ailments it defends against (Pflug). Settings still store the rune's name, so
    relabelling a display string never rewrites anybody's config.

    The settings-key helpers below are exported rather than kept local because
    lib/ui/config.lua draws the same rows and must agree on every key -- the same
    reason it already requires lib/actions/roll for reset_state.
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

-- Settings key prefix for a row. JA rows use their own lowercased name, so
-- Vallation reads rune_vallation_*; the idle row passes the literal 'idle'.
function rune.setting_prefix(ability)
    return ability.name:lower()
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
-- unset slot, or one naming a rune the player can no longer use, is skipped
-- rather than ending the list -- slot 3 still counts when slot 2 reads None.
-- Duplicates are kept: the same rune in two slots means "keep two up", which
-- action_core.first_missing_stack understands.
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
    -- The rune rows live inside the UI's Buffs section, so its master switch
    -- governs them too: turning Buffs off must not leave upkeep firing JAs with
    -- no visible config left to stop it with.
    if settings.buff_enabled == false then
        return nil
    end

    -- Upkeep only, not urgent: hold while resting. 'rune' is deliberately
    -- absent from automation.lua's REST_BREAKING, so nothing else clears
    -- common.is_resting() on our behalf -- firing here would stand the
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

    -- available[1] is arbitrary post-sort, but is_main_job is uniform across
    -- the whole rune category -- RUN can't be main and sub at once -- so
    -- reading it off any one element here is safe.
    local max_runes = rune.max_runes(rune.run_level(available[1], main_level, sub_level))
    local player_buffs = (common.game_state.player or {}).buffs or {}

    -- Rune-consuming JAs first, in job-file order (Vallation, Valiance, Pflug).
    -- is_ability_recast_zero, NOT is_usable: this only decides whether the row
    -- takes the slots over. is_usable's post-recast delay is consuming -- it arms
    -- a timestamp on the first zero-timer call and clears it on the call that
    -- returns true -- so asking with it here would leave the try_use below with
    -- nothing to consume and the JA would never fire.
    local ja_list = common.filter_abilities_by_level(abilities.rune_ja or {}, settings, main_level, sub_level, job_def)
    for _, ja in ipairs(ja_list) do
        local prefix = rune.setting_prefix(ja)
        if settings[rune.enable_key(prefix)] ~= false
            and action_core.is_ability_recast_zero(ja.recast_id) then
            local desired = rune.desired_runes(settings, prefix, available, max_runes)
            -- A row with no runes picked is not a claim on the slots: fall
            -- through to the next JA row, and then to Idle.
            if #desired > 0 then
                local missing = action_core.first_missing_stack(desired, player_buffs)
                if missing then
                    -- One rune per tick, not a burst -- try_use covers the shared
                    -- recast-10 timer and the Amnesia block on /ja.
                    return action_core.try_use(missing, job_def, settings, nil,
                        string.format('%s: %s', ja.name, missing.name))
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
