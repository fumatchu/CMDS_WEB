#!/usr/bin/env bash
# ============================================================
# CMDS-GO Release Preparation Script
# Run this on the DEV server before every release.
#
# What it does:
#   1. Removes dev artifacts from /opt/cmds-go
#   2. Clears runtime directories (keeps dir structure)
#   3. Creates a clean tarball: /root/cmds-go.tar.gz
#   4. Optionally uploads to a GitHub Release via gh CLI
#
# Usage:
#   chmod 700 prepare-release.sh
#   ./prepare-release.sh [--upload]
#
# Prerequisites for --upload:
#   dnf install gh   (GitHub CLI)
#   gh auth login
# ============================================================

set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"

APP_DIR="/opt/cmds-go"
TARBALL="/root/cmds-go.tar.gz"
GITHUB_REPO="fumatchu/CMDS_WEB"
UPLOAD=0

[[ "${1:-}" == "--upload" ]] && UPLOAD=1

ok()   { echo -e "  [${GREEN}✓${TEXTRESET}] $*"; }
fail() { echo -e "  [${RED}✗${TEXTRESET}] $*"; exit 1; }
info() { echo -e "  [${YELLOW}→${TEXTRESET}] $*"; }
section() { echo ""; echo -e "${CYAN}── $* ──${TEXTRESET}"; }

# ── Preflight ────────────────────────────────────────────────
clear
echo -e "${CYAN}CMDS-GO${TEXTRESET} ${YELLOW}Release Preparation${TEXTRESET}"
echo ""

[[ $EUID -eq 0 ]] || fail "Must be run as root"
ok "Running as root"

[[ -d "$APP_DIR" ]] || fail "${APP_DIR} not found — wrong server?"
ok "Found ${APP_DIR}"

# ── Confirm ──────────────────────────────────────────────────
section "Confirmation"
echo ""
echo -e "  This will modify ${CYAN}${APP_DIR}${TEXTRESET} by removing dev artifacts."
echo -e "  Runtime dirs (runs/, tmp/, logs/, state/, data/) will be emptied."
echo ""
read -r -p "  Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }

# ── Step 1: Remove .nfs lock files (SFTP/Mountain Duck artifacts) ──
section "Removing SFTP Lock Files"
NFS_COUNT=$(find "$APP_DIR" -name ".nfs.*" 2>/dev/null | wc -l)
if [[ $NFS_COUNT -gt 0 ]]; then
  find "$APP_DIR" -name ".nfs.*" -delete
  ok "Removed ${NFS_COUNT} .nfs lock file(s)"
else
  ok "No .nfs lock files found"
fi

# ── Step 2: Remove numbered backup files (.1 .2 etc) ──────────
section "Removing Numbered Backups"
NUMBERED=$(find "$APP_DIR" -type f \( -name "*.1" -o -name "*.2" -o -name "*.3" \) 2>/dev/null | wc -l)
if [[ $NUMBERED -gt 0 ]]; then
  find "$APP_DIR" -type f \( -name "*.1" -o -name "*.2" -o -name "*.3" \) -delete
  ok "Removed ${NUMBERED} numbered backup file(s)"
else
  ok "No numbered backup files found"
fi

# ── Step 3: Remove .bak / .orig files ────────────────────────
section "Removing Backup Files"
BAK_COUNT=$(find "$APP_DIR" -type f \( -name "*.bak" -o -name "*.bak2" -o -name "*.bak3" -o -name "*.bak4" -o -name "*.orig" \) 2>/dev/null | wc -l)
if [[ $BAK_COUNT -gt 0 ]]; then
  find "$APP_DIR" -type f \( -name "*.bak" -o -name "*.bak2" -o -name "*.bak3" -o -name "*.bak4" -o -name "*.orig" \) -delete
  ok "Removed ${BAK_COUNT} .bak/.orig file(s)"
else
  ok "No .bak/.orig files found"
fi

# ── Step 4: Remove specific dev/test artifacts ────────────────
section "Removing Dev/Test Artifacts"
REMOVED=0

for f in \
  "${APP_DIR}/ui/-d" \
  "${APP_DIR}/ui/-H" \
  "${APP_DIR}/ui/testlogin.html"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    info "Removed: ${f}"
    ((REMOVED++))
  fi
done

# Test files from write tests
WRITE_TESTS=$(find "$APP_DIR" -name "write_test*" -o -name "._write_test*" 2>/dev/null | wc -l)
if [[ $WRITE_TESTS -gt 0 ]]; then
  find "$APP_DIR" -name "write_test*" -delete 2>/dev/null || true
  find "$APP_DIR" -name "._write_test*" -delete 2>/dev/null || true
  info "Removed ${WRITE_TESTS} write_test file(s)"
  ((REMOVED += WRITE_TESTS))
fi

# Debug-named files
DEBUG_FILES=$(find "$APP_DIR" -name "*.brokenuipolling" -o -name "*.acl-bak" 2>/dev/null | wc -l)
if [[ $DEBUG_FILES -gt 0 ]]; then
  find "$APP_DIR" \( -name "*.brokenuipolling" -o -name "*.acl-bak" \) -delete
  info "Removed ${DEBUG_FILES} debug artifact(s)"
  ((REMOVED += DEBUG_FILES))
