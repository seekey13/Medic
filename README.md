# **Sidekick** - Support Job Automation Framework

A focused, support-oriented addon for Ashita v4 that automates healing, buffing, debuff removal, resource recovery, and reviving for most jobs in Final Fantasy XI.  Tuned specifically for [CatsEyeXI private server](https://www.catseyexi.com/).

# Quick Start Guide
<img width="1453" height="917" alt="image" src="https://github.com/user-attachments/assets/d109ad58-1d66-4a5b-9cbd-bc8566df0464" />

### Header
<img width="1447" height="546" alt="image" src="https://github.com/user-attachments/assets/3b34103b-819a-4e46-a07a-bccedfb23e09" />

### Focus Healing
<img width="1449" height="386" alt="image" src="https://github.com/user-attachments/assets/41492d8c-0dd8-4715-94de-cd5abb89c04f" />

### Group Healing
<img width="1454" height="643" alt="image" src="https://github.com/user-attachments/assets/4759be51-5d4d-42d5-849f-e86b96c63b75" />

### AOE Healing
<img width="1453" height="465" alt="image" src="https://github.com/user-attachments/assets/2de2b4ff-9aff-4012-b2bf-53f6746fd451" />

### Pet Healing
<img width="1454" height="353" alt="image" src="https://github.com/user-attachments/assets/560b3be2-055c-47f2-a1f4-711cfc6d4f7b" />

### Sleep Removal
<img width="1360" height="294" alt="image" src="https://github.com/user-attachments/assets/8496c23a-9ec3-4408-a339-84cdf99cc7fe" />

### Debuff Removal
<img width="1449" height="549" alt="image" src="https://github.com/user-attachments/assets/8676c0cd-561b-41bb-911e-7c48e72f4073" />

### Item Debuff Removal
<img width="1453" height="496" alt="image" src="https://github.com/user-attachments/assets/8c3e08b4-7827-44ae-bd0a-8872d8ffb8c8" />

### Resting
<img width="1453" height="581" alt="image" src="https://github.com/user-attachments/assets/9d3b6642-9ed8-49cb-9749-f10a259ffbba" />

### Recource Recovery
<img width="1450" height="469" alt="image" src="https://github.com/user-attachments/assets/7ca740b2-3ed2-4bbf-83d5-18bcc7d80837" />

### Buffs
<img width="1449" height="1075" alt="image" src="https://github.com/user-attachments/assets/27ebedaf-ffa7-4432-80c6-de90cb8c4a37" />

### Revive
<img width="1453" height="378" alt="image" src="https://github.com/user-attachments/assets/2afff4a6-9538-4f07-b7db-5c47cbeda4e1" />

## ⚠️ Important: This is NOT a Full Automation Tool

**Sidekick is a support-only addon.** It provides healing, buffing, debuff removal, and basic pet management. It does **NOT** automate:
- Combat/attacking
- Tanking/enmity management
- Magic bursting/nuking
- Weaponskills
- Combat movement/positioning
- Full job automation

The one exception is **opt-in leader following** (off by default): with **Follow** enabled, Sidekick will `/follow` a chosen party member or tracked target when they walk beyond a set distance. It never moves your character unless you turn this on. A second, narrower exception is the **opt-in send-pet-at-target toggle** in the **Pet Control** section (Puppetmaster/Summoner/Beastmaster, off by default): it sends the *pet*, not the player, and only at the mob you pick from the dropdown beside the toggle — either your own cursor target (`<t>`, and only while you're engaged) or the battle target (`<bt>`, whatever the party is already fighting).

## Latest Updates
### [2.8.0] - 2026-09-05

### Added
- **Sections as tabs**: right-click any section header for *Display as tabs* (and any tab for *Display as section headers*); each tab carries its own enable checkbox, and disabled ones are dimmed. — **Bloodlust**
- **Disabled tabs sort last**: sections you switch off move to the end of the tab bar, keeping the enabled ones together on the left.
- **Custom window size**: right-click empty space in the config window for *Use a custom window size*, then drag the corner; *Fit window to contents* puts it back on auto-sizing. — **Toranko**
- **Web UI**: `/sk webui on` lets the Sidekick web app read this character's config and change it from a browser.
- **Web app**: a hosted page at https://sidekick.xiim-app.workers.dev draws the same sections and checkboxes as the in-game window, for every character logged in on this PC.

### Changed
- **Gear panel**: the job-independent settings `/sk panel` holds in game are reachable from the web app's gear icon.

### Fixed
- **Loading a profile no longer changes the window itself**: opacity, and whether the config window and the widget are open, are no longer saved into or applied by profiles.
- **Erase clears everything the server says it can**: Stun, Addle, Requiem, Elegy, Enmity Down and Crit. Eva. Down are now erasable, are named in the per-status opt-out menus, and are cleared by the pet cleanses too. — **Atsumu**, **Tai**
- **Party buff targets load without opening the config window**: Buffs, Geo, Sleep Removal and Debuff Removal target selections used to load only when `/sidekick` was opened, so a session that skipped it fired none of those buffs.

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

## Features

### Core Support Actions
- **Revive / Raise**: Automatically raises dead party members, tracked targets, and alliance members using Raise, Raise II, or Arise. Respects prerequisite buffs (Scholar requires Addendum: White), validates range, and falls back to the next available raise spell. Out-of-combat only (`idle_only`).
- **Mount Detection**: Automation is fully suppressed while riding a mount (detected via entity status 5 or buff 252). Configuration panel shows "Automation paused (mounted)" in this state.
- **Alliance Support**: Automatically heals, removes debuffs, wakes, and applies buffs to alliance sub-party members (parties B and C) using abilities flagged with `target_outside = true`.
- **Tracked Targets**: Session-scoped tracking of out-of-party players for heal, buff, and status removal automation. (Power Leveling). Add them by hand with **Track Target**, or let the **Shared Party List** do it: two Sidekick clients on the same PC exchange party rosters, so a box outside the party tracks the whole party automatically — complete with everyone's real job and level, no `/check` required, plus real max HP for anyone the other box has seen at full health (the rest stay estimated).
- **Item-Based Status Removal**: Automatically use consumable items to cure status ailments — Antidote (Poison), Eye Drops (Blind), Echo Drops (Silence), Holy Water / Hallowed Water (Curse/Doom/Bane), Tincture (Plague/Disease), Remedy Ointment & Remedy (Poison/Paralyze/Blind/Silence), Panacea (stat-downs). Grouped under one collapsing header with a live per-item count; matched by item ID (not name, so custom-server items work), never fired while moving, and the section hides until inventory loads
- **Critical HP Response**: Emergency abilities (e.g., Divine Seal, Martyr, Contradance) automatically trigger when party members drop below critical threshold (default 30%)
- **Single-Target Healing**: Intelligent HP deficit-based heal selection with priority system (Critical HP → Focus target → Regular lowest HP)
- **Group / AOE Heal Target Selection**: Per-target ME/P1-P5 (plus alliance and tracked for Group) buttons choose who Group and AOE healing manage; party/tracked default ON, alliance default OFF, selections per-session
- **AOE Healing**: Party-wide healing when multiple members need HP
- **Pet Healing & Support**: Automated healing for pets — GEO luopan, DRG wyvern, BST jug pets, PUP automaton — plus pet buff/debuff removal for jobs whose pet-heal ability needs a consumable equipped in the ammo slot (auto-equipped from inventory or a Mog Wardrobe)
- **Sleep Removal (Wake)**: Automatically wake sleeping party members. **Sleep Targets** buttons (P1-P5, plus alliance and tracked where the spell reaches outside the party) choose who is watched, and are saved with your settings. No ME button — you can't cure your own Sleep — and the section is hidden while solo
- **Debuff Removal**: Remove poison, paralysis, silence, and other negative status effects
- **Buff Maintenance**: Auto-apply and maintain self-buffs with single-target party buff support
- **Resource Recovery**: Automated MP and TP recovery abilities
- **Automatic Resting**: MP-based jobs automatically rest when idle to recover MP with configurable timer, HP threshold safety, and optional follow target distance monitoring
- **Leader Following** (opt-in, off by default): `/follow` a chosen party member or tracked target when they move beyond a set distance. Healing and every other support action always take priority, and an autorun-cancel packet guard keeps `/follow` alive across the server's position syncs so it doesn't break mid-route. The only non-combat movement Sidekick performs.
- **AFK Sleep** (on by default): Sleeps automation after a configurable period with no party movement and no combat, and wakes on your own movement. A runtime pause, not a stop — nothing is saved or reset, so your settings and automation state survive a sleep cycle.
- **Hold AOE for Group** (opt-in, off by default): Holds area buffs (Protectra/Shellra/Bar, Diamondhide), Bard area songs, fresh Phantom Rolls, and Accession/Diffusion spells until every alive, in-zone party member is in range, so nobody misses the AOE. Trusts, dead members, and members in another zone never cause a hold. Checkbox in `/sk panel`.
- **Corsair Rolls**: Keeps two chosen Phantom Rolls up and Double-Ups each one according to a **Risk Tier** (Lowest / Medium / Highest) built on the roll's lucky and unlucky numbers, backing off at 11 so it can't bust. **Snake Eye** is used for guaranteed finishes and **Fold** clears a Bust the moment it lands. Roll totals are read from the action packet, and the second roll is held back while Bust is active.
- **Geomancer Support**: Single-target Geo buffs on party members, target-cast Geo debuffs in combat, and automatic Full Circle / luopan management (recalls and recasts when the luopan drifts beyond the distance threshold from the selected Geo target)

### User Interface
- **ImGui Configuration UI**: User-friendly settings interface with collapsible sections
- **Settings Profiles**: Save named snapshots of your settings per job/subjob combo (Dynamis, EXP, ...) and load them from the button on the job line. Live settings stay the auto-saving working copy; profiles only change on an explicit Save
- **Alliance Member Buttons**: Per-member buff-toggle buttons (`<B0>`–`<B5>`, `<C0>`–`<C5>`) for alliance sub-parties B and C, shown only when an alliance is detected
- **Group Dropdown Selectors**: Multiple abilities in a group (e.g., Cure I-V) consolidated into dropdown menus
- **Per-Ability Toggles**: Enable/disable individual abilities
- **Button-Based Party Buff Targeting**: Single-target buffs display ME/P1-P5 buttons for precise control over who receives each buff
- **Trust Buff Support**: Can track and cast buffs on Trusts using packet-based detection
- **Subjob Duplicate Filtering**: Automatically hides duplicate abilities from subjob when they exist in main job
- **Threshold Configuration**: Customize HP/TP/MP thresholds
- **Focus Target Support**: Prioritize specific party members
- **Level-Based Filtering**: Shows only abilities available at your current level
- **Collapsible Sections**: All major features (Healing, Buffs, Debuff Removal, etc.) are collapsible for cleaner organization
- **Contextual Tooltips**: Hover help across the configuration UI explaining what each section, slider, dropdown, button, and checkbox does
- **Attack Range Selector**: Choose `Off`, `Melee (3 yalms)`, or `Ranged (15 yalms)` to set how close a follow target must be (requires [Multisend](https://github.com/ThornyFFXI/Multisend)). Shown only when **Multisend Follow** is enabled in `/sk panel`, which also disables the native Follow feature so the two movement systems don't fight
- **Auto-Refresh**: UI updates automatically when jobs or levels change

### Core System Features
- **Smart Resource Management**: Automatic MP/TP checking and cooldown tracking
- **Status Ailment Detection**: Automatically detects and prevents casting when Silenced (magic) or Amnesiac (job abilities)
- **Job-Specific Ability Validation**: Jobs can implement custom validators for fine-grained ability control (e.g., checking pet type, buff requirements, etc.)
- **Pet Entity Management**: Consolidated pet entity access with `get_pet_entity()` for consistent pet checking across all features
- **Packet-Based Casting Detection**: Casting state is read from the parsed 0x028 action packet's category (`casting_begin` locks, `spell_finish` clears), including interrupts, which repeat the start category with a marker instead of reporting a finish
- **Movement Detection**: Prevents casting while moving to avoid interrupted spells
- **Trust Buff Tracking**: Packet-based buff tracking for Trusts (0x028 for application, 0x029 for removal)
- **Single-Target Party Buffs**: Cast buffs on specific party members with button-based targeting (Haste, Refresh, Protect, Shell, etc.)
- **Party Buff Management**: Per-party-member buff configuration with intelligent uptime tracking and range validation (20 yalms)
- **Focus Target Support**: Prioritize specific party members for healing/support
- **Main/Sub Job Support**: Automatically loads and merges abilities from both supported jobs with duplicate filtering
- **Priority-Based Actions**: Configurable action priority order per job
- **Settings Persistence**: Settings saved per job in JSON format

## Supported Jobs

Currently implemented support jobs:

- **Beastmaster** (BST) — *pet-only support*
  - Pet healing with **Reward** (requires a **Pet Food** biscuit in the ammo slot; auto-equips the best tier for your level)
  - Pet Regen with **Reward (Regen)** using a **Pet Poultice** (reapplied on a timer since pet buffs can't be read)
  - Pet debuff removal with **Reward (Erase)** using a **Pet Roborant**
  - Party AOE healing with **Wild Carrot** from a rabbit jug pet (KeenearedSteffi / Rabbit), gated on a Ready charge
  - Only one ammo can be worn at a time, so the three Reward variants never contend for the ammo slot
  - **Fight** (**Pet Control** section, opt-in, off by default): sends your pet at a mob whenever it isn't already engaged, and never while you have Invisible up (the command would break it). The dropdown beside the toggle picks which mob — `<t>` (your cursor target, only while you're engaged; default) or `<bt>` (the battle target). Shared logic with Puppetmaster's Deploy and Summoner's Assault.

- **Dragoon** (DRG) — *pet-only support*
  - Pet (wyvern) healing with **Spirit Link** (no item — transfers the master's HP)
  - Self-buffs: **Ancient Circle**, **Spirit Bond**

- **Puppetmaster** (PUP) — *pet-only support*
  - Automaton healing with **Repair** (requires an **Automaton Oil** in the ammo slot; higher tiers heal more; PUP-main only)
  - Automaton healing with **Role Reversal** (level 75 merit) when Repair is on cooldown — only fires when you're healthier than the automaton and the swap leaves you above 25% HP
  - Automaton debuff removal with **Maintenance** (same Oil ammo)
  - **Maneuver** (**Pet Control** section): pick up to 3 elemental Maneuvers (Fire/Ice/Wind/Earth/Thunder/Water/Light/Dark) from three dropdowns and Sidekick keeps them applied, stacking duplicates if you pick the same element twice. Works with PUP as main job or subjob; held off while **Overload** is up, and while you have Invisible up (the `/pet` command would break it). No combat gate — kept up in and out of battle.
  - **Deploy** (**Pet Control** section, opt-in, off by default, its own checkbox — independent of Maneuver): sends the automaton at a mob whenever it isn't already engaged, and never while you have Invisible up (the command would break it). The dropdown beside the toggle picks which mob — `<t>` (your cursor target, only while you're engaged; default) or `<bt>` (the battle target). Shared logic with Summoner's Assault and Beastmaster's Fight.

- **Bard** (BRD)
  - Buff with songs on self or party members using Pianissimo (level 20+) — the ME button self-buffs via Pianissimo too
  - Area songs: an `[A]` button (left of the target buttons) sings without Pianissimo so everyone in range (10 yalms) gets it
  - Songs: Minuet, Minne, Paeon, Madrigal, Prelude, March, Ballad, Etude, Carol, Mambo, Mazurka, Scherzo, Threnody, etc.
  - Song limits: 2 songs per party member (main job) or 1 song per party member (sub job)
  - Stack same-buff tiers: right-click → Ungroup to cast each tier independently (e.g. Mage's Ballad + Mage's Ballad II)
  - Party button targeting with automatic Pianissimo usage
  - Settings persist through reloads

- **Black Mage** (BLM) — *self-only support*
  - Self-buff with elemental Spikes (Blaze Spikes, Ice Spikes, Shock Spikes — grouped, single tier selectable via dropdown)
  - Self-heal with **Drain** on your battle target (drains its HP to you — combat-only)
  - MP recovery with **Aspir** on your battle target (drains its MP — combat-only)

- **Blue Mage** (BLU)
  - Self-heal with **Pollen**; party healing with **Wild Carrot** and **Magic Fruit** (blue magic cures can't target outside the party)
  - AOE healing with **Healing Breeze**
  - Self-buffs with blue magic (Cocoon, Metallic Body, Refueling, Feather Barrier, Memento Mori, Zephyr Mantle, Warm-Up, Amplification, Triumphant Roar, Saline Coat, Reactor Cool, Plasma Charge, Battery Charge, Animating Wail, Magic Barrier, Occultation, Orcish Counterstance, Barrier Tusk)
  - **Unbridled Learning** spells (Harden Shell, Pyric Bulwark, Carcharian Verve) — the Unbridled Learning JA is popped automatically right before the spell, and the spell is held while the JA is on cooldown
  - **Diffusion** (level 75 merit, BLU main): a **D** button on every blue buff row opens a popup — **Enable** fires Diffusion before the buff to spread it to the whole party; **Hold for Diffusion** skips the buff until Diffusion is ready (off by default: the buff still casts self-only when Diffusion is on cooldown)
  - **Set-spell awareness**: blue magic that isn't currently equipped in your set-spell list is grayed out (*"Blue Magic not currently equipped"*) and skipped by automation — it stays selectable, and Sidekick never equips spells for you (use the blusets addon or the in-game menu)

- **Corsair** (COR) — *rolls only*
  - Maintains two **Phantom Rolls** of your choice (pick them from the **Rolls** section) and uses **Double-Up** on each until it is good enough
  - **Risk Tier** (default *Medium*) decides how far it chases a total. Every tier doubles at 5 or less (no die can bust) unless it is already sitting on the roll's **lucky** number, never doubles at 11 (12 busts), and uses **Snake Eye** at 10 for a guaranteed 11:
    - *Lowest* — banks the **lucky** number on sight, and stops at 6 or more; never takes a bust chance
    - *Medium* — banks the **lucky** number, chases it while it's still one die away, and rerolls off the **unlucky** number while the bust chance is 50% or less
    - *Highest* — 11 or nothing. It rolls straight past the **lucky** number (free at 5 or less, where nothing can bust) and keeps doubling through 6-10 whenever **Fold** is up to undo a Bust, otherwise plays like Medium. Expect to give up lucky totals regularly — that's the trade for chasing the cap
  - **Fold** is used the moment you Bust, whatever the tier — that frees the slot, so a fresh roll goes back in and the chase restarts
  - **Snake Eye** and **Fold** are level 75 merit abilities, main job only; without them the tiers still work, just without the guaranteed finishes and the Bust insurance
  - Roll totals aren't in memory, so they're read from the roll action packet (the packet names which roll it belongs to, so Double-Ups can't be mixed up between your two slots)
  - While **Bust** is up only one roll slot exists, so the second roll is held back until it wears
  - Rolls fire in and out of combat. Quick Draw, Ranged Attack, and Random Deal are deliberately not automated (Sidekick is support-only)

- **Dancer** (DNC)
  - Critical HP abilities (Contradance)
  - Single-target healing with waltzes (Curing Waltz I/II/III)
  - AOE healing with waltzes (Divine Waltz, Divine Waltz II)
  - Debuff removal with waltz (Healing Waltz)
  - Buff with sambas (Drain Samba I/II/III, Aspir Samba, Haste Samba)
  - Buff with jigs (Spectral Jig)
  - Buff with level-75 job abilities (Saber Dance, Fan Dance, No Foot Rise, Presto)
  - Self-buff blocking: Saber Dance suppresses Waltzes and Fan Dance suppresses Sambas while active, so those stances aren't interrupted by an automatic Waltz/Samba

- **Dark Knight** (DRK) — *self-only support*
  - Self-buffs with job abilities (Arcane Circle, Last Resort, Souleater, Consume Mana, Diabolic Eye, Scarlet Delirium)
  - Self-buff with dark magic (Dread Spikes)
  - Absorb spells on your battle target (Absorb-Attri, Absorb-ACC, Absorb-TP, Absorb-STR/DEX/INT/AGI/VIT/CHR/MND) — combat-only, single spell selectable via dropdown
  - Self-heal with dark magic (**Drain**, **Drain II**) on your battle target — combat-only, drains its HP to you
  - MP recovery with dark magic (**Aspir**) on your battle target — combat-only, drains its MP
  - **Nether Void** (level 75, DRK main): an **N** button on the Absorb, Drain/Drain II, and Aspir rows opens a popup — **Enable** fires Nether Void before the selected spell to boost it; **Hold for Nether Void** skips the spell until Nether Void is ready (off by default: the spell still casts without it when Nether Void is on cooldown)

- **Geomancer** (GEO)
  - AOE healing with job abilities (Mending Halation)
  - Pet healing with job abilities (Life Cycle)
  - Buff with Geo geomancy spells, single-target party member selection (ME/P1-P5 buttons, single-select)
  - Buff with Indi geomancy spells (self)
  - Debuff with Geo geomancy spells on your battle target (Geo-Vex, Geo-Frailty, Geo-Paralysis, Geo-Languor, Geo-Slip, Geo-Torpor, Geo-Slow, Geo-Poison) — combat-only, single debuff selectable via dropdown
  - Entrust system: Select target party member and Indi spell to automatically cast via Entrust ability
  - Buff with job abilities (Lasting Emanation, Ecliptic Attrition, Collimated Fervor, Dematerialize)
  - Blaze of Glory as a Geo precast: fired only when no luopan is out and the pending Geo spell is affordable
  - Self-heal with dark magic (**Drain**) on your battle target — combat-only, drains its HP to you
  - MP recovery with job abilities (Radial Arcana) and dark magic (**Aspir**, on your battle target — combat-only)
  - Geomancy/luopan management (automatic Full Circle execution)

- **Monk** (MNK) — *self-only support*
  - Self-heal with Chakra (HP recovery)
  - Self debuff removal with Chakra (Poison, Blindness)
  - Self-buffs with job abilities (Boost, Dodge, Focus, Counterstance, Footwork)

- **Ninja** (NIN) — *self-only support*
  - Ninjutsu stances (Yonin / Innin — mutually exclusive)
  - Utsusemi (shadows, Ichi/Ni), and the idle-only Tonko (movement) / Monomi (Sneak) utility spells
  - Sange (throws a shuriken — auto-equips the best owned tier in the ammo slot)
  - Ninjutsu spells need their **tool in inventory** (family tool or Shikanofuda); a spell with zero tools is grayed and never cast

- **Paladin** (PLD)
  - Single-target healing with white magic (Cure I-IV)
  - Buff with white magic (Protect I-IV, Shell I-IV, Reprisal)
  - Buff with job abilities (Majesty, and the combat-only Fealty, Rampart, Sentinel, Holy Circle) — Majesty is prioritized so its Cure-potency bonus is up before the Cures it boosts
  - MP recovery with **Chivalry** (converts TP to MP; TP threshold set by the **Chivalry Min TP** setting)

- **Ranger** (RNG) — *self-only support*
  - Self-buffs with job abilities (Sharpshot, Scavenge, Velocity Shot (RNG-main only), Unlimited Shot, Flashy Shot, Stealth Shot)
  - Bounty Shot on your battle target — combat-only

- **Red Mage** (RDM)
  - Single-target healing with white magic (Cure I-IV)
  - Buff with enhancing magic (Protect I-IV, Shell I-IV, Haste, Refresh, Phalanx, Phalanx II, Enfire, Enblizzard, Enaero, Enstone, Enthunder, Enwater, Stoneskin, Blink, Aquaveil, Sneak, Invisible, Deodorize)
  - MP recovery with **Convert** — the first heal afterward is forced onto you, sized against your post-Convert MP
  - Revive with white magic (Raise)

- **Samurai** (SAM) — *self-only support*
  - Self-buffs with job abilities (Warding Circle, Third Eye, Hasso/Seigan stance — Hasso and Seigan grouped as mutually exclusive)
  - TP recovery with **Meditate**

- **Rune Fencer** (RUN)
  - AOE healing with job abilities (Vivacious Pulse)
  - Buff with enhancing magic (Protect I-III, Shell I-IV, Regen I-III, Refresh, Barfire, Barblizzard, Baraero, Barstone, Barthunder, Barwater, etc.)
  - **Embolden** (level 60, RUN main): an **E** button on every enhancing magic row opens a popup — **Enable** fires Embolden before the spell to boost its potency; **Hold for Embolden** skips the spell until Embolden is ready (off by default: the spell still casts unboosted when Embolden is on cooldown). Not offered on the Spikes, which it doesn't boost

- **Scholar** (SCH)
  - Single-target healing with white magic (Cure I-IV) and self-heal with dark magic (**Drain**, on your battle target — combat-only)
  - Debuff removal with white magic (Poisona, Paralyna, Blindna, Silena, Cursna, Erase, Viruna, Stona)
  - Revive with white magic (Raise, Raise II — requires Addendum: White)
  - Buff with enhancing magic (Protect I-IV, Shell I-IV, Regen I-III, Reraise, Reraise II, Stoneskin, Blink, Aquaveil, Sneak, Invisible, Deodorize)
  - Buff with geomancy spells (Sandstorm, Rainstorm, Windstorm, Firestorm, Hailstorm, Thunderstorm, Voidstorm, Aurorastorm, Klimaform)
  - Buff with elemental magic (Blaze Spikes, Ice Spikes, Shock Spikes)
  - Buff with job abilities (Light Arts, Dark Arts, Addendum: White, Addendum: Black, Sublimation)
  - MP recovery with job abilities (Sublimation) and dark magic (**Aspir**, on your battle target — combat-only)
  - **Enlightenment** (level 75 merit, SCH main): an **E** button on every spell that needs Addendum: White (Cursna, Erase, Raise / Raise II, Reraise, Regen…) fires Enlightenment first so the spell can be cast in **Dark Arts**. A plain on/off toggle — the spell can't be cast without it, so Sidekick always waits for it, and skips the JA when Addendum: White is already up. Shown only while in Dark Arts / Addendum: Black

- **Summoner** (SMN)
  - Critical HP abilities (Apogee)
  - Single-target healing with blood pacts (Healing Ruby - requires Carbuncle)
  - AOE healing with blood pacts (Healing Ruby II - requires Carbuncle)
  - Buff with blood pacts (Avatar's Favor, Shining Ruby)
  - Smart pet validation: Carbuncle-specific abilities only execute when Carbuncle is summoned; avatar-agnostic abilities work with any avatar
  - **Assault** (**Pet Control** section, opt-in, off by default): sends your avatar at a mob whenever it isn't already engaged, and never while you have Invisible up (the command would break it). The dropdown beside the toggle picks which mob — `<t>` (your cursor target, only while you're engaged; default) or `<bt>` (the battle target). Shared logic with Puppetmaster's Deploy and Beastmaster's Fight.

- **Thief** (THF) — *self-only support*
  - Self-buffs with job abilities (Conspirator, Assassin's Charge, Feint) — combat-only.

- **Warrior** (WAR) — *self-only support*
  - Self-buffs with job abilities (Berserk, Defender, Warcry, Blood Rage, Aggressor, Retaliation, Warrior's Charge)
  - Note: Berserk cancels Defender and Warcry removes Blood Rage (and vice versa) — enable only one of each pair

- **White Mage** (WHM)
  - Critical HP abilities (Divine Seal, Martyr)
  - Single-target healing with white magic (Cure I-V)
  - Revive with white magic (Raise, Raise II, Arise)
  - AOE healing with white magic (Curaga I-IV)
  - Debuff removal with white magic (Poisona, Paralyna, Blindna, Silena, Cursna, Erase, Viruna, Stona, Esuna)
  - Buff with white magic (Protectra I-V, Shellra I-V, Protect I-IV, Shell I-IV, Haste, Regen I-III, Reraise, Reraise II, Reraise III, Auspice, Aquaveil, Blink, Stoneskin, Enlight, Barfira, Barblizzara, Baraera, Barstonra, Barthundra, Barwatera, Barsleepra, Barpoisonra, Barparalyzra, Barblindra, Barsilencera, Barvira, Barpetra, Baramnesra)

## Installation

1. Place the entire `Sidekick` folder in your Ashita `addons` directory
2. Load the addon in-game: `/addon load sidekick`
3. Configure settings: `/sidekick` (opens the configuration UI)
4. Start automation: `/sidekick start`

## Commands

- `/sidekick` or `/sk` - Show/hide configuration UI (default action)
- `/sidekick help` or `/sk help` - Show command help
- `/sidekick start` or `/sk start` - Start automation
- `/sidekick stop` or `/sk stop` - Stop automation
- `/sidekick toggle` or `/sk toggle` - Toggle automation on/off
- `/sidekick config` or `/sk config` - Show/hide configuration UI
- `/sidekick widget` or `/sk widget` - Show/hide the floating widget (profile/job line, Start/Stop, status and Track Target, pulled out of the config window)
- `/sidekick focus <index>` - Set focus target (0-5, party member index)
- `/sidekick focus clear` - Clear focus target
- `/sidekick debug` or `/sk debug` - Toggle debug mode
- `/sidekick recast` or `/sk recast` - Show all active ability recast timers
- `/sidekick afk` or `/sk afk` - Show AFK Sleep state (enabled, timeout, awake/asleep)
- `/sidekick afk on|off` - Enable/disable AFK Sleep
- `/sidekick afk <seconds>` - Set the AFK Sleep timeout in **seconds** (60-3600; the `/sk panel` field shows the same value in minutes)
- `/sidekick status` or `/sk status` - Show current status and settings

**Note**: `/sk` is a shorthand alias for `/sidekick`. Running `/sidekick` with no arguments opens the configuration UI; use `/sidekick help` to list commands.

## Usage

### Basic Setup

1. Load the addon: `/addon load sidekick`
2. Open config: `/sk config`
3. Enable desired features (healing, buffs, etc.)
4. Adjust thresholds as needed
5. Start automation: `/sk start`

### Focus Target

Focus targets are prioritized for healing and debuff removal:

```
/sidekick focus 1  # Set party member 1 as focus
/sidekick focus clear  # Clear focus
```

Party indices:
- 0 = You
- 1-5 = Other party members

### Debug Mode

Enable debug logging to troubleshoot issues:

```
/sidekick debug
```

This will show detailed information about ability selection, cooldowns, and action execution.

## Architecture

```
Sidekick/
├── Sidekick.lua              # Main addon file
├── lib/
│   ├── core/
│   │   ├── action_core.lua   # Resource/cooldown tracking, buff-ID utils, ability candidacy
│   │   ├── afk.lua           # AFK Sleep dead-man's switch
│   │   ├── automation.lua    # Action selection engine
│   │   ├── common.lua        # Shared utilities
│   │   ├── parse_packets.lua # Packet parsing for casting state
│   │   ├── roll_strategy.lua # Corsair Double-Up / Fold decision logic
│   │   └── targets.lua       # Target-resolution helpers
│   ├── actions/
│   │   ├── buff.lua          # Buff maintenance
│   │   ├── follow.lua        # Opt-in leader following
│   │   ├── geo.lua           # Geo buff/debuff targeting & Full Circle / luopan management
│   │   ├── heal.lua          # Healing (single-target, AOE, pet)
│   │   ├── item.lua          # Consumable-based status removal
│   │   ├── pet.lua           # PUP Maneuver upkeep + send-pet-at-target (Deploy/Assault/Fight)
│   │   ├── recover.lua       # MP/TP recovery
│   │   ├── rest.lua          # Automatic resting (/heal)
│   │   ├── revive.lua        # Raise dead members
│   │   ├── roll.lua          # Corsair Phantom Rolls / Double-Up
│   │   └── status_removal.lua # Debuff removal & sleep wake (single + AOE)
│   ├── jobs/
│   │   ├── bard.lua          # Bard abilities
│   │   ├── beastmaster.lua   # Beastmaster abilities (pet-only)
│   │   ├── black_mage.lua    # Black Mage abilities (self-only)
│   │   ├── blue_mage.lua     # Blue Mage abilities
│   │   ├── corsair.lua       # Corsair abilities (rolls only)
│   │   ├── dancer.lua        # Dancer abilities
│   │   ├── dark_knight.lua   # Dark Knight abilities (self-only)
│   │   ├── dragoon.lua       # Dragoon abilities (pet-only)
│   │   ├── geomancer.lua     # Geomancer abilities
│   │   ├── monk.lua          # Monk abilities (self-only)
│   │   ├── ninja.lua         # Ninja abilities (self-only)
│   │   ├── paladin.lua       # Paladin abilities
│   │   ├── puppetmaster.lua  # Puppetmaster abilities (pet-only)
│   │   ├── ranger.lua        # Ranger abilities (self-only)
│   │   ├── red_mage.lua      # Red Mage abilities
│   │   ├── rune_fencer.lua   # Rune Fencer abilities
│   │   ├── samurai.lua       # Samurai abilities (self-only)
│   │   ├── scholar.lua       # Scholar abilities
│   │   ├── summoner.lua      # Summoner abilities
│   │   ├── thief.lua         # Thief abilities (self-only)
│   │   ├── warrior.lua       # Warrior abilities (self-only)
│   │   └── white_mage.lua    # White Mage abilities
│   └── ui/
│       ├── components.lua    # Reusable ImGui render components
│       ├── config.lua        # ImGui configuration window
│       ├── panel.lua         # Debug info panel
│       └── tooltips.lua      # Contextual hover help
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full technical map.

## Configuration

Settings are saved per character by Ashita's settings library:

```
<Ashita>/config/addons/sidekick/<CharName>_<ServerId>/settings.lua
```

Every job on that character shares the one file — job-specific keys are merged into it as
you switch jobs. Delete the file to reset that character back to defaults.

### Common Settings

- `automation_enabled` (boolean): Automation on/off
- `focus_enabled` (boolean): Use focus target
- `focus_target_index` (number): Focus target party index
- `heal_enabled` (boolean): Enable healing
- `heal_threshold` (number): HP% threshold for healing
- `heal_aoe_enabled` (boolean): Enable AOE healing
- `heal_aoe_threshold` (number): HP% threshold for AOE
- `heal_aoe_count_threshold` (number): Min members needing heal for AOE
- `heal_pet_enabled` (boolean): Enable pet healing
- `heal_pet_threshold` (number): Pet HP% threshold for healing
- `wake_enabled` (boolean): Enable sleep removal
- `buff_enabled` (boolean): Enable buff maintenance
- `debuff_removal_enabled` (boolean): Enable debuff removal
- `pet_debuff_removal_enabled` (boolean): Enable pet debuff removal (BST/PUP)
- `pet_enabled` (boolean): **Pet Control** section master switch over both pet features — Maneuver upkeep and send-pet-at-target (PUP/SMN/BST); on by default
- `maneuver_enabled` (boolean): Enable Elemental Maneuver upkeep (PUP main or sub); on by default
- `maneuver1_name` / `maneuver2_name` / `maneuver3_name` (string): the Maneuver each of the three slots keeps up, stored as the full name (e.g. `Fire Maneuver`) while the dropdowns show the element alone; the same element in two slots keeps two stacks up
- `pet_control_enabled` (boolean): Enable send-pet-at-target — **Deploy** (PUP) / **Assault** (SMN) / **Fight** (BST); off by default
- `pet_control_target` (string): which mob the pet is sent at — `<t>` (default; your own cursor target, and only while you're engaged) or `<bt>` (the battle target, no engaged check)
- `recover_enabled` (boolean): Enable MP/TP recovery
- `rest_enabled` (boolean): Enable automatic resting (MP-based jobs only)
- `rest_timer` (number): Timer duration in seconds before resting starts (1-20, default 5)
- `rest_threshold` (number): HP% threshold - stops resting if any party member below this (1-99, default 70)
- `rest_distance` (number): Distance in yalms to follow target - stops resting if exceeded (1-15, default 7)
- `multisend_follow` (boolean): Movement mode switch (checkbox in `/sk panel`). `true` = Multisend attack-range follow (shows Attack Range, disables native Follow); `false` = native leader Follow (hides Attack Range). Mutually exclusive; off by default
- `follow_enabled` (boolean): Enable opt-in leader following (`/follow` the follow target when far); off by default. Ignored while `multisend_follow` is on
- `follow_distance` (number): Distance in yalms the follow target must exceed before `/follow` is sent (1-15, default 5)
- `follow_target` (string): Character name to follow — a party member (P1-P5) or a session tracked target — shared by leader following and the resting distance check (optional)
- `hold_aoe_for_group` (boolean): Hold AOE casts (Protectra/Shellra/Bar, Diamondhide, area songs, fresh Phantom Rolls, Accession/Diffusion) until every alive, in-zone party member is in range (checkbox in `/sk panel`); off by default. While holding, sends `/p Gather together for <ability>` to the party, throttled to once every 5 seconds across all held abilities
- `afk_enabled` (boolean): Enable AFK Sleep — pause automation after `afk_timeout` with no party movement and no combat, resume on your own movement (checkbox in `/sk panel`); on by default
- `afk_timeout` (number): Seconds of no party movement and no combat before sleeping (60-3600, default 600). Stored in seconds; the `/sk panel` field shows minutes
- `geo_enabled` (boolean): Enable geo management (Geo buffs, Geo debuffs, and Full Circle / luopan handling)
- `geo_distance_threshold` (number): Distance (yalms) the luopan may drift from the selected Geo target before Full Circle recalls and recasts it (7-30)
- `geo_bt_timer` (number): Seconds to wait after the Geo-bt battle target dies before Full Circle dismisses the luopan; a new battle target within the window reuses it instead (1-20, default 5)
- `selected_Geo-bt` (string): Selected Geo debuff spell to cast on your battle target (combat-only)
- `disabled_group_Geo-bt` (boolean): Disables casting the selected Geo debuff
- `ungrouped_<group>` (boolean): When true, casts every tier in the group independently instead of only the selected tier (right-click → Ungroup)
- `auto_element_<group>` (boolean): When true, keeps the group's selected tier on the one matching the current element (right-click → Auto Select). RDM enspells follow storm buff, else weather, else day of the week; SCH storms follow the zone weather only. Offered only for element-tagged groups and only while grouped
- `stratagem_hold[<key>]` (boolean): When true, hold the spell until its assigned stratagem can fire; when false (default), cast without the stratagem if no charge is available

**Note**: Group/AOE heal target selection is per-session (not persisted). Debug Mode toggles from the `/sk panel` header.

## Design Principles

### Support-Only Focus
- No combat automation
- No tanking/enmity management
- No magic bursting or offensive spells
- Only healing, buffing, debuff removal, recovering, and basic Geo pet management

### Configuration Over Code
- Jobs defined via configuration files
- No hard-coded ability names in core logic
- Easy to adjust per-job settings

### Safety First
- Multiple validation layers
- Automatic resource checking
- Status ailment detection (Silence/Amnesia)
- Cooldown tracking
- Event/cutscene blocking

### Performance
- Efficient party checking algorithms
- 1.1-second command throttle to prevent spam (3.1 s after a spell, matching its longer lockout), timed from when an action completes
- Early returns for disabled states

## Known Limitations

- Alliance automation is limited to abilities with `target_outside = true` (spells/abilities that can be cast on non-party targets)
- Designed to work on [CatsEyeXI private server](https://www.catseyexi.com/)
- To use attack range requires [Multisend](https://github.com/ThornyFFXI/Multisend)
- Requires Ashita v4

## License

See [LICENSE file for details.](https://github.com/seekey13/Sidekick/blob/main/LICENSE)
