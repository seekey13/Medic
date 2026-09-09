--[[
    Buff maintenance action module
    Handles maintaining self and party buffs
]]--

local buff = {}

local common      = require('lib.core.common')
local action_core = require('lib.core.action_core')

-- Song AoE radius (yalms). Party members beyond this can't be covered by an area
-- song, so they don't count as "missing" and never force an endless recast.
local SONG_AOE_RANGE = 10

-- Re-sing interval for AREA songs when no member's buff list can answer whether
-- one is still up (see no_readable_voter) and the user set no Song Duration. The
-- 120s base song length: with no duration gear read from a Trust's unreliable
-- list there is nothing better to go on, and the alternative is area songs that
-- are never re-sung at all. Applies to [A] songs alone -- single-target songs
-- keep waiting for the explicit setting, since guessing 120s for a bard in
-- duration gear would re-sing their own songs early.
local DEFAULT_SONG_DURATION = 120

-- Songs one caster holds on one target: a new song beyond this overwrites that
-- caster's oldest, and the game gives a main-job Bard two. Manual timers only
-- run for a main-job Bard (see manual_tracking), so the sub-job's one slot never
-- applies here. Mirrored in handle_song_finished; area_needs_recast derives the
-- same number per tier for its slot math.
local SONG_SLOTS = 2

-- Casting anything at all breaks Invisible, so any non-travel buff cast while
-- it's up costs an Invisible reapply on top of itself.
local INVISIBLE_BUFF = common.INVISIBLE_BUFF

-- Bard lv75 merit JAs. Cast from bard.lua's buff list (self-buffs); read here
-- to gate the Pianissimo fast-cast trick and to double stamped song timers.
-- CatsEyeXI status_effects.sql: 347 = nightingale, 348 = troubadour.
local NIGHTINGALE_BUFF = 347
local TROUBADOUR_BUFF  = 348

-- Manual song timers: [server_id][ability.name] = {deadline, verify_at}, both
-- os.clock() stamps. Active
-- only for a level-75 main-job Bard with settings.song_duration > 0 (that's
-- where song+ duration gear lives). Instead of waiting for a buff to vanish
-- from memory (always a reaction, so always downtime), each song we land is
-- stamped per target and re-sung when its timer runs out -- before the real
-- buff drops, provided the user set the duration under their true value.
-- Stamped on the cast-FINISH packet, never on the send; ignored for a member
-- who is dead, and cleared for everyone on a job change or a reload.
-- Keyed by ability NAME, not buff_id, so stacked tiers sharing a buff_id
-- (Ballad + Ballad II = two of 196) each keep their own timer. A local, so a
-- reload clears it and every song is re-sung to establish known timers.
-- ponytail: entries for members who left the party linger; bounded and inert.
local song_expiry = {}

-- Nightingale + Troubadour are popped as a pair, and every song sung while both
-- hold casts much faster -- Nightingale halves the cast, or skips it entirely on
-- a (merits x 25) - 25 percent roll, so instant only at 5/5, and Troubadour then
-- adds 50% back -- and lasts twice as long. So the moment both are up, every song
-- we hold a timer for is worth re-singing on the spot: the instances we are
-- holding are the short ones, and the window is far too brief to wait them out.
-- os.clock() of the moment the pair was first seen, nil while no window is
-- armed. A row stamped before it is reported due (song_deadline); a row stamped
-- after it was already sung inside the window, so the burst converges after one
-- pass per song rather than looping.
-- Only rows we HOLD are forced. A song we hold no row for keeps falling back to
-- buff memory, and it has to: memory is what stops a bard with more configured
-- songs than song slots from cycling them forever.
local song_force_at = nil

-- Arm or disarm that window. Called first thing in buff.execute, ahead of its
-- own enable/resting guards, so the pair is tracked even on ticks that buff
-- nothing.
local function update_song_force(state)
    local buffs = state and state.player and state.player.buffs
    -- An empty list is allowed to disarm, on purpose: a transient failed read
    -- costs at most one extra burst of cheap casts, while refusing to disarm here
    -- would strand the window armed for a player who legitimately holds zero
    -- buffs -- and since arming only happens while song_force_at is nil, the next
    -- real pop would then silently burst nothing.
    if not buffs then return end
    -- Disarmed the moment EITHER buff is gone, not only once both are. The flag
    -- is a plain mirror of live state, so it can never be left armed across a
    -- stretch this module never ran (a higher-priority module winning the tick,
    -- or the loading / mounted / dead / casting guards) and then be re-read
    -- against a later, unpaired Troubadour -- which would burst pre-window rows
    -- outside any real window. The cost is that a one-frame dropout in the buff
    -- snapshot re-arms and re-bursts, bounded at one extra pass per dropout.
    if action_core.has_any_buff(buffs, NIGHTINGALE_BUFF)
       and action_core.has_any_buff(buffs, TROUBADOUR_BUFF) then
        if not song_force_at then
            song_force_at = os.clock()
            common.debugf('[SONG] Nightingale + Troubadour up: re-singing every song we hold a timer for')
        end
    else
        song_force_at = nil
    end
end

-- True while songs are actually being forced: the window armed AND both buffs
-- still live. song_deadline and /sk panel both read this rather than the flag,
-- because the flag alone lies whenever nothing has refreshed it -- the panel
-- renders ahead of automation_tick and outside its guards, so with automation
-- off (or mounted / dead / casting) song_force_at sits non-nil long after the
-- buffs wore. Reading them live is the condition that actually gates a cast.
function buff.song_force_active()
    if not song_force_at then return false end
    local p = common.game_state and common.game_state.player
    local buffs = p and p.buffs
    return action_core.has_any_buff(buffs, NIGHTINGALE_BUFF)
       and action_core.has_any_buff(buffs, TROUBADOUR_BUFF)
end

-- server_id set of members whose song slots are wholly assigned to single-target
-- songs. Rebuilt every buff.execute, read by handle_song_finished -- see the
-- comment where it is filled.
local slot_locked = {}

-- The area song path re-evaluates every frame, so a plain debugf there prints the
-- same line dozens of times a second. Log only when the text actually changes.
-- Numbers are stripped for the comparison so a countdown ("cooldown (8.2s)" ->
-- "(8.1s)") counts as the same message and prints once.
-- common.debugf drops the line with debug off, but only after we have formatted
-- and gsub'd it -- per frame, on the hot path. Check the flag before building.
local last_song_log = {}
local function song_debugf(key, fmt, ...)
    if not common.debug then return end
    local msg = string.format(fmt, ...)
    local sig = msg:gsub('%d+%.?%d*', '#')
    if last_song_log[key] == sig then return end
    last_song_log[key] = sig
    common.debugf('[SONG] %s', msg)
end

-- True when this member is dead, dropping every song timer we hold for them on
-- the way out. Death strips every buff, songs included, so a held timer is a lie
-- the moment they fall. Callers then skip them outright until they are raised:
-- singing at a corpse wastes the cast, and letting their (empty) buff list vote
-- would force the area song to recast on cooldown -- resetting every other
-- member's timer with it -- for as long as they lie there. Raised, they hold no
-- timer, so the buff-memory check governs and every song is re-established at
-- once. entity_status 3 is the reading revive.lua uses; HPP 0 is the other half
-- of refresh_game_state's is_dead sync, caught here for the tick before the
-- status lands.
-- Only a read we can trust may delete the rows. build_member_snapshot falls back
-- to hpp = 0 on a failed pcall and leaves entity_status at its -1 sentinel, and
-- an out-of-zone member reads 0 HPP too -- so a bare `hpp == 0` throws a live
-- member's timers away over a transient, and permanently, where the old
-- song_deadline check merely ignored them until the read recovered. HPP 0
-- therefore counts only once the status read succeeded (the `entity_status >= 0`
-- test refresh_game_state uses for the same reason). Out-of-zone members fall
-- through as not-dead and are excluded by the zone gate in both passes.
local function song_member_dead(member)
    if not member then return false end
    local status = member.entity_status
    if status ~= 3 and not (status and status >= 0 and member.hpp == 0) then return false end
    local sid = member.server_id
    if sid and sid ~= 0 then song_expiry[sid] = nil end
    return true
