#!/usr/bin/env bash
# Bricksearch installer — idempotent, diagnostic, fresh-user-safe.
#
# Handles every failure mode observed in testing:
#   - missing gh auth / missing databricks-eng membership -> actionable error
#   - stale ~/plugin-marketplace from a prior failed attempt -> git pull or clear error
#   - wrong repo at ~/plugin-marketplace -> refuses to clobber, tells user to move it
#   - fresh isaac users with no ~/.claude/commands dir -> mkdir -p
#   - multiple plugin versions in cache -> picks highest via sort -V
#   - zsh strict-glob vs bash literal -> explicit ls/tail, no glob
#   - user retries after anything -> every step is idempotent
#
# Usage: curl -fsSL https://muditmittal.github.io/bricksearch-plugin/install.sh | bash
#        or: bash install.sh

set -euo pipefail

# Colors (skipped if non-TTY or NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'; BLU='\033[0;34m'; DIM='\033[2m'; RST='\033[0m'
else
    GRN=''; RED=''; YLW=''; BLU=''; DIM=''; RST=''
fi

step()    { printf "${BLU}==>${RST} %s\n" "$*"; }
ok()      { printf "${GRN}✓${RST}   %s\n" "$*"; }
warn()    { printf "${YLW}!${RST}   %s\n" "$*"; }
fail()    { printf "${RED}✗${RST}   %s\n" "$*" 1>&2; }
die()     { fail "$*"; printf "\n${RED}Install aborted.${RST}\n" 1>&2; exit 1; }

MARKETPLACE_URL="https://github.com/databricks-eng/plugin-marketplace.git"
MARKETPLACE_DIR="$HOME/plugin-marketplace"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/experimental-plugin-marketplace/db-bricksearch"
COMMANDS_DIR="$HOME/.claude/commands"
ORG="databricks-eng"

printf "\n${BLU}Bricksearch installer${RST}\n"
printf "${DIM}Installs db-bricksearch plugin + /bricksearch command${RST}\n\n"

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

command -v git   >/dev/null || die "git not found. Install Xcode command-line tools: xcode-select --install"
command -v isaac >/dev/null || die "isaac not found. Install via the Databricks internal onboarding process."
ok "git and isaac are installed"

# gh is recommended but optional — only needed for friendlier auth errors.
if command -v gh >/dev/null; then
    HAS_GH=1
else
    HAS_GH=0
    warn "gh CLI not found. Install with: brew install gh (recommended for auth)"
fi

# ---------------------------------------------------------------------------
# 2. GitHub auth
# ---------------------------------------------------------------------------
step "Verifying GitHub access to ${ORG} org"

if [ "$HAS_GH" = "1" ]; then
    if ! gh auth status >/dev/null 2>&1; then
        fail "gh is not authenticated."
        printf "\n${DIM}Run:${RST}\n  gh auth login\n${DIM}Select: GitHub.com -> HTTPS -> login with a browser.${RST}\n"
        printf "${DIM}Use the GitHub account linked to your @databricks.com SSO.${RST}\n\n"
        die "Re-run this installer after gh auth succeeds."
    fi

    if ! gh api "user/memberships/orgs/${ORG}" --jq '.state' 2>/dev/null | grep -q active; then
        fail "Your GitHub account is not an active member of '${ORG}'."
        printf "\n${DIM}Request membership via the internal Databricks GitHub-org-access process.${RST}\n"
        printf "${DIM}If you just joined the org, authorize SSO: https://github.com/orgs/${ORG}/sso${RST}\n\n"
        die "Cannot reach the internal marketplace without org membership."
    fi
    ok "gh authenticated and ${ORG} membership verified"

    # Make sure git knows how to use gh for https clones
    gh auth setup-git >/dev/null 2>&1 || true
else
    # No gh — we'll trust the clone to surface any auth errors.
    warn "Skipping pre-flight auth check (gh not installed). Clone may fail with 'Repository not found' if you're not in ${ORG}."
fi

# ---------------------------------------------------------------------------
# 3. Marketplace (clone or pull, idempotent)
# ---------------------------------------------------------------------------
step "Preparing marketplace at ${MARKETPLACE_DIR}"

