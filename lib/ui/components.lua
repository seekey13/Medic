--[[
    UI Components for Sidekick Configuration
    Reusable UI rendering components extracted for DRY principles
]]--

local ui_components = {}

local imgui = require('imgui')
local common = require('lib.core.common')
local item_module = require('lib.actions.item')
local action_core = require('lib.core.action_core')
local tooltips = require('lib.ui.tooltips')

-- ============================================================================
-- UI Constants
-- ============================================================================

-- Layout Constants
local ABILITY_LIST_INDENT = 10
local PARTY_BUTTON_WIDTH = 35
local SPACE_BETWEEN_BUTTONS = 8

-- Width Constants
local DROPDOWN_WIDTH = 300
local SLIDER_WIDTH = 250
local DROPDOWN_FALLBACK_WIDTH = 200
local AUTOMATION_BUTTON_WIDTH = 80

-- Color Constants - Text
local LIGHT_RED = { 1.0, 0.7, 0.7, 1.0 }
local LIGHT_YELLOW = { 1.0, 1.0, 0.7, 1.0 }
local LIGHT_GREEN = { 0.7, 1.0, 0.7, 1.0 }
local LIGHT_BLUE = { 0.7, 0.7, 1.0, 1.0 }
local LIGHT_GRAY = { 0.5, 0.5, 0.5, 1.0 }

-- Color Constants - Buttons
local COLOR_BUTTON_DISABLED = { 0.2, 0.2, 0.2, 1.0 }
local COLOR_BUTTON_UNSELECTED = { 0.3, 0.3, 0.3, 1.0 }
local COLOR_BUTTON_UNSELECTED_HOVER = { 0.4, 0.4, 0.4, 1.0 }
local COLOR_BUTTON_UNSELECTED_ACTIVE = { 0.5, 0.5, 0.5, 1.0 }

-- Color Constants - Headers
local HEADER_COLOR_NORMAL = { 0.2, 0.2, 0.2, 0.31 }
local HEADER_COLOR_HOVERED = { 0.2, 0.2, 0.2, 0.45 }
local HEADER_COLOR_ACTIVE = { 0.2, 0.2, 0.2, 0.65 }

-- Color Constants - Tabs (disabled sections only; enabled tabs keep the theme's
-- own ImGuiCol_Tab* colors). A section's enable checkbox lives inside its tab
-- body, so dimming is the only thing that shows enable state without opening it.
local TAB_COLOR_DISABLED = { 0.15, 0.15, 0.15, 0.50 }
local TAB_COLOR_DISABLED_HOVERED = { 0.25, 0.25, 0.25, 0.60 }
local TAB_COLOR_DISABLED_ACTIVE = { 0.30, 0.30, 0.30, 0.80 }

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Returns true if the ability's effective (user-driven) combat_only setting is enabled.
local function effective_combat_only(ability, ctx)
    if not ability or not ctx or not ctx.settings then return false end
    return common.is_ability_combat_only(ability, ctx.settings)
end

