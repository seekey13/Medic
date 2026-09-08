--[[
    Rune Fencer job definition
    Defines abilities, validators, and configuration for Rune Fencer automation
    - Runes (unlocked at level 5, all eight) and the three rune-consuming JAs, in
      job/priority order: Vallation 10, Valiance 50, Pflug 40. Upkeep lives in
      lib/actions/rune.lua; the four config rows sit at the top of the UI's Buffs
      section.
    - Buffs (Protect, Shell, bar spells, Regen, Refresh, Spikes, Aquaveil, Blink, Stoneskin, Foil, Phalanx, job abilities)
    - Healing (Vivacious Pulse)
    - Embolden (60, RUN main): stratagem-style JA that boosts the potency of the
      next enhancing magic. Configured via the E button on every white enhancing
      buff row; fired through check_stratagem the tick before the spell. On
      cooldown: the buff still casts unboosted (hold off, default) or is held
      until Embolden is ready (hold on).
]]--


return {
    job_id = 22,
    job_name = 'Rune Fencer',
    resource_type = 'mp',
    
    abilities = {

        -- Runes (5, RUN main or sub). All eight are separate status effects that
        -- share one recast (abilities.sql recastId 10, 5s), so more than one
        -- stands at a time: 1 rune at RUN 1, 2 at 35, 3 at 65 (rune.max_runes).
        -- Swipe and Lunge eat every rune the player holds -- Sidekick fires
        -- neither, the player does; upkeep just puts them back.
        --
        -- element / resist / status are the three display strings the UI offers
        -- INSTEAD of the rune's own name, which tells a user nothing at a glance:
        -- the element the rune adds to your attacks, the element it resists, and
        -- the ailments it defends against. Which one a row shows is the row's job
        -- (Idle = element, Vallation/Valiance = resist, Pflug = status); settings
        -- still store the rune's name.
        rune = {
            {
                name = 'Ignis',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 523,
                element = 'Fire',
                resist = 'Ice',
                status = 'Paralyze / Bind',
                command = '/ja "Ignis" <me>',
            },
            {
                name = 'Gelus',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 524,
                element = 'Ice',
                resist = 'Wind',
                status = 'Silence / Weight',
                command = '/ja "Gelus" <me>',
            },
            {
                name = 'Flabra',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 525,
                element = 'Wind',
                resist = 'Earth',
                status = 'Petrify / Slow',
                command = '/ja "Flabra" <me>',
            },
            {
                name = 'Tellus',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 526,
                element = 'Earth',
                resist = 'Lightning',
                status = 'Stun',
                command = '/ja "Tellus" <me>',
            },
            {
                name = 'Sulpor',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 527,
                element = 'Lightning',
                resist = 'Water',
                status = 'Poison',
                command = '/ja "Sulpor" <me>',
            },
            {
                name = 'Unda',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 528,
                element = 'Water',
                resist = 'Fire',
                status = 'Amnesia / Plague',
                command = '/ja "Unda" <me>',
            },
            {
                name = 'Lux',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 529,
                element = 'Light',
                resist = 'Dark',
                status = 'Blind / Curse / Sleep',
                command = '/ja "Lux" <me>',
            },
            {
                name = 'Tenebrae',
                level = 5,
                cost = 0,
                recast_id = 10,
                buff_id = 530,
                element = 'Dark',
                resist = 'Light',
                status = 'Charm / Sleep',
                command = '/ja "Tenebrae" <me>',
            },
        },

        -- Rune-consuming job abilities, in the order the UI rows and the upkeep
        -- loop read them. Each carries its own three-rune set in settings; the
        -- first row whose recast is ready takes the rune slots over from Idle
        -- Runes, gets its runes up, then fires.
        --
        -- rune_field names which of the rune display strings that row's dropdowns
        -- show: Vallation/Valiance are damage mitigation, so they read as the
        -- element resisted; Pflug is ailment defence, so it reads as the ailments.
        --
        -- combat_only: these are long-recast mitigation abilities. Out of combat
        -- the row drops out of filter_abilities_by_level entirely and Idle Runes
        -- keeps the slots, which is the whole point of having an idle set.
        --
        -- priority: all three tie on cost (0), and filter_abilities_by_level
        -- sorts its output by priority then cost -- table.sort gives no
        -- stability guarantee for a tie, so leaving priority unset would let
        -- Vallation/Valiance/Pflug come back in whatever order table.sort felt
        -- like on a given run. rune.lua's execute() just walks the list and
        -- takes the first ready ability, trusting it to already be in the
        -- intended order (Vallation, then Valiance, then Pflug), so that order
        -- has to be pinned here in the data, not left to table order.
        rune_ja = {
            {
                name = 'Vallation',
                level = 10,
                cost = 0,
                priority = 3,
                recast_id = 23,
                buff_id = 531,
                -- Server-side, Vallation calls delStatusEffectSilent on Valiance
                -- before applying -- it silently stomps a standing one rather than
                -- refusing to cast -- and Liement (537) makes it a no-op outright.
                -- Blocking here keeps Sidekick from throwing away a standing
                -- Valiance for nothing; whichever landed first now holds until it
                -- expires. See rune_fencer.lua useVallationValiance.
                blocked_by = { 535, 537 },
                rune_field = 'resist',
                combat_only = true,
                command = '/ja "Vallation" <me>',
            },
            {
                name = 'Valiance',
                level = 50,
                cost = 0,
                priority = 2,
                recast_id = 113,
                buff_id = 535,
                -- Server-side, Valiance is a no-op on the caster while Vallation
                -- (531) stands -- JA_NO_EFFECT_2, "No effect on <Player>" -- and
                -- the 300s recast still runs anyway. Liement (537) no-ops it too.
                -- Blocking here stops Sidekick from burning that recast for
                -- nothing; see the Vallation entry above and useVallationValiance.
                blocked_by = { 531, 537 },
                rune_field = 'resist',
                combat_only = true,
                command = '/ja "Valiance" <me>',
            },
            {
                name = 'Pflug',
                level = 40,
                cost = 0,
                priority = 1,
                recast_id = 59,
                buff_id = 533,
                rune_field = 'status',
                combat_only = true,
                command = '/ja "Pflug" <me>',
            },
        },

        -- Buffs (Protect, Shell, bar spells, etc.)
        buff = {
            -- Protect spells
            {
                name = 'Protect',
                level = 20,
                cost = 9,
                spell_id = 43,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Protect" '..target
                end,
                element = 'Light',
                buff_id = 40,
                group = 'protect',
                target_outside = true,
            },
            {
                name = 'Protect II',
                level = 40,
                cost = 28,
                spell_id = 44,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Protect II" '..target
                end,
                element = 'Light',
                buff_id = 40,
                group = 'protect',
                target_outside = true,
            },
            {
                name = 'Protect III',
                level = 60,
                cost = 46,
                spell_id = 45,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Protect III" '..target
                end,
                element = 'Light',
                buff_id = 40,
                group = 'protect',
                target_outside = true,
            },
            -- Shell spells
            {
                name = 'Shell',
                level = 10,
                cost = 18,
                spell_id = 48,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Shell" '..target
                end,
                element = 'Light',
                buff_id = 41,
                group = 'shell',
                target_outside = true,
            },
            {
                name = 'Shell II',
                level = 30,
                cost = 37,
                spell_id = 49,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Shell II" '..target
                end,
                element = 'Light',
                buff_id = 41,
                group = 'shell',
                target_outside = true,
            },
            {
                name = 'Shell III',
                level = 50,
                cost = 56,
                spell_id = 50,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Shell III" '..target
                end,
                element = 'Light',
                buff_id = 41,
                group = 'shell',
                target_outside = true,
            },
            {
                name = 'Shell IV',
                level = 70,
                cost = 75,
                spell_id = 51,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Shell IV" '..target
                end,
                element = 'Light',
                buff_id = 41,
                group = 'shell',
                target_outside = true,
            },
            -- Barelement
            {
                name = 'Barstone',
                level = 4,
                cost = 6,
                spell_id = 63,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barstone" <me>',
                element = 'Wind',
                buff_id = 103,
                group = 'barelement',
            },
            {
                name = 'Barwater',
                level = 8,
                cost = 6,
                spell_id = 65,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barwater" <me>',
                element = 'Thunder',
                buff_id = 105,
                group = 'barelement',
            },
            {
                name = 'Baraero',
                level = 12,
                cost = 6,
                spell_id = 62,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Baraero" <me>',
                element = 'Ice',
                buff_id = 102,
                group = 'barelement',
            },
            {
                name = 'Barfire',
                level = 16,
                cost = 6,
                spell_id = 60,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barfire" <me>',
                element = 'Water',
                buff_id = 100,
                group = 'barelement',
            },
            {
                name = 'Barblizzard',
                level = 20,
                cost = 6,
                spell_id = 61,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barblizzard" <me>',
                element = 'Fire',
                buff_id = 101,
                group = 'barelement',
            },
            {
                name = 'Barthunder',
                level = 24,
                cost = 6,
                spell_id = 64,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barthunder" <me>',
                element = 'Earth',
                buff_id = 104,
                group = 'barelement',
            },
            -- Barstatus
            {
                name = 'Barsleep',
                level = 6,
                cost = 7,
                spell_id = 72,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barsleep" <me>',
                element = 'Light',
                buff_id = 106,
                group = 'barstatus',
            },
            {
                name = 'Barpoison',
                level = 9,
                cost = 9,
                spell_id = 73,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barpoison" <me>',
                element = 'Thunder',
                buff_id = 107,
                group = 'barstatus',
            },
            {
                name = 'Barparalyze',
                level = 11,
                cost = 11,
                spell_id = 74,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barparalyze" <me>',
                element = 'Fire',
                buff_id = 108,
                group = 'barstatus',
            },
            {
                name = 'Barblind',
                level = 17,
                cost = 13,
                spell_id = 75,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barblind" <me>',
                element = 'Light',
                buff_id = 109,
                group = 'barstatus',
            },
            {
                name = 'Barsilence',
                level = 22,
                cost = 15,
                spell_id = 76,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barsilence" <me>',
                element = 'Ice',
                buff_id = 110,
                group = 'barstatus',
            },
            {
                name = 'Barvirus',
                level = 38,
                cost = 25,
                spell_id = 78,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barvirus" <me>',
                element = 'Water',
                buff_id = 112,
                group = 'barstatus',
            },
            {
                name = 'Barpetrify',
                level = 42,
                cost = 20,
                spell_id = 77,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Barpetrify" <me>',
                element = 'Wind',
                buff_id = 111,
                group = 'barstatus',
            },
            {
                name = 'Baramnesia',
                level = 63,
                cost = 30,
                spell_id = 84,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Baramnesia" <me>',
                element = 'Water',
                buff_id = 286,
                group = 'barstatus',
            },
            -- Regen
            {
                name = 'Regen',
                level = 23,
                cost = 15,
                spell_id = 108,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Regen" '..target
                end,
                buff_id = 42,
            },
            {
                name = 'Regen II',
                level = 48,
                cost = 36,
                spell_id = 110,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Regen II" '..target
                end,
                element = 'Light',
                buff_id = 42,
            },
            {
                name = 'Regen III',
                level = 70,
                cost = 64,
                spell_id = 111,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Regen III" '..target
                end,
                element = 'Light',
                buff_id = 42,
            },
            -- Refresh
            {
                name = 'Refresh',
                level = 62,
                cost = 40,
                spell_id = 109,
                magic = 'white',
                magic_type = 'enhancing',
                command = function(target)
                    return '/ma "Refresh" '..target
                end,
                element = 'Light',
                buff_id = 43,
                priority = 50,
            },
            {
                name = 'Foil',
                level = 58,
                cost = 48,
                spell_id = 840,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Foil" <me>',
                element = 'Wind',
                buff_id = 568,
            },
            {
                name = 'Swordplay',
                level = 20,
                cost = 0,
                recast_id = 24,
                command = '/ja "Swordplay" <me>',
                buff_id = 532,
                combat_only = true,
            },
            {
                name = 'Phalanx',
                level = 68,
                cost = 21,
                spell_id = 106,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Phalanx" <me>',
                element = 'Light',
                buff_id = 116,
            },
            -- Spikes
            {
                name = 'Blaze Spikes',
                level = 45,
                cost = 8,
                spell_id = 249,
                magic = 'black',
                magic_type = 'enhancing',
                command = '/ma "Blaze Spikes" <me>',
                element = 'Fire',
                buff_id = 34,
                group = 'spikes',
            },
            {
                name = 'Ice Spikes',
                level = 65,
                cost = 16,
                spell_id = 250,
                magic = 'black',
                magic_type = 'enhancing',
                command = '/ma "Ice Spikes" <me>',
                element = 'Ice',
                buff_id = 35,
                group = 'spikes',
            },
            -- Everything else
            {
                name = 'Aquaveil',
                level = 15,
                cost = 12,
                spell_id = 55,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Aquaveil" <me>',
                element = 'Water',
                buff_id = 39,
            },
            {
                name = 'Blink',
                level = 35,
                cost = 20,
                spell_id = 53,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Blink" <me>',
                element = 'Wind',
                buff_id = 36,
            },
            {
                name = 'Stoneskin',
                level = 55,
                cost = 29,
                spell_id = 54,
                magic = 'white',
                magic_type = 'enhancing',
                command = '/ma "Stoneskin" <me>',
                element = 'Earth',
                buff_id = 37,
            },
        },
        
        -- Healing
        heal = {
            {
                name = 'Vivacious Pulse',
                level = 65,
                cost = 0,
                recast_id = 242,
                command = '/ja "Vivacious Pulse" <me>',
                self_only = true,
            },
        },

        -- Precast JA, fired the tick before its paired enhancing spell. recast_gate
        -- keeps it out of the Scholar S popup and check_stratagem's charge pool (it
        -- has its own JA timer). Its [E] button shows only on white enhancing rows --
        -- the spikes are magic = 'black' and are deliberately left out.
        precast = {
            {
                name = 'Embolden',
                level = 60,
                cost = 0,
                recast_id = 72,
                command = '/ja "Embolden" <me>',
                buff_id = 534,
                recast_gate = true,
                column = 'embolden',  -- [E] button column
            },
        },
    },
    
    -- Job-specific validators
    validators = {},
    
    -- Default settings for UI
    default_settings = {
        heal_enabled = true,
        heal_threshold = 75,
        wake_enabled = false,
        buff_enabled = true,
        focus_enabled = false,
        focus_threshold = 85,
        -- Rune rows default ON but with every slot unset, so upkeep does nothing
        -- at all until the user picks runes -- an upgrade never starts firing JAs
        -- on its own.
        rune_idle_enabled = true,
        rune_vallation_enabled = true,
        rune_valiance_enabled = true,
        rune_pflug_enabled = true,
    },
    
    -- Action priority order. Runes sit ahead of buffs: a rune is a 5-second JA on
    -- a 300-second timer that the player's own Swipe/Lunge keeps stripping, so it
    -- should not queue behind a Protect that is minutes from expiring.
    priority_order = {
        'item',
        'heal',
        'rune',
        'buff',
        'rest',
    },
}
