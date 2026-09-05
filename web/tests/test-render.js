/*
 * Self-check for web/render.js.
 *
 * Run from web/:
 *     node tests/test-render.js
 *
 * These are strings, not a DOM, on purpose: the renderer is the half of the app
 * worth testing (does a checkbox carry the op that turns into the right request
 * line?) and it stays testable in plain node as long as it builds HTML rather
 * than nodes. The layout itself is verified in a browser.
 */

const assert = require('assert');
const render = require('../render.js');

// Escaping ------------------------------------------------------------------
// Character and ability names come off the game client, and a name is not a
// place to find out that innerHTML runs markup.
assert.strictEqual(render.escapeHtml('<b>&"x"'), '&lt;b&gt;&amp;&quot;x&quot;');
assert.strictEqual(render.escapeHtml("Ni'Zho"), 'Ni&#39;Zho');

// Controls ------------------------------------------------------------------
const check = render.controlHtml(
    { t: 'check', key: 'multisend_follow', label: 'Multisend Follow', value: true });
assert.match(check, /data-op="set"/, 'checkbox missing its op');
assert.match(check, /data-key="multisend_follow"/, 'checkbox missing its key');
assert.match(check, /checked/, 'a true checkbox rendered unchecked');
assert.match(check, /Multisend Follow/, 'checkbox label missing');

const slider = render.controlHtml(
    { t: 'slider', key: 'heal_threshold', label: 'Group (HP%)', value: 75, min: 1, max: 100 });
assert.match(slider, /type="range"/, 'slider is not a range input');
assert.match(slider, /min="1"[\s\S]*max="100"/, 'slider range missing');
assert.match(slider, /value="75"/, 'slider value missing');
assert.match(slider, /data-readout="heal_threshold"[^>]*>75</, 'slider has no live readout');

const combo = render.controlHtml({ t: 'combo', key: 'risk_tier', label: 'Risk Tier',
    value: 'medium', options: ['lowest', 'medium', 'highest'] });
assert.match(combo, /<select[^>]+data-key="risk_tier"/, 'combo is not a select');
assert.match(combo, /<option value="medium" selected>medium<\/option>/, 'combo selection lost');

// An ability row is a checkbox whose op names the verb the addon needs.
const ability = render.controlHtml(
    { t: 'ability', name: 'Cure IV', label: 'Cure IV', group: false, value: true });
assert.match(ability, /data-op="ability"/, 'single ability sent the wrong verb');
assert.match(ability, /data-name="Cure IV"/, 'ability name missing');
const grouped = render.controlHtml(
    { t: 'ability', name: 'Protect', label: 'Protect', group: true, value: false });
assert.match(grouped, /data-op="group"/, 'a group sent the wrong verb');
assert.doesNotMatch(grouped, /checked/, 'a false row rendered checked');

// A target row is one button per slot, labelled the way the window labels them.
const targets = render.controlHtml({ t: 'targets', name: 'Protect V', label: 'Protect V',
    group: false, slots: ['A', '0', '1'], value: { A: false, 0: true, 1: false } });
assert.match(targets, /data-op="buff"/, 'target row sent the wrong verb');
assert.match(targets, /data-slot="A"[^>]*>A</, 'the bard area slot is labelled A');
assert.match(targets, /data-slot="0"[^>]*>ME</, 'slot 0 is labelled ME');
assert.match(targets, /data-slot="1"[^>]*>P1</, 'slot 1 is labelled P1');
assert.match(targets, /class="slot on"[^>]*data-slot="0"/, 'an on slot is not marked on');
assert.match(targets, /class="slot"[^>]*data-slot="1"/, 'an off slot was marked on');
assert.match(targets, /data-group="false"/, 'target row lost its group flag');

// Sections ------------------------------------------------------------------
const section = render.sectionHtml({
    label: 'Group Healing', key: 'heal_enabled', enabled: true, controls: [
        { t: 'slider', key: 'heal_threshold', label: 'Group (HP%)', value: 75, min: 1, max: 100 },
    ],
});
assert.match(section, /^<details/, 'a section is a details element');
assert.match(section, /<summary/, 'a section has no summary to click');
assert.match(section, /data-key="heal_enabled"[^>]*checked/, 'the enable checkbox lost its state');
assert.match(section, /Group Healing/, 'section label missing');
assert.match(section, /open/, 'an enabled section should start open');

const off = render.sectionHtml(
    { label: 'Geo', key: 'geo_enabled', enabled: false, controls: [] });
assert.match(off, /class="[^"]*\bdisabled\b/, 'a disabled section is not marked');

// A section with no controls still renders: its checkbox is the whole feature.
assert.match(render.sectionsHtml([{ label: 'X', key: 'x_enabled', enabled: false, controls: [] }]),
    /<details/, 'an empty section vanished');

// Hardening: empty lists arrive as empty objects from json.lua, not arrays.
// Each list-shaped field must be coerced with Array.isArray before iterating.
const emptyControlsSection = render.sectionHtml({
    label: 'Item Debuff Removal', key: 'item_removal_enabled', enabled: true, controls: {}
});
assert.match(emptyControlsSection, /<details/, 'empty controls section should render');

const emptyControlsRender = render.sectionsHtml({});
assert.strictEqual(emptyControlsRender, '', 'empty sections object should render as empty string');

const emptyCombo = render.controlHtml({ t: 'combo', key: 'test', label: 'Test',
    value: 'default', options: {} });
assert.match(emptyCombo, /<select/, 'empty options object should still render select');

const emptySlots = render.controlHtml({ t: 'targets', name: 'Test', label: 'Test',
    group: false, slots: {}, value: {} });
assert.match(emptySlots, /class="row targets"/, 'empty slots object should still render targets row');

const emptyGlobals = render.globalsHtml({});
assert.strictEqual(emptyGlobals, '', 'empty globals object should render as empty string');

// Character buttons ---------------------------------------------------------
const buttons = render.characterButtonsHtml({
    Seekey_33748: { character: 'Seekey', is_online: true },
    Butt_38408: { character: 'Butt', is_online: false },
}, 'Seekey_33748');
assert.match(buttons, /data-char="Seekey_33748"[^>]*class="character-btn active"/,
    'the active character is not marked active');
assert.match(buttons, /data-char="Butt_38408"[^>]*class="character-btn inactive"/,
    'the inactive character is not marked inactive');
assert.match(buttons, /status-indicator online/, 'an online character has no live dot');
assert.match(buttons, /status-indicator offline/, 'an offline character has no dead dot');

// Header --------------------------------------------------------------------
const header = render.headerHtml({
    character: 'Seekey', job: 'White Mage', main_level: 75,
    sub_job: 'Black Mage', sub_level: 37,
    automation: true, status: 'Automation running', profile: 'Default',
});
assert.match(header, /White Mage 75 \/ Black Mage 37/, 'the job line is wrong');
assert.match(header, /data-op="cmd"[^>]*data-word="toggle"[^>]*>Stop</,
    'a running client should offer Stop');
assert.match(header, /Automation running/, 'the status line is missing');
const stopped = render.headerHtml({ character: 'Seekey', job: 'White Mage', main_level: 75,
    sub_job: 'None', sub_level: 0, automation: false, status: 'Automation stopped' });
assert.match(stopped, />Start</, 'a stopped client should offer Start');

console.log('test-render.js: OK');