-- Render a right-click 'Combat Only' / 'Idle Only' toggle popup for an ability/group.
-- Call immediately after the imgui item the popup should attach to.
-- The two are mutually exclusive (checking one clears the other). Suppressed for
-- statically idle_only abilities (data-defined), where the gate isn't user-editable.
-- <bt> abilities are inherently combat-only, so they hide the Combat/Idle Only
-- toggles; grouped ones (DRK Absorbs) still get the Ungroup entry. Geo-bt is
-- fully suppressed: geo.lua's luopan lifecycle only supports one selected spell.
local function render_combat_only_context_menu(ctx, ability, scope)
    if not ability or not ctx or not ctx.settings then return end
    if ability.idle_only then return end
    local bt = common.ability_targets_bt(ability)
    -- Statically combat_only abilities (data-defined) gate isn't user-editable,
    -- same as bt: hide the Combat/Idle toggles, but grouped ones still get Ungroup.
    local hide_toggles = bt or ability.combat_only
    if hide_toggles and (not ability.group or ability.group == 'Geo-bt') then return end
    -- scope disambiguates the popup id when the same ability renders in two
    -- sections (e.g. Chakra in both Group Healing and Debuff Removal); without it
    -- both BeginPopupContextItem calls share an id and stack duplicate menus.
    -- Setting keys stay unscoped: it's one recast, so its gate is shared.
    local scope_suffix = scope and ('_' .. scope) or ''
    -- Popup id is always per-ability: when a group is ungrouped each tier renders
    -- its own row, so a shared group id would stack duplicate menus into one popup.
    local popup_id
    if ability.group then
        popup_id = '##cmenu_combat_only_group_' .. ability.group .. '_' .. (ability.name and ability.name:gsub(' ', '_') or '') .. scope_suffix
    else
        if not ability.name then return end
        popup_id = '##cmenu_combat_only_' .. ability.name:gsub(' ', '_') .. scope_suffix
    end
    if ui_components.begin_opaque_context_item(popup_id) then
        -- Setting keys follow common.ability_gate_key: group-level while grouped,
        -- per-ability once the group is ungrouped (so each tier gets its own gate).
        -- Built here (not above the Ungroup block) so a grouped bt/combat_only
        -- ability with no name still reaches the Ungroup checkbox to re-group.
        local combat_key = common.ability_gate_key('combat_only', ability, ctx.settings)
        local idle_key = common.ability_gate_key('idle_only', ability, ctx.settings)
        if not hide_toggles and combat_key and idle_key then
            local combat_cur = { ctx.settings[combat_key] == true }
            if imgui.Checkbox('Combat Only', combat_cur) then
                ctx.settings[combat_key] = combat_cur[1] or nil
                if combat_cur[1] then ctx.settings[idle_key] = nil end  -- mutually exclusive
                if ctx.save_callback then ctx.save_callback() end
            end
            local idle_cur = { ctx.settings[idle_key] == true }
            if imgui.Checkbox('Idle Only', idle_cur) then
                ctx.settings[idle_key] = idle_cur[1] or nil
                if idle_cur[1] then ctx.settings[combat_key] = nil end  -- mutually exclusive
                if ctx.save_callback then ctx.save_callback() end
            end
            if imgui.IsItemHovered() then
                ui_components.set_tooltip('Only fire when out of combat (e.g. Boost on cooldown).')
            end
        end
        -- Hold a Stratagem for AOE: an aoe_precast heal (SCH Accession) is the only
        -- consumer allowed to spend the reserved charge -- common.spendable_stratagems
        -- hides it from every other one. It rides in THIS popup rather than a second
        -- BeginPopupContextItem on the same widget, which would stack duplicate menus
        -- (see the note at the top of this function).
        if ability.aoe_precast then
            imgui.Separator()
            local reserve = { ctx.settings.stratagem_reserve_aoe == true }
            if imgui.Checkbox('Hold a Stratagem for AOE', reserve) then
                ctx.settings.stratagem_reserve_aoe = reserve[1] or nil
                if ctx.save_callback then ctx.save_callback() end
            end
            if imgui.IsItemHovered() then
                ui_components.set_tooltip('Keep one stratagem in reserve for AOE healing.\nEvery other stratagem use then treats 1 charge as 0.')
            end
        end
        -- Ungroup: cast every tier in the group independently instead of only
        -- the selected tier. Off (grouped) by default; persisted per group.
        if ability.group then
            local ung_key = 'ungrouped_' .. ability.group
            local ung = { ctx.settings[ung_key] == true }
            if imgui.Checkbox('Ungroup', ung) then
                ctx.settings[ung_key] = ung[1] or nil
                if ctx.save_callback then ctx.save_callback() end
            end
            if imgui.IsItemHovered() then
                ui_components.set_tooltip('Cast each tier in this group independently\n(e.g. both Mage\'s Ballad and Mage\'s Ballad II).')
            end
            -- Auto Select: let lib/core/vanadiel.lua keep the group's selection on
            -- the tier whose element matches the environment. Hidden while ungrouped
            -- -- ungrouped casts every tier, so there is no single selection to steer.
            if ability.auto_element and ctx.settings[ung_key] ~= true then
                local weather_only = ability.auto_element_source == 'weather'
                local auto_key = 'auto_element_' .. ability.group
                local auto = { ctx.settings[auto_key] == true }
                if imgui.Checkbox(weather_only and 'Auto Select for Weather' or 'Auto Select for Weather/Day', auto) then
                    ctx.settings[auto_key] = auto[1] or nil
                    if ctx.save_callback then ctx.save_callback() end
                end
                if imgui.IsItemHovered() then
                    if weather_only then
                        ui_components.set_tooltip('Match the zone weather, doubling its bonus.\nThe dropdown will move on its own.\nNo weather leaves your pick alone.')
                    else
                        ui_components.set_tooltip('Pick the tier matching the current element.\nStorm buff > weather > day of the week.\nThe dropdown will move on its own.\nNo match (e.g. Lightsday) leaves it alone.')
                    end
                end
            end
        end
        -- Per-status opt-out for multi-status removers (Erase, Esuna, Cursna,
        -- Viruna, Chakra...). One checkbox per status the ability strips; all
        -- enabled by default (absent 'skip_debuff_*' key = still removed). Keys
        -- match common.effective_debuff_ids so the automation honours them.
        local rids = ability.debuff_id
        if type(rids) == 'table' and #rids >= 2 and ability.name then
            imgui.Separator()
            imgui.Text('Remove:')
            local prefix = 'skip_debuff_' .. ability.name:gsub(' ', '_') .. '_'
            local function render_status_rows(first, last)
                for i = first, last do
                    local id = rids[i]
                    local label = common.DEBUFF_NAMES[id] or ('Status ' .. id)
                    local on = { ctx.settings[prefix .. id] ~= true }
                    if imgui.Checkbox(label .. '##' .. prefix .. id, on) then
                        ctx.settings[prefix .. id] = (not on[1]) or nil
                        if ctx.save_callback then ctx.save_callback() end
                    end
                end
            end
            -- Long lists run off the bottom of the screen as one column, so
            -- split them evenly across two once past ~one screen's worth.
            local single_column_max = 18
            if #rids > single_column_max then
                local col_rows = math.ceil(#rids / 2)
                imgui.BeginGroup()
                render_status_rows(1, col_rows)
                imgui.EndGroup()
                imgui.SameLine(0, 20)
                imgui.BeginGroup()
                render_status_rows(col_rows + 1, #rids)
                imgui.EndGroup()
            else
                render_status_rows(1, #rids)
            end
        end
        ui_components.end_opaque_popup()
    end
end

-- Text color for a target button's per-target Combat/Idle override, or nil
-- when the target has no override (inherits the ability's own gate).
local function target_gate_color(ctx, config_key, target_index)
    local override = ctx.party_buff_gates and config_key
        and common.target_gate_override(config_key, target_index, ctx.party_buff_gates)
    if override == 'combat' then return LIGHT_YELLOW end
    if override == 'idle' then return LIGHT_GREEN end
    return nil
end

-- Tooltip suffix for a button tinted by target_gate_color, or '' when untinted.
local function gate_tooltip_suffix(gate_color)
    if gate_color == LIGHT_YELLOW then return '\n(Combat Only override)' end
    if gate_color == LIGHT_GREEN then return '\n(Idle Only override)' end
    return ''
end

-- Right-click 'Combat Only' / 'Idle Only' popup for a single target button
-- (ME/P1-P5, alliance B0-C5, tracked T1..).
-- Session-only (never written to settings) and REPLACES the ability's own
-- combat_only/idle_only gate for this one target -- see common.target_gate_ok.
-- Buff abilities only (id_suffix == 'buff'): debuff-removal's na-spell buttons
-- have no automation wired to read this, so showing the menu there would be
-- inert and misleading. Also suppressed wherever the ability-level toggle is
-- (bt / statically idle_only / statically combat_only), same rule as
-- render_combat_only_context_menu, so an override can't fight a hard gate.
local function render_target_gate_context_menu(ctx, ability, config_key, target_index, id_suffix)
    if id_suffix ~= 'buff' then return end
    if not ctx or not ability or not config_key then return end
    if ability.idle_only or ability.combat_only or common.ability_targets_bt(ability) then return end
    local popup_id = '##cmenu_target_gate_' .. config_key:gsub(' ', '_') .. '_' .. tostring(target_index)
    if ui_components.begin_opaque_context_item(popup_id) then
        ctx.party_buff_gates = ctx.party_buff_gates or {}
        ctx.party_buff_gates[config_key] = ctx.party_buff_gates[config_key] or {}
        local gates = ctx.party_buff_gates[config_key]

        local combat_cur = { gates[target_index] == 'combat' }
        if imgui.Checkbox('Combat Only', combat_cur) then
            gates[target_index] = combat_cur[1] and 'combat' or nil
        end
        local idle_cur = { gates[target_index] == 'idle' }
        if imgui.Checkbox('Idle Only', idle_cur) then
            gates[target_index] = idle_cur[1] and 'idle' or nil
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Override for this target only (this session).\nReplaces the ability\'s own Combat/Idle setting.')
        end
        ui_components.end_opaque_popup()
    end
end

-- Default filter functions (can be overridden via ctx.filter_func)
local default_filters = {}

-- Check if player can use an ability based on level
function default_filters.can_use_ability(ability)
    if not ability or not ability.level then
        return true
    end
    
    -- Check if ability requires main job only (e.g., Geo spells)
    if ability.main_job_only and ability.is_main_job == false then
        return false
    end
    
    local main_level, sub_level = common.get_player_level()
    
    -- Check if this ability is for main job or subjob
    if ability.is_main_job == false then
        return sub_level >= ability.level
    else
        return main_level >= ability.level
    end
end

-- Get filter functions from context or use defaults
local function get_filters(ctx)
    if ctx and ctx.filter_func then
        return ctx.filter_func
    end
    return default_filters
end

-- Get all abilities in the same group
local function get_abilities_in_group(job_def, target_group)
    local group_abilities = {}
    if not job_def or not target_group then
        return group_abilities
    end
    
    if job_def.abilities then
        for category, abilities in pairs(job_def.abilities) do
            for _, ability in ipairs(abilities) do
                if ability.group == target_group then
                    table.insert(group_abilities, ability)
                end
            end
        end
    end
    
    return group_abilities
end

-- Get usable abilities in a group (level-appropriate and spell learned)
local function get_usable_abilities_in_group(job_def, target_group, ctx)
    local all_abilities = get_abilities_in_group(job_def, target_group)
    local usable = {}
    local filters = get_filters(ctx)
    
    for _, ability in ipairs(all_abilities) do
        local can_use = filters.can_use_ability(ability)
        
        if can_use then
            if common.has_spell_learned(ability) then
                table.insert(usable, ability)
            end
        end
    end
    
    return usable
end

-- Get the highest level usable ability in a group
local function get_highest_level_ability_in_group(job_def, target_group, ctx)
    local usable = get_usable_abilities_in_group(job_def, target_group, ctx)
    if #usable == 0 then
        return nil
    end
    
    table.sort(usable, function(a, b) return a.level > b.level end)
    return usable[1]
end

-- Get selected ability for a group (from settings, or auto-select highest)
local function get_selected_ability_for_group(ctx, job_def, target_group)
    if not ctx.settings or not job_def or not target_group then
        return nil
    end
    
    local setting_key = 'selected_' .. target_group
    local saved_name = ctx.settings[setting_key]
    
    local usable = get_usable_abilities_in_group(job_def, target_group, ctx)
    if #usable == 0 then
        return nil
    end
    
    -- Check if saved ability is still usable
    if saved_name then
        for _, ability in ipairs(usable) do
            if ability.name == saved_name then
                return ability
            end
        end
    end
    
    -- Auto-select highest level
    local highest = get_highest_level_ability_in_group(job_def, target_group, ctx)
    if highest then
        ctx.settings[setting_key] = highest.name
        if ctx.save_callback then
            ctx.save_callback()
        end
    end
    
    return highest
end

-- Check if an ability is a duplicate from subjob
local function is_subjob_duplicate(job_def, ability, ctx)
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

-- Check if ability can be cast on party members
local function can_cast_on_party(ability)
    return type(ability.command) == 'function'
end

-- Check if a group is enabled
local function is_group_enabled(ctx, group_name)
    if not ctx.settings then
        return false
    end
    
    local key = 'disabled_group_' .. group_name
    
    if ctx.settings[key] == nil then
        return true  -- Default to enabled when not in settings
    end
    
    return not ctx.settings[key]
end

-- Toggle group enabled state
local function toggle_group(ctx, group_name, enabled)
    local key = 'disabled_group_' .. group_name
    ctx.settings[key] = not enabled
    
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- Check if an ability is enabled (for non-grouped abilities)
local function is_ability_enabled(ctx, ability_name)
    if not ctx.settings then
        return false
    end
    
    local key = 'disabled_' .. ability_name:gsub(' ', '_')
    
    if ctx.settings[key] == nil then
        return true  -- Default to enabled when not in settings
    end
    
    return not ctx.settings[key]
end

-- Toggle ability enabled state (for non-grouped abilities)
local function toggle_ability(ctx, ability_name, enabled, job_def)
    local key = 'disabled_' .. ability_name:gsub(' ', '_')
    ctx.settings[key] = not enabled
    
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- Find an ability by name in job definition
local function find_ability_by_name(job_def, ability_name)
    if not job_def or not job_def.abilities then
        return nil
    end
    
    for category, abilities in pairs(job_def.abilities) do
        if type(abilities) == 'table' then
            for _, ability in ipairs(abilities) do
                if ability.name == ability_name then
                    return ability
                end
            end
        end
    end

    return nil
end

-- Is this party_buffs key a song? The key is a group name (grouped songs) OR an
-- ability name (ungrouped songs), so the song-limit count must recognize both --
-- otherwise grouped and ungrouped songs keep separate tallies.
local function is_song_config_key(job_def, key)
    local group_abilities = get_abilities_in_group(job_def, key)
    if #group_abilities > 0 then
        return group_abilities[1].magic == 'song'
    end
    local ability = find_ability_by_name(job_def, key)
    return ability ~= nil and ability.magic == 'song'
end

-- Check if a group buff is enabled for a specific party member
local function is_group_party_buff_enabled(ctx, group_name, party_index)
    if not ctx.party_buffs[group_name] then
        return false
    end
    return ctx.party_buffs[group_name][party_index] == true
end

-- Check if a buff is enabled for a specific party member (non-grouped abilities)
local function is_party_buff_enabled(ctx, ability_name, party_index)
    if not ctx.party_buffs[ability_name] then
        return false
    end
    return ctx.party_buffs[ability_name][party_index] == true
end

-- Party-buff target keys that must persist to disk. Numeric ME/P1-P5 (0-5) and
-- the bard area key 'A' are stable config; alliance ('al_')/tracked ('tt_') keys
-- are session-only because those members come and go.
local function is_persisted_target_key(k)
    return (type(k) == 'number' and k <= 5) or k == 'A'
end

-- Toggle group buff enabled state for a specific party member
local function toggle_group_party_buff(ctx, group_name, party_index, enabled)
    if not ctx.party_buffs[group_name] then
        ctx.party_buffs[group_name] = {}
    end
    
    -- Check if this is a song group that counts toward the limit
    if enabled then
        -- Get any ability from this group to check target_modifier
        local group_abilities = get_abilities_in_group(ctx.job_def, group_name)
        if #group_abilities > 0 then
            local sample_ability = group_abilities[1]
            
            if sample_ability.magic == 'song' then
                -- Determine the limit based on main/sub job
                local is_main_job = sample_ability.is_main_job ~= false
                local song_limit = is_main_job and 2 or 1

                -- Count currently enabled song groups for this party member. Every
                -- song occupies a slot (incl. Mazurka, which has no Pianissimo), so
                -- the predicate is magic=='song', not target_modifier.
                local active_song_groups = {}
                for other_group_name, targets in pairs(ctx.party_buffs) do
                    if other_group_name ~= group_name and targets[party_index] == true then
                        if is_song_config_key(ctx.job_def, other_group_name) then
                            table.insert(active_song_groups, other_group_name)
                        end
                    end
                end
                
                -- If at or over limit, deselect one existing song group for this party member
                if #active_song_groups >= song_limit then
                    local group_to_remove = active_song_groups[1]
                    ctx.party_buffs[group_to_remove][party_index] = false
                    
                    -- Ensure persistence structure exists (skip tracked targets)
                    if is_persisted_target_key(party_index) then
                        ctx.settings.party_buffs = ctx.settings.party_buffs or {}
                        ctx.settings.party_buffs[group_to_remove] = ctx.settings.party_buffs[group_to_remove] or {}
                        ctx.settings.party_buffs[group_to_remove][party_index] = false
                    end
                    
                    -- Check if removed group is still enabled for any member
                    local removed_still_enabled = false
                    for k, v in pairs(ctx.party_buffs[group_to_remove]) do
                        if v == true then
                            removed_still_enabled = true
                            break
                        end
                    end
                    
                    -- Update disabled setting for removed group
                    if not removed_still_enabled then
                        ctx.settings['disabled_group_' .. group_to_remove] = true
                    end
                end
            end
        end
    end
    
    -- Exclusive single-target groups (e.g. Geo): only one target at a time.
    -- Geo creates a single luopan, so selecting a target deselects the others.
    if enabled then
        local group_abilities = get_abilities_in_group(ctx.job_def, group_name)
        if #group_abilities > 0 and group_abilities[1].exclusive_target then
            for other_index, val in pairs(ctx.party_buffs[group_name]) do
                if other_index ~= party_index and val == true then
                    ctx.party_buffs[group_name][other_index] = false
                    if is_persisted_target_key(other_index) then
                        ctx.settings.party_buffs = ctx.settings.party_buffs or {}
                        ctx.settings.party_buffs[group_name] = ctx.settings.party_buffs[group_name] or {}
                        ctx.settings.party_buffs[group_name][other_index] = false
                    end
                end
            end
        end
    end

    -- Set the new buff state
    ctx.party_buffs[group_name][party_index] = enabled

    -- Check if ANY button is enabled for this group
    local any_button_enabled = false
    for k, v in pairs(ctx.party_buffs[group_name]) do
        if v == true then
            any_button_enabled = true
            break
        end
    end
    
    -- Update the group's disabled setting
    ctx.settings['disabled_group_' .. group_name] = not any_button_enabled
    
    -- Save party_buffs to settings for persistence (skip tracked targets)
    if is_persisted_target_key(party_index) then
        ctx.settings.party_buffs = ctx.settings.party_buffs or {}
        ctx.settings.party_buffs[group_name] = ctx.settings.party_buffs[group_name] or {}
        ctx.settings.party_buffs[group_name][party_index] = enabled
    end
    
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- Toggle buff enabled state for a specific party member (non-grouped abilities)
local function toggle_party_buff(ctx, ability_name, party_index, enabled)
    if not ctx.party_buffs[ability_name] then
        ctx.party_buffs[ability_name] = {}
    end
    
    -- Check if this is a song that counts toward the limit
    if enabled then
        local ability = find_ability_by_name(ctx.job_def, ability_name)
        
        if ability and ability.magic == 'song' then
            -- Determine the limit based on main/sub job
            local is_main_job = ability.is_main_job ~= false
            local song_limit = is_main_job and 2 or 1

            -- Count currently enabled songs for this party member. Every song
            -- occupies a slot (incl. Mazurka, no Pianissimo), so match magic=='song'.
            local active_songs = {}
            for other_ability_name, targets in pairs(ctx.party_buffs) do
                if other_ability_name ~= ability_name and targets[party_index] == true then
                    if is_song_config_key(ctx.job_def, other_ability_name) then
                        table.insert(active_songs, other_ability_name)
                    end
                end
            end
            
            -- If at or over limit, deselect one existing song for this party member
            if #active_songs >= song_limit then
                local song_to_remove = active_songs[1]  -- Remove first found (random due to table iteration)
                ctx.party_buffs[song_to_remove][party_index] = false
                
                -- Ensure persistence structure exists (skip tracked targets)
                if is_persisted_target_key(party_index) then
                    ctx.settings.party_buffs = ctx.settings.party_buffs or {}
                    ctx.settings.party_buffs[song_to_remove] = ctx.settings.party_buffs[song_to_remove] or {}
                    ctx.settings.party_buffs[song_to_remove][party_index] = false
                end
                
                -- Check if removed song is still enabled for any member
                local removed_still_enabled = false
                for k, v in pairs(ctx.party_buffs[song_to_remove]) do
                    if v == true then
                        removed_still_enabled = true
                        break
                    end
                end
                
                -- Update disabled setting for removed song
                local removed_key = 'disabled_' .. song_to_remove:gsub(' ', '_')
                if not removed_still_enabled then
                    ctx.settings[removed_key] = true
                end
            end
        end
    end
    
    -- Set the new buff state
    ctx.party_buffs[ability_name][party_index] = enabled
    
    -- Check if ANY button is enabled
    local any_button_enabled = false
    for k, v in pairs(ctx.party_buffs[ability_name]) do
        if v == true then
            any_button_enabled = true
            break
        end
    end
    
    -- Update the ability's disabled setting
    local key = 'disabled_' .. ability_name:gsub(' ', '_')
    if any_button_enabled then
        ctx.settings[key] = false
    else
        ctx.settings[key] = true
    end
    
    -- Save party_buffs to settings for persistence (skip tracked targets)
    if is_persisted_target_key(party_index) then
        if not ctx.settings.party_buffs then
            ctx.settings.party_buffs = {}
        end
        if not ctx.settings.party_buffs[ability_name] then
            ctx.settings.party_buffs[ability_name] = {}
        end
        ctx.settings.party_buffs[ability_name][party_index] = enabled
    end
    
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- Deselect songs the player can't currently sing, across ALL target slots
-- (A / ME / P1-P5 / tracked). Call on render: after a level-sync down a bard
-- keeps higher-level songs selected but can't cast them, which fills the 2-song
-- limit and blocks picking castable songs. Dropping them frees the slots (they
-- must be re-selected on level-up). Songs are the only selection that needs
-- this -- everything else (general buffs, stratagem/Diffusion/Nether Void
-- assignments) has no slot limit, so an out-of-range pick simply lies dormant
-- and switches back on when the player levels up. Saves once if anything changed.
function ui_components.disable_uncastable_songs(ctx)
    if not ctx or not ctx.job_def or not ctx.party_buffs then return end
    local filters = get_filters(ctx)
    local changed = false
    for key, targets in pairs(ctx.party_buffs) do
        if is_song_config_key(ctx.job_def, key) then
            local grouped = #get_abilities_in_group(ctx.job_def, key) > 0
            local usable
            if grouped then
                usable = #get_usable_abilities_in_group(ctx.job_def, key, ctx) > 0
            else
                local ability = find_ability_by_name(ctx.job_def, key)
                usable = ability ~= nil and filters.can_use_ability(ability)
                    and common.has_spell_learned(ability)
            end
            if not usable then
                local was_on = false
                for party_index, enabled in pairs(targets) do
                    if enabled == true then
                        was_on = true
                        targets[party_index] = false
                        if is_persisted_target_key(party_index) then
                            ctx.settings.party_buffs = ctx.settings.party_buffs or {}
                            ctx.settings.party_buffs[key] = ctx.settings.party_buffs[key] or {}
                            ctx.settings.party_buffs[key][party_index] = false
                        end
                    end
                end
                if was_on then
                    if grouped then
                        ctx.settings['disabled_group_' .. key] = true
                    else
                        ctx.settings['disabled_' .. tostring(key):gsub(' ', '_')] = true
                    end
                    changed = true
                end
            end
        end
    end
    if changed and ctx.save_callback then
        ctx.save_callback()
    end
end

-- Calculate the width for the ON/OFF button based on party size + alliance + tracked targets
local function get_onoff_button_width()
    local party_size = common.get_party_size()
    local alliance_count = common.get_alliance_count()
    local tracked_count = 0
    local tt_list = common.get_tracked_targets()
    for _ in pairs(tt_list) do tracked_count = tracked_count + 1 end
    local num_buttons = math.min(party_size, 6) + alliance_count + tracked_count
    return PARTY_BUTTON_WIDTH * num_buttons + (SPACE_BETWEEN_BUTTONS * (num_buttons - 1))
end

-- ============================================================================
-- Scholar Stratagem Button
-- ============================================================================

-- Helper: get the stratagem_settings table from ctx, creating it if needed
local function get_stratagem_settings(ctx)
    if not ctx or not ctx.settings then return nil end
    if not ctx.settings.stratagem_settings then
        ctx.settings.stratagem_settings = {}
    end
    return ctx.settings.stratagem_settings
end

-- Helper: get the stratagem_hold table from ctx, creating it if needed
-- stratagem_hold[ability_key] = true means "skip the spell until the stratagem is ready"
local function get_stratagem_hold(ctx)
    if not ctx or not ctx.settings then return nil end
    if not ctx.settings.stratagem_hold then
        ctx.settings.stratagem_hold = {}
    end
    return ctx.settings.stratagem_hold
end

-- Helper: check whether any of `available` is assigned to an ability key in settings.
-- Recast-gated JAs (RUN Embolden, DRK Nether Void, BLU Diffusion) share this
-- per-ability table with the scholar stratagems, so match only the names the caller
-- offers -- otherwise one button's assignment lights another.
local function has_any_stratagem(ctx, ability_key, available)
    local ss = ctx and ctx.settings and ctx.settings.stratagem_settings
    local assigned = ss and ss[ability_key]
    if not assigned then return false end
    for _, strat in ipairs(available) do
        if assigned[strat.name] then return true end
    end
    return false
end

-- Filter stratagems from job_def that apply to a given ability at the given level
local function get_available_stratagems(job_def, sch_level, ability)
    if not job_def or not job_def.abilities or not job_def.abilities.precast then
        return {}
    end
    local available = {}
    for _, strat in ipairs(job_def.abilities.precast) do
        -- Recast-gated strats (DRK Nether Void) have their own N button; never
        -- offer them in the Scholar S popup (e.g. on SCH main / DRK sub).
        -- stratagem_magic_matches is the colour/magic_type gate (shared with
        -- effective_ability_cost); stratagem_applies is Accession's spell_ids
        -- allowlist -- never offer it on a Raise, a Reraise, Haste or anything
        -- else the server won't extend.
        if not strat.recast_gate and strat.level and sch_level >= strat.level
            and common.stratagem_magic_matches(strat, ability)
            and common.stratagem_applies(strat, ability) then
            table.insert(available, strat)
        end
    end
    return available
end

-- Render the Scholar stratagem selector button for a single ability row.
-- ability_key: unique string key for the ability (e.g. ability name or group name)
-- ability: (optional) the ability table; when provided, only /ma commands get the button
-- ctx: (optional) UI context with settings and save_callback for persistence
-- Returns: consumed (bool) -- true when this drew a leading element (the S button
--   OR an alignment spacer), false when it drew nothing. The caller uses this to
--   avoid stacking a second indent (e.g. the bard [A] column) on the same row.
local function render_scholar_stratagem_button(ability_key, ability, ctx)
    -- Resolve Scholar level from main or sub job (SCH = job ID 20)
    local main_job_id, sub_job_id = common.get_player_job()
    local main_level, sub_level   = common.get_player_level()

    local sch_level = 0
    if main_job_id == 20 then
        sch_level = main_level
    elseif sub_job_id == 20 then
        sch_level = sub_level
    end

    if sch_level < 10 then
        return false, 0
    end

    -- Check if player is in any arts stance (required for stratagems)
    local in_light = common.has_buff(0, 358) or common.has_buff(0, 401)
    local in_dark  = common.has_buff(0, 359) or common.has_buff(0, 402)
    local in_arts  = in_light or in_dark

    -- No arts active → no S button or spacer on any row
    if not in_arts then
        return false, 0
    end

    -- Only magic (/ma) commands can use stratagems; skip job abilities (/ja)
    if ability and type(ability.command) == 'string' and ability.command:sub(1, 3) == '/ja' then
        imgui.Dummy({ 20, 0 })
        imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
        return true, 0
    end

    -- Geo-bt debuffs render in the Geo section, which has no S-button rows to
    -- align with, so skip the spacer to avoid an unwanted indent. Indi/Geo buffs
    -- still fall through to the spacer below to align with buff-section rows.
    if ability and ability.group == 'Geo-bt' then
        return false, 0
    end

    -- Bard songs get the area [A] button in the leading slot (drawn by
    -- render_party_buttons), so it already provides the indent. Adding a
    -- stratagem spacer here too would double-indent the row. Either the [A]
    -- button or the S button triggers the indent, never both.
    if ability and ability.magic == 'song' then
        return false, 0
    end

    -- Stratagems only apply to white/black magic; skip singing, geomancy, etc.
    -- Render an invisible spacer so these rows stay aligned with S-button rows.
    if ability and ability.magic then
        if ability.magic ~= 'white' and ability.magic ~= 'black' then
            imgui.Dummy({ 20, 0 })
            imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
            return true, 0
        end
    end

    -- Check arts stance: Light Arts → white only, Dark Arts → black only
    -- Wrong-stance spells get an invisible spacer to stay aligned with S-button rows
    if ability and ability.magic then
        if (ability.magic == 'white' and not in_light) or (ability.magic == 'black' and not in_dark) then
            imgui.Dummy({ 20, 0 })
            imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
            return true, 0
        end
    end

    -- Get job_def from ctx for stratagem definitions
    local job_def = ctx and ctx.job_def
    local available = get_available_stratagems(job_def, sch_level, ability)

    if #available == 0 then
        return false, 0
    end

    local has_sel  = has_any_stratagem(ctx, ability_key, available)
    local popup_id = '##sch_strat_popup_' .. ability_key

    -- Color: default (active) when a stratagem is chosen, gray when idle
    if not has_sel then
        imgui.PushStyleColor(ImGuiCol_Button,        COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  COLOR_BUTTON_UNSELECTED_ACTIVE)
    end

    if imgui.Button('S##sch_' .. ability_key, { 20, 0 }) then
        imgui.OpenPopup(popup_id)
    end

    if imgui.IsItemHovered() then
        ui_components.set_tooltip('Scholar Stratagem: apply a stratagem to this spell to\n' ..
            'reduce MP cost or boost its effect. Click to choose which\n' ..
            'stratagems to spend. Lit when one is assigned.')
    end

    if not has_sel then
        imgui.PopStyleColor(3)
    end

    if ui_components.begin_opaque_popup(popup_id) then
        imgui.TextColored({ 0.8, 0.8, 0.8, 1.0 }, 'Scholar Stratagem')
        imgui.Separator()

        -- Ensure settings table exists
        local ss = get_stratagem_settings(ctx)
        if ss then
            if not ss[ability_key] then
                ss[ability_key] = {}
            end

            for _, strat in ipairs(available) do
                local is_checked = ss[ability_key] and ss[ability_key][strat.name] == true
                local label = strat.name
                -- Show MP modifier info in label
                if strat.mp_modifier then
                    if strat.mp_modifier < 1.0 then
                        label = label .. '  (-' .. math.floor((1.0 - strat.mp_modifier) * 100) .. '% MP)'
                    else
                        label = label .. '  (+' .. math.floor((strat.mp_modifier - 1.0) * 100) .. '% MP)'
                    end
                end

                local cb_val = { is_checked }
                if imgui.Checkbox(label .. '##sch_opt_' .. strat.name .. '_' .. ability_key, cb_val) then
                    if not ss[ability_key] then
                        ss[ability_key] = {}
                    end
                    if cb_val[1] then
                        ss[ability_key][strat.name] = true
                    else
                        ss[ability_key][strat.name] = nil
                    end
                    if ctx.save_callback then
                        ctx.save_callback()
                    end
                end
            end

            -- Clean up empty tables after the loop
            if ss[ability_key] and not next(ss[ability_key]) then
                ss[ability_key] = nil
                if ctx.save_callback then
                    ctx.save_callback()
                end
            end
        end

        -- "Hold for Stratagem": gate casting on the stratagem being ready.
        imgui.Separator()
        local hold_tbl = get_stratagem_hold(ctx)
        if hold_tbl then
            local hold_val = { hold_tbl[ability_key] == true }
            if imgui.Checkbox('Hold for Stratagem##sch_hold_' .. ability_key, hold_val) then
                hold_tbl[ability_key] = hold_val[1] or nil
                if ctx.save_callback then
                    ctx.save_callback()
                end
            end
            if imgui.IsItemHovered() then
                ui_components.set_tooltip('On: skip this spell until the stratagem is ready.\n' ..
                    'Off (default): cast the spell without the stratagem when it is on cooldown.')
            end
        end

        ui_components.end_opaque_popup()
    end

    imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
    return true, 0
end

-- Resolve the recast-gated stratagem owning a given button column (the job data names
-- it: `column = 'embolden'`), if the player can use it: right level, never offered from
-- a subjob when main_job_only. Level-gated the same way filter_abilities_by_level
-- would be. Non-nil means that button column is on-screen, so every buff row needs its
-- leading indent (the button itself renders disabled while unlearned, so learned state
-- doesn't matter for alignment).
local function recast_gate_column_strat(ctx, column)
    local job_def    = ctx and ctx.job_def
    local strat_defs = job_def and job_def.abilities and job_def.abilities.precast
    if not strat_defs then return nil end
    local main_level, sub_level = common.get_player_level()
    for _, s in ipairs(strat_defs) do
        if s.recast_gate and s.column == column then
            local from_sub = s.is_main_job == false
            local level = from_sub and (sub_level or 0) or (main_level or 0)
            if not (s.main_job_only and from_sub) and level >= (s.level or 0) then
                return s
            end
            return nil
        end
    end
    return nil
end

local function nether_void_column_strat(ctx)
    return recast_gate_column_strat(ctx, 'nether_void')
end

local function diffusion_column_strat(ctx)
    return recast_gate_column_strat(ctx, 'diffusion')
end

local function embolden_column_strat(ctx)
    return recast_gate_column_strat(ctx, 'embolden')
end

-- SCH Enlightenment column, live only in Dark Arts / Addendum: Black -- the one stance
-- where an Addendum: White spell needs it. Off-stance the column collapses entirely.
local function enlightenment_column_strat(ctx)
    if not (common.has_buff(0, 359) or common.has_buff(0, 402)) then return nil end
    return recast_gate_column_strat(ctx, 'enlightenment')
end

-- Set or clear one strat assignment on an ability row, dropping the row's table once
-- its last assignment is gone (check_stratagem treats an empty table as an assignment).
local function set_strat_assigned(ss, ability_key, strat_name, on)
    if on then
        ss[ability_key] = ss[ability_key] or {}
        ss[ability_key][strat_name] = true
    elseif ss[ability_key] then
        ss[ability_key][strat_name] = nil
        if not next(ss[ability_key]) then ss[ability_key] = nil end
    end
end

-- Shared body for the recast-gated strat buttons (DRK [N], BLU [D], SCH [E]):
-- a one-letter button opening a popup with Enable (fire the JA before the
-- paired ability, via the stratagem machinery) and Hold (skip the ability
-- until the JA is ready; off = fire the ability without it when it's on
-- cooldown). Renders disabled (Not Learned) until the merit is unlocked.
-- Lit when enabled. Returns true when it drew the button (fills the row's
-- leading slot).
-- Passing no hold_tip drops the popup and makes the button a plain on/off toggle
-- (SCH Enlightenment): Hold is implicit for a JA its ability cannot be used without,
-- leaving Enable as the popup's only choice.
-- Widget ids key on strat.name, which is unique; `letter` is a display choice and is
-- not (Embolden and Enlightenment are both [E], and two on one row would silently
-- merge into one control).
local function render_recast_gate_button(ability_key, ctx, strat, letter, button_tip, enable_tip, hold_tip)
    local btn_id = letter .. '##rg_' .. strat.name .. '_' .. ability_key

    -- Merit JA not unlocked yet: draw the button disabled (like an unlearned
    -- spell row) -- grayed, click-locked, "Not Learned" tooltip. Any config
    -- left from when the merit was owned is cleared here, since the disabled
    -- button offers no popup to turn it off -- a stale Hold would otherwise
    -- make check_stratagem skip the paired ability forever.
    if not common.has_spell_learned(strat) then
        local ss = get_stratagem_settings(ctx)
        if ss and ss[ability_key] and ss[ability_key][strat.name] then
            ss[ability_key][strat.name] = nil
            if not next(ss[ability_key]) then
                ss[ability_key] = nil
                local hold_tbl = ctx.settings and ctx.settings.stratagem_hold
                if hold_tbl then hold_tbl[ability_key] = nil end
            end
            if ctx.save_callback then ctx.save_callback() end
        end
        imgui.PushStyleColor(ImGuiCol_Button,        COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  COLOR_BUTTON_DISABLED)
        imgui.Button(btn_id, { 20, 0 })
        imgui.PopStyleColor(3)
        if imgui.IsItemHovered() then
            ui_components.set_tooltip(strat.name .. ' Not Learned')
        end
        imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
        return true
    end

    local ss = get_stratagem_settings(ctx)
    if not ss then return false end
    local assigned = ss[ability_key] and ss[ability_key][strat.name] == true
    local popup_id = '##rg_popup_' .. strat.name .. '_' .. ability_key

    -- Color: default (active) when enabled, gray when idle -- same as S button
    if not assigned then
        imgui.PushStyleColor(ImGuiCol_Button,        COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  COLOR_BUTTON_UNSELECTED_ACTIVE)
    end

    if imgui.Button(btn_id, { 20, 0 }) then
        if hold_tip then
            imgui.OpenPopup(popup_id)
        else
            set_strat_assigned(ss, ability_key, strat.name, not assigned)
            if ctx.save_callback then ctx.save_callback() end
        end
    end

    if imgui.IsItemHovered() then
        ui_components.set_tooltip(button_tip)
    end

    if not assigned then
        imgui.PopStyleColor(3)
    end

    if hold_tip and ui_components.begin_opaque_popup(popup_id) then
        imgui.TextColored({ 0.8, 0.8, 0.8, 1.0 }, strat.name)
        imgui.Separator()

        local enable_val = { assigned }
        if imgui.Checkbox('Enable##rg_enable_' .. letter .. '_' .. ability_key, enable_val) then
            set_strat_assigned(ss, ability_key, strat.name, enable_val[1])
            if ctx.save_callback then ctx.save_callback() end
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip(enable_tip)
        end

        -- "Hold for ...": stored under the same stratagem_hold key
        -- check_stratagem reads, so the automation side needs no new wiring.
        imgui.Separator()
        local hold_tbl = get_stratagem_hold(ctx)
        if hold_tbl then
            local hold_val = { hold_tbl[ability_key] == true }
            if imgui.Checkbox('Hold for ' .. strat.name .. '##rg_hold_' .. letter .. '_' .. ability_key, hold_val) then
                hold_tbl[ability_key] = hold_val[1] or nil
                if ctx.save_callback then ctx.save_callback() end
            end
            if imgui.IsItemHovered() then
                ui_components.set_tooltip(hold_tip)
            end
        end

        ui_components.end_opaque_popup()
    end

    imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
    return true
end

-- DRK Nether Void [N] button. Shows on the Absorb group row (buff section) and
-- on Drain/Drain II/Aspir rows (heal/recover sections, flagged nether_void).
local function render_nether_void_button(ability_key, ability, ctx)
    if not (ability and (ability.group == 'absorb' or ability.nether_void)) then return false end
    local strat = nether_void_column_strat(ctx)
    if not strat then return false end
    local noun = ability.group == 'absorb' and 'Absorb spell' or 'spell'
    return render_recast_gate_button(ability_key, ctx, strat, 'N',
        string.format(tooltips.nether_void_button, noun),
        string.format(tooltips.nether_void_enable, noun),
        string.format(tooltips.nether_void_hold, noun, noun))
end

-- BLU Diffusion [D] button on every blue magic buff row: fire Diffusion
-- before the buff so it spreads to the whole party instead of self only.
-- Rows flagged no_diffusion (Diamondhide -- already AOE) skip the button
-- and fall through to the alignment spacer.
local function render_diffusion_button(ability_key, ability, ctx)
    if not (ability and ability.magic == 'blue') or ability.no_diffusion then return false end
    local strat = diffusion_column_strat(ctx)
    if not strat then return false end
    return render_recast_gate_button(ability_key, ctx, strat, 'D',
        tooltips.diffusion_button, tooltips.diffusion_enable, tooltips.diffusion_hold)
end

-- RUN Embolden [E] button on every white enhancing magic row: fire Embolden before the
-- spell to boost its potency. Both keys are needed -- magic_type keeps it off white
-- non-enhancing rows, magic off the black-magic spikes (also magic_type 'enhancing').
local function render_embolden_button(ability_key, ability, ctx)
    if not (ability and ability.magic == 'white' and ability.magic_type == 'enhancing') then return false end
    local strat = embolden_column_strat(ctx)
    if not strat then return false end
    return render_recast_gate_button(ability_key, ctx, strat, 'E',
        tooltips.embolden_button, tooltips.embolden_enable, tooltips.embolden_hold)
end

-- SCH Enlightenment [E] button on the rows Addendum: White gates, shown only in Dark
-- Arts -- the stance that locks them out. No popup (no hold_tip): Hold is implicit for
-- a spell that cannot be cast without the JA, leaving nothing to configure.
local function render_enlightenment_button(ability_key, ability, ctx)
    local strat = enlightenment_column_strat(ctx)
    if not strat then return false end
    -- Same rule precast_satisfies_prereq uses: the row is one this JA's buff unlocks,
    -- spelled out in the job data as requires_buff = {401, 416}. Rows gated on an arts
    -- stance instead ({358, 401}, e.g. Tranquility) carry no 416 and get no button --
    -- Enlightenment frees the next spell from the addenda, it does not change stance.
    if not action_core.has_any_buff({ strat.buff_id }, ability and ability.requires_buff) then
        return false
    end
    return render_recast_gate_button(ability_key, ctx, strat, 'E', tooltips.enlightenment_button)
end

-- One button-width spacer, keeping a row aligned under a column whose button it lacks.
local function render_slot_spacer()
    imgui.Dummy({ 20, 0 })
    imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
end

-- A recast-gate button gets its own column ONLY when a real S button could land on the
-- same row; otherwise it takes the scholar slot and the job stays one column wide.
--
-- S only draws a real button on a /ma row whose magic colour matches the arts stance,
-- so contention comes down to the rows each button appears on: Nether Void's Absorb
-- rows have no magic colour and Diffusion's are blue, so S never draws on either;
-- Enlightenment is Dark-Arts-only, where its white rows are wrong-stance. That leaves
-- Embolden's white enhancing rows in Light Arts as the one case needing a second
-- column. Per-stance, not per-row: every row in a section must agree on the column
-- count or they stop lining up.
local function embolden_needs_own_column(ctx)
    local in_dark_arts = common.has_buff(0, 359) or common.has_buff(0, 402)
    return not in_dark_arts and embolden_column_strat(ctx) ~= nil
end

-- True when the S button would put a REAL button on this row, i.e. the row is the
-- current stance's colour. Only then does it need the scholar slot -- on every other
-- row it draws an alignment spacer a recast-gate button can replace.
--
-- A safety net, not the mechanism: embolden_needs_own_column already assumes N/D never
-- land on a stance-coloured row. If that stops holding, this keeps the S button and
-- drops the N/D one rather than breaking the sharing scheme.
local function scholar_claims_row(ability)
    if not ability then return false end
    if ability.magic == 'white' then
        return common.has_buff(0, 358) or common.has_buff(0, 401)
    elseif ability.magic == 'black' then
        return common.has_buff(0, 359) or common.has_buff(0, 402)
    end
    return false
end

-- Draw a row's leading slot. Normally one column wide -- the scholar column, shared by
-- whichever of the S / N / D / E buttons this row and stance call for (see
-- embolden_needs_own_column). RUN/SCH in Light Arts is the sole two-column case: the
-- row reads [E][S] on an enhancing row, [ ][S] on a Cure row.
--
-- A column collapses entirely when its job isn't in play; a row that misses one gets a
-- spacer instead so rows stay aligned. Song rows are the exception -- no column applies
-- to them and render_party_buttons draws the [A] button in this slot.
local function render_leading_slot(ability_key, ability, ctx)
    if ability and ability.magic == 'song' then return end

    -- Geo-bt debuffs sit in their own section, with no button columns to align with.
    local no_spacer = ability and ability.group == 'Geo-bt'
    local own_column = embolden_needs_own_column(ctx)

    -- Column 1: Embolden's own column, live in Light Arts only.
    local drew = false
    if own_column then
        drew = render_embolden_button(ability_key, ability, ctx)
        if not drew and not no_spacer then
            render_slot_spacer()
            drew = true
        end
    end

    -- The scholar column: at most one of these applies to any given row/job, and the
    -- S button (or its own alignment spacer) takes the slot when none do.
    if render_enlightenment_button(ability_key, ability, ctx) then return end
    if not scholar_claims_row(ability) then
        if not own_column and render_embolden_button(ability_key, ability, ctx) then return end
        if render_nether_void_button(ability_key, ability, ctx) then return end
        if render_diffusion_button(ability_key, ability, ctx) then return end
    end
    if render_scholar_stratagem_button(ability_key, ability, ctx) then return end

    -- Nothing drew in the scholar column: the S button declined the row outright (no
    -- SCH, no arts stance, or no stratagem matches) rather than spacering it. A live
    -- shared column, or a bard [A] column, still needs this row indented.
    local has_songs = ctx and ctx.job_def and ctx.job_def.has_songs
    if not drew and not no_spacer
        and (has_songs
            or nether_void_column_strat(ctx) or diffusion_column_strat(ctx)
            or enlightenment_column_strat(ctx)
            or (not own_column and embolden_column_strat(ctx))) then
        render_slot_spacer()
    end
end

-- ============================================================================
-- Party Button Helper
-- ============================================================================

-- Render party toggle buttons ([ME] [P1] [P2] etc.)
-- Returns: true if any button was rendered
-- For grouped abilities, pass group_name instead of ability_name
local function render_party_buttons(ctx, key_name, has_spell, ability, is_group, id_suffix)
    local any_rendered = false

    -- Leading slot: scholar S button / bard [A] indent / spacer (aligns the row)
    render_leading_slot(key_name, ability, ctx)

    -- Check if this ability requires a target modifier (like Pianissimo)
    if not ability then
        ability = find_ability_by_name(ctx.job_def, key_name)
    end
    
    local requires_target_modifier = ability and ability.target_modifier == true
    local has_target_modifier = true  -- Default to true for non-modifier abilities
    
    if requires_target_modifier then
        -- Check if the target_modifier ability is available (e.g., Pianissimo at level 20)
        has_target_modifier = false
        if ctx.job_def.abilities.target_modifier then
            local main_level, sub_level = common.get_player_level()
            for _, modifier_ability in ipairs(ctx.job_def.abilities.target_modifier) do
                local is_main_job = ability.is_main_job ~= false
                local level_to_check = is_main_job and main_level or sub_level
                if modifier_ability.level and level_to_check >= modifier_ability.level then
                    has_target_modifier = true
                    break
                end
            end
        end
    end
    
    -- ME now behaves like P1-P5: for songs it uses Pianissimo, so it needs the
    -- target modifier to be available (same gate the party buttons use).
    local party_has_spell = has_spell and has_target_modifier

    -- Bard area-song [A] button: sing WITHOUT Pianissimo so everyone in range
    -- gets the song. Sits in the leading slot (like the Scholar S button on other
    -- jobs). Needs no Pianissimo, so it stays usable below Pianissimo's level.
    -- Every bard song gets it (Mazurka has no Pianissimo but is always area).
    if ability and ability.magic == 'song' then
        local a_enabled = is_group and is_group_party_buff_enabled(ctx, key_name, 'A')
            or is_party_buff_enabled(ctx, key_name, 'A')

        if not has_spell then
            imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
            imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
            imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
        elseif a_enabled then
            -- Use default colors
        else
            imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
            imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
        end

        local a_label = 'A##' .. key_name .. '_area'
        if has_spell and imgui.Button(a_label, { 20, 0 }) then
            if is_group then
                toggle_group_party_buff(ctx, key_name, 'A', not a_enabled)
            else
                toggle_party_buff(ctx, key_name, 'A', not a_enabled)
            end
        elseif not has_spell then
            imgui.Button(a_label, { 20, 0 })
        end

        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Area: sing without Pianissimo so everyone in range gets it.\nRecast tracks party members not given a specific ME/P button.')
        end

        if not has_spell then
            imgui.PopStyleColor(4)
        elseif not a_enabled then
            imgui.PopStyleColor(3)
        end

        imgui.SameLine(0, SPACE_BETWEEN_BUTTONS)
    end

    -- Render [ME] button
    local me_enabled = is_group and is_group_party_buff_enabled(ctx, key_name, 0) or is_party_buff_enabled(ctx, key_name, 0)

    if not party_has_spell then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif me_enabled then
        -- Use default colors
    else
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
    end

    local me_gate_color = party_has_spell and target_gate_color(ctx, key_name, 0)
    if me_gate_color then imgui.PushStyleColor(ImGuiCol_Text, me_gate_color) end

    local me_button_label = 'ME##' .. key_name .. '_me'
    if party_has_spell and imgui.Button(me_button_label, { PARTY_BUTTON_WIDTH, 0 }) then
        if is_group then
            toggle_group_party_buff(ctx, key_name, 0, not me_enabled)
        else
            toggle_party_buff(ctx, key_name, 0, not me_enabled)
        end
    elseif not party_has_spell then
        imgui.Button(me_button_label, { PARTY_BUTTON_WIDTH, 0 })
    end

    if party_has_spell then
        render_target_gate_context_menu(ctx, ability, key_name, 0, id_suffix)
    end

    if imgui.IsItemHovered() then
        local me_tip = (common.get_party_member_name(0) or 'ME') .. gate_tooltip_suffix(me_gate_color)
        ui_components.set_tooltip(me_tip)
    end

    if me_gate_color then imgui.PopStyleColor() end

    if not party_has_spell then
        imgui.PopStyleColor(4)
    elseif not me_enabled then
        imgui.PopStyleColor(3)
    end

    any_rendered = true
    
    -- Render party member buttons (P1-P5)
    local party_size = common.get_party_size()
    if party_size > 1 then
        for party_index = 1, 5 do
            local is_active = party_index < party_size
            
            if is_active then
                imgui.SameLine()
                
                local is_enabled = is_group and is_group_party_buff_enabled(ctx, key_name, party_index) or is_party_buff_enabled(ctx, key_name, party_index)
                
                -- Treat party button as "not has_spell" if target_modifier is required but not available
                -- NOTE: `and not is_trust_member` removed -- Trusts can now be buffed
                -- Damage-immune trusts (Moogle etc.) can't be supported, so lock the button.
                local pm = common.game_state and common.game_state.party[party_index]
                local is_excluded = pm and common.is_trust_excluded(pm.name, pm.server_id)
                -- buff.lua skips Trusts for travel_buff abilities, so lock the button rather
                -- than let it be switched on and silently do nothing (same pm.is_trust field).
                local is_trust_travel = ability and ability.travel_buff and pm and pm.is_trust
                local party_has_spell = has_spell and has_target_modifier and not is_excluded
                    and not is_trust_travel
                
                if not party_has_spell then
                    imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
                    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
                    imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
                elseif is_enabled then
                    -- Use default colors
                else
                    imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
                    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
                end
                
                local p_gate_color = party_has_spell and target_gate_color(ctx, key_name, party_index)
                if p_gate_color then imgui.PushStyleColor(ImGuiCol_Text, p_gate_color) end

                local button_label = 'P' .. party_index .. '##' .. key_name .. '_p' .. party_index
                if party_has_spell and imgui.Button(button_label, { PARTY_BUTTON_WIDTH, 0 }) then
                    if is_group then
                        toggle_group_party_buff(ctx, key_name, party_index, not is_enabled)
                    else
                        toggle_party_buff(ctx, key_name, party_index, not is_enabled)
                    end
                elseif not party_has_spell then
                    imgui.Button(button_label, { PARTY_BUTTON_WIDTH, 0 })
                end

                if party_has_spell then
                    render_target_gate_context_menu(ctx, ability, key_name, party_index, id_suffix)
                end

                -- Tooltip: party member name, plus a Trust reliability caveat
                -- (removal vs. buff tracking) appended only on actual Trust buttons.
                if imgui.IsItemHovered() then
                    local pname = common.get_party_member_name(party_index) or ('P' .. party_index)
                    if is_excluded then
                        ui_components.set_tooltip(pname .. '\nTrust cannot take any damage')
                    elseif is_trust_travel then
                        ui_components.set_tooltip(pname .. '\nTrusts do not need Sneak or Invisible')
                    elseif ctx.is_trust and ctx.is_trust(party_index) and ctx.show_trust_warning then
                        ui_components.set_tooltip(pname .. '\nTrust/Tracked Removal is not totally reliable')
                    elseif ctx.is_trust and ctx.is_trust(party_index) and ctx.show_buff_warning then
                        ui_components.set_tooltip(pname .. '\nTrust/Tracked Buff tracking is not totally reliable')
                    else
                        ui_components.set_tooltip(pname .. gate_tooltip_suffix(p_gate_color))
                    end
                end

                if p_gate_color then imgui.PopStyleColor() end

                if not party_has_spell then
                    imgui.PopStyleColor(4)
                elseif not is_enabled then
                    imgui.PopStyleColor(3)
                end
            end
        end
    end
    
    -- Render alliance member buttons ([B0]-[B5], [C0]-[C5])
    -- Uses key format 'al_<flat_index>' (flat_index 6-17) in party_buffs.
    -- Alliance members are targeted by server_id (same mechanism as tracked targets).
    local al_gs = common.game_state
    if al_gs and al_gs.alliance then
        local alliance_prefixes = { [2] = 'B', [3] = 'C' }
        for pi = 2, 3 do
            local sub_party = al_gs.alliance[pi]
            if sub_party and next(sub_party) ~= nil then
                local prefix = alliance_prefixes[pi]
                local sorted_al = common.sorted_alliance_members(sub_party)

                for _, entry in ipairs(sorted_al) do
                    local local_idx = entry.local_idx
                    local m         = entry.m
                    local flat_index = (pi - 1) * 6 + local_idx  -- 6-17
                    local al_key     = 'al_' .. flat_index

                    imgui.SameLine()

                    local is_enabled    = is_group and is_group_party_buff_enabled(ctx, key_name, al_key) or is_party_buff_enabled(ctx, key_name, al_key)
                    local is_compatible = ability and ability.target_outside
                    local is_disabled   = not has_spell or not is_compatible

                    if is_disabled then
                        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
                        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
                        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
                        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
                    elseif is_enabled then
                        -- Use default colors
                    else
                        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
                        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
                        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
                    end

                    local al_gate_color = not is_disabled and target_gate_color(ctx, key_name, al_key)
                    if al_gate_color then imgui.PushStyleColor(ImGuiCol_Text, al_gate_color) end

                    local button_label = prefix .. local_idx .. '##' .. key_name .. '_' .. al_key
                    local clicked = imgui.Button(button_label, { PARTY_BUTTON_WIDTH, 0 })
                    if clicked and not is_disabled then
                        if is_group then
                            toggle_group_party_buff(ctx, key_name, al_key, not is_enabled)
                        else
                            toggle_party_buff(ctx, key_name, al_key, not is_enabled)
                        end
                    end

                    if not is_disabled then
                        render_target_gate_context_menu(ctx, ability, key_name, al_key, id_suffix)
                    end

                    if imgui.IsItemHovered() then
                        if not is_compatible then
                            ui_components.set_tooltip('Not compatible with out-of-party targets')
                        else
                            ui_components.set_tooltip((m.name or (prefix .. local_idx)) .. gate_tooltip_suffix(al_gate_color))
                        end
                    end

                    if al_gate_color then imgui.PopStyleColor() end

                    if is_disabled then
                        imgui.PopStyleColor(4)
                    elseif not is_enabled then
                        imgui.PopStyleColor(3)
                    end
                end
            end
        end
    end

    -- Render tracked target buttons for every buff row.
    -- Buttons are grayed out and non-clickable when the ability is not compatible
    -- with out-of-party targets (i.e. ability.target_outside is not set).
    local tracked_list = common.get_tracked_targets()
    local sorted_tracked = {}
    for sid, tt in pairs(tracked_list) do
        table.insert(sorted_tracked, { sid = sid, name = tt.name })
    end
    table.sort(sorted_tracked, function(a, b) return a.name < b.name end)

    if #sorted_tracked > 0 then
        local is_compatible = ability and ability.target_outside

        for t_idx, tt in ipairs(sorted_tracked) do
            imgui.SameLine()

            local tt_key = 'tt_' .. tt.sid
            local is_tt_enabled = is_group and is_group_party_buff_enabled(ctx, key_name, tt_key) or is_party_buff_enabled(ctx, key_name, tt_key)
            local is_disabled = not has_spell or not is_compatible

            if is_disabled then
                imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
                imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
                imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
            elseif is_tt_enabled then
                -- Use default colors
            else
                imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
                imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
            end

            local tt_gate_color = not is_disabled and target_gate_color(ctx, key_name, tt_key)
            if tt_gate_color then imgui.PushStyleColor(ImGuiCol_Text, tt_gate_color) end

            local tt_button_label = 'T' .. t_idx .. '##' .. key_name .. '_t' .. tt.sid
            local clicked = imgui.Button(tt_button_label, { PARTY_BUTTON_WIDTH, 0 })
            if clicked and not is_disabled then
                if is_group then
                    toggle_group_party_buff(ctx, key_name, tt_key, not is_tt_enabled)
                else
                    toggle_party_buff(ctx, key_name, tt_key, not is_tt_enabled)
                end
            end

            if not is_disabled then
                render_target_gate_context_menu(ctx, ability, key_name, tt_key, id_suffix)
            end

            -- Tooltip: show target name, or reason why button is disabled
            if imgui.IsItemHovered() then
                if not is_compatible then
                    ui_components.set_tooltip('Not compatible with out-of-party targets')
                elseif ctx.show_trust_warning then
                    ui_components.set_tooltip(tt.name .. '\nTrust/Tracked Removal is not totally reliable')
                elseif ctx.show_buff_warning then
                    ui_components.set_tooltip(tt.name .. '\nTrust/Tracked Buff tracking is not totally reliable')
                else
                    ui_components.set_tooltip(tt.name .. gate_tooltip_suffix(tt_gate_color))
                end
            end

            if tt_gate_color then imgui.PopStyleColor() end

            if is_disabled then
                imgui.PopStyleColor(4)
            elseif not is_tt_enabled then
                imgui.PopStyleColor(3)
            end
        end
    end

    return any_rendered
end

-- ============================================================================
-- Render Functions
-- ============================================================================

-- Render an ON/OFF button for ability state
function ui_components.onoff_button(ctx, ability_name, job_def, has_spell)
    has_spell = has_spell == nil and true or has_spell

    -- Leading slot: scholar S button / bard [A] indent / spacer (aligns the row)
    -- Look up the ability to check if it's a /ja (not eligible for stratagems)
    local ability_obj = find_ability_by_name(job_def, ability_name)
    render_leading_slot(ability_name, ability_obj, ctx)

    local is_enabled = is_ability_enabled(ctx, ability_name)
    local button_width = get_onoff_button_width()
    
    if not has_spell then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
    elseif is_enabled then
        -- Use default colors
    else
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
    end
    
    local button_text = is_enabled and 'ON' or 'OFF'
    local button_label = button_text .. '##onoff_' .. ability_name
    
    if has_spell and imgui.Button(button_label, { button_width, 0 }) then
        toggle_ability(ctx, ability_name, not is_enabled, job_def)
    elseif not has_spell then
        imgui.Button(button_label, { button_width, 0 })
    end
    
    if not has_spell or not is_enabled then
        imgui.PopStyleColor(3)
    end
end

-- Render a dropdown for selecting ability from a group
function ui_components.group_dropdown(ctx, job_def, target_group, dropdown_width)
    if not job_def or not target_group then
        return
    end
    
    local usable = get_usable_abilities_in_group(job_def, target_group, ctx)
    if #usable == 0 then
        return
    end
    
    local selected = get_selected_ability_for_group(ctx, job_def, target_group)
    local current_display
    if selected then
        if selected.cost and selected.cost > 0 then
            local resource_label = (selected.resource_type or job_def.resource_type) == 'tp' and 'TP' or 'MP'
            local display_cost = common.effective_ability_cost(selected, ctx.settings, job_def)
            current_display = selected.name .. ' (' .. display_cost .. ' ' .. resource_label .. ')'
        else
            current_display = selected.name
        end
    else
        current_display = 'None'
    end
    
    local setting_key = 'selected_' .. target_group
    local combo_label = '##dropdown_' .. target_group
    local selected_combat_only = selected and effective_combat_only(selected, ctx) or false
    local selected_idle_only = selected and common.is_ability_idle_only(selected, ctx.settings) or false
    -- Ninjutsu tool (requires_item) not in inventory: gray the combo, overriding
    -- the idle/combat tint, so a 0-tool spell reads as unusable.
    local selected_no_item = selected and selected.requires_item
        and common.count_equippable_items(selected.requires_item) == 0 or false

    -- Apply color styling
    if selected then
        if selected_no_item then
            imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
        elseif selected_combat_only then
            imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
        elseif selected_idle_only then
            imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
        end
    end
    
    imgui.PushItemWidth(dropdown_width or DROPDOWN_FALLBACK_WIDTH)
    if ui_components.begin_opaque_combo(combo_label, current_display) then
        for _, ability in ipairs(usable) do
            local display_text
            if ability.cost and ability.cost > 0 then
                local resource_label = (ability.resource_type or job_def.resource_type) == 'tp' and 'TP' or 'MP'
                local display_cost = common.effective_ability_cost(ability, ctx.settings, job_def)
                display_text = ability.name .. ' (' .. display_cost .. ' ' .. resource_label .. ')'
            else
                display_text = ability.name
            end
            local is_selected = (selected and selected.name == ability.name)
            
            if imgui.Selectable(display_text, is_selected) then
                ctx.settings[setting_key] = ability.name
                
                if ctx.save_callback then
                    ctx.save_callback()
                end
            end
            
            if is_selected then
                imgui.SetItemDefaultFocus()
            end
        end
        ui_components.end_opaque_combo()
    end

    -- Right-click context menu for combat_only toggle (attaches to the combo)
    if selected then
        render_combat_only_context_menu(ctx, selected)
    end
    
    -- Show tooltip
    if imgui.IsItemHovered() and selected then
        if selected_combat_only then
            ui_components.set_tooltip('Combat Only')
        elseif selected_idle_only then
            ui_components.set_tooltip('Idle Only')
        end
    end
    
    imgui.PopItemWidth()
    
    if selected and (selected_no_item or selected_combat_only or selected_idle_only) then
        imgui.PopStyleColor()
    end
end

-- True when an ability needs a specific pet summoned (requires_pet_name) that
-- isn't out right now -- used to gray the row and tooltip why.
local function pet_type_unmet(ability)
    return ability.requires_pet_name ~= nil and not common.pet_type_ok(ability)
end

-- Tooltip text naming the pet(s) a requires_pet_name ability needs.
local function pet_type_tooltip(ability)
    return 'Requires pet ' .. table.concat(ability.requires_pet_name, ' / ')
end

-- True when a requires_buff (number or list) prerequisite is missing -- grays the
-- row but keeps it selectable. Merge clears requires_buff for subjob-supplied
-- spells (SCH/WHM), so those never reach here. An assigned precast that supplies
-- the buff ([E] Enlightenment) leaves the row ungated, so it stays lit.
local function requires_buff_unmet(ability, ctx)
    local req = ability and ability.requires_buff
    if not req then return false end
    if ctx and common.precast_satisfies_prereq(ctx.job_def, ctx.settings, ability) then return false end
    if type(req) == 'table' then
        for _, id in ipairs(req) do
            if common.has_buff(0, id) then return false end
        end
        return true
    end
    return not common.has_buff(0, req)
end

-- Ninjutsu tool count (requires_item): green "(N)" after the row, red at 0. N is
-- the summed inventory count of the spell's own tool plus Shikanofuda (both in
-- requires_item). count==0 also grays the row (see no_item in the callers).
local function render_item_count(ability)
    if not ability or not ability.requires_item then return end
    local count = common.count_equippable_items(ability.requires_item)
    imgui.SameLine()
    imgui.TextColored(count > 0 and LIGHT_GREEN or LIGHT_RED, string.format('(%d)', count))
end

-- Render a self-target single ability
-- Layout: [ON/OFF Button] Ability Name
function ui_components.self_single_ability(ctx, ability, job_def, id_suffix)
    local has_spell = common.has_spell_learned(ability)
    -- Ammo-gated ability (BST Reward Regen) with none of the consumable owned:
    -- gray it like an unlearned spell and say what's missing.
    local no_ammo = ability.requires_equipped_ammo
        and common.count_equippable_items(ability.requires_equipped_ammo) == 0
    -- Ninjutsu tool (requires_item) not in inventory: gray like no_ammo.
    local no_item = ability.requires_item
        and common.count_equippable_items(ability.requires_item) == 0
    local wrong_pet = pet_type_unmet(ability)
    -- Blue magic not in the set-spell list: gray the row but keep it
    -- selectable -- equipping the spell is up to the user, automation just
    -- skips it (filter_abilities_by_level) until it's set.
    local blue_unequipped = common.is_blue_magic_unequipped(ability)
    local buff_unmet = requires_buff_unmet(ability, ctx)
    local spell_suffix = ''
    local ability_combat_only = effective_combat_only(ability, ctx)
    local ability_idle_only = common.is_ability_idle_only(ability, ctx.settings)

    ui_components.onoff_button(ctx, ability.name, job_def, has_spell and not no_item)

    imgui.SameLine()

    -- Push text color after buttons so S button / ON/OFF button are not tinted
    if not has_spell or no_ammo or no_item or wrong_pet or blue_unequipped or buff_unmet then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif ability_combat_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
    elseif ability_idle_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
    end
    
    local desc
    if ability.cost and ability.cost > 0 then
        local resource_label = (ability.resource_type or job_def.resource_type) == 'tp' and 'TP' or 'MP'
        local display_cost = common.effective_ability_cost(ability, ctx.settings, job_def)
        desc = ability.name .. ' (' .. display_cost .. ' ' .. resource_label .. ')' .. spell_suffix
    else
        desc = ability.name .. spell_suffix
    end
    imgui.Text(desc)

    render_combat_only_context_menu(ctx, ability, id_suffix)

    if imgui.IsItemHovered() then
        if not has_spell then
            ui_components.set_tooltip('Not Learned')
        elseif blue_unequipped then
            ui_components.set_tooltip('Blue Magic not currently equipped')
        elseif no_ammo then
            ui_components.set_tooltip('No ' .. (ability.ammo_label or 'item') .. ' found in storage.')
        elseif no_item then
            ui_components.set_tooltip('No ' .. (ability.item_label or 'tool') .. ' or Shikanofuda in inventory.')
        elseif wrong_pet then
            ui_components.set_tooltip(pet_type_tooltip(ability))
        elseif buff_unmet then
            ui_components.set_tooltip('Prerequisite buff not active')
        elseif ability_combat_only then
            ui_components.set_tooltip('Combat Only')
        elseif ability_idle_only then
            ui_components.set_tooltip('Idle Only')
        end
    end

    if not has_spell or no_ammo or no_item or wrong_pet or blue_unequipped or buff_unmet or ability_combat_only or ability_idle_only then
        imgui.PopStyleColor()
    end

    render_item_count(ability)
end

-- Render a self-target grouped ability with dropdown
-- Layout: [ON/OFF Button] [Dropdown]
function ui_components.self_grouped_ability(ctx, ability, job_def)
    if not ability.group then
        return
    end
    
    local usable = get_usable_abilities_in_group(job_def, ability.group, ctx)
    if #usable == 0 then
        return
    end
    
    local selected = get_selected_ability_for_group(ctx, job_def, ability.group)
    if not selected then
        return
    end
    
    local has_spell = common.has_spell_learned(selected)
    -- Ninjutsu tool (requires_item) not in inventory: can't cast, so lock the
    -- ON/OFF toggle off and gray it, same as an unlearned spell.
    local no_item = selected.requires_item
        and common.count_equippable_items(selected.requires_item) == 0
    local can_toggle = has_spell and not no_item

    -- Leading slot: scholar S button / bard [A] indent / spacer (aligns the row)
    render_leading_slot(ability.group, selected, ctx)

    -- Use group-based ON/OFF button
    local is_enabled = is_group_enabled(ctx, ability.group)
    local button_width = get_onoff_button_width()

    if not can_toggle then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
    elseif is_enabled then
        -- Use default colors
    else
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
    end

    local button_text = is_enabled and 'ON' or 'OFF'
    local button_label = button_text .. '##onoff_group_' .. ability.group

    if can_toggle and imgui.Button(button_label, { button_width, 0 }) then
        toggle_group(ctx, ability.group, not is_enabled)
    elseif not can_toggle then
        imgui.Button(button_label, { button_width, 0 })
    end

    if not can_toggle or not is_enabled then
        imgui.PopStyleColor(3)
    end

    -- Push text color after buttons so S button / ON/OFF button are not tinted
    local selected_combat_only = effective_combat_only(selected, ctx)
    local selected_idle_only = common.is_ability_idle_only(selected, ctx.settings)
    local buff_unmet = requires_buff_unmet(selected, ctx)
    if not has_spell or no_item or buff_unmet then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif selected_combat_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
    elseif selected_idle_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
    end

    imgui.SameLine()
    ui_components.group_dropdown(ctx, job_def, ability.group, DROPDOWN_WIDTH)

    if not has_spell or no_item or buff_unmet or selected_combat_only or selected_idle_only then
        imgui.PopStyleColor()
    end

    render_item_count(selected)
end

-- Render a party-target single ability
-- Layout: [ME] [P1] [P2]... Ability Name
function ui_components.party_single_ability(ctx, ability, job_def, id_suffix)
    local has_spell = common.has_spell_learned(ability)
    local spell_suffix = ''

    -- Check if Pianissimo/target modifier is required but not available
    local requires_modifier = ability.target_modifier == true
    local has_modifier = true
    if requires_modifier and has_spell then
        has_modifier = false
        if job_def.abilities.target_modifier then
            local main_level, sub_level = common.get_player_level()
            for _, modifier_ability in ipairs(job_def.abilities.target_modifier) do
                local is_main_job = ability.is_main_job ~= false
                local level_to_check = is_main_job and main_level or sub_level
                if modifier_ability.level and level_to_check >= modifier_ability.level then
                    has_modifier = true
                    break
                end
            end
        end
        if not has_modifier then
            spell_suffix = spell_suffix .. ' (Pianissimo Lv20)'
        end
    end
    
    local desc
    if ability.cost and ability.cost > 0 then
        local resource_label = (ability.resource_type or job_def.resource_type) == 'tp' and 'TP' or 'MP'
        local display_cost = common.effective_ability_cost(ability, ctx.settings, job_def)
        desc = ability.name .. ' (' .. display_cost .. ' ' .. resource_label .. ')' .. spell_suffix
    else
        desc = ability.name .. spell_suffix
    end
    
    local wrong_pet = pet_type_unmet(ability)
    local buff_unmet = requires_buff_unmet(ability, ctx)

    render_party_buttons(ctx, ability.name, has_spell, ability, false, id_suffix)

    imgui.SameLine()

    local ability_combat_only = effective_combat_only(ability, ctx)
    local ability_idle_only = common.is_ability_idle_only(ability, ctx.settings)
    if not has_spell or not has_modifier or wrong_pet or buff_unmet then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif ability_combat_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
    elseif ability_idle_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
    end

    imgui.Text(desc)

    render_combat_only_context_menu(ctx, ability)

    if imgui.IsItemHovered() then
        if not has_spell then
            ui_components.set_tooltip('Not Learned')
        elseif wrong_pet then
            ui_components.set_tooltip(pet_type_tooltip(ability))
        elseif buff_unmet then
            ui_components.set_tooltip('Prerequisite buff not active')
        elseif ability_combat_only then
            ui_components.set_tooltip('Combat Only')
        elseif ability_idle_only then
            ui_components.set_tooltip('Idle Only')
        end
    end

    if not has_spell or not has_modifier or wrong_pet or buff_unmet or ability_combat_only or ability_idle_only then
        imgui.PopStyleColor()
    end
end

-- Render a party-target grouped ability with dropdown
-- Layout: [ME] [P1] [P2]... [Dropdown]
function ui_components.party_grouped_ability(ctx, ability, job_def, id_suffix)
    if not ability.group then
        return
    end
    
    local usable = get_usable_abilities_in_group(job_def, ability.group, ctx)
    if #usable == 0 then
        return
    end
    
    local selected = get_selected_ability_for_group(ctx, job_def, ability.group)
    if not selected then
        return
    end
    
    local has_spell = common.has_spell_learned(selected)
    
    -- Check if Pianissimo/target modifier is required but not available
    local requires_modifier = selected.target_modifier == true
    local has_modifier = true
    if requires_modifier and has_spell then
        has_modifier = false
        if job_def.abilities.target_modifier then
            local main_level, sub_level = common.get_player_level()
            for _, modifier_ability in ipairs(job_def.abilities.target_modifier) do
                local is_main_job = selected.is_main_job ~= false
                local level_to_check = is_main_job and main_level or sub_level
                if modifier_ability.level and level_to_check >= modifier_ability.level then
                    has_modifier = true
                    break
                end
            end
        end
    end
    
    render_party_buttons(ctx, ability.group, has_spell, selected, true, id_suffix)
    
    imgui.SameLine()
    
    local selected_combat_only = effective_combat_only(selected, ctx)
    local selected_idle_only = common.is_ability_idle_only(selected, ctx.settings)
    local buff_unmet = requires_buff_unmet(selected, ctx)
    if not has_spell or not has_modifier or buff_unmet then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif selected_combat_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
    elseif selected_idle_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
    end

    ui_components.group_dropdown(ctx, job_def, ability.group, DROPDOWN_WIDTH)

    if not has_spell or not has_modifier or buff_unmet or selected_combat_only or selected_idle_only then
        imgui.PopStyleColor()
    end
end

-- Main ability renderer - determines which rendering function to use
function ui_components.render_ability(ctx, ability, job_def, id_suffix)
    local filters = get_filters(ctx)
    
    if not ability or not filters.can_use_ability(ability) then
        return false
    end
    
    if is_subjob_duplicate(job_def, ability, ctx) then
        return false
    end
    
    -- Ungrouped groups render every tier as its own row (per-name), like a
    -- non-grouped ability, instead of a single-select dropdown.
    local has_group = ability.group ~= nil
        and not (ctx.settings and ctx.settings['ungrouped_' .. ability.group])
    local is_party_target = can_cast_on_party(ability)
    
    if has_group then
        local group_key = 'rendered_group_' .. ability.group
        if ctx.settings and ctx.settings[group_key] then
            return false
        end
        
        local usable = get_usable_abilities_in_group(job_def, ability.group, ctx)
        if #usable == 0 then
            return false
        end
        
        ctx.settings[group_key] = true
    end
    
    if has_group then
        if is_party_target then
            ui_components.party_grouped_ability(ctx, ability, job_def, id_suffix)
        else
            ui_components.self_grouped_ability(ctx, ability, job_def)
        end
    else
        if is_party_target then
            ui_components.party_single_ability(ctx, ability, job_def, id_suffix)
        else
            ui_components.self_single_ability(ctx, ability, job_def, id_suffix)
        end
    end
    
    return true
end

-- ============================================================================
-- UI Element Creators
-- ============================================================================

-- SetTooltip that ignores the window's ui_opacity fade (like the combo popups):
-- the tooltip renders fully opaque however faded the window under it is.
function ui_components.set_tooltip(text)
    if imgui.GetStyle().Alpha < 1.0 then
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, 1.0)
        imgui.SetTooltip(text)
        imgui.PopStyleVar()
    else
        imgui.SetTooltip(text)
    end
end

-- Sections held back for the disabled end of the tab bar, and the entry the next
-- item_tooltip belongs to. Filled by begin_section, drained by end_sections --
-- declared up here because item_tooltip below reads them. See "Section Display".
local deferred_tabs = {}
local deferred_tooltip_target = nil

-- Whether the tab begin_tab_section just submitted is hovered. Sampled there
-- because the enable checkbox and separator it draws afterwards would otherwise
-- be the "last item" the caller's item_tooltip tests. nil outside tab mode.
local tab_hovered = nil

-- Show a static help tooltip for the most recently rendered item.
function ui_components.item_tooltip(text)
    -- A deferred section has submitted no item yet, so IsItemHovered would test
    -- whatever was rendered before it -- usually the previous tab. Its help rides
    -- along with the tab instead and is shown when end_sections submits it.
    if deferred_tooltip_target then
        deferred_tooltip_target.tooltip = text
        deferred_tooltip_target = nil
        return
    end
    -- A tab's help belongs to the tab, not to the widgets begin_tab_section drew
    -- inside it, so it rides the hover sampled there instead of IsItemHovered.
    if tab_hovered ~= nil then
        local hovered = tab_hovered
        tab_hovered = nil
        if text and hovered then
            ui_components.set_tooltip(text)
        end
        return
    end
    if text and imgui.IsItemHovered() then
        ui_components.set_tooltip(text)
    end
end

-- Create a checkbox UI element linked to a setting
function ui_components.checkbox(ctx, label, setting_name, ui_var)
    if imgui.Checkbox(label, ui_var) then
        ctx.settings[setting_name] = ui_var[1]
        if ctx.save_callback then
            ctx.save_callback()
        end
    end
end

-- ============================================================================
-- Section Display (collapsing headers vs. tab bar)
-- ============================================================================
-- The window's main sections render with one of two chromes, never both: the
-- classic stack of CollapsingHeaders, or one tab per section in a single bar.
-- Which one is the per-character `display_mode` setting. Callers use the same
-- shape either way:
--
--     ui.begin_sections(ctx)
--       local is_open, is_enabled = ui.begin_section(ctx, 'Buffs', 'buff_enabled', false)
--       if is_open and is_enabled then ... end
--       ui.end_section(ctx, is_open)
--       ... 15 more ...
--     ui.end_sections(ctx)

-- A mode switch is made from a popup that opens inside a frame already begun in
-- the old mode. Applying it on the spot would leave a BeginTabBar without its
-- EndTabBar (or an EndTabBar with no BeginTabBar), so the click only records the
-- request and begin_sections applies it at the top of the next frame.
local pending_display_mode = nil

-- Read a section's enable setting, falling back to its default when the key has
-- never been written (a fresh character, or a setting added after the file was
-- first saved).
local function section_enabled(ctx, setting_name, default_value)
    local value = ctx.settings[setting_name]
    if value == nil then
        value = default_value
    end
    return value and true or false
end

-- The section whose tab is open, and the one that was open before it. Tracked by
-- begin_tab_section so disabling a section can hand the selection back to the tab
-- the user came from instead of leaving the choice to ImGui.
local selected_section = nil
local previous_section = nil

-- The section whose tab must be selected, and how many more frames to keep asking
-- for it. Toggling a section changes its tab id (the '_off' suffix comes and goes),
-- which ImGui reads as one tab closing and another opening -- that is what makes the
-- bar re-sort into submission order, but a closed selection also falls back to the
-- most recently selected tab. ImGuiTabItemFlags_SetSelected only queues a selection
-- for the *next* BeginTabBar, and the closing tab is not dropped until the frame
-- after that, so a single submission of the flag loses the race with that fallback.
-- Re-submitting it until the tab reports selected covers the whole transition; the
-- frame count stops it wedging if the target section stops rendering first (a job
-- change or a party-size gate can remove it mid-transition).
local reselect_id = nil
local reselect_frames = 0

local RESELECT_FRAMES = 4

-- Frames left to submit the bar with ImGuiTabBarFlags_AutoSelectNewTabs. That flag
-- is what actually moves the selection onto a section switched ON from inside its
-- own tab: SetSelected does not stick on a tab id ImGui is meeting for the first
-- time (the tab it would take the selection from is removed in the same layout
-- pass, and the fallback to the most recently selected tab wins), but AutoSelectNewTabs
-- is resolved by ImGui itself as the tab appears. It is armed only for the enable
-- transition and only for the two frames it takes to land, because the toggled
-- section is the only tab whose id changes on that frame -- left on, it would hand
-- the selection to the '_off' tab a *disabling* section creates, which is the one
-- place the plain fallback is already the wanted answer.
local autoselect_frames = 0

local function set_section_enabled(ctx, setting_name, value)
    ctx.settings[setting_name] = value
    if ctx.section_mode == 'tabs' then
        -- Enabling: keep the selection on the section just switched on, so its tab
        -- sorts into the enabled group without the user losing their place.
        -- Disabling: its tab moves to the disabled end, so hand the selection to the
        -- tab that was open before this one.
        local target = setting_name
        if value then
            autoselect_frames = 2
        else
            target = (previous_section ~= setting_name) and previous_section or nil
        end
        if target then
            reselect_id = target
            reselect_frames = RESELECT_FRAMES
        end
    end
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- The right-click popup every section header and every tab carries. It is the
-- only place display_mode is switched, and it offers exactly one direction:
-- headers offer tabs, tabs offer headers. Never both at once.
local function render_display_mode_menu(ctx, setting_name)
    local to_tabs = ctx.section_mode ~= 'tabs'
    if ui_components.begin_opaque_context_item('##cmenu_display_' .. setting_name) then
        imgui.TextColored(LIGHT_GRAY, to_tabs and tooltips.display_as_tabs_hint or tooltips.display_as_headers_hint)
        imgui.Separator()
        if imgui.Selectable(to_tabs and 'Display as tabs' or 'Display as section headers') then
            pending_display_mode = to_tabs and 'tabs' or 'headers'
        end
        ui_components.end_opaque_popup()
    end
end

local function begin_header_section(ctx, label, setting_name, default_value)
    local setting_var = { section_enabled(ctx, setting_name, default_value) }
    local previous_value = setting_var[1]
    if imgui.Checkbox('##' .. setting_name, setting_var) then
        set_section_enabled(ctx, setting_name, setting_var[1])
        -- Auto-expand when enabling the section (only on the transition from disabled to enabled)
        if setting_var[1] and not previous_value then
            imgui.SetNextItemOpen(true)
        end
    end
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol_Header, HEADER_COLOR_NORMAL)
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, HEADER_COLOR_HOVERED)
    imgui.PushStyleColor(ImGuiCol_HeaderActive, HEADER_COLOR_ACTIVE)
    local is_open = imgui.CollapsingHeader(label, ImGuiTreeNodeFlags_DefaultOpen)
    imgui.PopStyleColor(3)
    render_display_mode_menu(ctx, setting_name)
    return is_open, setting_var[1]
