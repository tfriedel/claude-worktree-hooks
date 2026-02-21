# Auto-Setup for Claude Code Worktrees: Env Files, Ports, and Dependencies

Claude Code recently shipped a `--worktree` flag that creates isolated git worktrees for parallel AI sessions. It's great — spin up `claude --worktree auth-refactor` and you get a fresh copy of your repo on its own branch, completely isolated from your main working directory.

But here's the thing: a fresh worktree is _empty_. No `.env` files. No `node_modules`. No virtualenv. You have to set all that up before the agent can do anything useful.

We solved this with hooks. Here's how.

## Quick start

1. Copy `worktree-create.sh` and `worktree-remove.sh` into your repo's `scripts/` directory
2. Make them executable: `chmod +x scripts/worktree-create.sh scripts/worktree-remove.sh`
3. Customize the env files, directories, and dependency install commands in `worktree-create.sh`
4. Merge [settings.json](./settings.json) into your `.claude/settings.json`
5. Add `**/.claude/worktrees/` to your `.gitignore`
6. Run `claude --worktree my-feature` and watch the setup happen automatically

## The problem

Say your project needs a few things before it can run:

```
.env              # API keys, secrets
.env.local        # Local overrides (dev server port, etc.)
node_modules/     # JS dependencies
.venv/            # Python virtualenv
```

Every time you spin up a new worktree, all of that is missing. You'd have to manually:

1. Copy `.env` from your main repo
2. Run `npm install`
3. Set up your virtualenv
4. Pick a port that doesn't collide with your other worktrees

If you're running 3 parallel Claude sessions, that's a lot of manual setup. And if you forget the `.env`, your agent will waste tokens debugging missing environment variables.

## The solution: WorktreeCreate hook

Claude Code has a [hook system](https://code.claude.com/docs/en/hooks) that lets you run shell commands on specific events. The one we want is [`WorktreeCreate`](https://code.claude.com/docs/en/hooks#worktreecreate) — it fires when `claude --worktree` is invoked, **before** the TUI renders.

From the docs: "If you configure a WorktreeCreate hook, it replaces the default git behavior." Your script creates the worktree with `git worktree add`, runs any setup you need, and prints the worktree path on stdout. Claude then starts a session in that directory.

The docs frame this as a way to support non-git VCS (SVN, Perforce, Mercurial), but it works just as well for git — and it's the cleanest way to run setup during worktree creation, since your script has full control of the terminal before the TUI appears.

### Step 1: The create script

Create `scripts/worktree-create.sh` in your repo (or grab the [template](./worktree-create.sh)):

```bash
#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')
REPO_PATH="$CLAUDE_PROJECT_DIR"
WORKTREE_PATH="${REPO_PATH}/.claude/worktrees/${NAME}"
BRANCH="worktree-${NAME}"

# Progress goes to /dev/tty — stdout is reserved for Claude (see below)
log() { echo "$*" > /dev/tty 2>/dev/null || true; }

log "Creating worktree (branch: $BRANCH)..."

# Create the git worktree — redirect git output away from stdout!
mkdir -p "${REPO_PATH}/.claude/worktrees"
git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1

# Copy env files from main repo
log "  Copying env files..."
for f in .env .env.local; do
  [ -f "${REPO_PATH}/$f" ] && cp "${REPO_PATH}/$f" "${WORKTREE_PATH}/$f"
done

# Install dependencies (customize for your stack)
log "  Installing dependencies..."
(cd "${WORKTREE_PATH}" && npm install) >> /tmp/worktree-setup.log 2>&1 || true

log "Worktree ready."

# Tell Claude where the worktree is — THE ONLY THING ON STDOUT
echo "$WORKTREE_PATH"
```

Make it executable: `chmod +x scripts/worktree-create.sh`

### The stdout contract

The [docs](https://code.claude.com/docs/en/hooks#worktreecreate) explain the contract: "The hook must print the absolute path to the created worktree directory on stdout." In practice, the critical detail is that _nothing else_ can go to stdout:

- **stdout**: The worktree path, and only the path. Any extra output (like `git worktree add`'s "HEAD is now at..." message) gets concatenated with your path. Claude can't parse it and hangs silently.
- **stdin**: JSON with `name`, `session_id`, `cwd`, and other fields. Read it with `cat` into a variable — you can only read it once.
- **/dev/tty**: Use this for progress output. It goes straight to the terminal, bypassing Claude's capture entirely.

### Step 2: Wire it up

Add this to your `.claude/settings.json`:

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/worktree-create.sh"
          }
        ]
      }
    ]
  }
}
```

### Step 3: Gitignore the worktrees

Add this to your `.gitignore` so worktree contents don't pollute `git status` in your main repo:

```
**/.claude/worktrees/
```

This is safe — the pattern is relative to the working tree root, so it won't affect anything _inside_ the worktrees themselves.

## Bonus: Deterministic ports

If you run dev servers, you'll hit port collisions fast. Worktree A starts on port 3000, worktree B tries port 3000... boom.

The fix: hash the branch name into a deterministic port number. Same branch always gets the same port.

```bash
hash_port() {
  local hash
  hash=$(echo -n "$1" | md5sum | tr -d -c '0-9' | head -c 5)
  echo $(( (hash % 6900) + 3100 ))
}

