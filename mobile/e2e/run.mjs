// End-to-end check of the Peon app (the web build Phoenix serves at /app)
// against a real server and OpenCode: every feature area, one PASS/FAIL line
// each. It creates and removes its own test data (named e2e-…).
//
//   PEON_URL=http://localhost:4471 PEON_USER=aksel PEON_PASS=… node e2e/run.mjs [desktop|iphone|all]
//
// desktop: Chromium at 1440×900 (sidebar layout, keyboard). iphone: WebKit
// (Safari's engine) emulating an iPhone 15 (phone layout, touch).

import { chromium, devices, webkit } from "playwright";
import { existsSync, rmSync } from "node:fs";

const BASE = process.env.PEON_URL ?? "http://localhost:4471";
const USER = process.env.PEON_USER ?? "aksel";
const PASS = process.env.PEON_PASS ?? "";
const PROJECT = process.env.PEON_PROJECT ?? "demo-app"; // a code project
const ROUTINE = process.env.PEON_ROUTINE ?? "file-digest";
const mode = process.argv[2] ?? "all";
const stamp = Date.now().toString(36);
const results = [];
const SHOTS = process.env.E2E_SHOTS; // a folder: a screenshot of each failed step goes there
let current = null; // the page under test, for those screenshots

async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`PASS ${name} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  } catch (e) {
    results.push({ name, ok: false, error: e.message });
    if (SHOTS && current)
      await current.screenshot({ path: `${SHOTS}/${name.replace(/\W+/g, "_")}.png` }).catch(() => {});
    console.log(`FAIL ${name}: ${e.message.split("\n")[0]}`);
  }
}

function expect(cond, message) {
  if (!cond) throw new Error(message);
}

const visible = (page, sel) => page.locator(sel).locator("visible=true");
const byText = (page, text, exact = true) => page.getByText(text, { exact }).locator("visible=true");

async function waitFor(fn, message, timeout = 60000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await fn().catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 400));
  }
  throw new Error(message);
}

async function login(page) {
  await page.goto(`${BASE}/`);
  await page.waitForURL(/\/login/);
  await page.fill('input[name="user[username]"]', USER);
  await page.fill('input[name="user[password]"]', PASS);
  await page.press('input[name="user[password]"]', "Enter");
  await page.waitForURL(/\/app/, { timeout: 20000 });
  await waitFor(
    async () => (await page.locator('[data-testid="tab-mic"], [data-testid="open-palette"]').count()) > 0,
    "app didn't load",
  );
}

async function openProject(page, name, desktop) {
  if (desktop) {
    await visible(page, `[data-testid="side-${name}"]`).first().click();
  } else {
    await click(page, "tab-projects");
    await visible(page, `[data-testid="project-${name}"]`).first().click();
  }
  await waitFor(async () => (await byText(page, name).count()) > 0, `project ${name} didn't open`);
}

const escape = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

async function tab(page, label) {
  await visible(page, '[data-kb="tab"]')
    .filter({ hasText: new RegExp(`^${escape(label)}$`) })
    .first()
    .click();
}

// Stack screens stay mounted (hidden) under the current one: always act on the visible element.
const click = (page, testId) => visible(page, `[data-testid="${testId}"]`).first().click();

// Waits until the session isn't working (no Stop button).
const idle = (page, timeout = 180000) =>
  waitFor(
    async () => (await visible(page, '[data-testid="stop"]').count()) === 0,
    "session still busy",
    timeout,
  );

async function sendInSession(page, text) {
  await visible(page, '[data-testid="reply"]').first().fill(text);
  await visible(page, '[data-testid="send"]').first().click();
}

// ── Desktop: every feature ────────────────────────────────────────────────

