--[[
    Roll action module (Corsair)

    Maintains two configured Phantom Rolls and Double-Ups each one according to the
    configured risk tier (settings.risk_tier). Roll totals are not readable from
    memory, so they come from the 0x028 action packet (see roll.handle_action_packet
    at the bottom of this file).

    The Double-Up / Snake Eye / Fold decision math lives in lib/core/roll_strategy.lua
    (pure, self-testable); this module owns everything stateful around it -- packet
    totals, buff reads, throttles and command construction.

    Deliberately NOT gated on being engaged -- rolls fire out of combat too.
]]--

local roll = {}

local common        = require('lib.core.common')
local action_core   = require('lib.core.action_core')
local roll_strategy = require('lib.core.roll_strategy')

-- Buff ids (status_effects.sql)
local BUST_BUFF_ID      = 309  -- Bust: costs you a roll slot until it wears
local DOUBLE_UP_BUFF_ID = 308  -- Double-Up Chance: the window in which Double-Up is usable

-- Action-packet message ids (src/map/enums/msg_basic.h)
local MSG_ROLL_MAIN       = 420
local MSG_ROLL_SUB        = 421
local MSG_DOUBLEUP        = 424
local MSG_DOUBLEUP_BUST   = 426
local MSG_DOUBLEUP_BUST_S = 427

-- Module-level state (transient, cleared on reload)
local roll_state = {
    roll1 = {
        total = 0,
        last_action_time = 0,
        expecting_double_up = false,
        snake_eye_armed = false,  -- Snake Eye cast, next Double-Up die is forced to 1
    },
    roll2 = {
        total = 0,
        last_action_time = 0,
        expecting_double_up = false,
        snake_eye_armed = false,
    },
    last_double_up_time = 0,  -- Global double-up cooldown
}

-- Throttle for the Snake Eye / Fold availability debug line (see roll.execute)
local last_control_log = 0

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Find a roll ability by name in a roll list (raw job list, or a level-filtered one)
local function find_roll_ability(roll_list, roll_name)
    if not roll_list or not roll_name or roll_name == '' then return nil end
    for _, ability in ipairs(roll_list) do
        if ability.name == roll_name then
            return ability
        end
    end
    return nil
end

-- Roll slots available right now: Bust eats one of the two.
local function get_available_roll_slots(player_buffs)
    return action_core.has_any_buff(player_buffs, BUST_BUFF_ID) and 1 or 2
end

-- Count how many of the configured rolls are currently active on the player
local function count_active_configured_rolls(player_buffs, roll1_ability, roll2_ability)
    local count = 0
    if roll1_ability and action_core.has_any_buff(player_buffs, roll1_ability.buff_id) then
        count = count + 1
    end
    if roll2_ability and action_core.has_any_buff(player_buffs, roll2_ability.buff_id) then
        count = count + 1
    end
    return count
end

-- What should we do with this roll right now?
-- Returns 'stop' | 'double' | 'snake_eye_then_double'. Everything that isn't a live,
-- doubleable roll (no buff, outside the Double-Up window, total not yet known) is
-- 'stop'; the actual risk call is roll_strategy's.
local function roll_decision(settings, roll_num, roll_ability, player_buffs, snake_eye_ready, fold_ready)
    if not roll_ability then
        return 'stop'
    end

    local state = roll_num == 1 and roll_state.roll1 or roll_state.roll2

    -- Must be inside the Double-Up window
    if not action_core.has_any_buff(player_buffs, DOUBLE_UP_BUFF_ID) then
        common.debugf('[ROLL] Roll%d: no Double-Up buff (%d)', roll_num, DOUBLE_UP_BUFF_ID)
        return 'stop'
    end

    -- Must have the roll buff active
    if not action_core.has_any_buff(player_buffs, roll_ability.buff_id) then
        common.debugf('[ROLL] Roll%d: no roll buff (%d)', roll_num, roll_ability.buff_id)
        return 'stop'
    end

    -- Must have a valid total (from packet)
    if state.total == 0 then
        common.debugf('[ROLL] Roll%d: total is 0, waiting for packet', roll_num)
        return 'stop'
    end

    -- Snake Eye already spent on this slot: its recast now reads busy, so the armed
    -- flag -- not snake_eye_ready -- is what says "the forced die is waiting".
    if state.snake_eye_armed then
        common.debugf('[ROLL] Roll%d: Snake Eye armed, doubling into the forced 1', roll_num)
        return 'double'
    end

    local tier = settings.risk_tier or 'medium'
    local decision = roll_strategy.decide(state.total, roll_ability.lucky, roll_ability.unlucky,
        tier, snake_eye_ready, fold_ready)

    common.debugf('[ROLL] Roll%d (%s): total=%d lucky=%d unlucky=%d tier=%s se=%s fold=%s -> %s',
        roll_num, roll_ability.name, state.total, roll_ability.lucky or 0, roll_ability.unlucky or 0,
        tier, tostring(snake_eye_ready), tostring(fold_ready), decision)

    return decision
