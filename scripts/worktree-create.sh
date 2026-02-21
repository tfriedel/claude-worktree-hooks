#!/usr/bin/env bash
# Claude Code WorktreeCreate hook — creates the worktree and runs setup.
#
# Contract:
#   - Receives JSON on stdin with 'name' field
#   - Must print the absolute worktree path on stdout (nothing else!)
#   - Progress output goes to /dev/tty
#
# Customize the sections below for your project:
#   - ENV_FILES: which env files to copy from the main repo
#   - COPY_DIRS: which directories to copy
#   - "Install dependencies": your package manager commands
#
# Usage: Add to .claude/settings.json (see settings.json template)
set -euo pipefail

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')
REPO_PATH="$CLAUDE_PROJECT_DIR"
WORKTREE_PATH="${REPO_PATH}/.claude/worktrees/${NAME}"
BRANCH="worktree-${NAME}"

# Progress goes to /dev/tty — stdout is reserved for Claude
TTY=/dev/tty
log() { echo "$*" > "$TTY" 2>/dev/null || true; }

hash_port() {
  local hash
  hash=$(echo -n "$1" | md5sum | tr -d -c '0-9' | head -c 5)
  echo $(( (hash % 6900) + 3100 ))
}
DEV_PORT=$(hash_port "$BRANCH")

log "Creating worktree (branch: $BRANCH, port: $DEV_PORT)..."

# --- Create the git worktree ---
# IMPORTANT: redirect git output away from stdout — Claude parses stdout for the path
mkdir -p "${REPO_PATH}/.claude/worktrees"
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git worktree add "$WORKTREE_PATH" "$BRANCH" >/dev/null 2>&1
else
  git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1
fi

# --- Copy env files from main repo ---
log "  Copying env files..."
ENV_FILES=(".env" ".env.local")
for f in "${ENV_FILES[@]}"; do
  [ -f "${REPO_PATH}/$f" ] && cp "${REPO_PATH}/$f" "${WORKTREE_PATH}/$f"
done

# --- Copy directories ---
# Useful for data dirs, fixtures, or other non-gittracked content.
COPY_DIRS=()  # e.g., ("data" "fixtures" "secrets")
for d in "${COPY_DIRS[@]}"; do
  if [ -d "${REPO_PATH}/$d" ]; then
    mkdir -p "${WORKTREE_PATH}/$d"
    cp -rT "${REPO_PATH}/$d" "${WORKTREE_PATH}/$d"
  fi
done

# --- Generate .env.local with a deterministic port ---
cat > "${WORKTREE_PATH}/.env.local" << EOF
DEV_PORT=${DEV_PORT}
EOF

# --- Install dependencies ---
# Customize for your stack. Verbose output goes to a log file.
LOGFILE="${WORKTREE_PATH}/.worktree-setup.log"
SETUP_ERRORS=()

# Uncomment and customize:
# log "  Installing Node dependencies..."
# (cd "${WORKTREE_PATH}" && npm install) >> "$LOGFILE" 2>&1 || SETUP_ERRORS+=("'npm install' failed")
# log "  Installing Python dependencies..."
# (cd "${WORKTREE_PATH}" && pip install -e '.[dev]') >> "$LOGFILE" 2>&1 || SETUP_ERRORS+=("'pip install' failed")

# --- Done ---
if [ ${#SETUP_ERRORS[@]} -gt 0 ]; then
  log "Setup completed with errors:"
  printf '  - %s\n' "${SETUP_ERRORS[@]}" > "$TTY" 2>/dev/null || true
  log "See $LOGFILE for details."
else
  log "Worktree ready."
fi

# Tell Claude where the worktree is — THE ONLY THING ON STDOUT
echo "$WORKTREE_PATH"
