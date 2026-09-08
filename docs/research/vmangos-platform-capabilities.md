# VMaNGOS Platform Capabilities Map (2025–2026 State)

**Date:** 2026-09-05
**Scope:** Custom-feature roadmap pre-planning for VMaNGOS-Manager — AI companions, bot-populated world, custom missions, gossip/dialogue, QoL, custom UI.
**Method:** Primary-source verification against the actual `vmangos/core` repository (shallow-cloned, `development` branch @ 2026-09-05), the `vmangos/wiki` repo, GitHub PR/issue history, community fork READMEs, and the Turtle WoW community wiki. Every claim is marked **VERIFIED** (checked against a primary source listed in Sources) or **INFERRED** (community consensus / secondary knowledge, not independently confirmed this session).

**Contains:**
- VMaNGOS core state: branches, client targets, build system, DB repos, ecosystem forks
- Configuration surface: real `mangosd.conf` option names relevant to custom gameplay
- Scripting/extension mechanisms: Eluna verdict, C++ scripts, integrated PlayerBots, Creature AI framework
- Database-driven "content without code" surface (94-command DB script system, conditions)
- Vanilla 1.12.1 client addon API constraints and server↔addon communication reality
- Server↔client protocol constraints for custom features
- Turtle WoW precedent (what a stock-1.12 client + heavy customization actually achieved)
- Capability matrix: desired feature category → what it takes on VMaNGOS

---

## 1. VMaNGOS Core State

