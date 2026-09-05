/*
 * Sidekick web UI.
 *
 * There is no server. The page reads the addon's own config folder, which the
 * user grants once through the browser's folder picker, and writes back one
 * request file at a time for the game client to execute.
 *
 * It keeps no model of the config: every click reads its op out of the clicked
 * element's data attributes, sends it, and waits for the addon's next snapshot
 * to redraw. That is a beat slower than an optimistic update and it is never
 * wrong about what the client actually did.
 */
(() => {
    'use strict';

    const POLL_INTERVAL_MS = 1000;
    // The addon's heartbeat rewrites every 10 seconds, so a character whose file
    // has not moved in 30 is not running.
    const ONLINE_TIMEOUT_SECONDS = 30;

    let root = null;
    let pollTimer = null;
    const cache = new Map();
    let states = {};
    let activeKey = null;
    let busy = false;

    const el = (id) => document.getElementById(id);

    // --- Overlay + toast ---------------------------------------------------

    function showConnectOverlay(message, showButton = true) {
        if (message) el('connectMessage').textContent = message;
        el('connectButton').style.display = showButton ? '' : 'none';
        el('connectOverlay').classList.remove('hidden');
    }

    function hideConnectOverlay() {
        el('connectOverlay').classList.add('hidden');
    }

    let toastTimer = null;
    function toast(text, isError) {
        const node = el('toast');
        node.textContent = text;
        node.classList.toggle('error', !!isError);
        node.classList.add('visible');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => node.classList.remove('visible'), 4000);
    }

    // --- Rendering ---------------------------------------------------------

    // A redraw replaces the section list wholesale, so the details elements the
    // user opened by hand would snap shut on every poll. Carry their state over.
    // We also track whether any sections existed before redraw: if the prior render
    // produced sections, restore what was open; if there was no prior render,
    // let the schema's enabled/open default take effect. We cannot distinguish
    // "first render" from "user closed all sections" by checking the open set alone.
    function openSectionKeys() {
        const open = new Set();
        const allDetails = document.querySelectorAll('#sections details');
        const hadSections = allDetails.length > 0;
        for (const details of allDetails) {
            if (details.open) {
                const key = details.querySelector('input[data-key]')?.dataset.key;
                if (key) open.add(key);
            }
        }
        return { keys: open, hadSections };
    }

    function render() {
        el('characterButtons').innerHTML =
            SidekickRender.characterButtonsHtml(states, activeKey);

        const state = states[activeKey];
        if (!state) {
            el('headerBlock').innerHTML = '';
            el('sections').innerHTML = '<div class="loading">Waiting for a character&hellip;</div>';
            el('globals').innerHTML = '';
            return;
        }

        const { keys: wasOpen, hadSections } = openSectionKeys();
        el('headerBlock').innerHTML = SidekickRender.headerHtml(state);
        el('sections').innerHTML = SidekickRender.sectionsHtml(state.sections);
        el('globals').innerHTML = SidekickRender.globalsHtml(state.globals);

        // Restore what the user had open, over the schema's own enabled/open
        // default -- their last click wins over the addon's suggestion. Only
        // restore if a prior render existed (hadSections); on first render, let
        // the schema's default guide the open state.
        if (hadSections) {
            for (const details of document.querySelectorAll('#sections details')) {
                const key = details.querySelector('input[data-key]')?.dataset.key;
                if (key) details.open = wasOpen.has(key);
            }
        }
    }

    // --- Sending -----------------------------------------------------------

    async function send(ops) {
        if (!root || !activeKey || busy) return;
        busy = true;
        try {
            const reply = await SidekickBridge.request(root, activeKey, ops);
            if (!reply.ok) toast(reply.err || 'The game client refused that change.', true);
            // A success needs no toast: the next snapshot shows the change,
            // which is the confirmation that matters.
            await refreshFromDisk();
        } catch (err) {
            toast(`Could not reach the game client: ${err.message}`, true);
        } finally {
            busy = false;
        }
    }

    // Every interactive element carries its own op, so one listener covers the
    // whole page -- sections, gear panel and header alike.
    function opFor(node) {
        const op = node.dataset.op;
        if (op === 'set') {
            if (node.type === 'checkbox') return ['set', node.dataset.key, node.checked];
            if (node.type === 'range') return ['set', node.dataset.key, Number(node.value)];
            return ['set', node.dataset.key, node.value];
        }
        if (op === 'ability' || op === 'group') return [op, node.dataset.name, node.checked];
        if (op === 'buff') {
            return ['buff', node.dataset.name, node.dataset.slot, node.dataset.on !== 'true'];
        }
        if (op === 'cmd') return ['cmd', node.dataset.word];
        return null;
    }

    document.addEventListener('click', (event) => {
        const charButton = event.target.closest('[data-char]');
        if (charButton) {
            activeKey = charButton.dataset.char;
            render();
            return;
        }

        // A range fires 'change', not 'click'; a select fires 'change' too.
        const node = event.target.closest('[data-op]');
        if (!node || node.type === 'range' || node.tagName === 'SELECT') return;

        // Clicking the enable checkbox inside a summary must not also toggle the
        // details open -- the checkbox is the feature switch, the label is the
        // collapse. A checkbox's checked state flips before the click event fires,
        // and cancelling the event makes the browser revert it after dispatch finishes.
        // Capture the intended value and reassert it in a macrotask so it sticks.
        if (node.type === 'checkbox' && node.closest('summary')) {
            const intendedValue = node.checked;
            event.preventDefault();
            // Must be async (macrotask) to run after the browser's canceled activation
            // steps revert the checkbox. Reasserting it synchronously would have no effect.
            setTimeout(() => { node.checked = intendedValue; }, 0);
        }

        const op = opFor(node);
        if (op) send([op]);
    });

    document.addEventListener('change', (event) => {
        const node = event.target.closest('[data-op]');
        if (!node || (node.type !== 'range' && node.tagName !== 'SELECT')) return;
        const op = opFor(node);
        if (op) send([op]);
    });

    // Live readout while dragging, so the number under the thumb is not a poll
    // behind the thumb.
    document.addEventListener('input', (event) => {
        const node = event.target;
        if (node.type !== 'range' || !node.dataset.key) return;
        const output = document.querySelector(`[data-readout="${CSS.escape(node.dataset.key)}"]`);
        if (output) output.value = node.value;
    });

    // --- Polling -----------------------------------------------------------

    // The addon can only write is_online=false on a clean unload, so a client
    // that crashed would read as Online forever. A running client bumps
    // last_seen every ten seconds, so staleness is what actually answers the
    // question -- and only the reader can notice it.
    function applyOnlineFreshness(all) {
        const now = Date.now() / 1000;
        let flipped = false;
        for (const state of Object.values(all)) {
            const fresh = state.online_flag !== false
                && (now - (state.last_seen || 0)) < ONLINE_TIMEOUT_SECONDS;
            if (state.is_online !== fresh) flipped = true;
            state.is_online = fresh;
        }
        return flipped;
    }

    async function refreshFromDisk() {
        if (!root) return;
        try {
            const read = await SidekickBridge.readAllStates(root, cache);

            if (read.outdated.length > 0 && Object.keys(read.states).length === 0) {
                showConnectOverlay(`The Sidekick addon writing ${read.outdated.join(', ')} is `
                    + 'older than this page. Update the addon in Ashita, then log the '
                    + 'character in again.');
                return;
            }

            if (Object.keys(read.states).length === 0) {
                showConnectOverlay('No characters found in that folder. Turn the bridge on in '
                    + 'game with /sk webui on, and choose your Ashita '
                    + 'config\\addons\\sidekick folder -- the one holding a folder per '
                    + 'character, not the addons\\Sidekick folder the Lua files live in.');
                return;
            }

            const flipped = applyOnlineFreshness(read.states);
            if (!read.changed && !flipped) return;

            hideConnectOverlay();
            states = read.states;
            if (!states[activeKey]) activeKey = Object.keys(states)[0];
            render();
        } catch (err) {
            console.error('Failed to read the Sidekick folder:', err);
            stopPolling();
            showConnectOverlay('Lost access to your Sidekick folder. Choose it again to reconnect.');
        }
    }

    function startPolling() {
        stopPolling();
        refreshFromDisk();
        pollTimer = setInterval(refreshFromDisk, POLL_INTERVAL_MS);
    }

    function stopPolling() {
        if (pollTimer) clearInterval(pollTimer);
        pollTimer = null;
    }

    // Polling a folder nobody is looking at is pure waste.
    document.addEventListener('visibilitychange', () => {
        if (!root) return;
        if (document.hidden) stopPolling(); else startPolling();
    });

    // --- Connecting --------------------------------------------------------

    async function useFolder(handle) {
        root = handle;
        cache.clear();
        hideConnectOverlay();
        startPolling();
    }

    async function connectFolder() {
        const button = el('connectButton');
        button.disabled = true;
        try {
            const handle = await SidekickBridge.pickFolder();
            if (!await SidekickBridge.ensurePermission(handle, { prompt: true })) {
                showConnectOverlay('Sidekick needs read and write access to that folder.');
                return;
            }
            try {
                await SidekickBridge.saveHandle(handle);
            } catch (err) {
                // Private window, or storage the user blocked. The handle still
                // works for this session, which is not a reason to refuse it.
                console.warn('Could not remember the folder for next time:', err);
            }
            await useFolder(handle);
        } catch (err) {
            if (err && err.name === 'AbortError') return; // User closed the picker.
            showConnectOverlay(`Could not open that folder: ${err.message}`);
        } finally {
            button.disabled = false;
        }
    }

    async function restoreFolder() {
        if (!SidekickBridge.isSupported()) {
            showConnectOverlay('Sidekick needs the File System Access API, which only Chromium '
                + 'browsers (Chrome, Edge) provide. Open this page in Edge or Chrome.', false);
            el('connectHint').style.display = 'none';
            return;
        }
        const handle = await SidekickBridge.loadHandle();
        if (handle && await SidekickBridge.ensurePermission(handle, { prompt: false })) {
            await useFolder(handle);
            return;
        }
        showConnectOverlay(handle
            ? 'Reconnect to your Sidekick folder to pick up where you left off.'
            : null);
    }

    // --- Boot --------------------------------------------------------------

    document.addEventListener('DOMContentLoaded', () => {
        el('connectButton').addEventListener('click', connectFolder);
        restoreFolder();

        const icon = el('settingsIcon');
        const panel = el('settingsPanel');
        icon.addEventListener('click', () => {
            icon.classList.toggle('menu-open', panel.classList.toggle('visible'));
        });
        document.addEventListener('click', (event) => {
            if (!panel.contains(event.target) && event.target !== icon) {
                panel.classList.remove('visible');
                icon.classList.remove('menu-open');
            }
        });

        // Offline shell. Registration failing (file:// during local debugging)
        // must not take the app down with it.
        if ('serviceWorker' in navigator) {
            navigator.serviceWorker.register('sw.js')
                .catch((err) => console.warn('Service worker not registered:', err));
            navigator.serviceWorker.addEventListener('message', (event) => {
                if (event.data === 'sidekick-update-ready') {
                    el('updateToast').classList.add('visible');
                }
            });
            el('updateButton').addEventListener('click', () => location.reload());
        }
    });
})();