end

local function begin_tab_section(ctx, label, setting_name, default_value)
    local enabled = section_enabled(ctx, setting_name, default_value)

    if not enabled then
        imgui.PushStyleColor(ImGuiCol_Tab, TAB_COLOR_DISABLED)
        imgui.PushStyleColor(ImGuiCol_TabHovered, TAB_COLOR_DISABLED_HOVERED)
        imgui.PushStyleColor(ImGuiCol_TabActive, TAB_COLOR_DISABLED_ACTIVE)
        -- ImGui swaps to the Unfocused pair whenever the tab bar's window is not the
        -- focused ImGui window (the widget or the panel has it), so without these two
        -- a disabled tab's background renders at full strength half the time.
        imgui.PushStyleColor(ImGuiCol_TabUnfocused, TAB_COLOR_DISABLED)
        imgui.PushStyleColor(ImGuiCol_TabUnfocusedActive, TAB_COLOR_DISABLED_ACTIVE)
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    end

    -- '###setting_name' pins the tab's id to its setting so the selected tab
    -- survives a label change. NoPushId keeps the id stack identical whether or
    -- not the tab is selected: render_display_mode_menu is submitted in both
    -- cases and would otherwise hash to two different popup ids between frames.
    -- p_open is nil on purpose: a close button would be the only widget ImGui can
    -- draw on a tab, and the enable checkbox lives in the tab body instead.
    --
    -- The '_off' suffix deliberately gives a disabled section a *different* id.
    -- ImGui keeps a bar's tab order across frames and only re-sorts it into
    -- submission order when a tab is added, so a section that merely changed state
    -- would otherwise sit where it always sat instead of moving to the enabled or
    -- disabled end of the bar. A new id is read as one tab closing and another
    -- opening, which is what makes the sort happen -- and SetSelected is what stops
    -- that close from dropping the user's selection along with it.
    local flags = ImGuiTabItemFlags_NoPushId
    if reselect_id == setting_name then
        flags = flags + ImGuiTabItemFlags_SetSelected
    end
    local selected = imgui.BeginTabItem(
        label .. '###' .. setting_name .. (enabled and '' or '_off'), nil, flags)
    tab_hovered = imgui.IsItemHovered()

    if selected then
        -- The request landed; stop re-submitting it so the next click can move on.
        if reselect_id == setting_name then
            reselect_id = nil
        end
        if selected_section ~= setting_name then
            previous_section = selected_section
            selected_section = setting_name
        end
    end

    -- Pop before the body renders, so tab dimming never bleeds into its contents.
    if not enabled then
        imgui.PopStyleColor(6)
    end

    render_display_mode_menu(ctx, setting_name)

    -- The tab-mode counterpart of the header's checkbox. ImGui can draw no widget
    -- on a tab itself, so it goes at the top of the tab's body -- and it renders
    -- whether or not the section is enabled, because it is the only way to switch
    -- a disabled one back on. Everything below the separator is the section's own
    -- controls, which the call site still gates on `is_enabled`.
    if selected then
        local setting_var = { enabled }
        if imgui.Checkbox(label .. '##' .. setting_name, setting_var) then
            set_section_enabled(ctx, setting_name, setting_var[1])
            enabled = setting_var[1]
        end
        imgui.Separator()
    end

    return selected, enabled
