--[[
    Common utilities for Sidekick automation framework
    Shared across all jobs: party management, buffs, targeting, logging
]]--

local common = {}
local chat = require('chat')
local targets = require('lib.core.targets')

-- Export targets module for direct access
common.targets = targets

-- Ashita API references
local ashita = ashita or {}
local AshitaCore = AshitaCore

-- Debug flag
common.debug = false

-- Addon name for header
local addon_name = 'Sidekick'

-- Param (0x7073) a 0x028 *_begin category carries in place of the spell/ability id when
-- the action was cancelled rather than started. See handle_action_packet.
common.INTERRUPT_PARAM = 28787

-- Casting state tracking (packet-based)
local casting_state = {
    is_casting = false,
    last_action_time = 0,
    -- Backstop only, not a mechanism: clears the lock if neither a spell_finish nor an
    -- interrupt packet ever arrives (zoning already clears it via clear_casting_state).
    cast_timeout = 16.0,
}

-- Last 0x028 action category seen from the player, for the debug panel readout.
local last_action = { category = nil, param = 0 }

-- 0x028 action categories (see handle_action_packet). Category 1 (melee) is absent by
-- design -- handle_action_packet drops those packets, so last_action never holds one.
local ACTION_CATEGORY_NAMES = {
    [2]  = 'ranged_finish', [6] = 'job_ability',    [11] = 'mob_tp_finish',
    [3]  = 'ws_finish',     [7] = 'ws_begin',       [12] = 'ranged_begin',
    [4]  = 'spell_finish',  [8] = 'casting_begin',  [13] = 'avatar_tp_finish',
    [5]  = 'item_finish',   [9] = 'item_begin',     [14] = 'job_ability_dnc',
                                                    [15] = 'job_ability_run',
}

-- How often any entity's position is re-sampled for movement (see
-- common.is_entity_moving).
local MOVEMENT_CHECK_INTERVAL = 0.25

-- Resting state tracking
local is_resting = false

-- Mount state tracking
local is_mounted = false

-- Dead state tracking
local is_dead = false

-- Rest conditions timer (shared so other modules can reset it)
-- Holds the os.clock() timestamp when rest conditions first became favorable (0 = not started)
local rest_conditions_met_time = 0

-- Cached max HP/MP per member (server_id -> {max_hp, max_mp})
-- Updated only when the member is observed at 100% HP or MP, since GetMemberMaxHP/GetMemberMaxMP do not exist.
local member_max_stats = {}

-- Trust buff tracking (packet-based since memory reads don't work for Trusts)
-- One entry per tracked instance, not per status: two songs of the same type
-- (Ballad + Ballad II) stack in-game and appear here as two 196s, matching what
-- a memory-read party member's buff array shows.
local trust_buffs = {}  -- trust_buffs[server_id] = {buff_id1, buff_id2, ...}

-- Cast time + base duration per tracked buff, parallel to trust_buffs.
-- Trusts and tracked targets get no reliable wear-off packets, so entries with a
-- known base duration are dropped by timer (expire_timed_buffs) instead —
-- same idea as the BST Reward reapply_interval, generalized per target/buff.
-- Keyed by the applying spell's name when we know it, else by the buff id, so
-- stacked tiers sharing a status id each keep their own row (and their own entry
-- in trust_buffs) instead of collapsing into one.
-- buff_timestamps[server_id][key] = { at = os.clock(), dur = seconds|nil, id = buff_id }
local buff_timestamps = {}

-- In-flight removals: when we fire a na-/Erase on a packet-tracked target we mark
-- the cured status here rather than deleting it, so the removal module skips it for
-- REMOVAL_SUPPRESS_WINDOW seconds (stops loop-casting while the spell resolves).
-- A successful cast's 0x028 msg-83 deletes the status well inside the window; a
-- rejected/resisted cast leaves no packet, so the mark expires and the status
-- becomes eligible again -- retried instead of orphaned on the target.
-- removal_suppress[server_id][debuff_id] = os.clock() of the attempt.
local removal_suppress = {}
local REMOVAL_SUPPRESS_WINDOW = 4.0  -- cast time (~2-3s) + post-action lockout (1.1s)

-- Base durations (seconds) for buffs cast on Trusts/tracked targets, keyed by
-- spell name. Our own casts pass the ability name; other casters' spells resolve
-- via GetSpellById. Detections with no spell id (0x029) fall back to the buff
-- name, so tierless buff names resolve to the base tier (buff "Regen" -> 75).
local BASE_BUFF_DURATION = {
    ['Haste']       = 180,
    ['Flurry']      = 180,
    ['Refresh']     = 150,
    ['Regen']       = 75,
    ['Regen II']    = 60,
    ['Regen III']   = 60,
    ['Phalanx II']  = 120,
    ['Protect']     = 1800,
    ['Protect II']  = 1800,
    ['Protect III'] = 1800,
    ['Protect IV']  = 1800,
    ['Shell']       = 1800,
    ['Shell II']    = 1800,
    ['Shell III']   = 1800,
    ['Shell IV']    = 1800,
}

-- All bard songs share one base duration.
local SONG_DURATION = 120

-- Backstop for a status detected on a packet-only target (Trust/tracked/alliance/
-- pet) that matches no known buff/debuff duration. Without a timer these tracked
-- forever, since their wear-off packets are unreliable/absent -- a stale status
-- then lingers until zone. 300s bounds that; Sidekick never re-applies unknown
-- statuses, so an early drop just clears tracking and re-adds on next detection.
local UNKNOWN_BUFF_DURATION = 300

-- Song slots one caster holds on one target. A main-job Bard maintains two; a
-- subjob Bard one. A new song beyond that evicts that caster's oldest-start-time
-- song, mirroring the game's overwrite behavior.
local SONG_SLOTS_MAIN = 2
local SONG_SLOTS_SUB  = 1
local BRD_JOB_ID      = 10

-- Ally-targetable song buff ids all live in 195-222 (Paeon..Scherzo);
-- 192-194 / 217 target enemies and never land on allies via these handlers.
local function is_song_buff(buff_id)
    return buff_id ~= nil and buff_id >= 195 and buff_id <= 222
end

-- Current pet's server id, refreshed each tick. Pets have normal entity ids
-- (< 0x1000000) so they miss the Trust guard; their buffs/debuffs ride the same
-- trust_buffs table via the packet handlers, keyed by this id.
local pet_server_id = 0

-- Alliance member server_id set — rebuilt each refresh_game_state tick.
-- Used by packet handlers to decide whether to track buffs for a given server_id.
local alliance_member_sids = {}  -- alliance_member_sids[server_id] = true
local pending_buffs = {}  -- pending_buffs[n] = {server_id=x, buff_id=y, timestamp=t}
local PENDING_BUFF_TIMEOUT = 10.0  -- Seconds before pending buff expires

-- Tracked targets (session-only, not saved to settings)
-- Players outside the party that we monitor for heal/buff/status_removal automation.
-- tracked_targets[server_id] = { server_id, name, target_index, main_level }
-- Buffs are tracked via trust_buffs (same packet-based system as Trusts).
-- Max HP is tracked via member_max_stats (same system as party members).
-- main_level is populated once the 0x0C9 check-response packet is received.
local tracked_targets = {}

-- Pending check requests: server_id -> timestamp (waiting for 0x0C9 response)
local pending_checks = {}
local PENDING_CHECK_TIMEOUT = 10.0

-- Pending raise flags: set when a 0x029 packet arrives for a dead target,
-- indicating the server rejected a raise spell because one is already pending.
-- Cleared in refresh_game_state when entity_status returns to non-dead.
local pending_raise_flags = {}  -- pending_raise_flags[server_id] = true

-- Average HP by level, averaged across all races/jobs in FFXI.
-- Used to estimate max HP for non-party tracked targets before they are seen at 100%.
local AVERAGE_HP_BY_LEVEL = {
    [1] = 70,   [2] = 86,   [3] = 101,  [4] = 117,  [5] = 133,
    [6] = 148,  [7] = 164,  [8] = 180,  [9] = 195,  [10] = 204,
    [11] = 227, [12] = 242, [13] = 258, [14] = 274, [15] = 289,
    [16] = 305, [17] = 321, [18] = 336, [19] = 352, [20] = 367,
    [21] = 382, [22] = 398, [23] = 414, [24] = 430, [25] = 445,
    [26] = 461, [27] = 477, [28] = 493, [29] = 508, [30] = 525,
    [31] = 540, [32] = 556, [33] = 572, [34] = 588, [35] = 603,
    [36] = 619, [37] = 635, [38] = 651, [39] = 665, [40] = 682,
    [41] = 697, [42] = 713, [43] = 729, [44] = 745, [45] = 760,
    [46] = 776, [47] = 792, [48] = 808, [49] = 823, [50] = 840,
    [51] = 855, [52] = 871, [53] = 887, [54] = 903, [55] = 918,
    [56] = 934, [57] = 950, [58] = 962, [59] = 979, [60] = 997,
    [61] = 1012, [62] = 1028, [63] = 1044, [64] = 1060, [65] = 1075,
    [66] = 1091, [67] = 1107, [68] = 1123, [69] = 1138, [70] = 1155,
    [71] = 1170, [72] = 1186, [73] = 1202, [74] = 1218, [75] = 1233,
}

-- Non-combat zone IDs (safe zones where combat is blocked)
local non_combat_zone_ids = {
    230, 231, 232, 233, -- San d'Oria
    234, 235, 236, 237, -- Bastok
    238, 239, 240, 241, 242, -- Windurst
    243, 244, 245, 246, -- Jeuno
    80, 87, 94, -- WotG Cities of the past (San d'Oria [S], Bastok [S], Windurst [S])
    48, 50, 53, -- Aht Urhgan cities/towns (Al Zahbi, Aht Urhgan Whitegate, Nashmau)
    26, 247, 248, 249, 250, 252, -- Other Towns (Tavnazian Safehold, Rabao, Selbina, Mhaura, Kazham, Norg)
    256, 257, -- Adoulin
    280, -- Mog Garden
    46, 47, -- Open sea routes
    220, 221, -- Ships bound for Selbina/Mhaura
    223, 224, 225, 226, -- Airships
    227, 228, -- Ships with Pirates (still safe zones)
    70, -- Chocobo Circuit
    251, -- Hall of the Gods
    284, -- Celennia Memorial Library
}

-- Helper function to get current zone ID
function common.get_zone_id()
    local ok, zone_id = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    end)
    if not ok or not zone_id then
        return 0
    end
    return zone_id
end

-- Helper function for distance calculation (public for use in other modules)
function common.calculate_distance(entity1, entity2)
    local ok_calc, distance = pcall(function()
        local dx = entity1.Movement.LocalPosition.X - entity2.Movement.LocalPosition.X
        local dy = entity1.Movement.LocalPosition.Y - entity2.Movement.LocalPosition.Y
        local dz = entity1.Movement.LocalPosition.Z - entity2.Movement.LocalPosition.Z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end)
    
    if not ok_calc or not distance then
        return nil
    end
    
    return distance
end

--[[
    Logging Utilities
]]--

-- Shared log helper: formats message, applies chat style, and prints.
-- @param style_fn  chat.message | chat.error | chat.warning
-- @param prefix    optional string prepended to message (e.g. '[DEBUG] ')
-- @param fmt       format string
-- @param ...       format arguments
local function log(style_fn, prefix, fmt, ...)
    local args = {...}
    local msg = fmt
    if #args > 0 then
        local ok, result = pcall(string.format, fmt, ...)
        if ok then msg = result end
    end
    print(chat.header(addon_name) .. style_fn((prefix or '') .. msg))
end

function common.printf(fmt, ...)  log(chat.message, nil, fmt, ...) end
function common.errorf(fmt, ...)  log(chat.error,   nil, fmt, ...) end
function common.warnf(fmt, ...)   log(chat.warning, nil, fmt, ...) end
-- Green. For an automation goal actually being met, not routine chatter.
function common.successf(fmt, ...) log(chat.success, nil, fmt, ...) end

--[[
    Repeat suppression for debug output. The tick loop runs every frame, so a
    module reporting a steady state ("no Double-Up buff") writes the same line
    ~60x/second and buries everything that actually changed.

    Per-message, not consecutive: modules interleave (Roll1 / Roll2 / Roll1 ...),
    so an "is this the same as the previous line?" check would suppress nothing.
    Each distinct message prints at most once per DEBUG_REPEAT_WINDOW; the count
    of what was swallowed rides along on the next print, so a stuck state still
    looks stuck rather than silent.

    The window is deliberately long. Any actual state CHANGE formats a different
    string and prints immediately, so nothing is delayed by it -- all it governs is
    how often an UNCHANGED state repeats itself. It is sized against the slowest
    thing being waited on (COR's ~60s Phantom Roll recast); anything shorter
    reprints the same idle line several times per cycle.
]]--
local DEBUG_REPEAT_WINDOW = 60.0   -- seconds
local debug_seen = {}             -- message -> { at = os.clock(), swallowed = n }
local debug_seen_count = 0

function common.debugf(fmt, ...)
    if not common.debug then return end

    local args = {...}
    local msg = fmt
    if #args > 0 then
        local ok, result = pcall(string.format, fmt, ...)
        if ok then msg = result end
    end

    local now  = os.clock()
    local seen = debug_seen[msg]

    if seen and (now - seen.at) < DEBUG_REPEAT_WINDOW then
        seen.swallowed = seen.swallowed + 1
        return
    end

    -- Messages embed live values (totals, timers), so the key space grows with
    -- session length. Nothing here is worth a real LRU -- drop the lot and let it
    -- refill, at worst one extra line prints.
    if debug_seen_count > 200 then
        debug_seen, debug_seen_count = {}, 0
        seen = nil
    end

    local suffix = (seen and seen.swallowed > 0) and string.format(' (x%d)', seen.swallowed + 1) or ''
    if not debug_seen[msg] then debug_seen_count = debug_seen_count + 1 end
    debug_seen[msg] = { at = now, swallowed = 0 }

    log(chat.message, '[DEBUG] ', '%s%s', msg, suffix)
end

--[[
    Player Status Checking
]]--

function common.is_idle()
    -- Idle == not in combat (exact inverse of is_combat, error paths included).
    return not common.is_combat()
end

-- Grace window (seconds) that is_combat stays true after the battle target
-- vanishes -- covers the gap between one mob dying and someone engaging the
-- next in a multi-mob pull, so support coverage overlaps instead of flickering.
local COMBAT_GRACE = 5.0
local combat_last_true = 0  -- os.clock() of the last real battle target

function common.is_combat()
    local ok, bt = pcall(function()
        return targets.get_bt()
    end)

    if not ok then
        return false  -- Assume not in combat if we can't get battle target
    end

    -- Check if battle target is a mob (0x10 flag in SpawnFlags)
    local is_mob = bt and bit.band(bt.SpawnFlags, 0x10) ~= 0 or false

    if is_mob then
        combat_last_true = os.clock()
        return true
    end

    -- No BT right now: stay "in combat" briefly so coverage overlaps the
    -- dead-mob -> next-mob gap.
    return (os.clock() - combat_last_true) < COMBAT_GRACE
end

-- Settings key for a per-ability gate (prefix 'combat_only' / 'idle_only').
-- Grouped abilities share one key (<prefix>_group_<group>); an ability with no
-- group -- or one whose group the user has ungrouped -- gets its own
-- (<prefix>_<ability_name_with_spaces_replaced_by_underscores>), so each tier of
-- an ungrouped group can be gated separately (e.g. Indi-Fury in combat,
-- Indi-Refresh while idle). No fallback to the group value once ungrouped,
-- matching how disabled_group_<group> keys behave.
-- Returns nil when no key can be built (unnamed, ungrouped ability).
function common.ability_gate_key(prefix, ability, settings)
    if not ability then return nil end
    if ability.group and not (settings and settings['ungrouped_' .. ability.group] == true) then
        return prefix .. '_group_' .. ability.group
    end
    if not ability.name then return nil end
    return prefix .. '_' .. ability.name:gsub(' ', '_')
end

-- Returns true if the given ability should be gated to combat-only based on user settings.
-- Key selection (per-group vs per-ability) is common.ability_gate_key.
-- Defaults to false (allowed outside of combat).
-- Abilities marked idle_only never participate in the combat_only gate.
-- <bt> abilities (e.g. Geo-bt debuffs) target the battle target and are
-- INHERENTLY combat-only -- there is no valid target outside combat -- so they
-- always return true regardless of (and independent of) the user setting.
function common.is_ability_combat_only(ability, settings)
    if not ability then return false end
    if ability.idle_only then return false end
    if ability.combat_only then return true end
    if common.ability_targets_bt(ability) then return true end
    if not settings then return false end
    local key = common.ability_gate_key('combat_only', ability, settings)
    return key ~= nil and settings[key] == true
end

-- Returns true if the given ability should be gated to idle-only (out of combat).
-- Mirror of is_ability_combat_only: a static ability.idle_only always wins;
-- otherwise the user setting at common.ability_gate_key('idle_only', ...) is
-- consulted. Combat Only and Idle Only are mutually exclusive; the UI clears
-- one when the other is set.
function common.is_ability_idle_only(ability, settings)
    if not ability then return false end
    if ability.idle_only then return true end
    if not settings then return false end
    local key = common.ability_gate_key('idle_only', ability, settings)
    return key ~= nil and settings[key] == true
end

-- Effective combat/idle gate for `ability` right now, using only its own
-- (static or user) combat_only/idle_only setting -- no per-target override.
-- Used wherever a target has no override concept of its own (area songs).
function common.ability_gate_ok_now(ability, settings)
    if common.is_ability_idle_only(ability, settings) and not common.is_idle() then return false end
    if common.is_ability_combat_only(ability, settings) and not common.is_combat() then return false end
    return true
end

-- Session-only per-target Combat/Idle override, keyed the same way as
-- party_buff_config (group name while grouped, else ability name; numeric 0-5
-- for ME/P1-P5, 'al_<flat_index>' for alliance, 'tt_<server_id>' for tracked).
-- Set via the right-click menu on any of those buttons.
-- Returns 'combat' | 'idle' | nil (nil = no override, inherit the ability's
-- own gate).
function common.target_gate_override(config_key, target_index, party_buff_gates)
    return party_buff_gates and config_key and party_buff_gates[config_key] and party_buff_gates[config_key][target_index]
end

-- Effective combat/idle gate for one target. A per-target override REPLACES
-- (not ANDs with) the ability's own combat_only/idle_only gate for that one
-- target; with no override it falls back to common.ability_gate_ok_now.
function common.target_gate_ok(ability, config_key, target_index, settings, party_buff_gates)
    local override = common.target_gate_override(config_key, target_index, party_buff_gates)
    if override == 'combat' then return common.is_combat() end
    if override == 'idle' then return common.is_idle() end
    return common.ability_gate_ok_now(ability, settings)
end

-- Config key for `ability` (group name while grouped, else ability name),
-- matching how party_buff_config/party_buff_gates key their entries.
function common.ability_config_key(ability, settings)
    local grouped = ability.group and not (settings and settings['ungrouped_' .. ability.group] == true)
    return grouped and ability.group or ability.name
end

-- True if some target's override matches the CURRENT combat/idle state, which
-- means filter_abilities_by_level must not drop the whole ability just
-- because its own gate doesn't match -- that one target still wants it.
-- Only per-target abilities (function command) carry overrides -- that covers
-- ME/P1-P5 plus the alliance and tracked buttons, which build their command
-- from a server id the same way.
function common.ability_gate_bypassed_by_target_override(ability, settings, party_buff_gates)
    if not party_buff_gates or not ability then return false end
    if type(ability.command) ~= 'function' then return false end
    local config_key = common.ability_config_key(ability, settings)
    local targets = config_key and party_buff_gates[config_key]
    if not targets then return false end
    local now = common.is_combat() and 'combat' or 'idle'
    for _, override in pairs(targets) do
        if override == now then return true end
    end
    return false
end

-- Returns true if the ability's command targets the battle target (<bt>).
-- These abilities cannot be cast without a valid mob battle target.
function common.ability_targets_bt(ability)
    if not ability or type(ability.command) ~= 'string' then return false end
    return ability.command:find('<bt>', 1, true) ~= nil
end

function common.is_engaged()
    local ok, player_entity = pcall(function()
        return GetPlayerEntity()
    end)
    
    if not ok or not player_entity then
        return false
    end
    
    local ok_status, status = pcall(function()
        return player_entity.Status
    end)
    
    if not ok_status or not status then
        return false
    end
    
    return status == 1
end

function common.can_attack()
    -- Get current zone
    local zone_id = common.get_zone_id()
    if zone_id == 0 then
        return false
    end
    
    -- Check if zone is in non-combat list
    for _, safe_zone_id in ipairs(non_combat_zone_ids) do
        if zone_id == safe_zone_id then
            return false
        end
    end
    
    -- Event system pointer (code from Thorny)
    local pEventSystem = ashita.memory.find('FFXiMain.dll', 0, "A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3", 0, 0)

    -- Check if event system is currently active (cutscene, dialog, etc.)
    if pEventSystem ~= 0 then
        local ptr = ashita.memory.read_uint32(pEventSystem + 1)
        if ptr ~= 0 and ashita.memory.read_uint8(ptr) == 1 then
            return false  -- Cannot attack during events
        end
    end
    
    return true
end

function common.is_casting()
    -- Returns true when player is casting a spell.
    -- State is tracked from the 0x028 action category (see handle_action_packet).
    -- Prevents automation from spamming actions during cast time

    -- Timeout check: if too much time has passed, clear the casting state
    if casting_state.is_casting then
        local elapsed = os.clock() - casting_state.last_action_time
        if elapsed > casting_state.cast_timeout then
            common.debugf('[Casting] Timeout after %.1fs, clearing stuck casting state', elapsed)
            casting_state.is_casting = false
            -- We lost track of the cast; don't let the panel keep reporting it.
            last_action.category = nil
            return false
        end
    end
    
    return casting_state.is_casting
end

-- Handle action packet (0x028) for casting detection.
-- Args: actionPacket (table) - parsed packet from parse_packets.parse_action_packet
-- Caller must have already confirmed the player is the actor (UserId).
--
-- Cast start and cast finish are separate packets, distinguished only by the 4-bit
-- category (actionPacket.Type):
--    1 = melee            6 = job_ability      11 = mob_tp_finish
--    2 = ranged_finish    7 = ws_begin         12 = ranged_begin
--    3 = ws_finish        8 = casting_begin    13 = avatar_tp_finish
--    4 = spell_finish     9 = item_begin       14 = job_ability (DNC)
--    5 = item_finish                           15 = job_ability (RUN)
-- An interrupted cast sends no category 4; it arrives as a *second* category 8 carrying
-- INTERRUPT_PARAM. Without that Param check it would re-arm the cast lock and freeze
-- automation until cast_timeout expired.
function common.handle_action_packet(actionPacket)
    if not actionPacket then return end

    local category = actionPacket.Type

    -- Autoattack rounds say nothing about casting; ignore them entirely.
    if category == 1 then return end

    last_action.category = category
    last_action.param = actionPacket.Param

    local was_casting = casting_state.is_casting

    -- Any action we take breaks resting. is_resting is authoritative from the
    -- player's entity_status each tick; this only avoids a one-tick lag.
    is_resting = false

    if category == 8 and actionPacket.Param ~= common.INTERRUPT_PARAM then
        casting_state.is_casting = true
        casting_state.last_action_time = os.clock()
    else
        -- Cast finished, interrupted, or a non-spell action (JA/WS/item/ranged) —
        -- none of which can overlap a cast, so the lock is safe to drop.
        casting_state.is_casting = false
    end

    -- Output state change messages
    if casting_state.is_casting and not was_casting then
        common.debugf('[CASTING STARTED] Category: %d, Param: %d', category, actionPacket.Param)
    elseif not casting_state.is_casting and was_casting then
        common.debugf('[CASTING ENDED] Category: %d, Param: %d', category, actionPacket.Param)
    end
end

-- Drop the casting lock without waiting for the timeout. Zoning cancels an in-flight
-- cast without sending spell_finish, and a stuck lock is self-sustaining (locked = no
-- actions = no packet to clear it), so automation would freeze for the whole timeout.
function common.clear_casting_state()
    if casting_state.is_casting then
        common.debugf('[Casting] Cleared (zone change)')
    end
    casting_state.is_casting = false
    last_action.category = nil
end

-- Debug panel readout: the last action category detected from the player, plus the
-- spell name where we have one. Param is a spell id only for the two magic categories.
function common.get_last_action()
    -- Evaluates the stuck-cast timeout, which clears last_action, so a cast whose
    -- finish packet never arrived isn't reported forever.
    common.is_casting()

    if not last_action.category then return 'none' end

    -- A cancelled action reuses its _begin category, so report the interrupt rather
    -- than a bogus 'casting_begin' and a spell lookup on an id that is not one.
    if last_action.param == common.INTERRUPT_PARAM then
        local name = ACTION_CATEGORY_NAMES[last_action.category]
        return name and ('interrupted (' .. name .. ')') or 'interrupted'
    end

    local label = ACTION_CATEGORY_NAMES[last_action.category]
        or string.format('category %d', last_action.category)

    if last_action.category == 4 or last_action.category == 8 then
        local spell = AshitaCore:GetResourceManager():GetSpellById(last_action.param)
        local name = spell and spell.Name and spell.Name[1]
        if name and name ~= '' then
            label = label .. ': ' .. name
        end
    end

    return label
end

-- True while the player is moving (for magic casting restrictions). The player
-- is just another entity, so this is common.is_entity_moving below with the
-- grace window cut to a single sample interval: the local player's position
-- updates every frame, so it needs none of the packet-lag slack a remote entity
-- does, and "moved within one interval" is the same read the old dedicated
-- player tracker gave.
function common.is_player_moving()
    return common.is_entity_moving(targets.get_party_member(0), MOVEMENT_CHECK_INTERVAL)
end

-- Position samples for entities other than the player, keyed by ServerId.
-- Entries are three floats and are only created for entities we actually gate
-- on (a Geo target), so they are left to accumulate for the session.
local entity_movement = {}

-- A remote entity's position only updates when its movement packet arrives, so a
-- straight "moved since the last sample" read blinks false between updates.
-- Anything that moved within this many seconds still counts as moving.
local MOVING_GRACE = 0.5

-- True while an entity is walking. Used by the Geomancer bubble gates: a luopan
-- is dropped where its target stands, so casting on someone mid-stride just
-- leaves the bubble behind them.
-- Args: entity (userdata) - entity from common.targets / GetEntity
--       grace (number, optional) - seconds since the last movement that still
--           read as moving; defaults to MOVING_GRACE (common.is_player_moving
--           passes one sample interval, having no packet lag to cover)
-- Returns: boolean (false when the entity is missing or has never been sampled)
function common.is_entity_moving(entity, grace)
    if not entity then return false end

    local ok, id, x, y, z = pcall(function()
        local pos = entity.Movement.LocalPosition
        return entity.ServerId, pos.X, pos.Y, pos.Z
    end)
    if not ok or not id or id == 0 then return false end

    local now   = os.clock()
    local state = entity_movement[id]

    -- First sighting: nothing to compare against, so read as standing still
    -- rather than blocking the cast until a second sample lands.
    if not state then
        entity_movement[id] = { last_check = now, last_moved = nil, x = x, y = y, z = z }
        return false
    end

    if now - state.last_check >= MOVEMENT_CHECK_INTERVAL then
        state.last_check = now
        if x ~= state.x or y ~= state.y or z ~= state.z then
            state.last_moved = now
            state.x, state.y, state.z = x, y, z
        end
    end

    return state.last_moved ~= nil and (now - state.last_moved) < (grace or MOVING_GRACE)
end

-- Refresh the movement samples for everyone a gate might ask about (party
-- members and the battle target). Called once per tick from refresh_game_state.
-- Sampling cannot be left to the gates themselves: those sit behind
-- is_command_blocked, which reports 'Moving' for every command while the player
-- walks, so an entity read only where it is gated would be sampled exclusively
-- while standing still and could never look like it had been moving.
-- No throttle here: each entity carries its own last_check, so a call between
-- sample intervals costs a position read and a compare.
-- Args: state (table) - the game_state snapshot being built
function common.sample_movement(state)
    for i = 0, 5 do
        if (i == 0 and state.player) or state.party[i] then
            common.is_entity_moving(targets.get_party_member(i))
        end
    end

    -- get_bt reads through an ffi pointer, and this runs outside the tick loop's
    -- per-module pcall, so a bad read here would take the whole refresh down.
    local ok, bt = pcall(targets.get_bt)
    if ok then common.is_entity_moving(bt) end
end

function common.get_player_level()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player then return 0, 0 end
    local main_level = player:GetMainJobLevel()
    local sub_level = player:GetSubJobLevel()
    return main_level, sub_level
end

function common.get_player_job()
    -- Read job straight off the Player struct. Party-based reads were used
    -- previously for packet sync during zoning, but Sidekick's tick loop is
    -- guarded off while loading, so that lag window never applies here.
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player then return 0, 0 end
    local ok, job = pcall(function() return player:GetMainJob() end)
    if not ok or not job then return 0, 0 end
    local ok_sub, subjob = pcall(function() return player:GetSubJob() end)
    if not ok_sub or not subjob then subjob = 0 end
    return job, subjob
end

-- Job data mappings (single source of truth)
local job_data = {
    {id = 1,  abbr = 'WAR', name = 'Warrior'},
    {id = 2,  abbr = 'MNK', name = 'Monk'},
    {id = 3,  abbr = 'WHM', name = 'White Mage'},
    {id = 4,  abbr = 'BLM', name = 'Black Mage'},
    {id = 5,  abbr = 'RDM', name = 'Red Mage'},
    {id = 6,  abbr = 'THF', name = 'Thief'},
    {id = 7,  abbr = 'PLD', name = 'Paladin'},
    {id = 8,  abbr = 'DRK', name = 'Dark Knight'},
    {id = 9,  abbr = 'BST', name = 'Beastmaster'},
    {id = 10, abbr = 'BRD', name = 'Bard'},
    {id = 11, abbr = 'RNG', name = 'Ranger'},
    {id = 12, abbr = 'SAM', name = 'Samurai'},
    {id = 13, abbr = 'NIN', name = 'Ninja'},
    {id = 14, abbr = 'DRG', name = 'Dragoon'},
    {id = 15, abbr = 'SMN', name = 'Summoner'},
    {id = 16, abbr = 'BLU', name = 'Blue Mage'},
    {id = 17, abbr = 'COR', name = 'Corsair'},
    {id = 18, abbr = 'PUP', name = 'Puppetmaster'},
    {id = 19, abbr = 'DNC', name = 'Dancer'},
    {id = 20, abbr = 'SCH', name = 'Scholar'},
    {id = 21, abbr = 'GEO', name = 'Geomancer'},
    {id = 22, abbr = 'RUN', name = 'Rune Fencer'}
}

-- Get full job name from ID
function common.get_job_name_from_id(job_id)
    if not job_id then return 'Unknown' end
    for _, job in ipairs(job_data) do
        if job.id == job_id then
            return job.name
        end
    end
    return 'Unknown'
end

function common.get_job_name(job_id)
    -- Try to get full job name first from our data
    local name = common.get_job_name_from_id(job_id)
    if name ~= 'Unknown' then
        return name
    end
    
    -- Fallback to resource manager
    local ok, res_name = pcall(function() 
        return AshitaCore:GetResourceManager():GetString('jobs.names', job_id) 
    end)
    if ok and res_name then
        return res_name
    end
    
    -- Fallback to abbreviated name if full name not available
    ok, res_name = pcall(function() 
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job_id) 
    end)
    if ok and res_name then
        return res_name:upper()
    end
    
    return tostring(job_id)
end

-- Deep copy for settings-profile snapshots. Settings hold plain data only
-- (bool/number/string/table -- the settings lib rejects anything else), so no
-- function/userdata handling. Tables come back as T{} to match surrounding usage.
function common.deep_copy(value)
    if type(value) ~= 'table' then
        return value
    end
    local copy = T{}
    for k, v in pairs(value) do
        copy[k] = common.deep_copy(v)
    end
    return copy
end

-- Profile combo key for the current main/sub pair: 'WHM/BLM', 'WHM/None'.
-- Settings-profile lists are keyed by this so WHM/BLM and WHM/SCH stay separate.
function common.get_job_combo()
    local main_id, sub_id = common.get_player_job()
    local main_abbr, sub_abbr
    for _, job in ipairs(job_data) do
        if job.id == main_id then main_abbr = job.abbr end
        if job.id == sub_id then sub_abbr = job.abbr end
    end
    return (main_abbr or 'UNK') .. '/' .. (sub_abbr or 'None')
end

-- Get pet entity
-- Returns: pet entity object or nil if no pet
function common.get_pet_entity()
    return targets.get_pet()
end

-- True when an ability's pet-type requirement is met (or it has none).
-- `ability.requires_pet_name` is a list of acceptable pet names (e.g. Carbuncle,
-- or the rabbit jug pets). Shared by job validators and the config UI so the
-- name list lives in one place (the ability data).
function common.pet_type_ok(ability)
    local names = ability.requires_pet_name
    if not names then return true end
    local pet = common.get_pet_entity()
    if not pet then return false end
    local ok, pet_name = pcall(function() return pet.Name end)
    if not ok then return false end
    for _, n in ipairs(names) do
        if pet_name == n then return true end
    end
    return false
end

-- Get party manager
-- Returns: party object or nil on error
function common.get_party()
    local ok, party = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty()
    end)
    
    if not ok or not party then
        return nil
    end
    
    return party
