--[[
Sidekick - Support Job Automation Framework
Copyright (c) 2025 Seekey
https://github.com/seekey13/Sidekick

This addon is designed for Ashita v4 and the CatsEyeXI private server.

Main addon file: job detection, event loop, command handler
]]--

addon.name      = 'Sidekick'
addon.author    = 'Seekey'
addon.version   = '2.8.0'
addon.desc      = 'Support Job Automation Framework'
addon.link      = 'https://github.com/seekey13/Sidekick'

require('common')
local chat = require('chat')
local settings = require('settings')
local imgui = require('imgui')

-- Load core modules
local common = require('lib.core.common')
local action_core = require('lib.core.action_core')
local automation = require('lib.core.automation')
local parse_packets = require('lib.core.parse_packets')
local afk = require('lib.core.afk')
local party_share = require('lib.core.party_share')  -- Shared party list (publish + tracked-target sync)
local webui = require('lib.core.webui')  -- Web UI bridge (/sk webui)
local vanadiel = require('lib.core.vanadiel')  -- Weather/day readers + enspell element auto-select

-- Load action modules
local heal_mod   = require('lib.actions.heal')
local status_mod = require('lib.actions.status_removal')
local roll_mod   = require('lib.actions.roll')  -- also reads roll totals off the 0x028 packet
local pet_mod = require('lib.actions.pet')  -- Pet Control: PUP maneuver upkeep + PUP/SMN/BST send-pet-at-target

local action_modules = {
    item           = require('lib.actions.item'),
    heal           = heal_mod,
    heal_aoe       = { execute = heal_mod.execute_aoe },
    heal_pet       = { execute = heal_mod.execute_pet },
    wake           = { execute = status_mod.execute_wake },
    debuff_removal = { execute = status_mod.execute_debuff_removal },
    pet_debuff_removal = { execute = status_mod.execute_pet_debuff_removal },
    roll           = roll_mod,
    maneuver       = { execute = pet_mod.execute_maneuver },
    pet_control     = { execute = pet_mod.execute_deploy },
    buff           = require('lib.actions.buff'),
    recover        = require('lib.actions.recover'),
    geo            = require('lib.actions.geo'),
    rest           = require('lib.actions.rest'),
    revive         = require('lib.actions.revive'),
    follow         = require('lib.actions.follow'),
}

-- Load config UI
local ui_config = require('lib.ui.config')
local ui_panel  = require('lib.ui.panel')

-- State
local current_main_job_id = nil
local current_sub_job_id = nil
-- '<Name>_<ServerId>' of the character addon_settings/job_def are currently
-- loaded for -- see setup_job's character-switch guard.
local current_character_key = nil
local job_def = nil  -- Merged job definition
local addon_settings = nil
local is_loaded = false
local automation_enabled = false
local last_job_id = nil
local last_sub_job_id = nil
local last_level = nil
local last_unsupported_warning = nil  -- Track last unsupported job warning to prevent spam

-- Default address for webui_url (below). This is where wrangler.jsonc deploys
-- the web app, so it is the same for everyone rather than something each player
-- has to be told.
-- /sk webui url still exists for anyone hosting their own copy elsewhere.
local DEFAULT_WEBUI_URL = 'https://sidekick.xiim-app.workers.dev'

-- Settings file path
local default_settings = T{
    automation_enabled = false,
    -- Start-button right-click menu. Both opt-in.
    load_stopped = false,     -- Ignore the saved automation state and load stopped.
    stop_after_zone = false,  -- Stop automation on zone change.
    focus_enabled = false,
    focus_target = nil,
    attack_range = 'Off',
    -- Leader following (job-independent), opt-in so it never moves you on upgrade.
    follow_enabled = false,
    follow_distance = 5,
    -- false = native Auto Follow; true = Multisend attack-range follow (see /sk panel).
    multisend_follow = false,
    -- Hold AOE (Protectra/Shellra/Bar, area songs, Phantom Rolls, Accession/
    -- Diffusion) until every alive, in-zone party member is in range. Opt-in;
    -- per-job-file like every setting, so flipping it on one job doesn't sync.
    hold_aoe_for_group = false,
    -- Gear-based heal potency bonuses (job-independent, set from /sk panel).
    -- +x% applied to each heal ability's base `value` when sizing to missing HP.
    cure_potency = 0,   -- MP heals (Cure spells, Blue Magic cures)
    waltz_potency = 0,  -- TP heals (DNC Waltzes)
    -- AFK Sleep (job-independent). Default-on: it only stops automation from acting.
    afk_enabled = true,
    afk_timeout = 600,  -- Seconds of no party movement and no combat before sleeping.
    -- Resting (/heal). Inert unless the job is MP-based and lists 'rest' in its
    -- priority_order, so these live here rather than in each MP job's defaults.
    rest_enabled = false,
    rest_timer = 5,
    rest_distance = 7,
    -- Main config sections render either as a stack of collapsing headers or as
    -- one row of tabs -- never both. Switched from the right-click menu on any
    -- header or tab. 'headers' | 'tabs'.
    display_mode = 'headers',
    -- Config window sizing. 'auto' pins the window to its contents -- instant, but the
    -- resize grip is off. 'custom' is a plain window: drag it to any size and the
    -- contents scroll when they overflow. Switched from the right-click menu on empty
    -- window space. The size itself is deliberately NOT stored here -- ImGui already
    -- persists this window's size and position in its own imgui.ini, which is what
    -- keeps it where the user left it across job changes. 'auto' | 'custom'.
    window_size_mode = 'auto',
    -- Config window opacity (job-independent). 1-100, set from /sk panel.
    ui_opacity = 100,
    -- Whether the config window was open when the addon last unloaded; reopened on load.
    ui_open = false,
    -- Same, for the floating widget (/sk widget).
    widget_open = false,
    -- Web UI bridge (/sk webui). Off by default: it writes a snapshot of this
    -- character's config to disk for the browser to read, which nobody who has
    -- not asked for it should be paying for.
    webui_enabled = false,
    -- Address /sk webui open launches. Per-character (not global) so anyone
    -- running their own copy of the worker can point it somewhere else.
    webui_url = DEFAULT_WEBUI_URL,
}

-- Range management state
local range_state = {
    follow_enabled = false,  -- Track current multisend follow state
    last_check = 0,          -- Timestamp of last range check
}

--[[
    Job Loading
]]--

local function load_single_job_definition(job_id)
    -- Map job IDs to job definition files
    local job_map = {
        [1] = 'warrior',      -- Warrior
        [2] = 'monk',         -- Monk
        [3] = 'white_mage',   -- White Mage
        [4] = 'black_mage',   -- Black Mage
        [5] = 'red_mage',     -- Red Mage
        [6] = 'thief',        -- Thief
        [7] = 'paladin',      -- Paladin
        [8] = 'dark_knight',  -- Dark Knight
        [9] = 'beastmaster',  -- Beastmaster
        [10] = 'bard',        -- Bard
        [11] = 'ranger',      -- Ranger
        [12] = 'samurai',     -- Samurai
        [13] = 'ninja',       -- Ninja
        [14] = 'dragoon',     -- Dragoon
        [15] = 'summoner',    -- Summoner
        [16] = 'blue_mage',   -- Blue Mage
        [17] = 'corsair',     -- Corsair
        [18] = 'puppetmaster',-- Puppetmaster
        [19] = 'dancer',      -- Dancer
        [20] = 'scholar',     -- Scholar
        [21] = 'geomancer',   -- Geomancer
        [22] = 'rune_fencer', -- Rune Fencer
    }
    
    local job_name = job_map[job_id]
    if not job_name then
        return nil
    end
    
    local success, job_module = pcall(require, 'lib.jobs.' .. job_name)
    if not success then
        common.errorf('Failed to load job definition for %s: %s', job_name, tostring(job_module))
        return nil
    end
    
    return job_module