end

-- Open the container the sections render into. Pair with end_sections.
-- Resolves the mode ONCE per frame onto ctx: begin_section reads ctx.section_mode
-- and never the setting, so the frame cannot end in a different chrome than it
-- began in.
function ui_components.begin_sections(ctx)
    deferred_tabs = {}

    -- Give up on a selection request the target never came back to claim.
    if reselect_id then
        reselect_frames = reselect_frames - 1
        if reselect_frames <= 0 then
            reselect_id = nil
        end
    end

    if pending_display_mode then
        ctx.settings.display_mode = pending_display_mode
        pending_display_mode = nil
        if ctx.save_callback then
            ctx.save_callback()
        end
    end

    if ctx.settings.display_mode == 'tabs' then
        -- FittingPolicyScroll keeps every label full width -- ResizeDown truncates
        -- them on jobs with many sections, and a truncated label is unreadable at
        -- the widths 16 tabs produce.
        local bar_flags = ImGuiTabBarFlags_FittingPolicyScroll
        if autoselect_frames > 0 then
            autoselect_frames = autoselect_frames - 1
            bar_flags = bar_flags + ImGuiTabBarFlags_AutoSelectNewTabs
        end
        if imgui.BeginTabBar('##sk_sections', bar_flags) then
            ctx.section_mode = 'tabs'
            return
        end
        -- BeginTabBar refused (the window is clipped). Fall back to headers for
        -- this frame rather than rendering no sections at all.
    end

    ctx.section_mode = 'headers'
    reselect_id = nil
    autoselect_frames = 0
    selected_section = nil
    previous_section = nil
