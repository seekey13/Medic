--[[
    Game State Info Panel for Sidekick
    Displays a per-frame snapshot of common.game_state for all party members.
    Toggle visibility with: /sk panel
]]--

local panel = {}

local imgui = require('imgui')
local common = require('lib.core.common')
local buff = require('lib.actions.buff')
local afk = require('lib.core.afk')
local tooltips = require('lib.ui.tooltips')
local components = require('lib.ui.components')

-- Window state
local is_open = { true }
local panel_visible = false

-- Row colors. Each section's color runs across the whole row (pushed once per
-- row), so the legend at the bottom reads as a key to the table.
local WHITE = { 1.0, 1.0, 1.0, 1.0 }
local LOW   = components.LIGHT_RED     -- HP/MP below threshold, overrides row color
local PET   = components.LIGHT_GRAY
local ALLY_B = components.LIGHT_BLUE
local ALLY_C = components.LIGHT_GREEN
local TRACKED = components.LIGHT_YELLOW

-- Width of the panel's numeric entry fields. InputInt spends most of its item
-- width on the -/+ step buttons, so 90 is what leaves room for 3 digits.
local INT_FIELD_WIDTH = 90

-- ============================================================================
-- Visibility Control
-- ============================================================================

function panel.show()
    panel_visible = true
    is_open[1] = true
end

function panel.hide()
    panel_visible = false
    is_open[1] = false
end

function panel.toggle()
    if panel_visible then
        panel.hide()
    else
        panel.show()
    end
end

function panel.is_visible()
    return panel_visible
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- Format position as "X, Y, Z"
local function fmt_pos(pos)
    if not pos then return '--' end
    return string.format('%.1f, %.1f, %.1f', pos.x or 0, pos.y or 0, pos.z or 0)
end

-- Short label for entity status values
local STATUS_LABELS = { [0]='Idle', [1]='Engaged', [2]='Dead 2', [3]='Dead', [5]='Mounted', [33]='Resting', [47]='Sitting' }
local function fmt_status(s)
    if s == nil or s == -1 then return '--' end
    -- tonumber() ensures cdata/boxed integers from Ashita's Lua bindings
    -- compare correctly against the integer keys in STATUS_LABELS.
    return STATUS_LABELS[tonumber(s)] or tostring(s)
end

-- HP/MP cell text. Falls back to a bare percentage when the max is unknown
-- (not yet cached), and to '--' when the member has no such pool at all.
-- '%%%%' survives string.format as '%%', which imgui.Text then prints as '%'.
local function fmt_pool(cur, max, pct, prefix)
    if max and max > 0 then
        return string.format('%s%d/%d (%d%%%%)', prefix or '', cur or 0, max, pct or 0)
    elseif pct then
        return string.format('%s%d%%%%', prefix or '', pct)
    end
    return '--'
end

-- Resolve a buff ID to a display string (name if available, else "#ID")
local function buff_name(buff_id)
    local ok, name = pcall(function()
        return AshitaCore:GetResourceManager():GetString('buffs.names', buff_id)
    end)
    if ok and name and name ~= '' then
        return name
    end
    return '#' .. tostring(buff_id)
end

-- Build a comma-separated buff list string for display
local function fmt_buffs(buffs, sep)
    if not buffs or #buffs == 0 then return '' end
    local parts = {}
    for _, id in ipairs(buffs) do
        table.insert(parts, buff_name(id))
    end
    return table.concat(parts, sep or ', ')
end

