#!/usr/bin/env bash
# launch-gate.sh
# Automate ~70% of LAUNCH GATE checks (non-destructive).
# Exit code: 0 = PASS (automated checks), 1 = FAIL
#
# Requirements on your local machine:
# - ssh access to nodes (key-based)
# - jq installed locally
#
# What this script DOES:
# - Verifies node reachability + bathron-cli works
# - Checks all nodes are on same chain tip (±1)
# - Checks recent block production (delta over a short window)
# - Checks SPV is enabled and "not stale" (best-effort via getbtcsyncstatus)
# - Runs reloadbtcspv and verifies it responds
# - Checks burnclaimpending is OFF (best-effort via getnetworkinfo args if exposed)
#
# What this script DOES NOT do (manual):
# - Inject header poison (Commit 2 adversarial)
# - End-to-end burn/claim/mint
# - Reorg tests

set -euo pipefail

############################
# CONFIG (edit these)
############################
SSH_USER="${SSH_USER:-ubuntu}"
# Space-separated list of producers (and optionally seed) to check
if [[ -z "${NODES:-}" ]]; then
  NODES=("57.131.33.151" "57.131.33.152" "57.131.33.214" "51.75.31.44" "162.19.251.75")
else
  read -ra NODES <<< "$NODES"
fi
# If you want a designated "seed" node for SPV comparison, set SEED_IP to one of NODES
SEED_IP="${SEED_IP:-57.131.33.151}"

# CLI command on remote
CLI="${CLI:-\$HOME/bathron-cli}"
# Network flag on remote (e.g., -testnet, -testnet5, etc.)
NET_FLAG="${NET_FLAG:--testnet}"

# Time window for block production check
PRODUCTION_WINDOW_SECONDS="${PRODUCTION_WINDOW_SECONDS:-45}"
# Acceptable tip height skew among nodes (±1 recommended)
MAX_TIP_SKEW="${MAX_TIP_SKEW:-1}"

# SPV freshness thresholds (best-effort; depends on what getbtcsyncstatus returns)
# Height delta threshold (ex: 100)
SPV_STALE_HEIGHT_DELTA="${SPV_STALE_HEIGHT_DELTA:-100}"
# Time delta threshold seconds (ex: 1800 = 30 min)
SPV_STALE_TIME_DELTA="${SPV_STALE_TIME_DELTA:-1800}"

# If your build has a custom RPC to expose burnclaimpending flag, set it here; otherwise script will skip.
# Example: bathron-cli -testnet getburnclaimpolicy  (just an example)
BURNCLAIM_POLICY_RPC="${BURNCLAIM_POLICY_RPC:-}"

############################
# Helpers
############################
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
BLU='\033[0;34m'
NC='\033[0m'

fail_count=0
warn_count=0

