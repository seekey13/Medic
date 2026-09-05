/*
 * Self-check for web/sw.js.
 *
 * Run from web/:
 *     node tests/test-sw.js
 *
 * The service worker caches the app shell by name. A file added to web/ and not
 * added to SHELL still works online and silently breaks offline, which is the
 * kind of bug nobody finds until they are on a train -- so the list is asserted
 * rather than remembered.
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const webDir = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(webDir, 'sw.js'), 'utf8');

const shell = JSON.parse(
    /const SHELL = (\[[\s\S]*?\]);/.exec(source)[1].replace(/'/g, '"').replace(/,\s*\]/, ']'));

// Everything the page actually loads. Tooling (wrangler config, package.json,
// the ignore file, this suite) is not site content and is held back by
// .assetsignore, so it is not expected in the shell either.
const TOOLING = new Set(['wrangler.jsonc', 'package.json', '.assetsignore', '_headers', 'sw.js']);
const NOT_SITE_CONTENT = new Set(['tests', 'node_modules']);

function walk(dir, prefix = '') {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const rel = prefix + entry.name;
        if (entry.isDirectory()) {
            if (NOT_SITE_CONTENT.has(entry.name)) continue;
            walk(path.join(dir, entry.name), rel + '/');
        } else if (!TOOLING.has(rel)) {
            assert.ok(shell.includes(rel), `${rel} is served but not in the sw.js SHELL`);
        }
    }
}
walk(webDir);

// './' is the navigation request; without it a cold offline load has no page.
assert.ok(shell.includes('./'), 'SHELL is missing the navigation entry');

for (const entry of shell) {
    if (entry === './') continue;
    assert.ok(fs.existsSync(path.join(webDir, entry)),
        `SHELL lists ${entry}, which does not exist -- install would fail and the `
        + 'worker would never take over');
}

console.log('test-sw.js: OK');
