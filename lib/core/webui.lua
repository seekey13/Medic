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
    local ops = {}

    for raw in text:gmatch('[^\r\n]+') do
        local fields = split_fields(raw)
        local verb = fields[1]

        if verb == 'id' then
            id = fields[2]
        elseif verb == 'ts' then
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
            -- 'None' first, and before the options scan: the dropdowns that can
            -- be cleared carry 'None' as an option, and storing the literal
            -- string would leave focus_target set to a character called None.
            if raw == 'None' then
                return { kind = 'set', key = key, value = nil }
            end
            for _, option in ipairs(control.options) do
                if option == raw then
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

return webui
