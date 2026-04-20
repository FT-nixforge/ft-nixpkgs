#!/usr/bin/env bash
# tui.sh — arrow-key TUI helpers for ft-nixpkgs scripts
#
# Source this file:  . "$(dirname "${BASH_SOURCE[0]}")/tui.sh"
# Requires bash ≥ 4.3 for local -n namerefs.
# All UI output → /dev/tty; key input ← /dev/tty.
# Falls back to plain prompts when stdin is not a terminal.

_tui_read_key() {
  local _k1 _k2 _k3
  IFS= read -r -s -n1 _k1 </dev/tty
  KEY="$_k1"
  if [[ "$_k1" == $'\033' ]]; then
    IFS= read -r -s -n1 -t 0.1 _k2 </dev/tty || true
    IFS= read -r -s -n1 -t 0.1 _k3 </dev/tty || true
    case "${_k2}${_k3}" in
      '[A') KEY="UP"    ;;
      '[B') KEY="DOWN"  ;;
      '[C') KEY="RIGHT" ;;
      '[D') KEY="LEFT"  ;;
      *)    KEY=$'\033'  ;;
    esac
  fi
}

_tui_has_tty() { [[ -t 0 && -t 1 ]]; }

# select_one "Title" result_varname  item1 item2 ...
select_one() {
  local _title="$1"
  local -n _result_one="$2"
  shift 2
  local -a _items=("$@")
  local _n=${#_items[@]}

  if ! _tui_has_tty; then
    echo "? $_title — choose one:" >/dev/tty
    local _i=0
    for _item in "${_items[@]}"; do
      printf '  %d) %s\n' "$(( _i + 1 ))" "$_item" >/dev/tty
      _i=$(( _i + 1 ))
    done
    printf 'Enter number [1]: ' >/dev/tty
    local _choice
    read -r _choice
    _choice="${_choice:-1}"
    _result_one="${_items[$(( _choice - 1 ))]}"
    return
  fi

  local _idx=0
  local KEY

  printf '\n' >/dev/tty
  tput civis >/dev/tty

  while true; do
    printf '\033[1m%s\033[0m\n' "$_title" >/dev/tty
    local _i=0
    for _item in "${_items[@]}"; do
      if [[ $_i -eq $_idx ]]; then
        printf '\033[32m  ❯ %s\033[0m\n' "$_item" >/dev/tty
      else
        printf '\033[2m    %s\033[0m\n' "$_item" >/dev/tty
      fi
      _i=$(( _i + 1 ))
    done

    _tui_read_key
    printf '\033[%dA\033[J' "$(( _n + 1 ))" >/dev/tty

    case "$KEY" in
      UP)
        [[ $_idx -gt 0 ]] && _idx=$(( _idx - 1 ))
        ;;
      DOWN)
        [[ $_idx -lt $(( _n - 1 )) ]] && _idx=$(( _idx + 1 ))
        ;;
      $'\n'|'')
        printf '\033[32m  ✓ %s: %s\033[0m\n' "$_title" "${_items[$_idx]}" >/dev/tty
        tput cnorm >/dev/tty
        _result_one="${_items[$_idx]}"
        return
        ;;
    esac
  done
}

# select_many "Title" result_arrayname  item1 item2 ...
select_many() {
  local _title="$1"
  local -n _result_many="$2"
  shift 2
  local -a _items=("$@")
  local _n=${#_items[@]}

  if ! _tui_has_tty; then
    echo "? $_title — space-separated selection (options: ${_items[*]}):" >/dev/tty
    local _input
    read -r _input
    read -ra _result_many <<< "$_input"
    return
  fi

  local _idx=0
  local -a _sel=()
  local _i=0
  for _item in "${_items[@]}"; do
    _sel+=( 0 )
    _i=$(( _i + 1 ))
  done
  local KEY

  printf '\n' >/dev/tty
  tput civis >/dev/tty

  while true; do
    printf '\033[1m%s\033[0m \033[2m(↑↓ navigate  Space toggle  Enter confirm)\033[0m\n' "$_title" >/dev/tty
    local _i=0
    for _item in "${_items[@]}"; do
      local _check
      if [[ ${_sel[$_i]} -eq 1 ]]; then
        _check='\033[32m[✓]\033[0m'
      else
        _check='\033[2m[ ]\033[0m'
      fi
      if [[ $_i -eq $_idx ]]; then
        printf "  \033[32m❯\033[0m ${_check} %s\n" "$_item" >/dev/tty
      else
        printf "    ${_check} \033[2m%s\033[0m\n" "$_item" >/dev/tty
      fi
      _i=$(( _i + 1 ))
    done

    _tui_read_key
    printf '\033[%dA\033[J' "$(( _n + 1 ))" >/dev/tty

    case "$KEY" in
      UP)
        [[ $_idx -gt 0 ]] && _idx=$(( _idx - 1 ))
        ;;
      DOWN)
        [[ $_idx -lt $(( _n - 1 )) ]] && _idx=$(( _idx + 1 ))
        ;;
      ' ')
        if [[ ${_sel[$_idx]} -eq 1 ]]; then
          _sel[$_idx]=0
        else
          _sel[$_idx]=1
        fi
        ;;
      $'\n'|'')
        _result_many=()
        local _i=0
        for _item in "${_items[@]}"; do
          [[ ${_sel[$_i]} -eq 1 ]] && _result_many+=("$_item")
          _i=$(( _i + 1 ))
        done
        local _summary="${_result_many[*]+"${_result_many[*]}"}"
        printf '\033[32m  ✓ %s: %s\033[0m\n' "$_title" "${_summary:-(none)}" >/dev/tty
        tput cnorm >/dev/tty
        return
        ;;
    esac
  done
}

