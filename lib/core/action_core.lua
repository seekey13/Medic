--[[
    Action core: shared ability infrastructure.
    Combines resource management (MP/TP checking, cooldown tracking),
    buff-ID utilities, and ability candidacy/execution helpers into a
    single module used by every action module.
]]--

local action_core = {}

local common     = require('lib.core.common')
local AshitaCore = AshitaCore

-- ============================================================================
-- Resource Management  (formerly lib.core.resource)
-- ============================================================================

-- Post-recast delay tracking (when recast hits 0, track when it became ready)
local recast_ready_time = {}
local POST_RECAST_DELAY = 0.5  -- 0.5 second delay after recast hits 0

-- Helper: check if recast timer is ready with post-delay
local function is_recast_ready_with_delay(key, timer)
    if timer == 0 then
        if not recast_ready_time[key] then
            recast_ready_time[key] = os.clock()
            return false
        end
        local elapsed = os.clock() - recast_ready_time[key]
        if elapsed >= POST_RECAST_DELAY then
            recast_ready_time[key] = nil
            return true
        end
        return false
    else
        recast_ready_time[key] = nil
        return false
    end
end

-- Check if player has enough MP or TP.
function action_core.has_resource(resource_type, amount)
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return false end
    if resource_type == 'mp' then
        return party:GetMemberMP(0) >= amount
    elseif resource_type == 'tp' then
        return party:GetMemberTP(0) >= amount
    end
    return false
end

-- Get current MP or TP value.
function action_core.get_resource(resource_type)
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return 0 end
    if resource_type == 'mp' then return party:GetMemberMP(0) end
    if resource_type == 'tp' then return party:GetMemberTP(0) end
    return 0
end

-- Check if a job ability (by timer ID) is off cooldown.
function action_core.is_ability_ready(ability_id)
    if not ability_id then return true end
    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then return false end
    for i = 0, 31 do
        local ok_id, timer_id = pcall(function() return recast_mgr:GetAbilityTimerId(i) end)
        if ok_id and timer_id == ability_id then
            local ok_timer, timer = pcall(function() return recast_mgr:GetAbilityTimer(i) end)
            if not ok_timer then return false end
            return is_recast_ready_with_delay('ability_' .. ability_id, timer)
        end
    end
    return true
end

--[[
    Read-only variant of is_ability_ready: true when the timer reads zero, with none
    of the POST_RECAST_DELAY bookkeeping.

    is_ability_ready is a CONSUMING check -- it arms a timestamp on the first call
    that sees a zero timer and clears it on the call that finally returns true, so
    two calls in the same tick disagree by design. Callers that need to know whether
    an ability is available WITHOUT trying to use it (deciding between two plans,
    reporting state) must use this instead; the real cast still goes through
    is_usable/try_use, which applies the delay.
]]--
function action_core.is_ability_recast_zero(recast_id)
    if not recast_id then return true end
    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then return false end
    for i = 0, 31 do
        local ok_id, timer_id = pcall(function() return recast_mgr:GetAbilityTimerId(i) end)
        if ok_id and timer_id == recast_id then
            local ok_timer, timer = pcall(function() return recast_mgr:GetAbilityTimer(i) end)
            return ok_timer and timer == 0
        end
    end
    return true  -- Not in the timer list at all = never started = ready
end

-- Check if a spell (by recast ID) is off cooldown.
function action_core.is_spell_ready(spell_recast_id)
    if not spell_recast_id then return true end
    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then return false end
    local recast_time = recast_mgr:GetSpellTimer(spell_recast_id)
    return is_recast_ready_with_delay('spell_' .. spell_recast_id, recast_time)
end

-- Get raw spell recast timer value.
function action_core.get_spell_recast(spell_recast_id)
    if not spell_recast_id then return 0 end
    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then return 0 end
    return recast_mgr:GetSpellTimer(spell_recast_id)
end

-- ============================================================================
-- Buff-ID Utilities  (formerly lib.core.buff_utils)
-- ============================================================================