end

local function merge_abilities(main_abilities, sub_abilities, main_def, sub_def)
    -- Start with main job abilities
    local merged = T{}

    -- Effective (capped) subjob level; gates the requires_buff clearing below.
    local _, sub_level = common.get_player_level()
    sub_level = sub_level or 0
    
    common.debugf('[merge_abilities] Starting merge (main_def=%s, sub_def=%s)', 
        main_def and main_def.job_name or 'nil', sub_def and sub_def.job_name or 'nil')
    
    -- Deep copy main job abilities and mark them
    for category, abilities in pairs(main_abilities) do
        merged[category] = T{}
        for _, ability in ipairs(abilities) do
            local ability_copy = T{}
            for k, v in pairs(ability) do
                ability_copy[k] = v
            end
            ability_copy.is_main_job = true
            -- Add resource type from main job definition
            if main_def then
                ability_copy.resource_type = main_def.resource_type
            end
            table.insert(merged[category], ability_copy)
        end
    end
    
    -- Add sub job abilities and mark them
    if sub_abilities then
        for category, abilities in pairs(sub_abilities) do
            if not merged[category] then
                merged[category] = T{}
            end
            for _, ability in ipairs(abilities) do
                -- Check if this ability already exists in main job (skip duplicates)
                local is_duplicate = false
                if merged[category] then
                    for _, main_ability in ipairs(merged[category]) do
                        if main_ability.name == ability.name and main_ability.is_main_job == true then
                            is_duplicate = true
                            -- Subjob supplies this spell without the main job's buff
                            -- prerequisite (SCH/WHM Poisona/Raise, no Addendum: White),
                            -- but only if the sub can actually cast it at its level.
                            if main_ability.requires_buff and not ability.requires_buff
                                and sub_level >= (ability.level or 0) then
                                main_ability.requires_buff = nil
                            end
                            break
                        end
                    end
                end
                
                -- Only add if not a duplicate
                if not is_duplicate then
                    local ability_copy = T{}
                    for k, v in pairs(ability) do
                        ability_copy[k] = v
                    end
                    ability_copy.is_main_job = false
                    -- Add resource type from sub job definition
                    if sub_def then
                        ability_copy.resource_type = sub_def.resource_type
                    end
                    table.insert(merged[category], ability_copy)
                end
            end
        end
    end
    
    return merged
end

local function load_job_definition(main_job_id, sub_job_id)
    local main_def = load_single_job_definition(main_job_id)
    local sub_def = nil
    if sub_job_id and sub_job_id > 0 then
        sub_def = load_single_job_definition(sub_job_id)
    end
    
    -- Check if at least one job is supported
    if not main_def and not sub_def then
        -- Only display warning once per job combination
        local warning_key = string.format('%d_%d', main_job_id, sub_job_id or 0)
        if last_unsupported_warning ~= warning_key then
            local main_name = common.get_job_name(main_job_id)
            local error_msg = 'No automation available for ' .. main_name
            if sub_job_id and sub_job_id > 0 then
                error_msg = error_msg .. '/' .. common.get_job_name(sub_job_id)
            end
            common.warnf(error_msg)
            last_unsupported_warning = warning_key
        end
        return nil
    end
    
    -- Create merged job definition
    local merged_def = T{}
    
    -- Use whichever job is available as the primary source
    local primary_def = main_def or sub_def
    local secondary_def = main_def and sub_def or nil
    
    -- Copy primary job properties
    merged_def.job_id = primary_def.job_id
    merged_def.resource_type = primary_def.resource_type
    merged_def.validators = primary_def.validators
    merged_def.validate_ability = primary_def.validate_ability
    
    -- Merge priority_order: use master list order, include actions from both jobs
    -- Master priority order (defines the execution sequence)
    local master_priority = {
        'item',
        'recover',
        'critical',
        'heal_aoe',
        'heal',
        'debuff_removal',
        'heal_pet',
        'pet_debuff_removal',
        'pet_control',
        'wake',
        'geo',
        'maneuver',
        'roll',
        'buff',
        'revive',
        'follow',
        'rest',
    }
    
    -- Collect all actions from both jobs
    local available_actions = {}
    if primary_def.priority_order then
        for _, action in ipairs(primary_def.priority_order) do
            available_actions[action] = true
        end
    end
    if secondary_def and secondary_def.priority_order then
        for _, action in ipairs(secondary_def.priority_order) do
            available_actions[action] = true
        end
    end

    -- Follow is job-independent: inject once instead of into every job's priority_order.
    available_actions['follow'] = true

    -- Build merged priority_order using master list order
    merged_def.priority_order = T{}
    for _, action in ipairs(master_priority) do
        if available_actions[action] then
            table.insert(merged_def.priority_order, action)
        end
    end
    
    -- Build combined job name
    local job_name = ''
    if main_def then
        job_name = main_def.job_name
        if sub_def then
            job_name = job_name .. '/' .. sub_def.job_name
        elseif sub_job_id and sub_job_id > 0 then
            job_name = job_name .. '/' .. common.get_job_name(sub_job_id)
        end
    else
        -- Only sub job is supported
        job_name = common.get_job_name(main_job_id) .. '/' .. sub_def.job_name
    end
    merged_def.job_name = job_name
    
    -- Merge abilities from both jobs
    local main_abilities = main_def and main_def.abilities or {}
    local sub_abilities = sub_def and sub_def.abilities or {}
    merged_def.abilities = merge_abilities(main_abilities, sub_abilities, main_def, sub_def)

    -- Flag whether this job (main or sub) has song magic. The buff UI shows the
    -- bard [A] area column when it does, and every non-song row indents under it.
    for _, list in pairs(merged_def.abilities) do
        if type(list) == 'table' then
            for _, ab in ipairs(list) do
                if ab.magic == 'song' then merged_def.has_songs = true end
            end
        end
    end

    -- Merge default_settings (main job takes priority if both exist)
    merged_def.default_settings = T{}
    if sub_def and sub_def.default_settings then
        for key, value in pairs(sub_def.default_settings) do
            if type(value) == 'table' then
                merged_def.default_settings[key] = T(value)
            else
                merged_def.default_settings[key] = value
            end
        end
    end
    if main_def and main_def.default_settings then
        for key, value in pairs(main_def.default_settings) do
            if type(value) == 'table' then
                merged_def.default_settings[key] = T(value)
            else
                merged_def.default_settings[key] = value
            end
        end
    end
    
    common.printf('Loaded job definition: %s', job_name)
    
    return merged_def
end

-- Returns the entity_status of a member by server_id from the current game_state snapshot.
-- Checks player, party, tracked targets, and alliance. Returns -1 if not found.
local function get_entity_status_in_gs(server_id)
    if not server_id or server_id == 0 then return -1 end
    local gs = common.game_state
    if not gs then return -1 end
    for i = 0, 5 do
        local m = i == 0 and gs.player or gs.party[i]
        if m and m.server_id == server_id then return m.entity_status or -1 end
    end
    if gs.tracked and gs.tracked[server_id] then
        return gs.tracked[server_id].entity_status or -1
    end
    if gs.alliance then
        for al_pi = 2, 3 do
            if gs.alliance[al_pi] then
                for _, m in pairs(gs.alliance[al_pi]) do
                    if m and m.server_id == server_id then return m.entity_status or -1 end
                end
            end
        end
    end
    return -1