end

-- ============================================================================
-- Main Execute Function
-- ============================================================================

function roll.execute(settings, job_def, main_level, sub_level, player_resource)
    if not settings.roll_enabled then
        return nil
    end

    if not job_def or not job_def.abilities or not job_def.abilities.roll then
        return nil
    end

    local player_buffs = common.game_state.player.buffs or {}
    local current_time = os.clock()

    -- Level filter here (not in the packet handler): a saved roll name the player
    -- can no longer use must never be cast, but its packets still decode fine.
    local available = common.filter_abilities_by_level(job_def.abilities.roll, settings, main_level, sub_level, job_def)
    local roll1_ability = find_roll_ability(available, settings.roll1_name)
    local roll2_ability = find_roll_ability(available, settings.roll2_name)

    -- Corsair as a subjob can only maintain one roll -- drop slot 2 outright rather
    -- than trusting the saved setting (settings files predate this rule).
    if roll2_ability and roll2_ability.is_main_job == false then
        roll2_ability = nil
    end

    -- Same roll in both slots is one buff, not two: left in place it counts twice
    -- against the slot capacity below and wedges slot 2 shut forever.
    if roll2_ability == roll1_ability then
        roll2_ability = nil
    end

    -- Snake Eye / Fold are merits, looked up by fixed name (not user-configurable).
    -- filter_abilities_by_level applies the merit/level/main-job gates that the
    -- recast check below doesn't.
    local controls   = common.filter_abilities_by_level(job_def.abilities.roll_control, settings, main_level, sub_level, job_def)
    local snake_eye  = find_roll_ability(controls, 'Snake Eye')
    local fold       = find_roll_ability(controls, 'Fold')

    -- Readiness feeds a DECISION, so it must be probed read-only: action_core's
    -- is_usable consumes the post-recast delay it tracks, and try_use calls it again
    -- when actually casting -- that second call re-arms the delay and returns false,
    -- so a Fold gated on is_usable could never fire. is_ability_recast_zero has no
    -- such bookkeeping; try_use still owns the real gate at cast time.
    local function control_ready(ability)
        if not ability then return false, 'not learned/level/main job' end
        local blocked = common.is_command_blocked(ability.command)
        if blocked then return false, blocked end
        if not action_core.is_ability_recast_zero(ability.recast_id) then
            return false, 'cooldown'
        end
        return true, nil
    end

    local snake_eye_ready, snake_eye_why = control_ready(snake_eye)
    local fold_ready, fold_why           = control_ready(fold)

    local has_bust = action_core.has_any_buff(player_buffs, BUST_BUFF_ID)

    -- Repeats are collapsed by debugf itself; this only keeps the per-frame string
    -- formatting off the tick loop.
    if (current_time - last_control_log) >= 2 then
        last_control_log = current_time
        common.debugf('[ROLL] controls: bust=%s | Snake Eye %s (%s) | Fold %s (%s)',
            tostring(has_bust),
            snake_eye and 'found' or 'MISSING', snake_eye_ready and 'ready' or tostring(snake_eye_why),
            fold and 'found' or 'MISSING', fold_ready and 'ready' or tostring(fold_why))
    end

    -- Priority 1: Fold a Bust, whatever the tier. That frees the slot so Priority 3
    -- recasts a fresh roll into it next tick and the chase starts over.
    if roll_strategy.should_fold(has_bust, fold_ready) then
        local result = action_core.try_use(fold, job_def, settings, nil, 'Fold: clear Bust')
        if result then
            return result
        end
    end

    -- Priority 2: Double-Up a live roll (Roll1 first, then Roll2)
    for roll_num = 1, 2 do
        -- Explicit on both arms: `n == 1 and roll1 or roll2` would fall through to
        -- Roll2 when only Roll2 is configured, and evaluate it as Roll1.
        local roll_ability = (roll_num == 1) and roll1_ability or (roll_num == 2) and roll2_ability or nil
        local state = roll_num == 1 and roll_state.roll1 or roll_state.roll2
        local decision = roll_decision(settings, roll_num, roll_ability, player_buffs, snake_eye_ready, fold_ready)

        -- Done chasing this one: stop holding up the other slot's cast. Only once a
        -- total is known -- a freshly cast roll sits at 0 awaiting its packet.
        if decision == 'stop' and state.total > 0 then
            state.expecting_double_up = false
        end

        if decision == 'snake_eye_then_double' then
            -- Cast now, double next tick: the die is forced server-side, so the only
            -- thing to remember is that we already paid for it.
            local result = action_core.try_use(snake_eye, job_def, settings, nil,
                string.format('Snake Eye: %s (Total: %d)', roll_ability.name, state.total))
            if result then
                state.snake_eye_armed = true
                return result
            end
        elseif decision == 'double' then
            -- 1 second after the initial roll, then 6 seconds between double-ups.
            -- Both timers are in-game proven -- do not tighten them.
            local ready_after_roll = (current_time - state.last_action_time) >= 1
            local ready_after_du   = (roll_state.last_double_up_time == 0)
                or ((current_time - roll_state.last_double_up_time) >= 6)

            if ready_after_roll and ready_after_du and not common.is_command_blocked('/ja "Double-Up" <me>') then
                common.debugf('[ROLL] Attempting Double-Up for Roll%d (%s) at total %d',
                    roll_num, roll_ability.name, state.total)

                -- Only one roll may await a packet at a time
                roll_state.roll1.expecting_double_up = false
                roll_state.roll2.expecting_double_up = false
                state.expecting_double_up = true

                -- Stamp on SEND, not just on the packet: until the 0x028 lands,
                -- state.total still reads the pre-double value, so an unstamped gate
                -- would let the next tick double again off a stale total and bust a
                -- total no tier would ever gamble on. The packet re-stamps this later.
                roll_state.last_double_up_time = current_time

                return {
                    command     = '/ja "Double-Up" <me>',
                    description = string.format('Double-Up: %s (Total: %d)', roll_ability.name, state.total),
                }
            end
        end
    end

    -- Priority 3: cast a missing roll, unless we're at slot capacity
    local active_rolls = count_active_configured_rolls(player_buffs, roll1_ability, roll2_ability)
    if active_rolls >= get_available_roll_slots(player_buffs) then
        common.debugf('[ROLL] Blocked from casting - at capacity')
        return nil
    end

    local has_roll1_buff = roll1_ability and action_core.has_any_buff(player_buffs, roll1_ability.buff_id) or false
    local has_roll2_buff = roll2_ability and action_core.has_any_buff(player_buffs, roll2_ability.buff_id) or false

    -- Which roll are we casting? Roll1 if it's missing; otherwise Roll2, but only
    -- once Roll1 exists and is no longer awaiting packets (one roll in flight).
    -- Slot 1 set to None is not "waiting on slot 1" -- slot 2 stands alone.
    local roll1_settled = (not roll1_ability) or (has_roll1_buff and not roll_state.roll1.expecting_double_up)
    local cast_num, cast_ability
    if roll1_ability and not has_roll1_buff then
        cast_num, cast_ability = 1, roll1_ability
    elseif roll1_settled and roll2_ability and not has_roll2_buff then
        cast_num, cast_ability = 2, roll2_ability
    end

    if cast_ability then
        -- Hold AOE for Group: a fresh roll is a party AOE -- hold the initial cast
        -- until the group is in range. Double-Up (Priority 2) is not gated; it
        -- refines an already-applied roll. Checked here (not earlier) so the
        -- gather announcement can name the actual roll about to be cast.
        if settings.hold_aoe_for_group and not common.group_in_aoe_range() then
            common.announce_gather(cast_ability.name, settings)
            return nil
        end

        local state = cast_num == 1 and roll_state.roll1 or roll_state.roll2
        -- Throttle: 2 seconds between roll casts (in-game proven)
        if (current_time - state.last_action_time) >= 2 then
            -- is_usable covers Phantom Roll's shared recast (193) and Amnesia
            local result = action_core.try_use(cast_ability, job_def, settings, nil,
                string.format('Casting: %s', cast_ability.name))
            if result then
                -- Reset state and mark that we're expecting this roll's packet value
                state.total = 0
                state.expecting_double_up = true
                state.snake_eye_armed = false
                state.last_action_time = current_time
                return result
            end
            common.debugf('[ROLL] Roll%d (%s) not usable yet', cast_num, cast_ability.name)
        end
    end

    return nil