log()  { echo -e "${BLU}[INFO]${NC} $*"; }
pass() { echo -e "${GRN}[PASS]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; ((warn_count+=1)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((fail_count+=1)) || true; }

remote() {
  local ip="$1"; shift
  # shellcheck disable=SC2029
  ssh -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${SSH_USER}@${ip}" "$@"
}

rpc_json() {
  local ip="$1"; shift
  # Execute a bathron-cli RPC that outputs JSON; return raw JSON on stdout
  remote "$ip" "${CLI} ${NET_FLAG} $*"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required on the LOCAL machine. Install jq and re-run." >&2
    exit 2
  fi
}

############################
# Checks
############################
check_reachability_and_cli() {
  log "1) Reachability + bathron-cli basic sanity"
  for ip in "${NODES[@]}"; do
    if remote "$ip" "echo ok" >/dev/null 2>&1; then
      :
    else
      fail "SSH unreachable: $ip"
      continue
    fi

    if remote "$ip" "command -v ${CLI} >/dev/null 2>&1 || test -x ${CLI}" >/dev/null 2>&1; then
      :
    else
      fail "bathron-cli not found/executable on $ip at CLI=${CLI}"
      continue
    fi

    # Cheap RPC
    if rpc_json "$ip" "getblockcount" >/dev/null 2>&1; then
      pass "Node OK: $ip"
    else
      fail "bathron-cli getblockcount failed on $ip"
    fi
  done
}

collect_heights() {
  log "2) Collect BATHRON chain tip heights"
  declare -gA HEIGHTS
  HEIGHTS=()
  for ip in "${NODES[@]}"; do
    local h
    h="$(rpc_json "$ip" "getblockcount" 2>/dev/null || echo "")"
    if [[ "$h" =~ ^[0-9]+$ ]]; then
      HEIGHTS["$ip"]="$h"
      log "  $ip tip_height=$h"
    else
      fail "Cannot read tip height from $ip"
    fi
  done
}

check_tip_skew() {
  log "3) Tip skew among nodes (±${MAX_TIP_SKEW})"
  local min=999999999 max=0
  for ip in "${!HEIGHTS[@]}"; do
    local h="${HEIGHTS[$ip]}"
    (( h < min )) && min="$h"
    (( h > max )) && max="$h"
  done
  local skew=$((max - min))
  if (( skew <= MAX_TIP_SKEW )); then
    pass "Tip skew OK: min=$min max=$max skew=$skew"
  else
    fail "Tip skew too high: min=$min max=$max skew=$skew"
  fi
}

check_block_production_delta() {
  log "4) Block production delta over ${PRODUCTION_WINDOW_SECONDS}s"
  declare -A start end
  for ip in "${NODES[@]}"; do
    start["$ip"]="$(rpc_json "$ip" "getblockcount" 2>/dev/null || echo "")"
  done
  sleep "${PRODUCTION_WINDOW_SECONDS}"
  for ip in "${NODES[@]}"; do
    end["$ip"]="$(rpc_json "$ip" "getblockcount" 2>/dev/null || echo "")"
  done

  # Evaluate: require at least ONE block advanced somewhere; and no node stuck far behind
  local any_advanced=0
  for ip in "${NODES[@]}"; do
    local a="${start[$ip]}" b="${end[$ip]}"
    if [[ ! "$a" =~ ^[0-9]+$ || ! "$b" =~ ^[0-9]+$ ]]; then
      fail "Production check failed (non-numeric heights) on $ip (start=$a end=$b)"
      continue
    fi
    local d=$((b - a))
    log "  $ip Δblocks=$d (from $a to $b)"
    if (( d > 0 )); then
      any_advanced=1
    fi
  done

  if (( any_advanced == 1 )); then
    pass "Blocks are being produced (at least one node advanced)"
  else
    fail "No block production observed in window"
  fi
}

check_spv_status_best_effort() {
  require_jq
  log "5) SPV status best-effort (getbtcsyncstatus)"
  # This assumes getbtcsyncstatus returns JSON with fields like:
  # { "state": "...", "tip_height": N, "tip_time": T, "network_tip_height": M, "network_tip_time": U }
  # If your RPC differs, adapt the jq selectors below.

  # Get seed baseline
  local seed_json
  seed_json="$(rpc_json "$SEED_IP" "getbtcsyncstatus" 2>/dev/null || echo "")"
  if ! echo "$seed_json" | jq . >/dev/null 2>&1; then
    warn "Seed getbtcsyncstatus not JSON or unavailable on $SEED_IP; skipping SPV freshness checks."
    return
  fi

  local seed_tip_h seed_tip_t
  seed_tip_h="$(echo "$seed_json" | jq -r '.tip_height // empty')"
  seed_tip_t="$(echo "$seed_json" | jq -r '.tip_time // empty')"
  if [[ ! "$seed_tip_h" =~ ^[0-9]+$ ]]; then
    warn "Seed tip_height missing; skipping detailed SPV checks."
    return
  fi
  log "  Seed SPV tip_height=$seed_tip_h tip_time=$seed_tip_t"

  for ip in "${NODES[@]}"; do
    local j
    j="$(rpc_json "$ip" "getbtcsyncstatus" 2>/dev/null || echo "")"
    if ! echo "$j" | jq . >/dev/null 2>&1; then
      warn "getbtcsyncstatus not JSON/unavailable on $ip"
      continue
    fi

    local st tip_h tip_t
    st="$(echo "$j" | jq -r '.state // empty')"
    tip_h="$(echo "$j" | jq -r '.tip_height // empty')"
    tip_t="$(echo "$j" | jq -r '.tip_time // empty')"

    if [[ -z "$st" || ! "$tip_h" =~ ^[0-9]+$ ]]; then
      warn "SPV fields missing on $ip (state=$st tip_h=$tip_h)"
      continue
    fi

    # Height gap vs seed
    local gap_h=$((seed_tip_h - tip_h))
    if (( gap_h < 0 )); then gap_h=$(( -gap_h )); fi

    # Time gap vs now (if tip_time is epoch seconds)
    local now epoch_gap=0
    now="$(date +%s)"
    if [[ "$tip_t" =~ ^[0-9]+$ ]]; then
      epoch_gap=$((now - tip_t))
      if (( epoch_gap < 0 )); then epoch_gap=$(( -epoch_gap )); fi
    else
      # If tip_time not numeric, we can't compute time delta
      epoch_gap=0
    fi

    log "  $ip SPV state=$st tip_h=$tip_h (|ΔH vs seed|=$gap_h) tip_time=$tip_t (|ΔT vs now|=${epoch_gap}s)"

    # Expectation for launch gate: not DISABLED, and preferably SYNCED
    if [[ "$st" == "DISABLED" ]]; then
      fail "SPV is DISABLED on $ip"
      continue
    fi

    # If state says STALE/LOADING, that's risky for launch gate
    if [[ "$st" == "STALE" || "$st" == "LOADING" ]]; then
      fail "SPV not ready on $ip (state=$st)"
      continue
    fi

    # Additional freshness sanity if we can compute
    if (( gap_h > SPV_STALE_HEIGHT_DELTA )); then
      fail "SPV height gap too large on $ip (gap_h=$gap_h > ${SPV_STALE_HEIGHT_DELTA})"
      continue
    fi

    if [[ "$tip_t" =~ ^[0-9]+$ ]] && (( epoch_gap > SPV_STALE_TIME_DELTA )); then
      fail "SPV tip too old on $ip (ΔT=${epoch_gap}s > ${SPV_STALE_TIME_DELTA}s)"
      continue
    fi

    pass "SPV OK on $ip"
  done
}

check_reloadbtcspv() {
  require_jq
  log "6) reloadbtcspv on all nodes (non-destructive)"
  for ip in "${NODES[@]}"; do
    local out
    out="$(rpc_json "$ip" "reloadbtcspv" 2>/dev/null || echo "")"
    if echo "$out" | jq . >/dev/null 2>&1; then
      local reloaded tip_h
      reloaded="$(echo "$out" | jq -r '.reloaded // empty')"
      tip_h="$(echo "$out" | jq -r '.tip_height // empty')"
      if [[ "$reloaded" == "true" ]]; then
        pass "$ip reloadbtcspv OK (tip_height=$tip_h)"
      else
        warn "$ip reloadbtcspv returned JSON but no reloaded=true (out=$out)"
      fi
    else
      warn "$ip reloadbtcspv not available or not JSON (out=$out)"
    fi
  done
}

check_burnclaimpending_off_best_effort() {
  log "7) burnclaimpending OFF (best-effort)"
  if [[ -n "$BURNCLAIM_POLICY_RPC" ]]; then
    for ip in "${NODES[@]}"; do
      local out
      out="$(rpc_json "$ip" "$BURNCLAIM_POLICY_RPC" 2>/dev/null || echo "")"
      if [[ -z "$out" ]]; then
        warn "$ip: cannot query burnclaimpending via $BURNCLAIM_POLICY_RPC"
        continue
      fi
      # Expect JSON containing something like {"burnclaimpending":false}
      if echo "$out" | jq . >/dev/null 2>&1; then
        local v
        v="$(echo "$out" | jq -r '.burnclaimpending // empty')"
        if [[ "$v" == "false" ]]; then
          pass "$ip burnclaimpending=false"
        else
          fail "$ip burnclaimpending is not false (value=$v)"
        fi
      else
        warn "$ip: burnclaim policy rpc did not return JSON (out=$out)"
      fi
    done
  else
    warn "No BURNCLAIM_POLICY_RPC configured. Skipping automated check (manual: ensure -burnclaimpending=0)."
  fi
}

print_manual_remaining() {
  echo
  log "MANUAL checks still required before GO GENESIS:"
  echo "  - (Commit 2) Inject header poison + confirm production continues (adversarial)."
  echo "  - (Commit 3) Submit burnclaim with both endian proofs end-to-end on real burn."
  echo "  - (Commit 5) Full SPV sync/distribution rehearsal if you depend on seed-copy."
  echo "  - Reorg test (>=2 blocks) after burnclaim inclusion."
  echo
}

summary_and_exit() {
  echo
  echo "===================="
  echo "LAUNCH-GATE SUMMARY"
  echo "===================="
  if (( fail_count == 0 )); then
    pass "Automated checks PASSED. (warnings=$warn_count)"
    echo "Next: run the manual checks listed above. If those PASS too: GO GENESIS."
    exit 0
  else
    fail "Automated checks FAILED. fails=$fail_count warnings=$warn_count"
    echo "NO-GO until fixed."
    exit 1
  fi
}

############################
# Main
############################
log "Running LAUNCH GATE automated checks"
check_reachability_and_cli
collect_heights
check_tip_skew
check_block_production_delta
check_spv_status_best_effort
check_reloadbtcspv
check_burnclaimpending_off_best_effort
print_manual_remaining
summary_and_exit
