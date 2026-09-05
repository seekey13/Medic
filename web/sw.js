/*
 * Sidekick service worker.
 *
 * Caches the app shell so the window opens instantly and keeps working if the
 * connection drops. It never touches config data -- that never crosses the
 * network at all; it comes off the user's disk through the File System Access
 * API, which service workers cannot see.
 */
const CACHE = 'sidekick-shell';

// Sent to every open page when a revalidation turns up a file whose bytes
// changed. app.js offers the reload; nothing here applies it.
const UPDATE_READY = 'sidekick-update-ready';

const SHELL = [
    './',
    'index.html',
    'app.js',
    'render.js',
    'fsbridge.js',
    'protocol.js',
    'styles.css',
    'manifest.webmanifest',
    'assets/Sidekick.svg',
];

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
    // CACHE is a single constant that no deploy changes, so there is never an
    // old cache to evict here -- freshness comes from the revalidate below.
    event.waitUntil(self.clients.claim());
});

function announceUpdate() {
    return self.clients.matchAll().then(
        (clients) => clients.forEach((client) => client.postMessage(UPDATE_READY)));
}

// Stale-while-revalidate: serve the cached copy immediately, refresh it in the
// background. A deploy reaches the user on their next load with no cache
// version to remember to bump.
self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);
    if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;

    event.respondWith(caches.open(CACHE).then(async (cache) => {
        const cached = await cache.match(event.request);
        const network = fetch(event.request)
            .then((response) => {
                // A redirected response cannot be replayed for a navigation,
                // and an opaque one has no usable status.
                if (response.ok && response.type === 'basic') {
                    // A different ETag means this file was deployed after the
                    // page loaded. The new bytes go into the cache on the next
                    // line, so a plain reload is enough to run them.
                    if (cached && cached.headers.get('etag') !== response.headers.get('etag')) {
                        announceUpdate();
                    }
                    cache.put(event.request, response.clone());
                }
                return response;
            })
            .catch(() => cached);

        // Without waitUntil the worker can be killed before cache.put lands,
        // and since sw.js itself rarely changes, install/addAll may not re-run
        // to correct it.
        event.waitUntil(network);
        return cached || network;
    }));
});
