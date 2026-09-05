/*
 * Sidekick local-folder bridge.
 *
 * The app is served from Cloudflare and holds no data of its own. Everything it
 * displays comes out of the folder the user grants it -- the addon's
 * config\addons\sidekick directory -- and every change it makes is a request
 * file dropped into a character's folder for the game client to pick up.
 *
 * Chromium only: this is the File System Access API, which Firefox and Safari
 * do not implement.
 */
const SidekickBridge = (() => {
    'use strict';

    // Mirrors webui.is_valid_key on the Lua side. These are directory names, so
    // a request for anything else never reaches a lookup.
    const CHARACTER_KEY_RE = /^[A-Za-z0-9_-]{1,64}$/;

    const DB_NAME = 'sidekick';
    const STORE = 'handles';
    const HANDLE_KEY = 'root';

    // The addon polls once a second, so anything under about three would
    // produce false timeouts.
    const DEFAULT_TIMEOUT_MS = 15000;
    const DEFAULT_POLL_MS = 300;

    // Snapshot layout this reader understands. The addon stamps every
    // state.json with it; anything else is an addon that needs updating.
    const STATE_FORMAT = 1;

    const proto = (typeof module !== 'undefined')
        ? require('./protocol.js')
        : SidekickProtocol;

    function isSupported() {
        return typeof window !== 'undefined' && typeof window.showDirectoryPicker === 'function';
    }

    async function pickFolder() {
        return window.showDirectoryPicker({
            id: 'sidekick-config',
            mode: 'readwrite',
            startIn: 'documents',
        });
    }

    // --- Handle persistence -------------------------------------------------
    // Directory handles are structured-cloneable, so IndexedDB can hold one
    // across sessions and the user is not asked to re-pick the folder on every
    // launch. They still need a permission re-grant on a user gesture.

    function openDb() {
        return new Promise((resolve, reject) => {
            const req = indexedDB.open(DB_NAME, 1);
            req.onupgradeneeded = () => req.result.createObjectStore(STORE);
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });
    }

    function dbRequest(db, mode, run) {
        return new Promise((resolve, reject) => {
            const tx = db.transaction(STORE, mode);
            const req = run(tx.objectStore(STORE));
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });
    }

    async function saveHandle(handle) {
        const db = await openDb();
        try {
            await dbRequest(db, 'readwrite', (store) => store.put(handle, HANDLE_KEY));
        } finally {
            db.close();
        }
    }

    async function loadHandle() {
        try {
            const db = await openDb();
            try {
                return (await dbRequest(db, 'readonly', (store) => store.get(HANDLE_KEY))) || null;
            } finally {
                db.close();
            }
        } catch (err) {
            // A private window, or storage the user cleared. Not worth
            // interrupting startup for -- the folder picker still works.
            console.warn('Could not read the saved folder handle:', err);
            return null;
        }
    }

    async function ensurePermission(handle, { prompt = false } = {}) {
        const opts = { mode: 'readwrite' };
        if ((await handle.queryPermission(opts)) === 'granted') return true;
        if (!prompt) return false;
        return (await handle.requestPermission(opts)) === 'granted';
    }

    // --- Reading ------------------------------------------------------------

    async function getFileHandle(dir, name, create = false) {
        try {
            return await dir.getFileHandle(name, { create });
        } catch (err) {
            if (err && err.name === 'NotFoundError') return null;
            throw err;
        }
    }

    async function readJson(dir, name) {
        const handle = await getFileHandle(dir, name);
        if (!handle) return null;
        const file = await handle.getFile();
        try {
            return { value: JSON.parse(await file.text()), lastModified: file.lastModified };
        } catch (err) {
            // Caught the addon mid-write. The caller keeps whatever it had.
            return null;
        }
    }

    /**
     * Read every character's config snapshot.
     *
     * Two files per character, on separate clocks:
     *   state.json      the config, rewritten only when something actually moves
     *   heartbeat.json  last_seen, rewritten every ten seconds
     *
     * They are separate so the liveness ping does not drag the whole config
     * through JSON.parse to say that nothing happened.
     *
     * `cache` is caller-owned and holds the last parsed snapshot per character,
     * keyed on file mtime. Returns `{ states, changed, outdated }`.
     */
    async function readAllStates(root, cache) {
        const seen = new Set();
        const outdated = [];
        let changed = false;

        for await (const [name, handle] of root.entries()) {
            if (handle.kind !== 'directory' || !CHARACTER_KEY_RE.test(name)) continue;

            const stateHandle = await getFileHandle(handle, 'state.json');
            if (!stateHandle) continue;
            seen.add(name);

            let entry = cache.get(name);
            if (!entry) {
                entry = { stateModified: null, state: null };
                cache.set(name, entry);
            }

            const file = await stateHandle.getFile();
            if (file.lastModified !== entry.stateModified) {
                let snapshot;
                try {
                    snapshot = JSON.parse(await file.text());
                } catch (err) {
                    continue; // Mid-write. Keep the last good snapshot.
                }

                if (snapshot.v !== STATE_FORMAT) {
                    // Guessing at a layout we do not know draws an empty config
                    // and blames the game for it.
                    outdated.push(name);
                    seen.delete(name);
                    cache.delete(name);
                    continue;
                }

                entry.state = snapshot;
                entry.stateModified = file.lastModified;
                changed = true;
            }

            // Liveness is deliberately not a change: last_seen ticks every ten
            // seconds forever, and re-rendering on that is the cost this layout
            // exists to remove. The reader decides what the numbers mean.
            const beat = await readJson(handle, 'heartbeat.json');
            if (beat && entry.state) {
                entry.state.last_seen = beat.value.last_seen || 0;
                entry.state.online_flag = beat.value.is_online;
            }
        }

        for (const key of [...cache.keys()]) {
            if (!seen.has(key)) {
                cache.delete(key);
                changed = true;
            }
        }

        const states = {};
        for (const [key, entry] of cache) {
            if (entry.state) states[key] = entry.state;
        }
        return { states, changed, outdated };
    }

    // --- Requests -----------------------------------------------------------

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    // Requests are serialised per character in this tab. The on-disk check in
    // sendRequest is a check-then-write with a gap, so two callers in the same
    // tick would both pass it and the second would clobber the first.
    // ponytail: per-tab only. Two tabs on the same folder still race, which the
    // on-disk check catches most of the time and the addon's id echo catches
    // the rest.
    const inFlight = new Map();

    function request(root, characterKey, ops, options = {}) {
        const previous = inFlight.get(characterKey) || Promise.resolve();
        const next = previous
            .catch(() => {})
            .then(() => sendRequest(root, characterKey, ops, options));
        inFlight.set(characterKey, next);
        next.catch(() => {}).then(() => {
            if (inFlight.get(characterKey) === next) inFlight.delete(characterKey);
        });
        return next;
    }

    async function sendRequest(root, characterKey, ops, options = {}) {
        const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
        const pollMs = options.pollMs ?? DEFAULT_POLL_MS;

        if (!CHARACTER_KEY_RE.test(String(characterKey || ''))) {
            return { ok: false, err: 'Invalid character key' };
        }

        let dir;
        try {
            dir = await root.getDirectoryHandle(characterKey);
        } catch (err) {
            return { ok: false, err: `No folder for ${characterKey}` };
        }

        // One request in flight per character. Overwriting a queued one would
        // silently drop whatever the player asked for first.
        if (await getFileHandle(dir, 'request.txt')) {
            return { ok: false, err: 'A request for this character is already queued' };
        }

        const id = proto.newId();
        let body;
        try {
            body = proto.encodeRequest({ id, ts: Math.floor(Date.now() / 1000), ops });
        } catch (err) {
            return { ok: false, err: err.message };
        }

        const handle = await dir.getFileHandle('request.txt', { create: true });
        const writable = await handle.createWritable();
        await writable.write(body);
        // Chromium writes to a swap file and swaps it in here, so the addon
        // never reads a half-written request.
        await writable.close();

        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
            await sleep(pollMs);
            const replyHandle = await getFileHandle(dir, 'response.txt');
            if (!replyHandle) continue;

            const reply = proto.parseResponse(await (await replyHandle.getFile()).text());
            if (reply.id !== id) continue; // Someone else's, or stale.

            await dir.removeEntry('response.txt').catch(() => {});
            return reply;
        }

        // The request is still on disk and runs when that client next starts --
        // saying it failed would be a lie the player acts on.
        return {
            ok: false,
            queued: true,
            err: 'No reply from the game client. The change is queued and will apply '
                + 'next time this character logs in with /sk webui on.',
        };
    }

    return {
        isSupported, pickFolder, saveHandle, loadHandle, ensurePermission,
        readAllStates, request, STATE_FORMAT,
    };
})();

if (typeof module !== 'undefined') { module.exports = SidekickBridge; }
