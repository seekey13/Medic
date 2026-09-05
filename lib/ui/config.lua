--[[
    Generic configuration UI for Sidekick
    Dynamically generates UI based on loaded job definition
]]--

local ui_config = {}

local imgui = require('imgui')
local common = require('lib.core.common')
local afk = require('lib.core.afk')
local ui = require('lib.ui.components')
local tooltips = require('lib.ui.tooltips')
local roll = require('lib.actions.roll')  -- for reset_state() when a roll selection changes

-- UI state
local is_open = { true }
local ui_visible = false
local widget_visible = false  -- floating header-only window (/sk widget)
local widget_open = { true }  -- Ashita's Begin drops the flags arg unless p_open is a table
local force_expand = false  -- when true, next render un-collapses the window once
-- Upper bound on the widget's job line: 'Puppetmaster' is the longest job name
-- in common.job_data, so both slots at 2-digit levels is wider than any real
-- main/sub combo. Measured, not hardcoded in pixels, so it tracks the font.
local WIDEST_JOB_LINE = 'Puppetmaster 99 / Puppetmaster 49'

-- Settings reference and callback
local current_settings = nil
local save_callback = nil

-- Floor for the custom window size. Small enough not to fight the user, large enough
-- that the window stays usable and keeps empty body space to right-click.
local MIN_CUSTOM_WINDOW_WIDTH = 320
local MIN_CUSTOM_WINDOW_HEIGHT = 200

-- Focus state (now saved to settings as names)
local focus_target_name = nil  -- Character name or nil for None
local focus_recovery_target_name = nil  -- Character name or nil for None
local follow_target_name = nil  -- Character name or nil for None

-- Entrust state (now saved to settings)
local entrust_target_name = nil  -- Character name or nil for None
local entrust_spell_name = nil   -- Spell name like "Indi-Haste" or nil for None

-- Party buff tracking (session only, not saved to settings)
-- Structure: party_buffs[ability_name][party_index] = true/false
-- party_index: 1-5 for P1-P5 (player is always handled separately)
local party_buffs = {}

-- Per-target Combat/Idle override for ME/P1-P5 buff buttons (right-click menu).
-- Purely session state -- never written to settings, so it resets on reload.
-- Structure: party_buff_gates[ability_name_or_group][target_index] = 'combat' | 'idle'
-- target_index: 0 = ME, 1-5 = P1-P5. Absent = inherit the ability's own
-- combat_only/idle_only setting. See common.target_gate_ok.
local party_buff_gates = {}

-- ============================================================================
-- Helper Functions (Remaining in ui_config)
-- ============================================================================

-- Check if player can use an ability based on level
local function can_use_ability(ability)
    if not ability or not ability.level then
        return true
    end
    
    -- Check if ability requires main job only (e.g., Geo spells)
    if ability.main_job_only and ability.is_main_job == false then
        return false
    end
    
    local main_level, sub_level = common.get_player_level()

    -- Abilities marked is_main_job = false are from subjob; check against sub level.
    if ability.is_main_job == false then
        return sub_level >= ability.level
    end
    return main_level >= ability.level
end

-- Check if a list of abilities has any usable abilities (level-appropriate)
local function has_usable_abilities(abilities)
    if not abilities then
        return false
    end

    for _, ability in pairs(abilities) do
        if can_use_ability(ability) then
            return true
        end
    end

    return false
end

-- Check if an ability is a duplicate from subjob
local function is_subjob_duplicate(job_def, ability)
    if ability.is_main_job ~= false then
        return false
    end
    
    if not job_def or not job_def.abilities then
        return false
    end
    
    for category, abilities in pairs(job_def.abilities) do
        for _, other_ability in ipairs(abilities) do
            if other_ability.name == ability.name and other_ability.is_main_job ~= false then
                return true
            end
        end
    end
    
    return false
end

-- Draw a "(<count>)" after an ammo-gated ability's row: green when a matching
-- item is worn, red when not -- reusing the current-job green and automation-
-- stopped red so the palette stays consistent. When show_name is set and an item
-- is worn, also name the equipped tier in green -- only useful for heal_pet
-- (Reward/Repair), where the tier changes how much the pet heals.
local function render_ammo_count(ability, show_name)
    if not ability.requires_equipped_ammo then return end
    local count = common.count_equippable_items(ability.requires_equipped_ammo)
    local equipped = common.is_ammo_equipped(ability.requires_equipped_ammo)
    imgui.SameLine()
    imgui.TextColored(equipped and ui.LIGHT_GREEN or ui.LIGHT_RED, string.format('(%d)', count))
    if show_name and equipped then
        local name = common.equipped_ammo_name(ability.requires_equipped_ammo)
        if name then
            imgui.SameLine()
            imgui.TextColored(ui.LIGHT_GREEN, name)
        end
    end
end

-- Check if a party member is a Trust (server_id >= 0x1000000)
local function is_trust(party_index)
    local party = common.get_party()
    if not party then
        return false
    end
    
    local ok_server, server_id = pcall(function()
        return party:GetMemberServerId(party_index)
    end)
    
    if not ok_server or not server_id or server_id == 0 then
        return false
    end
    
    -- Trusts have server IDs >= 0x1000000 (16777216)
    return server_id >= 0x1000000
end

-- Render a party-member dropdown (reusable for Focus/Follow/Recovery/Entrust Target)
-- Args:
--   label (string) - Combo display label
--   setting_key (string) - Key in settings to read/write the selected name
--   include_player (bool) - Whether to include P0 (the player) in the list
--   party_member_names (table) - Pre-built list of P1-P5 names
--   settings (table) - Current settings table
--   on_change (function|nil) - Callback after selection changes
--   include_tracked (bool|nil) - Whether to include tracked targets (default false)
-- Returns: string|nil - The currently selected name (or nil for 'None')
local function render_party_dropdown(label, setting_key, include_player, party_member_names, settings, on_change, include_tracked)
    local options = { 'None' }
    if include_player then
        local player_name = common.get_party_member_name(0)
        if player_name and player_name ~= '' then
            table.insert(options, player_name)
        end
    end
    for _, name in ipairs(party_member_names) do
        table.insert(options, name)
    end

    -- Include tracked target names if requested. Skip names already listed: a
    -- tracked target who later joins the party keeps their tracked entry (the
    -- party check in add_tracked_target only runs at add time), and would
    -- otherwise appear twice.
    if include_tracked then
        local tracked_list = common.get_tracked_targets()
        for _, tt in pairs(tracked_list) do
            if tt.name and tt.name ~= '' then
                local seen = false
                for _, existing in ipairs(options) do
                    if existing == tt.name then
                        seen = true
                        break
                    end
                end
                if not seen then
                    table.insert(options, tt.name)
                end
            end
        end
    end

    -- Display 'None' when the saved name isn't in the list, but keep the setting --
    -- clearing it here wiped the target on a transient zone-out. Re-matches on return.
    local current_name = settings[setting_key]
    local current_display = 'None'
    if current_name then
        for _, name in ipairs(options) do
            if name == current_name then
                current_display = current_name
                break
            end
        end
    end

    -- Render dropdown
    imgui.PushItemWidth(250)
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0.2, 0.2, 0.2, 1.0 })
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, { 0.3, 0.3, 0.3, 1.0 })
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, { 0.4, 0.4, 0.4, 1.0 })
    if ui.begin_opaque_combo(label, current_display) then
        for _, option in ipairs(options) do
            local is_selected = (option == current_display)
            if imgui.Selectable(option, is_selected) then
                settings[setting_key] = (option ~= 'None') and option or nil
                if on_change then on_change() end
            end
            if is_selected then
                imgui.SetItemDefaultFocus()
            end
        end
        ui.end_opaque_combo()
    end
    imgui.PopStyleColor(3)
    imgui.PopItemWidth()

    return settings[setting_key]
