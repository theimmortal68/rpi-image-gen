#!/usr/bin/env bash
# Migrate legacy IG-era names to KS names across the repo.
# - Dry-run by default (prints diffs). Use --apply to write.
# - --include-config: also migrate IGconf_*/IGCONF_* and igconf_* funcs
# - --migrate-dirs:   move templates/rpi -> templates, ks_helpers -> hooks
# - --migrate-files:  rename bin/igconf -> bin/ksconf and any *igconf* files

set -euo pipefail

# ------------------- config: token maps -------------------

# Core helpers/paths/env (strict word boundaries where sensible)
declare -a MAP_BASE=(
  'KS_TEMPLATES|KS_TEMPLATES'
  'KS_HELPERS|KS_HELPERS'
  'KS_TEMPLATES|KS_TEMPLATES'
  'KS_TEMPLATES|KS_TEMPLATES'
  'KS_HELPERS|KS_HELPERS'
  'KS_META_HOOKS_DIR\b|KS_META_HOOKS_DIR'
  '\bIGTOP\b|KS_TOP'
  '\bIGIMAGE\b|KS_IMAGE'
  '\bIGDEVICE\b|KS_DEVICE'
  '\bIGPROFILE\b|KS_PROFILE'
)

# Config vars + helper functions (enabled with --include-config)
#  - IGconf_*  → KSconf_*
#  - IGCONF_*  → KSCONF_*
#  - igconf_*  → ksconf_*   (functions/utilities)
declare -a MAP_CONFIG=(
  'IGconf_([A-Za-z0-9_]+)|KSconf_\1'
  'IGCONF_([A-Za-z0-9_]+)|KSCONF_\1'
  '\bigconf_([A-Za-z0-9_]+)\b|ksconf_\1'
)

# Files/paths to exclude from scanning
EXCLUDES=(
  '.git'
  'node_modules'
  'build'
  'dist'
  '.venv'
  'venv'
  '.idea'
  '.vscode'
  '*.png' '*.jpg' '*.jpeg' '*.webp' '*.ico' '*.pdf' '*.zip' '*.gz' '*.zst' '*.img'
)

# ------------------- CLI -------------------

APPLY=0
INCLUDE_CONFIG=0
MIGRATE_DIRS=0
MIGRATE_FILES=0
ROOT='.'

usage() {
  cat <<EOF
Usage: $(basename "$0") [repo_root] [--apply] [--include-config] [--migrate-dirs] [--migrate-files]

Options:
  --apply            Write changes (default: dry-run prints diffs)
  --include-config   Also migrate IGconf_*/IGCONF_* and igconf_* -> KSconf_*/KSCONF_*/ksconf_*
  --migrate-dirs     Move: templates/rpi -> templates ; ks_helpers -> hooks (or symlink if both exist)
  --migrate-files    Rename files: bin/igconf -> bin/ksconf ; any *igconf* -> *ksconf* (safe best-effort)

Examples:
  Dry-run:  $(basename "$0")
  Apply:     $(basename "$0") --apply
  Full:      $(basename "$0") --apply --include-config --migrate-dirs --migrate-files
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; break ;;
    --apply) APPLY=1 ;;
    --include-config) INCLUDE_CONFIG=1 ;;
    --migrate-dirs) MIGRATE_DIRS=1 ;;
    --migrate-files) MIGRATE_FILES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)  ROOT="$1" ;;
  esac
  shift || true