end

-- The re-sing deadline we hold for this song on this member, or nil when we
-- hold none. A member with no stampable server_id (0 = failed read;
-- queue_song_stamp skips those) returns nil too -- the memory check governs there, else a zeroed
-- self row would cycle area songs forever.
-- no_verify skips the landing check below. Pass it for a member whose song slots
-- are wholly assigned to single-target songs: the area song we stamped IS meant
-- to be overwritten there, so a missing buff proves nothing and dropping the
-- timer over it would put the area song back on a cooldown recast.
local function song_deadline(ability, member, no_verify)
    local sid = member and member.server_id
    if not sid or sid == 0 then return nil end
    local t = song_expiry[sid]
    local row = t and t[ability.name]
    if not row then return nil end
    -- Nightingale + Troubadour window: a row stamped before the pair went up is
    -- a short, pre-window song. Report it due (a deadline always in the past) so
    -- it is re-sung now at double length -- ahead of the buff-memory check,
    -- which still sees the old instance on the target and would veto the
    -- recast. Skipping the landing check below is free here: we are re-singing
    -- and restamping this row either way. Returning 0 (not false or -1) matters:
    -- callers must treat it as truthy, and area_needs_recast's
    -- `target_buffs and manual and song_deadline(...) or nil` chain relies on
    -- that -- a falsy sentinel would be swallowed by that and/or idiom and
    -- silently disable the feature with no error.
    -- song_force_active re-reads both buffs live, so a pair that wore off between
    -- the arm and this read forces nothing: the doubling is Troubadour's alone
    -- (handle_song_finished reads it there), and re-singing through a tail where
    -- either half has dropped would replace a DOUBLED instance with a
    -- single-length one -- the exact regression this feature exists to prevent.
    -- A failed buff read reads as "not up" and skips too, the safe way.
    if song_force_at and (row.at or 0) < song_force_at and buff.song_force_active() then
        return 0
    end
    -- Landing check, run once per stamp. The cast-FINISH packet proves the song
    -- resolved, not who it reached: an area song stamps everyone who was in
    -- radius at send, so a member who walked out mid-cast holds a full timer for
    -- a song that never touched them, and their re-sing stays suppressed for its
    -- whole duration. Their buff list settles the question -- but not at finish,
    -- where the song has not posted to it yet (game_state is a per-frame
    -- snapshot, and the buff array fills from the server's status packet, not
    -- from the 0x028 we stamped on). So the row carries a verify_at and the
    -- check waits until then; missing the buff by that point means the song
    -- never landed, and the timer goes rather than lie for its full duration.
    -- Deferred to the read because that is the only place we hold the member's
    -- buffs, and it is exactly when the answer matters.
    if not no_verify and row.verify_at and os.clock() >= row.verify_at then
        row.verify_at = nil
        if ability.buff_id and not action_core.has_any_buff(member.buffs, ability.buff_id) then
            t[ability.name] = nil
            return nil
        end
    end
    return row.deadline
end

-- The song we have sent and are waiting on, or nil. Every song -- area, party,
-- self, single-target, fast-cast -- travels the same three steps, so they all
-- get the same timer treatment:
--   1. ARMED   (queue_song_stamp, when the command goes out) -- the only moment
--      we know who the song is aimed at, so the target list is resolved here.
--   2. STARTED (buff.handle_song_cast_start, on our own cast-BEGIN packet for
--      that spell id) -- until this lands the command may never have reached the
--      server at all (refused client-side for silence / range / movement / a
--      changed target), so an armed entry alone must never stamp.
--   3. STAMPED (buff.handle_song_finished, on the cast-FINISH packet):
--      * the buff starts at finish, so that is when its duration really begins;
--      * an interrupted cast sends no finish -- buff.handle_song_interrupted
--        drops the entry, so the buff memory check keeps governing and the song
--        is re-sung right away;
--      * Troubadour is read at the moment the server fixes the song's length.
--        Read a whole cast time earlier it could wear mid-cast, doubling the
--        timer on a single-length song -- an error a full song long, in the
--        unsafe direction.
-- One slot is enough: a cast blocks every other send (the tick loop's is_casting
-- guard plus the command throttle), so only one song is ever in flight.
local pending_song = nil

-- An armed entry whose cast never began is stale after this long: the server's
-- cast-BEGIN follows the send by a fraction of a second, so anything older
-- belongs to a command that never took. Without the cutoff a stale entry would
-- sit indefinitely and then stamp on the next hand-cast of that same song --
-- which is exactly how an interrupted song ends up holding a timer.
local PENDING_SONG_TIMEOUT = 2.0

-- And a started entry is stale after this long. A cast that dies without an
-- interrupt packet -- the case common.lua's cast_timeout = 16.0 exists for --
-- would otherwise leave a STARTED entry with no expiry at all, free to stamp its
-- arm-time target list on any later finish of that song. Covers the arm window
-- plus that same 16s outer bound on a cast.
local PENDING_SONG_MAX_CAST = 20.0

-- How long after the cast finishes before a stamped timer is checked against the
-- target's buff list (see song_deadline). Long enough for the server's status
-- packet to land and the next game_state refresh to pick it up, so a song that
-- really did land is never clipped for not having posted yet.
local SONG_VERIFY_DELAY = 5.0

-- Songs go away with the job, so every held timer must go with it too -- else a
-- WHM keeps counting down the Victory March they sang as a Bard, and the song we
-- were waiting on goes with them.
function buff.reset_song_timers()
    song_expiry = {}
    slot_locked = {}
    pending_song = nil
    last_song_log = {}
    -- The window belongs to the job that opened it.
    song_force_at = nil
end

-- Drop every song timer held for one member. Our own death is the case that
-- needs it: song_member_dead never sees us, because the tick loop's is_dead
-- guard returns before buff.execute runs, and by the time we are raised the
-- read says alive again -- so our own row would survive a death that stripped
-- the songs it stands for, and we would sing nothing for a whole duration.
-- Only the caller's row goes: everyone else's songs outlive our death.
function buff.forget_song_timers(server_id)
    if server_id and server_id ~= 0 then song_expiry[server_id] = nil end
end

-- Live song timers for the /sk panel readout: [server_id][song name] = row.
-- Read-only view of the real table -- the panel formats it, nothing writes here.
function buff.song_timers()
    return song_expiry
end