end

function ui_components.end_sections(ctx)
    if ctx.section_mode == 'tabs' then
        -- The disabled sections, in declaration order, after every enabled one.
        for _, tab in ipairs(deferred_tabs) do
            local selected = begin_tab_section(ctx, tab.label, tab.setting_name, tab.default_value)
            ui_components.item_tooltip(tab.tooltip)
            if selected then
                imgui.EndTabItem()
            end
        end
        imgui.EndTabBar()
    end
end

function ui_components.begin_section(ctx, label, setting_name, default_value)
    deferred_tooltip_target = nil
    tab_hovered = nil

    if ctx.section_mode ~= 'tabs' then
        return begin_header_section(ctx, label, setting_name, default_value)
    end

    -- Disabled sections are held back for end_sections, so the bar reads enabled
    -- tabs first and disabled ones after. Holding one back costs nothing: the call
    -- site gates its body on is_enabled, so a disabled tab's entire body is the
    -- enable checkbox begin_tab_section draws itself.
    if not section_enabled(ctx, setting_name, default_value) then
        deferred_tabs[#deferred_tabs + 1] =
            { label = label, setting_name = setting_name, default_value = default_value }
        deferred_tooltip_target = deferred_tabs[#deferred_tabs]
        return false, false
    end

    return begin_tab_section(ctx, label, setting_name, default_value)
end

-- EndTabItem is called only when BeginTabItem returned true, per ImGui's rules.
function ui_components.end_section(ctx, is_open)
    deferred_tooltip_target = nil
    tab_hovered = nil
    if ctx.section_mode == 'tabs' and is_open then
        imgui.EndTabItem()
    end
end

-- ============================================================================
-- Window Size Mode (auto-fit vs. custom drag-to-resize)
-- ============================================================================

-- Same one-frame defer, for the other chrome switch this window offers. The click
-- lands inside a window imgui.Begin has already opened, but the window's flags and
-- size constraints had to be settled before that Begin -- so the request is recorded
-- here and config.lua applies it at the top of the next frame.
local pending_window_size_mode = nil

-- Called by config.lua BEFORE imgui.Begin. Nothing needs re-applying on the frame the
-- mode flips: dropping AlwaysAutoResize leaves the window at the size the auto-fit had
-- just produced, which is exactly where the user wants to start dragging from.
function ui_components.apply_pending_window_size_mode(ctx)
    if not pending_window_size_mode then
        return
    end
    ctx.settings.window_size_mode = pending_window_size_mode
    pending_window_size_mode = nil
    if ctx.save_callback then
        ctx.save_callback()
    end
end

-- The window-body counterpart of render_display_mode_menu above: right-click on empty
-- space -- never on a widget, see POPUP_FLAGS_EMPTY_SPACE_ONLY -- offers the one sizing
-- mode the window is not in. Same shape as that menu: the current behaviour in gray, a
-- separator, then a single Selectable describing the switch. Submitted once per frame,
-- at the end of the window body.
function ui_components.render_window_size_menu(ctx)
    local to_custom = ctx.settings.window_size_mode ~= 'custom'
    if ui_components.begin_opaque_context_window('##cmenu_window_size') then
        imgui.TextColored(LIGHT_GRAY,
            to_custom and tooltips.window_size_auto_hint or tooltips.window_size_custom_hint)
        imgui.Separator()
        if imgui.Selectable(to_custom and 'Use a custom window size' or 'Fit window to contents') then
            pending_window_size_mode = to_custom and 'custom' or 'auto'
        end
        ui_components.end_opaque_popup()
    end
end

-- Create an integer input UI element linked to a setting, clamped to [min, max]
function ui_components.input_int(ctx, label, setting_name, ui_var, min, max, width)
    width = width or SLIDER_WIDTH
    imgui.PushItemWidth(width)
    if imgui.InputInt(label, ui_var) then
        ui_var[1] = math.max(min, math.min(max, ui_var[1]))
        ctx.settings[setting_name] = ui_var[1]
        if ctx.save_callback then
            ctx.save_callback()
        end
    end
    imgui.PopItemWidth()
end

-- Create an integer slider UI element linked to a setting
function ui_components.slider_int(ctx, label, setting_name, ui_var, min, max, width)
    width = width or SLIDER_WIDTH
    imgui.PushItemWidth(width)
    if imgui.SliderInt(label, ui_var, min, max) then
        ctx.settings[setting_name] = ui_var[1]
        if ctx.save_callback then
            ctx.save_callback()
        end
    end
    imgui.PopItemWidth()
end

-- Popup-class windows (expanded combo menus, right-click context menus, the
-- stratagem pickers) are readability surfaces: they ignore the window's
-- ui_opacity fade and render fully opaque however faded the window under them
-- is. The closed combo preview keeps the window alpha.
-- The popup's bg alpha must be armed BEFORE Begin* creates the popup window,
-- but ONLY when the popup will actually open: on a closed one the un-consumed
-- SetNextWindowBgAlpha leaks onto the next window begun (usually a tooltip,
-- which then kept a faded bg under opaque text). Open state is only known after
-- the call, so remember it per id from the previous frame -- the popup bg is
-- faded for its single first frame, which isn't perceptible.
local opaque_was_open = {}

local function arm_opaque_bg(id)
    if opaque_was_open[id] and imgui.GetStyle().Alpha < 1.0 then
        imgui.SetNextWindowBgAlpha(1.0)
    end
end

local function track_opaque_open(id, open)
    opaque_was_open[id] = open or nil
    if open then
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, 1.0)
    end
end

-- Called when the config window closes: a popup left open at close leaves a
-- stale was-open entry, which on the reopen's first frame would arm
-- SetNextWindowBgAlpha for a now-closed popup and leak it onto the next
-- window begun -- the exact leak the previous-frame tracking exists to stop.
function ui_components.reset_opaque_tracking()
    opaque_was_open = {}
end

-- Pair with end_opaque_combo (only when this returns true, per BeginCombo rules).
function ui_components.begin_opaque_combo(label, preview)
    arm_opaque_bg(label)
    local open = imgui.BeginCombo(label, preview)
    track_opaque_open(label, open)
    return open
end

function ui_components.end_opaque_combo()
    imgui.PopStyleVar()
    imgui.EndCombo()
end

-- BeginPopup / BeginPopupContextItem variants. Both close with end_opaque_popup.
function ui_components.begin_opaque_popup(popup_id)
    arm_opaque_bg(popup_id)
    local open = imgui.BeginPopup(popup_id)
    track_opaque_open(popup_id, open)
    return open
end

function ui_components.begin_opaque_context_item(popup_id)
    arm_opaque_bg(popup_id)
    local open = imgui.BeginPopupContextItem(popup_id)
    track_opaque_open(popup_id, open)
    return open
end

-- NoOpenOverItems is what keeps this menu off the section headers and tabs, which
-- carry the display-mode menu instead, and off every widget row that has a popup of
-- its own -- it opens on empty window space only.
local POPUP_FLAGS_EMPTY_SPACE_ONLY = ImGuiPopupFlags_MouseButtonRight + ImGuiPopupFlags_NoOpenOverItems

-- Right-click anywhere in the CURRENT window that is not a widget. Pair with
-- end_opaque_popup, same as the other two.
function ui_components.begin_opaque_context_window(popup_id)
    arm_opaque_bg(popup_id)
    local open = imgui.BeginPopupContextWindow(popup_id, POPUP_FLAGS_EMPTY_SPACE_ONLY)
    track_opaque_open(popup_id, open)
    return open
end

function ui_components.end_opaque_popup()
    imgui.PopStyleVar()
    imgui.EndPopup()
end

-- Create a combo dropdown UI element linked to a setting
function ui_components.combo(ctx, label, setting_name, ui_var, options, converter, width)
    width = width or SLIDER_WIDTH
    imgui.PushItemWidth(width)
    local current_value = options[ui_var[1] + 1] or options[1] or ""
    if ui_components.begin_opaque_combo(label, current_value) then
        for i = 0, #options - 1 do
            local is_selected = (ui_var[1] == i)
            if imgui.Selectable(options[i + 1], is_selected) then
                ui_var[1] = i
                if converter then
                    ctx.settings[setting_name] = converter(i)
                else
                    ctx.settings[setting_name] = i
                end
                if ctx.save_callback then
                    ctx.save_callback()
                end
            end
            if is_selected then
                imgui.SetItemDefaultFocus()
            end
        end
        ui_components.end_opaque_combo()
    end
    imgui.PopItemWidth()
end

-- Render an ability checkbox with spell knowledge checking
function ui_components.ability_checkbox(ctx, ability, job_def, id_suffix, show_stratagem)
    -- Scholar column before the checkbox: the E button (Enlightenment, on the rows
    -- Addendum: White gates -- Raise II here) or the stratagem S button. As in
    -- render_leading_slot the two never compete: E draws only on white rows in Dark
    -- Arts, where S is wrong-stance.
    local drew = show_stratagem and render_enlightenment_button(ability.name, ability, ctx)

    -- The S button only applies when the ability's magic matches the current arts
    -- stance; sections where NO spell qualifies get no column at all rather than a
    -- row of pointless spacers.
    if not drew and show_stratagem and ability.magic then
        local dominated = false
        if ability.magic == 'white' then
            dominated = common.has_buff(0, 358) or common.has_buff(0, 401) -- Light Arts / Addendum: White
        elseif ability.magic == 'black' then
            dominated = common.has_buff(0, 359) or common.has_buff(0, 402) -- Dark Arts / Addendum: Black
        end
        if dominated then
            drew = render_scholar_stratagem_button(ability.name, ability, ctx)
        end
    end

    -- While the E column is up, a row that drew neither button still needs the indent
    -- so Raise lines up under Raise II's [E].
    if not drew and show_stratagem and ability.magic and enlightenment_column_strat(ctx) then
        render_slot_spacer()
    end

    -- DRK Nether Void [N] button on Drain/Drain II/Aspir rows (self-gates via the
    -- nether_void flag; draws nothing for every other ability).
    render_nether_void_button(ability.name, ability, ctx)

    local has_spell = common.has_spell_learned(ability)
    -- Ammo-gated abilities (BST Reward, PUP Repair) can't fire with none of the
    -- consumable in inventory/storage. Show them grayed like an unlearned spell.
    local no_ammo = ability.requires_equipped_ammo
        and common.count_equippable_items(ability.requires_equipped_ammo) == 0
    local wrong_pet = pet_type_unmet(ability)
    -- Blue magic not in the set-spell list: gray the row but keep it
    -- selectable -- equipping the spell is up to the user, automation just
    -- skips it (filter_abilities_by_level) until it's set.
    local blue_unequipped = common.is_blue_magic_unequipped(ability)
    local buff_unmet = requires_buff_unmet(ability, ctx)
    local spell_suffix = ''
    -- NOTE: an unlearned spell grays the row but must NOT write disabled_<name>.
    -- HasSpell reads false for every spell during a zone-in until the spell list
    -- repopulates, and the level is already back by then (is_loading() is false),
    -- so writing here deselected every cure on a zone. No write is needed anyway:
    -- filter_abilities_by_level drops unlearned abilities on its own. Same policy
    -- as the other gray-but-keep-selected rows (no ammo / wrong pet / BLU unset).

    local desc
    if ability.cost and ability.cost > 0 then
        local resource_label = (ability.resource_type or job_def.resource_type) == 'tp' and 'TP' or 'MP'
        local display_cost = common.effective_ability_cost(ability, ctx.settings, job_def)
        desc = ability.name .. ' (' .. display_cost .. ' ' .. resource_label .. ')' .. spell_suffix
    else
        desc = ability.name .. spell_suffix
    end
    
    local checkbox_label = desc
    if id_suffix then
        checkbox_label = desc .. '##' .. id_suffix
    end
    
    local ability_combat_only = effective_combat_only(ability, ctx)
    local ability_idle_only = common.is_ability_idle_only(ability, ctx.settings)
    if not has_spell or no_ammo or wrong_pet or blue_unequipped or buff_unmet then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif ability_combat_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_YELLOW)
    elseif ability_idle_only then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GREEN)
    end

    -- No consumable owned (no_ammo): show the box unchecked AND ignore clicks so
    -- it reads as disabled and can't be enabled. Non-destructive: the saved
    -- setting is untouched and restores once the consumable is back.
    local ability_enabled = { is_ability_enabled(ctx, ability.name) and not no_ammo }
    if imgui.Checkbox(checkbox_label, ability_enabled) and not no_ammo then
        toggle_ability(ctx, ability.name, ability_enabled[1], job_def)
    end

    render_combat_only_context_menu(ctx, ability, id_suffix)

    if imgui.IsItemHovered() then
        if not has_spell then
            ui_components.set_tooltip('Not Learned')
        elseif blue_unequipped then
            ui_components.set_tooltip('Blue Magic not currently equipped')
        elseif no_ammo then
            ui_components.set_tooltip('No ' .. (ability.ammo_label or 'item') .. ' found in storage.')
        elseif wrong_pet then
            ui_components.set_tooltip(pet_type_tooltip(ability))
        elseif buff_unmet then
            ui_components.set_tooltip('Prerequisite buff not active')
        elseif ability_combat_only then
            ui_components.set_tooltip('Combat Only')
        elseif ability_idle_only then
            ui_components.set_tooltip('Idle Only')
        elseif ctx.show_pet_debuff_warning then
            ui_components.set_tooltip('Pet Debuff Removal is not totally reliable')
        end
    end

    if not has_spell or no_ammo or wrong_pet or blue_unequipped or buff_unmet or ability_combat_only or ability_idle_only then
        imgui.PopStyleColor()
    end