-- Normalize a buff_id value (single number or table) to a flat table of IDs.
function action_core.normalize_ids(ids)
    if ids == nil then return {} end
    return type(ids) == 'table' and ids or {ids}
end

-- Check if any ID in `active_buffs` matches any ID in `check_ids`.
function action_core.has_any_buff(active_buffs, check_ids)
    local ids = action_core.normalize_ids(check_ids)
    for _, active in ipairs(active_buffs or {}) do
        for _, check in ipairs(ids) do
            if active == check then return true end
        end
    end
    return false
end

-- Count active instances of any id in check_ids -- buffs that share an id across
-- tiers (Ballad/Ballad II) or stack from repeated application (PUP maneuvers)
-- need "how many", not just "has it".
function action_core.count_instances(active_buffs, check_ids)
    local ids = action_core.normalize_ids(check_ids)
    local n = 0
    for _, active in ipairs(active_buffs or {}) do
        for _, check in ipairs(ids) do
            if active == check then n = n + 1; break end
        end
    end
    return n
end

-- First entry in `desired` (in list order) not yet covered by an active buff of
-- the same id, counting duplicates -- so the same buff listed twice correctly
-- asks for a second copy once the first is up. Returns nil once every entry, at
-- its requested multiplicity, is satisfied. Shared by the two upkeep loops that
-- keep a fixed set of self-buffs standing: PUP maneuvers and RUN runes.
function action_core.first_missing_stack(desired, active_buffs)
    local satisfied = {}
    for _, ability in ipairs(desired) do
        local id = ability.buff_id
        local have = action_core.count_instances(active_buffs, id)
        satisfied[id] = satisfied[id] or 0
        if satisfied[id] < have then
            satisfied[id] = satisfied[id] + 1
        else
            return ability
        end
    end
    return nil
end

-- Inverse of has_any_buff: true when the target is MISSING the buff.
-- When check_ids is nil (no tracking), always returns true (treat as always needed).
function action_core.needs_buff(active_buffs, check_ids)
    if check_ids == nil then return true end
    return not action_core.has_any_buff(active_buffs, check_ids)
end

-- True when the player holds a buff that blocks this ability. `blocked_by` names
-- the blocking buff id(s); distinct from buff_id (the buff the ability grants).
-- DNC: Saber Dance (410) blocks Waltzes; Fan Dance (411) blocks Sambas.
function action_core.is_self_blocked(ability, player_buffs)
    return ability.blocked_by ~= nil and action_core.has_any_buff(player_buffs, ability.blocked_by)
end

-- Drop abilities the player currently can't use because a self-buff blocks them
-- (see is_self_blocked). Abilities with no blocked_by pass through unchanged.
function action_core.filter_self_buff_blocked(abilities, player_buffs)
    if not player_buffs then return abilities end
    local out = {}
    for _, a in ipairs(abilities) do
        if not action_core.is_self_blocked(a, player_buffs) then
            table.insert(out, a)
        end
    end
    return out
end

-- ============================================================================
-- Ability Candidacy Helpers
-- ============================================================================

--[[
    Check whether a single ability is currently usable.
    Evaluates in order: status-blocked → resource → cooldown.
    Args:
      ability       – ability definition table
      job_def       – job definition table
      cost_override – optional number to replace ability.cost for the resource check
                      (used for stratagem-adjusted MP costs)
    Returns: is_ready (bool), reason (string or nil)
]]--
function action_core.is_usable(ability, job_def, cost_override)
    -- 1. Blocked by a status ailment?
    local blocked_by = common.is_command_blocked(ability.command)
    if blocked_by then
        return false, 'blocked by ' .. blocked_by
    end

    -- 2. Enough resource?
    local res_type = ability.resource_type or job_def.resource_type
    local effective_cost = cost_override or ability.cost
    if not action_core.has_resource(res_type, effective_cost) then
        return false, 'insufficient ' .. res_type
    end

    -- 3. Off cooldown? The field name selects the timer: spell_id (/ma) reads the
    -- spell recast table, recast_id (/ja and friends) the ability recast table.
    if ability.spell_id then
        if not action_core.is_spell_ready(ability.spell_id) then
            local secs = action_core.get_spell_recast(ability.spell_id) / 60.0
            return false, string.format('spell cooldown (%.1fs)', secs)
        end
    elseif ability.recast_id then
        if not action_core.is_ability_ready(ability.recast_id) then
            return false, 'ability cooldown'
        end
    end

    return true, nil
