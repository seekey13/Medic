/*
 * The wire between this page and the game client.
 *
 * The addon answers in JSON (state.json, which the browser parses for free) but
 * reads a line format, so it needs no JSON parser of its own for anything a web
 * page wrote. Every line is '|'-separated fields with the verb first:
 *
 *     id|7f3a91cc
 *     ts|1772841600
 *     set|heal_threshold|75
 *     ability|Cure IV|off
 *     buff|Protect V|1|on
 *     cmd|start
 *
 * The addon validates every op against the schema it last exported, so an op
 * this file encodes correctly can still come back refused -- which is the right
 * answer when the player changed job between the render and the click.
 */
const SidekickProtocol = (() => {
    'use strict';

    // Booleans mean different words depending on the verb: a `set` writes a
    // real boolean setting, while the row verbs mirror an in-game ON/OFF button.
    const BOOL_AS_ON_OFF = new Set(['ability', 'group', 'buff']);
    const VERB_FIELDS = { set: 2, ability: 2, group: 2, buff: 3, cmd: 1 };

    function newId() {
        const raw = (crypto.randomUUID && crypto.randomUUID())
            || String(Date.now()) + Math.random().toString(36).slice(2);
        return raw.replace(/[^A-Za-z0-9-]/g, '').slice(0, 64);
    }

    function field(value, verb) {
        if (typeof value === 'boolean') {
            if (BOOL_AS_ON_OFF.has(verb)) return value ? 'on' : 'off';
            return value ? 'true' : 'false';
        }
        const text = String(value);
        // A field carrying the separator would arrive at the addon as two
        // fields and mean something the player never asked for.
        if (/[|\r\n]/.test(text)) {
            throw new Error(`value contains a field separator: ${text}`);
        }
        return text;
    }

    function encodeRequest({ id, ts, ops }) {
        const lines = [`id|${field(id, 'id')}`, `ts|${field(ts, 'ts')}`];

        for (const op of ops || []) {
            const [verb, ...rest] = op;
            const expected = VERB_FIELDS[verb];
            if (expected === undefined) {
                throw new Error(`unknown verb: ${verb}`);
            }
            if (rest.length !== expected) {
                throw new Error(`${verb} takes ${expected} field(s), got ${rest.length}`);
            }
            lines.push([verb, ...rest.map((value) => field(value, verb))].join('|'));
        }

        return lines.join('\n') + '\n';
    }

    function parseResponse(text) {
        const reply = { id: null, ok: false, msg: null, err: null };

        for (const line of String(text || '').split(/\r?\n/)) {
            if (!line) continue;
            // Only the first separator splits: an error message is free to
            // carry one, and truncating it would hide the reason.
            const cut = line.indexOf('|');
            if (cut < 0) continue;
            const key = line.slice(0, cut);
            const value = line.slice(cut + 1);

            if (key === 'id') reply.id = value;
            else if (key === 'ok') reply.ok = value === '1';
            else if (key === 'msg') reply.msg = value;
            else if (key === 'err') reply.err = value;
        }

        return reply;
    }

    return { newId, encodeRequest, parseResponse };
})();

// Lets tests/test-protocol.js require this file. `module` is undefined in the
// browser, so the browser never sees this line do anything.
if (typeof module !== 'undefined') { module.exports = SidekickProtocol; }