end

-- Render a Corsair roll-selection dropdown (Roll 1 / Roll 2). Writes the roll name
-- into settings[setting_key] and resets roll state on every change, so a stale
-- packet total from the previous roll can't leak into the new one.
-- Generic named-ability selection dropdown (Corsair rolls, PUP maneuvers, ...).
-- `tooltip` is applied here rather than by the caller: the lucky-number text below
-- would otherwise be the "last item" that item_tooltip attaches to. `width`
-- defaults to 250 (roll dropdowns); pass a narrower value for tighter layouts
-- (e.g. 100 for maneuvers, which sit three to a row). Pass a '##id' label for an
-- unlabelled dropdown. `on_select`, if given, runs before `on_change` on every
-- pick, including 'None' -- rolls use it to reset roll.lua's tracked totals;
-- maneuvers, which allow picking the same element in more than one slot, don't
-- need it. Display strips a trailing ' Maneuver' (short_label) so the three
-- maneuver slots fit their row; settings still store the full name.
local function short_label(name)
    return (name:gsub(' Maneuver$', ''))
end

local function render_ability_dropdown(label, setting_key, available_abilities, settings, on_change, tooltip, width, on_select)
    local current = settings[setting_key]

    -- Show 'None' for an unset selection, or one the player can no longer use
    local current_display = 'None'
    local current_ability
    for _, ability in ipairs(available_abilities) do
        if ability.name == current then
            current_display = short_label(ability.name)
            current_ability = ability
            break
        end
    end

    local function choose(name)
        settings[setting_key] = name
        if on_select then on_select() end
        if on_change then on_change() end
    end

    imgui.PushItemWidth(width or 250)
    if ui.begin_opaque_combo(label, current_display) then
        local is_none_selected = (current_display == 'None')
        if imgui.Selectable('None', is_none_selected) then
            choose(nil)
        end
        if is_none_selected then
            imgui.SetItemDefaultFocus()
        end

        for _, ability in ipairs(available_abilities) do
            local is_selected = (ability.name == current)
            if imgui.Selectable(short_label(ability.name), is_selected) then
                choose(ability.name)
            end
            if is_selected then
                imgui.SetItemDefaultFocus()
            end
        end
        ui.end_opaque_combo()
    end
    imgui.PopItemWidth()
    ui.item_tooltip(tooltip)

    -- Lucky number of the selected roll -- the total roll.lua stops Double-Up on
    if current_ability and current_ability.lucky then
        imgui.SameLine()
        imgui.TextColored(ui.LIGHT_GREEN, string.format('(%d)', current_ability.lucky))
    end
end

-- ============================================================================
-- Settings Profiles
-- Named snapshots of live settings, per main/sub combo, stored inside the
-- settings table itself (settings.profiles[combo][name]) so Ashita's settings
-- module handles persistence. Live settings stay the auto-saving working copy;
-- profiles only change via explicit Save / Save As here.
-- Spec: docs/superpowers/specs/2026-07-22-settings-profiles-design.md
-- ============================================================================

-- Keys never copied into or out of a snapshot: container/meta, run state
-- (loading a profile must never start/stop automation), party-composition
-- state that would go stale between sessions, and per-character window chrome
-- -- a profile is per main/sub combo, the window is not, so loading one must
-- not resize the window, re-chrome its sections, refade it, or open and close it.
local PROFILE_EXCLUDED_KEYS = {
    profiles = true,
    active_profile = true,
    automation_enabled = true,
    load_stopped = true,
    focus_target = true,
    follow_enabled = true,
    follow_target = true,
    follow_distance = true,
    window_size_mode = true,
    display_mode = true,
    ui_opacity = true,
    ui_open = true,
    widget_open = true,
}

-- Reserved key inside a combo's profile list: the parked Default working copy.
-- Live settings are stashed here when a named profile is loaded, and restored
-- when the user clicks 'Default' in the list. Never shown as a named profile.
local DEFAULT_SLOT = '__default'

-- Profile list for the current main/sub combo, created on demand.
local function profile_list(settings)
    if not settings.profiles then settings.profiles = T{} end
    local combo = common.get_job_combo()
    if not settings.profiles[combo] then settings.profiles[combo] = T{} end
    return settings.profiles[combo]
end

-- Snapshot live settings (minus excluded keys) for storing under a name.
local function profile_snapshot(settings)
    local snap = T{}
    for key, value in pairs(settings) do
        if not PROFILE_EXCLUDED_KEYS[key] then
            snap[key] = common.deep_copy(value)
        end
    end
    return snap
end

-- Session-only mirrors of settings keys are refreshed after a profile Load/New
-- so the UI and automation pick up the new values instead of stale ones.
-- party_buffs must be re-seeded IMMEDIATELY (not left for the next-frame seed
-- block at the top of ui_config.render): sections below the job line render in
-- the same frame as the load, and render_party_selection's auto-init would see
-- a missing 'wake' key, overwrite the just-loaded settings.party_buffs.wake
-- with defaults, and -- by making the session table non-empty -- permanently
-- disarm the next-frame seed, leaving every party-button row (debuff removal,
-- buffs) reading empty session state. Session-only tracked-target buff toggles
-- are dropped by design (they never live in settings). The name mirrors
-- (entrust etc.) are safe to lazily re-seed next frame -- their render paths
-- only write settings on click. focus_target_name / follow_target_name mirror
-- excluded keys -- a load never changes those, so their mirrors stay valid.
local function profile_reset_session_state(settings)
    for k in pairs(party_buffs) do party_buffs[k] = nil end
    if settings.party_buffs then
        for ability_name, targets in pairs(settings.party_buffs) do
            party_buffs[ability_name] = {}
            for party_index, enabled in pairs(targets) do
                party_buffs[ability_name][party_index] = enabled
            end
        end
    end
    entrust_target_name = nil
    entrust_spell_name = nil
    focus_recovery_target_name = nil
end

-- Replace live settings with `source` (a snapshot, or merged job defaults for
-- New): clear every non-excluded key IN PLACE (Sidekick.lua and the settings
-- lib hold this exact table reference -- never replace the table), copy source
-- in, then backfill missing keys from job_def.merged_defaults. Backfill covers
-- snapshots saved before newer settings keys existed -- same merge setup_job
-- uses, so no nil-key surprises mid-session.
local function profile_apply(settings, job_def, source)
    for key in pairs(settings) do
        if not PROFILE_EXCLUDED_KEYS[key] then
            settings[key] = nil
        end
    end
    for key, value in pairs(source) do
        if not PROFILE_EXCLUDED_KEYS[key] then
            settings[key] = common.deep_copy(value)
        end
    end
    if job_def and job_def.merged_defaults then
        for key, value in pairs(job_def.merged_defaults) do
            if settings[key] == nil and not PROFILE_EXCLUDED_KEYS[key] then
                settings[key] = common.deep_copy(value)
            end
        end
    end
    profile_reset_session_state(settings)
end

-- Operations called from the profiles popup (lib/ui/components.lua). All take
-- the ctx object components already use (settings / job_def / save_callback).
local profile_ops = {}

-- Exposed so the popup renderer can hide the parked slot from the named list.
profile_ops.DEFAULT_SLOT = DEFAULT_SLOT

function profile_ops.list(ctx)
    return profile_list(ctx.settings)
end

-- Active profile validated against the current combo's list. active_profile is
-- one shared key in the settings table while profiles are per-combo, so a name
-- loaded on another combo must read as Default here, not as active.
function profile_ops.active(ctx)
    local active = ctx.settings.active_profile
    if active and profile_list(ctx.settings)[active] then
        return active
    end
    return nil
end

