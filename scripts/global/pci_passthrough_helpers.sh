#!/usr/bin/env bash

if [[ -n "${__PROXMENUX_PCI_PASSTHROUGH_HELPERS__}" ]]; then
  return 0
fi
__PROXMENUX_PCI_PASSTHROUGH_HELPERS__=1

function _pci_is_iommu_active() {
  grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null || return 1
  [[ -d /sys/kernel/iommu_groups ]] || return 1
  find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .
}

function _pci_next_hostpci_index() {
  local vmid="$1"
  local idx=0
  local hostpci_existing

  hostpci_existing=$(qm config "$vmid" 2>/dev/null) || return 1
  while grep -q "^hostpci${idx}:" <<< "$hostpci_existing"; do
    idx=$((idx + 1))
  done
  echo "$idx"
}

function _pci_slot_assigned_to_vm() {
  local pci_full="$1"
  local vmid="$2"
  local slot_base
  slot_base="${pci_full#0000:}"
  slot_base="${slot_base%.*}"

  qm config "$vmid" 2>/dev/null \
    | grep -qE "^hostpci[0-9]+:.*(0000:)?${slot_base}(\\.[0-7])?([,[:space:]]|$)"
}

function _pci_function_assigned_to_vm() {
  local pci_full="$1"
  local vmid="$2"
  local bdf slot func pattern
  bdf="${pci_full#0000:}"
  slot="${bdf%.*}"
  func="${bdf##*.}"

  if [[ "$func" == "0" ]]; then
    pattern="^hostpci[0-9]+:.*(0000:)?(${bdf}|${slot})([,:[:space:]]|$)"
  else
    pattern="^hostpci[0-9]+:.*(0000:)?${bdf}([,[:space:]]|$)"
  fi

  qm config "$vmid" 2>/dev/null | grep -qE "$pattern"
}

# ==========================================================
# SR-IOV detection helpers
# ==========================================================
# A PCI device participates in SR-IOV when either:
#   - It is a Physical Function (PF) with one or more active VFs
#     → /sys/bus/pci/devices/<BDF>/sriov_numvfs > 0
#   - It is a Virtual Function (VF) spawned by a PF
#     → /sys/bus/pci/devices/<BDF>/physfn is a symlink to the PF
#
# These helpers accept a BDF in either "0000:00:02.0" or "00:02.0" form.
# Return 0 on match, non-zero otherwise (shell convention).

function _pci_normalize_bdf() {
  local id="$1"
  [[ -z "$id" ]] && return 1
  [[ "$id" =~ ^0000: ]] || id="0000:${id}"
  printf '%s\n' "$id"
}

function _pci_is_vf() {
  local id
  id=$(_pci_normalize_bdf "$1") || return 1
  [[ -L "/sys/bus/pci/devices/${id}/physfn" ]]
}

function _pci_get_pf_of_vf() {
  local id
  id=$(_pci_normalize_bdf "$1") || return 1
  local link="/sys/bus/pci/devices/${id}/physfn"
  [[ -L "$link" ]] || return 1
  basename "$(readlink -f "$link")"
}

function _pci_is_sriov_capable() {
  local id total
  id=$(_pci_normalize_bdf "$1") || return 1
  total=$(cat "/sys/bus/pci/devices/${id}/sriov_totalvfs" 2>/dev/null)
  [[ -n "$total" && "$total" -gt 0 ]]
}

function _pci_active_vf_count() {
  local id num
  id=$(_pci_normalize_bdf "$1") || { echo 0; return 1; }
  num=$(cat "/sys/bus/pci/devices/${id}/sriov_numvfs" 2>/dev/null)
  [[ -n "$num" ]] || num=0
  echo "$num"
}

function _pci_has_active_vfs() {
  local n
  n=$(_pci_active_vf_count "$1")
  [[ "$n" -gt 0 ]]
}

# Filter an array (by name) of PCI BDFs in place, removing entries that
# are SR-IOV Virtual Functions or Physical Functions with active VFs —
# i.e. the configurations ProxMenux refuses to operate on today.
#
# Usage:  _pci_sriov_filter_array <array_name_by_ref>
# Output: one line per removed entry, formatted "BDF|role" where role is
# whatever _pci_sriov_role prints (e.g. "vf 0000:00:02.0" or
# "pf-active 7"). The caller decides how to surface the removals.
# Returns: 0 if the caller should continue (even if some entries were
# filtered); the array mutation happens either way.
function _pci_sriov_filter_array() {
  local -n _arr_ref="$1"
  local -a _kept=()
  local bdf role first
  for bdf in "${_arr_ref[@]}"; do
    role=$(_pci_sriov_role "$bdf" 2>/dev/null)
    first="${role%% *}"
    if [[ "$first" == "vf" || "$first" == "pf-active" ]]; then
      echo "${bdf}|${role}"
    else
      _kept+=("$bdf")
    fi
  done
  _arr_ref=("${_kept[@]}")
}

# Emits a one-line SR-IOV role description for diagnostics/messages.
# Prints one of:
#   "pf-active <N>"      — PF with N>0 active VFs
#   "pf-idle"            — SR-IOV capable PF with 0 VFs (benign)
#   "vf <PF-BDF>"        — VF (names its parent PF)
#   "none"               — device not involved in SR-IOV
function _pci_sriov_role() {
  local id
  id=$(_pci_normalize_bdf "$1") || { echo "none"; return 0; }
  if _pci_is_vf "$id"; then
    echo "vf $(_pci_get_pf_of_vf "$id")"
    return 0
  fi
  if _pci_is_sriov_capable "$id"; then
    local n
    n=$(_pci_active_vf_count "$id")
    if [[ "$n" -gt 0 ]]; then
      echo "pf-active ${n}"
    else
      echo "pf-idle"
    fi
    return 0
  fi
  echo "none"
}
