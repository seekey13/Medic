/*
 * Self-check for web/fsbridge.js against an in-memory File System Access API.
 *
 * Run from web/:
 *     node tests/test-fsbridge.js
 *
 * The real API only exists in a Chromium browser, so this fakes the handle
 * types fsbridge actually uses. If fsbridge starts calling something the fake
 * does not implement, this fails loudly, which is the point.
 */

const assert = require('assert');
const bridge = require('../fsbridge.js');

let clock = 1_000_000;

function notFound() {
    return Object.assign(new Error('not found'), { name: 'NotFoundError' });
}

function fakeFile(text) {
    return { kind: 'file', text, lastModified: ++clock };
}

function fakeDir(files = {}) {
    return {
        kind: 'directory',
        files,
        async *entries() {
            for (const entry of Object.entries(files)) yield entry;
        },
        async getDirectoryHandle(name) {
            if (!files[name] || files[name].kind !== 'directory') throw notFound();
            return files[name];
        },
        async getFileHandle(name, opts = {}) {
            if (!files[name]) {
                if (!opts.create) throw notFound();
                files[name] = fakeFile('');
            }
            const self = files[name];
            return {
                kind: 'file',
                async getFile() {
                    return { lastModified: self.lastModified, async text() { return self.text; } };
                },
                async createWritable() {
                    return {
                        async write(body) { self.text = body; },
                        async close() { self.lastModified = ++clock; },
                    };
                },
            };
        },
        async removeEntry(name) { delete files[name]; },
    };
}

function snapshot(overrides = {}) {
    return JSON.stringify(Object.assign({
        v: 1,
        key: 'Seekey_33748',
        character: 'Seekey',
        job: 'White Mage',
        automation: true,
        sections: [],
        globals: [],
    }, overrides));
}

(async () => {
    // Reading -------------------------------------------------------------
    const root = fakeDir({
        Seekey_33748: fakeDir({
            'state.json': fakeFile(snapshot()),
            'heartbeat.json': fakeFile('{"last_seen":1772841600,"is_online":true}'),
        }),
        'not a key!': fakeDir({ 'state.json': fakeFile(snapshot()) }),
        'party_Seekey.txt': fakeFile('ignored'),
    });

    const cache = new Map();
    let read = await bridge.readAllStates(root, cache);
    assert.deepStrictEqual(Object.keys(read.states), ['Seekey_33748'],
        'only well-formed character folders are read');
    assert.strictEqual(read.changed, true, 'a first read is a change');
    assert.strictEqual(read.states.Seekey_33748.character, 'Seekey');
    assert.strictEqual(read.states.Seekey_33748.last_seen, 1772841600, 'heartbeat not joined');
    assert.strictEqual(read.states.Seekey_33748.online_flag, true);

    // An unchanged folder is not a change: the whole point of the mtime check
    // is that a ten-second heartbeat does not force a re-render.
    read = await bridge.readAllStates(root, cache);
    assert.strictEqual(read.changed, false, 'an unchanged snapshot re-reported as changed');

    // A snapshot in a layout this page does not know is an addon that needs
    // updating, which is worth saying rather than rendering as an empty config.
    root.files.Seekey_33748.files['state.json'] = fakeFile(snapshot({ v: 99 }));
    read = await bridge.readAllStates(root, cache);
    assert.deepStrictEqual(read.outdated, ['Seekey_33748'], 'a future format was not reported');
    assert.deepStrictEqual(Object.keys(read.states), [], 'a future format was rendered anyway');

    // Truncated JSON means we caught the addon mid-write; keep the last good one.
    const cache2 = new Map();
    const live = fakeDir({ Seekey_33748: fakeDir({ 'state.json': fakeFile(snapshot()) }) });
    await bridge.readAllStates(live, cache2);
    live.files.Seekey_33748.files['state.json'] = fakeFile('{"v":1,"sec');
    const partial = await bridge.readAllStates(live, cache2);
    assert.strictEqual(partial.states.Seekey_33748.character, 'Seekey',
        'a mid-write read dropped the last good snapshot');

    // A folder that disappears drops out of the cache.
    delete live.files.Seekey_33748;
    const gone = await bridge.readAllStates(live, cache2);
    assert.deepStrictEqual(Object.keys(gone.states), [], 'a removed character stayed');
    assert.strictEqual(gone.changed, true, 'a removal is a change');

    // Requesting -----------------------------------------------------------
    const reqRoot = fakeDir({ Seekey_33748: fakeDir({}) });
    const dir = reqRoot.files.Seekey_33748;

    // Answer as the addon would, one tick later.
    const answer = setInterval(() => {
        const written = dir.files['request.txt'];
        if (!written) return;
        const id = /^id\|(.+)$/m.exec(written.text)[1];
        delete dir.files['request.txt'];
        dir.files['response.txt'] = fakeFile(`id|${id}\nok|1\nmsg|Applied 1 change(s)\n`);
    }, 5);

    const reply = await bridge.request(reqRoot, 'Seekey_33748',
        [['set', 'heal_threshold', 40]], { pollMs: 5, timeoutMs: 2000 });
    assert.strictEqual(reply.ok, true, `request failed: ${reply.err}`);
    assert.strictEqual(dir.files['response.txt'], undefined, 'the reply was not cleaned up');
    clearInterval(answer);

    assert.strictEqual((await bridge.request(reqRoot, 'nope!', [['cmd', 'start']])).ok, false,
        'an invalid character key was accepted');
    assert.strictEqual((await bridge.request(reqRoot, 'Missing_1', [['cmd', 'start']])).ok, false,
        'a character with no folder was accepted');

    // A client that is not running never answers. Saying the request failed
    // would be a lie the player acts on: it is on disk and will run at login.
    const timedOut = await bridge.request(reqRoot, 'Seekey_33748',
        [['cmd', 'stop']], { pollMs: 5, timeoutMs: 40 });
    assert.strictEqual(timedOut.ok, false);
    assert.strictEqual(timedOut.queued, true, 'a timeout did not report the request as queued');

    console.log('test-fsbridge.js: OK');
})().catch((err) => { console.error(err); process.exit(1); });