end

-- ============================================================================
-- Item Checkbox Component
-- ============================================================================

-- Render a checkbox for item-based debuff removal (DRY helper)
-- Args: ctx, entry (an item_module.REMOVALS row: item_id/item_name/setting_key/debuff_name)
local function render_item_removal_checkbox(ctx, entry)
    if not ctx or not ctx.settings then return end

    local item_name   = entry.item_name
    local setting_key = entry.setting_key
    local debuff_name = entry.debuff_name
    local count = item_module.get_item_count(entry.item_id)

    -- Build label with count (show ? while inventory loads)
    local checkbox_label
    if count == nil then
        checkbox_label = string.format('%s with %s (?)', debuff_name, item_name)
    else
        checkbox_label = string.format('%s with %s (%d)', debuff_name, item_name, count)
    end

    local is_disabled = (count == 0)

    -- Auto-disable when inventory is loaded but item count is zero
    if is_disabled and count ~= nil and ctx.settings[setting_key] then
        ctx.settings[setting_key] = false
        if ctx.save_callback then ctx.save_callback() end
    end

    -- Disabled styling
    if is_disabled then
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
        imgui.PushStyleColor(ImGuiCol_FrameBg, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_FrameBgActive, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_CheckMark, LIGHT_GRAY)
    end

    local enabled = { ctx.settings[setting_key] or false }

    if not is_disabled and imgui.Checkbox(checkbox_label, enabled) then
        ctx.settings[setting_key] = enabled[1]
        if ctx.save_callback then ctx.save_callback() end
    elseif is_disabled then
        imgui.Checkbox(checkbox_label, enabled)
    end

    if is_disabled then imgui.PopStyleColor(5) end

    if imgui.IsItemHovered() then
        local tooltip_text
        if is_disabled then
            tooltip_text = string.format('No %s in inventory', item_name)
        else
            tooltip_text = string.format('Use %s to remove %s', item_name, debuff_name)
        end
        ui_components.set_tooltip(tooltip_text)
    end