# select_search "Title" result_arrayname  item1 item2 ...
select_search() {
  local _title="$1"
  local -n _result_search="$2"
  shift 2
  local -a _items=("$@")
  local _total=${#_items[@]}

  if ! _tui_has_tty; then
    echo "? $_title — space-separated selection (options: ${_items[*]}):" >/dev/tty
    local _input
    read -r _input
    read -ra _result_search <<< "$_input"
    return
  fi

  local _query=""
  local _idx=0
  local -a _sel=()
  local _i=0
  for _item in "${_items[@]}"; do
    _sel+=( 0 )
    _i=$(( _i + 1 ))
  done
  local _prev_lines=2
  local KEY

  printf '\n' >/dev/tty
  tput civis >/dev/tty

  while true; do
    # Build filtered list
    local -a _filtered=()
    local -a _fmap=()
    local _i=0
    for _item in "${_items[@]}"; do
      local _lower="${_item,,}"
      local _qlower="${_query,,}"
      if [[ -z "$_query" || "$_lower" == *"$_qlower"* ]]; then
        _filtered+=("$_item")
        _fmap+=("$_i")
      fi
      _i=$(( _i + 1 ))
    done
    local _fn=${#_filtered[@]}

    # Clamp _idx
    if [[ $_fn -eq 0 ]]; then
      _idx=0
    elif [[ $_idx -ge $_fn ]]; then
      _idx=$(( _fn - 1 ))
    fi

    # Erase previous drawing
    if [[ $_prev_lines -gt 0 ]]; then
      printf '\033[%dA\033[J' "$_prev_lines" >/dev/tty
    fi

    # Draw header
    printf '\033[1m%s\033[0m \033[2m(↑↓ navigate  Space toggle  Enter confirm)\033[0m\n' "$_title" >/dev/tty
    printf '/%s_\n' "$_query" >/dev/tty

    # Draw filtered items
    local _fi=0
    for _item in "${_filtered[@]}"; do
      local _orig_i="${_fmap[$_fi]}"
      local _check
      if [[ ${_sel[$_orig_i]} -eq 1 ]]; then
        _check='\033[32m[✓]\033[0m'
      else
        _check='\033[2m[ ]\033[0m'
      fi
      if [[ $_fi -eq $_idx ]]; then
        printf "  \033[32m❯\033[0m ${_check} %s\n" "$_item" >/dev/tty
      else
        printf "    ${_check} \033[2m%s\033[0m\n" "$_item" >/dev/tty
      fi
      _fi=$(( _fi + 1 ))
    done

    _prev_lines=$(( _fn + 2 ))

    _tui_read_key

    case "$KEY" in
      UP)
        [[ $_idx -gt 0 ]] && _idx=$(( _idx - 1 ))
        ;;
      DOWN)
        [[ $_idx -lt $(( _fn - 1 )) ]] && _idx=$(( _idx + 1 ))
        ;;
      ' ')
        if [[ $_fn -gt 0 ]]; then
          local _orig_i="${_fmap[$_idx]}"
          if [[ ${_sel[$_orig_i]} -eq 1 ]]; then
            _sel[$_orig_i]=0
          else
            _sel[$_orig_i]=1
          fi
        fi
        ;;
      $'\177'|$'\b')
        if [[ ${#_query} -gt 0 ]]; then
          _query="${_query%?}"
        fi
        _idx=0
        ;;
      $'\n'|'')
        # Erase
        printf '\033[%dA\033[J' "$_prev_lines" >/dev/tty
        _result_search=()
        local _i=0
        for _item in "${_items[@]}"; do
          [[ ${_sel[$_i]} -eq 1 ]] && _result_search+=("$_item")
          _i=$(( _i + 1 ))
        done
        local _summary="${_result_search[*]+"${_result_search[*]}"}"
        printf '\033[32m  ✓ %s: %s\033[0m\n' "$_title" "${_summary:-(none)}" >/dev/tty
        tput cnorm >/dev/tty
        return
        ;;
      *)
        # Printable character — append to query
        if [[ ${#KEY} -eq 1 && "$KEY" != $'\033' ]]; then
          _query="${_query}${KEY}"
          _idx=0
        fi
        ;;
    esac
  done
}
