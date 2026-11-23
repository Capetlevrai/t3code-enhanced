# Providers: OpenCode v2 and Oh My Pi (Windows)

Field notes from setting these up on T3 Code 0.1.11 (Windows 11). Each item is a trap that cost time; the fix is listed with how to check it.

Tested versions: T3 Code 0.1.11, OpenCode 2.3.2, omp 19.1.0, omp-t3 1.5.0, Bun 1.4.5, Node 24.

## 1. OpenCode: move to v2

T3 Code ships an OpenCode **v2** adapter (it bundles the OpenCode 2.0.28 SDK schema). The `opencode-ai` npm package still tops out at 1.x, so `npm update -g` never gets you there.

```powershell
opencode upgrade --major   # installs @opencode/cli 2.x and removes opencode-ai 1.x
opencode --version         # expect: opencode v2.x
```

- Back up `~\.config\opencode` and `~\.local\share\opencode` first: `--major` removes v1.
- Restart T3 Code afterwards: it probes the OpenCode version at startup.

## 2. Switching provider mid-thread (handoff)

T3 Code can hand a thread over to another provider (Claude → OpenCode → Claude, Claude → Antigravity, …) by passing a summary of the conversation.

- **Desktop:** works with OpenCode both ways. Every bundled adapter reports `supportsProviderSwitchingViaHandoff: true`.
- **iOS app:** once an OpenCode turn has run in a thread, *Thread settings* only lists OpenCode. The server still allows the switch, so the iOS app is the one hiding the other providers. Workaround: switch provider from the desktop app, or start a new thread on the phone.

### What the target model actually receives

The handoff is **not** the whole thread. The target model gets one bounded excerpt (`packages/provider-core/src/server/handoffBudget.ts` in T3 Code 0.1.11):

- **Size:** `min(T3CODE_CONTEXT_HANDOFF_TOKEN_CAP, 64000, free room in the target model)`. Despite its name, the cap is compared to **bytes** of serialized history: the default `16000` is roughly 4k tokens, the maximum `64000` roughly 16k tokens. The free room is the model's window minus what it already holds, your new message, and a work reserve of at least a quarter of the window.
- **Selection:** your last message, the last "assistant" item (which can be a command output or a file change, not necessarily a written answer), your first message, then newest-first until the budget is full. An item that does not fit is skipped whole; command outputs are never truncated, so a few big ones can crowd everything else out.
- **Omitted items:** only the 20 most recent omitted ids are listed, with an instruction to fetch them with the `t3_thread_read` tool.
- **Switching back** to a provider that already took part only sends what happened since its last turn (`delta_since_target_last_seen`). A bigger cap does not resend what an earlier handoff dropped.

On a long thread (185 items, many tool outputs), the default sent 11 items and omitted 174, including the answer the next question was about.

### Making handoffs more reliable

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\improve-handoff.ps1   # -Undo to revert
```

Then quit T3 Code completely and restart it. The script:

1. Sets the user variable `T3CODE_CONTEXT_HANDOFF_TOKEN_CAP=64000`, the maximum T3 Code accepts (4× the default excerpt). It is still bounded by the free room of the target model, so small models stay safe. Cost: at most ~16k extra input tokens on the turn that switches.
2. Adds a short rule, between markers, to each installed agent's global instructions: when a handoff omitted items and the request depends on one of them, read the thread with `t3_thread_read` (`view: "messages"`, then `beforePosition`) instead of guessing. Files: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` (or `$CODEX_HOME`), `~/.gemini/GEMINI.md` (T3 Code copies it into its isolated Antigravity profile), `~/.config/opencode/AGENTS.md`, `~/.omp/agent/AGENTS.md`. The rest of each file is left untouched; `-Undo` removes only the block.

