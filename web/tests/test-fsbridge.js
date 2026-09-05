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

function notAllowed() {
    return Object.assign(new Error('permission denied'), { name: 'NotAllowedError' });
}

// `permission` mirrors the real API: a handle whose grant was revoked mid-
// session throws NotAllowedError from calls made on it (root.getDirectoryHandle
// here), not NotFoundError -- a distinct failure fsbridge is expected to tell
// apart from "no such folder".
function fakeDir(files = {}, { permission = 'granted' } = {}) {
    const dir = {
        kind: 'directory',
        files,
        permission,
        async *entries() {
            if (dir.permission !== 'granted') throw notAllowed();
            for (const entry of Object.entries(files)) yield entry;
        },
        async getDirectoryHandle(name) {
            if (dir.permission !== 'granted') throw notAllowed();
            if (!files[name] || files[name].kind !== 'directory') throw notFound();
            return files[name];
        },
        async getFileHandle(name, opts = {}) {
            if (dir.permission !== 'granted') throw notAllowed();
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
        async removeEntry(name) {
            if (dir.permission !== 'granted') throw notAllowed();
            delete files[name];
        },
    };
    return dir;
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
    // That is only worth anything on screen if it actually repaints: a caller
    // gates its re-render on `changed`, exactly like this file's own comments
    // describe for the mtime cache, so a valid-to-outdated transition that
    // does not set `changed` would never surface the warning.
    root.files.Seekey_33748.files['state.json'] = fakeFile(snapshot({ v: 99 }));
    read = await bridge.readAllStates(root, cache);
    assert.deepStrictEqual(read.outdated, ['Seekey_33748'], 'a future format was not reported');
    assert.deepStrictEqual(Object.keys(read.states), [], 'a future format was rendered anyway');
    assert.strictEqual(read.changed, true,
        'a valid-to-outdated transition did not report a change');

    // A character that stays outdated across polls (no file change at all)
    // must not re-report the change forever: the caller repaints only when
    // `changed` is true, and a stale addon build would otherwise force an
    // unbounded repaint loop for as long as the tab stays open.
    const steadyOutdated = await bridge.readAllStates(root, cache);
    assert.deepStrictEqual(steadyOutdated.outdated, ['Seekey_33748'],
        'a steady-state outdated character stopped being reported as outdated');
    assert.strictEqual(steadyOutdated.changed, false,
        'a steady-state outdated character re-reported a change on every poll');

    // Recovering from outdated (the player updated their addon) must still
    // surface as a change, and the character must stop being listed as
    // outdated once it is valid again.
    root.files.Seekey_33748.files['state.json'] = fakeFile(snapshot());
    const recovered = await bridge.readAllStates(root, cache);
    assert.deepStrictEqual(recovered.outdated, [],
        'a recovered character was still reported outdated');
    assert.strictEqual(recovered.states.Seekey_33748.character, 'Seekey',
        'a recovered character was not rendered');
    assert.strictEqual(recovered.changed, true,
        'an outdated-to-valid transition did not report a change');

    // Same failure mode, but on the very first read: the character was
    // already outdated before this page ever saw it. There is no prior state
    // to "transition" away from, so this path has to set `changed` on its own
    // rather than relying on the sweep loop, which cannot see a key that was
    // deleted from `seen`/`cache` inside the same iteration that added it.
    const freshCache = new Map();
    const freshRoot = fakeDir({
        Seekey_33748: fakeDir({ 'state.json': fakeFile(snapshot({ v: 99 })) }),
    });
    const freshRead = await bridge.readAllStates(freshRoot, freshCache);
    assert.deepStrictEqual(freshRead.outdated, ['Seekey_33748'],
        'an already-outdated first read was not reported');
    assert.deepStrictEqual(Object.keys(freshRead.states), [],
        'an already-outdated first read was rendered anyway');
    assert.strictEqual(freshRead.changed, true,
        'an already-outdated first read did not report a change');

    // An outdated character whose folder disappears entirely must still be
    // swept out of the cache and reported as a change, exactly like a valid
    // one -- losing track of it silently would leave a stale "update your
    // addon" banner with nothing behind it to confirm.
    const dropCache = new Map();
    const dropRoot = fakeDir({
        Seekey_33748: fakeDir({ 'state.json': fakeFile(snapshot({ v: 99 })) }),
    });
    await bridge.readAllStates(dropRoot, dropCache);
    delete dropRoot.files.Seekey_33748;
    const dropped = await bridge.readAllStates(dropRoot, dropCache);
    assert.deepStrictEqual(dropped.outdated, [],
        'an outdated character removed from disk was still reported outdated');
    assert.strictEqual(dropped.changed, true,
        'an outdated character removed from disk did not report a change');

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

    // A revoked permission is not the same failure as no folder at all: the
    // fix for it lives in a browser re-grant, not in picking a new folder.
    const deniedRoot = fakeDir({}, { permission: 'denied' });
    const denied = await bridge.request(deniedRoot, 'Seekey_33748', [['cmd', 'stop']]);
    assert.strictEqual(denied.ok, false);
    assert.ok(/permission/i.test(denied.err || ''),
        `a revoked permission was not distinguished from a missing folder: ${denied.err}`);

    // The fake's permission flag must behave like the real API: once
    // revoked, every call on the handle fails, not only getDirectoryHandle.
    // Revoke it only after the character directory handle is already in
    // hand, so this actually exercises getFileHandle/removeEntry/entries()
    // instead of the getDirectoryHandle check every other test relies on.
    const revokeAfterOpenRoot = fakeDir({
        Seekey_33748: fakeDir({ 'state.json': fakeFile(snapshot()) }),
    });
    const revokeAfterOpenDir = revokeAfterOpenRoot.files.Seekey_33748;
    revokeAfterOpenDir.permission = 'denied';
    await assert.rejects(() => revokeAfterOpenDir.getFileHandle('state.json'),
        { name: 'NotAllowedError' }, 'getFileHandle ignored a revoked permission');
    await assert.rejects(() => revokeAfterOpenDir.removeEntry('state.json'),
        { name: 'NotAllowedError' }, 'removeEntry ignored a revoked permission');
    await assert.rejects(async () => {
        for await (const entry of revokeAfterOpenDir.entries()) { void entry; }
    }, { name: 'NotAllowedError' }, 'entries() ignored a revoked permission');

    // Two tabs can both pass the check-then-write gap in sendRequest and one
    // clobbers the other's request.txt before either write lands. The loser
    // must not report queued:true on timeout -- its bytes never reached disk,
    // so there is nothing left to run at the character's next login.
    const raceRoot = fakeDir({ Seekey_33748: fakeDir({}) });
    const raceDir = raceRoot.files.Seekey_33748;
    // No responder runs in this scenario -- the point is what a losing call
    // reports about *why* it never heard back, not a real reply. Simulate the
    // winning tab's write landing shortly after ours, mid-poll.
    setTimeout(() => {
        raceDir.files['request.txt'] = fakeFile('id|other-tab-id\nts|1\ncmd|start\n');
    }, 20);
    const raced = await bridge.request(raceRoot, 'Seekey_33748',
        [['cmd', 'stop']], { pollMs: 5, timeoutMs: 100 });
    assert.strictEqual(raced.ok, false);
    assert.notStrictEqual(raced.queued, true,
        'a request clobbered by a racing tab falsely reported queued:true');

    // Same race, but the winning tab's request has already been picked up and
    // removed by the time we time out -- not just overwritten with a foreign
    // id. Still not "queued": there is nothing of ours left on disk.
    const raceRoot2 = fakeDir({ Seekey_33748: fakeDir({}) });
    const raceDir2 = raceRoot2.files.Seekey_33748;
    setTimeout(() => { delete raceDir2.files['request.txt']; }, 20);
    const raced2 = await bridge.request(raceRoot2, 'Seekey_33748',
        [['cmd', 'stop']], { pollMs: 5, timeoutMs: 100 });
    assert.strictEqual(raced2.ok, false);
    assert.notStrictEqual(raced2.queued, true,
        'a request removed from disk by a racing tab falsely reported queued:true');

    // The post-timeout re-read of request.txt is itself fallible -- a
    // permission revocation or a delete can land in the exact window between
    // the deadline and this confirmation check. Make that specific re-read
    // (and only it) fail, without disturbing the two earlier, unrelated
    // request.txt look-ups that precede it (the "already queued" check and
    // the create-on-write): a call-count trap is deterministic, where a
    // timer racing the poll loop would not be.
    const flakyRoot = fakeDir({ Seekey_33748: fakeDir({}) });
    const flakyDir = flakyRoot.files.Seekey_33748;
    const realFlakyGetFileHandle = flakyDir.getFileHandle.bind(flakyDir);
    let requestTxtCalls = 0;
    flakyDir.getFileHandle = async (name, opts = {}) => {
        if (name === 'request.txt') {
            requestTxtCalls += 1;
            if (requestTxtCalls === 3) throw notAllowed();
        }
        return realFlakyGetFileHandle(name, opts);
    };
    const flaky = await bridge.request(flakyRoot, 'Seekey_33748',
        [['cmd', 'stop']], { pollMs: 5, timeoutMs: 40 });
    assert.strictEqual(flaky.ok, false);
    assert.notStrictEqual(flaky.queued, true,
        'a failed post-timeout re-read falsely reported queued:true');

    // The per-character queue: two overlapping calls for the same key must be
    // serialised (the second only starts once the first has fully settled),
    // and the queue must not leak an entry once both are done.
    const queueRoot = fakeDir({ Seekey_33748: fakeDir({}) });
    const queueDir = queueRoot.files.Seekey_33748;
    const answeredIds = [];
    const queueAnswer = setInterval(() => {
        const written = queueDir.files['request.txt'];
        if (!written) return;
        const reqId = /^id\|(.+)$/m.exec(written.text)[1];
        answeredIds.push(reqId);
        delete queueDir.files['request.txt'];
        queueDir.files['response.txt'] = fakeFile(`id|${reqId}\nok|1\nmsg|Applied 1 change(s)\n`);
    }, 5);

    // Fired back to back, with neither awaited first: if the second were not
    // serialised behind the first, it would run concurrently and see the
    // first's still-on-disk request.txt, tripping the "already queued" guard
    // instead of getting its own turn.
    const q1 = bridge.request(queueRoot, 'Seekey_33748', [['cmd', 'start']], { pollMs: 5, timeoutMs: 2000 });
    const q2 = bridge.request(queueRoot, 'Seekey_33748', [['cmd', 'stop']], { pollMs: 5, timeoutMs: 2000 });
    const [q1Result, q2Result] = await Promise.all([q1, q2]);
    clearInterval(queueAnswer);

    assert.strictEqual(q1Result.ok, true, `first overlapping call failed: ${q1Result.err}`);
    assert.strictEqual(q2Result.ok, true,
        `second overlapping call was not serialised behind the first: ${q2Result.err}`);
    assert.strictEqual(answeredIds.length, 2,
        'both overlapping calls should have been written and answered separately');
    assert.strictEqual(bridge._inFlightSize(), 0,
        'the in-flight queue leaked an entry after both overlapping calls settled');

    console.log('test-fsbridge.js: OK');
})().catch((err) => { console.error(err); process.exit(1); });
