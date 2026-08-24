#!/bin/bash

# shellcheck disable=SC2034

# Iromihon's embedded fallback for Omarchy's native theme-source contract.
# Keep the storage layout and JSON schema compatible with the proposed core
# interface so an eventual native implementation can take over in place.

THEME_REPO_THEMES_DIR="$HOME/.config/omarchy/themes"
THEME_REPO_SOURCES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy/theme-sources"
THEME_REPO_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/theme-sources"
THEME_REPO_LOCK="${XDG_RUNTIME_DIR:-/tmp}/omarchy-theme-sources-${UID}.lock"

THEME_REPO_MAX_THEMES=128
THEME_REPO_MAX_SOURCE_FILES=2048
THEME_REPO_MAX_THEME_FILES=256
THEME_REPO_MAX_SOURCE_BYTES=$((512 * 1024 * 1024))
THEME_REPO_MAX_PREVIEW_BYTES=$((32 * 1024 * 1024))
THEME_REPO_MAX_PALETTE_BYTES=$((128 * 1024))
THEME_REPO_MAX_COLOR_CHARS=64
THEME_REPO_MAX_PATH_CHARS=512
THEME_REPO_MAX_WALLPAPERS=12
THEME_REPO_MAX_SHELL_SURFACES=16
THEME_REPO_CLONE_SECONDS=90
THEME_REPO_CLONE_FILE_BLOCKS=$((512 * 1024))

THEME_REPO_NAMES=()
THEME_REPO_RELATIVE_PATHS=()
THEME_REPO_INSTALLED_NAMES=()
THEME_REPO_SOURCE_ID=""
THEME_REPO_SOURCE_PATH=""
THEME_REPO_SOURCE_URL=""

theme_repo_error() {
  printf 'Error: %s\n' "$*" >&2
}

theme_repo_base_url() {
  printf '%s\n' "${1%%#*}"
}