end

local function setup_job()
    local main_job_id, sub_job_id = common.get_player_job()
    
    -- Ignore invalid job IDs (happens during zoning)
    if not main_job_id or main_job_id == 0 then
        return
    end

    -- Guard against transient sub_job=0 during zone transitions.
    if sub_job_id == 0 and current_sub_job_id and current_sub_job_id > 0 and job_def then
        return
    end
    
    -- Same job/subjob is not the same CHARACTER: switching at character select
    -- between two characters who happen to share a job (and are at the same
    -- level) looks identical to "already loaded" by job ids alone, which would
    -- leave addon_settings/job_def bound to the PREVIOUS character while the
    -- game is now running the new one. character_key is the same
    -- '<Name>_<ServerId>' identity webui.tick uses to pick a character's own
    -- state.json folder -- without this check the web UI would show and let
    -- the player edit character B's config under character A's name.
    --
    -- current_character_key starts nil, and character_key() itself reads nil
    -- until the first refresh_game_state() populates game_state.player. That
    -- refresh hasn't happened yet the first time setup_job runs after a load,
    -- since setup_job runs before automation_tick/render/panel/follow_tick in
    -- d3d_present. So the first real observation is nil -> <key>: a SEED, not
    -- a character change, and requiring both sides non-nil is what keeps it
    -- from being treated as one (a mid-zone nil on either side is excluded
    -- the same way). The tracker is still recorded on this pass -- via the
    -- unconditional assignment below -- so the seed sticks for next frame's
    -- comparison instead of comparing nil -> key again forever.
    local character_key = webui.character_key()
    local previous_character_key = current_character_key
    local character_changed = character_key ~= nil and current_character_key ~= nil
        and character_key ~= current_character_key
    if character_key then current_character_key = character_key end

    if main_job_id == current_main_job_id and sub_job_id == current_sub_job_id
        and job_def and not character_changed then
        return  -- Already loaded
    end

    if character_changed then
        common.debugf('Character change detected (%s -> %s); reloading settings.',
            previous_character_key, character_key)
    end

    -- Track job change
    if current_main_job_id and (current_main_job_id ~= main_job_id or current_sub_job_id ~= sub_job_id) then
        local old_job_str = common.get_job_name(current_main_job_id)
        if current_sub_job_id and current_sub_job_id > 0 then
            old_job_str = old_job_str .. '/' .. common.get_job_name(current_sub_job_id)
        end
        local new_job_str = common.get_job_name(main_job_id)
        if sub_job_id and sub_job_id > 0 then
            new_job_str = new_job_str .. '/' .. common.get_job_name(sub_job_id)
        end
        common.printf('Job change detected: %s -> %s', old_job_str, new_job_str)
    end
    
    current_main_job_id = main_job_id
    current_sub_job_id = sub_job_id

    -- Seed the change-detection tracking here rather than on the first render:
    -- during a zone/game load this function bails above, so a first-frame one-shot
    -- would burn with nothing seeded. Level is only taken when it reads valid, so a
    -- transient 0 can't disable level-change detection until the next job change.
    local seed_level = common.get_player_level()
    last_job_id = main_job_id
    last_sub_job_id = sub_job_id or 0
    if seed_level and seed_level > 0 then
        last_level = seed_level
    end

    job_def = load_job_definition(main_job_id, sub_job_id)
    
    if job_def then
        -- Build defaults table including job-specific defaults
        local load_defaults = T{}
        for key, value in pairs(default_settings) do
            if type(value) == 'table' then
                load_defaults[key] = T(value)
            else
                load_defaults[key] = value
            end
        end
        
        -- Merge job-specific defaults
        if job_def.default_settings then
            for key, value in pairs(job_def.default_settings) do
                if type(value) == 'table' then
                    load_defaults[key] = T(value)
                else
                    load_defaults[key] = value
                end
            end
        end
        
        -- Keep the merged defaults (global + job) on the job def: the profile
        -- New/Load helpers in lib/ui/config.lua reset or backfill live settings
        -- from this same table, so a loaded profile can never miss a newer key.
        job_def.merged_defaults = load_defaults

        -- Load settings (managed by Ashita settings library)
        -- Note: Ashita auto-determines filename based on addon name and character
        addon_settings = settings.load(load_defaults)
        
        -- Register settings to enable auto-save
        settings.register('settings', 'settings_reload', function(s)
            if s ~= nil then
                addon_settings = s
                -- Preserve the in-memory automation state; the local variable
                addon_settings.automation_enabled = automation_enabled
            end
        end)
        
        -- Merge with default settings (only if key doesn't exist)
        for key, value in pairs(default_settings) do
            if addon_settings[key] == nil then
                if type(value) == 'table' then
                    addon_settings[key] = T(value)
                else
                    addon_settings[key] = value
                end
            end
        end
        
        -- Merge with job-specific default settings (only if key doesn't exist)
        if job_def.default_settings then
            for key, value in pairs(job_def.default_settings) do
                if addon_settings[key] == nil then
                    if type(value) == 'table' then
                        addon_settings[key] = T(value)
                    else
                        addon_settings[key] = value
                    end
                end
            end
        end
        
        -- Drop stratagems assigned on a higher-level SCH that this job/level can't use
        if common.prune_unavailable_stratagems(job_def, addon_settings) then
            settings.save()
        end

        common.printf('Loaded settings for %s', job_def.job_name)

        -- A same-job character switch just reloaded addon_settings above (this
        -- point in the function, after settings.load, matters: doing this any
        -- earlier would hydrate from character A's table before B's has been
        -- loaded). The party-buff mirrors in lib/ui/config.lua are separate
        -- module-locals that nothing else clears, so reset them and re-hydrate
        -- from addon_settings now that it is B's -- reset first, since
        -- hydrate_party_buffs only ever fills an already-empty mirror and
        -- would otherwise no-op over A's leftover rows. This is what makes the
        -- Buffs/Geo/Sleep Removal/Debuff Removal target rows and Combat/Idle
        -- overrides follow the character switch instead of lagging a step
        -- behind it.
        if character_changed then
            ui_config.reset_party_buff_state()
            ui_config.hydrate_party_buffs(addon_settings)
            -- The web UI opt-in is per character as well, and the bridge keeps
            -- it in a module-local that the one-shot restore below sets exactly
            -- once per addon *load*. A character switch does not unload the
            -- addon, so without this B inherits A's answer: on for a character
            -- who never opted in (writing B's snapshot and running B's browser
            -- requests), or off while /sk webui still reports enabled.
            webui.set_enabled(addon_settings.webui_enabled == true)
        end
    end
end

--[[
    Automation Loop
]]--

local function automation_tick()
    if not automation_enabled then
        return
    end

    if not job_def then
        return
    end

    -- Gather player + party snapshot once for this tick.
    -- All action modules can read common.game_state.player / common.game_state.party[1..5]
    -- instead of making individual API calls each cycle.
    -- Must run BEFORE the mount guard so that is_mounted is refreshed every tick;
    -- otherwise once set to true it would never be cleared (the early return prevented
    -- refresh_game_state from executing).
    common.refresh_game_state()

    -- Player has not fully loaded in yet (job reads as NON/NON).
    -- Skip all automation until the server sends valid job data.
    if common.is_loading() then
        return
    end

    -- Point auto_element-tagged groups (RDM enspells, SCH storms) at the tier matching
    -- the current weather/day when 'Auto Select' is on. Self-throttled to 1/sec.
    -- Ahead of the AFK/mount/dead guards so the config dropdown stays accurate in
    -- those states too.
    vanadiel.apply_auto_selection(job_def, addon_settings)

    -- AFK Sleep. After is_loading() so zone-transition positions are never sampled;
    -- ahead of the mount/dead/can_attack/casting guards so it keeps timing (and can
    -- wake) regardless of those states.
    afk.update(addon_settings)
    if afk.is_sleeping() then
        return
    end

    -- Fire any queued mid-cast /debuff strip (Bard Pianissimo, Ninja 1-shadow).
    -- Must run ahead of the is_casting() guard below, which otherwise returns before
    -- any command could be sent while a spell is casting.
    common.process_scheduled_removal()

    if common.is_mounted() then
        return
    end

    if common.is_dead() then
        -- Dying in combat leaves Multisend follow off (no mob death re-enabled it).
        -- Re-enable now so movement resumes on revive instead of staying stuck off.
        if addon_settings and addon_settings.multisend_follow and addon_settings.attack_range
            and addon_settings.attack_range ~= 'Off' and range_state.follow_enabled == false then
            AshitaCore:GetChatManager():QueueCommand(1, '/ms follow on')
            range_state.follow_enabled = true
            common.debugf('[Range] Dead, re-enabling follow')
        end
        -- Death strips our own songs like anyone else's, but buff.lua's corpse
        -- check never runs on us: this guard returns before buff.execute, and
        -- once we are raised the read says alive. Drop our timers here instead,
        -- so a raised Bard re-establishes their songs at once.
        local me = common.game_state and common.game_state.player
        if me and action_modules.buff then
            action_modules.buff.forget_song_timers(me.server_id)
        end
        return
    end

    -- Sleep / Stun / Terror / Petrification / Charm: the server rejects every
    -- command, so stop the whole tick rather than burn the 1.1s throttle on
    -- guaranteed failures. Sits here, not in is_command_blocked, so it also
    -- covers the paths that skip the ability pipeline -- items, /heal rest, and
    -- the range/follow handling below.
    if common.is_incapacitated() then return end

    -- Check if combat is allowed
    if not common.can_attack() then
        return
    end

    -- Check if casting
    if common.is_casting() then
        return
    end

    -- Multisend range/follow -- only in Multisend Follow mode (else native follow runs).
    if addon_settings and addon_settings.multisend_follow and addon_settings.attack_range and addon_settings.attack_range ~= 'Off' then
        local in_combat = common.is_combat()

        -- If not in combat, ensure follow is enabled
        if not in_combat and range_state.follow_enabled == false then
            AshitaCore:GetChatManager():QueueCommand(1, '/ms follow on')
            range_state.follow_enabled = true
            common.debugf('[Range] Not in combat, enabling follow')
        end

        -- If in combat, manage range relative to the battle target
        if in_combat then
            local bt = common.targets.get_bt()
            local bt_index = bt and bt.TargetIndex or nil
            if bt_index and bt_index > 0 then
                -- Convert setting to yalms
                local desired_range = 0
                if addon_settings.attack_range == 'Melee (3 yalms)' then
                    desired_range = 3
                elseif addon_settings.attack_range == 'Ranged (15 yalms)' then
                    desired_range = 15
                end

                local in_range = common.is_in_range(bt_index, desired_range)

                if in_range and range_state.follow_enabled == true then
                    -- Within range, disable follow
                    AshitaCore:GetChatManager():QueueCommand(1, '/ms follow off')
                    range_state.follow_enabled = false
                    common.debugf('[Range] Within %d yalms of BT, disabling follow', desired_range)
                elseif not in_range and range_state.follow_enabled == false then
                    -- Out of range, enable follow
                    AshitaCore:GetChatManager():QueueCommand(1, '/ms follow on')
                    range_state.follow_enabled = true
                    common.debugf('[Range] Beyond %d yalms of BT, enabling follow', desired_range)
                end
            end
        end
    end
    
    -- Check for job or level changes (direct reading, no packet dependency)
    local main_level, sub_level
    do
        local job_id, sub_job_id = common.get_player_job()
        main_level, sub_level = common.get_player_level()
        
        -- Skip if job_id or level is invalid
        if job_id and job_id > 0 and main_level and main_level > 0 then
        -- Initialize tracking on first valid job detection
        if not last_job_id or last_job_id == 0 then
            last_job_id = job_id
            last_sub_job_id = sub_job_id or 0
            last_level = main_level
            common.debugf('Initialized job tracking: %s/%s (level %s)', tostring(job_id), tostring(sub_job_id), tostring(main_level))
        else
            -- Normalize sub job IDs (treat nil as 0)
            local normalized_sub_job = sub_job_id or 0
            local normalized_last_sub = last_sub_job_id or 0
            
            -- Detect job change
            -- Guard: sub_job momentarily reading as 0 during zone transitions
            local job_changed = false
            if job_id ~= last_job_id then
                job_changed = true
            elseif normalized_sub_job ~= normalized_last_sub and normalized_sub_job > 0 and normalized_last_sub > 0 then
                job_changed = true
            elseif normalized_sub_job > 0 and normalized_last_sub == 0 then
                job_changed = true
            end
            
            -- Detect level change
            local level_changed = false
            if last_level and main_level ~= last_level and last_level > 0 then
                level_changed = true
            end
            
            -- Handle job change
            if job_changed then
                local old_job_str = common.get_job_name(last_job_id)
                if last_sub_job_id and last_sub_job_id > 0 then
                    old_job_str = old_job_str .. '/' .. common.get_job_name(last_sub_job_id)
                end
                local new_job_str = common.get_job_name(job_id)
                if sub_job_id and sub_job_id > 0 then
                    new_job_str = new_job_str .. '/' .. common.get_job_name(sub_job_id)
                end
                common.printf('Job change detected: %s -> %s, reloading job definition...', old_job_str, new_job_str)
                
                -- Update tracking
                last_job_id = job_id
                last_sub_job_id = sub_job_id
                last_level = main_level
                current_main_job_id = nil
                current_sub_job_id = nil
                job_def = nil
                addon_settings = nil
                
                -- Reload job
                setup_job()
                
                -- Preserve the in-memory automation state through job changes.
                if addon_settings then
                    addon_settings.automation_enabled = automation_enabled
                end

                -- Fresh AFK timer for the new job (its saved afk_timeout may differ).
                afk.reset()

                -- Roll totals belong to the old job's rolls (and the new job's saved
                -- roll names are different anyway) -- drop them with the job.
                roll_mod.reset_state()

                -- Songs don't survive a job change, so neither may the manual
                -- re-sing timers stamped for them.
                action_modules.buff.reset_song_timers()

                -- Skip this frame after job reload
                return
            elseif level_changed then
                common.printf('Level change detected: %d -> %d, reloading UI...', last_level, main_level)
                
                -- Update level tracking
                last_level = main_level
                
                -- Force UI refresh by resetting job_def
                current_main_job_id = nil
                current_sub_job_id = nil
                
                -- Reload the job definition to pick up newly available abilities
                setup_job()
                
                -- Skip this frame after reload
                return
            end
        end
        end
    end
    
    local player_resource = action_core.get_resource(job_def.resource_type)
    
    -- Get priority order
    -- job_def.priority_order is always populated by load_job_definition's merge;
    -- `or {}` is a cheap nil-safety net (empty = no actions this tick, never a crash).
    local priority_order = job_def.priority_order or {}
    
    -- Execute priority actions
    automation.execute_priority_actions(
        priority_order,
        action_modules,
        addon_settings,
        job_def,
        main_level,
        sub_level,
        player_resource
    )
end

-- Auto Follow, run when the priority engine won't reach it: automation stopped, or
-- "paused" (on but can_attack blocked -- safe zone / cutscene / just-zoned). Follow
-- isn't combat, so unlike the engine it's not gated on can_attack (works in towns).
local function follow_tick()
    if not job_def or not addon_settings then return end
    if not addon_settings.follow_enabled or addon_settings.multisend_follow then return end

    -- Engine owns follow when it can (keeps healing above follow); only take over otherwise.
    if automation_enabled and common.can_attack() then return end

    if not common.game_state or not common.game_state.refreshed_at
        or os.clock() - common.game_state.refreshed_at > 0.1 then
        common.refresh_game_state()
    end

    if common.is_loading() then return end
    if common.is_mounted() then return end
    if common.is_dead() then return end
    if common.is_casting() then return end
    if common.is_incapacitated() then return end  -- slept/stunned/terrorized: can't move either

    local ok, result = pcall(action_modules.follow.execute, addon_settings, job_def)
    if ok and result then
        automation.execute_command(result.command, result.description)
    elseif not ok then
        common.errorf('follow_tick failed: %s', tostring(result))
    end
end

--[[
    Event Handlers
]]--

ashita.events.register('load', 'sidekick_load', function()
    is_loaded = true
    
    -- Initialize ui_config (registers event handlers)
    ui_config.initialize()
    
    common.printf('Loaded! Type /sidekick help for commands.')
end)

ashita.events.register('unload', 'sidekick_unload', function()
    if addon_settings then
        -- Reopen the config window on next load if it is open now. Covers /sk config
        -- and the [X] alike, since both just move ui_config's visibility flag.
        addon_settings.ui_open = ui_config.is_visible()
        addon_settings.widget_open = ui_config.is_widget_visible()

        -- settings.save takes an ALIAS, not (table, filename) -- passing the table
        -- silently no-ops. No alias == 'settings', the block settings.load registered.
        settings.save()
    end

    -- A browser tab must not keep showing a client that is gone as live.
    if webui.is_enabled() then
        webui.go_offline()
    end

    party_share.cleanup()

    common.printf('Unloaded.')
end)

-- Settings only exist once setup_job sees a valid job, which can be many frames later
-- if the addon loads mid-zone. Restore is one-shot on that, not on the first frame.
local state_restored = false

ashita.events.register('d3d_present', 'sidekick_render', function()
    if not is_loaded then
        return
    end
    
    -- Check for job changes (every frame); also seeds job/level change tracking
    setup_job()

    -- Restore the saved automation state, unless Load stopped is on
    -- (opt-in, right-click the Start button). Runs the first tick settings exist:
    -- loading the addon while the game is still loading leaves them nil for a while,
    -- and skipping this would strand the local flag out of sync with the saved one.
    if not state_restored and addon_settings then
        state_restored = true

        automation_enabled = not addon_settings.load_stopped
            and addon_settings.automation_enabled == true
        addon_settings.automation_enabled = automation_enabled

        -- Reopen the config window if it was open at unload.
        if addon_settings.ui_open == true then
            ui_config.show()
        end
        if addon_settings.widget_open == true then
            ui_config.toggle_widget()  -- starts hidden, so toggle == show
        end

        webui.set_enabled(addon_settings.webui_enabled == true)

        -- Unconditional, unlike the two calls inside webui.lua: those only run
        -- while the web UI feature is on, so with it off (the default) a
        -- session that never opened /sidekick would still never hydrate the
        -- Buffs/Geo/Sleep Removal/Debuff Removal target mirror. This is the
        -- first tick settings exist for ANY session, web UI or not.
        -- hydrate_party_buffs' own guard (only while the mirror is still
        -- empty) makes calling it again from render()/webui.tick harmless.
        ui_config.hydrate_party_buffs(addon_settings)
    end

    local save_settings_callback = function()
        settings.save()
    end

    -- Render config UI, then the floating widget (independent of the config window,
    -- and unlike it does not need a job_def).
    if addon_settings then
        if ui_config.is_visible() and job_def then
            ui_config.render(addon_settings, job_def, save_settings_callback)
        end
        ui_config.render_widget(addon_settings, job_def, save_settings_callback)
    end

    -- Render game-state panel (independent of automation / job_def)
    ui_panel.render(addon_settings, save_settings_callback)

    -- Run automation tick
    automation_tick()

    -- Auto Follow while stopped/paused; no-op when the engine handled follow this tick.
    follow_tick()

    -- Publish our party roster and mirror tracked anchors' parties (own 2s timer).
    party_share.tick()

    -- Web UI bridge: snapshot out, requests in. Self-throttled, and inert
    -- unless /sk webui is on -- gated here too, not just inside webui.tick's
    -- do_tick: building `status` below reaches common.can_attack() in the
    -- normal case, an uncached ashita.memory.find plus a linear zone-list
    -- walk, and allocates a fresh deps table and closures every frame. Paying
    -- that every frame for every user just for do_tick to throw the result
    -- away when the feature is off would tax everyone for an opt-in feature.
    if addon_settings and webui.is_enabled() then
        local status = 'Automation stopped'
        if automation_enabled then
            if     common.is_loading() then status = 'Automation loading'
            elseif afk.is_sleeping()   then status = 'Automation asleep'
            elseif common.is_mounted() then status = 'Automation mounted'
            elseif common.is_dead()    then status = 'Automation dead'
            elseif common.is_resting() then status = 'Automation resting'
            elseif common.can_attack() then status = 'Automation running'
            else                            status = 'Automation paused'
            end
        end
        webui.tick({
            settings = addon_settings,
            job_def = job_def,
            automation = automation_enabled,
            status = status,
            save = save_settings_callback,
            exec = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end,
        })
    end
end)