-- Save: name matches the selected (active) profile -> overwrite its snapshot;
-- name differs while one is selected -> rename in place (the snapshot moves,
-- live settings are not re-captured); no selection -> create from live settings.
function profile_ops.save(ctx, name)
    if not name or name == '' then return end
    if name == DEFAULT_SLOT or name:lower() == 'default' then return end
    local list = profile_list(ctx.settings)
    local selected = profile_ops.active(ctx)
    if selected and selected ~= name then
        list[name] = list[selected]
        list[selected] = nil
    else
        list[name] = profile_snapshot(ctx.settings)
    end
    ctx.settings.active_profile = name
    if ctx.save_callback then ctx.save_callback() end
end

-- Save As: always create/overwrite a fresh snapshot under the typed name.
function profile_ops.save_as(ctx, name)
    if not name or name == '' then return end
    if name == DEFAULT_SLOT or name:lower() == 'default' then return end
    profile_list(ctx.settings)[name] = profile_snapshot(ctx.settings)
    ctx.settings.active_profile = name
    if ctx.save_callback then ctx.save_callback() end
end

function profile_ops.load(ctx, name)
    local list = profile_list(ctx.settings)
    local snap = list[name]
    if not snap or name == DEFAULT_SLOT then return end
    -- Leaving Default: park the auto-saving working copy so clicking 'Default'
    -- later restores it. Named-to-named switches leave the stash alone.
    if profile_ops.active(ctx) == nil then
        list[DEFAULT_SLOT] = profile_snapshot(ctx.settings)
    end
    profile_apply(ctx.settings, ctx.job_def, snap)
    ctx.settings.active_profile = name
    if ctx.save_callback then ctx.save_callback() end
end

-- Back to the Default working copy: restore the parked stash (if any) and
-- resume plain auto-saving with no named profile active. With no stash (never
-- left Default, or pre-stash settings file) live settings are kept as-is --
-- only the mode switches back.
function profile_ops.load_default(ctx)
    if profile_ops.active(ctx) == nil then return end
    local stash = profile_list(ctx.settings)[DEFAULT_SLOT]
    if stash then
        profile_apply(ctx.settings, ctx.job_def, stash)
    end
    ctx.settings.active_profile = nil
    if ctx.save_callback then ctx.save_callback() end
end

-- New: reset the working copy to job defaults (same merge as setup_job), minus
-- the excluded window chrome -- New re-chromes nothing the user can see, since
-- PROFILE_EXCLUDED_KEYS gates the backfill too. Drops back to Default. Saved
-- profiles are untouched.
function profile_ops.new(ctx)
    profile_apply(ctx.settings, ctx.job_def,
        (ctx.job_def and ctx.job_def.merged_defaults) or {})
    ctx.settings.active_profile = nil
    if ctx.save_callback then ctx.save_callback() end
end

function profile_ops.delete(ctx, name)
    if not name then return end
    local list = profile_list(ctx.settings)
    if not list[name] then return end
    local was_active = profile_ops.active(ctx) == name
    list[name] = nil
    if ctx.settings.active_profile == name then
        ctx.settings.active_profile = nil
    end
    -- Deleting the selected profile drops back to Default: restore the parked
    -- working copy (same as clicking 'Default'). Without this, live settings
    -- keep the deleted snapshot while the UI shows Default selected, and the
    -- next named load would park that snapshot over the stash -- destroying
    -- the real Default working copy.
    if was_active then
        local stash = list[DEFAULT_SLOT]
        if stash then
            profile_apply(ctx.settings, ctx.job_def, stash)
        end
    end
    if ctx.save_callback then ctx.save_callback() end
end

-- Profile + job line and the Start/Stop button + status line. Shared by the
-- config window and the floating widget (/sk widget); the widget takes them
-- over while it is open so they only ever render once per frame.
local function render_header(ctx)
    local settings = ctx.settings
    local job_def = ctx.job_def
    local save_callback = ctx.save_callback

    -- Display job name and levels
    if job_def and job_def.job_name then
        -- Show normal job info
        local main_job_id, sub_job_id = common.get_player_job()
        local main_level, sub_level = common.get_player_level()
        local main_job_name = common.get_job_name_from_id(main_job_id)
        local sub_job_name = 'None'
        if sub_level and sub_level > 0 and sub_job_id and sub_job_id > 0 then
            sub_job_name = common.get_job_name_from_id(sub_job_id)
        end
        -- Settings profiles: button labeled with the active profile, opens
        -- the save/load panel (rendering in components, ops defined above).
        -- Leads the job line, fixed at the Start/Stop button width.
        ui.render_profile_button(ctx, profile_ops)
        imgui.SameLine()
        -- Center the job text on the button row (else it top-aligns).
        imgui.AlignTextToFramePadding()
        imgui.TextColored(ui.LIGHT_GREEN, string.format('%s %d / %s %d', main_job_name, main_level, sub_job_name, sub_level or 0))
    end

    -- Automation toggle button. Blue = enabled but suppressed by a runtime gate; the
    -- gate order below matches the tick loop's (loading, AFK sleep, mount, dead, rest).
    local button_text = settings.automation_enabled and 'Stop' or 'Start'
    local status_text, status_color = 'Automation stopped', ui.LIGHT_RED

    if settings.automation_enabled then
        status_color = ui.LIGHT_BLUE
        if     common.is_loading() then status_text = 'Automation loading'
        elseif afk.is_sleeping()   then status_text = 'Automation asleep'
        elseif common.is_mounted() then status_text = 'Automation mounted'
        elseif common.is_dead()    then status_text = 'Automation dead'
        elseif common.is_resting() then status_text = 'Automation resting'
        elseif common.can_attack() then status_text, status_color = 'Automation running', ui.LIGHT_GREEN
        else                            status_text = 'Automation paused'  -- combat blocked
        end
    end

    -- Use fixed width for button to keep consistent size
    if imgui.Button(button_text, { ui.AUTOMATION_BUTTON_WIDTH, 0 }) then
        -- Toggle automation
        AshitaCore:GetChatManager():QueueCommand(1, '/sidekick toggle')
    end

    -- Right-click: when automation stops by itself. Both opt-in, so an absent
    -- key reads as off.
    if ui.begin_opaque_context_item('##cmenu_automation') then
        local load_stopped = { settings.load_stopped == true }
        if imgui.Checkbox('Load stopped', load_stopped) then
            settings.load_stopped = load_stopped[1] or nil
            if save_callback then save_callback() end
        end
        if imgui.IsItemHovered() then
            ui.set_tooltip('Always load with automation stopped.\nOff: load in whatever state you left it.')
        end
        local stop_after_zone = { settings.stop_after_zone == true }
        if imgui.Checkbox('Stop after zone', stop_after_zone) then
            settings.stop_after_zone = stop_after_zone[1] or nil
            if save_callback then save_callback() end
        end
        if imgui.IsItemHovered() then
            ui.set_tooltip('Stop automation whenever you change zones.')
        end
        ui.end_opaque_popup()
    end

    -- Display status on same line
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol_Text, status_color)
    imgui.Text(status_text)
    imgui.PopStyleColor()
    ui.item_tooltip(tooltips.automation_status)

    -- Add Tracked Target button: only visible when current target is a valid PC
    -- (not NPC, not Trust, not already in party, not already tracked, not already in alliance)
    local targets_lib = common.targets
    local target_entity = targets_lib.get_t()
    local show_add_btn = false
    if target_entity then
        local spawn_flags = target_entity.SpawnFlags or 0
        local is_pc = bit.band(spawn_flags, 0x0001) ~= 0
        local target_sid = target_entity.ServerId or 0
        if is_pc and target_sid > 0 and target_sid < 0x1000000 then
            -- Not a Trust; check it's not in our party
            local in_party = false
            local party_obj = common.get_party()
            if party_obj then
                for pi = 0, 5 do
                    if party_obj:GetMemberIsActive(pi) == 1 then
                        if party_obj:GetMemberServerId(pi) == target_sid then
                            in_party = true
                            break
                        end
                    end
                end
            end
            if not in_party and not common.is_tracked_target(target_sid) and not common.is_alliance_member(target_sid) then
                show_add_btn = true
            end
        end
    end

    local add_target_btn_width = 120

    -- The widget shrink-wraps, so there is no content edge to right-align to:
    -- park the button at a fixed x wide enough for every row's worst case, so it
    -- never chases the status text. The slot is claimed every frame -- a
    -- zero-height Dummy stands in while the button is hidden -- so the widget's
    -- auto-resize width is a constant: it no longer twitches when the button
    -- appears/disappears or the job line changes length.
    if widget_visible then
        -- Row 1: profile button + 8px ItemSpacing + the longest job line any
        -- character can show (longest job name in both slots, 2-digit levels).
        -- Row 2: Start/Stop + 2x ItemSpacing + the longest status text + button.
        local job_text_w = imgui.CalcTextSize(WIDEST_JOB_LINE)
        local status_text_w = imgui.CalcTextSize('Automation mounted')
        local widget_width = math.max(
            ui.AUTOMATION_BUTTON_WIDTH + 8 + job_text_w,
            ui.AUTOMATION_BUTTON_WIDTH + 16 + status_text_w + add_target_btn_width)
        imgui.SameLine(widget_width - add_target_btn_width)
        if not show_add_btn then
            imgui.Dummy({ add_target_btn_width, 0 })
        end
    elseif show_add_btn then
        local content_max_x, _ = imgui.GetContentRegionMax()
        imgui.SameLine(content_max_x - add_target_btn_width)
    end

    if show_add_btn then
        if imgui.Button('Track Target', { add_target_btn_width, 0 }) then
            AshitaCore:GetChatManager():QueueCommand(1, '/sidekick addtarget')
        end
        ui.item_tooltip(tooltips.tracked_targets)
    end
