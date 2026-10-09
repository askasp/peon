# Setup

This is the setup project. Admins use sessions here to connect APIs (connectors)
and to set up routines. Be brief and concrete.

## Connectors

A connector is one JSON file: `connectors/<name>.json`. The gateway reads every file
in that folder and exposes each tool as an MCP tool to the projects listed in
`projects`. This setup project can always use every connector, so you can test it.
The tools show up from the `gateway` MCP server, named `<connector>_<tool>`.

```json
{
  "name": "front",
  "baseUrl": "https://api2.frontapp.com",
  "auth": { "type": "bearer", "secret": "FRONT_TOKEN" },
  "tools": {
    "list_conversations": ["GET", "/inboxes/{inbox}/conversations", "allow", "List conversations in an inbox"],
    "add_comment": ["POST", "/conversations/{id}/comments", "ask", "Add an internal comment"],
    "archive": ["PATCH", "/conversations/{id}", "deny"]
  },
  "projects": ["front-digest"]
}
```

- `auth.type`: `bearer`, `header` (add `"header": "X-Api-Key"`), `basic`
  (secret holds `user:password`), `query` (add `"param": "api_key"`) or `none`.
- Each tool is `[method, path, permission, description]`. The description is all
  a routine sees, so say exactly what values look like: date formats (Unix
  seconds vs ISO), ID prefixes, query syntax, and how paging works.
  Permission: `allow` runs, `ask` waits for a person to approve each call,
  `deny` is never exposed. Default: reads allow, writes ask, destructive deny.
- `{placeholders}` in the path become required tool arguments. Every tool also
  takes optional `query` and `body` objects.
- `name` must match the file name. Secret names are UPPER_SNAKE_CASE.
- Rate limits: look up the API's limit in its docs and set
  `"rateLimit": {"perMinute": N}` a bit under it. The gateway paces every
  call to that connector (all sessions together), and on HTTP 429 it waits
  as long as the API asks and retries. Skills must not sleep or retry 429s
  themselves.
- Verbose JSON: set `"compact": true` to drop `_links` and HTML `body`
  fields that have a plain `text` copy. Responses over 60 KB are cut, so
  prefer search endpoints and page sizes (`limit`) over listing everything.

## Secrets

Never ask anyone to paste a token into this chat, and never write one to a file.
Tell them to open **Connectors** in the sidebar and set the secret named in
`auth.secret`. It goes to the vault. Then test the connector with a read call.

## Setting up a connector

1. Read the API docs (webfetch).
2. Write `connectors/<name>.json` with the tools the user needs.
3. Ask the user to set the secret on the Connectors page.
4. Call one or two read tools to test it, and say what you found.
5. Ask which projects should get it and update `projects`.

## Routines and schedules

Routines live in `../routines/<name>/`. `routine.json` says how a run starts:
the prompt sent to a new session, and optional inputs the Run button asks for.

```json
{ "run": "/digest since {since}",
  "inputs": { "since": { "default": "last run", "options": ["last run", "today", "this week"] },
              "inboxes": { "default": ["Support"], "multi": true, "options": ["Support", "Billing"] } } }
```

A run's final answer is shown as its result, so end the skill with the result
itself (markdown), not with commentary.

Skills that read an API should narrow first (search by keywords, dates,
status) and only then read details, one call per item. Reading everything
and filtering afterwards hits rate limits.

A routine's schedules are in its `schedules.json` (leave `prompt` out to use
routine.json with its defaults):

```json
{ "morning-digest": { "cron": "0 8 * * 1-5", "prompt": "/digest since the last run",
                      "scope": "team", "owner": "aksel" } }
```

`cron` is five fields in server local time. `scope` is `team` or `me`.

A routine folder you create shows up in the app only after someone adds it.
You can't do that yourself: tell the user to click **+** next to Routines in the
sidebar and pick the folder under "Already on the server".
