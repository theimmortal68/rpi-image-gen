#!/usr/bin/env bash
# scripts/migrate_ig_to_ks.sh
# Migrate legacy IG-era names to KS names across the repo.
# - Dry-run by default (prints diffs). Use --apply to write.
# - Skips .git and common vendor/build dirs and binary files.
# - Optional: --include-config to migrate IGconf_*/IGCONF_* -> KSconf_*/KSCONF_*.
# - Optional: --migrate-dirs to move templates/rpi -> templates and ks_helpers -> hooks.

set -euo pipefail

## -------------------- configuration --------------------

# Core token replacements (helpers/paths/env). Format: 'old|new'
# add to MAP_BASE
declare -a MAP_BASE=(
  'RPI_TEMPLATES|KS_TEMPLATES'
  'BDEBSTRAP_HOOKS|KS_HELPERS'
  'KS_TEMPLATES_RPI|KS_TEMPLATES'
  'IG_TEMPLATES|KS_TEMPLATES'
  'IG_HOOKS|KS_HELPERS'
  'META_HOOKS\b|KS_META_HOOKS_DIR'
  '\bIGTOP\b|KS_TOP'
  '\bIGIMAGE\b|KS_IMAGE'
  '\bIGDEVICE\b|KS_DEVICE'
  '\bIGPROFILE\b|KS_PROFILE'   # optional, if present
)

# Optional config prefix migration
declare -a MAP_CONFIG_PREFIX=(
  'IGconf_([A-Za-z0-9_]+)|KSconf_\1'
  'IGCONF_([A-Za-z0-9_]+)|KSCONF_\1'
)

# Paths/globs to exclude from scanning
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

## -------------------- CLI --------------------

APPLY=0
INCLUDE_CONFIG=0
MIGRATE_DIRS=0
ROOT='.'   # <-- default repo root; changed from ${1:-.}

usage() {
  cat <<EOF
Usage: $(basename "$0") [repo_root] [--apply] [--include-config] [--migrate-dirs]

  --apply            Write changes (default is dry-run; prints unified diffs)
  --include-config   Also migrate IGconf_*/IGCONF_* -> KSconf_*/KSCONF_*
  --migrate-dirs     Move:
                       templates/rpi -> templates (merge)
                       ks_helpers    -> hooks (or symlink if both exist)

Examples:
  Dry-run:  $(basename "$0")
  Apply:     $(basename "$0") --apply
  Full:      $(basename "$0") --apply --include-config --migrate-dirs
EOF
}

# Robust option parsing with support for `--` end-of-options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; break ;;                 # stop option parsing
    --apply) APPLY=1 ;;
    --include-config) INCLUDE_CONFIG=1 ;;
    --migrate-dirs) MIGRATE_DIRS=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)  ROOT="$1" ;;                    # positional repo root
  esac
  shift || true
done

# If there is exactly one leftover positional arg after `--`, treat as ROOT
if [[ $# -gt 0 ]]; then
  if [[ "$ROOT" = '.' ]]; then
    ROOT="$1"; shift
  else
    echo "Too many positional args: $* (already set root: $ROOT)" >&2
    exit 1
  fi
fi

cd "$ROOT"

## -------------------- helpers --------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# List candidate text files (no eval; build find args as array)
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

# Apply regex replacements to a file
apply_maps() {
  local file="$1"; shift
  local -a maps=( "$@" )

  # Prefer GNU sed if available; otherwise perl fallback (portable)
  if have_cmd gsed; then
    local expr=()
    for m in "${maps[@]}"; do IFS='|' read -r from to <<<"$m"; expr+=( -E -e "s/${from}/${to}/g" ); done
    if [[ $APPLY -eq 1 ]]; then
      gsed -i "${expr[@]}" -- "$file"
    else
      gsed "${expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true
    fi
  elif sed --version >/dev/null 2>&1; then
    local expr=()
    for m in "${maps[@]}"; do IFS='|' read -r from to <<<"$m"; expr+=( -E -e "s/${from}/${to}/g" ); done
    if [[ $APPLY -eq 1 ]]; then
      sed -i "${expr[@]}" -- "$file"
    else
      sed "${expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true
    fi
  else
    # perl -0777 processes whole file (handles multi-line patterns)
    local -a perl_expr=()
    for m in "${maps[@]}"; do IFS='|' read -r from to <<<"$m"; perl_expr+=( -pe "s/${from}/${to}/g" ); done
    if [[ $APPLY -eq 1 ]]; then
      perl -0777 -i "${perl_expr[@]}" -- "$file"
    else
      perl -0777 "${perl_expr[@]}" -- "$file" | diff -u --label "$file" "$file" - || true
    fi
  fi
}

# Move/merge directories safely
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
    mv ks_helpers hooks
    moved=1
  elif [[ -d ks_helpers && -d hooks ]]; then
    echo "[dirs] both ks_helpers and hooks exist; creating symlink ks_helpers -> hooks"
    rm -rf ks_helpers
    ln -s hooks ks_helpers
    moved=1
  fi

  [[ $moved -eq 0 ]] && echo "[dirs] nothing to migrate"
}

## -------------------- run --------------------

echo "== IG→KS migration =="
echo " dry-run: $((1-APPLY)) (use --apply to write)"
echo " include-config: $INCLUDE_CONFIG"
echo " migrate-dirs: $MIGRATE_DIRS"
echo

if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[git] repo: $(git rev-parse --show-toplevel)"
  if [[ $APPLY -eq 1 ]]; then
    git add -A >/dev/null 2>&1 || true
    git commit -m "checkpoint: before IG→KS migration" >/dev/null 2>&1 || true
  fi
fi

# Compose mapping set
MAP_ALL=( "${MAP_BASE[@]}" )
if [[ $INCLUDE_CONFIG -eq 1 ]]; then
  MAP_ALL+=( "${MAP_CONFIG_PREFIX[@]}" )
fi

changed=0
while read -r f; do
  # fast prefilter: skip files with no triggers
  if ! grep -E -q 'KS_TEMPLATES|KS_HELPERS|KS_TEMPLATES|KS_TEMPLATES|KS_HELPERS|KS_META_HOOKS_DIR|IGconf_|IGCONF_' "$f"; then
    continue
  fi

  if [[ $APPLY -eq 1 ]]; then
    apply_maps "$f" "${MAP_ALL[@]}"
  else
    # Produce diff only if changes would occur
    tmp=$(mktemp)
    cp "$f" "$tmp"
    ( APPLYSAVE=$APPLY; APPLY=1; export APPLY; apply_maps "$tmp" "${MAP_ALL[@]}" >/dev/null 2>&1 || true; APPLY=$APPLYSAVE )
    if ! cmp -s "$f" "$tmp"; then
      echo "---- $f"
      diff -u "$f" "$tmp" || true
      changed=1
    fi
    rm -f "$tmp"
  fi
done < <(list_files)

if [[ $MIGRATE_DIRS -eq 1 ]]; then
  move_dirs
fi

if [[ $APPLY -eq 1 ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -A
    git commit -m "migrate: IG-era names → KS names${INCLUDE_CONFIG:+ (incl. config)}" || true
  fi
  echo "✓ migration applied."
else
  if [[ $changed -eq 0 ]]; then
    echo "No changes would be made. Try --include-config or check patterns."
  else
    echo
    echo "Dry-run complete. Re-run with --apply to write changes."
  fi
fi