async function desktop() {
  console.log("\n== desktop (Chromium 1440×900) ==");
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  const page = await context.newPage();
  current = page;
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await step("login: / sends you to log in, then into the app", async () => {
    await login(page);
    expect(page.url().includes("/app"), `landed on ${page.url()}`);
  });

  await step("inbox: loads with its summary", async () => {
    await page.goto(`${BASE}/app`);
    await waitFor(async () => (await byText(page, "Inbox").count()) > 0, "no inbox");
  });

  const chat = `e2e-chat-${stamp}`;
  await step("new project: create a chat project", async () => {
    await page.goto(`${BASE}/app/new`);
    await click(page, "kind-chat");
    await page.fill('[data-testid="project-name"]', chat);
    await click(page, "create-project");
    await page.waitForURL(/\/app\/project\/\d+/, { timeout: 30000 });
    await waitFor(
      async () => (await visible(page, `[data-testid="side-${chat}"]`).count()) === 1,
      "not in the sidebar",
    );
  });

  await step("project settings: remove the test project", async () => {
    page.once("dialog", (d) => d.accept());
    await tab(page, "Settings");
    await byText(page, "Remove project").first().click();
    await page.waitForURL(/\/app\/?$/, { timeout: 20000 });
    await waitFor(
      async () => (await visible(page, `[data-testid="side-${chat}"]`).count()) === 0,
      "still listed",
    );
  });

  await step("project: sessions list, search and day groups", async () => {
    await openProject(page, PROJECT, true);
    await waitFor(async () => (await visible(page, '[data-testid^="session-"]').count()) > 0, "no sessions");
    const before = await visible(page, '[data-testid^="session-"]').count();
    await visible(page, '[data-kb="search"]').first().fill("zzz-no-match");
    await waitFor(
      async () => (await visible(page, '[data-testid^="session-"]').count()) === 0,
      "search didn't filter",
    );
    await visible(page, '[data-kb="search"]').first().fill("");
    await waitFor(
      async () => (await visible(page, '[data-testid^="session-"]').count()) === before,
      "search didn't reset",
    );
  });

  const skill = `e2e-${stamp}`;
  await step("skills: create a skill and save an edit", async () => {
    await tab(page, "Skills");
    await byText(page, "+ New skill").first().click();
    await page.keyboard.type(skill);
    await page.keyboard.press("Enter");
    await waitFor(
      async () => (await byText(page, `.opencode/skill/${skill}/SKILL.md`).count()) > 0,
      "skill not opened",
    );
    const editor = visible(page, '[data-testid="file-editor"]').first();
    await waitFor(async () => (await editor.inputValue()).includes(`name: ${skill}`), "template not loaded");
    await editor.fill(`---\nname: ${skill}\ndescription: e2e test skill\n---\n\nSay e2e.\n`);
    await byText(page, "Save").first().click();
    await waitFor(
      async () => (await byText(page, `Saved .opencode/skill/${skill}/SKILL.md.`).count()) > 0,
      "not saved",
    );
  });

  const sched = `e2e-${stamp}`;
  await step("schedules: create, edit and delete a schedule", async () => {
    await tab(page, "Schedules");
    // The button is enabled once the schedules have loaded.
    await waitFor(
      async () =>
        (await visible(page, '[data-testid="new-schedule"]').first().getAttribute("aria-disabled")) !==
        "true",
      "never loaded",
    );
    await click(page, "new-schedule");
    await page.getByPlaceholder("morning-digest").fill(sched);
    await page.getByPlaceholder("/digest since the last run").fill("Say e2e.");
    await waitFor(async () => (await page.getByText(/weekdays 08:00/).count()) > 0, "no cron preview");
    await click(page, "save-schedule");
    await waitFor(async () => (await byText(page, sched).count()) > 0, "not listed");
    const card = () =>
      page
        .locator("div")
        .filter({ has: byText(page, sched) })
        .filter({ has: byText(page, "Delete") })
        .last();
    await card().getByText("Edit", { exact: true }).click();
    await page.getByPlaceholder("/digest since the last run").fill("Say e2e again.");
    await click(page, "save-schedule");
    await waitFor(async () => (await byText(page, "Say e2e again.").count()) > 0, "edit not saved");
    page.once("dialog", (d) => d.accept());
    await card().getByText("Delete", { exact: true }).click();
    await waitFor(async () => (await byText(page, sched).count()) === 0, "not deleted");
  });

  await step("project settings: toggle worktrees on and off", async () => {
    await tab(page, "Settings");
    await waitFor(async () => (await byText(page, "New sessions in a worktree").count()) > 0, "no settings");
    const toggle = page.getByRole("switch", { name: "New sessions in a worktree" }).locator("visible=true");
    const was = await toggle.isChecked();
    await toggle.click();
    await waitFor(
      async () => (await toggle.isChecked()) !== was && (await byText(page, "Saved.").count()) > 0,
      "not saved",
    );
    await toggle.click();
    await waitFor(async () => (await toggle.isChecked()) === was, "not saved back");
  });

  await step("session: new session, send, streamed reply", async () => {
    await tab(page, "Sessions");
    await click(page, "new-session");
    await page.waitForURL(/\/app\/session\//, { timeout: 30000 });
    await sendInSession(page, "Reply with exactly the word: pong");
    await waitFor(async () => (await byText(page, "pong").count()) > 0, "no reply", 90000);
  });

  await step("session: rename", async () => {
    const title = `e2e session ${stamp}`;
    await visible(page, '[data-testid="session-menu"]').first().click();
    await byText(page, "Rename").first().click();
    await page.keyboard.press("Control+a");
    await page.keyboard.type(title);
    await page.keyboard.press("Enter");
    await waitFor(async () => (await byText(page, title).count()) > 0, "title not updated", 20000);
  });

  await step("session: model picker lists models", async () => {
    await visible(page, '[data-testid="model-chip"]').first().click();
    await waitFor(async () => (await byText(page, "Model").count()) > 0, "no picker");
    await page.keyboard.press("Escape");
    await page.mouse.click(10, 450);
  });

  await step("session: Tab cycles the agent (your composer keys)", async () => {
    const chip = visible(page, '[data-testid="agent-chip"]').first();
    const before = await chip.innerText();
    await visible(page, '[data-testid="reply"]').first().click();
    await page.keyboard.press("Tab");
    await waitFor(async () => (await chip.innerText()) !== before, "agent unchanged", 15000);
    await page.keyboard.press("Shift+Tab");
    await waitFor(async () => (await chip.innerText()) === before, "agent not back", 15000);
  });

  await step("session: / and @ completion", async () => {
    const reply = visible(page, '[data-testid="reply"]').first();
    await reply.fill("@READ");
    await waitFor(async () => (await byText(page, "README.md").count()) > 0, "no @ completion", 15000);
    await reply.fill("");
    await reply.type("/");
    await waitFor(
      async () =>
        (await page
          .getByText(/^\/[\w-]+$/)
          .locator("visible=true")
          .count()) > 0,
      "no / completion",
      15000,
    );
    await reply.fill("");
  });

  await step("session: paste an image attaches it", async () => {
    await visible(page, '[data-testid="reply"]').first().click();
    await page.evaluate(async () => {
      const c = document.createElement("canvas");
      c.width = 40;
      c.height = 30;
      c.getContext("2d").fillRect(0, 0, 40, 30);
      const blob = await new Promise((r) => c.toBlob(r, "image/png"));
      const dt = new DataTransfer();
      dt.items.add(new File([blob], "e2e.png", { type: "image/png" }));
      document.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true }));
    });
    await waitFor(
      async () => (await page.locator('img[src^="data:image"]').locator("visible=true").count()) > 0,
      "no thumbnail",
      10000,
    );
  });

  await step("session: send the image, it shows in the transcript", async () => {
    await visible(page, '[data-testid="reply"]').first().fill("What colour is this image? One word.");
    await visible(page, '[data-testid="send"]').first().click();
    await waitFor(
      async () => (await byText(page, "What colour is this image? One word.").count()) > 0,
      "not sent",
      30000,
    );
    // The image is in the same bubble as the text.
    const bubble = byText(page, "What colour is this image? One word.")
      .last()
      .locator("xpath=ancestor::div[.//img][1]");
    await waitFor(
      async () => (await bubble.locator('img[src^="data:image"]').count()) > 0,
      "image not in transcript",
      30000,
    );
  });

  await step("session: compact", async () => {
    await waitFor(
      async () => (await visible(page, '[data-testid="stop"]').count()) === 0,
      "still running",
      90000,
    );
    await visible(page, '[data-testid="session-menu"]').first().click();
    await byText(page, "Compact the conversation").first().click();
    await waitFor(async () => (await byText(page, "Compacting…").count()) > 0, "no note");
  });

  await step("session: stop a running turn", async () => {
    await waitFor(
      async () => (await visible(page, '[data-testid="stop"]').count()) === 0,
      "still busy",
      90000,
    );
    await sendInSession(page, "Run the shell command `sleep 60` and then say done.");
    await waitFor(
      async () => (await visible(page, '[data-testid="stop"]').count()) > 0,
      "never started",
      60000,
    );
    await visible(page, '[data-testid="stop"]').first().click();
    await waitFor(
      async () => (await visible(page, '[data-testid="stop"]').count()) === 0,
      "didn't stop",
      60000,
    );
  });

  await step("session: diff panel, thinking and tool output", async () => {
    // A fresh session: OpenCode can loop on a request sent after a stop in a compacted session.
    await openProject(page, PROJECT, true);
    await tab(page, "Sessions");
    await click(page, "new-session");
    await page.waitForURL(/\/app\/session\//, { timeout: 30000 });
    await sendInSession(
      page,
      `Create the file e2e-${stamp}.txt containing the word hello. Use the write tool.`,
    );
    await waitFor(async () => (await byText(page, "Changed files").count()) > 0, "no diff panel", 120000);
    await waitFor(
      async () => (await page.getByText(new RegExp(`e2e-${stamp}\\.txt`)).count()) > 0,
      "file not in diff",
      30000,
    );
    await idle(page);
    await page
      .getByText(/^Ran \d+ step/)
      .locator("visible=true")
      .last()
      .click();
    await waitFor(async () => (await byText(page, "completed").count()) > 0, "no tool status", 10000);
  });

  const permFile = `/var/tmp/peon-e2e-${stamp}.txt`;
  await step("permission: card shows what it asks; Allow once runs it", async () => {
    await idle(page);
    await sendInSession(
      page,
      `Write the word ok to the exact file path ${permFile} with the write tool. No other path.`,
    );
    await waitFor(async () => (await byText(page, "/var/tmp/*").count()) > 0, "no permission card", 120000);
    await visible(page, '[data-testid="allow-once"]').first().click();
    await waitFor(async () => existsSync(permFile), `${permFile} not written`, 90000);
    rmSync(permFile, { force: true });
  });

  await step("inbox: a permission can be denied from the inbox", async () => {
    await idle(page);
    await waitFor(
      async () => (await visible(page, '[data-testid="stop"]').count()) === 0,
      "still busy",
      90000,
    );
    await sendInSession(
      page,
      `Write the word no to /var/tmp/peon-e2e-deny-${stamp}.txt with the write tool. No other path.`,
    );
    await waitFor(async () => (await byText(page, "/var/tmp/*").count()) > 0, "no permission", 120000);
    await page.goto(`${BASE}/app`);
    await waitFor(async () => (await byText(page, "Deny").count()) > 0, "not in inbox");
    await byText(page, "Deny").first().click();
    await waitFor(async () => (await byText(page, "Deny").count()) === 0, "still in inbox", 30000);
    expect(!existsSync(`/var/tmp/peon-e2e-deny-${stamp}.txt`), "file written anyway");
  });

  await step("composer: preview while typing, Enter starts a session", async () => {
    await page.goto(`${BASE}/app`);
    const box = visible(page, '[data-testid="top-composer"]').first();
    await box.click();
    await box.fill(`new session in ${PROJECT}, reply with exactly: composed`);
    await waitFor(async () => (await byText(page, "New session").count()) > 0, "no preview");
    await box.press("Enter");
    await page.waitForURL(/\/app\/session\//, { timeout: 60000 });
    await waitFor(async () => (await byText(page, "composed").count()) > 0, "no reply", 90000);
  });

  await step("composer: a status question is answered in place", async () => {
    const box = visible(page, '[data-testid="top-composer"]').first();
    await box.click();
    await box.fill("anything waiting?");
    await box.press("Enter");
    await waitFor(
      async () =>
        (await page
          .getByText(/Sessions|No sessions|waiting/)
          .locator("visible=true")
          .count()) > 0,
      "no answer",
      60000,
    );
    await page.keyboard.press("Escape");
  });

  await step("routines: run a routine; the run shows who and is searchable", async () => {
    await openProject(page, ROUTINE, true);
    await waitFor(
      async () =>
        (await page
          .getByText(/^(you|schedule|\w+) · /)
          .locator("visible=true")
          .count()) > 0,
      "no runs listed",
    );
    const before = await page
      .getByText(/^you · /)
      .locator("visible=true")
      .count();
    await click(page, "run-routine");
    await page.waitForURL(/\/app\/session\//, { timeout: 60000 });
    await page.goBack();
    await waitFor(
      async () =>
        (await page
          .getByText(/^you · /)
          .locator("visible=true")
          .count()) > before,
      "run not listed as yours",
      60000,
    );
    await page.getByPlaceholder("Search runs and results").fill("zzz-no-match");
    await waitFor(async () => (await byText(page, "No runs match").count()) > 0, "search didn't filter");
  });

  await step("schedules page: filters and opens a project's schedules", async () => {
    await page.goto(`${BASE}/app/schedules`);
    await waitFor(async () => (await byText(page, "Only me").count()) > 0, "no filter");
    await tab(page, "Team");
    await tab(page, "All");
    const row = visible(page, '[data-kb="row"]').first();
    if ((await row.count()) > 0) {
      await row.click();
      await page.waitForURL(/tab=schedules/, { timeout: 15000 });
    }
  });

  await step("admin users: add, make admin, remove", async () => {
    const name = `e2e${stamp}`;
    await page.goto(`${BASE}/app/users`);
    await page.getByPlaceholder("Username").fill(name);
    await page.getByPlaceholder("Password (8 characters or more)").fill("e2e-password-1");
    await byText(page, "Add").first().click();
    await waitFor(async () => (await byText(page, `${name} can sign in now.`).count()) > 0, "not added");
    const row = page
      .locator("div")
      .filter({ has: byText(page, name) })
      .filter({ has: byText(page, "Remove") })
      .last();
    await row.getByText("Make admin", { exact: true }).click();
    await waitFor(async () => (await row.getByText("Make member", { exact: true }).count()) > 0, "not admin");
    page.once("dialog", (d) => d.accept());
    await row.getByText("Remove", { exact: true }).click();
    await waitFor(async () => (await byText(page, name).count()) === 0, "not removed");
  });

  await step("admin connectors: save and delete a secret", async () => {
    const name = `E2E_${stamp.toUpperCase()}`;
    await page.goto(`${BASE}/app/connectors`);
    await page.getByPlaceholder("FRONT_API_TOKEN").fill(name);
    await page.getByPlaceholder("Value").fill("e2e-value");
    await byText(page, "Save secret").first().click();
    await waitFor(async () => (await byText(page, name).count()) > 0, "not saved", 30000);
    page.once("dialog", (d) => d.accept());
    const row = page
      .locator("div")
      .filter({ has: byText(page, name) })
      .filter({ has: byText(page, "Delete") })
      .last();
    await row.getByText("Delete", { exact: true }).click();
    await waitFor(async () => (await byText(page, name).count()) === 0, "not deleted", 30000);
  });

  await step("admin models: lists connected providers and ones to connect", async () => {
    await page.goto(`${BASE}/app/models`);
    await waitFor(async () => (await byText(page, "Connect a provider").count()) > 0, "no providers", 30000);
  });

  await step("settings: voice reply, keymap and keycast save", async () => {
    await page.goto(`${BASE}/app/settings`);
    await tab(page, "Standard (alt+1–9, g …)");
    await waitFor(async () => (await byText(page, "Keymap saved.").count()) > 0, "keymap not saved");
    await tab(page, "tmux (prefix, then a key)");
    await waitFor(async () => (await byText(page, "Prefix").count()) > 0, "tmux not back");
  });

  await step("settings: change password and change it back", async () => {
    const field = page.getByPlaceholder("New password (8 characters or more)");
    await field.fill(`${PASS}-e2e`);
    await byText(page, "Change password").first().click();
    await waitFor(async () => (await byText(page, "Password changed.").count()) > 0, "not changed");
    await field.fill(PASS);
    await byText(page, "Change password").first().click();
    await waitFor(async () => (await byText(page, "Password changed.").count()) > 0, "not changed back");
  });

  await step("palette: jump to a project and offers routine runs", async () => {
    await page.keyboard.press("Control+k");
    await page.keyboard.type(PROJECT);
    await page.keyboard.press("Enter");
    await page.waitForURL(/\/app\/project\//, { timeout: 15000 });
    await page.keyboard.press("Control+k");
    await page.keyboard.type(`run ${ROUTINE}`);
    await waitFor(async () => (await byText(page, `Run ${ROUTINE}`).count()) > 0, "no run action");
    await page.keyboard.press("Escape");
  });

  await step("keyboard: prefix navigation, g-go-to, j/k + Enter, help", async () => {
    await page.mouse.click(1300, 700);
    await page.keyboard.press("Control+b");
    await page.keyboard.press("g");
    await page.keyboard.press("s");
    await page.waitForURL(/\/app\/schedules/, { timeout: 10000 });
    await page.keyboard.press("Control+b");
    await page.keyboard.press("i");
    await page.waitForURL(/\/app\/?$/, { timeout: 10000 });
    await page.goto(`${BASE}/app/projects`);
    await waitFor(async () => (await visible(page, '[data-kb="row"]').count()) > 0, "no rows");
    await page.mouse.click(1300, 800);
    await page.keyboard.press("j");
    await page.keyboard.press("Enter");
    await page.waitForURL(/\/app\/project\//, { timeout: 10000 });
    await page.keyboard.press("?");
    await waitFor(async () => (await byText(page, "Keyboard shortcuts").count()) > 0, "no help");
    await page.keyboard.press("Escape");
  });

  await step("logout: back to the login page", async () => {
    await page.goto(`${BASE}/app/settings`);
    await byText(page, "Sign out").first().click();
    await page.waitForURL(/\/login/, { timeout: 15000 });
  });

  await step("no page errors", async () => expect(errors.length === 0, errors.slice(0, 3).join(" | ")));
  await browser.close();
}

// ── iPhone (WebKit, iPhone 15): the phone layout ──────────────────────────

async function iphone() {
  console.log("\n== iphone (WebKit, iPhone 15) ==");
  const browser = await webkit.launch();
  const context = await browser.newContext({ ...devices["iPhone 15"] });
  const page = await context.newPage();
  current = page;
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await step("iphone login", () => login(page));

  await step("iphone tab bar: inbox, projects, routines, settings", async () => {
    for (const t of ["projects", "routines", "settings", "index"]) {
      await click(page, `tab-${t}`);
      await page.waitForTimeout(600);
    }
    await waitFor(async () => (await byText(page, "Inbox").count()) > 0, "not back on inbox");
  });

  await step("iphone project: tabs and a new session with a reply", async () => {
    await openProject(page, PROJECT, false);
    await tab(page, "Skills");
    await tab(page, "Schedules");
    await tab(page, "Sessions");
    await click(page, "new-session");
    await page.waitForURL(/\/app\/session\//, { timeout: 30000 });
    await sendInSession(page, "Reply with exactly the word: iphone");
    await waitFor(async () => (await byText(page, "iphone").count()) > 0, "no reply", 90000);
  });

  await step("iphone permission: Allow once from the session", async () => {
    const f = `/var/tmp/peon-e2e-ios-${stamp}.txt`;
    await sendInSession(
      page,
      `Write the word ok to the exact file path ${f} with the write tool. No other path.`,
    );
    await waitFor(async () => (await byText(page, "/var/tmp/*").count()) > 0, "no permission card", 120000);
    await visible(page, '[data-testid="allow-once"]').first().click();
    await waitFor(async () => existsSync(f), "file not written", 90000);
    rmSync(f, { force: true });
  });

  await step("iphone composer sheet: mic button opens it, Go starts a session", async () => {
    await page.goto(`${BASE}/app`);
    await click(page, "tab-mic");
    const box = page.locator('[data-testid="compose-input"]');
    await box.fill(`new session in ${PROJECT}, reply with exactly: sheet`);
    await waitFor(async () => (await byText(page, "New session").count()) > 0, "no preview");
    await click(page, "compose-go");
    await page.waitForURL(/\/app\/session\//, { timeout: 60000 });
    await waitFor(async () => (await byText(page, "sheet").count()) > 0, "no reply", 90000);
  });

  await step("iphone routines: run one", async () => {
    await page.goto(`${BASE}/app`);
    await click(page, "tab-routines");
    await click(page, `routine-${ROUTINE}`);
    await click(page, "run-routine");
    await page.waitForURL(/\/app\/session\//, { timeout: 60000 });
  });

  await step("iphone settings: admin pages open from Settings", async () => {
    await page.goto(`${BASE}/app`);
    await click(page, "tab-settings");
    await byText(page, "Users").first().click();
    await waitFor(async () => (await byText(page, "Add someone").count()) > 0, "users didn't open");
  });

  await step("iphone logout", async () => {
    await page.goto(`${BASE}/app/settings`);
    await byText(page, "Sign out").first().click();
    await page.waitForURL(/\/login/, { timeout: 15000 });
  });

  await step("iphone: no page errors", async () =>
    expect(errors.length === 0, errors.slice(0, 3).join(" | ")),
  );
  await browser.close();
}

if (!PASS) {
  console.error("Set PEON_PASS (and PEON_URL / PEON_USER).");
  process.exit(2);
}
if (mode === "desktop" || mode === "all") await desktop();
if (mode === "iphone" || mode === "all") await iphone();

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
