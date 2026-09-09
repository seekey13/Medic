--[[
    Pet action module -- everything that automates a controllable pet
    (Puppetmaster automaton / Summoner avatar / Beastmaster jug pet):

      * Maneuver upkeep (PUP only): keeps up to 3 configured elemental
        maneuvers applied to the player (the automaton reads them off the
        player, same as retail), stacking duplicates when the same element is
        picked in more than one slot.
      * Send pet at target (PUP Deploy / SMN Assault / BST Fight -- the UI labels
        it with whichever ability the job has): sends the pet at a mob whenever the
        pet is not already engaged (read off the pet entity's Status). Which mob
        comes from pet_control_target: '<t>' (default)
        is the player's cursor target and only fires while engaged; '<bt>' is the
        battle target and needs no engaged check. Opt-in (pet_control_enabled, off
        by default). Shared across all three jobs; each supplies its own
        single-entry abilities.pet_control list (name/recast_id/command differ per
        job). execute_deploy() always reads pet_control[1] -- with two pet-control
        jobs main+sub, the main job's entry wins (BST/SMN with Carbuncle out still
        tries Fight, not Assault).

    Maneuver upkeep has no combat gate; send-pet-at-target does -- a real
    behavioral difference, not an oversight. Both sit under the UI's "Pet Control"
    section and its `pet_enabled` master switch, and both are held off entirely
    while the player has Invisible up (common.INVISIBLE_BUFF).

    Spec: docs/superpowers/specs/2026-08-08-pup-maneuver-deploy-design.md
    Spec: docs/superpowers/specs/2026-08-08-pet-deploy-smn-bst-design.md
]]--

local pet = {}

local common      = require('lib.core.common')
local action_core = require('lib.core.action_core')

-- Both maneuvers and the send-pet-at-target abilities go out as /pet, which drops
-- Invisible -- so neither fires while it's up. Travel wins over upkeep: the
-- maneuvers come back on their own once Invisible is down, a blown Invisible in a
-- mob-heavy zone does not.
local function is_invisible()
    local buffs = (common.game_state.player or {}).buffs or {}
    return action_core.has_any_buff(buffs, common.INVISIBLE_BUFF)
end

-- ============================================================================
-- Maneuver upkeep
-- ============================================================================

function pet.execute_maneuver(settings, job_def, main_level, sub_level, player_resource)
    -- pet_enabled is the UI's "Pet" section master switch, over both features here
    if not settings.pet_enabled or not settings.maneuver_enabled then
        return nil
    end

    -- Do not apply maneuvers while resting
    if common.is_resting() then
        return nil
    end

    -- Do not break Invisible for upkeep
    if is_invisible() then
        return nil
    end

    if not job_def or not job_def.abilities or not job_def.abilities.maneuver then
        return nil
    end

    if not common.targets.get_pet() then
        return nil
    end

    local player_buffs = common.game_state.player.buffs or {}

    -- Level/disabled filter, then drop anything Overload (299) is blocking --
    -- try_use does not check blocked_by on its own, so every caller with a
    -- blocked_by ability filters it explicitly first (same as
    -- heal.lua/status_removal.lua).
    local available = common.filter_abilities_by_level(job_def.abilities.maneuver, settings, main_level, sub_level, job_def)
    available = action_core.filter_self_buff_blocked(available, player_buffs)
    if #available == 0 then
        return nil
    end

    local function find_maneuver(name)
        if not name then return nil end
        for _, ability in ipairs(available) do
            if ability.name == name then
                return ability
            end
        end
        return nil
    end

    -- Desired list in slot order. Not deduped -- the same element picked twice
    -- means "keep two stacks up", which action_core.first_missing_stack understands via count_instances.
    local desired = {}
    for _, key in ipairs({ 'maneuver1_name', 'maneuver2_name', 'maneuver3_name' }) do
        local ability = find_maneuver(settings[key])
        if ability then
            table.insert(desired, ability)
        end
    end
    if #desired == 0 then
        return nil
    end

    -- Slot order, duplicates included: picking Fire in two slots asks for a
    -- second stack once the first is up (action_core.first_missing_stack).
    local missing = action_core.first_missing_stack(desired, player_buffs)
    if not missing then
        return nil
    end

    -- One attempt per tick, not a burst -- try_use covers the recast-210 shared
    -- cooldown, the movement block, and Amnesia (is_command_blocked treats /pet
    -- as a job ability, which is what a maneuver is server-side).
    return action_core.try_use(missing, job_def, settings, nil, 'Maneuver: ' .. missing.name)
end

-- ============================================================================
-- Automaton/avatar/pet Deploy
-- ============================================================================

-- True when the pet is already fighting, so deploy must not re-send it. Status
-- (1 = engaged) is the same field is_engaged() reads off the player. Note there
-- is no client-side field naming what another entity targets -- an entity's
-- TargetIndex is its OWN slot, which is why an earlier version reading it never
-- saw the pet as busy.
local function pet_is_engaged(pet_entity)
    local ok, status = pcall(function() return pet_entity.Status end)
    return ok and tonumber(status) == 1
end

function pet.execute_deploy(settings, job_def, main_level, sub_level, player_resource)
    if not settings.pet_enabled or not settings.pet_control_enabled then
        return nil
    end

    if not job_def or not job_def.abilities or not job_def.abilities.pet_control then
        return nil
    end

    -- Do not break Invisible to send the pet in. Matters most on the '<bt>' path,
    -- which has no engaged check and would otherwise fire while sneaking past a
    -- camp toward a party fight.
    if is_invisible() then
        return nil
    end

    local pet_entity = common.targets.get_pet()
    if not pet_entity then
        return nil
    end

    if pet_is_engaged(pet_entity) then
        return nil
    end

    -- Which target the pet gets sent at, picked in the UI dropdown next to the
    -- toggle. '<bt>' fires off the battle target alone (the pet joins whatever
    -- the party is already fighting, player need not be engaged); '<t>' only
    -- fires while the player is engaged, so a passing cursor hover can't send
    -- the pet at something nobody is fighting.
    local use_bt = settings.pet_control_target == '<bt>'
    if not use_bt and not common.is_engaged() then
        return nil
    end

    -- pcall: get_bt is a raw ffi call, same guard common.is_combat() uses.
    local ok, target = pcall(use_bt and common.targets.get_bt or common.targets.get_t)
    if not ok or not target or (target.HPPercent or 0) <= 0 then
        return nil
    end

    -- Only send the pet at an actual mob -- same SpawnFlags 0x10 check
    -- common.is_combat() uses -- so a party member the player happened to have
    -- targeted can't be Deployed at.
    local is_mob = bit.band(target.SpawnFlags or 0, 0x10) ~= 0
    if not is_mob then
        return nil
    end

    local ability = job_def.abilities.pet_control[1]
    if not ability then
        return nil
    end

    -- Jobs store the command with <t>; retarget it here rather than carrying two
    -- near-identical entries per job.
    local result = action_core.try_use(ability, job_def, settings, nil, ability.name)
    if result and use_bt then
        result.command = result.command:gsub('<t>', '<bt>')
    end
    return result
end

return pet