-- 0x028 categories marking one of our actions *resolving*. The post-action lockout is
-- server-side and starts here, so these restart the command throttle; see
-- automation.notify_action_finished. JAs included: they also catch abilities the player
-- used by hand, which execute_command never sees. The *_begin categories are absent --
-- their own finish packet lands here later; melee (1) never reaches this table.
local ACTION_FINISH_CATEGORIES = {
    [2]  = true,  -- ranged_finish
    [3]  = true,  -- ws_finish
    [4]  = true,  -- spell_finish
    [5]  = true,  -- item_finish
    [6]  = true,  -- job_ability
    [14] = true,  -- job_ability (DNC)
    [15] = true,  -- job_ability (RUN)
}

-- 7 ws, 8 casting, 9 item, 12 ranged. An interrupt arrives as one of these carrying
-- INTERRUPT_PARAM, sends no finish packet, and locks out just the same.
local ACTION_BEGIN_CATEGORIES = { [7] = true, [8] = true, [9] = true, [12] = true }

local function is_action_finish(actionPacket)
    if ACTION_FINISH_CATEGORIES[actionPacket.Type] then return true end
    return ACTION_BEGIN_CATEGORIES[actionPacket.Type]
        and actionPacket.Param == common.INTERRUPT_PARAM
end

-- 0x029 battle-message ids where param1 IS a status id (verified against the
-- CatsEyeXI server enums msg_std.h / msg_basic.h). Everything else on 0x029
-- (damage, misses, synth results, skill-ups, no-effect...) carries an unrelated
-- param and must be ignored, or it injects phantom statuses (e.g. a synth whose
-- param happened to equal Sleep=2 / Terror=28). GAINS: "gains/receives the
-- effect of <status>" and "is <status>" families. LOSSES: EffectWearsOff (206,
-- broadcast in-range on every wear-off) and effect-disappears/dispel.
local STATUS_GAIN_MESSAGES = {
    [186] = true,  -- <user> uses <skill>. <target> gains the effect of <status>
    [203] = true,  -- <target> is <status>
    [205] = true,  -- <target> gains the effect of <status>  (MsgStd GainsEffect)
    [230] = true,  -- <caster> casts <spell>. <target> gains the effect of <status>
    [236] = true,  -- <caster> casts <spell>. <target> is <status>
    [237] = true,  -- <caster> casts <spell>. <target> receives the effect of <status>
    [242] = true,  -- <user> uses <skill>. <target> is <status>
    [243] = true,  -- <user> uses <skill>. <target> receives the effect of <status>
    [266] = true,  -- <target> gains the effect of <status>
    [277] = true,  -- <target> is <status>
    [278] = true,  -- <target> receives the effect of <status>
    [280] = true,  -- <target> is afflicted with <status> (CatsEyeXI status-gain variant; param@0x0C = status id, not in named msg_basic.h enum)
}
local STATUS_LOSE_MESSAGES = {
    [204] = true,  -- <target>'s <status> effect wears off (variant)
    [206] = true,  -- <target>'s <status> effect wears off  (MsgStd EffectWearsOff)
    [343] = true,  -- <target>'s <status> effect disappears! (dispel/erase)
}