fi

# Temp files from editors/SFTP
TEMP_FILES=$(find "$APP_DIR" -name "*.tmp.*" -o -name "._*.tmp.*" 2>/dev/null | wc -l)
if [[ $TEMP_FILES -gt 0 ]]; then
  find "$APP_DIR" \( -name "*.tmp.*" -o -name "._*.tmp.*" \) -delete
  info "Removed ${TEMP_FILES} temp file(s)"
  ((REMOVED += TEMP_FILES))
fi

[[ $REMOVED -gt 0 ]] && ok "Total dev/test artifacts removed: ${REMOVED}" || ok "No dev/test artifacts found"

# ── Step 5: Remove __pycache__ ────────────────────────────────
section "Removing Python Cache"
CACHE=$(find "$APP_DIR" -type d -name "__pycache__" 2>/dev/null | wc -l)
if [[ $CACHE -gt 0 ]]; then
  find "$APP_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  ok "Removed ${CACHE} __pycache__ director(ies)"
else
  ok "No __pycache__ found"
fi

# ── Step 6: Clear runtime directories ─────────────────────────
section "Clearing Runtime Directories"
for dir in runs tmp logs state data; do
  if [[ -d "${APP_DIR}/${dir}" ]]; then
    COUNT=$(find "${APP_DIR}/${dir}" -mindepth 1 2>/dev/null | wc -l)
    if [[ $COUNT -gt 0 ]]; then
      rm -rf "${APP_DIR}/${dir:?}"/*
      ok "Cleared ${dir}/ (${COUNT} items removed)"
    else
      ok "${dir}/ already empty"
    fi
  else
    mkdir -p "${APP_DIR}/${dir}"
    ok "Created ${dir}/"
  fi
done

# ── Step 7: Verify no secrets in .env files ───────────────────
section "Secrets Check"
ENV_FILES=$(find "$APP_DIR" -name ".env" -not -name "*.example" 2>/dev/null)
if [[ -n "$ENV_FILES" ]]; then
  echo ""
  fail ".env file(s) found — remove before packaging:\n${ENV_FILES}"
fi
ok "No .env files found"

# ── Step 8: Show what will be packaged ────────────────────────
section "Package Preview"
info "Contents of ${APP_DIR}:"
find "$APP_DIR" -not -path '*/runs/*' -not -path '*/tmp/*' \
     -not -path '*/logs/*' -not -path '*/state/*' -not -path '*/data/*' \
     -not -path '*/__pycache__/*' \
     | sort | awk '{print "    " $0}'
echo ""
TOTAL_FILES=$(find "$APP_DIR" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$APP_DIR" | cut -f1)
info "Total files: ${TOTAL_FILES}  |  Total size: ${TOTAL_SIZE}"

# ── Step 9: Create tarball ────────────────────────────────────
section "Creating Tarball"
[[ -f "$TARBALL" ]] && rm -f "$TARBALL"

info "Building ${TARBALL}..."
tar -czf "$TARBALL" -C /opt cmds-go/
ok "Created: ${TARBALL}"

TAR_SIZE=$(du -sh "$TARBALL" | cut -f1)
CHECKSUM=$(sha256sum "$TARBALL" | cut -d' ' -f1)
ok "Size: ${TAR_SIZE}"
ok "SHA256: ${CHECKSUM}"

# Save checksum alongside tarball
echo "$CHECKSUM  cmds-go.tar.gz" > /root/cmds-go.tar.gz.sha256
ok "Checksum saved: /root/cmds-go.tar.gz.sha256"

# ── Step 10: Upload to GitHub Release (optional) ──────────────
section "GitHub Release"

if [[ $UPLOAD -eq 1 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    fail "'gh' CLI not found. Install: dnf install gh && gh auth login"
  fi

  # Prompt for version tag
  read -r -p "  Enter release tag (e.g., v1.0.0): " TAG
  [[ -n "$TAG" ]] || fail "Tag cannot be empty"

  read -r -p "  Release title (e.g., CMDS-GO ${TAG}): " TITLE
  [[ -n "$TITLE" ]] || TITLE="CMDS-GO ${TAG}"

  info "Creating GitHub Release ${TAG}..."
  gh release create "$TAG" "$TARBALL" \
    --repo "$GITHUB_REPO" \
    --title "$TITLE" \
    --notes "Release ${TAG} — built $(date '+%Y-%m-%d %H:%M')" \
    --latest

  ok "Release ${TAG} created and tarball uploaded"
  ok "Install URL: https://github.com/${GITHUB_REPO}/releases/latest/download/cmds-go.tar.gz"
else
  echo ""
  info "To upload to GitHub, run:"
  echo ""
  echo "    gh release create <tag> ${TARBALL} \\"
  echo "      --repo ${GITHUB_REPO} \\"
  echo "      --title 'CMDS-GO <tag>' \\"
  echo "      --latest"
  echo ""
  info "Or run this script with: ./prepare-release.sh --upload"
fi

# ── Done ─────────────────────────────────────────────────────
section "Complete"
echo ""
echo -e "  ${GREEN}Tarball ready: ${TARBALL}${TEXTRESET}"
echo -e "  ${GREEN}SHA256: ${CHECKSUM}${TEXTRESET}"
echo ""