end

-- True once inventory is readable (used to hide the Item Removal section while
-- counts are still unknown "?" rather than a real 0).
function ui_components.item_inventory_loaded()
    return item_module.inventory_loaded()
end

-- Render one checkbox per item-removal definition (driven by item.REMOVALS).
function ui_components.item_removal_checkboxes(ctx)
    for _, entry in ipairs(item_module.REMOVALS) do
        render_item_removal_checkbox(ctx, entry)
    end
end

-- ============================================================================
-- Party Selection Buttons (for status removal targeting)
-- ============================================================================

-- One toggle button in a target-selection row, shared by render_party_selection
-- and render_heal_group_selection. `id` is the full ##suffix. A non-nil
-- `disabled_reason` grays the button, swallows its click, and is appended to the
-- tooltip (which falls back to the label) as the line explaining why.
local function draw_toggle(label, id, on, on_click, tooltip, disabled_reason)
    if disabled_reason then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_DISABLED)
        imgui.PushStyleColor(ImGuiCol_Text, LIGHT_GRAY)
    elseif not on then
        imgui.PushStyleColor(ImGuiCol_Button, COLOR_BUTTON_UNSELECTED)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLOR_BUTTON_UNSELECTED_HOVER)
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLOR_BUTTON_UNSELECTED_ACTIVE)
    end
    if imgui.Button(label .. '##' .. id, { PARTY_BUTTON_WIDTH, 0 }) and not disabled_reason then
        on_click()
    end
    if imgui.IsItemHovered() then
        if disabled_reason then
            ui_components.set_tooltip((tooltip or label) .. '\n' .. disabled_reason)
        elseif tooltip then
            ui_components.set_tooltip(tooltip)
        end
    end
    if disabled_reason then imgui.PopStyleColor(4)
    elseif not on then imgui.PopStyleColor(3) end