ashita.events.register('packet_in', 'sidekick_packet_in', function(e)
    if not is_loaded then
        return
    end

    -- Zero the server's autorun-cancel flag on position syncs (0x0D byte 0x42) so
    -- /follow survives them. Only while native follow is enabled. Do NOT touch 0x37
    -- byte 0x58: that is Flags4 (GeoIndi bits 0-6 + JobMasterFlag bit 7), not a
    -- movement flag -- zeroing it wiped the job-mastery stars and the GEO Indi aura.
    if addon_settings and addon_settings.follow_enabled and not addon_settings.multisend_follow then
        if e.id == 0x0D then
            local packet = e.data:totable()
            if packet[0x42 + 1] ~= 0 then
                packet[0x42 + 1] = 0
                e.data_modified = packet
            end
        end
    end

    -- Handle action packets (0x028): casting detection, buff tracking, sleep inference
    -- Message 230 = caster/player gains the effect, 266 = other party members/Trusts gain the effect
    -- Message 83  = buff/debuff removed from target (e.g. Paralyna removes Paralysis)
    -- Cure healing messages (2, 7, 24) on tracked sleeping targets infer wake
    if e.id == 0x028 then
        local actionPacket = parse_packets.parse_action_packet(e)

        -- Corsair roll totals ride on the same parsed packet: cmd_arg identifies the
        -- roll, the caster's own target entry carries the die value and running total.
        -- Costs one table lookup for every other job.
        if job_def and job_def.abilities and job_def.abilities.roll then
            roll_mod.handle_action_packet(actionPacket, addon_settings, job_def)
        end

        -- Determine if we (the player) are the actor
        local party = common.get_party()
        local player_id = party and party:GetMemberServerId(0)
        local actor_is_player = (actionPacket and player_id and actionPacket.UserId == player_id)

        -- Casting detection (always active). Category 8 = casting start (or, with
        -- Param INTERRUPT_PARAM, interrupt), 4 = casting finish; see
        -- common.handle_action_packet.
        if actor_is_player then
            common.handle_action_packet(actionPacket)

            -- Bard manual song timers, steps 2 and 3 of the handshake (step 1 is
            -- the send; see pending_song in lib/actions/buff.lua). Cast start
            -- confirms the song we armed really went out; an interrupt says it
            -- never landed, so nothing may be stamped for it. Both are needed for
            -- the timer to start only once the cast has actually completed.
            if actionPacket.Type == 8 then
                if actionPacket.Param == common.INTERRUPT_PARAM then
                    action_modules.buff.handle_song_interrupted()
                else
                    action_modules.buff.handle_song_cast_start()
                end
            elseif actionPacket.Type == 4 and actionPacket.Param == common.INTERRUPT_PARAM then
                -- Interrupt landing on the finish category instead of the begin one.
                action_modules.buff.handle_song_interrupted()
            end

            -- Our action just resolved — start the throttle from now, not from the
            -- send that may have been a full cast time ago.
            if is_action_finish(actionPacket) then
                automation.notify_action_finished(actionPacket.Type == 4)
            end

            -- Cast finished (category 4) — apply the pending buff to the Trust.
            -- INTERRUPT_PARAM is rejected in case the interrupt lands on category 4:
            -- recording a buff the Trust never got would suppress the recast for the
            -- buff's full duration. No spell id is 28787, so a real cast never trips it.
            if actionPacket.Type == 4 and actionPacket.Param ~= common.INTERRUPT_PARAM then
                common.handle_buff_application()
                -- Same moment for Bard's manual song timers: the song's duration
                -- starts here, so this is where it gets stamped (and where
                -- Troubadour is read). Param is the spell id, which identifies
                -- the song that landed; see buff.handle_song_finished.
                action_modules.buff.handle_song_finished(actionPacket.Param)
            end
        end

        -- Buff gain/loss tracking — casting finish packets only
        if actionPacket and actionPacket.Type == 4 then
            -- Resolve the spell name once for base-duration lookup (timed expiry)
            local spell = AshitaCore:GetResourceManager():GetSpellById(actionPacket.Param)
            local spell_name = spell and spell.Name and spell.Name[1] or nil

            for _, target in ipairs(actionPacket.Targets) do
                for _, action in ipairs(target.Actions) do
                    -- Resolve target name via fast index lookup (avoid O(2304) scan)
                    local target_name = common.resolve_entity_name(target.Id)

                    local buff_name = AshitaCore:GetResourceManager():GetString('buffs.names', action.Param)
                    if not buff_name or buff_name == '' then
                        buff_name = 'Buff#' .. action.Param
                    end

                    if action.Message == 230 or action.Message == 266 then
                        common.debugf('%s gained the effect of %s.', target_name, buff_name)

                        -- Base duration for timed expiry (nil = no timer). The
                        -- actor (UserId) is the caster -- used for per-caster song
                        -- slot accounting on the target.
                        local duration = common.base_buff_duration(action.Param, spell_name, target.Id)
                        local source_id = actionPacket.UserId

                        -- Update Trust buff tracking so game_state reflects the change
                        if target.Id >= 0x1000000 then
                            common.apply_trust_buff(target.Id, action.Param, duration, source_id, actionPacket.Param)
                        end

                        -- Update tracked target buff tracking
                        if common.is_tracked_target(target.Id) then
                            common.apply_tracked_target_buff(target.Id, action.Param, duration, source_id, actionPacket.Param)
                        end

                        -- Update alliance member buff tracking
                        if common.is_alliance_member(target.Id) then
                            common.apply_alliance_member_buff(target.Id, action.Param, duration, source_id, actionPacket.Param)
                        end

                        -- Update pet buff/debuff tracking
                        if common.is_pet(target.Id) then
                            common.apply_pet_buff(target.Id, action.Param, duration, source_id, actionPacket.Param)
                        end

                    elseif action.Message == 83 then
                        common.debugf('%s lost the effect of %s (via 0x028).', target_name, buff_name)

                        -- Remove from Trust, tracked target, alliance, and pet buff tracking (all in trust_buffs)
                        if target.Id >= 0x1000000 or common.is_tracked_target(target.Id) or common.is_alliance_member(target.Id) or common.is_pet(target.Id) then
                            common.handle_buff_removal(target.Id, action.Param)
                        end
                    end

                    -- Sleep removal inference: only for cure-type spells cast by the player.
                    -- Cure spells can't miss, so landing on a sleeping target means wake.
                    -- Applies to every packet-tracked ally (Trust/tracked/alliance/pet) --
                    -- none get a reliable wear-off packet, so without this Sleep lingers in
                    -- tracking and wake re-cures every tick until the base-duration timer
                    -- clears it. handle_buff_removal no-ops when Sleep isn't tracked.
                    -- Message 2 = "recovers X HP" (single cure), 7 = "recovers X HP" (AoE cure),
                    -- 24 = Curaga-style HP recovery
                    local packet_tracked = target.Id >= 0x1000000
                        or common.is_tracked_target(target.Id)
                        or common.is_alliance_member(target.Id)
                        or common.is_pet(target.Id)
                    if actor_is_player and packet_tracked then
                        if action.Message == 2 or action.Message == 7 or action.Message == 24 then
                            common.handle_buff_removal(target.Id, 2)   -- Sleep
                            common.handle_buff_removal(target.Id, 19)  -- Sleep II
                        end
                    end
                end
            end
        end
    end

    -- Handle character check response (0x0C9): resolves tracked target level.
    if e.id == 0x0C9 then
        if e.data then
            common.handle_check_packet(e.data)
        end
    end

    -- Detect buff gain/loss via 0x029 (battle message). Catches status changes
    -- 0x028 misses (buffs not cast by the local player, out-of-party targets
    -- getting slept, and every wear-off -- EffectWearsOff is broadcast in-range).
    -- message (0x18) = battle-message id; param (0x0C) = status id, but ONLY when
    -- message is a status gain/loss (STATUS_GAIN/LOSE_MESSAGES). target (0x08) =
    -- entity the effect changed on.
    if e.id == 0x029 then
        if e.data and #e.data >= 0x1A then
            local msg = parse_packets.parse_message_packet(e)

            local server_id = msg.target
            local buff_id   = msg.param

            if server_id > 0 and buff_id > 0 and buff_id ~= 255 then
                -- Resolve target name via fast index lookup (avoid O(2304) scan)
                local target_name = common.resolve_entity_name(server_id)

                -- When the target is dead (entity_status == 3), the server sends a 0x029
                -- packet whose param is the SPELL ID of the rejected raise — not a buff ID.
                -- Treat this as a signal that the target already has a pending raise.
                if get_entity_status_in_gs(server_id) == 3 then
                    common.debugf('[REVIVE] %s is dead — 0x029 param %d is a rejected raise spell ID; setting pending_raise flag',
                        target_name, buff_id)
                    common.set_pending_raise(server_id)
                elseif STATUS_GAIN_MESSAGES[msg.message] or STATUS_LOSE_MESSAGES[msg.message] then
                    -- Target is alive and this is a status gain/loss message, so
                    -- param is a real status id. Any other 0x029 (synth results,
                    -- damage, misses...) is ignored above -- its param is unrelated
                    -- and would otherwise inject a phantom status.
                    local buff_name = AshitaCore:GetResourceManager():GetString('buffs.names', buff_id)
                    if not buff_name or buff_name == '' then
                        buff_name = 'Buff#' .. buff_id
                    end

                    if STATUS_LOSE_MESSAGES[msg.message] then
                        common.debugf('%s lost the effect of %s (via 0x029).', target_name, buff_name)
                        -- handle_buff_removal no-ops on untracked ids, so no guard needed.
                        common.handle_buff_removal(server_id, buff_id)
                    else
                        common.debugf('%s gained the effect of %s (via 0x029).', target_name, buff_name)

                        -- Base duration for timed expiry; 0x029 has no spell id, so
                        -- this resolves via song range / buff name only. It also
                        -- carries no caster, so source stays nil (no song eviction --
                        -- 0x028 is the reliable song-detection path anyway).
                        local duration = common.base_buff_duration(buff_id, nil, server_id)

                        -- Update Trust buff tracking
                        if server_id >= 0x1000000 then
                            common.apply_trust_buff(server_id, buff_id, duration)
                        end

                        -- Update tracked target buff tracking
                        if common.is_tracked_target(server_id) then
                            common.apply_tracked_target_buff(server_id, buff_id, duration)
                        end

                        -- Update alliance member buff tracking
                        if common.is_alliance_member(server_id) then
                            common.apply_alliance_member_buff(server_id, buff_id, duration)
                        end

                        -- Update pet buff/debuff tracking (mob debuffs on the pet
                        -- arrive here as an out-of-party target gaining an effect)
                        if common.is_pet(server_id) then
                            common.apply_pet_buff(server_id, buff_id, duration)
                        end
                    end
                end
            end
        end
    end

    -- Clear Trust buffs on zone change (tracked targets survive zoning)
    if e.id == 0x0A then  -- Zone change packet
        common.clear_trust_buffs()
        common.clear_casting_state()
        -- Zoning cancels an in-flight cast without sending an interrupt packet, so
        -- the song we were waiting on must be dropped here too.
        action_modules.buff.handle_song_interrupted()

        -- Stop after zone (opt-in via the Start button right-click menu).
        if automation_enabled and addon_settings and addon_settings.stop_after_zone == true then
            automation_enabled = false
            addon_settings.automation_enabled = false
            common.printf('Automation stopped (zoned).')
        end
    end
end)