done
if [[ $# -gt 0 && "$ROOT" = '.' ]]; then ROOT="$1"; shift; fi
cd "$ROOT"

# ------------------- helpers -------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

list_files() {
  local -a args=( . '(' )
  local first=1
  for e in "${EXCLUDES[@]}"; do
    [[ $first -eq 0 ]] && args+=( -o )
    if [[ "$e" == *'*'* || "$e" == *'?'* || "$e" == *'['* ]]; then
      args+=( -name "$e" )
    else
      args+=( -path "./$e" )
    fi
    first=0
  done
  args+=( ')' -prune -o -type f -print )
  find "${args[@]}" | while read -r f; do
    # Skip binaries
    if file -b --mime "$f" | grep -q 'charset=binary'; then
      continue
    fi
    echo "$f"
  done
}

apply_maps() {
  local file="$1"; shift
  local -a maps=( "$@" )
  if have_cmd gsed; then
    local expr=(); for m in "${maps[@]}"; do IFS='|' read -r a b <<<"$m"; expr+=( -E -e "s/${a}/${b}/g" ); done
    if [[ $APPLY -eq 1 ]]; then gsed -i "${expr[@]}" -- "$file"; else gsed "${expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true; fi
  elif sed --version >/dev/null 2>&1; then
    local expr=(); for m in "${maps[@]}"; do IFS='|' read -r a b <<<"$m"; expr+=( -E -e "s/${a}/${b}/g" ); done
    if [[ $APPLY -eq 1 ]]; then sed -i "${expr[@]}" -- "$file"; else sed "${expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true; fi
  else
    local -a perl_expr=(); for m in "${maps[@]}"; do IFS='|' read -r a b <<<"$m"; perl_expr+=( -pe "s/${a}/${b}/g" ); done
    if [[ $APPLY -eq 1 ]]; then perl -0777 -i "${perl_expr[@]}" -- "$file"; else perl -0777 "${perl_expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true; fi
  fi
}

move_dirs() {
  local moved=0
  if [[ -d templates/rpi ]]; then
    echo "[dirs] moving templates/rpi -> templates"
    mkdir -p templates
    rsync -a templates/rpi/ templates/
    rm -rf templates/rpi
    moved=1
  fi
  if [[ -d ks_helpers && ! -e hooks ]]; then
    echo "[dirs] renaming ks_helpers -> hooks"
    mv ks_helpers hooks; moved=1
  elif [[ -d ks_helpers && -d hooks ]]; then
    echo "[dirs] creating symlink ks_helpers -> hooks"
    rm -rf ks_helpers; ln -s hooks ks_helpers; moved=1
  fi
  [[ $moved -eq 0 ]] && echo "[dirs] nothing to migrate"
}

rename_files() {
  local changed=0
  # canonical: bin/igconf -> bin/ksconf
  if [[ -f bin/igconf && ! -e bin/ksconf ]]; then
    echo "[files] renaming bin/igconf -> bin/ksconf"
    git mv bin/igconf bin/ksconf 2>/dev/null || mv bin/igconf bin/ksconf
    changed=1
  fi
  # any file/dir with 'igconf' in name -> 'ksconf'
  while read -r path; do
    [[ "$path" == *ksconf* ]] && continue
    local new="${path//igconf/ksconf}"
    echo "[files] renaming $path -> $new"
    mkdir -p "$(dirname "$new")"
    git mv "$path" "$new" 2>/dev/null || mv "$path" "$new"
    changed=1
  done < <(git ls-files '*igconf*' 2>/dev/null || find . -type f -name '*igconf*')
  [[ $changed -eq 0 ]] && echo "[files] nothing to rename"
}

echo "== IG→KS migration =="
echo " dry-run: $((1-APPLY)) (use --apply to write)"
echo " include-config: $INCLUDE_CONFIG"
echo " migrate-dirs: $MIGRATE_DIRS"
echo " migrate-files: $MIGRATE_FILES"
echo

if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[git] repo: $(git rev-parse --show-toplevel)"
  if [[ $APPLY -eq 1 ]]; then
    git add -A >/dev/null 2>&1 || true
    git commit -m "checkpoint: before full IG→KS migration" >/dev/null 2>&1 || true
  fi
fi

MAP_ALL=( "${MAP_BASE[@]}" )
if [[ $INCLUDE_CONFIG -eq 1 ]]; then MAP_ALL+=( "${MAP_CONFIG[@]}" ); fi

changed=0
while read -r f; do
  if ! grep -E -q 'KS_TEMPLATES|KS_HELPERS|KS_TEMPLATES|KS_TEMPLATES|KS_HELPERS|KS_META_HOOKS_DIR|KS_TOP|KS_IMAGE|KS_DEVICE|KS_PROFILE|IGconf_|IGCONF_|\bigconf_' "$f"; then
    continue
  fi
  if [[ $APPLY -eq 1 ]]; then
    apply_maps "$f" "${MAP_ALL[@]}"
  else
    tmp=$(mktemp); cp "$f" "$tmp"
    (APPLYSAVE=$APPLY; APPLY=1; export APPLY; apply_maps "$tmp" "${MAP_ALL[@]}" >/dev/null 2>&1 || true; APPLY=$APPLYSAVE)
    if ! cmp -s "$f" "$tmp"; then
      echo "---- $f"; diff -u "$f" "$tmp" || true; changed=1
    fi
    rm -f "$tmp"
  fi
done < <(list_files)

[[ $MIGRATE_DIRS -eq 1 ]] && move_dirs
[[ $MIGRATE_FILES -eq 1 ]] && rename_files

if [[ $APPLY -eq 1 ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -A
    git commit -m "migrate: IG → KS (vars, funcs, dirs, files)${INCLUDE_CONFIG:+ +config}" || true
  fi
  echo "✓ migration applied."
else
  if [[ $changed -eq 0 && $MIGRATE_DIRS -eq 0 && $MIGRATE_FILES -eq 0 ]]; then
    echo "No changes would be made. Use --include-config / --migrate-dirs / --migrate-files."
  else
    echo; echo "Dry-run complete. Re-run with --apply to write changes."
  fi
fi