theme_repo_url_path() {
  local repo_path

  repo_path=$(theme_repo_base_url "$1")
  if [[ $repo_path != *"://"* && $repo_path == *:*/* ]]; then
    repo_path="${repo_path#*:}"
  fi

  repo_path="${repo_path%%\?*}"
  printf '%s\n' "$repo_path"
}

theme_repo_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

theme_repo_name_from_url() {
  local repo_name

  repo_name=$(basename "$(theme_repo_url_path "$1")" .git | tr '[:upper:]' '[:lower:]')
  repo_name=$(printf '%s' "$repo_name" | sed -E 's/^omarchy-//; s/-theme$//')
  theme_repo_slugify "$repo_name"
}

theme_repo_source_id() {
  local repo_url repo_name repo_hash

  repo_url=$(theme_repo_base_url "$1")
  repo_name=$(basename "$(theme_repo_url_path "$repo_url")" .git)
  repo_name=$(theme_repo_slugify "$repo_name")
  [[ -n $repo_name ]] || repo_name="theme-source"
  repo_hash=$(printf '%s' "$repo_url" | sha256sum | cut -c1-12)
  printf '%s-%s\n' "$repo_name" "$repo_hash"
}

theme_repo_valid_source_id() {
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*-[a-f0-9]{12}$ ]]
}

theme_repo_valid_slug() {
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

theme_repo_name_exists() {
  local requested_name="$1"
  local name

  for name in "${THEME_REPO_NAMES[@]}"; do
    [[ $name == "$requested_name" ]] && return 0
  done

  return 1
}

theme_repo_count_files() {
  local source_path="$1"
  local search_path="$2"
  local limit="$3"
  local path count=0

  while IFS= read -r -d '' path; do
    (( count += 1 ))
    if (( count > limit )); then
      break
    fi
  done < <(find -P "$search_path" -path "$source_path/.git" -prune -o -type f -print0)

  printf '%d\n' "$count"
}

theme_repo_validate_source_payload() {
  local source_path="$1"
  local unsafe_path path source_file_count source_bytes

  unsafe_path=$(find -P "$source_path" -path "$source_path/.git" -prune -o -type l -print -quit)
  if [[ -n $unsafe_path ]]; then
    theme_repo_error "Theme source contains a symlink: ${unsafe_path#"$source_path"/}"
    return 1
  fi

  unsafe_path=$(find -P "$source_path" -path "$source_path/.git" -prune -o -type f -perm /111 -print -quit)
  if [[ -n $unsafe_path ]]; then
    theme_repo_error "Theme source contains an executable file: ${unsafe_path#"$source_path"/}"
    return 1
  fi

  source_file_count=$(theme_repo_count_files "$source_path" "$source_path" "$THEME_REPO_MAX_SOURCE_FILES")
  if (( source_file_count > THEME_REPO_MAX_SOURCE_FILES )); then
    theme_repo_error "Theme source exceeds $THEME_REPO_MAX_SOURCE_FILES files."
    return 1
  fi

  source_bytes=$(find -P "$source_path" -path "$source_path/.git" -prune -o -type f -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')
  if (( source_bytes > THEME_REPO_MAX_SOURCE_BYTES )); then
    theme_repo_error "Theme source exceeds $THEME_REPO_MAX_SOURCE_BYTES bytes."
    return 1
  fi

  while IFS= read -r -d '' path; do
    if (( ${#path} > THEME_REPO_MAX_PATH_CHARS )); then
      theme_repo_error "Theme source contains a path longer than $THEME_REPO_MAX_PATH_CHARS characters."
      return 1
    fi
  done < <(find -P "$source_path" -path "$source_path/.git" -prune -o -print0)
}

theme_repo_validate_theme() {
  local source_path="$1"
  local theme_path="$2"
  local preview palette theme_file_count

  if [[ ! -f $theme_path/colors.toml && ! -f $theme_path/alacritty.toml ]]; then
    theme_repo_error "Theme '$(basename "$theme_path")' needs colors.toml or alacritty.toml at its root."
    return 1
  fi

  for palette in "$theme_path/colors.toml" "$theme_path/alacritty.toml"; do
    [[ -f $palette ]] || continue
    if (( $(stat -c%s "$palette") > THEME_REPO_MAX_PALETTE_BYTES )); then
      theme_repo_error "Palette exceeds $THEME_REPO_MAX_PALETTE_BYTES bytes: ${palette#"$theme_path"/}"
      return 1
    fi
  done

  theme_file_count=$(theme_repo_count_files "$source_path" "$theme_path" "$THEME_REPO_MAX_THEME_FILES")
  if (( theme_file_count > THEME_REPO_MAX_THEME_FILES )); then
    theme_repo_error "Theme '$(basename "$theme_path")' exceeds $THEME_REPO_MAX_THEME_FILES files."
    return 1
  fi

  while IFS= read -r -d '' preview; do
    if (( $(stat -c%s "$preview") > THEME_REPO_MAX_PREVIEW_BYTES )); then
      theme_repo_error "Preview exceeds $THEME_REPO_MAX_PREVIEW_BYTES bytes: ${preview#"$theme_path"/}"
      return 1
    fi
  done < <(find -P "$theme_path" -type f \( -iname 'preview.*' -o -path '*/backgrounds/*' \) -print0)
}

theme_repo_discover() {
  local source_path="$1"
  local child name origin_url

  THEME_REPO_NAMES=()
  THEME_REPO_RELATIVE_PATHS=()
  theme_repo_validate_source_payload "$source_path" || return 1

  if [[ -f $source_path/colors.toml || -f $source_path/alacritty.toml ]]; then
    origin_url=$(git -C "$source_path" config --get remote.origin.url 2>/dev/null || true)
    name=$(theme_repo_name_from_url "$origin_url")
    if [[ -z $name ]] || ! theme_repo_valid_slug "$name"; then
      theme_repo_error "The repository name does not produce a valid theme slug."
      return 1
    fi

    theme_repo_validate_theme "$source_path" "$source_path" || return 1
    THEME_REPO_NAMES+=("$name")
    THEME_REPO_RELATIVE_PATHS+=(".")
    return
  fi

  if [[ ! -d $source_path/themes ]]; then
    theme_repo_error "Repository root needs colors.toml, or a collection needs themes/<slug>/colors.toml."
    return 1
  fi

  while IFS= read -r -d '' child; do
    if (( ${#THEME_REPO_NAMES[@]} >= THEME_REPO_MAX_THEMES )); then
      theme_repo_error "Collection exceeds $THEME_REPO_MAX_THEMES themes."
      return 1
    fi

    name=$(basename "$child")
    if ! theme_repo_valid_slug "$name"; then
      theme_repo_error "Collection theme directory '$name' is not a lowercase hyphen slug."
      return 1
    fi

    theme_repo_validate_theme "$source_path" "$child" || return 1
    THEME_REPO_NAMES+=("$name")
    THEME_REPO_RELATIVE_PATHS+=("themes/$name")
  done < <(find -P "$source_path/themes" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

  if (( ${#THEME_REPO_NAMES[@]} == 0 )); then
    theme_repo_error "Collection contains no themes under themes/<slug>/."
    return 1
  fi
}

theme_repo_link_owned_by_source() {
  local link_path="$1"
  local source_path="$2"
  local target

  [[ -L $link_path ]] || return 1
  target=$(readlink "$link_path")
  [[ $target == "$source_path" || $target == "$source_path/"* ]]
}

theme_repo_installed_dir() {
  local source_path="$1"

  printf '%s/%s/installed\n' "$THEME_REPO_STATE_DIR" "$(basename "$source_path")"
}

theme_repo_theme_installed() {
  local source_path="$1"
  local theme_name="$2"
  local installed_dir

  installed_dir=$(theme_repo_installed_dir "$source_path")
  [[ -f $installed_dir/$theme_name ]]
}

theme_repo_migrate_state() {
  local source_path="$1"
  local source_id installed_dir link theme_name

  source_id=$(basename "$source_path")
  installed_dir=$(theme_repo_installed_dir "$source_path")
  [[ -d $installed_dir ]] && return

  mkdir -p "$installed_dir"
  while IFS= read -r -d '' link; do
    theme_repo_link_owned_by_source "$link" "$source_path" || continue
    theme_name=$(basename "$link")
    theme_repo_valid_slug "$theme_name" && touch "$installed_dir/$theme_name"
  done < <(find "$THEME_REPO_THEMES_DIR" -mindepth 1 -maxdepth 1 -type l -print0 2>/dev/null)

  if [[ -d $THEME_REPO_STATE_DIR/$source_id/disabled ]]; then
    rm -rf "$THEME_REPO_STATE_DIR/$source_id/disabled"
  fi
}

theme_repo_relative_path() {
  local requested_name="$1"
  local index

  for index in "${!THEME_REPO_NAMES[@]}"; do
    if [[ ${THEME_REPO_NAMES[$index]} == "$requested_name" ]]; then
      printf '%s\n' "${THEME_REPO_RELATIVE_PATHS[$index]}"
      return
    fi
  done

  return 1
}

theme_repo_target() {
  local source_path="$1"
  local theme_name="$2"
  local relative_path

  relative_path=$(theme_repo_relative_path "$theme_name") || return 1
  if [[ $relative_path == "." ]]; then
    printf '%s\n' "$source_path"
  else
    printf '%s/%s\n' "$source_path" "$relative_path"
  fi
}

theme_repo_preflight_names() {
  local source_path="$1"
  shift
  local name destination
  local conflicts=()

  for name in "$@"; do
    destination="$THEME_REPO_THEMES_DIR/$name"
    if [[ -e $destination || -L $destination ]]; then
      theme_repo_link_owned_by_source "$destination" "$source_path" || conflicts+=("$name")
    fi
  done

  if (( ${#conflicts[@]} > 0 )); then
    theme_repo_error "Already installed theme names would be replaced: ${conflicts[*]}"
    return 1
  fi
}

theme_repo_installed_names() {
  local source_path="$1"
  local name

  THEME_REPO_INSTALLED_NAMES=()
  for name in "${THEME_REPO_NAMES[@]}"; do
    if theme_repo_theme_installed "$source_path" "$name"; then
      THEME_REPO_INSTALLED_NAMES+=("$name")
    fi
  done
}

theme_repo_validate_installed_children() {
  local source_path="$1"
  local installed_dir marker name

  installed_dir=$(theme_repo_installed_dir "$source_path")
  for marker in "$installed_dir"/*; do
    [[ -f $marker ]] || continue
    name=$(basename "$marker")
    if ! theme_repo_name_exists "$name"; then
      theme_repo_error "Update removes installed theme '$name'; detach it before updating."
      return 1
    fi
  done
}

theme_repo_sync_source() {
  local source_path="$1"
  local name target destination link target_name expected_target

  theme_repo_discover "$source_path" || return 1
  theme_repo_migrate_state "$source_path"
  theme_repo_validate_installed_children "$source_path" || return 1
  theme_repo_installed_names "$source_path"
  theme_repo_preflight_names "$source_path" "${THEME_REPO_INSTALLED_NAMES[@]}" || return 1
  mkdir -p "$THEME_REPO_THEMES_DIR"

  for name in "${THEME_REPO_INSTALLED_NAMES[@]}"; do
    target=$(theme_repo_target "$source_path" "$name")
    destination="$THEME_REPO_THEMES_DIR/$name"
    if [[ -L $destination ]]; then
      if [[ $(readlink "$destination") != "$target" ]]; then
        rm "$destination"
        ln -s "$target" "$destination"
      fi
    elif [[ ! -e $destination ]]; then
      ln -s "$target" "$destination"
    fi
  done

  while IFS= read -r -d '' link; do
    theme_repo_link_owned_by_source "$link" "$source_path" || continue
    target_name=$(basename "$link")
    expected_target=""
    if theme_repo_theme_installed "$source_path" "$target_name" && theme_repo_name_exists "$target_name"; then
      expected_target=$(theme_repo_target "$source_path" "$target_name")
    fi

    if [[ -z $expected_target || $(readlink "$link") != "$expected_target" ]]; then
      rm "$link"
    fi
  done < <(find "$THEME_REPO_THEMES_DIR" -mindepth 1 -maxdepth 1 -type l -print0 2>/dev/null)
}

theme_repo_kill_clone_group() {
  local clone_pid="$1"
  local attempt

  kill -TERM -- "-$clone_pid" 2>/dev/null || true
  for (( attempt = 0; attempt < 30; attempt++ )); do
    if ! kill -0 -- "-$clone_pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  kill -KILL -- "-$clone_pid" 2>/dev/null || true
}

theme_repo_clone() {
  local repo_url="$1"
  local destination="$2"
  local clone_pid status
  local interrupted=false
  local restore_errexit=false

  (
    umask 077
    ulimit -f "$THEME_REPO_CLONE_FILE_BLOCKS"
    exec setsid timeout --signal=TERM --kill-after=3s "${THEME_REPO_CLONE_SECONDS}s" \
      env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git -c core.hooksPath=/dev/null clone --quiet --depth 1 --single-branch --no-recurse-submodules --no-local -- "$repo_url" "$destination" \
      >/dev/null 2>&1
  ) &
  clone_pid=$!

  trap 'interrupted=true; theme_repo_kill_clone_group "$clone_pid"' TERM INT HUP
  [[ $- == *e* ]] && restore_errexit=true
  set +e
  wait "$clone_pid"
  status=$?
  if [[ $restore_errexit == "true" ]]; then
    set -e
  fi
  trap - TERM INT HUP

  if [[ $interrupted == "true" ]]; then
    return 143
  fi
  if kill -0 -- "-$clone_pid" 2>/dev/null; then
    theme_repo_kill_clone_group "$clone_pid"
  fi
  return "$status"
}

theme_repo_refresh_source() {
  local source_path="$1"
  local source_id origin_url temp_root candidate_path previous_path

  source_id=$(basename "$source_path")
  origin_url=$(git -C "$source_path" config --get remote.origin.url 2>/dev/null || true)
  if [[ -z $origin_url ]]; then
    theme_repo_error "Theme source has no origin URL: $source_path"
    return 1
  fi

  temp_root=$(mktemp -d "$THEME_REPO_SOURCES_DIR/.refresh.XXXXXX")
  candidate_path="$temp_root/candidate"
  previous_path="$temp_root/previous"
  if ! theme_repo_clone "$origin_url" "$candidate_path"; then
    rm -rf "$temp_root"
    theme_repo_error "Failed to refresh theme source $source_id."
    return 1
  fi

  theme_repo_discover "$candidate_path" || {
    rm -rf "$temp_root"
    return 1
  }
  theme_repo_validate_installed_children "$source_path" || {
    rm -rf "$temp_root"
    return 1
  }
  theme_repo_installed_names "$source_path"
  theme_repo_preflight_names "$source_path" "${THEME_REPO_INSTALLED_NAMES[@]}" || {
    rm -rf "$temp_root"
    return 1
  }

  trap '' TERM INT HUP
  if ! mv "$source_path" "$previous_path"; then
    trap - TERM INT HUP
    rm -rf "$temp_root"
    theme_repo_error "Failed to stage the current source for update."
    return 1
  fi
  if ! mv "$candidate_path" "$source_path"; then
    mv "$previous_path" "$source_path"
    trap - TERM INT HUP
    rm -rf "$temp_root"
    theme_repo_error "Failed to activate the candidate source update."
    return 1
  fi
  if theme_repo_sync_source "$source_path"; then
    rm -rf "$temp_root"
    trap - TERM INT HUP
    return
  fi

  rm -rf "${source_path:?}"
  mv "$previous_path" "$source_path"
  theme_repo_sync_source "$source_path" || true
  rm -rf "$temp_root"
  trap - TERM INT HUP
  return 1
}

theme_repo_prepare_source() {
  local repo_url="$1"
  local refresh="${2:-false}"
  local source_id source_path existing_url temp_root clone_path

  repo_url=$(theme_repo_base_url "$repo_url")
  if [[ -z $repo_url ]]; then
    theme_repo_error "A Git repository URL is required."
    return 1
  fi

  source_id=$(theme_repo_source_id "$repo_url")
  source_path="$THEME_REPO_SOURCES_DIR/$source_id"
  mkdir -p "$THEME_REPO_SOURCES_DIR" "$THEME_REPO_STATE_DIR"
  if [[ -e $source_path ]]; then
    if [[ ! -d $source_path/.git ]]; then
      theme_repo_error "Theme source path exists but is not a Git repository: $source_path"
      return 1
    fi

    existing_url=$(git -C "$source_path" config --get remote.origin.url 2>/dev/null || true)
    if [[ $existing_url != "$repo_url" ]]; then
      theme_repo_error "Theme source identity does not match its installed repository."
      return 1
    fi

    if [[ $refresh == "true" ]]; then
      theme_repo_refresh_source "$source_path" || return 1
    else
      theme_repo_discover "$source_path" || return 1
      theme_repo_migrate_state "$source_path"
      theme_repo_sync_source "$source_path" || return 1
    fi
  else
    temp_root=$(mktemp -d "$THEME_REPO_SOURCES_DIR/.install.XXXXXX")
    clone_path="$temp_root/repository"
    if ! theme_repo_clone "$repo_url" "$clone_path"; then
      rm -rf "$temp_root"
      theme_repo_error "Failed to clone theme repository."
      return 1
    fi

    theme_repo_discover "$clone_path" || {
      rm -rf "$temp_root"
      return 1
    }
    mv "$clone_path" "$source_path"
    rm -rf "$temp_root"
    mkdir -p "$(theme_repo_installed_dir "$source_path")"
    theme_repo_sync_source "$source_path" || return 1
  fi

  THEME_REPO_SOURCE_ID="$source_id"
  THEME_REPO_SOURCE_PATH="$source_path"
  THEME_REPO_SOURCE_URL="$repo_url"
  theme_repo_discover "$source_path" || return 1
  theme_repo_migrate_state "$source_path"
  theme_repo_installed_names "$source_path"
}

theme_repo_load_source() {
  local source_id="$1"
  local source_path source_url

  if ! theme_repo_valid_source_id "$source_id"; then
    theme_repo_error "Invalid theme source ID: $source_id"
    return 1
  fi

  source_path="$THEME_REPO_SOURCES_DIR/$source_id"
  if [[ ! -d $source_path/.git ]]; then
    theme_repo_error "Theme source not found: $source_id"
    return 1
  fi

  source_url=$(git -C "$source_path" config --get remote.origin.url 2>/dev/null || true)
  if [[ -z $source_url ]]; then
    theme_repo_error "Theme source has no origin URL: $source_id"
    return 1
  fi

  THEME_REPO_SOURCE_ID="$source_id"
  THEME_REPO_SOURCE_PATH="$source_path"
  THEME_REPO_SOURCE_URL="$source_url"
  theme_repo_discover "$source_path" || return 1
  theme_repo_migrate_state "$source_path"
  theme_repo_sync_source "$source_path" || return 1
  theme_repo_installed_names "$source_path"
}

theme_repo_install_selection() {
  local source_path="$1"
  local selection="$2"
  local installed_dir name marker
  local names_to_install=()
  local new_markers=()

  installed_dir=$(theme_repo_installed_dir "$source_path")
  mkdir -p "$installed_dir"
  if [[ $selection == "all" || $selection == "--all" ]]; then
    names_to_install=("${THEME_REPO_NAMES[@]}")
  else
    selection=$(theme_repo_slugify "$selection")
    if [[ -z $selection ]] || ! theme_repo_name_exists "$selection"; then
      theme_repo_error "Theme '$selection' is not provided by this repository."
      return 1
    fi
    names_to_install+=("$selection")
  fi

  theme_repo_preflight_names "$source_path" "${names_to_install[@]}" || return 1
  for name in "${names_to_install[@]}"; do
    marker="$installed_dir/$name"
    if [[ ! -f $marker ]]; then
      touch "$marker"
      new_markers+=("$marker")
    fi
  done

  if ! theme_repo_sync_source "$source_path"; then
    for marker in "${new_markers[@]}"; do
      rm -f "$marker"
    done
    theme_repo_sync_source "$source_path" || true
    return 1
  fi

  theme_repo_installed_names "$source_path"
}

theme_repo_detach() {
  local source_path="$1"
  local theme_name="$2"
  local theme_path installed_dir

  theme_name=$(theme_repo_slugify "$theme_name")
  installed_dir=$(theme_repo_installed_dir "$source_path")
  theme_path="$THEME_REPO_THEMES_DIR/$theme_name"
  if [[ ! -f $installed_dir/$theme_name ]]; then
    theme_repo_error "Theme '$theme_name' is not installed from source '$(basename "$source_path")'."
    return 1
  fi

  if [[ -L $theme_path ]]; then
    if ! theme_repo_link_owned_by_source "$theme_path" "$source_path"; then
      theme_repo_error "Theme '$theme_name' is no longer owned by its recorded source."
      return 1
    fi
    rm "$theme_path"
  elif [[ -e $theme_path ]]; then
    theme_repo_error "Theme '$theme_name' is no longer owned by its recorded source."
    return 1
  fi

  rm "$installed_dir/$theme_name"
  printf '%s\n' "$theme_name"
}

theme_repo_find_preview() {
  local theme_path="$1"
  local preview_name preview
  local previews=()

  for preview_name in preview.png preview.jpg preview.jpeg preview.webp preview.gif preview.bmp; do
    if [[ -f $theme_path/$preview_name ]]; then
      printf '%s\n' "$theme_path/$preview_name"
      return
    fi
  done

  if [[ -d $theme_path/backgrounds ]]; then
    mapfile -t previews < <(find -P "$theme_path/backgrounds" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) -print | sort)
    preview="${previews[0]:-}"
    [[ -n $preview ]] && printf '%s\n' "$preview"
  fi

  return 0
}

theme_repo_wallpapers_json() {
  local theme_path="$1"
  local wallpaper count=0

  if [[ ! -d $theme_path/backgrounds ]]; then
    printf '[]\n'
    return
  fi

  while IFS= read -r -d '' wallpaper; do
    (( count += 1 ))
    if (( count > THEME_REPO_MAX_WALLPAPERS )); then
      break
    fi
    jq -cn --arg path "$wallpaper" '$path'
  done < <(find -P "$theme_path/backgrounds" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) -print0 | sort -z) | jq -cs '.'
}

theme_repo_shell_surface_count() {
  local theme_path="$1"
  local shell_file count=0

  while IFS= read -r -d '' shell_file; do
    (( count += 1 ))
    if (( count >= THEME_REPO_MAX_SHELL_SURFACES )); then
      break
    fi
  done < <(find -P "$theme_path" -maxdepth 1 -type f \( -name 'shell.toml' -o -name 'shell.*.toml' \) -print0)

  printf '%d\n' "$count"
}

theme_repo_color() {
  local colors_file="$1"
  local key="$2"
  local value

  [[ -f $colors_file ]] || return 0
  value=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"[:space:]]+).*/\1/p" "$colors_file" | sed -n '1p')
  (( ${#value} <= THEME_REPO_MAX_COLOR_CHARS )) || return 0
  printf '%s\n' "$value"
}

theme_repo_title() {
  sed -E 's/(^|-)([a-z])/\1\u\2/g; s/-/ /g' <<<"$1"
}

theme_repo_emit_json() {
  local source_path="$1"
  local source_id source_url commit index name relative_path theme_path preview destination installed conflict status colors_file
  local wallpapers_json wallpaper_count unlock icons keyboard shell shell_surface_count

  source_id=$(basename "$source_path")
  source_url=$(git -C "$source_path" config --get remote.origin.url 2>/dev/null || true)
  commit=$(git -C "$source_path" rev-parse HEAD 2>/dev/null || true)
  theme_repo_discover "$source_path" || return 1
  theme_repo_migrate_state "$source_path"

  {
    for index in "${!THEME_REPO_NAMES[@]}"; do
      name="${THEME_REPO_NAMES[$index]}"
      relative_path="${THEME_REPO_RELATIVE_PATHS[$index]}"
      theme_path=$(theme_repo_target "$source_path" "$name")
      preview=$(theme_repo_find_preview "$theme_path")
      destination="$THEME_REPO_THEMES_DIR/$name"
      installed=false
      conflict=false
      status="available"
      if theme_repo_theme_installed "$source_path" "$name"; then
        installed=true
        status="installed"
      elif [[ -e $destination || -L $destination ]]; then
        conflict=true
        status="conflict"
      fi
      colors_file="$theme_path/colors.toml"
      wallpapers_json=$(theme_repo_wallpapers_json "$theme_path")
      wallpaper_count=$(jq -r 'length' <<<"$wallpapers_json")
      unlock=false
      icons=false
      keyboard=false
      shell=false
      [[ -f $theme_path/unlock.png && -f $theme_path/preview-unlock.png ]] && unlock=true
      [[ -f $theme_path/icons.theme ]] && icons=true
      [[ -f $theme_path/keyboard.rgb ]] && keyboard=true
      shell_surface_count=$(theme_repo_shell_surface_count "$theme_path")
      (( shell_surface_count > 0 )) && shell=true

      jq -cn \
        --arg slug "$name" \
        --arg name "$(theme_repo_title "$name")" \
        --arg relativePath "$relative_path" \
        --arg path "$theme_path" \
        --arg preview "$preview" \
        --arg status "$status" \
        --arg mode "$(theme_repo_color "$colors_file" mode)" \
        --arg accent "$(theme_repo_color "$colors_file" accent)" \
        --arg background "$(theme_repo_color "$colors_file" background)" \
        --arg foreground "$(theme_repo_color "$colors_file" foreground)" \
        --arg red "$(theme_repo_color "$colors_file" red)" \
        --arg yellow "$(theme_repo_color "$colors_file" yellow)" \
        --arg green "$(theme_repo_color "$colors_file" green)" \
        --arg cyan "$(theme_repo_color "$colors_file" cyan)" \
        --arg blue "$(theme_repo_color "$colors_file" blue)" \
        --arg magenta "$(theme_repo_color "$colors_file" magenta)" \
        --argjson wallpapers "$wallpapers_json" \
        --argjson wallpaperCount "$wallpaper_count" \
        --argjson unlock "$unlock" \
        --argjson icons "$icons" \
        --argjson keyboard "$keyboard" \
        --argjson shell "$shell" \
        --argjson shellSurfaceCount "$shell_surface_count" \
        --argjson installed "$installed" \
        --argjson conflict "$conflict" \
        '{slug: $slug, name: $name, relativePath: $relativePath, path: $path, preview: $preview, wallpapers: $wallpapers, status: $status, installed: $installed, conflict: $conflict, mode: $mode, capabilities: {wallpaperCount: $wallpaperCount, unlock: $unlock, icons: $icons, keyboard: $keyboard, shell: $shell, shellSurfaceCount: $shellSurfaceCount}, colors: {accent: $accent, background: $background, foreground: $foreground, red: $red, yellow: $yellow, green: $green, cyan: $cyan, blue: $blue, magenta: $magenta}}'
    done
  } | jq -cs \
    --arg id "$source_id" \
    --arg url "$source_url" \
    --arg path "$source_path" \
    --arg commit "$commit" \
    '{schemaVersion: 1, source: {id: $id, url: $url, path: $path, commit: $commit}, themes: .}'
}