| Item | Finding | Status |
|---|---|---|
| Main repo | [github.com/vmangos/core](https://github.com/vmangos/core) — "Progressive Vanilla Core aimed at all versions from 1.2 to 1.12", self-described "independent continuation of the Elysium / LightsHope codebases". GPL-2.0, C++. 923 stars / 585 forks / 7,326 commits; `development` branch pushed 2026-09-05 (same day as this research — actively maintained). | VERIFIED ([README](https://github.com/vmangos/core), repo metadata) |
| Client targets | 1.12.1.5875+ (primary), plus progressive 1.11.2, 1.10.2, 1.9.4, 1.8.4, 1.7.1, 1.6.1, 1.5.1; issue templates reference down to 1.2.4. One core, per-patch data via DB `patch_min`/`patch_max` columns + runtime `WowPatch` config. | VERIFIED (README; issue template) |
| TBC status | Not a mainline target. Progression stops at 1.12; no TBC branch exists in `vmangos/core`. | VERIFIED (`git ls-remote --heads`) |
| Branches | `development` (default), plus side branches: `ace`, `alterac`, `dev_copy`, `example`, `mingw3`, `no_anticheat`, misc. No stable/release branch; releases are CI builds. | VERIFIED (`git ls-remote --heads`) |
| Build system | CMake; GitHub Actions CI produces Linux/macOS/Windows binaries ("latest" release tag) and a MySQL 5.6 world-DB snapshot ("db_latest" tag). | VERIFIED (README badges) |
| Wiki | [github.com/vmangos/wiki](https://github.com/vmangos/wiki) — MkDocs repo: per-system docs (AI, Progression, Gossip, Conditions, Quest, DB Script Tables, GM Commands, tutorials "Adding a Custom NPC/Quest"). | VERIFIED |
| World DB | [brotalnia/database](https://github.com/brotalnia/database) — fork of `LightsHope/database`, full world dumps (`.7z`), newest listed dump 14 June 2021. Mainline CI now ships fresher `db_latest` snapshots. | VERIFIED |
| "classic-db" | That is the **CMaNGOS** ecosystem DB (different core). Not the VMaNGOS mainline DB. | INFERRED |
| Tools | [brotalnia/scripteditor](https://github.com/brotalnia/scripteditor) (visual script editor for the DB script system), [vmangos/ScriptConverter](https://github.com/vmangos/ScriptConverter). | VERIFIED (README links) |
| "romanholidin's fork" | **Not found.** No repo/user by that name surfaced in GitHub searches. VMaNGOS is developed by the vmangos org + community collaborators (e.g., `0blu`, `brotalnia`). Treat the name as an unconfirmed lead. | VERIFIED ABSENT (searched) |
| Notable active forks | [Yafrovon/SuperUI-Core](https://github.com/Yafrovon/SuperUI-Core) (heavy VMaNGOS fork: persistent world bots, LLM chat for bots, web UI, lootifier/questifier; active 2026-09); jcpulido97's fork (mod-playerbots port, see §3); several Eluna ports (see §3). | VERIFIED (READMEs, search) |

**Takeaway:** there is one true mainline (`vmangos/core@development`, vanilla 1.2→1.12 only) with a fat ring of special-purpose forks. Any roadmap must decide: stay on mainline + DB/scripts, or maintain a fork line.

---

## 2. Configuration Surface (`src/mangosd/mangosd.conf.dist.in`, 3,337 lines, ~600 options)

All names below are **VERIFIED** verbatim from [`src/mangosd/mangosd.conf.dist.in`](https://github.com/vmangos/core/blob/development/src/mangosd/mangosd.conf.dist.in).

### 2.1 Progression system (config-driven "which patch is it")
| Option | Effect |
|---|---|
| `WowPatch` | The content patch the server targets: `0`=1.2 … `10`=1.12. Filters DB rows via `patch_min`/`patch_max` columns (quests, NPCs, dungeons, item/creature equipment). This is VMaNGOS's signature feature. |
| `PvP.AccurateEquipRequirements` / `PvP.AccuratePurchaseRequirements` / `PvP.AccurateTimeline` / `PvP.AccurateRewards` / `PvP.DishonorableKills` / `PvP.CityProtector` | Patch-accurate honor system behavior |
| `Progression.AccuratePetStatistics`, `Progression.AccurateLFGAvailability`, `Progression.AccuratePVEEvents`, `Progression.RestoreDeletedItems`, `Progression.NoRespecPriceDecay`, `Progression.NoQuestXpToGold`, `Progression.UnlinkedAuctionHouses` | Patch-accurate progression details |
| `DebuffLimit` | 8→16 debuffs at 1.7, `0` = auto per patch |

### 2.2 Rates / player progression
`Rate.XP.Kill`, `Rate.XP.Kill.Elite`, `Rate.XP.Quest`, `Rate.XP.Explore`, `Rate.XP.Personal.Min/Max`, `Rate.Drop.Item.Poor…Artifact`, `Rate.Drop.Money`, `Rate.Health/Mana/Rage.Income/Rage.Loss/Focus/Energy/Loyalty`, `Rate.Rest.InGame`, `Rate.Rest.Offline.InTavernOrCity/InWilderness`, `Rate.Reputation.Gain`, `Rate.Talent`, `Rate.Respec*`, `SkillGain.*`, `SkillChance.*`, `Rate.Creature.Normal/Elite.*.Damage/HP/SpellDamage`, `Rate.Auction.*`, `Rate.WarEffortResourceComplete`.

### 2.3 Player-facing commands & chat
- `PlayerCommands` — "Should player chat be parsed for GM commands" (**default 1**: every chat line starting with `.` is parsed as a server command; per-command security levels decide who may run what). This single option is the foundation of addon-driven UI on stock clients.
- `AllowTwoSide.Interaction.*` (Chat/Channel/Group/Guild/Trade/Auction/Mail), `GM.JoinOppositeFactionChannels`, `WorldChan.MinLevel/Cooldown*`, `ChatFlood.*`, `Antiflood.Sanction`, `Channel.*`, `SayMinLevel`, `YellMinLevel`, `WhisperRestriction`, `AutoBroadcast.Timer`, `Event.Announce`, `Motd`, `AddonChannel` (enables/disables addon-language chat, see §5).

### 2.4 AI / bots (built into mainline — see §3.3)
`RandomBot.Enable/MinBots/MaxBots/Refresh`, `PlayerBot.AllowSaving/Debug/UpdateMs/ShowInWhoList`, `PartyBot.MaxBots/SkipChecks/AutoEquip/RandomGearLevelDifference`, `BattleBot.AutoEquip/AutoJoin`, `AHBot.Enable/ah.fid/itemcount`.

### 2.5 Battlegrounds / PvP / Outdoor PvP
`Battleground.CastDeserter`, `Battleground.QueueAnnouncer.Join/Start`, `Battleground.InvitationType`, `BattleGround.PrematureFinishTimer`, `BattleGround.PremadeGroupWaitForMatch`, `BattleGround.PremadeQueue.MinGroupSize`, `BattleGround.QueuesCount`, `BattleGround.TagInBattleGrounds`, `BattleGround.RandomizeQueues`, `BattleGround.GroupQueueLimit`, `Alterac.MinPlayersInQueue/InitMaxPlayers`, `OutdoorPvP.SI.Enable`, `OutdoorPvP.EP.Enable`, `PvP.PoolSizePerFaction`, `MinHonorKills`.

### 2.6 Weather, pooling, world dynamics
- Weather: `ActivateWeather`, `ChangeWeatherInterval`.
- Pooling is **DB-driven** (`pool_template`, `pool_creature`, `pool_creature_template`, `pool_gameobject`, … — loaded in `ObjectMgr.cpp`), plus config-side dynamic respawn: `DynamicRespawn.Range/PercentPerPlayer/MaxReductionRate/MinRespawnTime/AffectRespawnTimeBelow/AffectLevelBelow/PlayersThreshold/PlayersMaxLevelDiff`.
- Events: `Event.Announce`; game events are DB tables (see §4).

### 2.7 Ops-relevant to VMaNGOS-Manager (control plane)
`Console.Enable`, `Ra.Enable/IP/Port/MinAccountLevel/Restricted` (remote admin telnet), `SOAP.Enabled/IP/Port` (SOAP API), `GM.*` defaults, `GMTickets.*`, `LogsDB.*` (DB logging), `LogFile.*` (file logging), `Warden.*` (client anti-cheat), `Anticheat.*` (~50 movement/exploit detectors incl. `Anticheat.Botting.*` bot-behavior heuristics), `Network.KickOnBadPacket`, `CharacterDatabaseCleanup.*`, `LoginQueue.GracePeriodSecs`, `PlayerHardLimit`, `MaintenanceDay`.

---

## 3. Scripting / Extension Mechanisms

### 3.1 Eluna (Lua) — **NOT in mainline. This is the critical roadmap fact.**

| Finding | Status |
|---|---|
| `grep -ri eluna` across `src/`, `CMakeLists.txt`, `cmake/` of `vmangos/core@development` → **zero hits**. No Eluna, no cmake toggle, no mod loader. | VERIFIED |
| Community PRs to add it: [#1260](https://github.com/vmangos/core/pull/1260) and [#1261](https://github.com/vmangos/core/pull/1261) "Core eluna support" (den13501, Jul 2021) — **closed, unmerged** (one as draft). | VERIFIED |
| User demand exists: issues #675 (2020), #833 (2020), #2702 (2024, log showing an Eluna-enabled build) all ask how to get Eluna on VMaNGOS. | VERIFIED |
| Working Eluna lines live in **third-party forks**, all small/low-visibility: [chenmins/Eluna-VMaNGOS](https://github.com/chenmins/Eluna-VMaNGOS) (pushed 2026-07, most current), [d23monkey/MOD-VMaNGOS-Eluna](https://github.com/d23monkey/MOD-VMaNGOS-Eluna), [AusHick/vmangos-old](https://github.com/AusHick/vmangos-old) (archived), [nelysiumhope/docker-vmangos-eluna](https://github.com/nelysiumhope/docker-vmangos-eluna). None is an official `ElunaLua/Eluna` target (Eluna officially targets CMaNGOS/AzerothCore/etc.). | VERIFIED (repo metadata) |
| Practical consequence: choosing Eluna on VMaNGOS = adopting/maintaining a fork line and reconciling it with upstream forever. | INFERRED |

### 3.2 ScriptDev2-style C++ scripts — alive and standard
- Layout: `src/scripts/` with `ScriptLoader.cpp` (the classic `AddSC_*()` declare+register pattern) and areas `battlegrounds/`, `custom/`, `eastern_kingdoms/`, `kalimdor/`, `spells/`, `world/`; `ScriptLoader_noscripts.cpp` builds a scripts-less binary. — VERIFIED
- Binding: DB row (`creature_template.script_name`, gameobject/areatrigger equivalents) → registered C++ AI/GameObjectAI/instance script. Selection order documented in the wiki [AI-System.md](https://github.com/vmangos/wiki/blob/master/docs/AI-System.md): `script_name` match **overrides** `ai_name` registry. — VERIFIED
- Tooling: [ScriptConverter](https://github.com/vmangos/ScriptConverter) (converts old SD2 scripts) and brotalnia's ScriptEditor for DB scripts. — VERIFIED

### 3.3 Playerbots — **integrated into mainline, actively maintained** (not the ike3/mod-playerbots codebases)

VMaNGOS ships its own bot framework at `src/game/PlayerBots/` — VERIFIED files: `PlayerBotMgr.{cpp,h}`, `PlayerBotAI.{cpp,h}`, `PartyBotAI.{cpp,h}`, `BattleBotAI.{cpp,h}` + `BattleBotWaypoints.{cpp,h}` (pre-built BG navigation), `CombatBotBaseAI.{cpp,h}`.

| Bot type | What exists today | Status |
|---|---|---|
| **PartyBot** | Players summon bots into their party (`.partybot add tank/healer/dps/<class>`, `clone`, `load`); rich control verbs in Chat.cpp: `setrole, attackstart/stop, pull, aoe, caststart/stop, ccmark, focusmark, clearmarks, cometome, usegobject, pause`… — i.e., a working **dungeon-companion system** (roles, CC marking, pull/stop, loot behavior via `PartyBot.*` config). | VERIFIED (`Chat.cpp` partyBotCommandTable, `PlayerBotMgr.cpp`) |
| **BattleBot** | BG filler bots: `BattleBot.AutoJoin` auto-fills a battleground when a player queues; `BattleBotWaypoints.cpp` carries per-BG navigation paths; gear via `BattleBot.AutoEquip` (random/normal/premade-template). | VERIFIED |
| **RandomBot** | World-population bots; conf states plainly: "These bots have no AI. You have to code one and assign it." (`RandomBot.Enable/MinBots/MaxBots`). | VERIFIED (conf text) |
| **AHBot** | Auction-house economy bot (`.ahbot update/reload`, `AHBot.itemcount` listings cap). | VERIFIED |
| Persistence | `PlayerBot.AllowSaving` saves bot character progress (real characters reused as bots). | VERIFIED |
| Maturity signals | Present since 2018 (issues #32, #65); real-player bug reports since 2023 (#2267, #1751); **PR #3323 "PlayerBots use new ClientPackets" merged 2026-04-03 by collaborator 0blu** → mainline-adjacent maintenance, not abandoned. | VERIFIED |
| Relationship to other bot projects | ike3's `mangosbot-bots` = **CMaNGOS**; `mod-playerbots` (liyunfan123/Macx-Lio MultiBot) = **AzerothCore**. A port of mod-playerbots+mod-ahbot to VMaNGOS was offered in [PR #3298](https://github.com/vmangos/core/pull/3298) (Mar 2026) — **closed unmerged**; author keeps it in his own fork with the MultiBotClassic control addon. | VERIFIED |
| World-population frontier | [SuperUI-Core](https://github.com/Yafrovon/SuperUI-Core): "Permanent world bots with persistent characters, equipment, progression, state; bot questing, grouping, combat, training, vendors, travel; LLM-powered bot/player chat; persistent bot memories/relationships/goals; web world editor." Proves the ceiling but is a fork, not mainline. | VERIFIED (README) |

### 3.4 Creature AI framework (primitives for NPC behavior)
All VERIFIED in `src/game/AI/` + wiki [AI-System.md](https://github.com/vmangos/wiki/blob/master/docs/AI-System.md):
- `ai_name` registry (`CreatureAIRegistry.cpp`, selected by `FactorySelector::selectAI` at spawn): `EventAI`, `BasicAI`, `CritterAI`, `GuardAI`, `PetAI`, `TotemAI`, `NullAI`, `PetEventAI`, `GuardEventAI`, empty = auto.
- C++ base classes: `CreatureAI`, `BasicAI`, `ScriptedAI`, `ScriptedEscortAI`, `ScriptedFollowerAI`, `ScriptedPetAI`, `ScriptedInstance`, `PlayerAI` (charmed-player style AI — a reusable primitive for companion logic), `PetAI`, `GameObjectAI`.
- **CreatureEventAI** = table-driven AI from `creature_ai_events` / `creature_ai_scripts` (the DB route for custom NPC behavior, no code).
- `MotionMaster` (`src/game/Movement/MotionMaster.h`): DB-settable generators `IDLE/RANDOM/WAYPOINT/CYCLIC` + internal `CONFUSED/CHASE/HOME/…`.
- React states `REACT_PASSIVE/DEFENSIVE/AGGRESSIVE` (`src/game/Objects/UnitDefines.h`), group behavior via `CreatureGroups.{cpp,h}` and DB script command 78 `JOIN_CREATURE_GROUP`, possession (`HandlePossessCommand`).

---

## 4. Database-Driven Customization Surface ("content without code")

The wiki's [DB-Script-Tables.md](https://github.com/vmangos/wiki/blob/master/docs/DB-Script-Tables.md) (VERIFIED) documents VMaNGOS's unified script system — this is the strongest no-code layer of any vanilla core:

- **11 script tables share one schema** (id/delay/priority/command/…/condition_id): `areatrigger_scripts`, `creature_ai_scripts`, `creature_movement_scripts`, `creature_spells_scripts`, `event_scripts`, `gameobject_scripts`, `generic_scripts`, `gossip_scripts`, `quest_end_scripts`, `quest_start_scripts`, `spell_scripts`.
- **94 script commands (0–93)**, including: TALK (broadcast_text w/ random variants), EMOTE, MOVE_TO, TELEPORT_TO, TEMP_SUMMON_CREATURE, CAST_SPELL/ADD_AURA, SET_EQUIPMENT, SET_FACTION, MORPH/MOUNT, SET_PHASE(+RANGE/RANDOM), START_SCRIPT (4-way chained w/ chances), SET_SERVER_VARIABLE, CREATURE_SPELLS (weighted spell lists), SET_REACT_STATE, START_WAYPOINTS, **map-event commands 61–66/69 (START_MAP_EVENT, success/failure conditions+scripts, timed)**, FOLLOW_ESCORT, QUEST_CREDIT/FAIL_QUEST, PLAY_CUSTOM_ANIM, START_SCRIPT_ON_GROUP/ON_ZONE.
- **29 target types** (aggro-based, nearest/random by entry, friendly-injured/missing-buff, instance-data-stored, map-event participants…), source/target swap flags, per-row `condition_id`.
- **Conditions system** (`src/game/Conditions.h`, VERIFIED): 45+ condition types — AURA, ITEM(_WITH_BANK), ITEM_EQUIPPED, AREAID, REPUTATION_RANK_MIN/MAX, TEAM, SKILL(_BELOW), QUESTREWARDED/QUESTTAKEN/QUESTAVAILABLE/QUEST_NONE, ACTIVE_GAME_EVENT, RACE_CLASS, LEVEL, SOURCE_ENTRY, SPELL, INSTANCE_SCRIPT/DATA, NEARBY_CREATURE/GAMEOBJECT, WOW_PATCH, ESCORT, GENDER, IS_PLAYER, HAS_FLAG, LAST_WAYPOINT, MAP_ID, MAP_EVENT_DATA/ACTIVE, LINE_OF_SIGHT, DISTANCE_TO_TARGET, IS_MOVING, HAS_PET, HEALTH_PERCENT, MANA_PERCENT, IS_IN_COMBAT, REACTION…
- **Progression-aware DB**: rows carry `patch_min`/`patch_max` and are filtered at load by `WowPatch` — seen directly in `ObjectMgr.cpp` SQL for creature spawns and `creature_equip_template` (`WHERE %u BETWEEN patch_min AND patch_max`). VERIFIED
- Standard content tables (as in all MaNGOS lineages): `creature_template` (incl. `ai_name`, `script_name`, `equipment_id`), `creature_addon`/`creature_equip_template`, `gameobject_template`, `item_template`, `quest_template` (+`quest_start/end_scripts` hooks), `gossip_menu`/`gossip_menu_option`/`gossip_scripts`, `broadcast_text`, `creature_ai_events/scripts`, `pool_*`, game-event tables, `spell_scripts`/`spell_template` references. VERIFIED (code + wiki index: [World-Database.md](https://github.com/vmangos/wiki/blob/master/docs/World-Database.md), [Gossip-System.md](https://github.com/vmangos/wiki/blob/master/docs/Gossip-System.md), [Quest-System.md](https://github.com/vmangos/wiki/blob/master/docs/Quest-System.md))

**Bottom line:** custom missions, dialogue, phase/escort/map-event gameplay, NPC spell kits, equipment swaps, spawns/pools and patch-gating are all achievable **DB-only**; the wiki even ships step-by-step tutorials ([Tutorial-Custom-NPC.md](https://github.com/vmangos/wiki/blob/master/docs/Tutorial-Custom-NPC.md), [Tutorial-Custom-Quest.md](https://github.com/vmangos/wiki/blob/master/docs/Tutorial-Custom-Quest.md)).

---

## 5. Vanilla 1.12.1 Client Addon API — Constraints & Reality

| Topic | Finding | Status |
|---|---|---|
| Lua/XML addon API | Full era API exists: unit frames, casting (`CastSpell`), targeting, action bar control, map/coords, item links, gossip interception, event registry — reference docs maintained on the Turtle WoW wiki ([API_Functions](https://turtle-wow.fandom.com/wiki/API_Functions), [API_Events](https://turtle-wow.fandom.com/wiki/API_Events), [Widget_API](https://turtle-wow.fandom.com/wiki/Widget_API), [Slash_commands](https://turtle-wow.fandom.com/wiki/Slash_commands)). | VERIFIED (docs exist); exact function list not audited this session |
| `SendAddonMessage` / `CHAT_MSG_ADDON` | **Not a vanilla 1.12 API.** The modern prefix-addressed addon message system came later (2.0-era; the "message type" form replaced the old language form by 2.4). Do **not** plan around it for 1.12.1. | INFERRED, strongly supported by VMaNGOS source comment: `LANG_ADDON = 0xFFFFFFFF // used by addons, in 2.4.0 not exist, replaced by messagetype?` (`src/game/SharedDefines.h:270`) — VERIFIED comment |
| What 1.12 *does* have server-side | VMaNGOS accepts addon-language chat on **all supported builds incl. 1.12**: `IsLanguageAllowedForChatType()` permits `LANG_ADDON` on PARTY/GUILD/OFFICER/RAID/RAID_LEADER/RAID_WARNING/BATTLEGROUND/CHANNEL message types, exempt from flood control and language checks, gated by config `AddonChannel` (`src/game/Handlers/ChatHandler.cpp`, `World.cpp`). | VERIFIED |
| Server→addon data push | Via regular chat events the addon can read: whispers, party/raid/guild chat, channel messages, system messages, gossip frames, item links. Era raid addons (CTRA-style) coordinated through a **custom chat channel** plus whispers. | INFERRED (era-addon pattern; CTRA source not audited) |
| Addon→server control | Chat text is parsed for commands server-side (`PlayerCommands = 1`; conf: "Should player chat be parsed for GM commands"), and commands are never broadcast. Live example: PartyBotPanel addon sends `.partybot add tank` via `/say` on a stock client. | VERIFIED (conf + [PartyBotPanel README](https://github.com/oroblu/PartyBotPanel)) |
| Secure code / taint | 1.12 is vastly more permissive than modern clients; the formal "taint"/protected-function regime arrived with TBC+. Combat-state restrictions exist but era addons routinely drive targeting, casting, and full custom UIs (Decursive/CTRA era). | INFERRED |
| Distribution | No package manager for 1.12: manual unzip into `Interface\AddOns\` (all referenced community addons ship exactly this way). Server projects therefore bundle addons with their installer — a natural job for VMaNGOS-Manager. | VERIFIED pattern (PartyBotPanel/vBots/MultiBotClassic READMEs); "no CurseForge" INFERRED |

---

## 6. Server↔Client Protocol Constraints for Custom Features

- **Stock-client rule:** VMaNGOS is built to serve *unmodified* 1.12.1 clients. The core gates wire behavior by compile-time `SUPPORTED_CLIENT_BUILD` (e.g., `CHAT_MSG_RAID_WARNING` only on >1.10.2 builds) — VERIFIED (`ChatHandler.cpp` preprocessor guards).
- **Unknown opcodes to a stock client:** community consensus is that unhandled opcodes are generally ignored, while *known* opcodes carrying unexpected payloads, or content referencing data the client lacks (DBC entries, models, icons), are what break/crash clients — the practical reason vanilla custom servers stay stock-client and express new features through existing opcodes (spells, gossip, items, chat). — INFERRED (no primary protocol study fetched this session)
- **Server side protection exists:** `Network.KickOnBadPacket` and strict chat-link checking (`ChatStrictLinkChecking.*`) — VERIFIED.
- **Modifying the client is possible but carries real risk.** Turtle WoW shipped a patched 1.12.2-based client: custom MPQ patch files (community repo: [redmagejoe/TurtleHD](https://github.com/redmagejoe/TurtleHD) "Turtle WoW HD patch MPQ repo" — VERIFIED) and the client's own auto-patch delivery mechanism — which became an attack vector in the 2026 Turtle WoW leak ("RSA keys got cracked, Turtle-WoW uses this patching mechanism in the client… RCEPatcher" — [leak README](https://github.com/Winfidonarleyan/turtle-wow), VERIFIED). VMaNGOS counters the server side with `Warden.*` options and `Anticheat.*`. Default for our roadmap: **stock client, no exe mods**.
- **Progressive builds as a precedent:** the same core serves 1.5.1→1.12.1 clients by adapting payloads per build — evidence that the protocol surface of a 1.12 client is fully known and usable server-side.

---

## 7. Precedent: Turtle WoW ("Mysteries of Azeroth") — the ceiling of 1.12 customization

**Status note:** Turtle WoW shut down 2026-05-15; the evidence below survives in its community wiki and repo ecosystem. It remains the strongest existence proof of "Tier-ADDON + core patches + stock(-ish) client."

Per the community wiki [Custom Turtle WoW content](https://turtle-wow.fandom.com/wiki/Custom_Turtle_WoW_content) (VERIFIED, 1.12.2-based client):
- **New playable races:** High Elf (Alliance) and Goblin (Horde), each with custom starting zones, racials, and class lists.
- **New zones:** Alah'Thalas, Thalassian Highlands, Blackstone Island, Northwind, Balor, Grim Reaches, Gilneas, Icepoint Rock, Lapidis Isle, Gillijim's Isle, Moonwhisper Coast, Tel'Abim, Scarlet Enclave, Hyjal — plus reworked subzones in nearly every vanilla zone.
- **New dungeons** (e.g., Frostmane Hollow) and **new bosses/quests in vanilla dungeons**; new raids and world bosses; **new PvP maps**: rated arenas (Sunstrider Court 2v2, Ruins of Lordaeron 2v2, Blood Ring 3v3) and Sunnyglade Valley 20v20.
- **New professions:** Jewelcrafting (primary; Goldsmithing/Gemology specs) and Survival (secondary; Woodcutting, Gardening).
- **Meta-systems:** server-supported **leveling challenges** — Hardcore, Traveling Craftmaster, Slow and Steady, Level One Lunatic (with achievement titles); Transmogrification (Fashion Coins); Barber Shop; expanded character-creation options.
- **Cross-faction PvE:** shared world chat and AH, cross-faction groups/raids/guilds, cross-faction BG teams.
- Class/talent changes for all nine classes; custom patches numbered 1.13→1.18.x on top of vanilla.

**How they shipped it:** closed-source heavily-modified core (leaked 2026; community reads it as VMaNGOS-lineage — INFERRED), custom **MPQ patch files** for client data (models, icons, zones — VERIFIED via TurtleHD), a **publishing addon ecosystem** on GitHub (Tmog dressing room, MissingCrafts, InstanceJournal, auto-login client patch — VERIFIED repos), custom client-side Lua API documented on their wiki ("API for Turtle WoW" section — VERIFIED), and distributed client patches via the game's patch mechanism (which led to the RCE incident above). Distribution of addons remained manual `Interface\AddOns`.

**Lesson for us:** DB + core scripts + addons carry a Vanilla+ roadmap very far on a stock 1.12 client; new races/classes/zones and any new *client-visible data* require MPQ patches and a fork-grade core — high value, high cost, high operational risk.

---

## 8. Capability Matrix — Desired Feature → What It Takes on VMaNGOS

Legend: ✅ config-only · 🗄️ DB-only · 🧩 C++ script (mainline, `src/scripts/` or `src/game/`) · 🔱 requires fork · 📦 addon (stock client) · 🎨 client MPQ/exe patch

| Feature category | Feasible? | Mix | Notes |
|---|---|---|---|
| **AI companion that fights alongside a player** | ✅ today, close to done | 🧩 + 🗄️ + 📦 | Mainline **PartyBot** is a functioning role-based combat companion (summon, roles, CC marks, pull/AoE control). Deeper custom companions (persistent pet-like NPC) → `PetAI`/`ScriptedPetAI`/`PlayerAI` C++ work + `creature_*` DB rows; UI via addon; commands via chat-command channel. No Eluna → logic lives in C++ or a fork. |
| **Bot-populated world** | ⚠️ partially | ⚙️ + 🔱 | `RandomBot.*` spawns framework-only bots (no AI shipped); AHBot covers economy; BattleBots fill BGs. Persistent, questing, "living world" bots = SuperUI-Core-style fork (or upstream contribution). |
| **Custom missions / event gameplay** | ✅ | 🗄️ | quest templates + start/end scripts, 94-command script system, conditions, phases, map events, game events, `WOW_PATCH` gating. Zero core code for most designs. |
| **Gossip / dialogue systems** | ✅ | 🗄️ | `gossip_menu`/`gossip_menu_option`/`gossip_scripts`, `broadcast_text` variants, conditions per option, `SET_GOSSIP_MENU` command. Rich branching dialogs are DB work. |
| **QoL features** (commands, teleports, buffs, auto-broadcast, scheduler hooks) | ✅ | ✅ + 🗄️ + 🧩 | Huge config surface (§2); `PlayerCommands` + security levels expose commands to players; SOAP/RA/console = manager automation plane; DB scripts + events for scheduled behaviors. |
| **Custom UI (HUD, panels, companion control)** | ✅ | 📦 | 1.12 addon, full widget API, no taint regime; talk to server via chat-commands + whisper/channel/LANG_ADDON reads. Ship via our installer (no addon store). |
| **New items / spells reusing existing effects / NPC re-skins / loot & equip** | ✅ | 🗄️ | `item_template`, `creature_equip_template`, `creature_template`, spell DB fields; patch-gated. |
| **Truly new spell effects / classes / races / zone terrain / client assets** | ⚠️ | 🔱 + 🎨 + 🗄️ | Requires core patching (fork) + client MPQ data (+ possibly exe patches) — Turtle WoW precedent; highest cost & risk. Out of stock-client territory. |
| **Eluna Lua scripting anywhere in the above** | ❌ mainline | 🔱 | Only via third-party Eluna forks (chenmins 2026 most current). Plan C++/DB-first, treat Eluna as a fork decision. |
| **TBC or post-1.12 progression** | ❌ | — | Mainline hard-stops at 1.12. |

---

## Sources

Primary (repo/code — VERIFIED this session against `vmangos/core@development` clone of 2026-09-05):
- https://github.com/vmangos/core (README, metadata, branches via `git ls-remote`)
- https://github.com/vmangos/core/blob/development/src/mangosd/mangosd.conf.dist.in (all config names/texts quoted)
- https://github.com/vmangos/core/tree/development/src/game/PlayerBots/ (PlayerBotMgr/PartyBotAI/BattleBotAI/BattleBotWaypoints)
- https://github.com/vmangos/core/blob/development/src/game/Chat/Chat.cpp (`.bot`/`.ahbot`/`.partybot`/`.battlebot` command tables)
- https://github.com/vmangos/core/blob/development/src/game/Handlers/ChatHandler.cpp (LANG_ADDON acceptance, `PlayerCommands` chat parsing, build guards)
- https://github.com/vmangos/core/blob/development/src/game/SharedDefines.h (LANG_ADDON comment)
- https://github.com/vmangos/core/blob/development/src/game/AI/ (CreatureAIRegistry, EventAI, ScriptedAI family, PlayerAI)
- https://github.com/vmangos/core/blob/development/src/game/Movement/MotionMaster.h
- https://github.com/vmangos/core/blob/development/src/game/Conditions.h (condition types)
- https://github.com/vmangos/core/blob/development/src/game/ObjectMgr.cpp (pool_*, patch_min/patch_max, creature_equip_template)
- https://github.com/vmangos/core/tree/development/src/scripts/ (ScriptLoader.cpp, custom/)

Wiki / docs:
- https://github.com/vmangos/wiki (index) — incl. AI-System.md, DB-Script-Tables.md, Gossip-System.md, Quest-System.md, World-Database.md, Tutorial-Custom-NPC.md, Tutorial-Custom-Quest.md, GM-Commands.md

Ecosystem / precedent:
- https://github.com/brotalnia/database, https://github.com/brotalnia/scripteditor, https://github.com/vmangos/ScriptConverter
- PRs/issues: vmangos/core #3323 (merged 2026-04, playerbots maintenance), #3298 (mod-playerbots port, unmerged), #1260/#1261 (Eluna, unmerged), #675/#833/#2702 (Eluna demand), #2267/#1751/#32/#65 (playerbot usage history)
- https://github.com/Yafrovon/SuperUI-Core (world-bot fork), https://github.com/jcpulido97/MultiBotClassic, https://github.com/oroblu/PartyBotPanel, https://github.com/cbunting99/vBots, https://github.com/freadblangks/VBots-v2-playerbotaddon
- Eluna forks: https://github.com/chenmins/Eluna-VMaNGOS, https://github.com/d23monkey/MOD-VMaNGOS-Eluna, https://github.com/AusHick/vmangos-old
- Turtle WoW: https://turtle-wow.fandom.com/wiki/Custom_Turtle_WoW_content (and wiki home; shutdown note), https://github.com/Winfidonarleyan/turtle-wow (leak README), https://github.com/redmagejoe/TurtleHD, addon ecosystem repos (Tmog, MissingCrafts, InstanceJournal, turtle-autologin)

**Status:** 📋 Reference — Platform research complete; VERIFIED/INFERRED labels inline. Inputs for roadmap tiering (config → DB → C++ script → fork → addon → client patch).