end

-- Status ailments Erase removes (WHM/SCH). Mirrors every status_effects.sql row
-- carrying EFFECTFLAG_ERASABLE (0x2) -- the only flag EraseStatusEffect() reads --
-- minus the two that land on a mob and never on a party member (536 Gambit,
-- 571 Rayke, both RUN). The Na-spell ailments are deliberately absent -- Erase
-- does not touch them, so listing them only made Erase fire and fail. Helix (186)
-- is absent for the same reason: no erasable flag on this server, despite being a
-- Bio/Dia-style DoT.
common.ERASABLE_DEBUFFS = {10, 11, 12, 13, 21, 128, 129, 130, 131, 132, 133, 134,
    135, 136, 137, 138, 139, 140, 141, 142, 144, 145, 146, 147, 148, 149, 156,
    167, 174, 175, 189, 192, 194, 291, 298, 404}

-- Status ailments the pet cleanses remove (BST Reward, PUP Maintenance): everything
-- Erase clears plus the Na-spell ailments below. Deliberately not Erase's list --
-- server-side neither ability is an Erase (Maintenance walks its own ailment list
-- before falling back to eraseStatusEffect(); Reward is a Jackcoat-gear-gated cleanse
-- that never calls Erase). Reward over-claims here, firing and no-opping without the
-- gear rather than missing a real cleanse.
common.PET_CLEANSE_DEBUFFS = {3, 4, 5, 6, 8, 9, 31}  -- Poison, Paralysis, Blindness,
                                                     -- Silence, Disease, Curse, Plague
for _, id in ipairs(common.ERASABLE_DEBUFFS) do
    table.insert(common.PET_CLEANSE_DEBUFFS, id)
end

-- Invisible (status_effects.sql id 69). Casting anything, and any /pet command,
-- breaks it -- so the modules that would spend it check for it first. Sneak (71)
-- survives both and is never gated.
common.INVISIBLE_BUFF = 69

-- Curse-family statuses removed by Cursna and by Holy Water / Hallowed Water.
-- 9 = Curse, 15 = Doom, 20 = Bane, 30 = Curse (Bane II).
common.CURSE_DEBUFFS = {9, 15, 20, 30}

-- Human-readable names for the statuses removers can strip, for the per-status
-- opt-out checkboxes in the ability right-click menu. Curse-family naming
-- follows the CURSE_DEBUFFS comment above (not the raw status_effects.sql, where
-- 9/20/30 all read "curse"/"bane"); the stat-down tail matches Panacea's family.
common.DEBUFF_NAMES = {
    [3]='Poison', [4]='Paralysis', [5]='Blindness', [6]='Silence',
    [7]='Petrification', [8]='Disease', [9]='Curse', [10]='Stun', [11]='Bind',
    [12]='Weight', [13]='Slow', [15]='Doom', [20]='Bane', [21]='Addle',
    [30]='Curse II', [31]='Plague', [128]='Burn', [129]='Frost',
    [130]='Choke', [131]='Rasp', [132]='Shock', [133]='Drown',
    [134]='Dia', [135]='Bio',
    [136]='STR Down', [137]='DEX Down', [138]='VIT Down', [139]='AGI Down',
    [140]='INT Down', [141]='MND Down', [142]='CHR Down', [144]='Max HP Down',
    [145]='Max MP Down', [146]='Accuracy Down', [147]='Attack Down',
    [148]='Evasion Down', [149]='Defense Down', [156]='Flash',
    [167]='Magic Def. Down', [174]='Magic Acc. Down', [175]='Magic Atk. Down',
    [189]='Max TP Down', [192]='Requiem', [194]='Elegy', [291]='Enmity Down',
    [298]='Crit. Eva. Down', [404]='Magic Eva. Down',
}

-- Base durations (seconds) for DEBUFFS packet-detected on Trusts/tracked targets,
-- keyed by status id. Backstop so a missed removal packet can't loop a na-/Erase
-- spell forever: expire_timed_buffs drops the status once the timer elapses.
-- Only debuffs a Sidekick ability can actually remove are listed (no remover = no
-- loop to guard against). These are the ones NOT already covered by the flat 120s
-- erasable-debuff default in base_buff_duration: non-erasable statuses that still
-- have a remover (Sleep/Petrify/Doom), non-120 accurate durations (Bind/Gravity/
-- Slow), and the until-removed group (Disease/Curse/Bane/Plague -> INFINITE, which
-- also overrides the 120s default back to no-timer). Erasable 120s debuffs
-- (Poison/Paralyze/Blind/Silence/Dia/Bio) fall through to that default. Debuffs
-- nothing strips (Amnesia/Charm/Terror) are intentionally absent -- timing
-- them out buys nothing.
local INFINITE = false  -- tracked but never timer-expired
local BASE_DEBUFF_DURATION = {
    [2]  = 90,        -- Sleep       (Cure/wake; not erasable)
    [19] = 90,        -- Sleep II    (Cure/wake; not erasable)
    [7]  = 60,        -- Petrification (Stona; not erasable)
    [11] = 60,        -- Bind        (Erase)
    [12] = 90,        -- Weight/Gravity (Erase)
    [13] = 180,       -- Slow        (Erase)
    [15] = 30,        -- Doom        (Cursna / Holy Water; not erasable)
    [8]  = INFINITE,  -- Disease     (Viruna; until removed)
    [9]  = INFINITE,  -- Curse       (Cursna; until removed)
    [20] = INFINITE,  -- Bane        (Cursna; until removed)
    [31] = INFINITE,  -- Plague      (Viruna; until removed)
}