end

-- ============================================================================
-- Packet Handler
-- ============================================================================
--[[
    Roll totals come out of the already-parsed 0x028 action packet
    (lib/core/parse_packets.lua), whose bit layout matches the server packer at
    src/map/packets/s2c/0x028_battle2.cpp.

    For a roll, on the caster's OWN target entry:
        packet.Type    = 6      -- cmd_no: job ability
        packet.Param            -- cmd_arg: the roll's ability id. On a Double-Up the
                                   server rewrites it to the UNDERLYING roll's id
                                   (action:actionID(prevAbility:getID())), so every
                                   packet self-identifies which roll it belongs to.
        action.Info             -- the die value 1-6, set by action:info() in
                                   scripts/globals/job_utils/corsair.lua. Only present
                                   on the caster's own entry.
        action.Param            -- the running total (the Lua ability's return value)
        action.Message          -- 420/421 roll, 424 double-up, 426/427 bust
]]--

function roll.handle_action_packet(packet, settings, job_def)
    if not settings or not settings.roll_enabled or not packet then
        return
    end

    -- cmd_no 6 = job ability
    if packet.Type ~= 6 then
        return
    end

    -- Actor must be us -- party members' rolls come through here too
    local party = common.get_party()
    local player_id = party and party:GetMemberServerId(0)
    if not player_id or packet.UserId ~= player_id then
        return
    end

    -- The die value only exists on the caster's own target entry
    local action
    for _, target in ipairs(packet.Targets or {}) do
        if target.Id == player_id then
            action = target.Actions and target.Actions[1]
            break
        end
    end
    if not action then
        return
    end

    -- Which configured slot is this? cmd_arg carries the roll's ability id.
    local roll_list = job_def and job_def.abilities and job_def.abilities.roll
    local roll_num, roll_ability
    for n = 1, 2 do
        local ability = find_roll_ability(roll_list, n == 1 and settings.roll1_name or settings.roll2_name)
        if ability and ability.ability_id == packet.Param then
            roll_num, roll_ability = n, ability
            break
        end
    end
    if not roll_num then
        return
    end

    local state = roll_num == 1 and roll_state.roll1 or roll_state.roll2
    local total = action.Param
    local die   = action.Info
    local msg   = action.Message

    -- Bust: the slot is spent until the Bust status wears off
    if msg == MSG_DOUBLEUP_BUST or msg == MSG_DOUBLEUP_BUST_S or total > 11 then
        state.total = 0
        state.expecting_double_up = false
        state.snake_eye_armed = false
        common.printf('[Roll] Bust: %s', roll_ability.name)
        return
    end

    -- Anything else (fail, already-active, ...) carries no usable total
    if msg ~= MSG_ROLL_MAIN and msg ~= MSG_ROLL_SUB and msg ~= MSG_DOUBLEUP then
        return
    end

    state.total = total
    -- Whatever Snake Eye was armed for has now resolved into this total.
    state.snake_eye_armed = false

    if msg == MSG_DOUBLEUP then
        roll_state.last_double_up_time = os.clock()
        common.printf('[Roll] Double-Up %s: %d (Total: %d)', roll_ability.name, die, total)
    else
        common.printf('[Roll] %s: %d (Total: %d)', roll_ability.name, die, total)
    end

    -- Landing on lucky, called out in green -- it's what the Double-Up sequence is
    -- aiming at. Deliberately says nothing about stopping: Lowest/Medium bank it here,
    -- but Highest rolls straight past it chasing 11.
    if total == roll_ability.lucky then
        common.successf('[Roll] %s: LUCKY %d!',
            roll_ability.name, total)
    elseif total == 11 then
        -- 11 is the cap and every tier stops here (12 busts), lucky included -- no
        -- roll's lucky number reaches 11, so this never competes with the line above.
        common.successf('[Roll] %s: 11!!!', roll_ability.name)
    end

    -- Every other stop reason is re-decided each tick in execute() (they depend on
    -- Snake Eye / Fold readiness), which also clears expecting_double_up once the
    -- chase is over.
end

-- ============================================================================
-- State Reset / Inspection
-- ============================================================================

-- Called when a roll selection changes in the config UI, so a stale packet total
-- can't leak into the newly picked roll.
function roll.reset_state()
    for _, state in ipairs({ roll_state.roll1, roll_state.roll2 }) do
        state.total = 0
        state.last_action_time = 0
        state.expecting_double_up = false
        state.snake_eye_armed = false
    end

    roll_state.last_double_up_time = 0

    common.debugf('[ROLL] State reset')
end

-- Current roll state (debug/UI display)
function roll.get_state()
    return roll_state
end

return roll