if [ -d "$MARKETPLACE_DIR/.git" ]; then
    # Is it the right repo?
    EXISTING_URL=$(git -C "$MARKETPLACE_DIR" config --get remote.origin.url 2>/dev/null || echo "")
    NORMALIZED="${EXISTING_URL%.git}"
    EXPECTED="${MARKETPLACE_URL%.git}"
    if [ "$NORMALIZED" = "$EXPECTED" ]; then
        step "Existing clone found — pulling latest"
        if git -C "$MARKETPLACE_DIR" pull --ff-only 2>&1 | sed 's/^/    /'; then
            ok "Marketplace up to date"
        else
            warn "Pull failed — local changes may be present. Using existing checkout."
        fi
    else
        fail "${MARKETPLACE_DIR} exists but its origin is '${EXISTING_URL:-(none)}'."
        printf "\n${DIM}Expected: ${MARKETPLACE_URL}${RST}\n"
        printf "${DIM}Move it aside and re-run:${RST}\n  mv ${MARKETPLACE_DIR} ${MARKETPLACE_DIR}.backup\n\n"
        die "Refusing to clobber an unrelated repository."
    fi
elif [ -e "$MARKETPLACE_DIR" ]; then
    fail "${MARKETPLACE_DIR} exists but is not a git repository."
    printf "\n${DIM}This usually means a prior install attempt left partial state.${RST}\n"
    printf "${DIM}Move it aside and re-run:${RST}\n  mv ${MARKETPLACE_DIR} ${MARKETPLACE_DIR}.backup\n\n"
    die "Refusing to clobber an existing directory."
else
    step "Cloning marketplace (first-time setup)"
    if ! git clone "$MARKETPLACE_URL" "$MARKETPLACE_DIR" 2>&1 | sed 's/^/    /'; then
        fail "Clone failed."
        printf "\n${DIM}If you saw 'Repository not found': you're not authenticated as a ${ORG} member.${RST}\n"
        printf "${DIM}Run:${RST}\n  gh auth login\n  gh auth setup-git\n  gh api user/memberships/orgs/${ORG}\n\n"
        die "Could not clone marketplace."
    fi
    ok "Marketplace cloned"
fi

# ---------------------------------------------------------------------------
# 4. Install plugin
# ---------------------------------------------------------------------------
step "Installing db-bricksearch plugin"

if ! isaac plugin add db-bricksearch@experimental 2>&1 | sed 's/^/    /'; then
    fail "isaac plugin add failed."
    printf "\n${DIM}Verify marketplace layout:${RST}\n  ls ${MARKETPLACE_DIR}/experimental/general/db-bricksearch/\n\n"
    die "Plugin install failed."
fi

# Verify the cache landed
if [ ! -d "$PLUGIN_CACHE" ]; then
    die "Plugin cache missing at $PLUGIN_CACHE. isaac plugin add may have silently failed."
fi
ok "Plugin installed"

# ---------------------------------------------------------------------------
# 5. Register /bricksearch command
# ---------------------------------------------------------------------------
step "Registering /bricksearch command"

mkdir -p "$COMMANDS_DIR"

# Pick the highest version deterministically (no shell globs)
VERSION_DIRS=$(find "$PLUGIN_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)
if [ -z "$VERSION_DIRS" ]; then
    die "No plugin version directories in $PLUGIN_CACHE. Install is incomplete."
fi
LATEST=$(echo "$VERSION_DIRS" | tail -1)
SRC="$LATEST/commands/bricksearch.md"

if [ ! -f "$SRC" ]; then
    die "bricksearch.md not found in $LATEST/commands/. Plugin version may be incompatible."
fi

cp "$SRC" "$COMMANDS_DIR/bricksearch.md"
ok "Registered /bricksearch (version $(basename "$LATEST"))"

# ---------------------------------------------------------------------------
# 6. Final verification
# ---------------------------------------------------------------------------
step "Verifying install"

MISS=0
for p in \
    "$MARKETPLACE_DIR/experimental/general/db-bricksearch/.claude-plugin/plugin.json" \
    "$PLUGIN_CACHE" \
    "$COMMANDS_DIR/bricksearch.md"
do
    if [ -e "$p" ]; then
        ok "$p"
    else
        fail "missing: $p"
        MISS=$((MISS+1))
    fi
done

if [ "$MISS" -ne 0 ]; then
    die "Install verification failed ($MISS missing)."
fi

printf "\n${GRN}✓ Bricksearch installed successfully.${RST}\n\n"
printf "  Marketplace: ${DIM}${MARKETPLACE_DIR}${RST}\n"
printf "  Plugin:      ${DIM}${LATEST}${RST}\n"
printf "  Command:     ${DIM}${COMMANDS_DIR}/bricksearch.md${RST}\n\n"
printf "${BLU}Next steps${RST}\n"
printf "  1. Start a ${BLU}new${RST} isaac session (existing sessions won't pick up the command).\n"
printf "  2. Type ${BLU}/bricksearch${RST} followed by your research question.\n\n"
printf "${DIM}To update later: re-run this installer, or \`isaac plugin update\`.${RST}\n"