end

-- ============================================================================
-- Module Functions
-- ============================================================================

function ui_config.initialize()
    -- No-op, reserved for future use
end

function ui_config.show()
    ui_visible = true
    is_open[1] = true
    -- A popup left open when the window last closed leaves stale was-open
    -- state that would arm a bg-alpha override on the reopen's first frame.
    ui.reset_opaque_tracking()
    -- Force the window uncollapsed on open. imgui persists a collapsed state in
    -- imgui.ini; without this, opening a previously-collapsed window shows only
    -- the title bar (and used to be force-closed by the render below).
    force_expand = true
end

function ui_config.hide()
    ui_visible = false
    is_open[1] = false
end

function ui_config.toggle()
    if ui_visible then
        ui_config.hide()
    else
        ui_config.show()
    end
end

function ui_config.is_visible()
    return ui_visible
end

function ui_config.toggle_widget()
    widget_visible = not widget_visible
    if widget_visible then
        ui.reset_opaque_tracking()  -- same stale-popup guard as show()
    end
end

function ui_config.is_widget_visible()
    return widget_visible
end

-- Floating widget: just the profile/job and Start/Stop rows, no title bar and
-- no close button (toggled only by /sk widget). Movable by dragging the body.
function ui_config.render_widget(settings, job_def, callback)
    if not widget_visible then
        return
    end

    local ctx = {
        settings = settings,
        save_callback = callback,
        job_def = job_def,
    }

    imgui.PushStyleVar(ImGuiStyleVar_Alpha, (settings.ui_opacity or 100) / 100)
    -- p_open must be a TABLE: Ashita's binding ignores the flags argument when it is nil,
    -- which is what put a title bar + [X] on this window. NoTitleBar means the [X] never
    -- renders, so nothing ever flips widget_open -- it is a dummy.
    if imgui.Begin('Sidekick Widget', widget_open,
        ImGuiWindowFlags_AlwaysAutoResize + ImGuiWindowFlags_NoTitleBar) then
        render_header(ctx)
    end
    imgui.End()
    imgui.PopStyleVar()
end

function ui_config.get_party_buffs()
    return party_buffs
end

--- Copy settings.party_buffs into the module-local mirror on first use.
-- Pulled out of render() so webui.lua can call it too: render() only runs
-- while the config window is open, and heal.lua / buff.lua / geo.lua /
-- status_removal.lua all read get_party_buffs() regardless of whether that
-- window has ever been opened this session. Guarded the same way it was
-- inline -- only hydrate while the mirror is still empty -- so a player who
-- toggles targets in-game first is never overwritten by a stale settings read.
function ui_config.hydrate_party_buffs(settings)
    if settings.party_buffs and next(party_buffs) == nil then
        -- Deep copy party_buffs from settings
        for ability_name, targets in pairs(settings.party_buffs) do
            party_buffs[ability_name] = {}
            for party_index, enabled in pairs(targets) do
                party_buffs[ability_name][party_index] = enabled
            end
        end
    end
end

function ui_config.get_party_buff_gates()
    return party_buff_gates
end

--- Drop both session-only party-buff mirrors so a stale character's target
-- selections can't leak into the next one. Sidekick.lua's setup_job calls
-- this from its character-changed branch, right before re-hydrating from the
-- newly loaded settings -- callers outside this file go through this
-- accessor rather than reaching into the party_buffs/party_buff_gates
-- module-locals directly. hydrate_party_buffs only ever fills an empty
-- mirror, so without this a same-job character switch would leave character
-- B's Buffs/Geo/Sleep Removal/Debuff Removal rows (and Combat/Idle overrides)
-- showing character A's choices -- in the in-game window, in state.json, and
-- in B's actual automation. party_buff_gates has no settings table to
-- re-hydrate from (it is purely session state), so clearing it is the whole
-- fix for that one.
function ui_config.reset_party_buff_state()
    for k in pairs(party_buffs) do party_buffs[k] = nil end
    for k in pairs(party_buff_gates) do party_buff_gates[k] = nil end
end

function ui_config.get_entrust_config()
    -- Return nil if entrust target or spell is None
    if not entrust_target_name or not entrust_spell_name then
        return nil
    end
    
    -- Find party member by name (check P1-P5 only, not P0)
    local party = common.get_party()
    if not party then
        return nil
    end
    
    local target_index = nil
    for i = 1, 5 do
        local member_name = common.get_party_member_name(i)
        if member_name and member_name == entrust_target_name then
            target_index = i
            break
        end
    end
    
    if not target_index then
        -- Target not in party
        return nil
    end
    
    return {
        target_index = target_index,         -- 1-5 for P1-P5
        target_name = entrust_target_name,   -- Character name
        spell_name = entrust_spell_name,     -- Spell name like "Indi-Haste"
    }
end

