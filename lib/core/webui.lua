--[[
    Web UI bridge

    File-based request channel between the hosted web UI and the addon, modelled
    on XIIM's modules/bridge.lua. The browser holds a read/write grant on
    config\addons\sidekick\ through the File System Access API; it drops one
    request at a time into a character's own folder, and the game client that
    owns that character picks it up, executes it, and writes a reply next to it.
    There is no socket and no server.

        config\addons\sidekick\<CharacterKey>\state.json      written by the addon
        config\addons\sidekick\<CharacterKey>\heartbeat.json  written by the addon
        config\addons\sidekick\<CharacterKey>\request.txt     written by the web UI
        config\addons\sidekick\<CharacterKey>\response.txt    written by the addon

    Addressing a character IS writing to that character's folder, which is why
    there is no cross-character routing here.

    Requests are lines of '|'-separated fields rather than JSON. The addon has to
    parse whatever a web page wrote, and this grammar needs one split where JSON
    needs a parser -- see docs/superpowers/plans for the reasoning. The other
    direction is JSON, because the browser parses that for free.
]]--

local webui = {}

-- A request older than this is stale. The player may have been logged out for
-- days, and replaying the change they made last week is not what they meant.
webui.MAX_AGE_SECONDS = 3600

-- Slack for clock drift between the browser and the game client, which share a
-- machine. Without an upper bound a skewed ts never ages out and fires whenever
-- the character next logs in.
local MAX_FUTURE_SECONDS = 60

-- More ops than any UI action produces. A whole section of checkboxes is ~30.
local MAX_OPS = 200

local VALID_COMMANDS = { start = true, stop = true, toggle = true }

-- Field count each verb takes after the verb itself.
local OP_FIELDS = { set = 2, ability = 2, group = 2, buff = 3, cmd = 1 }

