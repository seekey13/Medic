--[[
    Minimal JSON encoder.

    One direction only. The addon writes state.json and heartbeat.json for the
    web UI to read; the web UI answers in a line format that lib/core/webui.lua
    parses with one split, so nothing here ever has to consume browser input and
    Sidekick carries no JSON *parser* at all.

    Object keys are sorted, which makes two encodes of equal data byte-identical
    -- webui.tick compares the encoded string against the last one written and
    skips the disk when nothing moved.
]]--

local json = {}

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function escape(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        return ESCAPES[c] or string.format('\\u%04X', string.byte(c))
    end))
end

--- Encode any Lua value as JSON.
-- A table with a non-nil [1] is an array; anything else is an object. Every
-- table this addon encodes is built in lib/ui/schema.lua, which keys party-buff
-- target maps as STRINGS ('0'..'5', 'A') precisely so a targets table can never
-- be mistaken for an array here.
function json.encode(value)
    local t = type(value)

    if t == 'string' then
        return '"' .. escape(value) .. '"'
    elseif t == 'boolean' then
        return tostring(value)
    elseif t == 'number' then
        -- NaN and the infinities are numbers to Lua and are not JSON. They can
        -- only arrive from arithmetic we got wrong; null keeps the file readable.
        if value ~= value or value == math.huge or value == -math.huge then
            return 'null'
        end
        return string.format('%.14g', value)
    elseif t == 'table' then
        local parts = {}

        if value[1] ~= nil then
            for i = 1, #value do
                parts[i] = json.encode(value[i])
            end
            return '[' .. table.concat(parts, ',') .. ']'
        end

        local keys = {}
        for k in pairs(value) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

        for i, k in ipairs(keys) do
            parts[i] = '"' .. escape(tostring(k)) .. '":' .. json.encode(value[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end

    return 'null'
end

return json