-- Set form of "is this a debuff some Sidekick ability can remove", for O(1) lookups.
-- Built from the PET_CLEANSE_DEBUFFS superset, not Erase's share: the 120s expiry
-- backstop below keys off this, and a debuff left out of it is tracked with no timer,
-- so one missed removal packet loops its remover forever.
local REMOVABLE_SET = {}
for _, id in ipairs(common.PET_CLEANSE_DEBUFFS) do REMOVABLE_SET[id] = true end

-- Effective (user-filtered) debuff-id list for a remover. Multi-status removers
-- (Erase, Esuna, Cursna, Viruna, Chakra...) expose a per-status opt-out in the
-- right-click menu; a 'skip_debuff_<AbilityName>_<id>' setting drops that id.
-- Returns debuff_id unchanged for single-id / nil / no-settings cases, so a
-- wildcard remover (nil debuff_id) still reads as "removes anything". A remover
-- with every status disabled returns {}, i.e. removes nothing.
function common.effective_debuff_ids(ability, settings)
    local ids = ability.debuff_id
    if type(ids) ~= 'table' or #ids < 2 or not settings or not ability.name then
        return ids
    end
    local prefix = 'skip_debuff_' .. ability.name:gsub(' ', '_') .. '_'
    local filtered = {}
    for _, id in ipairs(ids) do
        if settings[prefix .. id] ~= true then filtered[#filtered + 1] = id end
    end
    return filtered
end

-- Containers an equippable (armor) item can be worn from: main inventory (0)
-- plus all eight Mog Wardrobes (8, 10-16). Matches the client's equip-eligible
-- container set, so a "count" here reflects everything the player could equip.
local EQUIP_CONTAINERS = { 0, 8, 10, 11, 12, 13, 14, 15, 16 }

-- Ashita's internal container id -> the container number the /equip command
-- expects (0 = Inventory, 1-8 = Mog Wardrobe 1-8).
local EQUIP_COMMAND_CONTAINER = { [0] = 0, [8] = 1, [10] = 2, [11] = 3, [12] = 4, [13] = 5, [14] = 6, [15] = 7, [16] = 8 }

-- Normalize an ammo spec (a list of { id=, name=, level= } tier entries) to a
-- set of item ids.
local function ammo_id_set(spec)
    local set = {}
    for _, e in ipairs(spec) do
        if e.id then set[e.id] = true end
    end
    return set
end

-- pcall wrapper around the inventory manager, shared by every ammo helper below.
local function get_inventory()
    local ok, inventory = pcall(function()
        return AshitaCore:GetMemoryManager():GetInventory()
    end)
    if ok then return inventory end
    return nil
end

-- Count how many of the given items the player holds across every
-- equip-eligible container. spec is a list of tier entries. Returns a total
-- count (0 if none / inventory not loaded).
function common.count_equippable_items(spec)
    local inventory = get_inventory()
    if not inventory then return 0 end

    local id_set = ammo_id_set(spec)

    local total = 0
    for _, container in ipairs(EQUIP_CONTAINERS) do
        local ok_max, max = pcall(function() return inventory:GetContainerCountMax(container) end)
        if ok_max and max then
            for i = 0, max do
                local entry = inventory:GetContainerItem(container, i)
                if entry and id_set[entry.Id] then
                    total = total + entry.Count
                end
            end
        end
    end
    return total
end

-- Return the item id equipped in the given equipment slot (0-indexed:
-- 0=main, 1=sub, 2=range, 3=ammo, ...), or nil if the slot is empty.
function common.get_equipped_item_id(slot)
    local inventory = get_inventory()
    if not inventory then return nil end

    local eq = inventory:GetEquippedItem(slot)
    if not eq or not eq.Index or eq.Index == 0 then return nil end

    -- Index packs the source slot: high byte = container, low byte = slot index.
    local entry = inventory:GetContainerItem(math.floor(eq.Index / 256), eq.Index % 256)
    if not entry then return nil end
    local id = entry.Id
    if id == 0 or id == -1 or id == 65535 then return nil end
    return id
end

-- True when one of the spec's item ids is equipped in the ammo slot (slot 3).
function common.is_ammo_equipped(spec)
    local equipped = common.get_equipped_item_id(3)
    if not equipped then return false end
    return ammo_id_set(spec)[equipped] == true
end

-- Name of the spec's tier currently worn in the ammo slot, or nil if none.
function common.equipped_ammo_name(spec)
    local equipped = common.get_equipped_item_id(3)
    if not equipped or type(spec) ~= 'table' then return nil end
    for _, e in ipairs(spec) do
        if type(e) == 'table' and e.id == equipped then return e.name end
    end
    return nil
end

-- Find the first owned item (matching the spec) across equip-eligible
-- containers. Returns container, item_id -- or nil if none owned.
function common.find_equippable_item(spec)
    local inventory = get_inventory()
    if not inventory then return nil end

    local id_set = ammo_id_set(spec)
    for _, container in ipairs(EQUIP_CONTAINERS) do
        local ok_max, max = pcall(function() return inventory:GetContainerCountMax(container) end)
        if ok_max and max then
            for i = 0, max do
                local entry = inventory:GetContainerItem(container, i)
                if entry and entry.Count and entry.Count > 0 and id_set[entry.Id] then
                    return container, entry.Id
                end
            end
        end
    end
    return nil
end

-- Build a native "/equip ammo" command for the best ammo tier the player can
-- use and actually owns. spec must be a list of { id=, name=, level= } entries,
-- ordered worst -> best. Picks the highest-level entry with level <= player_level
-- (the main job level) that is owned, and names its container so the game equips
-- it straight from a wardrobe if needed. When several tiers share a level
-- (e.g. oils are all level 1), the later/better list entry wins.
-- Returns { command, description } or nil (own none / none level-eligible).
function common.select_ammo_equip_command(spec, player_level)
    if type(spec) ~= 'table' then return nil end
    local best, best_container
    for _, e in ipairs(spec) do
        if type(e) == 'table' and e.name and (e.level or 0) <= (player_level or 0) then
            local container = common.find_equippable_item({ e })  -- nil if not owned
            if container and ((not best) or (e.level or 0) >= (best.level or 0)) then
                best, best_container = e, container
            end
        end
    end
    if not best then return nil end
    local equip_num = EQUIP_COMMAND_CONTAINER[best_container] or 0
    return {
        command     = string.format('/equip ammo "%s" %d', best.name, equip_num),
        description = string.format('Equipping %s', best.name),
    }
end

-- For the first enabled, level-eligible ability in `abilities` that needs a
-- consumable in the ammo slot (BST biscuit/poultice, PUP oil) and isn't wearing
-- one, return the /equip command for the best owned tier. nil when all are
-- already equipped, disabled, none owned, or not equippable on this job.
function common.ammo_equip_command(abilities, settings, player)
    for _, ability in ipairs(abilities or {}) do
        local spec = ability.requires_equipped_ammo
        -- Skip a pet-only ammo (BST poultice) when no pet is out, so pet-less
        -- jobs (NIN Sange -> Shuriken) can share this without equipping it early.
        if spec and not common.is_ammo_equipped(spec)
           and not (ability.pet_required and not targets.get_pet()) then
            local disabled     = settings['disabled_' .. ability.name:gsub(' ', '_')] == true
            local usable_level = ability.is_main_job == false and (player.sub_level or 0) or (player.main_level or 0)
            -- Oils equip PUP-main only; biscuits/poultice equip on any job.
            local wrong_main   = ability.ammo_main_job_only and ability.is_main_job == false
            if not disabled and not wrong_main and (ability.level or 0) <= usable_level then
                local equip = common.select_ammo_equip_command(spec, player.main_level or 0)
                if equip then return equip end
            end
        end
    end
    return nil
end

-- Get entity manager
-- Returns: entity manager object or nil on error
function common.get_entity_manager()
    local ok, entity_mgr = pcall(function()
        return AshitaCore:GetMemoryManager():GetEntity()
    end)
    
    if not ok or not entity_mgr then
        return nil
    end
    
    return entity_mgr
end

-- Resolve a server ID to an entity name using fast index derivation.
-- Uses the same shortcut that parse_packets.GetIndexFromId does for NPCs/Trusts
-- (bit-mask on the lower 12 bits) and falls back to a party/tracked lookup,
-- avoiding a full O(2304) entity scan in the common case.
-- Args:   server_id (number) - Entity server ID
-- Returns: string - Entity name or 'Unknown'
function common.resolve_entity_name(server_id)
    if not server_id or server_id == 0 then return 'Unknown' end
    local entMgr = AshitaCore:GetMemoryManager():GetEntity()
    if not entMgr then return 'Unknown' end

    -- Fast path for NPCs/Trusts (server_id has 0x1000000 bit set)
    if bit.band(server_id, 0x1000000) ~= 0 then
        local index = bit.band(server_id, 0xFFF)
        if index >= 0x900 then index = index - 0x100 end
        if index < 0x900 and entMgr:GetServerId(index) == server_id then
            local name = entMgr:GetName(index)
            if name and name ~= '' then return name end
        end
    end

    -- Try party members (indices are low, fast check)
    local party = common.get_party()
    if party then
        for i = 0, 5 do
            if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == server_id then
                local ti = party:GetMemberTargetIndex(i)
                if ti and ti > 0 then
                    local name = entMgr:GetName(ti)
                    if name and name ~= '' then return name end
                end
            end
        end
    end

    -- Try tracked targets
    local tt = tracked_targets[server_id]
    if tt then
        if tt.name and tt.name ~= '' then return tt.name end
        if tt.target_index and tt.target_index > 0 then
            local name = entMgr:GetName(tt.target_index)
            if name and name ~= '' then return name end
        end
    end

    -- Fallback: full entity scan (rare, only for unknown entities)
    for idx = 1, 0x8FF do
        if entMgr:GetServerId(idx) == server_id then
            local name = entMgr:GetName(idx)
            if name and name ~= '' then return name end
            break
        end
    end

    return 'Unknown'
end

-- Get player's current target server ID
-- Returns: number (target server ID) or 0 if no target
function common.get_target_id()
    local target_entity = targets.get_t()
    if not target_entity then
        return 0
    end
    
    local server_id = target_entity.ServerId
    if not server_id or server_id == 0 then
        return 0
    end
    
    return server_id
end

-- Get array of party member server IDs
-- Returns: table of server IDs (numbers) for active party members
function common.get_party_server_ids()
    local party = common.get_party()
    if not party then
        return {}
    end
    
    local server_ids = {}
    for i = 0, 5 do
        if party:GetMemberIsActive(i) == 1 then
            local server_id = party:GetMemberServerId(i)
            if server_id and server_id > 0 then
                table.insert(server_ids, server_id)
            end
        end
    end
    
    return server_ids
end

function common.get_party_size()
    local party = common.get_party()
    if not party then return 0 end
    
    local count = 0
    for i = 0, 5 do
        if party:GetMemberIsActive(i) == 1 then
            count = count + 1
        end
    end
    return count
end

function common.is_party_member_active(index)
    local party = common.get_party()
    if not party then return false end
    return party:GetMemberIsActive(index) == 1
end

function common.get_party_member_name(index)
    local party = common.get_party()
    if not party then return nil end
    return party:GetMemberName(index)
end

function common.get_party_member_zone(index)
    local party = common.get_party()
    if not party then return nil end
    return party:GetMemberZone(index)
end

function common.get_party_index_by_name(name)
    -- Returns party index (0-5) for given character name, or nil if not found
    if not name then return nil end
    
    local party = common.get_party()
    if not party then return nil end
    
    -- Check all party slots (0=player, 1-5=party members)
    for i = 0, 5 do
        if party:GetMemberIsActive(i) == 1 then
            local member_name = party:GetMemberName(i)
            if member_name == name then
                return i
            end
        end
    end
    
    return nil
end

function common.get_target_index_by_name(name)
    -- Returns entity target index for given character name, or nil if not found
    local party_index = common.get_party_index_by_name(name)
    if not party_index then return nil end
    
    local party = common.get_party()
    if not party then return nil end
    
    local target_index = party:GetMemberTargetIndex(party_index)
    if target_index and target_index > 0 then
        return target_index
    end
    
    return nil
end

-- Returns true if value is above zero and below threshold (i.e. alive/present but needs attention).
-- Consolidates the repeated pattern: value > 0 and value < threshold
function common.below_threshold(value, threshold)
    return value > 0 and value < threshold
end

-- Returns true if a member's HP% indicates they are alive and not at full health.
-- Used to skip dead (0%) and full-health (100%) members in party loops.
function common.is_active_member(hpp)
    return common.below_threshold(hpp, 100)
end

-- CatsEyeXI trusts that can't take damage (and stay at full HP), so healing,
-- AOE healing, debuff removal and buffing them is wasted. Support modules skip
-- any party/tracked/alliance member matching one of these names AND confirmed to
-- be a Trust/NPC (server_id >= 0x1000000, same test as build_member's is_trust)
-- so a real player who happens to share one of these names is never blocked.
local EXCLUDED_TRUSTS = {
    ['Moogle'] = true, ['Sakura'] = true, ['Kupofried'] = true,
    ['Star Sibyl'] = true, ['Brygid'] = true, ['Cornelia'] = true,
}
function common.is_trust_excluded(name, server_id)
    if name == nil or EXCLUDED_TRUSTS[name] ~= true then return false end
    return server_id ~= nil and server_id >= 0x1000000
end

function common.is_in_range(target_index, range)
    -- Ensure range is a number
    local range_value = type(range) == 'number' and range or 21
    
    -- Get both entities
    local player_entity = targets.get_me()
    if not player_entity then
        return false
    end
    
    local target_entity = GetEntity(target_index)
    if not target_entity then
        return false
    end
    
    -- Calculate distance between player and target
    local distance = common.calculate_distance(player_entity, target_entity)
    return distance and distance <= range_value
end

-- AOE radius (yalms). -ga/-ra, area songs, Phantom Rolls and Accession/Diffusion
-- all land within ~10. One default; add a per-call override if a mechanism proves
-- to differ (rolls are slightly tighter) rather than special-casing the helper.
common.AOE_RADIUS = 10

-- True when every alive, in-zone, non-trust party member (1-5) is within radius,
-- i.e. an area buff/song/roll cast now would cover the whole group. Used to hold
-- AOE casts until nobody would be left out (opt-in hold_aoe_for_group).
--   Self (index 0) always qualifies and never blocks.
--   Trusts skipped -- they auto-follow, so they're always in range.
--   Members in another zone ignored -- an AOE can never reach them, so they must
--     not cause an indefinite hold.
--   Dead members skipped (hpp == 0) -- a corpse can't receive the buff and should
--     not force a wait. Full-HP members still count: HP is irrelevant to buffs.
--   No qualifying members (solo / everyone elsewhere) -> true -> cast normally.
--   exclude: optional {[idx]=true} set of party indices to skip (BRD single-target).
function common.group_in_aoe_range(radius, exclude)
    radius = radius or common.AOE_RADIUS
    local state = common.game_state
    local pz = common.get_party_member_zone(0)
    for i = 1, 5 do
        if not (exclude and exclude[i]) then
            local m = state.party[i]
            if m and not m.is_trust and m.hpp and m.hpp > 0
               and common.get_party_member_zone(i) == pz then
                -- Unresolved entity (nil / <=0) = member not loaded, so out of
                -- AOE range: fail closed to keep the hold guarantee.
                local ei = m.target_index
                if type(ei) ~= 'number' or ei <= 0
                   or not common.is_in_range(ei, radius) then
                    return false
                end
            end
        end
    end
    return true
end

-- os.clock() of the last "gather" party chat line, shared across every
-- hold_aoe_for_group hold point so back-to-back holds (across abilities, or
-- tick after tick while one member stays out of range) don't flood party chat.
local last_gather_announce = 0
local GATHER_ANNOUNCE_THROTTLE = 5.0

-- Tell the party to gather when an AOE cast is being held for hold_aoe_for_group.
-- Throttled to once per GATHER_ANNOUNCE_THROTTLE seconds across ALL callers (not
-- per-ability), so it reads as one reminder line rather than one per held ability.
-- Fires every time the hold is still active once the throttle clears, acting as a
-- periodic reminder rather than a one-shot. Opt-out via hold_aoe_announce: the hold
-- itself is unaffected, only the party chat line is suppressed.
function common.announce_gather(ability_name, settings)
    if settings and settings.hold_aoe_announce == false then return end
    local now = os.clock()
    if (now - last_gather_announce) < GATHER_ANNOUNCE_THROTTLE then
        return
    end
    last_gather_announce = now
    AshitaCore:GetChatManager():QueueCommand(1, string.format('/p Gather together for %s', ability_name))
end

-- Get distance between player and party member
-- Args: party_index (number) - Party member index (1-5)
-- Returns: number (distance in yalms) or nil if error
function common.get_party_member_distance(party_index)
    if not party_index or party_index < 1 or party_index > 5 then
        return nil
    end
    
    local player_entity = targets.get_me()
    if not player_entity then
        return nil
    end
    
    local party = common.get_party()
    if not party or not common.is_party_member_active(party_index) then
        return nil
    end
    
    local target_index = party:GetMemberTargetIndex(party_index)
    if not target_index or target_index == 0 then
        return nil
    end
    
    local member_entity = GetEntity(target_index)
    if not member_entity then
        return nil
    end

    return common.calculate_distance(player_entity, member_entity)
end

-- Resolve a follow-target name to a live distance. Checks party P1-P5 first,
-- then session tracked targets. Zoned-out members keep their slot with a
-- garbage position, so both paths gate on SpawnFlags before measuring.
-- Args: name (string) - Character name (settings.follow_target)
-- Returns: number|nil (distance in yalms), number|nil (party index 1-5, nil for tracked)
function common.get_follow_target_distance(name)
    if not name then return nil end

    local gs = common.game_state
    if gs and gs.party then
        for i = 1, 5 do
            local m = gs.party[i]
            if m and m.name == name then
                local ti = m.target_index
                if not ti or ti == 0 then return nil end
                local ent = GetEntity(ti)
                if not ent or (ent.SpawnFlags or 0) <= 0 then return nil end
                local me = targets.get_me()
                if not me then return nil end
                local distance = common.calculate_distance(me, ent)
                if not distance then return nil end
                return distance, i
            end
        end
    end

    -- Not in party: try session tracked targets. An entity slot can be recycled
    -- when its occupant despawns mid-zone (tracked targets themselves are cleared
    -- on zone change), so require the ServerId to still match.
    for _, tt in pairs(tracked_targets) do
        if tt.name == name then
            local ent = (tt.target_index and tt.target_index ~= 0) and GetEntity(tt.target_index) or nil
            if not ent or ent.ServerId ~= tt.server_id or (ent.SpawnFlags or 0) <= 0 then
                return nil
            end
            local me = targets.get_me()
            if not me then return nil end
            return common.calculate_distance(me, ent), nil
        end
    end

    return nil
end

-- Radial Arcana consumes the luopan, so the Geomancer job's validate_ability
-- gates it on arcana_usable: true only while we are stood in a bubble we can
-- afford to lose. lib/actions/geo.lua recomputes it every tick (it owns the
-- cost/HP rules) and raises arcana_luopan when the bubble out is the throwaway
-- Geo-Voidance one it placed for this. They live on `common` because
-- validate_ability is handed only `common` and `settings` (SCH reads the latter
-- for the AOE stratagem reserve) -- there is nowhere else to hang live state.
-- arcana_sequence additionally holds group 'Geo' buffs off the luopan slot while
-- the teardown/rebuild is in flight.
common.arcana_usable   = false
common.arcana_luopan   = false
common.arcana_sequence = false

-- True while the player is standing inside their own luopan's aura, the only
-- place the luopan-centred Geomancer JAs (Radial Arcana, ...) reach. False with
-- no luopan out.
function common.is_in_luopan_radius()
    local d = common.get_pet_distance_from_member(0)
    -- ponytail: flat 10-yalm base radius; Widened Compass / merits are ignored
    -- until someone asks for them.
    return d ~= nil and d <= 10
end

-- Clear autofollow so a follow-target change stops running at the old target.
function common.reset_autofollow()
    local af = AshitaCore:GetMemoryManager():GetAutoFollow()
    if af then
        af:SetIsAutoRunning(0)
        af:SetFollowTargetIndex(0)
        af:SetFollowTargetServerId(0)
    end
end

-- Get distance between a party member (0 = player) and the pet/luopan.
-- Used by Geo automation to measure luopan drift from the party member who
-- is holding the Geo bubble, rather than always from the caster.
-- Args: party_index (number) - Party member index (0-5)
-- Returns: number (distance in yalms) or nil if member or pet unavailable
function common.get_pet_distance_from_member(party_index)
    local pet_entity = targets.get_pet()
    if not pet_entity then
        return nil
    end

    -- Index 0 is the player: measure from the player's own entity.
    if party_index == 0 then
        local player_entity = targets.get_me()
        if not player_entity then return nil end
        return common.calculate_distance(player_entity, pet_entity)
    end

    if party_index < 1 or party_index > 5 then
        return nil
    end

    local party = common.get_party()
    if not party or not common.is_party_member_active(party_index) then
        return nil
    end

    local target_index = party:GetMemberTargetIndex(party_index)
    if not target_index or target_index == 0 then
        return nil
    end

    local member_entity = GetEntity(target_index)
    if not member_entity then
        return nil
    end

    return common.calculate_distance(member_entity, pet_entity)
end

--[[
    Buff/Debuff Checking
]]--

function common.has_buff(target_index, buff_id)
    if not target_index then return false end
    
    -- Special case: target_index 0 is the player - use the working get_player_buffs() method
    if target_index == 0 then
        local player_buffs = common.get_player_buffs()
        for _, player_buff in ipairs(player_buffs) do
            if player_buff == buff_id then
                return true
            end
        end
        return false
    end
    
    -- For other targets, use party member lookup
    local party = common.get_party()
    if not party then return false end
    
    -- Find party member index and server ID for this target
    local party_index = -1
    local server_id = nil
    for i = 0, 5 do
        if party:GetMemberIsActive(i) == 1 then
            if party:GetMemberTargetIndex(i) == target_index then
                party_index = i
                local ok_server, sid = pcall(function()
                    return party:GetMemberServerId(i)
                end)
                if ok_server then
                    server_id = sid
                end
                break
            end
        end
    end
    
    if party_index == -1 then return false end
    
    -- Check if this is a Trust (server_id >= 0x1000000)
    if server_id and server_id >= 0x1000000 then
        -- Use Trust buff tracking
        local trust_buff_list = common.get_trust_buffs(server_id)
        for _, trust_buff in ipairs(trust_buff_list) do
            if trust_buff == buff_id then
                return true
            end
        end
        return false
    end
    
    -- For regular party members, check buffs via memory pointer
    local ok_ptr, ptr = pcall(function() return party:GetMemberPointer(party_index) end)
    if not ok_ptr or not ptr or ptr == 0 then return false end
    
    local buffs_ptr = ashita.memory.read_uint32(ptr + 0x0C)
    if buffs_ptr == 0 then return false end
    
    for i = 0, 31 do
        local buff = ashita.memory.read_uint16(buffs_ptr + (i * 2))
        if buff == buff_id then
            return true
        end
    end
    
    return false
end

function common.get_player_buffs()
    local ok, player = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer()
    end)
    
    if not ok or not player then
        return {}
    end
    
    local ok_buffs, buffs = pcall(function()
        return player:GetBuffs()
    end)
    
    if not ok_buffs or not buffs then
        return {}
    end
    
    -- Filter out invalid buffs (ID 255 or 0)
    local valid_buffs = {}
    for i = 1, 32 do
        local buff_id = buffs[i]
        if buff_id and buff_id ~= 255 and buff_id > 0 then
            table.insert(valid_buffs, buff_id)
        end
    end
    
    return valid_buffs
end

-- Get party member's current buffs using direct memory reading
-- Args: member_index (number) - Party member index (0-5, where 0 is player)
-- Returns: table of buff IDs (numbers), or empty table on error/trust
function common.get_party_buffs(member_index)
    -- Special case: p0 (player) uses different method
    if member_index == 0 then
        return common.get_player_buffs()
    end
    
    local party = common.get_party()
    if not party then
        return {}
    end
    
    -- Check if member is active
    local ok_active, is_active = pcall(function()
        return party:GetMemberIsActive(member_index)
    end)
    
    if not ok_active or is_active ~= 1 then
        return {}
    end
    
    -- Get the server ID for this party member
    local ok_server, server_id = pcall(function()
        return party:GetMemberServerId(member_index)
    end)
    
    if not ok_server or not server_id or server_id == 0 then
        return {}
    end
    
    -- Trusts have server IDs > 0x1000000 (16777216)
    if server_id >= 0x1000000 then
        -- Return Trust buffs from packet-based tracking
        return trust_buffs[server_id] or {}
    end
    
    -- Get the status icons pointer (direct memory reading)
    local ok_pointer, base_ptr = pcall(function()
        return AshitaCore:GetPointerManager():Get('party.statusicons')
    end)
    
    if not ok_pointer or not base_ptr or base_ptr == 0 then
        common.errorf('Failed to get party status icons pointer for member %d', member_index)
        return {}
    end
    
    -- Dereference the pointer
    local ok_deref, dereferenced_ptr = pcall(function()
        return ashita.memory.read_uint32(base_ptr)
    end)
    
    if not ok_deref or dereferenced_ptr == 0 then
        common.errorf('Failed to dereference status icons pointer')
        return {}
    end
    
    -- Scan through party members (indices 0-4 in memory, which map to p1-p5)
    for i = 0, 4 do
        local member_ptr = dereferenced_ptr + (0x30 * i)
        
        local ok_read, player_id = pcall(function()
            return ashita.memory.read_uint32(member_ptr)
        end)
        
        if ok_read and player_id == server_id then
            -- Found matching server_id, read buffs
            local buffs = {}
            
            -- Read all 32 buff slots using bit manipulation
            for j = 0, 31 do
                local ok_buff, high_bits = pcall(function()
                    return ashita.memory.read_uint8(member_ptr + 8 + math.floor(j / 4))
                end)
                
                if ok_buff then
                    local f_mod = math.fmod(j, 4) * 2
                    high_bits = bit.lshift(bit.band(bit.rshift(high_bits, f_mod), 0x03), 8)
                    
                    local ok_low, low_bits = pcall(function()
                        return ashita.memory.read_uint8(member_ptr + 16 + j)
                    end)
                    
                    if ok_low then
                        local buff_id = high_bits + low_bits
                        
                        if buff_id ~= 255 and buff_id > 0 then
                            table.insert(buffs, buff_id)
                        end
                    end
                end
            end
            
            return buffs
        end
    end
    
    return {}
end

--[[
    Trust Buff Tracking Functions
    Since Trusts' buffs cannot be read from memory, we track them via packets
]]--

-- Haste (buff_id 33) base duration scales with the target's level below 40:
-- verified lv10=43s, lv40=180s -> linear Duration = 4.5667*Level - 2.67 (Plush).
-- Level 40+ gets the flat 180. Only tracked targets carry a known level.
local HASTE_BUFF_ID = 33
local function haste_duration_for_level(level)
    if not level or level >= 40 then return BASE_BUFF_DURATION['Haste'] end
    return 4.5667 * level - 2.67
end

-- Resolve the base duration (seconds) for a buff application, or nil if unknown
-- (unknown = never expires by timer, wear-off packets only — today's behavior).
-- Args: buff_id (number), spell_name (string|nil - ability/spell name when known),
--       server_id (number|nil - target, for level-scaled durations like Haste)
function common.base_buff_duration(buff_id, spell_name, server_id)
    -- Haste lands with a reduced duration on players below level 40. We only
    -- know a target's level after /check, so this applies to tracked targets.
    if (spell_name == 'Haste' or buff_id == HASTE_BUFF_ID) and server_id then
        local tt = tracked_targets[server_id]
        if tt and tt.main_level then
            return haste_duration_for_level(tt.main_level)
        end
    end

    if spell_name and BASE_BUFF_DURATION[spell_name] then
        return BASE_BUFF_DURATION[spell_name]
    end
    if is_song_buff(buff_id) then
        return SONG_DURATION
    end
    if buff_id then
        local buff_name = AshitaCore:GetResourceManager():GetString('buffs.names', buff_id)
        if buff_name and BASE_BUFF_DURATION[buff_name] then
            return BASE_BUFF_DURATION[buff_name]
        end
        -- Debuff backstop: explicit duration, INFINITE (no timer), else 120s for
        -- any other removable debuff.
        local d = BASE_DEBUFF_DURATION[buff_id]
        if d ~= nil then
            return d or nil  -- INFINITE (false) -> no timer
        end
        if REMOVABLE_SET[buff_id] then
            return 120
        end
        -- Unknown status on a packet-only target: cap it so it can't linger forever.
        return UNKNOWN_BUFF_DURATION
    end
    return nil
end

-- Register a pending buff when we initiate a cast on a Trust
-- Args: server_id (number), buff_id (number), spell_name (string|nil - for base
--       duration lookup), spell_id (number|nil - the instance key; job files name
--       abilities with a UI label, so only the id matches what the 0x028 gain loop
--       resolves for the same landing)
function common.register_pending_buff(server_id, buff_id, spell_name, spell_id)
    if not server_id or not buff_id then return end
    
    -- Clean up expired pending buffs first
    local current_time = os.clock()
    local i = 1
    while i <= #pending_buffs do
        if (current_time - pending_buffs[i].timestamp) > PENDING_BUFF_TIMEOUT then
            table.remove(pending_buffs, i)
        else
            i = i + 1
        end
    end
    
    -- Add new pending buff
    table.insert(pending_buffs, {
        server_id = server_id,
        buff_id = buff_id,
        spell_id = spell_id,
        duration = common.base_buff_duration(buff_id, spell_name, server_id),
        timestamp = current_time
    })

end

-- Handle casting completion (packet 0x028, category 4 = spell_finish)
-- Matches the most recent pending buff and adds it to trust_buffs
function common.handle_buff_application()
    if #pending_buffs == 0 then return end

    -- Pop the most recent pending buff; apply_external_buff handles init + dedup.
    -- We are the caster, so the source is our own player server id (per-caster
    -- song slots). game_state.player is refreshed each tick before packets fire.
    local pending = pending_buffs[#pending_buffs]
    table.remove(pending_buffs, #pending_buffs)

    -- An interrupted cast registers a pending buff and never sends the spell_finish
    -- that pops it, so without this a later unrelated spell_finish claims the stale
    -- entry and records a buff the target never received.
    if (os.clock() - pending.timestamp) > PENDING_BUFF_TIMEOUT then return end
    local source_id = common.game_state and common.game_state.player and common.game_state.player.server_id
    common.apply_external_buff(pending.server_id, pending.buff_id, pending.duration, source_id,
        pending.spell_id)
end

-- Directly apply a buff to a Trust's tracked buff list (called from packet detection)
-- Args: server_id (number), buff_id (number), duration (number|nil), source_id (number|nil - caster)
function common.apply_trust_buff(server_id, buff_id, duration, source_id, spell_id)
    if not server_id or server_id < 0x1000000 then return end
    common.apply_external_buff(server_id, buff_id, duration, source_id, spell_id)
end

-- True when server_id is the current pet (refreshed each tick). Packet handlers
-- use this to route the pet's buffs/debuffs into trust_buffs.
function common.is_pet(server_id)
    return server_id ~= nil and server_id ~= 0 and server_id == pet_server_id
end

-- Apply a buff/debuff to the pet's tracked list (called from packet detection).
-- Pets never receive songs, so source_id is unused here but kept for a uniform signature.
function common.apply_pet_buff(server_id, buff_id, duration, source_id, spell_id)
    if not common.is_pet(server_id) then return end
    common.apply_external_buff(server_id, buff_id, duration, source_id, spell_id)
end

-- Drop one tracked instance: its buff_timestamps row plus one matching id from
-- the buff list. The list holds bare ids, so its entries are interchangeable --
-- which one goes doesn't matter, only that the two tables stay in step. Both are
-- always written and cleared together, so a row with no list entry can't happen.
local function remove_buff_instance(server_id, key)
    local times = buff_timestamps[server_id]
    local t = times and times[key]
    if not t then return end

    times[key] = nil
    if not next(times) then buff_timestamps[server_id] = nil end

    local list = trust_buffs[server_id]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == t.id then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then trust_buffs[server_id] = nil end
end

-- Handle buff removal (packet 0x029)
-- Args: server_id (number), buff_id (number)
function common.handle_buff_removal(server_id, buff_id)
    if not server_id or not buff_id then return end

    -- One wear-off drops one instance. The packet names a status id, never which
    -- of two stacked tiers ran out, so the oldest instance of it is the
    -- assumption -- it is the one closest to the end of its own duration.
    local times = buff_timestamps[server_id]
    if times then
        local oldest_key, oldest_at = nil, math.huge
        for key, t in pairs(times) do
            if t.id == buff_id and t.at < oldest_at then
                oldest_key, oldest_at = key, t.at
            end
        end
        if oldest_key then remove_buff_instance(server_id, oldest_key) end
    end

    -- Clear any in-flight removal mark so a later re-application isn't suppressed.
    local sup = removal_suppress[server_id]
    if sup then
        sup[buff_id] = nil
        if not next(sup) then removal_suppress[server_id] = nil end
    end
end

-- Mark one status a na-/Erase spell just tried to cure as in-flight on a Trust /
-- tracked / alliance / pet packet-tracked target, so the removal module stops
-- re-selecting it (removable_after_suppression filters it out) while the cast
-- resolves. Unlike the old hard delete, the status stays tracked: a landed cast's
-- 0x028 msg-83 removes it for real inside the window, while a rejected/resisted
-- cast -- which sends no removal packet -- becomes eligible again after the window
-- and is retried, instead of vanishing from tracking while still on the target.
-- Each removal spell clears one status per cast, so we mark a single match; the
-- base-duration timer covers any we guess wrong. No-op for memory-read party
-- members (their sid isn't in trust_buffs) and for abilities with no debuff_id.
function common.drop_removed_debuff(server_id, ability)
    local ids = ability and ability.debuff_id
    if not server_id or not ids then return end
    local list = trust_buffs[server_id]
    if not list then return end
    if type(ids) ~= 'table' then ids = { ids } end
    local match = {}
    for _, id in ipairs(ids) do match[id] = true end
    for _, tracked_id in ipairs(list) do
        if match[tracked_id] then
            if not removal_suppress[server_id] then removal_suppress[server_id] = {} end
            removal_suppress[server_id][tracked_id] = os.clock()
            return
        end
    end
end

-- Return <buffs> minus any id with an in-flight removal (attempted within
-- REMOVAL_SUPPRESS_WINDOW). Used only by the removal selector -- the panel keeps
-- reading the full trust_buffs list, since the status really is still on the
-- target until a removal packet or the base-duration timer clears it. Expired
-- marks are dropped here (lazy GC) so a genuinely-failed cast retries next tick.
function common.removable_after_suppression(server_id, buffs)
    local sup = server_id and removal_suppress[server_id]
    if not sup or not buffs then return buffs or {} end
    local now = os.clock()
    local out = {}
    for _, id in ipairs(buffs) do
        local at = sup[id]
        if at and (now - at) < REMOVAL_SUPPRESS_WINDOW then
            -- still in flight: hide from the removal selector this tick
        else
            if at then sup[id] = nil end  -- window elapsed: eligible again
            out[#out + 1] = id
        end
    end
    return out
end

-- Clear all Trust buffs and alliance tracking (call on zone change)
function common.clear_trust_buffs()
    trust_buffs = {}
    buff_timestamps = {}
    removal_suppress = {}
    pending_buffs = {}
    member_max_stats = {}
    alliance_member_sids = {}
    pending_raise_flags = {}
end

-- Set pending raise flag for a server_id (called from 0x029 handler when target is dead).
function common.set_pending_raise(server_id)
    if not server_id or server_id == 0 then return end
    pending_raise_flags[server_id] = true
end

-- Returns true if the given server_id has a pending raise flag set.
function common.has_pending_raise(server_id)
    if not server_id or server_id == 0 then return false end
    return pending_raise_flags[server_id] == true
end

-- Explicitly clear the pending raise flag for a server_id.
function common.clear_pending_raise(server_id)
    if not server_id or server_id == 0 then return end
    pending_raise_flags[server_id] = nil
end

-- Check if a server_id belongs to an active alliance member.
-- The set is rebuilt every refresh_game_state() tick.
function common.is_alliance_member(server_id)
    if not server_id or server_id == 0 then return false end
    return alliance_member_sids[server_id] == true
end

-- Evict oldest-start-time songs FROM one caster off a target's buff list until at
-- most keep_n of that caster's songs remain. Song slots are per-caster in FFXI:
-- each bard maintains their own set on a target, so we only ever evict songs whose
-- tracked source matches source_id -- another bard's songs never count here.
-- Slots the caster holds. Only our own job is readable, so every other caster
-- is taken for a main-job Bard -- the same assumption the old flat 2 made.
local function song_slots(source_id)
    local me = common.game_state and common.game_state.player
    if not me or not source_id or source_id ~= me.server_id then return SONG_SLOTS_MAIN end
    local main_job, sub_job = common.get_player_job()
    if main_job ~= BRD_JOB_ID and sub_job == BRD_JOB_ID then return SONG_SLOTS_SUB end
    return SONG_SLOTS_MAIN
end

local function evict_oldest_songs(server_id, source_id, keep_n)
    local times = buff_timestamps[server_id] or {}
    local songs = {}
    for key, t in pairs(times) do
        if is_song_buff(t.id) and t.src == source_id then
            table.insert(songs, key)
        end
    end
    while #songs > keep_n do
        local oldest_i, oldest_at = 1, math.huge
        for i, key in ipairs(songs) do
            local at = times[key] and times[key].at or 0
            if at < oldest_at then oldest_at, oldest_i = at, i end
        end
        local drop    = table.remove(songs, oldest_i)
        local drop_id = times[drop] and times[drop].id
        remove_buff_instance(server_id, drop)
        common.debugf('Song buff %s evicted from %d (caster %d slots full, oldest start time)',
            tostring(drop_id), server_id, source_id)
    end
end

-- Shared helper: insert a buff instance into trust_buffs.
-- Used by both apply_alliance_member_buff and apply_tracked_target_buff.
-- duration   (seconds, optional): base duration for timed expiry; nil = no timer.
-- source_id  (server_id, optional): the caster, for per-caster song slot accounting.
-- spell_id   (optional): the spell that applied it -- the instance key. Two tiers
--   sharing a status id (Ballad + Ballad II) are two effects in-game, and only the
--   spell tells them apart; re-applying the same spell refreshes its own row. It is
--   the spell ID and not the ability name because one landing is detected twice --
--   once through the pending-cast path, once through the 0x028 gain loop -- and
--   only the id reads the same in both (job files carry a UI label for a name).
--   With no id (0x029 carries none) an already-tracked instance of that status is
--   refreshed instead: a second detection of the effect we know about is the
--   likelier reading than a second effect having appeared unseen.
function common.apply_external_buff(server_id, buff_id, duration, source_id, spell_id)
    if not server_id or not buff_id then return end

    if not trust_buffs[server_id] then
        trust_buffs[server_id] = {}
    end

    if not buff_timestamps[server_id] then
        buff_timestamps[server_id] = {}
    end
    local times = buff_timestamps[server_id]

    local function key_for_status()
        for k, t in pairs(times) do
            if t.id == buff_id then return k end
        end
        return nil
    end

    local key
    if spell_id then
        -- Per caster, not per spell: two bards singing the same song on one
        -- target hold two separate instances, and a bare spell key collapses
        -- them into one row -- the second application then hits the refresh
        -- early-out below and is never tracked at all, and evict_oldest_songs
        -- (which counts per src) loses its accounting with it.
        key = 'spell:' .. spell_id .. (source_id and (':' .. source_id) or '')
        -- One landing is detected twice -- pending cast and 0x028 gain -- and
        -- the two resolve different keys whenever only one of them carried a
        -- spell id (a 0x029 gain arriving first keys on the status alone). For
        -- anything but a song that is one effect, not two: refresh the row we
        -- already hold rather than stack a phantom second instance that
        -- count_instances would then read as the target being covered.
        -- Songs are exempt because tiers sharing a status id (Ballad + Ballad II
        -- = two of 196) really are two instances, told apart only by spell id.
        if not times[key] and not is_song_buff(buff_id) then
            key = key_for_status() or key
        end
    else
        key = key_for_status() or ('status:' .. buff_id)
    end

    -- Stamp/refresh the start time on every application; keep a previously
    -- known duration/source when this detection path couldn't resolve one
    -- (0x029 carries no spell id or caster).
    local prev = times[key]
    local row = {
        at  = os.clock(),
        dur = duration  or (prev and prev.dur) or nil,
        src = source_id or (prev and prev.src) or nil,
        id  = buff_id,
    }

    -- Already tracked: the refresh is the whole update.
    if prev then
        times[key] = row
        return
    end

    -- A new song consumes one of the caster's TRUST_SONG_SLOTS song slots on this
    -- target; the game overwrites that caster's oldest song when their slots are
    -- full, so mirror it -- but only when we know the caster (0x029 gives none).
    -- No range math needed: packet handlers only apply songs to targets the action
    -- packet says were actually hit (i.e. in AoE range of the cast).
    -- Run before the new instance is written, so it is neither counted against
    -- the caster's slots nor eligible for eviction itself. Evicting the last
    -- tracked status drops both tables, hence the re-seat below.
    if is_song_buff(buff_id) and source_id then
        evict_oldest_songs(server_id, source_id, song_slots(source_id) - 1)
    end

    buff_timestamps[server_id] = buff_timestamps[server_id] or {}
    trust_buffs[server_id]     = trust_buffs[server_id] or {}
    buff_timestamps[server_id][key] = row
    table.insert(trust_buffs[server_id], buff_id)
end

-- Drop tracked buffs whose base duration has elapsed. Applies to every
-- packet-tracked target -- Trusts, tracked targets, alliance members and the pet
-- (all read from trust_buffs, never from memory) -- since their wear-off packets
-- are unreliable/absent and the timer is the only guaranteed drop signal. Regular
-- party members read buffs from memory each tick, so they're skipped here.
-- Called once per refresh_game_state tick.
function common.expire_timed_buffs()
    local now = os.clock()
    for sid, times in pairs(buff_timestamps) do
        if sid >= 0x1000000 or tracked_targets[sid] or alliance_member_sids[sid]
           or (pet_server_id ~= 0 and sid == pet_server_id) then
            for key, t in pairs(times) do
                if t.dur and (now - t.at) >= t.dur then
                    common.debugf('Timed buff %d expired on %d after %ds', t.id, sid, t.dur)
                    -- By key, not by id: the instance whose own timer ran out is
                    -- the one that goes, not whichever of a stacked pair is older.
                    remove_buff_instance(sid, key)
                end
            end
        end
    end
end

-- Apply a buff to an alliance member (packet-based, reuses trust_buffs table).
function common.apply_alliance_member_buff(server_id, buff_id, duration, source_id, spell_id)
    if not server_id or not buff_id then return end
    if not alliance_member_sids[server_id] then return end
    common.apply_external_buff(server_id, buff_id, duration, source_id, spell_id)
end

-- Get Trust buffs by server_id
-- Args: server_id (number)
-- Returns: table of buff IDs, or empty table
function common.get_trust_buffs(server_id)
    if not server_id then return {} end
    if server_id < 0x1000000 then return {} end  -- Not a Trust
    return trust_buffs[server_id] or {}
end

-- ============================================================================
-- Tracked Target Functions (session-only, outside-party players)
-- ============================================================================

-- Add a tracked target by entity.
-- Args: entity (userdata|table) - The entity to track (must be a PC with SpawnFlags & 0x0001).
--                                 Only ServerId / Name / TargetIndex are read, so a plain
--                                 table stands in fine (see party_share.lua).
--       known  (table|nil)      - Roster row from a trusted source (the shared party list),
--                                 as {main_job, sub_job, main_level, sub_level, max_hp}.
--                                 Supplying it at all means no /check is sent.
-- Returns: boolean - true if added, false if already tracked or invalid
function common.add_tracked_target(entity, known)
    if not entity then return false end

    local server_id = entity.ServerId
    local name      = entity.Name
    if not server_id or server_id == 0 or not name or name == '' then
        return false
    end

    -- Reject if already tracked
    if tracked_targets[server_id] then
        return false
    end

    -- Reject if the target is already in our party
    local party = common.get_party()
    if party then
        for i = 0, 5 do
            if party:GetMemberIsActive(i) == 1 then
                local pid = party:GetMemberServerId(i)
                if pid == server_id then
                    return false
                end
            end
        end
    end

    tracked_targets[server_id] = {
        server_id    = server_id,
        name         = name,
        target_index = entity.TargetIndex or 0,
        main_job     = nil,
        sub_job      = nil,
        main_level   = nil,
        sub_level    = nil,
    }

    -- A player's own client reads job/level straight out of its party list, so a roster
    -- published by someone actually in that party is authoritative: /check would only
    -- re-derive what we already have, and needs the target in range to answer at all.
    -- Any roster at all suppresses the check, level 0 included -- that row means the
    -- member is /anon, and a check would come back just as empty.
    if known then
        common.set_tracked_target_info(server_id, known)
        common.printf('Now tracking: %s (%s, from shared party list)', name,
            (known.main_level and known.main_level > 0)
                and string.format('Lv%d', known.main_level)
                or 'job/level hidden')
        return true
    end

    pending_checks[server_id] = os.clock()
    AshitaCore:GetChatManager():QueueCommand(1, string.format('/check %s', name))

    common.printf('Now tracking: %s (checking level...)', name)
    return true
end

-- Write a roster row onto a tracked target: job/level in the same "0 means unknown" shape
-- handle_check_packet uses, plus the real max HP the publisher's own client knows (a
-- non-party entity exposes only HP percent, so that is otherwise learned only by catching
-- the member at 100% in build_member_snapshot). Also refreshes an entry we already hold,
-- so a level-up on the other box lands here.
function common.set_tracked_target_info(server_id, info)
    local tt = tracked_targets[server_id]
    if not tt or not info then return end

    -- Ahead of the level guard: /anon hides job and level, never HP.
    if info.max_hp and info.max_hp > 0 then
        member_max_stats[server_id] = member_max_stats[server_id] or {}
        member_max_stats[server_id].max_hp = info.max_hp
    end

    if not info.main_level or info.main_level <= 0 then return end

    tt.main_job   = (info.main_job  and info.main_job  > 0) and info.main_job  or nil
    tt.sub_job    = (info.sub_job   and info.sub_job   > 0) and info.sub_job   or nil
    tt.main_level = info.main_level
    tt.sub_level  = (info.sub_level and info.sub_level > 0) and info.sub_level or nil
    pending_checks[server_id] = nil
end

-- Handle incoming packet 0x0C9 (character check response).
-- Sub-type byte at 0x00A: 0x03 = first packet (no data), 0x01 = second packet (has data).
-- Layout of the data packet:
--   0x022  main_job  (uint8)
--   0x023  sub_job   (uint8)
--   0x024  main_level (uint8)
--   0x025  sub_level  (uint8)
function common.handle_check_packet(packet)
    if not packet or #packet < 0x26 then return end

    local sub_type = struct.unpack('B', packet, 0x0A + 1)
    if sub_type ~= 0x01 then return end

    local main_job  = struct.unpack('B', packet, 0x022 + 1)
    local sub_job   = struct.unpack('B', packet, 0x023 + 1)
    local main_level = struct.unpack('B', packet, 0x024 + 1)
    local sub_level  = struct.unpack('B', packet, 0x025 + 1)
    if not main_level or main_level == 0 then return end

    local now = os.clock()
    for sid, timestamp in pairs(pending_checks) do
        if (now - timestamp) > PENDING_CHECK_TIMEOUT then
            pending_checks[sid] = nil
        elseif tracked_targets[sid] then
            tracked_targets[sid].main_job   = (main_job  and main_job  > 0) and main_job  or nil
            tracked_targets[sid].sub_job    = (sub_job   and sub_job   > 0) and sub_job   or nil
            tracked_targets[sid].main_level = main_level
            tracked_targets[sid].sub_level  = (sub_level and sub_level > 0) and sub_level or nil
            pending_checks[sid] = nil
            common.debugf('[Check] %s resolved: job=%d/%d lv=%d/%d',
                tracked_targets[sid].name,
                main_job or 0, sub_job or 0, main_level, sub_level or 0)
            return
        end
    end
end

-- Remove a tracked target by server_id.
function common.remove_tracked_target(server_id)
    if not server_id then return end
    if tracked_targets[server_id] then
        local name = tracked_targets[server_id].name
        tracked_targets[server_id] = nil
        -- Also clean buff tracking for this target
        trust_buffs[server_id] = nil
        buff_timestamps[server_id] = nil
        member_max_stats[server_id] = nil
        common.printf('Stopped tracking: %s', name or tostring(server_id))
    end
end

-- Remove a tracked target by name.
function common.remove_tracked_target_by_name(name)
    if not name then return end
    for sid, tt in pairs(tracked_targets) do
        if tt.name == name then
            common.remove_tracked_target(sid)
            return
        end
    end
end

-- Get the tracked targets table (read-only reference).
function common.get_tracked_targets()
    return tracked_targets
end

-- Get tracked target buffs (uses trust_buffs since we track via packets).
function common.get_tracked_target_buffs(server_id)
    if not server_id then return {} end
    return trust_buffs[server_id] or {}
end

-- Apply a buff to a tracked target (packet-based, reuses trust_buffs table).
function common.apply_tracked_target_buff(server_id, buff_id, duration, source_id, spell_id)
    if not server_id or not buff_id then return end
    if not tracked_targets[server_id] then return end
    common.apply_external_buff(server_id, buff_id, duration, source_id, spell_id)
end

-- Check if a server_id belongs to a tracked target.
function common.is_tracked_target(server_id)
    if not server_id then return false end
    return tracked_targets[server_id] ~= nil
end

--[[
    Debug: Show all recast timers
]]--

function common.show_recast_timers()
    common.printf('=== Recast Timer Debug ===')
    
    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then
        common.errorf('Failed to get recast manager')
        return
    end
    
    -- Show Job Ability Recasts
    common.printf('Job Ability Recast Timers (slots 0-31):')
    local ability_count = 0
    for i = 0, 31 do
        local ok_id, timer_id = pcall(function()
            return recast_mgr:GetAbilityTimerId(i)
        end)
        
        local ok_timer, timer = pcall(function()
            return recast_mgr:GetAbilityTimer(i)
        end)
        
        if ok_id and ok_timer and timer_id and timer_id > 0 and timer and timer > 0 then
            local recast_seconds = timer / 60.0
            common.printf('  Slot[%d]: TimerID=%d, RawTimer=%d, Recast=%.1fs', 
                i, timer_id, timer, recast_seconds)
            ability_count = ability_count + 1
        end
    end
    
    if ability_count == 0 then
        common.printf('  (No active ability recasts)')
    end
    
    -- Show Spell Recasts
    common.printf('Spell Recast Timers (IDs 0-1023):')
    local spell_count = 0
    for spell_id = 0, 1023 do
        local ok_timer, timer = pcall(function()
            return recast_mgr:GetSpellTimer(spell_id)
        end)
        
        if ok_timer and timer and timer > 0 then
            local recast_seconds = timer / 60.0
            common.printf('  SpellID=%d, RawTimer=%d, Recast=%.1fs', 
                spell_id, timer, recast_seconds)
            spell_count = spell_count + 1
        end
    end
    
    if spell_count == 0 then
        common.printf('  (No active spell recasts)')
    end
    
    common.printf('==========================')
end

--[[
    Status Ailment Blocking Checks
]]--

-- Statuses that stop the player acting at all -- not just one command family the
-- way Silence and Amnesia do. Under any of these the server rejects spells,
-- abilities, items, ranged attacks and /heal alike, and the player cannot move,
-- so automation pauses outright rather than burning the action throttle on
-- commands that can only fail. status_effects.sql ids: Sleep 2 / Sleep II 19
-- (Sleepga, Lullaby, sleep procs), Petrification 7, Stun 10, Charm 14 / 17,
-- Terror 28 (no action AND no movement).
common.INCAPACITATING_STATUS = { 2, 7, 10, 14, 17, 19, 28 }

-- Whether any of them is up on the player.
-- Returns: boolean
function common.is_incapacitated()
    return require('lib.core.action_core').has_any_buff(
        common.get_player_buffs(), common.INCAPACITATING_STATUS)
end

-- Check if player has Amnesia (blocks Job Abilities)
-- Returns: boolean
function common.has_amnesia()
    return common.has_buff(0, 16)  -- Amnesia buff_id = 16
end

-- Check if player has Silence -- or Mute, which blocks magic the same way but is
-- a separate status the na-spells don't share (Silena won't touch it).
-- Returns: boolean
function common.has_silence()
    return common.has_buff(0, 6) or common.has_buff(0, 29)  -- Silence / Mute
end

-- Check if a command is currently blocked -- by movement (any command) or by a
-- status ailment (Silence/Mute on /ma, Amnesia on /ja and /pet). Statuses that
-- block *everything* (Sleep, Stun, Terror, ...) are not checked here: the tick
-- loop's is_incapacitated() guard has already returned before any module runs.
-- Args:
--   command (string or function) - Command string or function that generates one
-- Returns: string or nil - 'Moving' / 'Silence' / 'Amnesia', or nil if not blocked
function common.is_command_blocked(command)
    -- Get command string if it's a function
    local command_str = command
    if type(command) == 'function' then
        -- Call with dummy parameter to get command string
        command_str = command(0)
    end
    
    if not command_str or type(command_str) ~= 'string' then
        return nil  -- Can't determine, assume not blocked
    end
    
    -- No abilities fire while moving.
    if common.is_player_moving() then
        return 'Moving'
    end

    -- Check command type
    if command_str:match('^/ma ') then
        -- Magic command - blocked by Silence
        if common.has_silence() then
            return 'Silence'
        end
    elseif command_str:match('^/ja ') or command_str:match('^/pet ') then
        -- Job Ability command - blocked by Amnesia. /pet counts: maneuvers,
        -- Ready moves, Blood Pacts and the send-pet abilities are all JAs.
        if common.has_amnesia() then
            return 'Amnesia'
        end
    end
    
    return nil  -- Not blocked
end

--[[
    DRY Helper Functions for Action Modules
]]--

-- Check if a spell or job ability has been learned by the player.
-- Spells (/ma) check HasSpell(spell_id). Job abilities check HasAbility only when
-- the definition carries an ability_id (the raw abilities.sql id; +512 converts to
-- the client's JA resource id) -- set it on merit-unlocked JAs like Diabolic
-- Eye so automation skips them until merited. JAs without ability_id (and
-- items) are always treated as known.
-- Args:   ability (table) - Ability definition with command and optional
--                           spell_id/ability_id fields
-- Returns: boolean (true if the ability can be used / spell is known)
function common.has_spell_learned(ability)
    if not ability then return false end
    local cmd = type(ability.command) == 'function' and ability.command(0) or ability.command
    if not cmd or not cmd:match('^/ma%s') then
        if not ability.ability_id then return true end            -- JA/item, no id to check
        local ok, known = pcall(function()
            return AshitaCore:GetMemoryManager():GetPlayer():HasAbility(ability.ability_id + 512)
        end)
        if not ok then return true end  -- assume known on error
        return known
    end
    if not ability.spell_id then return true end                  -- no id to check
    local ok, known = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer():HasSpell(ability.spell_id)
    end)
    if not ok then return true end  -- assume known on error
    return known
end

-- ============================================================================
-- Blue Magic Set-Spell Tracking
-- ============================================================================

-- BLU spells only work while equipped in the set-spell list. The client keeps
-- that list in memory (the same signature-scanned buffer the blusets addon
-- reads); slot values are (spell_id - 512), 0 = empty. Sidekick only READS the
-- list -- equipping spells is left to the user / blusets.
local BLU_SET_SIG    = 'C1E1032BC8B0018D????????????B9????????F3A55F5E5B'
local blu_set_offset = false  -- false = not scanned yet, nil = scan failed
local blu_set_cache  = { at = nil, ids = nil }

-- Set of equipped blue magic spell ids ({ [549] = true, ... }), or nil when
-- the buffer can't be read (signature scan failed, zoning). Reads are cached
-- for 0.5s since both the UI and every automation tick call this.
function common.get_equipped_blue_spells()
    local now = os.clock()
    if blu_set_cache.at and (now - blu_set_cache.at) < 0.5 then
        return blu_set_cache.ids
    end
    blu_set_cache.at  = now
    blu_set_cache.ids = nil

    if blu_set_offset == false then
        local addr = ashita.memory.find('FFXiMain.dll', 0, BLU_SET_SIG, 10, 0)
        if addr and addr ~= 0 then
            -- The scanned dword is a static offset; keep the value, not the pointer.
            blu_set_offset = require('ffi').cast('uint32_t*', addr)[0]
        else
            blu_set_offset = nil
            common.warnf('Blue magic set-spell signature not found; equipped-spell gating disabled.')
        end
    end
    if not blu_set_offset then return nil end

    local ok, ids = pcall(function()
        local ptr = ashita.memory.read_uint32(AshitaCore:GetPointerManager():Get('inventory'))
        if ptr == 0 then return nil end
        ptr = ashita.memory.read_uint32(ptr)
        if ptr == 0 then return nil end
        local main_blu = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob() == 16
        local slots = ashita.memory.read_array(ptr + blu_set_offset + (main_blu and 0x04 or 0xA0), 0x14)
        local set = {}
        for _, v in ipairs(slots) do
            if v and v > 0 then set[v + 512] = true end
        end
        return set
    end)
    if ok then blu_set_cache.ids = ids end
    return blu_set_cache.ids
end

-- True when `ability` is a blue magic SPELL that is not in the equipped
-- set-spell list, so automation must skip it (the UI still shows the row,
-- grayed, and leaves it selectable). JAs carrying magic = 'blue' (Diffusion,
-- Unbridled Learning) aren't set spells, so only /ma commands are checked.
-- Fails open: when the list can't be read this returns false, so a failed
-- signature scan can't silently disable all BLU automation.
function common.is_blue_magic_unequipped(ability)
    if not ability or ability.magic ~= 'blue' or not ability.spell_id then return false end
    -- Unbridled Learning spells are unlocked by the JA, not the set-spell list,
    -- so the equipped check never applies to them.
    if ability.requires_precast == 'Unbridled Learning' then return false end
    local cmd = type(ability.command) == 'function' and ability.command(0) or ability.command
    if not cmd or not cmd:match('^/ma%s') then return false end
    local set = common.get_equipped_blue_spells()
    if not set then return false end
    return not set[ability.spell_id]
end

-- Filter abilities by level, disabled status, and pet requirements
-- Args:
--   abilities (table) - List of abilities to filter
--   settings (table) - Settings table with disabled flags
--   main_level (number) - Player's main job level
--   sub_level (number) - Player's sub job level
--   job_def (table|nil) - Job definition with optional validate_ability function
--   party_buff_gates (table|nil) - Session-only per-target Combat/Idle overrides
--     (see common.target_gate_ok); when omitted the idle_only/combat_only gate
--     applies to the whole ability as before.
-- Returns: table - Filtered and sorted abilities (by cost descending)
function common.filter_abilities_by_level(abilities, settings, main_level, sub_level, job_def, party_buff_gates)
    local available_abilities = {}
    
    -- Safety check: return empty table if abilities is nil
    if not abilities then
        return available_abilities
    end

    for _, ability in ipairs(abilities) do
        -- Safely get level value
        local required_level = 0
        if type(ability.level) == 'number' then
            required_level = ability.level
        elseif type(ability.level) == 'function' then
            common.errorf('[filter_abilities] ERROR: ability.level is a function for %s!', ability.name)
            goto continue
        end
        
        -- Determine which level to check based on ability source
        local player_level = ability.is_main_job == false and (sub_level or 0) or (main_level or 0)
        local job_source = ability.is_main_job == false and 'subjob' or 'main job'

        -- Check if ability requires main job only (e.g., Geo spells)
        if ability.main_job_only and ability.is_main_job == false then
            -- Skip main-job-only abilities when from subjob
            goto continue
        end
        
        -- Check if ability is disabled in settings. An ungrouped group is keyed
        -- per ability name (same rule buff.lua uses) -- the UI writes only that
        -- key once ungrouped, and a stale disabled_group_<group> would otherwise
        -- filter out every tier with no way left to clear it.
        local disabled_key
        if ability.group and settings['ungrouped_' .. ability.group] ~= true then
            disabled_key = 'disabled_group_' .. ability.group
        else
            disabled_key = 'disabled_' .. ability.name:gsub(' ', '_')
        end
        -- Default to enabled (false) if key doesn't exist (nil)
        local is_disabled = settings[disabled_key]
        if is_disabled == nil then
            is_disabled = false  -- Default new abilities to enabled
        end
        
        local gate_bypassed = common.ability_gate_bypassed_by_target_override(ability, settings, party_buff_gates)

        if is_disabled then
        elseif not common.has_spell_learned(ability) then
        elseif common.is_blue_magic_unequipped(ability) then
        elseif ability.requires_pet and not targets.get_pet() then
        elseif ability.requires_equipped_ammo and not common.is_ammo_equipped(ability.requires_equipped_ammo) then
        elseif ability.requires_item and not common.find_equippable_item(ability.requires_item) then
        elseif common.is_ability_idle_only(ability, settings) and not common.is_idle() and not gate_bypassed then
        elseif common.is_ability_combat_only(ability, settings) and not common.is_combat() and not gate_bypassed then
        elseif common.ability_targets_bt(ability) and not common.is_combat() then
        elseif job_def and job_def.validate_ability and not job_def.validate_ability(ability, common, settings) then
        elseif required_level <= player_level then
            table.insert(available_abilities, ability)
        end
        
        ::continue::
    end
    
    -- Sort by explicit priority first, then cost descending.
    -- Most abilities leave priority unset/0, so existing behavior stays the same.
    -- Priority may be negative, to sort below every unprioritised (0) ability.
    -- One uniform value across all tiers of a group is fine (NIN 'tonko'); DIFFERENT
    -- values within one group are not -- buff.lua's default-tier auto-select takes the
    -- first grouped tier and expects highest cost first. Keep the two keys plain: a
    -- per-group special-case here would make the comparator intransitive (sort crash).
    table.sort(available_abilities, function(a, b)
        local a_priority = type(a.priority) == 'number' and a.priority or 0
        local b_priority = type(b.priority) == 'number' and b.priority or 0
        if a_priority ~= b_priority then
            return a_priority > b_priority
        end

        local a_cost = type(a.cost) == 'number' and a.cost or 0
        local b_cost = type(b.cost) == 'number' and b.cost or 0
        return a_cost > b_cost
    end)
    
    return available_abilities
end

-- Build command string from ability definition
-- Args:
--   ability (table) - Ability definition with command field
--   party_index (number|nil) - party index 0-5 for p0-p5
-- Returns: string - Command string or nil
function common.build_ability_command(ability, party_index)
    local command = nil
    
    if type(ability.command) == 'function' then
        -- If party_index is provided, convert party index (0-5) to server ID
        if party_index ~= nil then
            local party = common.get_party()
            if party then
                -- Convert party index to server ID
                local server_id = party:GetMemberServerId(party_index)
                if server_id and server_id > 0 then
                    command = ability.command(server_id)
                end
            end
        end
    elseif type(ability.command) == 'string' then
        command = ability.command
    end
    
    return command
end

-- Build command for tracked targets (outside-party) using server_id directly.
-- Args:
--   ability (table) - Ability definition with command field
--   server_id (number) - Server ID of the tracked target
-- Returns: string - Command string or nil
function common.build_ability_command_for_target(ability, server_id)
    if not ability or not server_id or server_id == 0 then return nil end

    if type(ability.command) == 'function' then
        return ability.command(server_id)
    elseif type(ability.command) == 'string' then
        return ability.command
    end

    return nil
end

-- ============================================================================
-- Target Modifier Management (Pianissimo, Entrust, etc.)
-- ============================================================================

-- Check if target modifier ability (like Pianissimo or Entrust) is needed
-- and return command to use it if necessary
-- Args:
--   job_def (table) - Job definition containing abilities
--   settings (table) - Addon settings
--   main_level (number) - Main job level
--   sub_level (number) - Sub job level
-- Returns: table|nil - {command, description} if modifier needs to be used, nil otherwise
-- ============================================================================
-- Scheduled mid-cast buff removal
-- Used by Bard Pianissimo fast-casting (strip Pianissimo 409 so an area song
-- keeps its shorter cast but still lands as area) and Ninja "Cast with 1 Shadow"
-- (strip Copy Image 66 so Utsusemi recast at 1 shadow applies cleanly). After the
-- spell is cast, a /debuff command is queued to fire ~1s into the cast. It must
-- fire DURING the cast, so it runs from the tick loop ahead of the is_casting()
-- guard rather than through the throttled action pipeline. Only one is pending at
-- a time (only one spell casts at once). Requires the Debuff addon (/debuff).
-- ============================================================================
local pending_removal = nil  -- { command = string, deadline = number } or nil

function common.schedule_command_removal(command, delay)
    pending_removal = { command = command, deadline = os.clock() + (delay or 1.0) }
end

function common.process_scheduled_removal()
    if pending_removal and os.clock() >= pending_removal.deadline then
        local command = pending_removal.command
        pending_removal = nil
        AshitaCore:GetChatManager():QueueCommand(0, command)
        return true
    end
    return false
end

function common.check_target_modifier(job_def, settings, main_level, sub_level)
    -- Check if job has target_modifier abilities defined
    if not job_def.abilities.target_modifier or #job_def.abilities.target_modifier == 0 then
        return nil
    end
    
    -- Get the first (and typically only) target modifier ability
    local modifier_ability = job_def.abilities.target_modifier[1]
    
    -- Check if we already have the modifier buff active
    if common.has_buff(0, modifier_ability.buff_id) then
        -- We have the buff, ready to cast the modified spell/song
        return nil
    end
    
    -- We don't have the buff, check if we can use the modifier ability
    -- Determine the appropriate player level to use for gating
    local player_level = main_level
    if modifier_ability.is_main_job == false then
        player_level = sub_level or main_level
    end

    -- Check level requirement
    if modifier_ability.level and modifier_ability.level > player_level then
        return nil
    end
    
    -- Check if ability is disabled in settings
    local key = 'disabled_' .. modifier_ability.name:gsub(' ', '_')
    if settings[key] == true then
        return nil
    end
    
    -- Check combat_only / idle_only flags (user-driven via settings)
    if common.is_ability_combat_only(modifier_ability, settings) and not common.is_combat() then
        return nil
    end
    if common.is_ability_idle_only(modifier_ability, settings) and not common.is_idle() then
        return nil
    end
    
    -- Check if blocked by status ailments
    local blocked_by = common.is_command_blocked(modifier_ability.command)
    if blocked_by then
        return nil
    end
    
    -- Check resource cost
    local action_core = require('lib.core.action_core')
    if not action_core.has_resource(job_def.resource_type, modifier_ability.cost or 0) then
        return nil
    end
    
    -- Check cooldown if ability has a recast ID
    if modifier_ability.recast_id then
        local is_ready = action_core.is_ability_ready(modifier_ability.recast_id)
        if not is_ready then
            return nil
        end
    end
    
    -- Build and return the command
    local command = common.build_ability_command(modifier_ability, 0)
    if command then
        return {
            command = command,
            description = string.format('Using %s for party targeting', modifier_ability.name)
        }
    end
    
    return nil
end

-- ============================================================================
-- Scholar Stratagem Pre-Cast Management
-- ============================================================================

-- Scholar Arts tax the OPPOSITE magic school by 20%:
--   Dark Arts / Addendum: Black up  → White Magic costs base + floor(base * 0.20)
--   Light Arts / Addendum: White up → Black Magic costs base + floor(base * 0.20)
-- Nothing else is affected (ninjutsu, songs, summoning, blue, geomancy, JAs, items).
-- Mirrors battleutils::CalculateSpellCost, which adds the WHITE/BLACK_MAGIC_COST mod as
-- `cost += (int16)(base * mod / 100.0f)` — a C cast, so the tax truncates, never rounds up.
-- Keyed off the spell's Type from the resource manager (1 = white, 2 = black) rather
-- than a hardcoded spell list, so it covers subjob spells and future additions too.
local ARTS_TAX_PCT = 20         -- WHITE/BLACK_MAGIC_COST mod granted by the opposing Arts
local ARTS_LIGHT = {358, 401}   -- Light Arts / Addendum: White  → taxes black magic
local ARTS_DARK  = {359, 402}   -- Dark Arts  / Addendum: Black  → taxes white magic
local TABULA_RASA = 377         -- Cancels the Arts cost penalty (see below)
local SPELL_TYPE_WHITE = 1      -- spells.dat magic type, as GetSpellById().Type
local SPELL_TYPE_BLACK = 2

-- Args:
--   ability (table) – ability definition with .cost and .spell_id
-- Returns: number (arts-taxed cost, or the base cost when no tax applies)
function common.arts_adjusted_cost(ability)
    if not ability or not ability.cost then return 0 end
    if not ability.spell_id then return ability.cost end

    -- Buff check first: no arts up is the common case (every non-SCH), and it skips the
    -- resource lookup that would otherwise run per ability per UI frame.
    local action_core = require('lib.core.action_core')
    local player_buffs = common.get_player_buffs()
    local taxed_type
    if action_core.has_any_buff(player_buffs, ARTS_DARK) then
        taxed_type = SPELL_TYPE_WHITE
    elseif action_core.has_any_buff(player_buffs, ARTS_LIGHT) then
        taxed_type = SPELL_TYPE_BLACK
    else
        return ability.cost
    end

    -- Tabula Rasa suppresses the penalty: light_arts.lua / dark_arts.lua skip the +20 mod
    -- while it is up, and tabula_rasa.lua subtracts 30 from that same mod. Either way the
    -- opposing school is never taxed during TR, so treat the base cost as the real one.
    if action_core.has_any_buff(player_buffs, TABULA_RASA) then return ability.cost end

    -- Unknown id → nil spell; fall back to the base cost rather than guessing a school.
    local spell = AshitaCore:GetResourceManager():GetSpellById(ability.spell_id)
    if not spell or spell.Type ~= taxed_type then return ability.cost end

    return ability.cost + math.floor(ability.cost * ARTS_TAX_PCT / 100)
end

-- True when a stratagem is allowed to act on this ability at all. A strat carrying
-- `spell_ids` (SCH Accession) only works on the spells the server flags for it; matching
-- the magic colour and type is not enough. Strats without the field apply to everything
-- their colour/type already matched.
-- Args:
--   strat   (table) – stratagem definition from job_def.abilities.precast
--   ability (table) – ability definition being cast
-- Returns: boolean
function common.stratagem_applies(strat, ability)
    if not strat.spell_ids then return true end
    local id = ability and ability.spell_id
    if not id then return false end
    for _, sid in ipairs(strat.spell_ids) do
        if sid == id then return true end
    end
    return false
end

-- The magic colour / type match: whether a stratagem may apply to an ability at all.
-- Used by the S popup when OFFERING a stratagem (get_available_stratagems in
-- components.lua) and by the buff-already-up path in effective_ability_cost -- without
-- it there, a black Parsimony would halve the budgeted cost of a white Cure. spell_ids
-- is a separate, narrower gate and stays in common.stratagem_applies.
function common.stratagem_magic_matches(strat, ability)
    if strat.magic and strat.magic ~= (ability and ability.magic) then return false end
    if strat.magic_types then
        local mt = ability and ability.magic_type
        if not mt then return false end
        for _, t in ipairs(strat.magic_types) do
            if t == mt then return true end
        end
        return false
    end
    return true
end

-- Calculate the effective MP cost of an ability considering stratagems.
-- When a stratagem with an mp_modifier (e.g. Penury 0.5x, Accession 2.0x) is assigned
-- to the ability OR its buff is already up, the base cost is multiplied by it.
-- Checks both ability.name and ability.group as lookup keys (the UI stores stratagem
-- assignments under the group name for grouped abilities like Protect/Shell).
-- Args:
--   ability  (table)  – ability definition with .name, .cost, and optionally .group
--   settings (table)  – addon settings (contains stratagem_settings)
--   job_def  (table)  – job definition (contains abilities.precast list)
-- The Scholar Arts tax and a stratagem modifier never stack: server-side
-- (battleutils::CalculateSpellCost) Penury/Parsimony/Accession/Manifestation all clear
-- `applyArts`, so a cost-modifying stratagem replaces the Arts penalty instead of
-- compounding with it. Only when no mp_modifier stratagem applies does the tax apply.
-- Returns: number (modified cost, or the arts-adjusted ability.cost if no stratagems apply)
function common.effective_ability_cost(ability, settings, job_def)
    if not ability or not ability.cost then return 0 end

    -- Strat list first: it is the cheap check and it is nil for most jobs, so only the
    -- four that own a precast list ever reach the buff read below.
    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return common.arts_adjusted_cost(ability) end

    -- Try ability.name first, then ability.group as fallback. May legitimately come back
    -- nil now: a buff that is already up modifies the cost with nothing assigned -- so a
    -- missing stratagem_settings table can NOT short-circuit here. It is created lazily by
    -- the S popup, and heal.execute_aoe raises Accession without ever touching that popup,
    -- which is exactly the player who has none.
    local sset = settings and settings.stratagem_settings
    local ss   = sset and (sset[ability.name] or (ability.group and sset[ability.group]))

    -- A strat counts when the user assigned it OR its buff is already up: the server
    -- charges the modified cost for whichever spell consumes the buff, whether or not
    -- Sidekick was the one that planned it (heal.execute_aoe raises Accession itself, and
    -- the player can raise one by hand). The buff half additionally needs the colour/type
    -- match the S popup would have applied, which the assigned half already carries.
    -- Modifiers are multiplicative and commutative (Accession 2.0x * Penury 0.5x = 1.0x).
    -- ONE pass over strat_defs, so a strat that is both assigned and active is applied
    -- once rather than squared.
    -- Lazy require -- action_core requires common.
    local action_core = require('lib.core.action_core')
    local buffs = common.game_state.player and common.game_state.player.buffs
    local modifier, modified = 1.0, false
    -- stratagem_applies is tested LAST: it is the expensive gate (Accession's spell_ids
    -- is a ~50-entry linear scan) and this runs per ability per tick and per UI frame.
    -- Pure `and` reordering -- none of these have side effects.
    for _, strat in ipairs(strat_defs) do
        if strat.mp_modifier
            and ((ss and ss[strat.name])
                 or (action_core.has_any_buff(buffs, strat.buff_id)
                     and common.stratagem_magic_matches(strat, ability)))
            and common.stratagem_applies(strat, ability) then
            modifier = modifier * strat.mp_modifier
            modified = true
        end
    end
    -- Flag rather than `modifier ~= 1.0`: Accession 2.0x * Penury 0.5x multiplies back out
    -- to 1.0 and still is the thing that suppressed the Arts tax.
    if not modified then return common.arts_adjusted_cost(ability) end
    return math.floor(ability.cost * modifier)
end

-- The half of a precast JA's usability that only a job/level change can alter:
-- on-level, meritted (has_spell_learned reads ability_id), and not a main-job JA
-- supplied by the subjob. Split from the recast so callers can tell "unusable for a
-- few seconds" (hold the spell) from "unusable until you re-level" (don't hold).
function common.precast_permanently_usable(strat, main_level, sub_level)
    if strat.main_job_only and strat.is_main_job == false then return false end
    local level = strat.is_main_job == false and (sub_level or 0) or (main_level or 0)
    if strat.level and level < strat.level then return false end
    return common.has_spell_learned(strat)
end

-- A required precast (SCH Enlightenment) exists only to satisfy its spell's
-- requires_buff, so don't burn the JA when that is already met another way
-- (Addendum: White up). The assignment stays configured for when the stance changes.
local function precast_redundant(strat, ability, player_buffs)
    if not strat.precast_required then return false end
    return require('lib.core.action_core').has_any_buff(player_buffs, ability and ability.requires_buff)
end

-- Stratagem charges a caller may actually spend. With "Hold a Stratagem for AOE"
-- on, one charge is fenced off for Scholar's Accession AOE heal, so every other
-- consumer reads one fewer -- a lone charge reads as none. The AOE heal itself is
-- the reserve's consumer and reads game_state.stratagems directly instead.
-- heal_aoe_enabled is load-bearing, not belt-and-braces: with AOE Healing off there is
-- nothing to reserve FOR, and the checkbox that clears the reserve lives on an ability
-- row that config.lua only draws while the section is open AND enabled -- so a reserve
-- left set would quietly starve Addendum: White and every assigned precast forever,
-- with no visible control to undo it.
function common.spendable_stratagems(settings)
    local n = (common.game_state and common.game_state.stratagems) or 0
    if settings and settings.stratagem_reserve_aoe and settings.heal_aoe_enabled then n = n - 1 end
    return n > 0 and n or 0
end

-- Check if stratagem-style JAs need to fire before casting a spell (Scholar
-- stratagems, DRK Nether Void). Each automation tick, this returns the NEXT
-- action to take:
--   nil                    → no stratagems assigned OR all strat buffs active → cast the spell
--   {command, description} → fire this stratagem JA this tick; caller returns it, re-checks next tick
--   false                  → stratagems assigned, "Hold for Stratagem" ON, but the strat
--                            cannot fire (not enough charges, wrong arts, blocked) → skip ability
--                            (when hold is OFF this path returns nil instead → cast without the strat)
-- Checks both ability_key (ability.name) and the optional group key (ability.group)
-- since the UI stores assignments under the group name for grouped buffs.
-- Args:
--   job_def     (table)  – job definition (contains abilities.precast list)
--   settings    (table)  – addon settings (contains stratagem_settings)
--   ability_key (string) – primary lookup key (typically ability.name)
--   ability     (table)  – optional ability table; when provided, ability.group is used as fallback key
function common.check_stratagem(job_def, settings, ability_key, ability)
    if not settings or not settings.stratagem_settings then return nil end

    -- Try primary key first, then group as fallback
    local resolved_key = ability_key
    local ss = settings.stratagem_settings[ability_key]
    if not ss and ability and ability.group then
        ss = settings.stratagem_settings[ability.group]
        resolved_key = ability.group
    end
    if not ss then return nil end

    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return nil end

    -- "Hold for Stratagem": when enabled, skip the spell until the stratagem
    -- can fire. When disabled (default), a stratagem that can't fire falls
    -- through and the spell is cast without it.
    local hold = settings.stratagem_hold and settings.stratagem_hold[resolved_key] == true
    local unavailable = nil          -- value returned when a stratagem can't fire
    if hold then unavailable = false end

    -- Get player buffs once for all checks
    local player_buffs = common.get_player_buffs()

    -- Find assigned stratagems whose buff is NOT yet active.
    -- Iterate strat_defs in definition order (not pairs(ss)) so that
    -- the chosen stratagem is deterministic when multiple are assigned.
    local missing = {}
    for _, strat in ipairs(strat_defs) do
        if ss[strat.name] and common.stratagem_applies(strat, ability)
           and not precast_redundant(strat, ability, player_buffs) then
            local buff_active = false
            for _, pb in ipairs(player_buffs) do
                if pb == strat.buff_id then
                    buff_active = true
                    break
                end
            end
            if not buff_active then
                table.insert(missing, strat)
            end
        end
    end

    -- All strat buffs active → ready to cast the spell
    if #missing == 0 then return nil end

    -- Fire the first missing stratagem
    local strat = missing[1]

    -- Hold AOE for Group: Accession/Diffusion make the paired spell AOE, so hold
    -- the whole spell until the group is in range. Return false (hold spell), not
    -- nil -- nil would cast the spell self-only, giving the caster the buff while
    -- the group misses it and the self-buff check then suppresses recasts.
    -- Independent of the per-spell "Hold for Stratagem" setting.
    if strat.aoe and settings.hold_aoe_for_group and not common.group_in_aoe_range() then
        common.announce_gather(ability.name, settings)
        return false
    end

    -- A required precast holds regardless of the Hold setting: its spell is gated on
    -- the JA's buff, so casting without it only fails. Scoped to the strat firing this
    -- tick -- overriding the whole list would silently hold an unrelated charge
    -- stratagem the user deliberately left un-held.
    if strat.precast_required then unavailable = false end

    -- Need one charge per missing stratagem buff. Recast-gated strats have no charge
    -- pool (their own JA timer is checked below) and job files list them ahead of the
    -- charge strats, so missing[1] being one means this tick spends no charge; any
    -- charge strat behind it is re-checked, and charge-gated, on a later tick.
    local charges = common.spendable_stratagems(settings)
    if not strat.recast_gate and charges < #missing then
        return unavailable
    end

    -- Recast-gated strat: main-job JA with no charge pool. Gate on the player being
    -- able to use it at all (on-level, meritted, right job) and on its own recast.
    -- Lazy require -- action_core requires common.
    if strat.recast_gate then
        local main_level, sub_level = common.get_player_level()
        if not common.precast_permanently_usable(strat, main_level, sub_level)
            or not require('lib.core.action_core').is_ability_ready(strat.recast_id) then
            return unavailable
        end
    end

    -- Verify arts-stance prerequisite (requires_buff may be a number or table)
    if strat.requires_buff then
        local req_ids = type(strat.requires_buff) == 'table' and strat.requires_buff or { strat.requires_buff }
        local has_required = false
        for _, req_id in ipairs(req_ids) do
            for _, pb in ipairs(player_buffs) do
                if pb == req_id then
                    has_required = true
                    break
                end
            end
            if has_required then break end
        end
        if not has_required then
            return unavailable
        end
    end

    -- Check if blocked by status ailment (silence, stun, etc.)
    local blocked_by = common.is_command_blocked(strat.command)
    if blocked_by then
        return unavailable
    end

    -- Return the stratagem JA command (is_stratagem flag tells the automation
    -- engine to lock the next tick to the same action type so the paired
    -- ability fires immediately without being pre-empted by higher-priority actions)
    return {
        command = strat.command,
        description = string.format('Using %s', strat.name),
        is_stratagem = true,
    }
end

-- Check the always-required precast JA for a spell that cannot function
-- without its buff (BLU Unbridled Learning: ability.requires_precast names
-- the abilities.precast entry). Unlike stratagems this is never user-assigned;
-- the spell is simply locked behind the JA. Returns:
--   nil                    → no precast needed OR its buff is already active → cast the spell
--   {command, description} → fire the precast JA this tick (is_stratagem locks
--                            the follow-up so the spell fires the next tick)
--   false                  → precast can't fire right now (unlearned, wrong
--                            job, cooldown, blocked) → skip the spell
function common.check_required_precast(job_def, ability)
    if not ability or not ability.requires_precast then return nil end
    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return false end
    for _, strat in ipairs(strat_defs) do
        if strat.name == ability.requires_precast then
            if common.has_buff(0, strat.buff_id) then return nil end
            local main_level = common.get_player_level()
            -- is_usable covers cooldown + status-block (cost 0 = free); the rest
            -- (main job / level / learned) it doesn't check, so gate those here.
            if (strat.main_job_only and strat.is_main_job == false)
                or (strat.level and main_level < strat.level)
                or not common.has_spell_learned(strat)
                or not require('lib.core.action_core').is_usable(strat, job_def, 0) then
                return false
            end
            return {
                command = strat.command,
                description = string.format('Using %s', strat.name),
                is_stratagem = true,
            }
        end
    end
    return false
end

-- True when a precast_required JA assigned to this ability would grant the
-- requires_buff it is currently missing (SCH Enlightenment on an Addendum: White spell
-- in Dark Arts). The action modules' requires_buff gates must let such an ability
-- through, else it never reaches check_stratagem and the JA never fires.
--
-- Recast is deliberately NOT checked: it's momentary, and check_stratagem holds the
-- spell for the seconds the JA needs. Level / merit / main-job ARE -- those are
-- permanent, and check_stratagem force-holds a precast_required strat, so a JA that
-- can never fire would hold the ability forever instead of skipping it.
function common.precast_satisfies_prereq(job_def, settings, ability)
    if not (ability and ability.requires_buff and settings and settings.stratagem_settings) then
        return false
    end
    local ss = settings.stratagem_settings
    local assigned = ss[ability.name] or (ability.group and ss[ability.group])
    if not assigned then return false end
    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return false end
    local action_core = require('lib.core.action_core')
    for _, strat in ipairs(strat_defs) do
        -- Table lookups before AshitaCore reads: the UI calls this per row per ImGui
        -- frame, and only a strat that actually grants this row's buff is worth
        -- reading the player's level and buffs for.
        if strat.precast_required and assigned[strat.name]
            and action_core.has_any_buff({ strat.buff_id }, ability.requires_buff) then
            local main_level, sub_level = common.get_player_level()
            if common.precast_permanently_usable(strat, main_level, sub_level)
                -- The precast's own prerequisite (Enlightenment: Dark Arts) decides
                -- whether it applies at all; outside it the gate stays shut.
                and (not strat.requires_buff
                    or action_core.has_any_buff(common.get_player_buffs(), strat.requires_buff)) then
                return true
            end
        end
    end
    return false
end

-- Remove assigned stratagems the player can no longer use. A stratagem configured
-- on a high-level SCH (or a level-75 DRK's Nether Void) stays in stratagem_settings
-- after dropping to a lower level or to a subjob; without this, automation would
-- keep trying to fire a JA the player doesn't know -- or, with Hold on, keep
-- skipping the paired spell for it. Called on job/level change. Returns true if
-- anything was pruned.
function common.prune_unavailable_stratagems(job_def, settings)
    if not settings or not settings.stratagem_settings then return false end
    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return false end

    local main_level, sub_level = common.get_player_level()

    -- name -> true for strats unusable at this job/level. Level source follows
    -- the merge's is_main_job flag (SCH-sub strats check sub level, etc.).
    -- A transient 0 level read (e.g. zoning) marks nothing unusable, so config
    -- is never wiped wrongly.
    local unusable = {}
    for _, strat in ipairs(strat_defs) do
        local from_sub = strat.is_main_job == false
        local level = from_sub and (sub_level or 0) or (main_level or 0)
        if level > 0 then
            if (strat.main_job_only and from_sub) or level < (strat.level or 0) then
                unusable[strat.name] = true
            end
        end
    end

    local changed = false
    for ability_key, assigned in pairs(settings.stratagem_settings) do
        for strat_name in pairs(assigned) do
            if unusable[strat_name] then
                assigned[strat_name] = nil
                changed = true
            end
        end
        if not next(assigned) then
            settings.stratagem_settings[ability_key] = nil
            -- Hold is only meaningful with an assignment; drop it too so it
            -- can't silently re-apply if the strat is reassigned later.
            if settings.stratagem_hold then
                settings.stratagem_hold[ability_key] = nil
            end
        end
    end
    return changed
end

-- ============================================================================
-- Resting State Management
-- ============================================================================

-- Get resting state.
-- The value is refreshed once per automation tick inside refresh_game_state()
-- from the player's cached entity_status, avoiding per-call GetPlayerEntity() overhead.
function common.is_resting()
    return is_resting
end

-- Set resting state
function common.set_resting(state)
    is_resting = state
end

-- ============================================================================
-- Mount State Management
-- ============================================================================

-- Get mount state.
-- Synced once per tick inside refresh_game_state() via the player's entity_status (5 = mounted)
-- and buff array (buff 252 = Mounted), checked with OR as a safeguard.
function common.is_mounted()
    return is_mounted
end

-- Get dead state.
-- Synced once per tick inside refresh_game_state() via the player's entity_status (3 = dead)
-- and HPP (0 = no health remaining), checked with OR as a safeguard.
function common.is_dead()
    return is_dead
end

-- Check if the player is still loading in (job reads as NON/NON and level == 0).
-- This happens during zone transitions or initial login before the server has sent
-- the player's job data.  Automation should be paused while this is true.
function common.is_loading()
    local main_level, _ = common.get_player_level()
    return not main_level or main_level == 0
end

-- ============================================================================
-- Rest Conditions Timer (shared across modules)
-- ============================================================================

-- Reset the rest conditions timer to zero (call whenever an action fires)
function common.reset_rest_timer()
    rest_conditions_met_time = 0
end

-- Get the rest conditions timer value
function common.get_rest_timer()
    return rest_conditions_met_time
end

-- Set the rest conditions timer to a specific time
function common.set_rest_timer(t)
    rest_conditions_met_time = t
end

-- ============================================================================
-- Centralized Game State (refreshed once per automation tick)
-- ============================================================================
-- Snapshot of player (index 0), party members (indices 1-5), alliance sub-parties
-- (flat indices 6-17), and out-of-party tracked targets.
-- Call common.refresh_game_state() once at the start of each automation cycle
-- so all action modules share the same consistent data without redundant API calls.
--
-- common.game_state.player  (index 0) fields:
--   index, name, server_id, target_index
--   hp, hpp, max_hp (cached; 0 until member seen at 100% HP)
--   mp, mpp, max_mp (cached; 0 until member seen at 100% MP)
--   tp
--   buffs            (table of buff IDs)
--   position         ({x, y, z} in local coords)
--   job, job_name, sub_job, sub_job_name
--   main_level, sub_level
--   is_trust (always false for player), is_active (always true for player)
--   fm, pet_hpp, pet_position  (player-only)
--
-- common.game_state.party[1..5] fields: identical to player + is_trust, is_active
-- common.game_state.party_size  : active member count for main party only (indices 0-5)
-- common.game_state.alliance_size : active member count across alliance sub-parties B and C
--
-- common.game_state.alliance[2|3][0..5] fields: identical to party member fields
--   party index 2 = flat indices 6-11, party index 3 = flat indices 12-17
--   buffs: populated via 0x028/0x029 party buff packets (see read_alliance_buffs); empty if unavailable
--
-- common.game_state.alliance_leaders[1|2|3] : server IDs of each sub-party leader
--
-- common.game_state.tracked[server_id] fields:
--   server_id, name, target_index
--   hp, hpp, max_hp (max_hp known from the 100% cache or a shared party list that had
--                    one, else estimated from AVERAGE_HP_BY_LEVEL, else 0 when there is
--                    no level to estimate from; hp is always hpp-derived)
--   max_hp_estimated (true only when max_hp actually came from the level table, i.e. it
--                     is a guess; false for both a known value and no value at all)
--   buffs            (table of buff IDs, packet-tracked)
--   position         ({x, y, z} in local coords)
--   is_tracked       (always true)
--   is_active        (true if entity still visible in zone)

common.game_state = {
    refreshed_at     = 0,
    player           = nil,              -- index 0
    party            = {},               -- indices 1-5 (nil when slot is inactive)
    party_size       = 0,                -- main party only (0-5)
    alliance         = { [2] = {}, [3] = {} },  -- sub-party B (6-11) and C (12-17)
    alliance_size    = 0,                -- alliance sub-parties only (6-17)
    alliance_leaders = { [1] = 0, [2] = 0, [3] = 0 },
    tracked          = {},               -- keyed by server_id
    stratagems       = 0,                -- Scholar stratagem charges (0 when not SCH)
    ready_charges    = 0,                -- Beastmaster Ready charges (0 when not BST)
    pet_debuffs      = {},               -- pet's tracked statuses (buffs+debuffs); consumer filters by debuff_id
}

-- ============================================================================
-- Charge-Based Recast Calculation (Scholar Stratagems, Beastmaster Ready)
-- ============================================================================
-- Both are charge systems on a single shared recast timer: the timer counts the
-- time left until FULL, so available charges = max - ceil(remaining / rate).

local STRATAGEM_RECAST_ID = 231
local SCH_JOB_ID = 20

-- Level thresholds for stratagem charges (descending order for first-match)
local STRATAGEM_TIERS = {
    { level = 75, max_charges = 5, recharge_rate = 48  },
    { level = 65, max_charges = 4, recharge_rate = 60  },
    { level = 50, max_charges = 3, recharge_rate = 80  },
    { level = 30, max_charges = 2, recharge_rate = 120 },
    { level = 10, max_charges = 1, recharge_rate = 240 },
}

local READY_RECAST_ID     = 102
local BST_JOB_ID          = 9
local READY_MAX_CHARGES   = 3   -- 3 charges max
local READY_RECHARGE_RATE = 30  -- 30s per charge (90s from empty to full)

-- Convert the recast slot matching recast_id into how many of max_charges are
-- available right now. Shared by stratagems and Ready.
local function charges_from_recast(recast_id, max_charges, recharge_rate)
    if max_charges == 0 then return 0 end

    local recast_mgr = AshitaCore:GetMemoryManager():GetRecast()
    if not recast_mgr then return max_charges end

    local timer_value = nil
    for slot = 0, 31 do
        local ok_id, tid = pcall(function() return recast_mgr:GetAbilityTimerId(slot) end)
        if ok_id and tid == recast_id then
            local ok_t, t = pcall(function() return recast_mgr:GetAbilityTimer(slot) end)
            if ok_t then timer_value = t end
            break
        end
    end

    -- No matching slot or timer 0 -> all charges available
    if not timer_value or timer_value == 0 then
        return max_charges
    end

    -- Timer is in ticks (60 ticks = 1 second). Subtract a small epsilon before
    -- ceil to avoid over-counting by 1 near a charge boundary.
    local seconds_remaining = timer_value / 60
    local missing_charges   = math.ceil((seconds_remaining - 0.5) / recharge_rate)
    local current_charges   = max_charges - missing_charges

    if current_charges < 0 then current_charges = 0 end
    if current_charges > max_charges then current_charges = max_charges end

    return current_charges
end

--- Calculate the number of stratagem charges currently available.
--- Returns 0 if the player is not Scholar main or sub.
local function calculate_stratagems()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player then return 0 end

    local main_job = player:GetMainJob()
    local sub_job  = player:GetSubJob()
    local level    = 0

    if main_job == SCH_JOB_ID then
        level = player:GetMainJobLevel()
    elseif sub_job == SCH_JOB_ID then
        level = player:GetSubJobLevel()
    else
        return 0
    end

    local max_charges   = 0
    local recharge_rate = 0
    for _, tier in ipairs(STRATAGEM_TIERS) do
        if level >= tier.level then
            max_charges   = tier.max_charges
            recharge_rate = tier.recharge_rate
            break
        end
    end

    return charges_from_recast(STRATAGEM_RECAST_ID, max_charges, recharge_rate)
end

--- Ready charges currently available. 0 when not Beastmaster main or sub.
-- ponytail: fixed 3-charge max; if the server scales it by level/merits, make
-- this level-tiered like STRATAGEM_TIERS.
local function calculate_ready()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player then return 0 end

    local main_job = player:GetMainJob()
    local sub_job  = player:GetSubJob()
    if main_job ~= BST_JOB_ID and sub_job ~= BST_JOB_ID then
        return 0
    end

    return charges_from_recast(READY_RECAST_ID, READY_MAX_CHARGES, READY_RECHARGE_RATE)
end

-- Internal helper: return packet-tracked buffs for an alliance member.
-- All alliance member buffs are populated via 0x028/0x029 packet handlers
-- into the shared trust_buffs table (keyed by server_id).
local function read_alliance_buffs(server_id)
    if not server_id or server_id == 0 then return {} end
    return trust_buffs[server_id] or {}
end

-- Internal helper: build a member snapshot from a party manager flat index (0-17).
local function build_member_snapshot(party_mgr, entity_mgr, flat_index)
    local function safe_get(fn, fallback)
        local ok, val = pcall(fn)
        if ok and val ~= nil then return val end
        return fallback
    end

    local server_id  = safe_get(function() return party_mgr:GetMemberServerId(flat_index)     end, 0)
    local name       = safe_get(function() return party_mgr:GetMemberName(flat_index)         end, '')
    local target_idx = safe_get(function() return party_mgr:GetMemberTargetIndex(flat_index)  end, 0)

    local hp  = safe_get(function() return party_mgr:GetMemberHP(flat_index)           end, 0)
    local hpp = safe_get(function() return party_mgr:GetMemberHPPercent(flat_index)    end, 0)
    local mp  = safe_get(function() return party_mgr:GetMemberMP(flat_index)           end, 0)
    local mpp = safe_get(function() return party_mgr:GetMemberMPPercent(flat_index)    end, 0)
    local tp  = safe_get(function() return party_mgr:GetMemberTP(flat_index)           end, 0)

    if not member_max_stats[server_id] then
        member_max_stats[server_id] = {}
    end
    if hpp == 100 and hp > 0 then member_max_stats[server_id].max_hp = hp end
    if mpp == 100 and mp > 0 then member_max_stats[server_id].max_mp = mp end
    local max_hp = member_max_stats[server_id].max_hp or 0
    local max_mp = member_max_stats[server_id].max_mp or 0

    local job        = safe_get(function() return party_mgr:GetMemberMainJob(flat_index)      end, 0)
    local sub_job    = safe_get(function() return party_mgr:GetMemberSubJob(flat_index)       end, 0)
    local main_level = safe_get(function() return party_mgr:GetMemberMainJobLevel(flat_index) end, 0)
    local sub_level  = safe_get(function() return party_mgr:GetMemberSubJobLevel(flat_index)  end, 0)

    -- /anon: the server only writes job/level into the party-list packet when the
    -- character is not anonymous (0x0dd_group_list.cpp), so our own entry comes
    -- back as job 0 / level 0 and every level gate in the action modules fails.
    -- The Player struct is unaffected, so patch our own row back up from it.
    if flat_index == 0 and main_level == 0 then
        local p = safe_get(function() return AshitaCore:GetMemoryManager():GetPlayer() end, nil)
        if p then
            job        = safe_get(function() return p:GetMainJob()      end, job)
            sub_job    = safe_get(function() return p:GetSubJob()       end, sub_job)
            main_level = safe_get(function() return p:GetMainJobLevel() end, main_level)
            sub_level  = safe_get(function() return p:GetSubJobLevel()  end, sub_level)
        end
    end

    local job_name     = safe_get(function()
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job)
    end, '')
    local sub_job_name = safe_get(function()
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', sub_job)
    end, '')

    local position = {x = 0, y = 0, z = 0}
    local entity_status = -1
    if entity_mgr and target_idx and target_idx > 0 then
        local ok_x, px = pcall(function() return entity_mgr:GetLocalPositionX(target_idx) end)
        local ok_y, py = pcall(function() return entity_mgr:GetLocalPositionY(target_idx) end)
        local ok_z, pz = pcall(function() return entity_mgr:GetLocalPositionZ(target_idx) end)
        if ok_x and ok_y and ok_z then
            position = {x = px, y = py, z = pz}
        end
        local ent = GetEntity(target_idx)
        if ent then
            local ok_s, s = pcall(function() return ent.Status end)
            if ok_s and s ~= nil then entity_status = s end
        end
    end

    -- Buffs: player and main-party members via normal API; alliance members via read_alliance_buffs() (packet-tracked from trust_buffs)
    local buffs
    if flat_index == 0 then
        buffs = common.get_player_buffs()
    elseif flat_index <= 5 then
        buffs = common.get_party_buffs(flat_index)
    else
        buffs = read_alliance_buffs(server_id)
    end

    return {
        index        = flat_index,
        name         = name,
        server_id    = server_id,
        target_index = target_idx,
        hp           = hp,
        hpp          = hpp,
        max_hp       = max_hp,
        mp           = mp,
        mpp          = mpp,
        max_mp       = max_mp,
        tp           = tp,
        buffs        = buffs,
        position     = position,
        job          = job,
        job_name     = job_name,
        sub_job      = sub_job,
        sub_job_name = sub_job_name,
        main_level   = main_level,
        sub_level    = sub_level,
        is_trust      = (server_id >= 0x1000000),
        is_active     = true,
        entity_status = entity_status,
        -- Player-only extras (zeroed for all non-player members)
        fm           = 0,
        pet_hpp      = 0,
        pet_position = {x = 0, y = 0, z = 0},
    }
end

function common.refresh_game_state()
    local state = common.game_state
    state.refreshed_at     = os.clock()
    state.player           = nil
    state.party            = {}
    state.party_size       = 0
    state.alliance         = { [2] = {}, [3] = {} }
    state.alliance_size    = 0
    state.alliance_leaders = { [1] = 0, [2] = 0, [3] = 0 }
    state.tracked          = {}
    state.stratagems       = calculate_stratagems()
    state.ready_charges    = calculate_ready()

    -- Drop expired timed buffs (Trusts/tracked targets) before buffs are read
    -- into the snapshot, so action modules see them as missing and recast.
    common.expire_timed_buffs()

    local party_mgr = common.get_party()
    if not party_mgr then return end

    local entity_mgr = common.get_entity_manager()

    local function safe_get(fn, fallback)
        local ok, val = pcall(fn)
        if ok and val ~= nil then return val end
        return fallback
    end

    -- Cache alliance leader server IDs
    state.alliance_leaders[1] = safe_get(function() return party_mgr:GetAlliancePartyLeaderServerId1() end, 0)
    state.alliance_leaders[2] = safe_get(function() return party_mgr:GetAlliancePartyLeaderServerId2() end, 0)
    state.alliance_leaders[3] = safe_get(function() return party_mgr:GetAlliancePartyLeaderServerId3() end, 0)

    -- -----------------------------------------------------------------------
    -- Main party: flat indices 0-5
    -- -----------------------------------------------------------------------
    for i = 0, 5 do
        local is_active = safe_get(function() return party_mgr:GetMemberIsActive(i) == 1 end, false)
        if not is_active then
            if i > 0 then state.party[i] = nil end
        else
            state.party_size = state.party_size + 1
            local member = build_member_snapshot(party_mgr, entity_mgr, i)

            if i == 0 then
                -- Player-only extras
                local fm = 0
                for fm_val, fm_num in ipairs({381, 382, 383, 384, 385}) do
                    if common.has_buff(0, fm_num) then fm = fm_val break end
                end
                member.fm = fm

                local pet_entity = targets.get_pet()
                if pet_entity then
                    member.pet_hpp = pet_entity.HPPercent or 0
                    if entity_mgr then
                        local pet_idx = pet_entity.TargetIndex
                        if pet_idx and pet_idx > 0 then
                            local ok_px, px = pcall(function() return entity_mgr:GetLocalPositionX(pet_idx) end)
                            local ok_py, py = pcall(function() return entity_mgr:GetLocalPositionY(pet_idx) end)
                            local ok_pz, pz = pcall(function() return entity_mgr:GetLocalPositionZ(pet_idx) end)
                            if ok_px and ok_py and ok_pz then
                                member.pet_position = {x = px, y = py, z = pz}
                            end
                        end
                    end
                end

                -- Track the pet's server id so the packet handlers can route the
                -- pet's buffs/debuffs into trust_buffs. Drop the previous pet's
                -- list when the pet changes or leaves (swap/release) so no stale
                -- debuff lingers.
                local new_pet_sid = pet_entity and (pet_entity.ServerId or 0) or 0
                if new_pet_sid ~= pet_server_id then
                    if pet_server_id ~= 0 then trust_buffs[pet_server_id] = nil end
                    pet_server_id = new_pet_sid
                end
                state.pet_debuffs = (pet_server_id ~= 0 and trust_buffs[pet_server_id]) or {}

                state.player = member

                -- Sync is_resting from the player's entity Status (33 = resting).
                -- Only update when the status was successfully read (>= 0) to avoid
                -- clobbering the cached value on a transient entity read failure.
                if member.entity_status >= 0 then
                    is_resting = (member.entity_status == 33)
                end

                -- Sync is_mounted: entity Status 5 OR buff 252 (Mounted), whichever fires first.
                local has_mount_buff = false
                if member.buffs then
                    for _, bid in ipairs(member.buffs) do
                        if bid == 252 then has_mount_buff = true break end
                    end
                end
                is_mounted = (member.entity_status == 5) or has_mount_buff

                -- Sync is_dead: entity Status 3 (dead) OR HPP 0, whichever fires first.
                is_dead = (member.entity_status == 3) or (member.hpp == 0)
            else
                state.party[i] = member
            end
        end
    end

    common.sample_movement(state)

    -- -----------------------------------------------------------------------
    -- Alliance sub-parties B and C: flat indices 6-17
    -- Rebuild alliance_member_sids so packet handlers know who to track.
    -- -----------------------------------------------------------------------
    local old_alliance_sids = alliance_member_sids
    alliance_member_sids = {}
    for party_index = 2, 3 do
        local first = (party_index - 1) * 6   -- 6 or 12
        local last  = first + 5                -- 11 or 17
        for flat_i = first, last do
            local is_active = safe_get(function() return party_mgr:GetMemberIsActive(flat_i) == 1 end, false)
            if is_active then
                state.alliance_size = state.alliance_size + 1
                local local_index = flat_i - first   -- 0-5 within sub-party
                local snapshot = build_member_snapshot(party_mgr, entity_mgr, flat_i)
                state.alliance[party_index][local_index] = snapshot
                -- Register server_id for packet-based buff tracking
                if snapshot.server_id and snapshot.server_id > 0 then
                    alliance_member_sids[snapshot.server_id] = true
                end
            end
        end
    end

    -- Purge stale trust_buffs for server_ids that dropped out of the alliance.
    -- Trusts are not allowed in alliances, so former alliance member entries
    -- should not linger in trust_buffs.
    for sid in pairs(old_alliance_sids) do
        if not alliance_member_sids[sid] and not tracked_targets[sid] then
            trust_buffs[sid] = nil
        end
    end

    -- -----------------------------------------------------------------------
    -- Refresh tracked targets (outside-party players)
    -- -----------------------------------------------------------------------
    for sid, tt in pairs(tracked_targets) do
        local entity = nil
        -- Re-resolve entity by server_id (target_index may change across zones)
        for idx = 0, 2302 do
            local e = GetEntity(idx)
            if e and e.ServerId == sid then
                entity = e
                tt.target_index = e.TargetIndex or 0
                break
            end
        end

        if entity and entity.TargetIndex and entity.TargetIndex > 0 then
            local hpp = entity.HPPercent or 0

            -- Position
            local position = {x = 0, y = 0, z = 0}
            if entity_mgr then
                local tidx = entity.TargetIndex
                local ok_x, px = pcall(function() return entity_mgr:GetLocalPositionX(tidx) end)
                local ok_y, py = pcall(function() return entity_mgr:GetLocalPositionY(tidx) end)
                local ok_z, pz = pcall(function() return entity_mgr:GetLocalPositionZ(tidx) end)
                if ok_x and ok_y and ok_z then
                    position = {x = px, y = py, z = pz}
                end
            end

            -- Only HPPercent is available for non-party entities from GetEntity();
            -- raw HP is not exposed in the FFXI entity array for non-party PCs.
            -- Priority: (1) known max HP -- observed at 100%, or handed over by a party
            -- member's own client through the shared party list (party_share.lua, which
            -- can only pass a value it has itself observed at 100%, so a roster row is
            -- not a guarantee); (2) level-based estimate from AVERAGE_HP_BY_LEVEL. Only
            -- the second is a guess, and max_hp_estimated says so, so the panel marks the
            -- right rows '~'. Neither available (no cache, and no level to estimate from
            -- -- an /anon row publishes level 0) leaves max_hp 0 and the flag false: there
            -- is no estimate to mark, and the panel shows no number at all.
            if not member_max_stats[sid] then
                member_max_stats[sid] = {}
            end
            local max_hp = member_max_stats[sid].max_hp or 0
            local max_hp_estimated = false
            if max_hp == 0 and tt.main_level then
                max_hp = AVERAGE_HP_BY_LEVEL[tt.main_level] or 0
                max_hp_estimated = (max_hp > 0)
            end
            local hp = (max_hp > 0) and math.floor(hpp * max_hp / 100) or 0

            -- Buffs via packet tracking (same table as Trusts)
            local buffs = trust_buffs[sid] or {}

            local t_entity_status = -1
            local ok_es, es = pcall(function() return entity.Status end)
            if ok_es and es ~= nil then t_entity_status = es end

            state.tracked[sid] = {
                server_id     = sid,
                name          = tt.name,
                target_index  = entity.TargetIndex,
                hp            = hp,
                hpp           = hpp,
                max_hp        = max_hp,
                max_hp_estimated = max_hp_estimated,
                main_job      = tt.main_job,
                sub_job       = tt.sub_job,
                main_level    = tt.main_level,
                sub_level     = tt.sub_level,
                buffs         = buffs,
                position      = position,
                is_tracked    = true,
                is_active     = true,
                entity_status = t_entity_status,
            }
        else
            -- Entity not visible; keep entry but mark inactive
            local cached_max_hp = (member_max_stats[sid] or {}).max_hp or 0
            local cached_estimated = false
            if cached_max_hp == 0 and tt.main_level then
                cached_max_hp = AVERAGE_HP_BY_LEVEL[tt.main_level] or 0
                cached_estimated = (cached_max_hp > 0)
            end
            state.tracked[sid] = {
                server_id     = sid,
                name          = tt.name,
                target_index  = 0,
                hp            = 0,
                hpp           = 0,
                max_hp        = cached_max_hp,
                max_hp_estimated = cached_estimated,
                main_job      = tt.main_job,
                sub_job       = tt.sub_job,
                main_level    = tt.main_level,
                sub_level     = tt.sub_level,
                buffs         = trust_buffs[sid] or {},
                position      = {x = 0, y = 0, z = 0},
                is_tracked    = true,
                is_active     = false,
                entity_status = -1,
            }
        end
    end

    -- Clear pending_raise flags for any server_id whose entity is no longer dead.
    -- Iterating a sparse table while modifying it is safe in Lua (next-based iteration).
    for sid in pairs(pending_raise_flags) do
        local still_dead = false
        -- Check player and main party
        for i = 0, 5 do
            local m = i == 0 and state.player or state.party[i]
            if m and m.server_id == sid and m.entity_status == 3 then
                still_dead = true; break
            end
        end
        -- Check tracked targets
        if not still_dead and state.tracked and state.tracked[sid] then
            if state.tracked[sid].entity_status == 3 then still_dead = true end
        end
        -- Check alliance sub-parties
        if not still_dead and state.alliance then
            for al_pi = 2, 3 do
                if state.alliance[al_pi] then
                    for _, m in pairs(state.alliance[al_pi]) do
                        if m and m.server_id == sid and m.entity_status == 3 then
                            still_dead = true; break
                        end
                    end
                end
            end
        end
        if not still_dead then
            common.debugf('[REVIVE] server_id %d is no longer dead — clearing pending raise flag', sid)
            pending_raise_flags[sid] = nil
        end
    end
end

-- ============================================================================
-- Shared target-resolution helpers (used by heal, buff, status_removal)
-- ============================================================================

--- Resolve the focus target name across party → tracked → alliance.
--- Returns: kind ('party'|'tracked'|'alliance'|nil), ref (party_index or server_id)
function common.resolve_focus_target(settings, state)
    if not settings.focus_enabled or not settings.focus_target then
        return nil, nil
    end
    local name = settings.focus_target

    for i = 0, 5 do
        local m = i == 0 and state.player or state.party[i]
        if m and m.name == name then
            return 'party', i
        end
    end

    if state.tracked then
        for sid, tt in pairs(state.tracked) do
            if tt.name == name and tt.is_active then
                return 'tracked', sid
            end
        end
    end

    if state.alliance then
        for al_pi = 2, 3 do
            if state.alliance[al_pi] then
                for _, m in pairs(state.alliance[al_pi]) do
                    if m and m.name == name and m.is_active then
                        return 'alliance', m.server_id
                    end
                end
            end
        end
    end

    return nil, nil
end

--- Find an alliance member snapshot by server_id across both sub-parties.
--- Returns the member table or nil.
function common.find_alliance_member(state, server_id)
    if not state or not state.alliance or not server_id then return nil end
    for al_pi = 2, 3 do
        if state.alliance[al_pi] then
            for _, m in pairs(state.alliance[al_pi]) do
                if m and m.server_id == server_id then
                    return m
                end
            end
        end
    end
    return nil
end

--- Return a new list containing only abilities with target_outside == true.
function common.outside_abilities(abilities)
    local result = {}
    for _, a in ipairs(abilities) do
        if a.target_outside then
            table.insert(result, a)
        end
    end
    return result
end

--- Return the total number of active alliance members across sub-parties B and C.
function common.get_alliance_count()
    local count = 0
    local gs = common.game_state
    if gs and gs.alliance then
        for pi = 2, 3 do
            if gs.alliance[pi] then
                for _ in pairs(gs.alliance[pi]) do count = count + 1 end
            end
        end
    end
    return count
end

--- Return a sorted array of { local_idx, m } entries for a given alliance sub-party table.
--- Sorted by local_idx ascending (0-5 within the sub-party).
function common.sorted_alliance_members(sub_party)
    local sorted = {}
    if not sub_party then return sorted end
    for local_idx, m in pairs(sub_party) do
        table.insert(sorted, { local_idx = local_idx, m = m })
    end
    table.sort(sorted, function(a, b) return a.local_idx < b.local_idx end)
    return sorted
end

return common