-- Manual song timers, one line per party member holding any. Empty unless
-- Song Duration (s) > 0 -- that setting is what turns stamping on. Area [A]
-- casts stamp everyone in range, so a stuck area song shows itself here.
local function song_timer_lines(gs, addon_settings)
    local timers = buff.song_timers()
    local now, lines = os.clock(), {}
    local function add(label, m)
        local t = m and m.server_id and timers[m.server_id]
        if not t then return end
        local parts = {}
        for name, row in pairs(t) do
            local left = row.deadline - now
            parts[#parts + 1] = string.format('%s %s', name,
                left > 0 and string.format('%.0fs', left) or 'due')
        end
        if #parts == 0 then return end
        table.sort(parts)
        lines[#lines + 1] = string.format('%s %s: %s', label, m.name or '--',
            table.concat(parts, ', '))
    end
    add('ME', gs.player)
    for i = 1, 5 do add('P' .. i, gs.party and gs.party[i]) end

    -- Only beside held songs: with Song Duration 0 nothing is held, so nothing
    -- is being re-sung, and a line here would short-circuit the "why nothing is
    -- held" explanations below.
    if #lines > 0 and buff.song_force_active() then
        lines[#lines + 1] = 'Nightingale + Troubadour: re-singing held songs'
    end

    if #lines > 0 then return table.concat(lines, '\n') end

    -- Nothing held: say WHY, so an empty readout tells you whether stamping is
    -- switched off or simply has not happened yet. Song Duration is the switch
    -- for all songs; area songs additionally track themselves when no member's
    -- buff list can be read, so 0 is reported as "single-target off" rather than
    -- off outright. The job/level gate on top is visible in the panel already.
    local duration = tonumber(addon_settings and addon_settings.song_duration) or 0
    if duration <= 0 then
        return 'none held -- single-target timers off (Song Duration 0)'
    end
    return string.format('none held -- %ds interval, no song finished yet', duration)
end

local function job_abbr(id)
    if not id or id == 0 then return '??' end
    local ok, s = pcall(function()
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', id)
    end)
    return (ok and s and s ~= '') and s or ('J' .. id)
end

-- ============================================================================
-- Table Row
-- ============================================================================

-- One member row. `color` runs across every cell; low HP/MP overrides it.
-- opts.job  : job cell text ('--' when unknown)
-- opts.est  : prefix HP with '~' (derived, not server-reported)
-- Returns true when the row drew its own tooltip, so the caller can hold back the
-- table-wide legend tooltip -- both write the same tooltip window and the later
-- SetTooltip would win.
local function member_row(slot, color, m, opts)
    opts = opts or {}
    local drew_tooltip = false
    imgui.TableNextRow()
    imgui.PushStyleColor(ImGuiCol_Text, color)

    -- Slt
    imgui.TableNextColumn()
    imgui.Text(slot)

    -- Name
    imgui.TableNextColumn()
    imgui.Text(m.name or '--')

    -- Job
    imgui.TableNextColumn()
    imgui.Text(opts.job or '--')

    -- HP
    imgui.TableNextColumn()
    local hp_low = (m.hpp or 100) <= 50
    if hp_low then imgui.PushStyleColor(ImGuiCol_Text, LOW) end
    imgui.Text(fmt_pool(m.hp, m.max_hp, m.hpp, opts.est and '~' or nil))
    if hp_low then imgui.PopStyleColor() end

    -- MP
    imgui.TableNextColumn()
    local mp_low = (m.mpp or 100) <= 40
    if mp_low then imgui.PushStyleColor(ImGuiCol_Text, LOW) end
    imgui.Text(fmt_pool(m.mp, m.max_mp, m.mpp))
    if mp_low then imgui.PopStyleColor() end

    -- TP
    imgui.TableNextColumn()
    imgui.Text(m.tp and tostring(m.tp) or '--')

    -- Buffs: the cell clips to one row at the column width; the full list is
    -- one-per-line in the tooltip.
    imgui.TableNextColumn()
    if m.buffs and #m.buffs > 0 then
        imgui.Text(fmt_buffs(m.buffs))
        if imgui.IsItemHovered() then
            imgui.SetTooltip(fmt_buffs(m.buffs, '\n'))
            drew_tooltip = true
        end
    else
        imgui.Text('--')
    end

    -- Position
    imgui.TableNextColumn()
    imgui.Text(fmt_pos(m.position))

    -- Status
    imgui.TableNextColumn()
    imgui.Text(fmt_status(m.entity_status))

    imgui.PopStyleColor()
    return drew_tooltip
end

-- The legend: what the row colors and slot markers mean. Shown as a tooltip on
-- the table rather than as a permanent row of text.
local function legend_tooltip()
    imgui.BeginTooltip()
    imgui.TextColored(ALLY_B, 'Alliance B')
    imgui.TextColored(ALLY_C, 'Alliance C')
    imgui.TextColored(TRACKED, 'Tracked Target')
    imgui.TextColored(PET, 'Pet')
    imgui.Text('Trust NPC^')
    imgui.Text('Party Leader*')
    imgui.Text('~HP Values Estimated')
    imgui.EndTooltip()
end

-- Slot label + markers: '^' Trust NPC, '*' party leader.
local function slot_label(prefix, m, leader_sid)
    local s = prefix
    if m.is_trust then s = s .. '^' end
    if leader_sid and leader_sid ~= 0 and m.server_id == leader_sid then s = s .. '*' end
    return s
end

local function party_job(m)
    -- The server omits job and level for /anon characters (0x0dd_group_list.cpp),
    -- so a zeroed row means hidden, not level 0. Our own row never lands here --
    -- it is backfilled from the Player struct in build_member_snapshot.
    if (m.main_level or 0) == 0 then return 'hidden' end
    return string.format('%s%d/%s%d',
        m.job_name     or '??', m.main_level or 0,
        m.sub_job_name or '??', m.sub_level  or 0)
end

-- ============================================================================
-- Render
-- ============================================================================

function panel.render(addon_settings, save_settings)
    if not panel_visible then return end

    -- Refresh if stale (automation tick may have already done it this frame)
    if os.clock() - common.game_state.refreshed_at > 0.1 then
        common.refresh_game_state()
    end

    local gs = common.game_state

    if imgui.Begin('Sidekick: Party State', is_open, ImGuiWindowFlags_AlwaysAutoResize) then

        -- ── Status line ──────────────────────────────────────────────────
        local tracked_count = 0
        if gs.tracked then
            for _ in pairs(gs.tracked) do tracked_count = tracked_count + 1 end
        end
        local main_count = gs.player and 1 or 0
        for i = 1, 5 do if gs.party[i] then main_count = main_count + 1 end end

        -- AFK state. Only afk.update() advances the timer and the tick loop returns
        -- before it when stopped, so 'idle' rather than a countdown draining to a
        -- permanent 'awake (0s)'.
        local afk_str
        if not (addon_settings and addon_settings.afk_enabled) then
            afk_str = 'off'
        elseif not addon_settings.automation_enabled then
            afk_str = 'idle'
        elseif afk.is_sleeping() then
            afk_str = 'asleep'
        else
            afk_str = string.format('awake (%.0fs)', afk.seconds_remaining(addon_settings))
        end

        imgui.Text(table.concat({
            string.format('Action: %s',   common.get_last_action()),
            string.format('Moving: %s',   tostring(common.is_player_moving())),
            string.format('AFK: %s',      afk_str),
            string.format('Zone: %d',     common.get_zone_id()),
            string.format('Target: %s',   tostring(common.get_target_id())),
        }, '   '))

        -- Scholar Stratagem / Beastmaster Ready charges
        if gs.stratagems and gs.stratagems > 0 then
            imgui.SameLine(0, 20)
            local strat_color = gs.stratagems <= 1
                and { 1.0, 0.4, 0.4, 1.0 }   -- red when low
                or  { 0.4, 0.8, 1.0, 1.0 }   -- cyan
            imgui.TextColored(strat_color, string.format('Stratagems: %d', gs.stratagems))
        end
        if gs.ready_charges and gs.ready_charges > 0 then
            imgui.SameLine(0, 20)
            local ready_color = gs.ready_charges <= 1
                and { 1.0, 0.4, 0.4, 1.0 }
                or  { 0.4, 0.8, 1.0, 1.0 }
            imgui.TextColored(ready_color, string.format('Ready: %d', gs.ready_charges))
        end

        -- ── Table ────────────────────────────────────────────────────────
        -- NoHostExtendX: every column is WidthFixed, so without it the table
        -- border stretches to the window width (which the controls row below
        -- makes much wider than the columns), leaving dead space past Status.
        local TABLE_FLAGS = bit.bor(
            ImGuiTableFlags_Borders,
            ImGuiTableFlags_RowBg,
            ImGuiTableFlags_SizingFixedFit,
            ImGuiTableFlags_NoHostExtendX
        )

        -- Grouped so the whole table is one hoverable item for the legend tooltip.
        local cell_tooltip = false
        imgui.BeginGroup()
        if imgui.BeginTable('##ps_table', 9, TABLE_FLAGS, { 0, 0 }) then
            imgui.TableSetupColumn('Slot',      ImGuiTableColumnFlags_WidthFixed, 34)
            imgui.TableSetupColumn('Name',     ImGuiTableColumnFlags_WidthFixed, 150)
            imgui.TableSetupColumn('Job',      ImGuiTableColumnFlags_WidthFixed, 100)
            imgui.TableSetupColumn('HP',       ImGuiTableColumnFlags_WidthFixed, 140)
            imgui.TableSetupColumn('MP',       ImGuiTableColumnFlags_WidthFixed, 140)
            imgui.TableSetupColumn('TP',       ImGuiTableColumnFlags_WidthFixed,  38)
            imgui.TableSetupColumn('Buffs',    ImGuiTableColumnFlags_WidthFixed, 200)
            imgui.TableSetupColumn('Position', ImGuiTableColumnFlags_WidthFixed, 168)
            imgui.TableSetupColumn('Status',   ImGuiTableColumnFlags_WidthFixed,  60)
            imgui.TableHeadersRow()

            local main_leader = gs.alliance_leaders and gs.alliance_leaders[1] or 0

            -- ME
            if gs.player then
                cell_tooltip = member_row(slot_label('ME', gs.player, main_leader), WHITE, gs.player,
                    { job = party_job(gs.player) }) or cell_tooltip

                -- PT (pet) -- only when the player has one out
                if (gs.player.pet_hpp or 0) > 0 then
                    local pet_entity = common.get_pet_entity()
                    local ok, pet_name = pcall(function() return pet_entity and pet_entity.Name end)
                    -- Pet's own engaged state -- the field that gates deploy.
                    local ok_s, pet_status = pcall(function() return pet_entity and pet_entity.Status end)
                    cell_tooltip = member_row('PET', PET, {
                        name          = (ok and pet_name ~= '' and pet_name) or nil,
                        hpp           = gs.player.pet_hpp,
                        position      = gs.player.pet_position,
                        buffs         = gs.pet_debuffs,
                        entity_status = ok_s and pet_status or nil,
                    }, {}) or cell_tooltip
                end
            end

            -- P1-P5
            for i = 1, 5 do
                local m = gs.party[i]
                if m then
                    cell_tooltip = member_row(slot_label('P' .. i, m, main_leader), WHITE, m,
                        { job = party_job(m) }) or cell_tooltip
                end
            end

            -- Alliance sub-parties B (gs.alliance[2]) and C (gs.alliance[3])
            if gs.alliance then
                local prefixes = { [2] = 'B', [3] = 'C' }
                local colors   = { [2] = ALLY_B, [3] = ALLY_C }
                for pi = 2, 3 do
                    local sub_party = gs.alliance[pi]
                    if sub_party and next(sub_party) ~= nil then
                        local leader_sid = (gs.alliance_leaders and gs.alliance_leaders[pi]) or 0
                        for _, entry in ipairs(common.sorted_alliance_members(sub_party)) do
                            local m = entry.m
                            cell_tooltip = member_row(slot_label(prefixes[pi] .. entry.local_idx, m, leader_sid),
                                colors[pi], m, { job = party_job(m) }) or cell_tooltip
                        end
                    end
                end
            end

            -- T1-Tn (tracked targets). HP is always derived from the percent
            -- (hp = hpp*max_hp/100), but max_hp is only a guess when it came from the
            -- level table, so only max_hp_estimated rows get the '~'. A target picked up
            -- through the shared party list drops the '~' once its roster row carried a
            -- max HP value -- the publisher only has one after seeing that member at 100%
            -- HP, so a freshly shared target can still be estimated for a while.
            if gs.tracked then
                local sorted = {}
                for _, tt in pairs(gs.tracked) do table.insert(sorted, tt) end
                table.sort(sorted, function(a, b) return (a.name or '') < (b.name or '') end)

                for t_idx, m in ipairs(sorted) do
                    local job
                    if m.main_level and m.main_level > 0 then
                        if m.main_job and m.main_job > 0 then
                            job = string.format('%s%d/%s%d',
                                job_abbr(m.main_job), m.main_level,
                                job_abbr(m.sub_job),  m.sub_level or 0)
                        else
                            job = string.format('Lv.%d', m.main_level)
                        end
                    end
                    cell_tooltip = member_row('T' .. t_idx, TRACKED, m, { job = job, est = m.max_hp_estimated })
                        or cell_tooltip
                end
            end

            imgui.EndTable()
        end
        imgui.EndGroup()

        -- Legend, unless a cell (Buffs) already claimed the tooltip this frame.
        if not cell_tooltip and imgui.IsItemHovered() then
            legend_tooltip()
        end

        -- ── Controls (last row) ──────────────────────────────────────────
        -- Everything here renders unconditionally, including the settings that
        -- only bite on one job (Pianissimo = BRD, 1 Shadow = NIN): the panel is a
        -- debug surface, so a stable row beats one that reshuffles on job change.
        local debug_var = { common.debug }
        if imgui.Checkbox('Debug Mode', debug_var) then
            common.debug = debug_var[1]
        end

        if addon_settings then
            -- Multisend Follow (global). ON = Attack Range shown, native Follow off.
            local ms_var = { addon_settings.multisend_follow == true }
            imgui.SameLine(0, 20)
            if imgui.Checkbox('Multisend Follow', ms_var) then
                addon_settings.multisend_follow = ms_var[1]
                -- Disabling Multisend Follow reverts attack range to Off.
                if not ms_var[1] then addon_settings.attack_range = 'Off' end
                if save_settings then save_settings() end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.multisend_follow)
            end

            -- Hold AOE for Group (per-job). Holds area buffs/songs/rolls/Accession/
            -- Diffusion until every alive, in-zone party member is in range.
            local hold_aoe_var = { addon_settings.hold_aoe_for_group == true }
            imgui.SameLine(0, 20)
            if imgui.Checkbox('Hold AOE for Group', hold_aoe_var) then
                addon_settings.hold_aoe_for_group = hold_aoe_var[1]
                if save_settings then save_settings() end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.hold_aoe_for_group)
            end

            -- Party chat alert for the hold above. Only meaningful while the hold
            -- is on, so it greys out with it.
            local hold_msg_var = { addon_settings.hold_aoe_announce ~= false }
            imgui.SameLine(0, 20)
            if not addon_settings.hold_aoe_for_group then
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.5)
            end
            if imgui.Checkbox('Gather Alert', hold_msg_var) then
                addon_settings.hold_aoe_announce = hold_msg_var[1]
                if save_settings then save_settings() end
            end
            if not addon_settings.hold_aoe_for_group then
                imgui.PopStyleVar()
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.hold_aoe_announce)
            end

            -- Pianissimo Fast Casting (BRD main or sub). Persisted per-job.
            local fast_var = { addon_settings.pianissimo_fast_casting == true }
            imgui.SameLine(0, 20)
            if imgui.Checkbox('Pianissimo Fast Casting', fast_var) then
                addon_settings.pianissimo_fast_casting = fast_var[1]
                if save_settings then save_settings() end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.pianissimo_fast_casting)
            end

            -- Cast with 1 Shadow (NIN main or sub). Persisted per-job.
            local one_shadow_var = { addon_settings.cast_with_1_shadow == true }
            imgui.SameLine(0, 20)
            if imgui.Checkbox('Cast with 1 Shadow', one_shadow_var) then
                addon_settings.cast_with_1_shadow = one_shadow_var[1]
                if save_settings then save_settings() end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.cast_with_1_shadow)
            end

            -- ── Potency / duration row ───────────────────────────────────
            -- All three are 3-digit fields, so they share one width.
            local ctx = { settings = addon_settings, save_callback = save_settings }

            -- Cure Potency +% (gear bonus, MP cures). See lib/actions/heal.lua.
            components.input_int(ctx, 'Cure Potency +%', 'cure_potency',
                { addon_settings.cure_potency or 0 }, 0, 100, INT_FIELD_WIDTH)
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.cure_potency)
            end

            -- Waltz Potency +% (gear bonus, TP waltzes).
            imgui.SameLine(0, 20)
            components.input_int(ctx, 'Waltz Potency +%', 'waltz_potency',
                { addon_settings.waltz_potency or 0 }, 0, 100, INT_FIELD_WIDTH)
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.waltz_potency)
            end

            -- Song Duration (BRD main at 75 only). 0 = off: recast when the buff
            -- is seen missing (memory-based, the default). >0 = manual song
            -- timers: re-sing each song this many seconds after we sang it,
            -- doubled while Troubadour is up. See lib/actions/buff.lua.
            imgui.SameLine(0, 20)
            components.input_int(ctx, 'Song Duration (s)', 'song_duration',
                { addon_settings.song_duration or 0 }, 0, 999, INT_FIELD_WIDTH)
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.song_duration)
            end

            -- Area group buff tracking: the timers those songs are stamped on,
            -- read straight out of lib/actions/buff.lua. Read-only.
            -- Debug Mode only: a troubleshooting readout, not a control.
            if common.debug then
                imgui.Text('Area Buffs:')
                imgui.Text(song_timer_lines(gs, addon_settings))
            end

            -- AFK Sleep (global). afk_timeout is stored in seconds but shown in
            -- minutes, so read afk_timeout/60 and write value*60. Starts the
            -- last controls row, shared with the UI Opacity slider.
            local afk_var = { addon_settings.afk_enabled == true }
            if imgui.Checkbox('AFK Sleep', afk_var) then
                addon_settings.afk_enabled = afk_var[1]
                if not afk_var[1] then afk.reset() end  -- never leave it stuck asleep
                if save_settings then save_settings() end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(tooltips.afk_sleep)
            end

            local mins_var = { math.floor((addon_settings.afk_timeout or 600) / 60) }
            imgui.SameLine(0, 20)
            imgui.PushItemWidth(80)
            if imgui.InputInt('Timeout (minutes)', mins_var) then
                -- Bounds mirror /sidekick afk <seconds> (60-3600s = 1-60m).
                local m = mins_var[1]
                if m < 1 then m = 1 end
                if m > 60 then m = 60 end
                addon_settings.afk_timeout = m * 60
                afk.reset()  -- restart the interval with the new timeout
                if save_settings then save_settings() end
            end
            imgui.PopItemWidth()

            -- UI Opacity (global). Drives the config window's alpha directly:
            -- 100 = fully opaque, 1 = nearly invisible.
            local opacity_var = { addon_settings.ui_opacity or 100 }
            imgui.SameLine(0, 20)
            imgui.PushItemWidth(460)
            if imgui.SliderInt('UI Opacity', opacity_var, 1, 100) then
                addon_settings.ui_opacity = opacity_var[1]
                if save_settings then save_settings() end
            end
            imgui.PopItemWidth()
        end
    end
    imgui.End()

    -- Sync close button
    if not is_open[1] then
        panel_visible = false
    end
end

return panel