-- Remember what to stamp once the cast lands. Server ids are resolved now rather
-- than at finish so a party reshuffle mid-cast can't retarget the stamp.
-- target_index = the single member (0-5) a Pianissimo song lands on; omit it for
-- an area song, which covers self plus everyone in zone and within song range.
-- ponytail: who is in AoE range is also sampled now, not at finish, so someone
-- who walks out of range mid-cast still gets a timer. Sample at finish if that
-- proves to matter.
local function queue_song_stamp(ability, duration, state, target_index)
    local sids = {}
    if target_index then
        local m = (target_index == 0) and state.player or state.party[target_index]
        if m and (m.server_id or 0) > 0 and not song_member_dead(m) then sids[1] = m.server_id end
    else
        if (state.player.server_id or 0) > 0 then sids[1] = state.player.server_id end
        local player_zone = common.get_party_member_zone(0)
        for ti = 1, 5 do
            local m  = state.party[ti]
            local ei = m and m.target_index
            -- A corpse in radius takes no song, so it takes no timer either --
            -- both readers drop it again on their next pass, but stamping it at
            -- all means one frame where a dead member looks covered.
            if ei and ei > 0 and (m.server_id or 0) > 0 and not song_member_dead(m)
               and common.get_party_member_zone(ti) == player_zone
               and common.is_in_range(ei, SONG_AOE_RANGE) then
                sids[#sids + 1] = m.server_id
            end
        end
    end
    if #sids == 0 then return end
    pending_song = {
        spell_id = ability.spell_id,
        name     = ability.name,
        duration = duration,
        sids     = sids,
        armed_at = os.clock(),
        started  = false,
    }
end

-- Called from Sidekick.lua's 0x028 handler on the player's own cast-BEGIN
-- (category 8, non-interrupt). Promotes the armed song once we see the server
-- actually start it. Any other spell starting while we are still ARMED means
-- ours never went out, so the entry is dropped rather than left to stamp on some
-- later finish. Once STARTED it is left alone: our own cast is under way, and a
-- stray player-sourced cast-begin (the mid-cast /debuff of a Pianissimo fast-cast
-- is the one that could plausibly emit one) must not silently cancel the timer.
-- Nothing is risked by keeping it -- the finish still has to match the spell id
-- and beat PENDING_SONG_MAX_CAST.
function buff.handle_song_cast_start()
    local p = pending_song
    if not p or p.started then return end
    -- No spell id to check against: a category 8 packet's Param is a fixed marker,
    -- not the spell being cast (see parse_packets). The age bound is the whole
    -- guard, and it is enough -- the command throttle means only one action of
    -- ours can be in flight, and the finish packet still has to match the id.
    if (os.clock() - p.armed_at) > PENDING_SONG_TIMEOUT then
        pending_song = nil
        return
    end
    p.started = true
end

-- The cast was interrupted or cancelled (stun, damage, zoning, job change): the
-- song never landed, so no timer may be stamped for it.
function buff.handle_song_interrupted()
    pending_song = nil
end

-- Called from Sidekick.lua's 0x028 handler on the player's own cast finish
-- (category 4, non-interrupt). spell_id identifies the song that landed, so a
-- different spell finishing just drops the pending entry instead of stamping the
-- wrong song. `started` is the interrupt guard: only a cast we watched the
-- server begin may stamp, so an entry left over from a song that was interrupted
-- or never sent cannot ride a later finish packet into a timer. The age bound is
-- the other half of that: a started cast that died without an interrupt packet
-- must not sit forever waiting to stamp the next hand-cast of the same song.
function buff.handle_song_finished(spell_id)
    local p = pending_song
    pending_song = nil
    if not p or not p.started or p.spell_id ~= spell_id
       or (os.clock() - p.armed_at) > PENDING_SONG_MAX_CAST then
        -- Say which half of the handshake failed -- an empty timer table is
        -- otherwise silent, and the three causes want different fixes.
        if p then
            common.debugf('[SONG] %s stamp dropped: started=%s, age %.1fs, spell %s vs finish %s',
                p.name, tostring(p.started), os.clock() - p.armed_at,
                tostring(p.spell_id), tostring(spell_id))
        end
        return
    end
    local state = common.game_state
    if not state or not state.player then return end
    local dur = p.duration
    if action_core.has_any_buff(state.player.buffs, TROUBADOUR_BUFF) then
        dur = dur * 2
    end
    local now    = os.clock()
    local expiry = now + dur
    for _, sid in ipairs(p.sids) do
        local rows = song_expiry[sid] or {}
        song_expiry[sid] = rows
        -- One caster gets SONG_SLOTS songs on one target, and a new song beyond
        -- that overwrites their OLDEST -- so the table has to evict the same one
        -- the server just did. Both directions matter, and both happen every
        -- cycle in the order this addon sings in: the area pass pushes a
        -- single-target song off a full member, then the single-target pass
        -- pushes an area song off the members it covers. A row left standing for
        -- a song the server already overwrote is a timer that suppresses the
        -- re-sing for its whole duration, and the member sits there holding
        -- neither song.
        -- Re-singing a song we already hold a row for is a refresh of its own
        -- slot: it displaces nothing, so it evicts nothing.
        if not rows[p.name] and not slot_locked[sid] then
            local n = 0
            for _ in pairs(rows) do n = n + 1 end
            -- Oldest by start time, not by time left: durations differ (Troubadour
            -- doubles one song and not the next), so the row with the least time
            -- remaining is not necessarily the one the server drops.
            while n >= SONG_SLOTS do
                local oldest, oldest_at = nil, math.huge
                for name, row in pairs(rows) do
                    if (row.at or 0) < oldest_at then oldest, oldest_at = name, row.at or 0 end
                end
                if not oldest then break end
                song_debugf(sid .. '/evict', '%s evicted from %d: slot taken by %s',
                    oldest, sid, p.name)
                rows[oldest] = nil
                n = n - 1
            end
        end
        rows[p.name] = { at = now, deadline = expiry, verify_at = now + SONG_VERIFY_DELAY }
    end
end

-- os.clock() of our last cast per ability name, for buffs whose target we can't
-- read (pet buffs aren't tracked). Cleared on reload -> re-applies immediately.
local last_self_cast = {}

-- How many distinct selected songs share this ability's buff_id for target_key
-- (0-5, or 'A'). A grouped group contributes one (only one tier is ever active);
-- an ungrouped group contributes one per selected tier, so stacking tiers each
-- demand their own instance.
local function wanted_instances(ability, target_key, available_abilities, settings, party_buff_config)
    local keys = {}
    for _, b in ipairs(available_abilities) do
        if b.buff_id == ability.buff_id then
            keys[common.ability_config_key(b, settings)] = true
        end
    end
    local n = 0
    for key in pairs(keys) do
        local cfg = party_buff_config[key]
        if cfg and cfg[target_key] == true then n = n + 1 end
    end
    return n
end

-- True when target lacks enough instances of this song's buff to satisfy every
-- selected tier sharing that buff_id. Falls back to the plain presence check
-- (handles buff_id == nil) unless two or more tiers are stacked. Songs that
-- share a buff_id stack as separate instances (e.g. Mage's Ballad + Mage's
-- Ballad II = two of buff 196), so a plain "has it" check is not enough.
-- With manual song timers active, the timer we hold for this member IS the
-- answer, both ways: expired = re-sing (before the buff drops), still running =
-- not needed. The instance count must not get a vote there, because it counts
-- a shared buff_id in bulk and can't tell WHICH tier a member is short of --
-- one member missing one March would otherwise report every March needed and
-- re-sing them all on cooldown. The memory check governs only songs we hold no
-- timer for (first sing after a reload, a member who just joined); the cost is
-- that an interrupted re-sing isn't noticed until its timer runs out.
local function song_needed(target_buffs, ability, target_key, available_abilities, settings, party_buff_config, member, manual)
    if manual and ability.magic == 'song' and member then
        -- No landing check on a Trust: their buff list is the one this file
        -- distrusts everywhere else (drops go undetected, stacked tiers show as
        -- one), so a song missing from it proves nothing -- and verifying would
        -- throw the timer away and drop them back to recasting off that same
        -- unreliable list. The timer is all we have for them, so it stands.
        local deadline = song_deadline(ability, member, member.is_trust)
        if deadline then return os.clock() >= deadline end
    end
    local wanted = wanted_instances(ability, target_key, available_abilities, settings, party_buff_config)
    if wanted <= 1 then
        return action_core.needs_buff(target_buffs, ability.buff_id)
    end
    return action_core.count_instances(target_buffs, ability.buff_id) < wanted
end

-- Config keys (group name, or ability name when ungrouped) for THIS job's songs.
-- Only these count toward a member's song slots. party_buff_config is shared
-- across every job and buff type (WHM cures/-na, Geo, etc.), so scanning all of
-- it would mistake unrelated self-buffs for songs and wrongly mark everyone's
-- slots full -- which silently kills every area song.
local function song_config_keys(job_def, settings)
    local keys = {}
    for _, ability in ipairs(job_def.abilities.buff or {}) do
        if ability.magic == 'song' then
            keys[common.ability_config_key(ability, settings)] = true
        end
    end
    return keys
end

-- Party indices (0-5) mapped to how many single-target (Pianissimo) songs are
-- configured for that member. Feeds both dedicated_targets (full/not-full) and
-- area_needs_recast (partial capacity math).
local function single_target_song_counts(party_buff_config, song_keys)
    local counts = {}
    for key in pairs(song_keys) do
        local targets = party_buff_config[key]
        if type(targets) == 'table' then
            for idx, v in pairs(targets) do
                if v == true and type(idx) == 'number' and idx >= 0 and idx <= 5 then
                    counts[idx] = (counts[idx] or 0) + 1
                end
            end
        end
    end
    return counts
end

-- Party indices (0-5) whose song slots are already FULL of single-target
-- (Pianissimo) songs. A bard holds `song_limit` songs per member (2 main / 1
-- sub); once that many single-target SONGS are assigned to a member there's no
-- free slot for an area song, so it must not TRIGGER an area recast for them. A
-- member with a free slot still gets covered.
local function dedicated_targets(party_buff_config, song_keys, song_limit)
    local counts = single_target_song_counts(party_buff_config, song_keys)
    local dedicated = {}
    for idx, c in pairs(counts) do
        if c >= song_limit then dedicated[idx] = true end
    end
    return dedicated
end

-- True when no member's buff list can answer "is the area song still up?".
-- A member is unreadable when they are a Trust (drops go undetected and stacked
-- tiers show as one), out of zone or out of song range, dead, or have every song
-- slot assigned to single-target songs -- those overwrite the area song, so its
-- absence from their buffs proves nothing. Self is judged on the slot test alone.
--
-- With nobody readable the memory check can never fire: area songs are never
-- reported missing, so they are never re-sung and the single-target pass is the
-- only thing that ever sings -- which is exactly backwards, since a single sung
-- with an area song owed loses the slot to it later. So the area songs fall back
-- to a timer at DEFAULT_SONG_DURATION instead.
local function no_readable_voter(party_buff_config, song_keys, state)
    local single_counts = party_buff_config
        and single_target_song_counts(party_buff_config, song_keys) or {}
    local player_zone   = common.get_party_member_zone(0)
    for ti = 0, 5 do
        local member = (ti == 0) and state.player or state.party[ti]
        if (SONG_SLOTS - (single_counts[ti] or 0)) > 0 and not song_member_dead(member) then
            if ti == 0 then return false end
            if member and not member.is_trust then
                local ei = member.target_index
                if ei and ei > 0 and player_zone == common.get_party_member_zone(ti)
                   and common.is_in_range(ei, SONG_AOE_RANGE) then
                    return false
                end
            end
        end
    end
    return true
end

-- If `ability` is the active [A] area song to consider this cycle, return its
-- config key (group name, or ability name when ungrouped); else nil. Mirrors the
-- group-selection rules the single-target pass uses.
local function area_song_config_key(ability, settings, party_buff_config, area_processed)
    -- Every bard song gets an area toggle. Songs cast area by omitting Pianissimo;
    -- the single-target pass adds Pianissimo for ME/P1-P5.
    if ability.magic ~= 'song' then return nil end
    local grouped = ability.group and settings['ungrouped_' .. ability.group] ~= true
    local config_key
    if grouped then
        config_key = ability.group
        local selected = settings['selected_' .. ability.group]
        if selected then
            if selected ~= ability.name then return nil end
        else
            if area_processed[ability.group] then return nil end
            area_processed[ability.group] = true
        end
    else
        config_key = ability.name
    end
    if not (party_buff_config[config_key] and party_buff_config[config_key]['A'] == true) then
        return nil
    end
    return config_key
end

-- True when any in-range party member with a free song slot lacks the song, so
-- the area song should be (re)cast.
--
-- "Free slot" is capacity math, not all-or-nothing: a member with one
-- single-target song assigned (e.g. Ballad) and two area songs configured
-- (e.g. Minuet + March) only has room for song_limit - 1 of them. Once
-- they're holding that many area songs -- whichever ones they happen to be --
-- they're satisfied (single target OK with Ballad + (Minuet OR March)); this
-- stops the single/area songs from endlessly knocking each other off the same
-- member's last slot.
-- Why an area song was demanded, for /sk debug. A stuck area song is always one
-- member voting the same reason every tick, and the reason says which of the
-- three tests it came from.
local function area_vote(ability, ti, reason, buffs)
    if common.debug then
        local ids = {}
        for _, id in ipairs(buffs or {}) do ids[#ids + 1] = tostring(id) end
        song_debugf(ability.name .. '/vote', '%s area recast: %s -- %s [buffs: %s]', ability.name,
            ti == 0 and 'ME' or ('P' .. ti), reason,
            #ids > 0 and table.concat(ids, ',') or 'none')
    end
    return true
end

local function area_needs_recast(ability, party_buff_config, song_keys, available_abilities, settings, state, manual)
    local tier_is_main  = ability.is_main_job ~= false
    local song_limit    = tier_is_main and 2 or 1
    local single_counts = single_target_song_counts(party_buff_config, song_keys)

    -- Every ability that is this cycle's active [A] area song and shares this
    -- ability's main/sub tier, for counting how many area-song slots a member
    -- already holds.
    local area_list = {}
    local area_processed = {}
    for _, a in ipairs(available_abilities) do
        if (a.is_main_job ~= false) == tier_is_main
           and area_song_config_key(a, settings, party_buff_config, area_processed) then
            area_list[#area_list + 1] = a
        end
    end

    local player_zone = common.get_party_member_zone(0)
    for ti = 0, 5 do
        local member    = (ti == 0) and state.player or state.party[ti]
        local remaining = song_limit - (single_counts[ti] or 0)
        -- A corpse is skipped outright (and forgets its timers): their buff list
        -- is empty, so letting it vote would recast the area song on cooldown --
        -- restamping everyone else early each time -- until they are raised.
        if not song_member_dead(member) then
            local target_buffs
            if ti == 0 then
                -- Self is always in range/zone and covered by a self-cast song.
                target_buffs = state.player.buffs or {}
            else
                -- Trusts have unreliable buff tracking: drops aren't detected and
                -- only one copy of a buff_id is visible (stacked songs like Ballad
                -- I+II always look short), which would force an endless area recast.
                -- Skip them -- self/real players drive recast timing and the AoE
                -- covers in-range trusts on that same cast.
                if member and not member.is_trust then
                    local ei = member.target_index
                    local mz = common.get_party_member_zone(ti)
                    if ei and ei > 0 and player_zone == mz and common.is_in_range(ei, SONG_AOE_RANGE) then
                        target_buffs = member.buffs or {}
                    end
                end
            end
            -- Every slot spoken for by single-target (Pianissimo) songs. The area
            -- song still LANDS on them -- Phase 1 sings before Phase 2 does -- it
            -- just can't be seen afterwards, because those singles overwrite it.
            -- Their buff list is a permanent "missing" and must never vote by
            -- memory; the timer stamped on the area cast is the only truth left.
            -- So with manual timers on they vote by that alone (no timer = never
            -- sung; expired = due), and without them they stay silent as before,
            -- since there is no schedule to sing on.
            --
            -- This is what lets a bard hand the party area songs and keep the
            -- single-target ones for themselves: a solo bard, or one whose party is
            -- all Trusts, is otherwise the only voter there is, and used to veto
            -- every area song outright.
            local slots_full = remaining <= 0
            local deadline   = target_buffs and manual and song_deadline(ability, member, slots_full) or nil
            if target_buffs and slots_full then
                if manual and (not deadline or os.clock() >= deadline) then
                    return area_vote(ability, ti, deadline and 'slots full, timer expired'
                        or 'slots full, no timer held', target_buffs)
                end
            -- Manual timers: while we hold one for this member it decides alone
            -- (see song_needed). Expired forces the recast outright -- memory
            -- still shows the old instance we're deliberately overwriting, so
            -- counting it would veto the early re-sing. Still running skips this
            -- member entirely -- the held-count math below counts a shared
            -- buff_id in bulk and would re-sing a March they already have.
            -- (Trusts never reach here: target_buffs stays nil for them above,
            -- and while area casts stamp them, their entries are never read.)
            elseif deadline then
                if os.clock() >= deadline then
                    return area_vote(ability, ti, 'timer expired', target_buffs)
                end
            elseif target_buffs and song_needed(target_buffs, ability, 'A', available_abilities, settings, party_buff_config) then
                -- Count buff INSTANCES per distinct buff_id, not presence per song:
                -- two area songs sharing an id (Victory + Advancing March = 214)
                -- would each see the same single instance and report the member
                -- full after one of them landed, so the second never cast.
                local held, counted = 0, {}
                for _, a in ipairs(area_list) do
                    if a.buff_id and not counted[a.buff_id] then
                        counted[a.buff_id] = true
                        held = held + action_core.count_instances(target_buffs, a.buff_id)
                    end
                end
                if held < remaining then
                    return area_vote(ability, ti, string.format('holds %d area song(s), %d slot(s) free',
                        held, remaining), target_buffs)
                end
            end
        end
    end
    return false
end

function buff.execute(settings, job_def, main_level, sub_level, player_resource, party_buff_config)
    -- Ahead of every guard below, so a pair popped while resting -- or with
    -- buffing switched off -- still opens (and closes) a window. Not every tick,
    -- though: a higher-priority module winning the tick skips buff.execute
    -- entirely. Harmless, because the arm/disarm always runs before any
    -- song_deadline read in the same call, so a stale window never reaches a vote.
    update_song_force(common.game_state)

    -- Check if buff is enabled
    if not settings.buff_enabled then
        return nil
    end

    -- Do not apply buffs while resting
    if common.is_resting() then
        return nil
    end

    -- Read player data from game_state
    local state  = common.game_state
    local player = state and state.player
    if not player then
        return nil
    end

    local derived_main_level = player.main_level
    local derived_sub_level  = player.sub_level

    -- Track which groups have been processed in this execution (local, never persisted)
    local processed_groups = {}
    
    -- Get party buff configuration from ui_config if not provided
    local ui_config = require('lib.ui.config')
    if not party_buff_config then
        party_buff_config = ui_config.get_party_buffs()
    end
    -- Session-only per-target Combat/Idle overrides (right-click on ME/P1-P5).
    local party_buff_gates = ui_config.get_party_buff_gates()
    
    -- Get buff abilities from job definition
    local buff_abilities = job_def.abilities.buff or {}
    if #buff_abilities == 0 then
        return nil
    end

    -- Auto-equip a consumable a buff needs in the ammo slot (BST Reward Regen ->
    -- Pet Poultice; NIN Sange -> Shuriken). For pet buffs this is only reached
    -- after the higher-priority pet-heal passed this tick, so biscuit and poultice
    -- never contend; ammo_equip_command itself skips pet-only ammo when no pet.
    local equip = common.ammo_equip_command(buff_abilities, settings, player)
    if equip then return equip end

    -- Filter abilities by level and settings
    local available_abilities = common.filter_abilities_by_level(buff_abilities, settings, derived_main_level, derived_sub_level, job_def, party_buff_gates)

    if #available_abilities == 0 then
        return nil
    end

    -- Any cast breaks Invisible (69), so while it's up cast travel buffs only.
    -- Heals, -na, wake and revive are other modules and stay ungated.
    if action_core.has_any_buff(state.player.buffs, INVISIBLE_BUFF) then
        local travel_only = {}
        for _, a in ipairs(available_abilities) do
            if a.travel_buff then travel_only[#travel_only + 1] = a end
        end
        -- No travel buff castable (job has none, or in combat -- all are idle_only) = no gate.
        if #travel_only > 0 then available_abilities = travel_only end
    end

    -- Phase 1: area songs ([A]). Checked before the single-target ME/P1-P5 pass
    -- because an AoE song overwrites single-target songs on everyone it hits, so
    -- the area baseline must be established first. Covers every in-range party
    -- member that isn't given a specific ME/P button (see dedicated_targets).
    --
    -- Skip while Pianissimo is active: it makes the NEXT song single-target, so an
    -- area cast now would fire single-target by mistake. Let the single-target
    -- pass consume the Pianissimo first, then area-cast on a later cycle.
    -- (Fast-casting mode is the deliberate exception -- see below.)
    local tmods = job_def.abilities.target_modifier
    local has_pianissimo = tmods and tmods[1]
        and action_core.has_any_buff(state.player.buffs, tmods[1].buff_id)
    -- Fast-casting mode raises Pianissimo on purpose for the area cast (shorter
    -- cast time), then strips it mid-cast so the song still lands as area. In that
    -- mode we run the area phase even while Pianissimo is up, since it's ours.
    -- Suspended while Nightingale is up: it already shortens song casting, so the
    -- Pianissimo trick would only burn Pianissimo and a /debuff for nothing.
    -- (If Nightingale lands between our Pianissimo raise and the song, the area
    -- phase skips until something consumes the Pianissimo or it wears -- rare,
    -- since players fire Nightingale before singing, not mid-sequence.)
    local fast_casting = settings.pianissimo_fast_casting == true
        and not action_core.has_any_buff(state.player.buffs, NIGHTINGALE_BUFF)
    -- Manual song timers (see song_expiry above), main-job BRD75 only, and split
    -- in two because the two passes are not in the same position.
    --   manual_tracking -- ALL songs, and only on the explicit Song Duration.
    --     Single-target songs land on members whose buff lists we can read, so
    --     memory is a fine fallback there; guessing an interval for a bard in
    --     duration gear would re-sing their own songs a minute early.
    --   area_manual -- [A] songs alone. When nobody left in the area pool has a
    --     readable buff list (an all-Trust remainder, or a bard whose own slots
    --     are full of [ME] songs) memory can never report an area song missing,
    --     so it is never re-sung and the single-target pass becomes the only
    --     thing that sings -- backwards, since the area song takes those slots
    --     back the moment it does fire. Falls back to DEFAULT_SONG_DURATION.
    local song_keys = song_config_keys(job_def, settings)
    local song_duration = tonumber(settings.song_duration) or 0
    local is_bard75 = player.job == 10 and (player.main_level or 0) >= 75
    local manual_tracking = is_bard75 and song_duration > 0
    local area_manual, area_duration = manual_tracking, song_duration
    if is_bard75 and not manual_tracking
       and no_readable_voter(party_buff_config, song_keys, state) then
        area_manual, area_duration = true, DEFAULT_SONG_DURATION
    end

    -- Members whose slots are wholly assigned to single-target songs. The area
    -- timer we hold for them is a re-sing SCHEDULE for the group, not a claim
    -- the song is on them -- it is not, their own singles overwrote it, which is
    -- the same reason the area pass skips verifying them. So a single-target
    -- stamp must not evict it: doing so leaves the area pass reading "no timer
    -- held" and recasting on cooldown, the very thing these timers exist to
    -- stop. Refreshed here and read at cast finish rather than threaded through
    -- the pending entry -- the config cannot change in the second between them.
    slot_locked = {}
    if (manual_tracking or area_manual) and party_buff_config then
        for ti in pairs(dedicated_targets(party_buff_config, song_keys, SONG_SLOTS)) do
            local m   = (ti == 0) and state.player or state.party[ti]
            local sid = m and m.server_id
            if sid and sid ~= 0 then slot_locked[sid] = true end
        end
    end
    -- Set when a due [A] song did not go out this tick for any reason: Phase 2
    -- skips single-target songs while it holds, since the area song would
    -- overwrite them moments later. Declared out here because Phase 2 reads it.
    local hold_songs = false
    if fast_casting or not has_pianissimo then
        -- Hold AOE for Group: members with at least one single-target (Pianissimo)
        -- song assigned are managed individually, so their range must not gate the
        -- area cast -- exclude them (threshold 1, not song_limit).
        local aoe_excl = settings.hold_aoe_for_group
            and dedicated_targets(party_buff_config, song_keys, 1) or nil
        local area_processed = {}
        -- Set when an [A] song still needs (re)casting but couldn't fire this
        -- tick -- recast, cost, ailment, anything. Forces a hold so the
        -- single-target pass can't jump ahead and get overwritten by the area
        -- song later. See the comment on the two holds below for what each mode
        -- does with it.
        local area_pending = false
        for _, ability in ipairs(available_abilities) do
            local config_key = area_song_config_key(ability, settings, party_buff_config, area_processed)
            -- The area [A] button has no per-target override of its own, so it must
            -- still obey the ability's plain global gate even when filter_abilities_by_level
            -- let the ability through only because some OTHER target (ME/P1-P5) overrode it.
            if config_key and common.ability_gate_ok_now(ability, settings)
               and area_needs_recast(ability, party_buff_config, song_keys, available_abilities, settings, state, area_manual) then
                if aoe_excl and not common.group_in_aoe_range(SONG_AOE_RANGE, aoe_excl) then
                    -- Hold: a member with no single-target song is out of range.
                    -- Don't area-cast and don't mark pending, so the single-target
                    -- pass still manages Pianissimo-assigned members this tick.
                    common.announce_gather(ability.name, settings)
                elseif fast_casting and not has_pianissimo then
                    -- Only raise Pianissimo once the song is off recast and affordable,
                    -- else Pianissimo's own recast burns down while the song waits.
                    local eff_cost = common.effective_ability_cost(ability, settings, job_def)
                    if action_core.is_usable(ability, job_def, eff_cost) then
                        -- Fast mode always holds: wait for Pianissimo rather than
                        -- casting the area song without it.
                        return common.check_target_modifier(job_def, settings, derived_main_level, derived_sub_level)
                    end
                    area_pending = true
                else
                    local desc = string.format('Applying area buff: %s', ability.name)
                    local result, reason = action_core.try_use(ability, job_def, settings, 0, desc, state)
                    song_debugf(ability.name .. '/cast', '%s area cast: %s', ability.name,
                        result and 'sent' or ('BLOCKED -- ' .. tostring(reason)))
                    if result then
                        -- Queue everyone the area cast covers for this song's
                        -- re-sing deadline; stamped when the cast finishes.
                        -- Not on a stratagem result: try_use returns the precast
                        -- JA instead of the song there (BRD/SCH), so the song
                        -- hasn't been sent and stamping it would skip it entirely.
                        if area_manual and ability.magic == 'song' and not result.is_stratagem then
                            queue_song_stamp(ability, area_duration, state, nil)
                        end
                        -- Pianissimo up (fast cast): schedule its removal so the song
                        -- reverts single-target -> area once casting is underway.
                        if fast_casting and has_pianissimo then
                            if type(result) ~= 'table' then result = { command = result, description = desc } end
                            result.scheduled_removal = { command = '/debuff 409', delay = 1.0 }
                        end
                        return result
                    end
                    area_pending = true
                end
            end
        end
        -- Every configured [A] song must be established before the single-target
        -- pass sings, in both modes, and for ANY reason the area cast did not go
        -- out -- not just a recast. The two overwrite each other on every member
        -- they share, so a single sung while an area song is still owed is a cast
        -- thrown away, and the area song that follows it takes the slot back.
        -- Fast-casting holds the whole pass (its Phase 2 songs are blocked by the
        -- same silence/MP anyway, so nothing is lost).
        if fast_casting and area_pending then
            return nil
        end
        -- Normal mode holds back the single-target SONGS only. They are the ones
        -- the area cast would overwrite; every other buff the job maintains (a
        -- subjob Protect, Nightingale, a rune) has nothing to do with the area
        -- song and must not be stalled behind it -- which returning out of the
        -- module here would do.
        -- The one thing that does NOT hold is the gather wait above: it leaves
        -- area_pending clear on purpose, so a member out of range can't stop the
        -- single-target pass from managing the members it can reach.
        hold_songs = area_pending
    end

    -- Phase 2: single-target buffs (ME/P1-P5, alliance, tracked).
    -- Check each buff to see if it needs to be applied/refreshed
    for _, ability in ipairs(available_abilities) do
        local should_skip = false

        -- A group the user has "ungrouped" casts every tier independently
        -- (keyed by ability name, like a non-grouped ability) instead of only
        -- the single selected tier. Off (grouped) by default.
        local grouped = ability.group and settings['ungrouped_' .. ability.group] ~= true

        -- While in combat with Geo-bt enabled, reserve the single luopan for the
        -- enemy debuff -- don't try to place a Geo buff luopan. (Geo-bt itself
        -- lives in abilities.geo now, so it never reaches this buff loop.)
        if ability.group == 'Geo' and common.is_combat() and settings['disabled_group_Geo-bt'] ~= true then
            goto continue_ability
        end

        -- An [A] song is due and only its recast is in the way: singing a
        -- single-target song now throws the cast away, since the area song
        -- overwrites it as soon as the recast is up. Songs only -- see hold_songs.
        if hold_songs and ability.magic == 'song' then
            goto continue_ability
        end

        -- Check pet requirement
        if not should_skip and ability.pet_required then
            if not common.targets.get_pet() then
                should_skip = true
            end
        end
        
        -- Check required buff prerequisite for player. An assigned precast that grants
        -- the buff (SCH Enlightenment) counts as met -- check_stratagem fires the JA
        -- below and holds the spell until its buff lands.
        if not should_skip and ability.requires_buff then
            if not action_core.has_any_buff(state.player.buffs, ability.requires_buff)
                and not common.precast_satisfies_prereq(job_def, settings, ability) then
                should_skip = true
            end
        end
        
        -- Check if this ability is blocked by status ailments
        if not should_skip then
            local blocked_by = common.is_command_blocked(ability.command)
            if blocked_by then
                should_skip = true
            end
        end

        -- Check if a self-buff blocks this ability (DNC Fan Dance blocks Sambas)
        if not should_skip and action_core.is_self_blocked(ability, state.player.buffs) then
            should_skip = true
        end
        
        if not should_skip then
            -- Determine if this is a single-target buff (function command) or self-only buff (string command)
            local is_single_target = type(ability.command) == 'function'
            
            if is_single_target then
                -- Single-target buff: Check button states for ME and party members (P1-P5)
                -- First check if ability/group is enabled via settings
                local key
                local config_key
                if grouped then
                    key = 'disabled_group_' .. ability.group
                    config_key = ability.group
                    
                    -- Check if this ability is the selected one for this group
                    local selected_key = 'selected_' .. ability.group
                    local selected_ability = settings[selected_key]
                    if selected_ability then
                        -- A specific ability is selected, only use that one
                        if selected_ability ~= ability.name then
                            goto continue_ability
                        end
                    else
                        -- No selection made yet - UI will handle this on next open
                        -- For now, skip all but the first available ability in this group
                        -- (filter_abilities_by_level already sorted by cost descending = highest level first)
                        -- Check if we've already processed an ability from this group
                        if processed_groups[ability.group] then
                            -- Already processed another ability from this group, skip this one
                            goto continue_ability
                        else
                            -- Mark this group as processed for this execution cycle
                            processed_groups[ability.group] = true
                        end
                    end
                else
                    key = 'disabled_' .. ability.name:gsub(' ', '_')
                    config_key = ability.name
                end
                local is_ability_enabled = settings[key] == false or settings[key] == nil
                
                if not is_ability_enabled then
                    goto continue_ability
                end
                
                -- Check if any party buttons are enabled
                local has_any_target = false
                if party_buff_config and party_buff_config[config_key] then
                    for k, v in pairs(party_buff_config[config_key]) do
                        if v == true then
                            has_any_target = true
                            break
                        end
                    end
                end
                
                if not has_any_target then
                    goto continue_ability
                end
                
                -- Priority order: ME, P1, P2, P3, P4, P5 (0 = ME, 1-5 = P1-P5).
                -- travel buffs put the caster LAST: their own Invisible must be the final
                -- cast of the run or the next one breaks it.
                local targets_to_check = ability.travel_buff and {1, 2, 3, 4, 5, 0} or {0, 1, 2, 3, 4, 5}

                for _, target_index in ipairs(targets_to_check) do
                    -- Check if this target is enabled in party_buff_config
                    local is_target_enabled = false
                    if party_buff_config and party_buff_config[config_key] then
                        is_target_enabled = party_buff_config[config_key][target_index] == true
                    end
                    
                    if is_target_enabled then
                        -- Per-target Combat/Idle override (right-click on ME/P1-P5) replaces
                        -- the ability's own gate for this one target; falls back to it otherwise.
                        if not common.target_gate_ok(ability, config_key, target_index, settings, party_buff_gates) then
                            goto continue_target
                        end

                        local target_buffs = nil
                        local target_needs_buff = false
                        local target_entity_index = nil
                        
                        -- Get target buffs and entity index
                        if target_index == 0 then
                            -- ME: Check player buffs from game_state
                            target_buffs = state.player.buffs or {}
                            target_entity_index = 0
                        else
                            -- P1-P5: Check party member buffs from game_state
                            -- Zone check stays as live call (zone not stored in game_state)
                            local party_member = state.party[target_index]
                            -- Trusts take none of the aggro travel buffs prevent, so casting
                            -- one on a Trust is wasted MP and a wasted tick.
                            if party_member and (common.is_trust_excluded(party_member.name, party_member.server_id)
                                or (ability.travel_buff and party_member.is_trust)) then
                                goto continue_target
                            end
                            if party_member then
                                local player_zone = common.get_party_member_zone(0)
                                local member_zone = common.get_party_member_zone(target_index)
                                target_entity_index = party_member.target_index
                                
                                if target_entity_index and target_entity_index > 0 and player_zone == member_zone and common.is_in_range(target_entity_index, 20) then
                                    target_buffs = party_member.buffs or {}
                                else
                                    -- Party member not available or out of range, skip
                                    goto continue_target
                                end
                            else
                                -- Party member not active in game_state, skip
                                goto continue_target
                            end
                        end
                        
                        -- A Geo bubble is dropped where its target is standing and
                        -- stays put, so casting on someone mid-stride just leaves it
                        -- behind them. Wait for them to stop.
                        if ability.group == 'Geo'
                            and common.is_entity_moving(common.targets.get_party_member(target_index)) then
                            common.debugf('[BUFF] %s held: %s is moving', ability.name,
                                target_index == 0 and 'you' or ('P' .. target_index))
                            goto continue_target
                        end

                        -- Check if target needs buff (manual song timers can force
                        -- an early re-sing; see song_needed)
                        local member_snapshot = (target_index == 0) and state.player or state.party[target_index]
                        -- Same corpse rule the area pass uses: songs don't stick to
                        -- the dead, so don't sing at them and drop the timers we
                        -- held for them (see song_member_dead).
                        if ability.magic == 'song' and song_member_dead(member_snapshot) then
                            goto continue_target
                        end
                        target_needs_buff = song_needed(target_buffs, ability, target_index, available_abilities, settings, party_buff_config, member_snapshot, manual_tracking)
                        
                        if target_needs_buff then
                            -- Check if this ability requires a target modifier (Pianissimo, Entrust, etc.)
                            -- Includes ME (target_index 0): songs are now single-target on self via
                            -- Pianissimo, matching P1-P5. The area ([A]) pass above handles no-Pianissimo AoE.
                            if ability.target_modifier then
                                -- Check if we already have the modifier buff active
                                local has_modifier_buff = false
                                if job_def.abilities.target_modifier and #job_def.abilities.target_modifier > 0 then
                                    local modifier_ability = job_def.abilities.target_modifier[1]
                                    has_modifier_buff = action_core.has_any_buff(state.player.buffs, modifier_ability.buff_id)
                                end
                                
                                if not has_modifier_buff then
                                    -- Only raise the modifier once the song is off recast
                                    -- and affordable, else its recast burns down while the
                                    -- song waits.
                                    local eff_cost = common.effective_ability_cost(ability, settings, job_def)
                                    if not action_core.is_usable(ability, job_def, eff_cost) then
                                        goto continue_ability
                                    end
                                    -- Don't have modifier buff, try to use it
                                    local modifier_result = common.check_target_modifier(job_def, settings, derived_main_level, derived_sub_level)
                                    if modifier_result then
                                        -- Need to use modifier ability first
                                        return modifier_result
                                    else
                                        -- Modifier unavailable (on cooldown, disabled, etc.), skip this ability for now
                                        return nil
                                    end
                                end
                                -- If we reach here, we have the modifier buff, proceed to cast the song
                            end
                            
                            -- Use action_core for resource + cooldown + command building
                            local target_name = target_index == 0 and 'self' or (state.party[target_index] and state.party[target_index].name or ('P' .. target_index))
                            local desc = string.format('Applying buff: %s to %s', ability.name, target_name)

                            local result, reason = action_core.try_use(ability, job_def, settings, target_index, desc, state)
                            if result then
                                -- is_stratagem = the precast JA fired, not the song
                                -- itself; nothing to stamp until the song goes out.
                                if manual_tracking and ability.magic == 'song' and not result.is_stratagem then
                                    queue_song_stamp(ability, song_duration, state, target_index)
                                end
                                return result
                            end
                        end
                        
                        ::continue_target::
                    end
                end

                -- After checking party members, check enabled alliance members
                -- (only if ability has target_outside, same restriction as tracked targets).
                -- The combat/idle gate is per-target (right-click a B/C button), checked
                -- inside the loop below alongside the party ME/P1-P5 buttons.
                if ability.target_outside and state.alliance then
                    for al_pi = 2, 3 do
                        local sub_party = state.alliance[al_pi]
                        if sub_party then
                            local base_flat = (al_pi - 1) * 6
                            for local_idx = 0, 5 do
                                local flat_index = base_flat + local_idx
                                local al_key = 'al_' .. flat_index
                                local is_al_enabled = party_buff_config and party_buff_config[config_key] and party_buff_config[config_key][al_key] == true
                                if is_al_enabled and common.target_gate_ok(ability, config_key, al_key, settings, party_buff_gates) then
                                    local m = sub_party[local_idx]
                                    -- Same travel_buff Trust skip as the party loop -- other
                                    -- players' Trusts show up in the alliance sub-parties.
                                    if m and not (ability.travel_buff and m.is_trust) and m.is_active and m.target_index and m.target_index > 0 and common.is_in_range(m.target_index, 20) then
                                        local al_buffs = m.buffs or {}
                                        local al_needs_buff = action_core.needs_buff(al_buffs, ability.buff_id)
                                        if al_needs_buff then
                                            local eff_cost = common.effective_ability_cost(ability, settings, job_def)
                                            local ok_use, _ = action_core.is_usable(ability, job_def, eff_cost)
                                            if ok_use then
                                                -- Check stratagems before casting
                                                local strat_result = common.check_stratagem(job_def, settings, ability.name, ability)
                                                if strat_result == false then ok_use = false
                                                elseif strat_result then return strat_result end
                                            end
                                            if ok_use then
                                                local command = common.build_ability_command_for_target(ability, m.server_id)
                                                if command then
                                                    if ability.buff_id then
                                                        local bid = type(ability.buff_id) == 'table' and ability.buff_id[1] or ability.buff_id
                                                        common.register_pending_buff(m.server_id, bid, ability.name, ability.spell_id)
                                                    end
                                                    local desc = string.format('Applying buff: %s to alliance %s', ability.name, m.name)
                                                    return { command = command, description = desc }
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- After checking party members, also check tracked targets (only if ability has target_outside)
                -- Same per-target combat/idle gate as the alliance loop above -- right-click
                -- a T button to override the ability's own gate for that target.
                if ability.target_outside and state.tracked then
                    for sid, tt in pairs(state.tracked) do
                        -- Check if this tracked target has its button enabled in the config
                        local tt_key = 'tt_' .. sid
                        local is_tt_enabled = party_buff_config and party_buff_config[config_key] and party_buff_config[config_key][tt_key] == true
                        if is_tt_enabled and common.target_gate_ok(ability, config_key, tt_key, settings, party_buff_gates)
                            and tt.is_active and tt.target_index and tt.target_index > 0 and common.is_in_range(tt.target_index, 20) then
                            local tt_buffs = tt.buffs or {}
                            local tt_needs_buff = action_core.needs_buff(tt_buffs, ability.buff_id)
                            if tt_needs_buff then
                                local eff_cost = common.effective_ability_cost(ability, settings, job_def)
                                local ok, reason = action_core.is_usable(ability, job_def, eff_cost)
                                if ok then
                                    -- Check stratagems before casting
                                    local strat_result = common.check_stratagem(job_def, settings, ability.name, ability)
                                    if strat_result == false then ok = false
                                    elseif strat_result then return strat_result end
                                end
                                if ok then
                                    local command = common.build_ability_command_for_target(ability, sid)
                                    if command then
                                        -- Register pending buff for packet tracking
                                        if ability.buff_id then
                                            local bid = type(ability.buff_id) == 'table' and ability.buff_id[1] or ability.buff_id
                                            common.register_pending_buff(sid, bid, ability.name, ability.spell_id)
                                        end
                                        local desc = string.format('Applying buff: %s to tracked %s', ability.name, tt.name)
                                        return { command = command, description = desc }
                                    end
                                end
                            end
                        end
                    end
                end
            else
                -- Self-only buff: Use checkbox-based logic (original behavior)
                -- Check if ability/group is enabled via settings
                local key
                if grouped then
                    key = 'disabled_group_' .. ability.group
                    
                    -- Check if this ability is the selected one for this group
                    local selected_key = 'selected_' .. ability.group
                    local selected_ability = settings[selected_key]
                    if selected_ability then
                        -- A specific ability is selected, only use that one
                        if selected_ability ~= ability.name then
                            goto continue_ability
                        end
                    else
                        -- No selection made yet - UI will handle this on next open
                        -- For now, skip all but the first available ability in this group
                        -- (filter_abilities_by_level already sorted by cost descending = highest level first)
                        -- Check if we've already processed an ability from this group
                        if processed_groups[ability.group] then
                            -- Already processed another ability from this group, skip this one
                            goto continue_ability
                        else
                            -- Mark this group as processed for this execution cycle
                            processed_groups[ability.group] = true
                        end
                    end
                else
                    key = 'disabled_' .. ability.name:gsub(' ', '_')
                end
                local is_enabled = settings[key] == false or settings[key] == nil
                
                if not is_enabled then
                    goto continue_ability
                end
                
                -- For buffs we can't detect on the target (e.g. pet Regen from
                -- Reward), reapply_interval is the effect's duration in seconds;
                -- skip until that has elapsed since our last cast so we don't
                -- reapply every recast and waste the consumable.
                if ability.reapply_interval then
                    local last = last_self_cast[ability.name]
                    if last and (os.clock() - last) < ability.reapply_interval then
                        goto continue_ability
                    end
                end

                -- Ninja "Cast with 1 Shadow": Utsusemi normally blocks while ANY
                -- Copy Image buff is up (66/444/445/446). This mode ignores the
                -- 1-shadow buff (one_shadow_buff = 66) so it recasts at 1 shadow,
                -- then strips 66 mid-cast (/debuff 66) so the new shadows apply.
                local needs_buff
                local strip_one_shadow = false
                if ability.one_shadow_buff and settings.cast_with_1_shadow == true then
                    local blocking = {}
                    for _, id in ipairs(action_core.normalize_ids(ability.buff_id)) do
                        if id ~= ability.one_shadow_buff then blocking[#blocking + 1] = id end
                    end
                    needs_buff = action_core.needs_buff(state.player.buffs, blocking)
                    strip_one_shadow = needs_buff
                        and action_core.has_any_buff(state.player.buffs, ability.one_shadow_buff)
                else
                    needs_buff = action_core.needs_buff(state.player.buffs, ability.buff_id)
                end

                if needs_buff then
                    -- Hold AOE for Group: Protectra/Shellra/Bar (WHM), Diamondhide
                    -- (BLU) are <me> self-casts that hit the party. Hold until the
                    -- group is in range. goto (not return) so a held AOE buff doesn't
                    -- block lower-priority non-AOE self-buffs this tick.
                    if ability.aoe and settings.hold_aoe_for_group
                       and not common.group_in_aoe_range() then
                        common.announce_gather(ability.name, settings)
                        goto continue_ability
                    end

                    -- Always-required precast (BLU Unbridled Learning): the
                    -- spell cannot function without the JA's buff. Fire the JA
                    -- first -- but only when the spell itself could follow it
                    -- (usable, and not held back waiting on Diffusion) so the
                    -- JA isn't popped for nothing.
                    local pre = common.check_required_precast(job_def, ability)
                    if pre == false then goto continue_ability end
                    if pre then
                        local eff_cost = common.effective_ability_cost(ability, settings, job_def)
                        if not action_core.is_usable(ability, job_def, eff_cost) then
                            goto continue_ability
                        end
                        if common.check_stratagem(job_def, settings, ability.name, ability) == false then
                            goto continue_ability
                        end
                        return pre
                    end

                    -- Use action_core for resource + cooldown + command building
                    local desc = string.format('Applying buff: %s', ability.name)
                    local result, reason = action_core.try_use(ability, job_def, settings, 0, desc, state)
                    if result then
                        last_self_cast[ability.name] = os.clock()
                        -- Strip the lingering 1-shadow buff mid-cast so the new
                        -- shadows apply cleanly (Ninja "Cast with 1 Shadow").
                        if strip_one_shadow then
                            if type(result) ~= 'table' then result = { command = result, description = desc } end
                            result.scheduled_removal = { command = '/debuff ' .. ability.one_shadow_buff, delay = 1.0 }
                        end
                        return result
                    end
                end
            end
        end
        
        ::continue_ability::
    end
    
    return nil
end

return buff
