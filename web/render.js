/*
 * state.json -> HTML.
 *
 * The addon exports its config window as data (lib/ui/schema.lua) and this
 * draws it: one collapsible section per in-game section, in the same order,
 * with the same labels. There is no model on this side -- every element carries
 * the request op it produces in data attributes, so app.js needs one delegated
 * listener and never has to keep a second copy of the config in sync.
 *
 * Sections are <details>/<summary>: the browser already collapses those.
 */
const SidekickRender = (() => {
    'use strict';

    const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

    // Character and ability names come off the game client. A name is not a
    // place to find out that innerHTML runs markup.
    function escapeHtml(text) {
        return String(text ?? '').replace(/[&<>"']/g, (c) => ENTITIES[c]);
    }

    // 'A' is the bard area-song slot; the rest are ME and P1-P5, exactly as the
    // in-game buttons are labelled.
    function slotLabel(slot) {
        if (slot === 'A') return 'A';
        return slot === '0' ? 'ME' : `P${slot}`;
    }

    function controlHtml(control) {
        const label = escapeHtml(control.label);

        switch (control.t) {
            case 'check':
                return `<label class="row check"><input type="checkbox" data-op="set"`
                    + ` data-key="${escapeHtml(control.key)}"${control.value ? ' checked' : ''}>`
                    + `<span>${label}</span></label>`;

            case 'slider':
                return `<label class="row slider"><span>${label}</span>`
                    + `<input type="range" data-op="set" data-key="${escapeHtml(control.key)}"`
                    + ` min="${control.min}" max="${control.max}" value="${control.value}">`
                    + `<output data-readout="${escapeHtml(control.key)}">${control.value}</output>`
                    + `</label>`;

            case 'combo': {
                // Hardening: empty Lua tables encode as {} not []. Coerce to array.
                const optionsArray = Array.isArray(control.options) ? control.options : [];
                const options = optionsArray.map((option) => {
                    const selected = option === control.value ? ' selected' : '';
                    return `<option value="${escapeHtml(option)}"${selected}>`
                        + `${escapeHtml(option)}</option>`;
                }).join('');
                return `<label class="row combo"><span>${label}</span>`
                    + `<select data-op="set" data-key="${escapeHtml(control.key)}">`
                    + `${options}</select></label>`;
            }

            case 'ability':
                // The verb differs because the addon toggles a group and a
                // single ability through different settings keys.
                return `<label class="row ability"><input type="checkbox"`
                    + ` data-op="${control.group ? 'group' : 'ability'}"`
                    + ` data-name="${escapeHtml(control.name)}"`
                    + `${control.value ? ' checked' : ''}><span>${label}</span></label>`;

            case 'targets': {
                // Hardening: empty Lua tables encode as {} not []. Coerce to array.
                const slotsArray = Array.isArray(control.slots) ? control.slots : [];
                const buttons = slotsArray.map((slot) => {
                    const on = control.value[slot] === true;
                    return `<button type="button" class="slot${on ? ' on' : ''}" data-op="buff"`
                        + ` data-name="${escapeHtml(control.name)}"`
                        + ` data-group="${control.group ? 'true' : 'false'}"`
                        + ` data-slot="${escapeHtml(slot)}" data-on="${on ? 'true' : 'false'}">`
                        + `${slotLabel(slot)}</button>`;
                }).join('');
                return `<div class="row targets"><span class="target-name">${label}</span>`
                    + `<span class="slots">${buttons}</span></div>`;
            }

            default:
                return '';
        }
    }

    function sectionHtml(section) {
        // Hardening: empty Lua tables encode as {} not []. Coerce to array.
        const controlsArray = Array.isArray(section.controls) ? section.controls : [];
        const controls = controlsArray.map(controlHtml).join('');
        // Enabled sections open, disabled ones closed and dimmed -- the same
        // signal the in-game tab bar gives by sorting disabled sections away.
        return `<details class="section${section.enabled ? '' : ' disabled'}"`
            + `${section.enabled ? ' open' : ''}>`
            + `<summary><input type="checkbox" data-op="set"`
            + ` data-key="${escapeHtml(section.key)}"${section.enabled ? ' checked' : ''}>`
            + `<span class="section-label">${escapeHtml(section.label)}</span></summary>`
            + `<div class="section-body">${controls}</div>`
            + `</details>`;
    }

    function sectionsHtml(sections) {
        // Hardening: empty Lua tables encode as {} not []. Coerce to array.
        const sectionsArray = Array.isArray(sections) ? sections : [];
        return sectionsArray.map(sectionHtml).join('');
    }

    function globalsHtml(globals) {
        // Hardening: empty Lua tables encode as {} not []. Coerce to array.
        const globalsArray = Array.isArray(globals) ? globals : [];
        return globalsArray.map(controlHtml).join('');
    }

    function characterButtonsHtml(states, activeKey) {
        return Object.keys(states).map((key) => {
            const state = states[key];
            const active = key === activeKey ? 'active' : 'inactive';
            const dot = state.is_online ? 'online' : 'offline';
            const icon = state.is_online ? 'mdi-circle-slice-8' : 'mdi-minus-circle-off';
            return `<button type="button" data-char="${escapeHtml(key)}"`
                + ` class="character-btn ${active}">${escapeHtml(state.character)}`
                + `<i class="mdi ${icon} status-indicator ${dot}"></i></button>`;
        }).join('');
    }

    function headerHtml(state) {
        const sub = state.sub_level > 0
            ? `${escapeHtml(state.sub_job)} ${state.sub_level}`
            : 'None 0';
        // One button, like the window's: it always sends `toggle`, so a stale
        // page cannot start a client it thought was stopped and stop it twice.
        return `<div class="job-row">`
            + `<span class="profile">${escapeHtml(state.profile || 'Default')}</span>`
            + `<span class="job-line">${escapeHtml(state.job)} ${state.main_level} / ${sub}</span>`
            + `</div>`
            + `<div class="automation-row">`
            + `<button type="button" class="automation ${state.automation ? 'stop' : 'start'}"`
            + ` data-op="cmd" data-word="toggle">${state.automation ? 'Stop' : 'Start'}</button>`
            + `<span class="status ${state.automation ? 'running' : 'stopped'}">`
            + `${escapeHtml(state.status)}</span>`
            + `</div>`;
    }

    return {
        escapeHtml, controlHtml, sectionHtml, sectionsHtml, globalsHtml,
        characterButtonsHtml, headerHtml,
    };
})();

if (typeof module !== 'undefined') { module.exports = SidekickRender; }
