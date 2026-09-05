/*
 * Self-check for web/protocol.js.
 *
 * Run from web/:
 *     node tests/test-protocol.js
 *
 * This is the only thing on the browser side that writes into the game client's
 * folder, so its output has to be exactly what lib/core/webui.lua parses --
 * including the on/off vs true/false split, which is per verb, not per value.
 */

const assert = require('assert');
const proto = require('../protocol.js');

// Ids -----------------------------------------------------------------------
const id = proto.newId();
assert.match(id, /^[A-Za-z0-9-]{1,64}$/, `id is not addon-safe: ${id}`);
assert.notStrictEqual(proto.newId(), proto.newId(), 'ids repeat');

// Envelope ------------------------------------------------------------------
const body = proto.encodeRequest({ id: 'abc', ts: 1772841600, ops: [] });
assert.strictEqual(body, 'id|abc\nts|1772841600\n', 'empty envelope wrong');

// set: booleans are true/false, numbers are plain, strings pass through -------
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['set', 'heal_enabled', true]] }),
    'id|a\nts|1\nset|heal_enabled|true\n');
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['set', 'heal_threshold', 75]] }),
    'id|a\nts|1\nset|heal_threshold|75\n');
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['set', 'risk_tier', 'highest']] }),
    'id|a\nts|1\nset|risk_tier|highest\n');

// ability/group/buff: booleans are on/off ------------------------------------
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['ability', 'Cure IV', false]] }),
    'id|a\nts|1\nability|Cure IV|off\n');
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['group', 'Protect', true]] }),
    'id|a\nts|1\ngroup|Protect|on\n');
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['buff', 'Protect V', '1', true]] }),
    'id|a\nts|1\nbuff|Protect V|1|on\n');
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [['cmd', 'start']] }),
    'id|a\nts|1\ncmd|start\n');

// Several ops keep their order: a request is applied top to bottom.
assert.strictEqual(
    proto.encodeRequest({ id: 'a', ts: 1, ops: [
        ['set', 'heal_enabled', true],
        ['ability', 'Cure IV', true],
    ] }),
    'id|a\nts|1\nset|heal_enabled|true\nability|Cure IV|on\n');

// A field carrying the separator would silently become two fields on the addon
// side, so refuse it here rather than send a request that means something else.
assert.throws(() => proto.encodeRequest({ id: 'a', ts: 1, ops: [['set', 'k', 'a|b']] }),
    /separator/i, 'a pipe in a value was not refused');
assert.throws(() => proto.encodeRequest({ id: 'a', ts: 1, ops: [['set', 'k', 'a\nb']] }),
    /separator/i, 'a newline in a value was not refused');
assert.throws(() => proto.encodeRequest({ id: 'a|b', ts: 1, ops: [] }),
    /separator/i, 'a pipe in the id was not refused');
assert.throws(() => proto.encodeRequest({ id: 'a', ts: 1, ops: [['exec', 'rm']] }),
    /verb/i, 'an unknown verb was encoded');

// Responses -----------------------------------------------------------------
const ok = proto.parseResponse('id|abc\nok|1\nmsg|Applied 2 change(s)\n');
assert.deepStrictEqual(ok, { id: 'abc', ok: true, msg: 'Applied 2 change(s)', err: null });

const bad = proto.parseResponse('id|abc\nok|0\nerr|line 1: nope\n');
assert.strictEqual(bad.ok, false);
assert.strictEqual(bad.err, 'line 1: nope');

// An error message can carry anything the addon put in it, separators included;
// only the first one splits.
assert.strictEqual(proto.parseResponse('id|a\nok|0\nerr|bad|value\n').err, 'bad|value');

// A file caught mid-write parses to nothing rather than to a false success.
assert.strictEqual(proto.parseResponse('id|abc\nok').ok, false);
assert.strictEqual(proto.parseResponse('').id, null);

console.log('test-protocol.js: OK');
