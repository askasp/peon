# Peon (beamcode)

A Phoenix gateway for an OpenCode v2 server (`opencode serve`), with one app
for phone and web: the Expo / React Native app in `mobile/` (the "Peon iOS
Green" design). Phoenix serves its web build at `/app` and talks to it over one
websocket (see `mobile/README.md`).

One primitive: **a project is a folder** on the OpenCode server. Code repos,
routines (one job each) and chats are all projects. Instructions, skills,
connectors and schedules are files in those folders.

The gateway adds only what OpenCode lacks: logins, a vault, cron, a shared
Inbox and one generic connector (an MCP server). Everything else goes straight
to the OpenCode API.

## Run it

```sh
mix setup
OPENCODE_URL=http://127.0.0.1:4096 OPENCODE_PASSWORD=... mix phx.server
```

Open http://localhost:4000. The first login creates the admin account.

| Env var | Default | What |
| --- | --- | --- |
| `OPENCODE_URL` | `http://127.0.0.1:4096` | OpenCode server |
| `OPENCODE_USERNAME` | `opencode` | Basic-auth user |
| `OPENCODE_PASSWORD` | none | The server's `OPENCODE_SERVER_PASSWORD` |
| `CHATOS_ROOT` | `<server folder>/chatos` | Folder on the server that holds projects |
| `GATEWAY_URL` | `http://127.0.0.1:$PORT` | How OpenCode reaches this app's `/mcp` endpoint |
| `VAULT_KEY` | secret_key_base | Key for encrypting vault secrets |
| `BIND_IP` | `127.0.0.1` | Interface to listen on in prod (behind a reverse proxy) |

For production, `mix release` builds `bin/server` (starts the app) and
`bin/migrate`; the ansible `beamcode` role deploys it next to its own OpenCode
server.

## Folder layout on the server

```
<CHATOS_ROOT>/
  setup/                  system project, admins only
    AGENTS.md             how to write connectors
    connectors/*.json     one file per connector
  routines/
    AGENTS.md             shared by all routines
    <name>/               a routine = its own project
      AGENTS.md
      .opencode/skill/<skill>/SKILL.md
      opencode.json       gateway MCP server + connector permissions (managed)
      schedules.json
  code/<name>/            cloned or new git repos
  <name>/                 chat projects
```

## How the pieces work

- **Sessions** stream live from OpenCode's `/api/event`. Permission asks show
  inline in the session and in the Inbox for everyone who can see the session.
- **Worktrees**: code projects can start each session in a fresh git worktree
  (checkbox per session, or "always" per project in Settings).
- **Connectors**: `setup/connectors/<name>.json` lists tools as
  `[method, path, allow|ask|deny, description]`. The gateway serves them as MCP
  tools (`<name>_<tool>`) to the projects in `"projects"`, and writes matching
  `permissions` into each project's `opencode.json`, so `ask` tools pause the
  session until someone approves. Secrets live in the vault, never in files or
  chat. Use **Connectors → Set up a connector** to have a setup session write
  the file for you.
- **GitHub tokens**: a code project cloned from github.com can carry a
  fine-grained token (on New project, or later in the project's Settings). It is
  kept in the vault and written to `~/.config/opencode-git/tokens.local` on the
  OpenCode server, which the server's git credential helper and `gh` wrapper read
  (ansible `opencode_web` role), so sessions can clone, push and open PRs.
  Sessions can read that file: scope each token to its one repo.
- **Models** (admins): sign the OpenCode server in to model providers with an
  API key or OAuth, e.g. OpenCode Go. One sign-in serves every user and session.
- **Schedules**: a cron line and a prompt in the project's `schedules.json`
  (server local time). Each run is an ordinary session; finished runs land in
  the Inbox. `scope: "me"` keeps runs private to the owner.
- **Team vs private**: private projects and "Only me" schedule runs are only
  visible to their owner. The setup project is admins only.
- **Shortcuts** default to OpenCode's keybinds (`ctrl+p` palette, `ctrl+x`
  leader, `<leader>n` new session, `escape` interrupt, …) and are editable per
  user in Settings.

## Development

```sh
mix precommit   # compile with warnings as errors, format, test
```