function ui_config.render(settings, job_def, callback)
    if not ui_visible or not is_open[1] then
        return
    end

    -- Zoning blanks the player memory block: HasSpell reads false for EVERY spell
    -- and level reads 0. The render path treats that as "unlearned" and writes it
    -- back destructively (ability_checkbox's disabled_<name> = true,
    -- disable_uncastable_songs dropping song targets), which deselected every cure
    -- on a zone. Skip those frames -- the window is behind a loading screen anyway.
    if common.is_loading() then
        return
    end

    -- Refresh if stale (automation tick may have already done it this frame).
    -- With automation stopped (and follow off, panel closed) nothing else
    -- refreshes game_state, so the alliance B/C buttons -- which read the
    -- game_state.alliance snapshot rather than the live party manager --
    -- would freeze until the user hit Start. Same guard as panel.lua.
    if os.clock() - common.game_state.refreshed_at > 0.1 then
        common.refresh_game_state()
    end

    -- Load entrust settings from settings on first render
    if settings.entrust_target ~= nil and entrust_target_name == nil then
        entrust_target_name = settings.entrust_target
    end
    if settings.entrust_spell ~= nil and entrust_spell_name == nil then
        entrust_spell_name = settings.entrust_spell
    end
    
    -- Load party buff selections from settings on first render
    ui_config.hydrate_party_buffs(settings)

    -- Always sync disabled_ keys from party_buffs to ensure consistency
    -- This prevents old disabled_ values from overriding the party buff selections
    if settings.party_buffs then
        for ability_name, targets in pairs(settings.party_buffs) do
            -- Check if ANY button is enabled for this ability
            local any_button_enabled = false
            for party_index, enabled in pairs(targets) do
                if enabled == true then
                    any_button_enabled = true
                    break
                end
            end
            -- Also check session-only tracked target entries (keyed as 'tt_<sid>')
            if not any_button_enabled and party_buffs[ability_name] then
                for k, v in pairs(party_buffs[ability_name]) do
                    if v == true and type(k) == 'string' then
                        any_button_enabled = true
                        break
                    end
                end
            end
            
            -- Sync the disabled_ key
            local disabled_key = 'disabled_' .. ability_name:gsub(' ', '_')
            if any_button_enabled then
                settings[disabled_key] = false
            else
                settings[disabled_key] = true
            end
        end
    end
    
    -- Load focus target settings from settings on first render
    if settings.focus_target ~= nil and focus_target_name == nil then
        focus_target_name = settings.focus_target
    end
    if settings.focus_recovery_target ~= nil and focus_recovery_target_name == nil then
        focus_recovery_target_name = settings.focus_recovery_target
    end
    if settings.follow_target ~= nil and follow_target_name == nil then
        follow_target_name = settings.follow_target
    end
    
    -- Store settings reference and callback
    current_settings = settings
    save_callback = callback

    -- Create context object for ui_components
    local ctx = {
        settings = current_settings,
        save_callback = save_callback,
        party_buffs = party_buffs,
        party_buff_gates = party_buff_gates,
        job_def = job_def,
        is_trust = is_trust,
        filter_func = {
            can_use_ability = can_use_ability
        }
    }

    -- Drop any song the player can't currently sing (e.g. after a level-sync
    -- down) so uncastable high-level songs stop holding the 2-song limit.
    ui.disable_uncastable_songs(ctx)

    -- Build party member list once (used by multiple dropdowns)
    local party_member_names = {}  -- Names only (P1-P5, excluding player)
    local party = common.get_party()
    if party then
        for i = 1, 5 do
            if party:GetMemberIsActive(i) == 1 then
                local member_name = common.get_party_member_name(i)
                if member_name and member_name ~= '' then
                    table.insert(party_member_names, member_name)
                end
            end
        end
    end

    -- Use consistent window title to maintain position across job changes
    local window_title = 'Sidekick Configuration'

    -- Un-collapse once when the window is (re)opened, so a collapsed imgui.ini
    -- state doesn't leave the user staring at an empty title bar.
    if force_expand then
        if imgui.SetNextWindowCollapsed then
            imgui.SetNextWindowCollapsed(false)
        end
        force_expand = false
    end

    -- Window sizing, per character. 'auto' is the original behaviour: the window is
    -- pinned to its contents and the resize grip is off. 'custom' is a plain window --
    -- drag it to any size, contents scroll when they overflow. The mode is switched from
    -- the right-click menu on empty body space (ui.render_window_size_menu, submitted at
    -- the end of this window), and applied HERE rather than at the click, because both
    -- the flags and the size constraints have to be settled before Begin opens the window.
    ui.apply_pending_window_size_mode(ctx)
    local window_flags = ImGuiWindowFlags_NoResize + ImGuiWindowFlags_AlwaysAutoResize
    if settings.window_size_mode == 'custom' then
        window_flags = 0  -- ImGuiWindowFlags_None: resize grip on, auto scrollbar on
        -- ImGui's own floor is style.WindowMinSize (32x32). The menu is still reachable
        -- there (BeginPopupContextWindow tests the whole outer rect, so the title bar
        -- opens it too), so this floor is comfort rather than an escape hatch.
        imgui.SetNextWindowSizeConstraints(
            { MIN_CUSTOM_WINDOW_WIDTH, MIN_CUSTOM_WINDOW_HEIGHT }, { FLT_MAX, FLT_MAX })
    end

    -- NOTE: imgui.Begin returns false when the window is COLLAPSED, not only when
    -- the [X] was clicked. Treat collapse as "still open, just skip content" and
    -- only close on the [X] (is_open flips to false). Always call End() to match
    -- Begin() per imgui rules.
    imgui.PushStyleVar(ImGuiStyleVar_Alpha, (settings.ui_opacity or 100) / 100)
    if imgui.Begin(window_title, is_open, window_flags) then

        -- Profile/job + Start/Stop rows move to the floating widget while it is open.
        if not widget_visible then
            render_header(ctx)
        end

        -- Tracked Targets list (show if any are being tracked)
        local tracked_list = common.get_tracked_targets()
        local has_tracked = next(tracked_list) ~= nil

        if has_tracked then
            local sorted_tt = {}
            for sid, tt in pairs(tracked_list) do
                table.insert(sorted_tt, { sid = sid, name = tt.name })
            end
            table.sort(sorted_tt, function(a, b) return a.name < b.name end)
            local remove_sid = nil
            local container_color = { 0.2, 0.2, 0.2, 1.0 }
            for t_idx, tt in ipairs(sorted_tt) do
                if t_idx > 1 then imgui.SameLine() end

                -- Non-interactive visual button container showing T-index + name
                imgui.PushStyleColor(ImGuiCol_Button, container_color)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, container_color)
                imgui.PushStyleColor(ImGuiCol_ButtonActive, container_color)
                imgui.PushID('lbl_' .. tostring(tt.sid))
                imgui.Button('T' .. t_idx .. ' ' .. tt.name)
                imgui.PopID()
                imgui.PopStyleColor(3)

                imgui.SameLine(0, 2)
                imgui.PushID('rm_' .. tostring(tt.sid))
                if imgui.Button('X') then
                    remove_sid = tt.sid
                end
                imgui.PopID()
            end
            if remove_sid then
                common.remove_tracked_target(remove_sid)
                -- Clean up party_buffs entries for this tracked target
                local tt_key = 'tt_' .. remove_sid
                for key, targets in pairs(party_buffs) do
                    if targets[tt_key] then
                        targets[tt_key] = nil
                    end
                end
            end
        end
        
        -- Attack Range (global). Shown only in Multisend Follow mode (native Follow hidden).
        if settings.multisend_follow then
            local attack_range_options = { 'Off', 'Melee (3 yalms)', 'Ranged (15 yalms)' }
            local attack_range_current = settings.attack_range or 'Off'
            local attack_range_index = { 0 }
            
            -- Find current index
            for i, option in ipairs(attack_range_options) do
                if option == attack_range_current then
                    attack_range_index[1] = i - 1
                    break
                end
            end
            
            ui.combo(ctx, 'Attack Range', 'attack_range', attack_range_index, attack_range_options, function(i)
                return attack_range_options[i + 1]
            end)
            ui.item_tooltip(tooltips.attack_range)
        end

        -- Everything from here to end_sections is a "section": one enable checkbox
        -- plus a body. They render as collapsing headers or as a tab bar depending
        -- on settings.display_mode. Nothing but sections may be submitted between
        -- these two calls -- in tab mode a stray widget would land inside the tab
        -- bar, which ImGui does not allow.
        ui.begin_sections(ctx)

        -- Auto Follow (job-independent, top of window). Follow Target is shared with
        -- Resting's distance check. Changing it resets autofollow. Hidden in Multisend mode.
        if not settings.multisend_follow then
            local follow_on_change = function()
                common.reset_autofollow()
                if callback then callback() end
            end
            local is_open, is_enabled = ui.begin_section(ctx, 'Auto Follow', 'follow_enabled', false)
            ui.item_tooltip(tooltips.follow)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                follow_target_name = render_party_dropdown('Follow Target', 'follow_target', false, party_member_names, settings, follow_on_change, true)
                ui.item_tooltip(tooltips.follow_target)
                ui.slider_int(ctx, 'Distance (yalms)##follow_distance', 'follow_distance', { settings.follow_distance or 5 }, 1, 15)
                ui.item_tooltip(tooltips.follow_distance)
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Pet Control: master `pet_enabled` header checkbox (same shape as every other
        -- section) over two independent per-feature checkboxes -- send pet at target
        -- (labelled PUP Deploy / SMN Assault / BST Fight, the job's own ability name --
        -- "Deploy" is never used as the feature's name) and maneuver upkeep. Sits by
        -- Auto Follow, the other section that moves something rather than supporting it.
        -- Gated on the ability lists being present and usable (same pattern as "Pet
        -- Debuff Removal" below), not on job_def.job_id -- that only ever reads the
        -- *main* job's id and would hide maneuvers for a subjob PUP, which is supported.
        local pet_control_list = job_def and job_def.abilities.pet_control
        local maneuver_list = job_def and job_def.abilities.maneuver
        local has_pet_control = pet_control_list and has_usable_abilities(pet_control_list)
        local has_maneuver = maneuver_list and has_usable_abilities(maneuver_list)

        if has_pet_control or has_maneuver then
            local is_open, is_enabled = ui.begin_section(ctx, 'Pet Control', 'pet_enabled', true)
            ui.item_tooltip(tooltips.pet_control)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)

                -- Labelled with the job's own ability name (Deploy / Assault / Fight),
                -- plus the target the pet gets sent at on the same row
                if has_pet_control then
                    ui.checkbox(ctx, pet_control_list[1].name, 'pet_control_enabled', { settings.pet_control_enabled or false })
                    imgui.SameLine()
                    ui.combo(ctx, '##pet_control_target', 'pet_control_target',
                        { settings.pet_control_target == '<bt>' and 1 or 0 },
                        { '<T>', '<BT>' },  -- display only; converter stores lowercase for the command
                        function(i) return i == 1 and '<bt>' or '<t>' end, 70)
                end

                -- One checkbox plus three unlabelled slot dropdowns on the same row
                if has_maneuver then
                    local available_maneuvers = {}
                    for _, ability in ipairs(maneuver_list) do
                        if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                            table.insert(available_maneuvers, ability)
                        end
                    end

                    ui.checkbox(ctx, 'Maneuver', 'maneuver_enabled', { settings.maneuver_enabled ~= false })
                    imgui.SameLine()
                    render_ability_dropdown('##maneuver1', 'maneuver1_name', available_maneuvers, settings, callback, nil, 100)
                    imgui.SameLine()
                    render_ability_dropdown('##maneuver2', 'maneuver2_name', available_maneuvers, settings, callback, nil, 100)
                    imgui.SameLine()
                    render_ability_dropdown('##maneuver3', 'maneuver3_name', available_maneuvers, settings, callback, nil, 100)
                end

                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Show job-specific sections if we have a job definition
        if job_def then
        
        -- Focus Healing settings
        if job_def and job_def.abilities.heal and has_usable_abilities(job_def.abilities.heal) then
            local has_non_self_heal = false
            for _, ability in ipairs(job_def.abilities.heal) do
                if not ability.self_only then
                    has_non_self_heal = true
                    break
                end
            end
            
            if has_non_self_heal then
                local is_open, is_enabled = ui.begin_section(ctx, 'Focus Healing', 'focus_enabled', false)
                ui.item_tooltip(tooltips.focus_healing)
                if is_open and is_enabled then
                    imgui.Indent(ui.ABILITY_LIST_INDENT)
                    -- Focus Target dropdown
                    focus_target_name = render_party_dropdown('Focus Target', 'focus_target', true, party_member_names, settings, callback, true)
                    
                    ui.slider_int(ctx, 'Focus (HP%)', 'focus_threshold', { settings.focus_threshold or 85 }, 1, 100)
                    imgui.Unindent(ui.ABILITY_LIST_INDENT)
                end
                ui.end_section(ctx, is_open)
            end
        end
        
        -- Group Healing settings
        if job_def and job_def.abilities.heal and has_usable_abilities(job_def.abilities.heal) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Group Healing', 'heal_enabled', false)
            ui.item_tooltip(tooltips.group_healing)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.slider_int(ctx, 'Group (HP%)', 'heal_threshold', { settings.heal_threshold or 75 }, 1, 100)
                -- Group Targets buttons only make sense when a heal can target others;
                -- hide them for self-only heal sets (mirrors Focus Healing gate above).
                local has_non_self_heal = false
                for _, ability in ipairs(job_def.abilities.heal) do
                    if not ability.self_only then
                        has_non_self_heal = true
                        break
                    end
                end
                if has_non_self_heal then
                    ui.render_heal_group_selection(ctx, 'heal_group', true)
                    imgui.SameLine()
                    imgui.Text('Group Targets')
                end
                for _, ability in ipairs(job_def.abilities.heal) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'heal', true)
                    end
                end
                
                -- Critical HP section (inside Group Healing)
                if job_def.abilities.critical and has_usable_abilities(job_def.abilities.critical) then
                    ui.slider_int(ctx, 'Critical (HP%)', 'critical_threshold', { settings.critical_threshold or 30 }, 1, 50)
                    ui.item_tooltip(tooltips.critical_hp)
                    for _, ability in ipairs(job_def.abilities.critical) do
                        if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                            ui.ability_checkbox(ctx, ability, job_def, 'critical')
                        end
                    end
                end
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        
        -- AOE Healing settings
        if job_def and job_def.abilities.heal_aoe and has_usable_abilities(job_def.abilities.heal_aoe) then
            local is_open, is_enabled = ui.begin_section(ctx, 'AOE Healing', 'heal_aoe_enabled', false)
            ui.item_tooltip(tooltips.aoe_healing)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.slider_int(ctx, 'AOE (HP%)', 'heal_aoe_threshold', { settings.heal_aoe_threshold or 70 }, 1, 100)
                ui.render_heal_group_selection(ctx, 'heal_aoe_group', false)
                imgui.SameLine()
                imgui.Text('AOE Targets')

                for _, ability in ipairs(job_def.abilities.heal_aoe) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'heal_aoe', true)
                    end
                end
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        
        -- Pet Healing settings
        if job_def and job_def.abilities.heal_pet and has_usable_abilities(job_def.abilities.heal_pet) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Pet Healing', 'heal_pet_enabled', false)
            ui.item_tooltip(tooltips.pet_healing)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.slider_int(ctx, 'Pet (HP%)', 'heal_pet_threshold', { settings.heal_pet_threshold or 50 }, 1, 100)
                
                for _, ability in ipairs(job_def.abilities.heal_pet) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'heal_pet')
                        render_ammo_count(ability, true)
                    end
                end

                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Wake detection (used by the Sleep Removal section below)
        local has_wake_abilities = false
        local has_outside_wake = false
        if job_def and job_def.abilities.heal then
            for _, ability in ipairs(job_def.abilities.heal) do
                if ability.wakes and can_use_ability(ability) then
                    has_wake_abilities = true
                    if ability.target_outside then
                        has_outside_wake = true
                        break
                    end
                end
            end
        end

        -- Sleep removal settings. Hidden while solo -- you cannot cure your own
        -- Sleep, so with no P1..P5 to scan the whole section is dead UI.
        if has_wake_abilities and common.get_party_size() > 1 then
            local is_open_wake, is_enabled_wake = ui.begin_section(ctx, 'Sleep Removal', 'wake_enabled', false)
            ui.item_tooltip(tooltips.sleep_removal)
            if is_open_wake and is_enabled_wake then
                -- Party selection buttons (who gets sleep removal)
                -- exclude ME since player cannot wake themselves from sleep
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.render_party_selection(ctx, 'wake', has_outside_wake, false)
                imgui.SameLine()
                imgui.Text('Sleep Targets')
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open_wake)
        end

        -- Debuff removal settings
        if job_def and job_def.abilities.debuff_removal and has_usable_abilities(job_def.abilities.debuff_removal) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Debuff Removal', 'debuff_removal_enabled', false)
            ui.item_tooltip(tooltips.debuff_removal)
            if is_open and is_enabled then
                -- Clear temporary group rendering flags
                if current_settings then
                    for key in pairs(current_settings) do
                        if key:match('^rendered_group_') then
                            current_settings[key] = nil
                        end
                    end
                end

                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ctx.show_trust_warning = true
                for _, ability in ipairs(job_def.abilities.debuff_removal) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.render_ability(ctx, ability, job_def, 'debuff_removal')
                    end
                end
                ctx.show_trust_warning = false
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Pet Debuff Removal settings (BST Reward+Roborant, PUP Maintenance+Oil).
        -- Pet statuses are inferred from packets (the client has no pet buff
        -- memory), so warn it's not fully reliable -- same caveat as Trust/tracked.
        if job_def and job_def.abilities.pet_debuff_removal and has_usable_abilities(job_def.abilities.pet_debuff_removal) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Pet Debuff Removal', 'pet_debuff_removal_enabled', false)
            ui.item_tooltip(tooltips.pet_debuff_removal)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ctx.show_pet_debuff_warning = true
                for _, ability in ipairs(job_def.abilities.pet_debuff_removal) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'pet_debuff_removal')
                        render_ammo_count(ability)
                    end
                end
                ctx.show_pet_debuff_warning = false
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Item-based status removal (consumables) -- hidden until inventory loads
        -- (counts read as "?"); shown once readable, even if every count is 0.
        if ui.item_inventory_loaded() then
            local is_open_item, is_enabled_item = ui.begin_section(ctx, 'Item Debuff Removal', 'item_removal_enabled', false)
            ui.item_tooltip(tooltips.item_removal)
            if is_open_item and is_enabled_item then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.item_removal_checkboxes(ctx)
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open_item)
        end

        -- Resting (MP jobs). Distance watches the Auto Follow section's Follow Target.
        if job_def and job_def.resource_type == 'mp' then
            local is_open, is_enabled = ui.begin_section(ctx, 'Resting', 'rest_enabled', false)
            ui.item_tooltip(tooltips.resting)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ui.slider_int(ctx, 'Timer (seconds)', 'rest_timer', { settings.rest_timer or 5 }, 1, 20)
                ui.item_tooltip(tooltips.rest_timer)

                ui.slider_int(ctx, 'Distance (yalms)##rest_distance', 'rest_distance', { settings.rest_distance or 7 }, 1, 15)
                ui.item_tooltip(tooltips.rest_distance)
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        
        -- Recovery settings
        local has_mp_recovery = job_def and job_def.abilities.recover_mp and has_usable_abilities(job_def.abilities.recover_mp)
        local has_tp_recovery = job_def and job_def.abilities.recover_tp and has_usable_abilities(job_def.abilities.recover_tp)
        local has_party_mp_recovery = job_def and job_def.abilities.recover_party_mp and has_usable_abilities(job_def.abilities.recover_party_mp)
        
        if has_mp_recovery or has_tp_recovery or has_party_mp_recovery then
            local is_open, is_enabled = ui.begin_section(ctx, 'Resource Recovery', 'recover_enabled', false)
            ui.item_tooltip(tooltips.resource_recovery)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                -- Self Recover (TP%) section
                if has_tp_recovery then
                    ui.slider_int(ctx, 'Self Recover (TP)', 'recover_tp_threshold', { settings.recover_tp_threshold or 500 }, 100, 3000)
                    for _, ability in ipairs(job_def.abilities.recover_tp) do
                        if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                            ui.ability_checkbox(ctx, ability, job_def, 'recover_tp')
                        end
                    end
                    
                    if has_mp_recovery or has_party_mp_recovery then
                        imgui.Spacing()
                    end
                end
                
                -- Self Recover (MP%) section
                if has_mp_recovery then
                    ui.slider_int(ctx, 'Self Recover (MP%)', 'recover_mp_threshold', { settings.recover_mp_threshold or 30 }, 1, 100)
                    local chivalry_visible = false
                    for _, ability in ipairs(job_def.abilities.recover_mp) do
                        if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                            ui.ability_checkbox(ctx, ability, job_def, 'recover_mp')
                            if ability.min_tp ~= nil then
                                chivalry_visible = true
                            end
                        end
                    end
                    if chivalry_visible then
                        ui.slider_int(ctx, 'Chivalry Min TP', 'chivalry_min_tp', { settings.chivalry_min_tp or 3000 }, 0, 3000)
                    end

                    if has_party_mp_recovery then
                        imgui.Spacing()
                    end
                end
                
                -- Party MP recovery section (for Devotion)
                if has_party_mp_recovery then
                    -- Recovery Target dropdown
                    -- Party-only: Devotion resolves by P1-P5 index in recover.lua, so
                    -- tracked/alliance targets would never match. Don't offer them.
                    focus_recovery_target_name = render_party_dropdown('Recovery Target', 'focus_recovery_target', false, party_member_names, settings, callback, false)
                    
                    if focus_recovery_target_name then
                        ui.slider_int(ctx, 'Target Recover (MP%)', 'focus_recovery_threshold', { settings.focus_recovery_threshold or 30 }, 1, 100)
                    end
                    
                    for _, ability in ipairs(job_def.abilities.recover_party_mp) do
                        if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                            ui.ability_checkbox(ctx, ability, job_def, 'recover_party_mp')
                        end
                    end
                end
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        
        -- Roll settings (Corsair): pick two rolls and the total to stop doubling at
        if job_def and job_def.abilities.roll and has_usable_abilities(job_def.abilities.roll) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Rolls', 'roll_enabled', true)
            ui.item_tooltip(tooltips.rolls)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)

                -- Rolls are unlocked individually, not purely by level, so the level
                -- check in can_use_ability isn't enough -- has_spell_learned reads the
                -- client's own ability list (HasAbility) and drops rolls you don't know.
                local available_rolls = {}
                for _, ability in ipairs(job_def.abilities.roll) do
                    if can_use_ability(ability) and common.has_spell_learned(ability)
                        and not is_subjob_duplicate(job_def, ability) then
                        table.insert(available_rolls, ability)
                    end
                end

                render_ability_dropdown('Roll 1', 'roll1_name', available_rolls, settings, callback, tooltips.roll_slot, nil, roll.reset_state)

                -- Corsair as a subjob can only keep one roll up, so slot 2 is hidden
                -- and force-cleared. roll.lua enforces the same rule independently.
                local cor_is_sub = job_def.abilities.roll[1] and job_def.abilities.roll[1].is_main_job == false
                if cor_is_sub then
                    if settings.roll2_name then
                        settings.roll2_name = nil
                        roll.reset_state()
                        callback()
                    end
                else
                    render_ability_dropdown('Roll 2', 'roll2_name', available_rolls, settings, callback, tooltips.roll_slot, nil, roll.reset_state)
                end

                -- Risk tier drives the whole Double-Up / Snake Eye / Fold decision
                -- (lib/core/roll_strategy.lua). Labels are display-only; the setting
                -- stores the lowercase key.
                local tier_labels = { 'Lowest', 'Medium', 'Highest' }
                local tier_values = { 'lowest', 'medium', 'highest' }
                local tier_index  = { 1 }  -- default Medium
                for i, value in ipairs(tier_values) do
                    if value == (settings.risk_tier or 'medium') then
                        tier_index[1] = i - 1
                        break
                    end
                end
                ui.combo(ctx, 'Risk Tier##risk_tier', 'risk_tier', tier_index, tier_labels, function(i)
                    return tier_values[i + 1]
                end)
                ui.item_tooltip(tooltips.risk_tier)

                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Buff settings
        if job_def and job_def.abilities.buff and has_usable_abilities(job_def.abilities.buff) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Buffs', 'buff_enabled', false)
            ui.item_tooltip(tooltips.buffs)
            if is_open and is_enabled then
                -- Clear temporary group rendering flags
                if current_settings then
                    for key in pairs(current_settings) do
                        if key:match('^rendered_group_') then
                            current_settings[key] = nil
                        end
                    end
                end
                
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                ctx.show_buff_warning = true
                for _, ability in ipairs(job_def.abilities.buff) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.render_ability(ctx, ability, job_def, 'buff')
                        render_ammo_count(ability, true)  -- name equipped tier (NIN Sange shuriken)
                    end
                end
                ctx.show_buff_warning = false
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        
        -- Geo settings (Geomancer)
        if job_def and job_def.abilities.geo and has_usable_abilities(job_def.abilities.geo) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Geo', 'geo_enabled', false)
            ui.item_tooltip(tooltips.geo)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)

                -- Geo-bt debuff selector (<bt> enemy debuffs): self-grouped
                -- ON/OFF + dropdown. Cast/luopan lifecycle lives in geo.lua.
                if current_settings then
                    current_settings['rendered_group_Geo-bt'] = nil
                end
                for _, ability in ipairs(job_def.abilities.geo) do
                    if ability.group == 'Geo-bt' then
                        ui.render_ability(ctx, ability, job_def, 'geo')
                    end
                end

                -- Full Circle checkbox, kept directly above its own Distance/Timer
                -- sliders. Blaze of Glory renders after them (below) rather than in
                -- this loop, so it can't split Full Circle from its settings.
                for _, ability in ipairs(job_def.abilities.geo) do
                    if ability.group == nil and ability.name ~= 'Entrust' and ability.name ~= 'Blaze of Glory'
                        and can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'geo')
                        ui.item_tooltip(tooltips.geo_full_circle)
                    end
                end

                -- Distance threshold (Full Circle recast trigger)
                ui.slider_int(ctx, 'Distance (yalms)##geo_distance_threshold', 'geo_distance_threshold', { settings.geo_distance_threshold or 10 }, 7, 30)
                ui.item_tooltip(tooltips.geo_distance)

                -- Grace period after the battle target dies before Full Circle
                -- dismisses the Geo-bt luopan (lets a fresh <bt> reuse it).
                -- Geo-bt is Geomancer-only, so only show it there.
                if job_def.job_id == 21 then
                    ui.slider_int(ctx, 'Timer (seconds)##geo_bt_timer', 'geo_bt_timer', { settings.geo_bt_timer or 5 }, 1, 20)
                    ui.item_tooltip(tooltips.geo_bt_timer)
                end

                -- Blaze of Glory: a precast for the NEXT Geo spell, not part of the
                -- Full Circle distance logic, so it sits below those sliders.
                for _, ability in ipairs(job_def.abilities.geo) do
                    if ability.name == 'Blaze of Glory' and can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'geo')
                        ui.item_tooltip(tooltips.geo_blaze_of_glory)
                    end
                end

                -- Entrust settings (only for Geomancer)
                if job_def.job_id == 21 then
                    -- Build list of available Indi spells
                    local available_indi_spells = {}
                    if job_def.abilities.buff then
                        for _, ability in ipairs(job_def.abilities.buff) do
                            if ability.group == 'Indi' and can_use_ability(ability) and common.has_spell_learned(ability) then
                                table.insert(available_indi_spells, ability)
                            end
                        end
                    end
                    
                    -- Sort by level descending (highest first)
                    table.sort(available_indi_spells, function(a, b) return a.level > b.level end)
                    
                    if #available_indi_spells > 0 then
                        -- Entrust ability checkbox
                        for _, ability in ipairs(job_def.abilities.geo) do
                            if ability.name == 'Entrust' and can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                                ui.ability_checkbox(ctx, ability, job_def, 'geo')
                                ui.item_tooltip(tooltips.geo_entrust_enable)
                            end
                        end

                        -- Entrust Target dropdown
                        entrust_target_name = render_party_dropdown('Entrust Target', 'entrust_target', false, party_member_names, settings, callback)
                        ui.item_tooltip(tooltips.geo_entrust_target)

                        -- Validate saved spell name is in available spells
                        local current_spell_display = 'None'
                        if entrust_spell_name then
                            local found = false
                            for _, spell in ipairs(available_indi_spells) do
                                if spell.name == entrust_spell_name then
                                    current_spell_display = spell.name
                                    if spell.cost and spell.cost > 0 then
                                        current_spell_display = current_spell_display .. ' (' .. spell.cost .. ' MP)'
                                    end
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                -- Saved spell not available, reset
                                entrust_spell_name = nil
                                settings.entrust_spell = nil
                                if callback then callback() end
                            end
                        end
                        
                        -- Entrust Spell dropdown
                        imgui.PushItemWidth(250)
                        if ui.begin_opaque_combo('Entrust Spell', current_spell_display) then
                            -- Add None option
                            local is_none_selected = (entrust_spell_name == nil)
                            if imgui.Selectable('None', is_none_selected) then
                                entrust_spell_name = nil
                                settings.entrust_spell = nil
                                if callback then callback() end
                            end
                            if is_none_selected then
                                imgui.SetItemDefaultFocus()
                            end
                            
                            -- Add spell options
                            for _, spell in ipairs(available_indi_spells) do
                                local label = spell.name
                                if spell.cost and spell.cost > 0 then
                                    label = label .. ' (' .. spell.cost .. ' MP)'
                                end
                                local is_selected = (spell.name == entrust_spell_name)
                                if imgui.Selectable(label, is_selected) then
                                    entrust_spell_name = spell.name
                                    settings.entrust_spell = spell.name
                                    if callback then callback() end
                                end
                                if is_selected then
                                    imgui.SetItemDefaultFocus()
                                end
                            end
                            ui.end_opaque_combo()
                        end
                        imgui.PopItemWidth()
                        ui.item_tooltip(tooltips.geo_entrust_spell)
                    end
                end
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end

        -- Revive settings
        if job_def and job_def.abilities.revive and has_usable_abilities(job_def.abilities.revive) then
            local is_open, is_enabled = ui.begin_section(ctx, 'Revive', 'revive_enabled', false)
            ui.item_tooltip(tooltips.revive)
            if is_open and is_enabled then
                imgui.Indent(ui.ABILITY_LIST_INDENT)
                for _, ability in ipairs(job_def.abilities.revive) do
                    if can_use_ability(ability) and not is_subjob_duplicate(job_def, ability) then
                        ui.ability_checkbox(ctx, ability, job_def, 'revive', true)
                    end
                end
                imgui.Unindent(ui.ABILITY_LIST_INDENT)
            end
            ui.end_section(ctx, is_open)
        end
        end  -- End of job_def check

        ui.end_sections(ctx)

        -- Right-click on empty body space opens the window-sizing menu. Submitted last:
        -- it must sit OUTSIDE the section run (ImGui allows nothing but tab items between
        -- begin_sections and end_sections), and by here every item for the frame has been
        -- submitted, so NoOpenOverItems has the full hover picture to test against.
        ui.render_window_size_menu(ctx)
    end
    imgui.End()
    imgui.PopStyleVar()

    -- Close only when the [X] was clicked (imgui sets is_open to false). A mere
    -- collapse leaves is_open true, so the window stays open.
    if not is_open[1] then
        ui_visible = false
    end
end

return ui_config