end

-- Render party selection buttons for a feature (debuff removal, wake, etc.)
-- Provides a row of [ME] [P1] [P2]... [B0] [C0]... [T1]... toggle buttons.
-- Reuses ctx.party_buffs[key_name][party_index] for state storage.
-- Auto-initialises all current party members as enabled on first render.
-- Args:
--   ctx          - UI context (settings, save_callback, party_buffs, is_trust)
--   key_name     - Key in party_buffs (e.g. "debuff_removal", "wake")
--   show_outside - Whether to show alliance/tracked target buttons
--   include_self - Whether to show the [ME] button (default true)
-- Returns: true if any button was rendered
function ui_components.render_party_selection(ctx, key_name, show_outside, include_self)
    if include_self == nil then include_self = true end

    -- Auto-initialise on first render: enable all current party members
    if not ctx.party_buffs[key_name] then
        ctx.party_buffs[key_name] = {}
        if include_self then
            ctx.party_buffs[key_name][0] = true
        end
        local ps = common.get_party_size()
        for i = 1, math.min(ps - 1, 5) do
            ctx.party_buffs[key_name][i] = true
        end
        -- Persist
        ctx.settings.party_buffs = ctx.settings.party_buffs or {}
        ctx.settings.party_buffs[key_name] = {}
        for k, v in pairs(ctx.party_buffs[key_name]) do
            if type(k) == 'number' and k <= 5 then
                ctx.settings.party_buffs[key_name][k] = v
            end
        end
        if ctx.save_callback then ctx.save_callback() end
    end

    local function is_sel(index)
        return ctx.party_buffs[key_name][index] == true
    end

    local function toggle_sel(index, enabled)
        ctx.party_buffs[key_name][index] = enabled
        if type(index) == 'number' and index <= 5 then
            ctx.settings.party_buffs = ctx.settings.party_buffs or {}
            ctx.settings.party_buffs[key_name] = ctx.settings.party_buffs[key_name] or {}
            ctx.settings.party_buffs[key_name][index] = enabled
        end
        if ctx.save_callback then ctx.save_callback() end
    end

    local any_rendered = false

    -- Every button here toggles one key of the same table; only label/id and
    -- tooltip differ.
    local function draw(label, id, sel_key, tooltip, disabled_reason)
        local on = is_sel(sel_key)
        draw_toggle(label, key_name .. '_sel_' .. id, on,
            function() toggle_sel(sel_key, not on) end, tooltip, disabled_reason)
        any_rendered = true
    end

    -- [ME] button
    if include_self then
        draw('ME', 'me', 0)
    end

    -- P1-P5 buttons
    local party_size = common.get_party_size()
    if party_size > 1 then
        for pi = 1, 5 do
            if pi < party_size then
                if any_rendered then imgui.SameLine() end
                -- Damage-immune trusts (Moogle, Kupofried, ...) are immune to
                -- status too, so they can never be a removal target -- lock the
                -- button rather than let it be switched on and do nothing.
                local pm = common.game_state and common.game_state.party[pi]
                local is_excluded = pm and common.is_trust_excluded(pm.name, pm.server_id)
                local trust_tip = ctx.is_trust and ctx.is_trust(pi)
                    and 'Trust/Tracked Removal is not totally reliable' or nil
                draw('P' .. pi, 'p' .. pi, pi,
                    is_excluded and pm.name or trust_tip,
                    is_excluded and 'Cannot be given a status ailment' or nil)
            end
        end
    end

    -- Alliance buttons
    if show_outside then
        local al_gs = common.game_state
        if al_gs and al_gs.alliance then
            local alliance_prefixes = { [2] = 'B', [3] = 'C' }
            for api = 2, 3 do
                local sub_party = al_gs.alliance[api]
                if sub_party and next(sub_party) ~= nil then
                    local prefix = alliance_prefixes[api]
                    local sorted_al = common.sorted_alliance_members(sub_party)
                    for _, entry in ipairs(sorted_al) do
                        local local_idx = entry.local_idx
                        local m = entry.m
                        local flat_index = (api - 1) * 6 + local_idx
                        local al_key = 'al_' .. flat_index

                        if any_rendered then imgui.SameLine() end
                        draw(prefix .. local_idx, al_key, al_key, m.name or (prefix .. local_idx))
                    end
                end
            end
        end

        -- Tracked target buttons
        local tracked_list = common.get_tracked_targets()
        local sorted_tracked = {}
        for sid, tt in pairs(tracked_list) do
            table.insert(sorted_tracked, { sid = sid, name = tt.name })
        end
        table.sort(sorted_tracked, function(a, b) return a.name < b.name end)
        for t_idx, tt in ipairs(sorted_tracked) do
            if any_rendered then imgui.SameLine() end
            -- Always show warning tooltip for tracked targets
            draw('T' .. t_idx, 't' .. tt.sid, 'tt_' .. tt.sid,
                tt.name .. '\nTrust/Tracked Removal is not totally reliable')
        end
    end

    return any_rendered
end

-- Render group-target selection buttons for Group / AOE healing.
-- Unlike render_party_selection (wake/debuff) this is SESSION-ONLY (never
-- persisted) and uses asymmetric defaults so the behaviour is correct even
-- when the config window was never opened this session:
--   ME / party / tracked -> ON  by default (included unless explicitly disabled)
--   alliance (B/C)        -> OFF by default (excluded unless explicitly enabled)
-- State lives in ctx.party_buffs[key_name]; heal.lua reads it via the same keys.
-- show_outside: whether to draw alliance + tracked buttons (Group=true, AOE=false;
-- AOE healing is party-scoped so out-of-party buttons would do nothing).
function ui_components.render_heal_group_selection(ctx, key_name, show_outside)
    ctx.party_buffs[key_name] = ctx.party_buffs[key_name] or {}
    local state = ctx.party_buffs[key_name]

    -- party/tracked default ON (~= false); alliance default OFF (== true)
    local function is_sel(key, is_alliance)
        if is_alliance then return state[key] == true end
        return state[key] ~= false
    end

    local function draw(label, id, on, on_click, tooltip, disabled)
        draw_toggle(label, key_name .. '_gsel_' .. id, on, on_click, tooltip,
            disabled and 'Trust cannot take any damage' or nil)
    end

    -- [ME]
    do
        local on = is_sel(0)
        draw('ME', 'me', on, function() state[0] = not on end)
    end

    -- P1-P5
    local party_size = common.get_party_size()
    for pi = 1, 5 do
        if pi < party_size then
            imgui.SameLine()
            local on = is_sel(pi)
            local pname = common.get_party_member_name(pi)
            local pm = common.game_state and common.game_state.party[pi]
            draw('P' .. pi, 'p' .. pi, on, function() state[pi] = not on end,
                pname, pm and common.is_trust_excluded(pm.name, pm.server_id))
        end
    end

    if not show_outside then return true end

    -- Alliance B/C
    local gs = common.game_state
    if gs and gs.alliance then
        local prefixes = { [2] = 'B', [3] = 'C' }
        for api = 2, 3 do
            local sub = gs.alliance[api]
            if sub and next(sub) ~= nil then
                for _, entry in ipairs(common.sorted_alliance_members(sub)) do
                    local al_key = 'al_' .. ((api - 1) * 6 + entry.local_idx)
                    imgui.SameLine()
                    local on = is_sel(al_key, true)
                    draw(prefixes[api] .. entry.local_idx, al_key, on,
                        function() state[al_key] = not on end, entry.m.name)
                end
            end
        end
    end

    -- Tracked targets
    local sorted = {}
    for sid, tt in pairs(common.get_tracked_targets()) do
        table.insert(sorted, { sid = sid, name = tt.name })
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    for t_idx, tt in ipairs(sorted) do
        imgui.SameLine()
        local tt_key = 'tt_' .. tt.sid
        local on = is_sel(tt_key)
        draw('T' .. t_idx, 't' .. tt.sid, on, function() state[tt_key] = not on end, tt.name)
    end

    return true
end

-- ============================================================================
-- Settings Profiles popup
-- Job-line button labeled with the active profile ('Default' when none).
-- Clicking opens a panel: name field, [New][Save][Save As][Delete], and a
-- Selectable list for the current combo. Clicking a list entry loads it and
-- keeps the panel open so a rename can follow. Ops come from lib/ui/config.lua.
-- ============================================================================

-- Typed profile name; session-only. Refilled from the active profile when the
-- popup opens and from list clicks afterward.
local profile_name_buf = { '' }

function ui_components.render_profile_button(ctx, ops)
    local popup_id = '##profiles_popup'
    local active = ops.active(ctx)

    -- Fixed width, same as the Start/Stop button; long names clip.
    if imgui.Button((active or 'Default') .. '##profiles_btn', { AUTOMATION_BUTTON_WIDTH, 0 }) then
        profile_name_buf[1] = active or ''
        imgui.OpenPopup(popup_id)
    end
    if imgui.IsItemHovered() then
        ui_components.set_tooltip('Settings profiles for this job/subjob combo.\n' ..
            'Save named snapshots of the current settings and load them later.\n' ..
            'Tweaks after a load auto-save to the working copy, never to the profile.')
    end

    if ui_components.begin_opaque_popup(popup_id) then
        imgui.PushItemWidth(238)
        imgui.InputText('##profile_name', profile_name_buf, 64)
        imgui.PopItemWidth()

        local typed = profile_name_buf[1]:match('^%s*(.-)%s*$')

        if imgui.Button('New##profile_new') then
            ops.new(ctx)
            profile_name_buf[1] = ''
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Reset the working copy to job defaults.\nSaved profiles are kept.')
        end
        imgui.SameLine()
        if imgui.Button('Save##profile_save') then
            ops.save(ctx, typed)
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Save current settings under this name.\n' ..
                'With a profile selected and the name edited: rename it instead.')
        end
        imgui.SameLine()
        if imgui.Button('Save As##profile_save_as') then
            ops.save_as(ctx, typed)
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Always save current settings under this name,\noverwriting any profile already using it.')
        end
        imgui.SameLine()
        if imgui.Button('Delete##profile_delete') then
            if active then
                ops.delete(ctx, active)
                profile_name_buf[1] = ''
            end
        end
        if imgui.IsItemHovered() then
            ui_components.set_tooltip('Delete the selected (highlighted) profile.')
        end

        local names = {}
        for name in pairs(ops.list(ctx)) do
            -- ops.DEFAULT_SLOT is the parked Default working copy, not a named profile.
            if name ~= ops.DEFAULT_SLOT then
                table.insert(names, name)
            end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        -- List-box style: bordered child sized to the row count (+1 for the
        -- Default row, +16 for the border padding) so every profile is always
        -- visible without scrolling. The popup auto-sizes around it.
        local list_height = (#names + 1) * imgui.GetTextLineHeightWithSpacing() + 16
        imgui.BeginChild('##profile_list', { 0, list_height }, true)
        -- 'Default' always heads the list: the auto-saving working copy, parked
        -- while a named profile is active. Selecting it restores that copy.
        if imgui.Selectable('Default##profile_default', active == nil,
                ImGuiSelectableFlags_DontClosePopups) then
            ops.load_default(ctx)
            profile_name_buf[1] = ''
        end
        for _, name in ipairs(names) do
            -- DontClosePopups: a load keeps the panel open so a rename can follow.
            if imgui.Selectable(name .. '##profile_' .. name, name == active,
                    ImGuiSelectableFlags_DontClosePopups) then
                ops.load(ctx, name)
                profile_name_buf[1] = name
            end
        end
        imgui.EndChild()

        ui_components.end_opaque_popup()
    end
end

-- ============================================================================
-- Export Constants
-- ============================================================================

ui_components.ABILITY_LIST_INDENT = ABILITY_LIST_INDENT
ui_components.AUTOMATION_BUTTON_WIDTH = AUTOMATION_BUTTON_WIDTH
ui_components.LIGHT_GREEN = LIGHT_GREEN
ui_components.LIGHT_BLUE = LIGHT_BLUE
ui_components.LIGHT_RED = LIGHT_RED
ui_components.LIGHT_YELLOW = LIGHT_YELLOW
ui_components.LIGHT_GRAY = LIGHT_GRAY

-- ============================================================================
-- Exports for the web UI bridge (lib/core/webui.lua)
-- ============================================================================
-- A row toggled from the browser must land on exactly the same code path as a
-- click in game: the song limit, exclusive Geo targets and the disabled_ key
-- sync all live in here, and a second implementation of them would drift.

function ui_components.toggle_ability(ctx, ability_name, enabled)
    toggle_ability(ctx, ability_name, enabled, ctx.job_def)
end

function ui_components.toggle_group(ctx, group_name, enabled)
    toggle_group(ctx, group_name, enabled)
end

function ui_components.toggle_party_buff(ctx, ability_name, party_index, enabled)
    toggle_party_buff(ctx, ability_name, party_index, enabled)
end

function ui_components.toggle_group_party_buff(ctx, group_name, party_index, enabled)
    toggle_group_party_buff(ctx, group_name, party_index, enabled)
end

return ui_components