BRANCH="worktree-${NAME}"
DEV_PORT=$(hash_port "$BRANCH")

cat > "${WORKTREE_PATH}/.env.local" << EOF
DEV_PORT=${DEV_PORT}
EOF
```

Now each worktree gets a stable port in the 3100-9999 range. Your dev server just reads `DEV_PORT` from `.env.local` and uses it. No collisions, no guessing.

## Bonus: Cleanup on removal

Claude Code also has a `WorktreeRemove` hook that fires when a worktree is being deleted. It receives JSON on stdin with a `worktree_path` field. Use it to kill lingering processes and clean up the git worktree:

```json
{
  "hooks": {
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/worktree-remove.sh"
          }
        ]
      }
    ]
  }
}
```

```bash
#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
WORKTREE_PATH=$(echo "$INPUT" | jq -r '.worktree_path')

[ ! -d "$WORKTREE_PATH" ] && exit 0

# Kill processes on the worktree's dev port
if [ -f "${WORKTREE_PATH}/.env.local" ]; then
  DEV_PORT=$(grep -oP 'DEV_PORT=\K\d+' "${WORKTREE_PATH}/.env.local" || true)
  [ -n "$DEV_PORT" ] && lsof -ti :"$DEV_PORT" | xargs kill 2>/dev/null || true
fi

# Remove the git worktree and its branch
BRANCH=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
[ -n "$BRANCH" ] && git branch -D "$BRANCH" 2>/dev/null || true
```

## Gotchas we hit

**`git worktree add` prints to stdout.** Its "HEAD is now at..." message gets concatenated with your path output. Claude can't parse it and hangs silently. Always redirect: `git worktree add ... >/dev/null 2>&1`.

**Inline commands don't reliably receive stdin.** Using a command string directly in `settings.json` with `cat /dev/stdin | jq` resulted in empty stdin. Switching to a script file fixed this.

**stdin can only be read once.** Don't try to pipe `cat /dev/stdin` twice. Read into a variable first: `INPUT=$(cat)`.

**Why not SessionStart?** We initially used `SessionStart` with a `"startup"` matcher. It works, but the hook runs _after_ the TUI renders, so your progress output interleaves with Claude's banner and prompt. `WorktreeCreate` runs before the TUI, giving you clean terminal output.

## Putting it all together

Here's the workflow:

```
claude --worktree my-feature
```

What happens behind the scenes:

1. `WorktreeCreate` fires, runs `worktree-create.sh`
2. Script creates `.claude/worktrees/my-feature/` with branch `worktree-my-feature`
3. Script copies `.env`, installs deps, assigns port 7342
4. Script prints the worktree path on stdout
5. Claude starts a session inside the worktree, TUI renders
6. Claude is ready to work with a fully configured environment

When you're done:

1. You exit the session
2. Claude asks if you want to keep or remove the worktree
3. If you remove it, `WorktreeRemove` fires, kills the dev server on port 7342
4. Worktree and branch are cleaned up

## Files

- [`worktree-create.sh`](./worktree-create.sh) — Creates worktree + runs setup, with env copying, deterministic ports, and dependency installation
- [`worktree-remove.sh`](./worktree-remove.sh) — Cleanup script for WorktreeRemove hook
- [`settings.json`](./settings.json) — Hook configuration to add to your `.claude/settings.json`

Customize the dependency installation section for your stack (npm, pip, cargo, etc.) and the list of env files to copy.