ashita.events.register('command', 'sidekick_command', function(e)
    local args = e.command:args()
    
    if args[1] ~= '/sidekick' and args[1] ~= '/sk' then
        return
    end
    
    e.blocked = true
    
    -- Handle commands
    local cmd = args[2] and args[2]:lower() or 'config'
    
    if cmd == 'help' then
        common.printf('Sidekick Commands:')
        common.printf('  /sidekick - Show configuration UI')
        common.printf('  /sidekick help - Show this help')
        common.printf('  /sidekick start - Start automation')
        common.printf('  /sidekick stop - Stop automation')
        common.printf('  /sidekick toggle - Toggle automation on/off')
        common.printf('  /sidekick config - Show configuration UI')
        common.printf('  /sidekick widget - Toggle the floating profile/job + Start/Stop widget')
        common.printf('  /sidekick webui [on|off|folder|open|url <address>] - Web UI bridge for the browser app')
        common.printf('  /sidekick focus <index> - Set focus target (0-5, party member index)')
        common.printf('  /sidekick focus clear - Clear focus target')
        common.printf('  /sidekick addtarget - Track current target for automation')
        common.printf('  /sidekick removetarget <name> - Stop tracking a target')
        common.printf('  /sidekick panel - Toggle party state info panel')
        common.printf('  /sidekick debug - Toggle debug mode')
        common.printf('  /sidekick recast - Show all active ability recast timers')
        common.printf('  /sidekick roll_test - Self-test the Corsair roll strategy rules')
        common.printf('  /sidekick afk [on|off|<seconds>] - AFK Sleep: show/toggle/set timeout')
        common.printf('  /sidekick status - Show current status')
        
    elseif cmd == 'start' then
        automation_enabled = true
        addon_settings.automation_enabled = true
        afk.reset()  -- Start awake with a full AFK interval.
        settings.save()
        common.printf('Automation started.')
        
    elseif cmd == 'stop' then
        automation_enabled = false
        addon_settings.automation_enabled = false
        settings.save()
        common.printf('Automation stopped.')
        
    elseif cmd == 'toggle' then
        automation_enabled = not automation_enabled
        addon_settings.automation_enabled = automation_enabled
        -- Same fresh interval as 'start' (this is the path the UI Start button takes),
        -- else a restart while asleep comes back still asleep.
        if automation_enabled then afk.reset() end
        settings.save()
        common.printf('Automation %s.', automation_enabled and 'enabled' or 'disabled')
        
    elseif cmd == 'config' then
        ui_config.toggle()
        
    elseif cmd == 'widget' then
        -- Persisted by the unload handler, same as /sidekick config.
        ui_config.toggle_widget()

    elseif cmd == 'webui' then
        local sub = args[3] and args[3]:lower()
        if sub == 'on' or sub == 'off' then
            addon_settings.webui_enabled = (sub == 'on')
            webui.set_enabled(addon_settings.webui_enabled)
            if not addon_settings.webui_enabled then
                webui.go_offline()
            end
            settings.save()
            common.printf('Web UI %s.', addon_settings.webui_enabled and 'enabled' or 'disabled')
        elseif sub == 'folder' then
            common.printf('%s', webui.root_dir())
            common.printf('Choose that folder in the web app.')
        elseif sub == 'url' then
            -- args[4] is whatever the player typed after 'url', verbatim -- a
            -- URL has no spaces, so e.command:args() splitting on whitespace
            -- is not a concern here. This string reaches os.execute inside a
            -- quoted start "" "<url>" command below, so a stray " could break
            -- out of that quoting -- reject it outright rather than escaping it.
            local url = args[4]
            if not url or url == '' then
                common.printf('Usage: /sidekick webui url <http(s)://address>')
            elseif url:find('"', 1, true) then
                common.printf('Web UI address cannot contain a " character.')
            elseif url:find('%', 1, true) then
                -- os.execute runs via cmd.exe /c, which expands %VAR% BEFORE its
                -- special-character/quoting pass, so whatever the expansion
                -- produces gets re-parsed as command syntax. &, |, <, >, ^ and \
                -- are all inert inside the surrounding double quotes, but a %
                -- reference is not -- an address containing %FOO% where FOO
                -- holds something like "&calc&" would break out of the quoting
                -- once expanded. Reject it the same way as the literal ".
                common.printf('Web UI address cannot contain a % character.')
            elseif not url:match('^https?://') then
                common.printf('Web UI address must start with http:// or https://')
            else
                addon_settings.webui_url = url
                settings.save()
                common.printf('Web UI address set to %s', url)
            end
        elseif sub == 'open' then
            os.execute(string.format('start "" "%s"', addon_settings.webui_url or DEFAULT_WEBUI_URL))
            common.printf('Opening the web interface...')
        else
            common.printf('Web UI: %s (%s). Usage: /sidekick webui [on|off|folder|open|url <address>]',
                webui.is_enabled() and 'enabled' or 'disabled',
                addon_settings.webui_url or DEFAULT_WEBUI_URL)
        end

    elseif cmd == 'focus' then
        local subcmd = args[3] and args[3]:lower()
        
        if subcmd == 'clear' then
            addon_settings.focus_target = nil
            settings.save()
            common.printf('Focus target cleared.')
        elseif subcmd and tonumber(subcmd) then
            local index = tonumber(subcmd)
            if index >= 0 and index <= 5 then
                local member_name = common.get_party_member_name(index)
                if member_name then
                    addon_settings.focus_target = member_name
                    settings.save()
                    common.printf('Focus target set to %s (P%d)', member_name, index)
                else
                    common.errorf('Party member %d not found or not active.', index)
                end
            else
                common.errorf('Invalid party index. Use 0-5.')
            end
        else
            common.printf('Usage: /sidekick focus <index> or /sidekick focus clear')
        end
        
    elseif cmd == 'panel' then
        ui_panel.toggle()
        common.printf('Party state panel %s.', ui_panel.is_visible() and 'shown' or 'hidden')

    elseif cmd == 'debug' then
        common.debug = not common.debug
        common.printf('Debug mode %s.', common.debug and 'enabled' or 'disabled')
        
    elseif cmd == 'recast' then
        common.show_recast_timers()

    elseif cmd == 'roll_test' then
        -- roll_strategy is pure, so its decision table can be verified without a live
        -- Corsair or a real roll sequence.
        require('lib.core.roll_strategy').self_test(function(line)
            common.printf('%s', line)
        end)

    elseif cmd == 'status' then
        common.printf('Sidekick Status:')
        common.printf('  Job: %s', job_def and job_def.job_name or 'Not loaded')
        common.printf('  Automation: %s', automation_enabled and 'Enabled' or 'Disabled')
        common.printf('  Focus Target: %s', addon_settings.focus_target or 'None')
        common.printf('  Debug Mode: %s', common.debug and 'Enabled' or 'Disabled')
        local tracked = common.get_tracked_targets()
        local tracked_names = {}
        for _, tt in pairs(tracked) do table.insert(tracked_names, tt.name) end
        if #tracked_names > 0 then
            common.printf('  Tracked Targets: %s', table.concat(tracked_names, ', '))
        end
        
    elseif cmd == 'afk' then
        -- AFK Sleep. Timeout is read/written in SECONDS here; the config slider
        -- shows the same value in minutes.
        local subcmd = args[3] and args[3]:lower()

        if subcmd == nil then
            common.printf('AFK Sleep: %s, timeout %ds, currently %s.',
                addon_settings.afk_enabled and 'Enabled' or 'Disabled',
                addon_settings.afk_timeout or 600,
                afk.is_sleeping() and 'asleep' or 'awake')
        elseif subcmd == 'on' or subcmd == 'off' then
            addon_settings.afk_enabled = (subcmd == 'on')
            if not addon_settings.afk_enabled then
                afk.reset()  -- Never leave automation stuck asleep after disabling.
            end
            settings.save()
            common.printf('AFK Sleep %s.', addon_settings.afk_enabled and 'enabled' or 'disabled')
        elseif tonumber(subcmd) then
            local seconds = math.floor(tonumber(subcmd))
            if seconds < 60 then seconds = 60 end
            if seconds > 3600 then seconds = 3600 end
            addon_settings.afk_timeout = seconds
            afk.reset()  -- Restart the interval so the new timeout takes effect now.
            settings.save()
            common.printf('AFK Sleep timeout set to %ds.', seconds)
        else
            common.printf('Usage: /sidekick afk [on|off|<seconds 60-3600>]')
        end

    elseif cmd == 'addtarget' then
        -- Add current target as a tracked target
        local targets_lib = common.targets
        local target_entity = targets_lib.get_t()
        if not target_entity then
            common.errorf('No target selected.')
        else
            local spawn_flags = target_entity.SpawnFlags or 0
            local is_pc = bit.band(spawn_flags, 0x0001) ~= 0
            local target_sid = target_entity.ServerId or 0
            if not is_pc or target_sid == 0 then
                common.errorf('Target is not a player character.')
            elseif target_sid >= 0x1000000 then
                common.errorf('Target is a Trust or NPC.')
            else
                local added = common.add_tracked_target(target_entity)
                if not added then
                    common.errorf('%s is already in party or being tracked.', target_entity.Name or 'Target')
                end
            end
        end
        
    elseif cmd == 'removetarget' then
        -- Remove a tracked target by name
        local target_name = args[3]
        if not target_name then
            common.errorf('Usage: /sidekick removetarget <name>')
        else
            common.remove_tracked_target_by_name(target_name)
        end

    else
        common.printf('Unknown command: %s. Type /sidekick help for commands.', cmd)
    end
end)