local function split_fields(line)
    local fields = {}
    for field in (line .. '|'):gmatch('([^|]*)|') do
        fields[#fields + 1] = field
    end
    return fields
end

--- Parse and envelope-check a request file.
-- Returns { id, ts, ops } where each op is an array of strings, or nil plus an
-- error. Only the shape is checked here; whether a key may be written is
-- decided in webui.apply against the schema the addon last exported.
function webui.parse_request(text, now)
    if type(text) ~= 'string' or text == '' then
        return nil, 'empty request'
    end

    local id, ts
    local seen_id, seen_ts = false, false
    local ops = {}

    for raw in text:gmatch('[^\r\n]+') do
        local fields = split_fields(raw)
        local verb = fields[1]

        if verb == 'id' then
            -- A second id or ts line almost certainly means two requests got
            -- concatenated (a retry racing a stale write, a hand-edited
            -- file); silently keeping the last value would apply an
            -- envelope that never existed as written. Reject like every
            -- other malformed line rather than picking a winner.
            if seen_id then return nil, 'duplicate id' end
            seen_id = true
            id = fields[2]
        elseif verb == 'ts' then
            if seen_ts then return nil, 'duplicate ts' end
            seen_ts = true
            ts = tonumber(fields[2])
        elseif OP_FIELDS[verb] then
            if #fields - 1 ~= OP_FIELDS[verb] then
                return nil, string.format('%s takes %d field(s)', verb, OP_FIELDS[verb])
            end
            if #ops >= MAX_OPS then
                return nil, 'too many changes in one request'
            end
            ops[#ops + 1] = fields
        else
            return nil, 'unknown verb: ' .. tostring(verb)
        end
    end

    if type(id) ~= 'string' or #id == 0 or #id > 64 or id:match('^[%w%-]+$') == nil then
        return nil, 'invalid id'
    end
    -- NaN is a number to Lua and every comparison below is false for it, so the
    -- self-equality test has to come first.
    if type(ts) ~= 'number' or ts ~= ts or ts <= 0 or ts >= 4102444800 then
        return nil, 'invalid timestamp'
    end
    if (now - ts) > webui.MAX_AGE_SECONDS then
        return nil, 'request expired'
    end
    if (ts - now) > MAX_FUTURE_SECONDS then
        return nil, 'request timestamp is in the future'
    end

    return { id = id, ts = ts, ops = ops }
end

-- ============================================================================
-- Applying
-- ============================================================================

local function on_off(word)
    if word == 'on' then return true end
    if word == 'off' then return false end
    return nil
end

-- Check one op against the exported schema and return the call it turns into,
-- or nil plus the reason. Nothing is written here: validation runs over the
-- whole request first, so a request that is wrong halfway through changes
-- nothing at all.
local function plan_op(op, index)
    local verb = op[1]

    if verb == 'set' then
        local key, raw = op[2], op[3]
        local control = index.set[key]
        if not control then
            return nil, 'not settable right now: ' .. key
        end

        if control.t == 'check' then
            if raw ~= 'true' and raw ~= 'false' then
                return nil, key .. ' takes true or false'
            end
            return { kind = 'set', key = key, value = (raw == 'true') }

        elseif control.t == 'slider' then
            -- tonumber alone is too permissive for an untrusted field: "0x10"
            -- parses as hex, "1e400" as an infinity that the clamp below would
            -- swallow silently, "1.0" as a float where every slider wants an
            -- integer. None of those would escape the clamp or crash, but they
            -- are side doors this format has no reason to open. Require plain
            -- decimal digits, optionally negative, before parsing.
            if not raw:match('^%-?%d+$') then
                return nil, key .. ' takes a whole number'
            end
            local value = tonumber(raw)
            if not value or value ~= value or value ~= math.floor(value) then
                return nil, key .. ' takes a whole number'
            end
            -- Clamp rather than refuse: the browser and the addon can disagree
            -- about a range for one poll after a job or level change, and the
            -- player asked for "as far as it goes", not for an error.
            if value < control.min then value = control.min end
            if value > control.max then value = control.max end
            return { kind = 'set', key = key, value = value }

        elseif control.t == 'combo' then
            for _, option in ipairs(control.options) do
                if option == raw then
                    -- 'None' maps to nil rather than the literal string: the
                    -- dropdowns that can be cleared carry 'None' as an option,
                    -- and storing the literal string would leave focus_target
                    -- set to a character called None. Folded into the options
                    -- scan (rather than checked up front) so a combo that does
                    -- not list 'None' rejects it like any other unknown value.
                    if raw == 'None' then
                        return { kind = 'set', key = key, value = nil }
                    end
                    return { kind = 'set', key = key, value = raw }
                end
            end
            return nil, key .. ' has no option ' .. raw
        end

        return nil, 'unsupported control for ' .. key

    elseif verb == 'ability' or verb == 'group' then
        local name = op[2]
        local enabled = on_off(op[3])
        if enabled == nil then return nil, name .. ' takes on or off' end
        local entry = index.ability[name]
        if not entry then return nil, 'no such row right now: ' .. name end
        local wants_group = (verb == 'group')
        if (entry.group and true or false) ~= wants_group then
            return nil, name .. ' is ' .. (entry.group and 'a group' or 'a single ability')
        end
        return { kind = 'ability', name = name, group = wants_group, value = enabled }

    elseif verb == 'buff' then
        local name, slot = op[2], op[3]
        local enabled = on_off(op[4])
        if enabled == nil then return nil, name .. ' takes on or off' end
        local entry = index.targets[name]
        if not entry then return nil, 'no such target row right now: ' .. name end
        if not entry.slots[slot] then
            return nil, name .. ' has no target ' .. slot
        end
        -- 'A' (bard area) stays a string; ME/P1-P5 are numeric keys in the
        -- live party_buffs table, which is what the toggle expects.
        return { kind = 'buff', name = name, group = entry.group and true or false,
                 slot = (slot == 'A') and 'A' or tonumber(slot), value = enabled }

    elseif verb == 'cmd' then
        if not VALID_COMMANDS[op[2]] then
            return nil, 'unknown command: ' .. tostring(op[2])
        end
        return { kind = 'cmd', word = op[2] }
    end

    return nil, 'unknown verb: ' .. tostring(verb)
end

--- Validate every op, then apply them in order.
-- ctx = { settings, index, toggles = { ability, buff, command, save } }.
-- Ability and target rows go through ctx.toggles rather than straight to
-- settings, because the in-game toggles carry rules the web app must not
-- reimplement: the two-song limit, exclusive Geo targets, and the disabled_
-- key each row keeps in sync.
function webui.apply(parsed, ctx)
    local planned = {}

    for i, op in ipairs(parsed.ops) do
        local call, err = plan_op(op, ctx.index)
        if not call then
            return { ok = false, err = string.format('line %d: %s', i, err) }
        end
        planned[i] = call
    end

    local dirty = false
    for _, call in ipairs(planned) do
        if call.kind == 'set' then
            ctx.settings[call.key] = call.value
            dirty = true
        elseif call.kind == 'ability' then
            ctx.toggles.ability(call.name, call.group, call.value)
        elseif call.kind == 'buff' then
            ctx.toggles.buff(call.name, call.group, call.slot, call.value)
        elseif call.kind == 'cmd' then
            ctx.toggles.command(call.word)
        end
    end

    -- The toggles save for themselves; a plain `set` does not.
    if dirty then ctx.toggles.save() end

    return { ok = true, applied = #planned }
end

--- The reply the web UI is waiting on.
function webui.format_response(id, result)
    local lines = { 'id|' .. tostring(id) }
    if result.ok then
        lines[#lines + 1] = 'ok|1'
        lines[#lines + 1] = string.format('msg|Applied %d change(s)', result.applied or 0)
    else
        lines[#lines + 1] = 'ok|0'
        lines[#lines + 1] = 'err|' .. tostring(result.err or 'unknown error')
    end
    return table.concat(lines, '\n') .. '\n'
end

-- ============================================================================
-- Files
--
-- Everything below runs in the game client only: AshitaCore for the install
-- path, and lazy requires for common/ui_config/components, which pull in
-- Ashita's own libraries and cannot load headless. Nothing above this line
-- touches either, which is what keeps tests/test_webui.lua runnable.
-- ============================================================================

-- Shape of state.json. The browser refuses a snapshot stamped with anything
-- else rather than guessing at a layout it does not know.
webui.STATE_FORMAT = 1

local enabled = false
local last_state = nil   -- last encoded snapshot, so an unchanged one skips the disk
local last_key = nil
local next_state = 0
local next_heartbeat = 0
local next_poll = 0

local STATE_INTERVAL = 1.0
local POLL_INTERVAL = 1.0
local HEARTBEAT_INTERVAL = 10.0

function webui.is_enabled()
    return enabled
end

function webui.set_enabled(on)
    enabled = on and true or false
    last_state = nil  -- force a rewrite on the next tick
end

-- Character keys are used verbatim as a directory name, so anything carrying a
-- separator or a dot could reach outside the addon's config folder.
function webui.is_valid_key(key)
    return type(key) == 'string' and #key > 0 and #key <= 64
        and key:match('^[%w_%-]+$') ~= nil
end

function webui.root_dir()
    -- GetInstallPath() returns the Ashita root with NO trailing separator --
    -- lib/core/party_share.lua's shared_dir() and Ashita's own
    -- addons/libs/settings.lua both add the '\' themselves. Do not "clean up"
    -- this literal backslash; without it every path here resolves one
    -- directory level off (...\Ashitaconfig\... instead of ...\Ashita\config\...)
    -- and the whole bridge silently reads and writes nothing.
    return string.format('%s\\config\\addons\\sidekick\\', AshitaCore:GetInstallPath())
end

function webui.character_dir(key)
    if not webui.is_valid_key(key) then return nil end
    return webui.root_dir() .. key .. '\\'
end

--- '<Name>_<ServerId>' -- the folder Ashita's settings module already made.
-- nil while zoning, when the party snapshot has no player in it yet.
function webui.character_key()
    local common = require('lib.core.common')
    local player = common.game_state and common.game_state.player
    if not player or not player.name or player.name == '' then return nil end
    if not player.server_id or player.server_id == 0 then return nil end
    local key = string.format('%s_%d', player.name, player.server_id)
    return webui.is_valid_key(key) and key or nil
end

local function write_file(path, body)
    local file = io.open(path, 'w')
    if not file then return false end
    file:write(body)
    file:close()
    return true
end

-- Shared by the periodic online beat, go_offline(), and the character-switch
-- beat below, so all three agree on the wire format.
local function write_heartbeat(dir, is_online)
    write_file(dir .. 'heartbeat.json',
        string.format('{"last_seen":%d,"is_online":%s}', os.time(), is_online and 'true' or 'false'))
end

--- Everything schema.build needs that only the game knows.
local function build_env(settings)
    local common = require('lib.core.common')
    local ui_config = require('lib.ui.config')
    local ui = require('lib.ui.components')
    local item = require('lib.actions.item')

    -- render() only runs while the config window is open, so a player who
    -- drives Sidekick entirely from the browser this session would otherwise
    -- never hydrate the mirror and see every target row read as unset even
    -- though settings.party_buffs holds real saved data.
    ui_config.hydrate_party_buffs(settings)

    local main_level, sub_level = common.get_player_level()

    local party_names = {}
    for i = 1, 5 do
        if common.is_party_member_active(i) then
            local name = common.get_party_member_name(i)
            if name and name ~= '' then party_names[#party_names + 1] = name end
        end
    end

    local tracked_names = {}
    for _, tracked in pairs(common.get_tracked_targets()) do
        tracked_names[#tracked_names + 1] = tracked.name
    end
    table.sort(tracked_names)

    local loaded = ui.item_inventory_loaded()
    local item_removals = {}
    if loaded then
        for _, entry in ipairs(item.REMOVALS) do
            item_removals[#item_removals + 1] = {
                key = entry.setting_key,
                label = string.format('%s with %s (%d)', entry.debuff_name, entry.item_name,
                    item.get_item_count(entry.item_id) or 0),
                value = settings[entry.setting_key] == true,
            }
        end
    end

    return {
        main_level = main_level or 0,
        sub_level = sub_level or 0,
        -- The player's own name, not the literal 'ME': render_party_dropdown
        -- writes a real character name into focus_target, and a dropdown whose
        -- options do not contain the saved value shows nothing selected.
        player_name = common.game_state.player.name,
        party_size = common.get_party_size(),
        party_names = party_names,
        tracked_names = tracked_names,
        party_buffs = ui_config.get_party_buffs(),
        item_removals = item_removals,
        item_inventory_loaded = loaded,
        has_spell = function(ability) return common.has_spell_learned(ability) end,
    }
end

--- The ctx the exported toggles expect, built from the same live tables the
-- config window uses so a browser click and an in-game click are one path.
local function toggle_ctx(deps)
    local ui_config = require('lib.ui.config')
    -- Same guarded hydration as build_env: poll() builds this ctx to apply a
    -- browser-driven buff/target toggle, and that has to land on the real
    -- saved rows even when build_env has not run yet this session.
    ui_config.hydrate_party_buffs(deps.settings)
    return {
        settings = deps.settings,
        save_callback = deps.save,
        party_buffs = ui_config.get_party_buffs(),
        party_buff_gates = ui_config.get_party_buff_gates(),
        job_def = deps.job_def,
    }
end

local function build_snapshot(deps, key)
    local common = require('lib.core.common')
    local schema = require('lib.ui.schema')

    local built = schema.build(deps.job_def, deps.settings, build_env(deps.settings))
    local main_job_id, sub_job_id = common.get_player_job()
    local main_level, sub_level = common.get_player_level()

    return {
        v = webui.STATE_FORMAT,
        key = key,
        character = common.game_state.player.name,
        job = common.get_job_name_from_id(main_job_id),
        job_id = main_job_id or 0,
        main_level = main_level or 0,
        sub_job = (sub_level and sub_level > 0 and sub_job_id and sub_job_id > 0)
            and common.get_job_name_from_id(sub_job_id) or 'None',
        sub_level = sub_level or 0,
        automation = deps.automation and true or false,
        status = deps.status or '',
        profile = deps.settings.active_profile or 'Default',
        sections = built.sections,
        globals = built.globals,
    }, built
end

--- Read, execute and answer at most one request for this character.
local function poll(deps, dir, built)
    local common = require('lib.core.common')
    local ui = require('lib.ui.components')
    local schema = require('lib.ui.schema')

    local path = dir .. 'request.txt'
    local file = io.open(path, 'r')
    if not file then return false end
    local body = file:read('*all')
    file:close()

    -- Remove it before doing anything else. A request that fails to validate
    -- must not be retried every second for the rest of the session, and one
    -- that throws must not be replayed. If the removal itself fails --
    -- file locks are far more common on Windows than POSIX -- request.txt
    -- stays on disk and would otherwise be re-read and re-applied on every
    -- following poll; cmd|toggle is a valid command, so a stuck removal
    -- would flip automation on and off once a second. Bail out with nothing
    -- applied and let the next poll retry the removal instead.
    local removed, remove_err = os.remove(path)
    if not removed then
        common.debugf('[WebUI] Could not remove %s: %s', path, tostring(remove_err))
        return false
    end

    local parsed, err = webui.parse_request(body, os.time())
    if not parsed then
        common.debugf('[WebUI] Rejected request: %s', tostring(err))
        write_file(dir .. 'response.txt', webui.format_response('unknown', { ok = false, err = err }))
        return false
    end

    local ctx = toggle_ctx(deps)
    local result = webui.apply(parsed, {
        settings = deps.settings,
        index = schema.index(built),
        toggles = {
            ability = function(name, is_group, on)
                if is_group then
                    ui.toggle_group(ctx, name, on)
                else
                    ui.toggle_ability(ctx, name, on)
                end
            end,
            buff = function(name, is_group, slot, on)
                if is_group then
                    ui.toggle_group_party_buff(ctx, name, slot, on)
                else
                    ui.toggle_party_buff(ctx, name, slot, on)
                end
            end,
            command = function(word) deps.exec('/sidekick ' .. word) end,
            save = deps.save,
        },
    })

    write_file(dir .. 'response.txt', webui.format_response(parsed.id, result))
    if not result.ok then
        common.debugf('[WebUI] Request %s failed: %s', parsed.id, tostring(result.err))
    end
    return result.ok
end

-- The actual per-frame work, split out so webui.tick can pcall the whole thing:
-- this touches disk, scans inventory and builds whatever schema the loaded
-- job produces, and a throw from a job-specific edge case must not escape
-- into Sidekick.lua's d3d_present handler and repeat every frame -- same
-- reasoning as automation.lua's per-module pcall.
local function do_tick(deps)
    if not enabled or not deps.settings or not deps.job_def then return end

    local key = webui.character_key()
    if not key then return end

    local dir = webui.character_dir(key)
    if not dir then return end
    if key ~= last_key then
        -- Switching characters at character select does not unload the
        -- addon, so without this the OLD character's heartbeat.json would
        -- stay "is_online":true forever and the web page would show a
        -- client that is gone as live. Write it for the key we are LEAVING,
        -- before last_key moves on to the new one.
        if last_key then
            local old_dir = webui.character_dir(last_key)
            if old_dir then write_heartbeat(old_dir, false) end
        end
        -- The settings module made this folder at load, but a first login on a
        -- new character can beat it there.
        ashita.fs.create_dir(dir)
        last_key = key
        last_state = nil
    end

    local now = os.clock()
    local json = require('lib.core.json')

    -- The snapshot and the request channel share one build of the schema: the
    -- browser is answered against exactly what it was last shown.
    local built = nil

    if now >= next_state then
        next_state = now + STATE_INTERVAL
        local snapshot
        snapshot, built = build_snapshot(deps, key)
        local encoded = json.encode(snapshot)
        -- Object keys are sorted, so an unchanged config encodes to an
        -- unchanged string and never reaches the disk.
        if encoded ~= last_state then
            if write_file(dir .. 'state.json', encoded) then
                last_state = encoded
            end
        end
    end

    if now >= next_poll then
        next_poll = now + POLL_INTERVAL
        if not built then
            local _
            _, built = build_snapshot(deps, key)
        end
        if poll(deps, dir, built) then
            -- A change just landed; write the snapshot back on the next tick
            -- rather than making the browser wait a full second to see it.
            next_state = 0
            last_state = nil
        end
    end

    if now >= next_heartbeat then
        next_heartbeat = now + HEARTBEAT_INTERVAL
        write_heartbeat(dir, true)
    end
end

--- Called every frame from Sidekick.lua's d3d_present handler. Self-throttled.
-- pcall-wrapped like automation.lua wraps each action module: a throw here
-- must not escape into the render loop and repeat every frame. The interval
-- gates inside do_tick advance BEFORE the risky work they guard, so even a
-- persistent failure is only retried -- and only logged -- once per second,
-- not 60 times; the next tick always gets to try again.
function webui.tick(deps)
    local ok, result = pcall(do_tick, deps)
    if not ok then
        local common = require('lib.core.common')
        common.errorf('[WebUI] tick failed: %s', tostring(result))
    end
end

--- Mark this character offline. Called on unload and when the feature is
-- switched off, so a browser tab does not show a client that is gone as live.
function webui.go_offline()
    local key = last_key or webui.character_key()
    local dir = key and webui.character_dir(key)
    if not dir then return end
    write_heartbeat(dir, false)
end

return webui