end

--[[
    Filter a list of abilities down to those that pass is_usable.
    Logs skipped abilities at debug level when tag is provided.
    When settings is provided, stratagem MP modifiers are applied to the
    resource check so that Penury/Parsimony-discounted spells pass through
    and Accession-inflated spells are correctly gated.
    Returns a new table of usable abilities (preserves original order).
]]--
function action_core.filter_usable(abilities, job_def, tag, settings)
    local usable = {}
    for _, ability in ipairs(abilities) do
        local eff_cost = settings and common.effective_ability_cost(ability, settings, job_def) or nil
        local ok, reason = action_core.is_usable(ability, job_def, eff_cost)
        if ok then
            table.insert(usable, ability)
        end
    end
    return usable
end

--[[
    Find the first usable ability, build its command, and return an action
    result table  { command, description }.  Returns nil if nothing is usable.

    abilities      – already level/settings-filtered ability list
    job_def        – job definition table (for resource_type fallback)
    settings       – settings table
    tag            – debug prefix string, e.g. '[HEAL_AOE]'
    party_index    – nil for AOE/self-targeted abilities, number for party member
    description_fn – function(ability) → string  (optional; falls back to ability.name)
]]--
function action_core.first_command(abilities, job_def, settings, tag, party_index, description_fn)
    for _, ability in ipairs(abilities) do
        local eff_cost = settings and common.effective_ability_cost(ability, settings, job_def) or nil
        local ok, reason = action_core.is_usable(ability, job_def, eff_cost)
        if ok then
            -- Check stratagems before casting
            if settings then
                local strat_result = common.check_stratagem(job_def, settings, ability.name, ability)
                if strat_result == false then
                    goto continue_first_cmd
                elseif strat_result then
                    return strat_result
                end
            end
            local command = common.build_ability_command(ability, party_index)
            if command then
                return {
                    command     = command,
                    description = description_fn and description_fn(ability) or ability.name,
                }
            end
        end
        ::continue_first_cmd::
    end
    return nil
end

--[[
    Try to use a single ability on a specific target.
    Combines is_usable + build_ability_command + optional Trust buff registration.
    Returns: {command, description} or nil, reason
]]--
function action_core.try_use(ability, job_def, settings, party_index, description, game_state)
    -- Check usability first (with stratagem-adjusted cost) to avoid wasting charges
    local eff_cost = settings and common.effective_ability_cost(ability, settings, job_def) or nil
    local ok, reason = action_core.is_usable(ability, job_def, eff_cost)
    if not ok then return nil, reason end

    -- Only fire stratagems after confirming the spell is castable
    if settings then
        local strat_result = common.check_stratagem(job_def, settings, ability.name, ability)
        if strat_result == false then
            return nil, 'stratagem unavailable'
        elseif strat_result then
            return strat_result
        end
    end

    local command = common.build_ability_command(ability, party_index)
    if not command then return nil, 'failed to build command' end

    -- Register pending Trust buff if applicable
    if ability.buff_id and party_index and party_index > 0 and game_state then
        local member = game_state.party[party_index]
        local sid = member and member.server_id
        if sid and sid >= 0x1000000 then
            local bid = type(ability.buff_id) == 'table' and ability.buff_id[1] or ability.buff_id
            common.register_pending_buff(sid, bid, ability.name, ability.spell_id)
        end
    end

    return { command = command, description = description or ability.name }
end

return action_core
