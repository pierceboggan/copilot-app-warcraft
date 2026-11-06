# Copilot Mission Table

Watch and steer your GitHub Copilot app sessions from inside World of Warcraft.

Your sessions show up as followers on missions. A busy session casts "Thinking..." on a loop. A session that needs you gets a quest-giver "!" and a raid warning, and its `ask_user` choices appear as gossip options. Context use shows as a mana bar. You send orders by courier, and Hearth (`/reload`) dispatches them.

## How it works

WoW addons can't touch the network or read files while the game runs. A small companion process on your Mac bridges the gap:

```
Copilot app --ws (observer)--> companion --writes--> AddOns/CopilotMissionTable/Inbox.lua --/reload--> addon
addon --/reload--> WTF/.../SavedVariables/CopilotMissionTable.lua --watched--> companion --send_message--> Copilot app
```

On every `/reload`, WoW saves your queued orders and reloads the latest reports. The companion delivers each order within a second or two, and the next Hearth confirms it. Everything stays inside Blizzard's addon rules: no input automation and no memory reading.

## Setup

Requires Node 22+ and the GitHub Copilot app running.

```sh
node companion/companion.mjs install --wow "/Applications/World of Warcraft"   # once; remembers the path
node companion/companion.mjs                                                   # leave running while you play
```

Add `--flavor _classic_` or `--flavor _classic_era_` for Classic clients. Restart WoW once after installing so it discovers the addon.

## In game

| | |
|---|---|
| Beacon (draggable spyglass) | Count of missions needing you; click to open |
| `/cmt` or `/copilot` | Open the Mission Table |
| `/cmt list` | Roll call with numbers |
| `/cmt 3 run the tests again` | Queue orders for mission 3 |
| `/cmt 3! stop and summarize` | Priority orders (read at the next turn) |
| `/cmt answer 3 2` | Answer mission 3's question with choice 2 (or free text) |
| `/cmt sync` or the Hearth button | `/reload`: dispatch couriers and fetch reports |
| `/cmt raid` | CI bosses: open PRs with failing checks. **Engage** drafts fix-it orders to the mission on that branch |
| `/cmt loot` | Your bags: every merged PR is an item, with quality set by lines changed |
| `/cmt ach` | Achievements |
| `/cmt log` | Combat log: your missions' tool calls as spells ("Detect Magic hits \"TODO\" for 812") |
| `/cmt sound`, `/cmt announce` | Toggle alerts |

Loot and bosses come from `gh api graphql` every 3 minutes, so the companion needs `gh` signed in.

## Limitations

- Updates arrive on `/reload`. Live in-game updates aren't possible without breaking WoW's sandbox.
- Permission prompts must be answered in the app; the addon flags them.
- Questions asked while the companion wasn't running aren't recoverable, because the app doesn't persist them.
- After you steer from WoW, the app routes that session's UI tool actions (opening canvases, for example) to the companion until you next send from the app window.
- The companion uses the app's local WebSocket (`~/.copilot/run/ws.*`), which is an internal protocol and may change between app versions.

## Development

```sh
node companion/companion.mjs status        # print what the addon would see
lua tools/smoke.lua path/to/Inbox.lua      # run the addon headless against stubbed WoW APIs
```