3. Installs a `/recap` command (see the [README](../README.md#recap-before-switching-provider)): a native command for Claude Code, omp and OpenCode, and a rule-based fallback for Codex and Antigravity/Gemini.

Habits that help on top of it:

- **Before switching**, type `/recap`. The last assistant message is selected first, so a compact recap almost always makes it through whole. Do not rely on `/compact` instead: compaction summaries are not part of what a handoff sends (`historicalMessage` keeps user/assistant messages, commands, file changes, errors and plans only).
- **When switching to resume a precise point**, quote a distinctive sentence from the answer you mean. Your new message is never cut.
- **Keep noisy work out of the main thread:** delegate big builds or log dumps to a sub-agent so their output does not eat the handoff budget.

## 3. Oh My Pi (omp) in T3 Code

T3 Code has no Oh My Pi driver. omp is a fork of Pi, and T3 Code has a **Pi** driver (`pi --mode rpc`, JSONL over stdio), but omp does not speak it exactly. The community shim [omp-t3](https://github.com/hashangit/omp-t3) sits between them.

### Quick setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-oh-my-pi.ps1 `
  -Favorites "<provider>/<model>,<provider>/<other-model>"
```

Take the model ids from `omp models ls <pattern>` (e.g. `zai/glm-5.3`). Close T3 Code first, or add `-Force` (T3 Code reloads `settings.json` live). Re-running is safe: it keeps your instance's `environment`, colour and other `config` keys, never downgrades omp-t3, and skips the write when nothing changes. Undo with `-Remove`.

### What does not work, and why

| Attempt | Result | Cause |
| --- | --- | --- |
| Pi driver → `omp.exe` directly | Turns never finish, no approval prompts, model list can drop the connection | omp sends `session_settled` (T3 waits for `agent_settled`), `--mode rpc` mutes confirmations, and the model catalog can exceed the 1 MB frame limit. omp-t3 fixes all three. |
| ACP Registry driver, local command `omp acp` | No selectable model in T3 Code | See the `config` trap below; ACP also skips everything omp-t3 adapts. |
| `binaryPath` at the top level of the instance | T3 Code silently runs `pi` instead (fails with *"Pi CLI is installed but failed to run"* if Pi is broken or absent) | Driver settings belong under `config`. |

### Traps

1. **`config` key.** A provider instance in `~\.t3\userdata\settings.json` is `{ driver, displayName, enabled, environment, config }`. Driver settings (`binaryPath`, `launchArgs`, ACP `commandPath`, …) go inside `config`:

   ```json
   "ohmypi": {
     "driver": "pi",
     "displayName": "Oh My Pi",
     "enabled": true,
     "config": { "binaryPath": "C:\\Users\\<you>\\AppData\\Roaming\\npm\\omp-t3.cmd" }
   }
   ```

2. **Bun version.** omp 19.x exits with `Bun runtime must be >= 1.4.4` on older Bun. Run `bun upgrade`, then `omp --version` should print `omp/19.x`. A failed global install can also leave `omp` pointing at a missing `dist/cli.js`: reinstall with `bun install -g @oh-my-pi/pi-coding-agent`.

3. **omp-t3 can file GitHub issues as you.** When it detects a protocol drift, it runs `gh issue create` on its own repo with your logged-in `gh` (at most once a day per drift). It has no switch to turn that off. `setup-oh-my-pi.ps1` patches the default in `src/doctor.js` so this only happens with `OMPT3_FILE_ISSUES=1`, and refuses to enable the provider if it cannot verify the patch. **`npm update -g omp-t3` reverts the patch:** re-run the script afterwards (it keeps the updated version).

4. **omp-t3 defaults change omp's behavior.** It removes omp's native `task` subagents and tells the model to delegate through T3's `delegate_task`. Delegated models must be on a built-in allowlist (`glm-5.3-flash`, `gemini-3.8-flash`, `deepseek-v4.1-flash` only) and off a denylist (`gpt-*sol*`, `*opus*`, `glm-5.3`, `glm-5.3:*`). To restore stock omp, add to the instance in `settings.json`:

   ```json
   "environment": {
     "OMPT3_DELEGATE_TASKS": "0",
     "OMPT3_SUBAGENT_ALLOWED_MODELS": "",
     "OMPT3_SUBAGENT_DISALLOWED_MODELS": ""
   }
   ```

   The two lists must be truly empty (blank in T3 Code's settings UI). Typing `""` into the UI field makes `""` a pattern that matches no model, which blocks every delegation.

5. **Sessions junction.** `omp-t3 --check` creates `~\.pi\agent\sessions` → `~\.omp\agent\sessions` (so T3's usage view sees omp sessions). It never replaces an existing folder, but if you also use upstream Pi, its new sessions now land in omp's folder.

6. **Model ids.** T3 Code names Pi-driver models `<provider>/<id>`, as returned by omp (`omp models ls <pattern>`). Favorites must match exactly, e.g. `zhipuai-coding-plan/glm-5.4`.

7. **Models missing from omp's catalog.** Add a provider to `~\.omp\agent\models.yml` (OpenAI-compatible example below), then check with `omp models ls <id>` and `omp -p --no-session --model <provider>/<id> "ping"`. Keep API keys out of any repo.

   ```yaml
   providers:
     zhipuai-coding-plan:
       baseUrl: https://open.bigmodel.cn/api/coding/paas/v4
       apiKey: <your key>
       api: openai-completions
       compat:
         supportsStore: false
         supportsDeveloperRole: false
         reasoningContentField: reasoning_content
         maxTokensField: max_tokens
       models:
         - id: glm-5.4
           name: GLM-5.4
           reasoning: true
           thinking: { mode: effort, efforts: [low, high, max], defaultLevel: high }
           input: [text]
           contextWindow: 1000000
           maxTokens: 131072
   ```

### Check it works

```powershell
omp-t3 --check        # expect "All checks passed!"; a first-run [WARN] about extension deferral is normal
```

In T3 Code, *Oh My Pi* should list your omp models. A one-line prompt should then answer and finish its turn (it should not stay "running").

## Troubleshooting

| Symptom | Check |
| --- | --- |
| *Pi CLI is installed but failed to run* | `binaryPath` is under `config`? `& "<binaryPath>" --version` exits 0? |
| *Provider executable is not installed* (ACP) | `commandPath` is under `config`. |
| Oh My Pi lists no models | `omp-t3 --check` reports the catalog size; `omp models ls` works in a terminal. |
| `omp` crashes on start | `bun --version` ≥ 1.4.4. |
| Setup stops with *omp-t3 a change* | A new omp-t3 moved the issue-filing code: check `src/doctor.js` by hand before using it. |
| OpenCode adapter errors after an update | `opencode --version` is 2.x; restart T3 Code. |
