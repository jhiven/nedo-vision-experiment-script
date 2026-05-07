#!/usr/bin/env bash
# =============================================================================
# run_benchmark_others.sh — E1, E2, E3, E4, B1, B2, B3
# Target instance : L40S (or any CUDA instance)
# Estimated time  : ~2 hours
#
# Run AFTER setup.sh completes successfully.
#
# Usage:
#   bash run_benchmark_others.sh
#
# Optional env overrides:
#   RTMP_SERVER      — required for B2 (live config-swap benchmark)
#   B2_PIPELINE_ID   — required for B2
#   B3_VIDEO_PATH    — optional static video path for B3
#   SKIP_B2          — set to "1" to skip B2 explicitly
#   RUN_TAG          — label appended to output dir
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

CORE_DIR="$HOME/nedovision/nedo-vision-worker-core-v2"
SESSION="nedovision-benchmark"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M)}"
OUTPUT_DIR="benchmark_output/others_${RUN_TAG}"

DEVICE="cuda"
WARMUP=50     # minimum for cuda
SOURCE="dummy"

# Duration per experiment (seconds)
# 5 min per complexity level / tier is a safe baseline
# E1: 3 levels × 2 pipelines × 300s = ~30 min
# E2: 3 N-values × 300s             = ~15 min
# E3: 3 levels × 300s               = ~15 min
# E4: 4 tiers × 2 pipelines × 300s  = ~40 min
# B1/B3: driven by --trials/--frames
DURATION=300

B1_TRIALS=30
B2_TRIALS=20
B3_FRAMES=100

# ─── Optional args ────────────────────────────────────────────────────────────
RTMP_ARG=""
B2_PIPELINE_ARG=""
B3_VIDEO_ARG=""

if [[ -n "${RTMP_SERVER:-}" ]]; then
    RTMP_ARG="--rtmp-server ${RTMP_SERVER}"
fi
if [[ -n "${B2_PIPELINE_ID:-}" ]]; then
    B2_PIPELINE_ARG="--b2-pipeline-id ${B2_PIPELINE_ID}"
fi
if [[ -n "${B3_VIDEO_PATH:-}" ]]; then
    B3_VIDEO_ARG="--b3-video-path ${B3_VIDEO_PATH}"
fi

# ─── Determine BYOM set ───────────────────────────────────────────────────────
BYOM_EXPS="b1 b3"
if [[ "${SKIP_B2:-0}" == "1" ]]; then
    warn "SKIP_B2=1 — skipping B2."
elif [[ -z "${RTMP_SERVER:-}" ]] || [[ -z "${B2_PIPELINE_ID:-}" ]]; then
    warn "RTMP_SERVER or B2_PIPELINE_ID not set — skipping B2."
    warn "Set both to include B2 in the run."
else
    BYOM_EXPS="b1 b2 b3"
fi

# ─── Pre-flight ───────────────────────────────────────────────────────────────
[[ -d "$CORE_DIR" ]] || die "worker-core not found at $CORE_DIR. Run setup.sh first."
cd "$CORE_DIR"
[[ -d ".venv" ]]     || die ".venv not found. Run setup.sh first."
source .venv/bin/activate

python - <<'PYCHECK'
import torch, sys
if not torch.cuda.is_available():
    print("ERROR: CUDA not available.")
    sys.exit(1)
print(f"CUDA OK — {torch.cuda.get_device_name(0)}")
PYCHECK

mkdir -p "$OUTPUT_DIR"
success "Pre-flight passed."

# ─── Commands ─────────────────────────────────────────────────────────────────
CORE_CMD="cd $CORE_DIR && source .venv/bin/activate && \
CORE_STORAGE_PATH=\"../data\" \
python -m benchmark \
  --experiment e1 e2 e3 e4 \
  --device $DEVICE \
  --source $SOURCE \
  --duration $DURATION \
  --warmup $WARMUP \
  --no-speed \
  --markdown \
  --pdf-charts \
  --storage-path \"../data\" \
  --output-dir $OUTPUT_DIR \
  2>&1 | tee ${OUTPUT_DIR}/core_run.log"

BYOM_CMD="cd $CORE_DIR && source .venv/bin/activate && \
CORE_STORAGE_PATH=\"../data\" \
python -m benchmark \
  --experiment $BYOM_EXPS \
  --device $DEVICE \
  --source $SOURCE \
  --warmup $WARMUP \
  --no-speed \
  --markdown \
  --pdf-charts \
  --storage-path \"../data\" \
  --b1-trials $B1_TRIALS \
  --b2-trials $B2_TRIALS \
  --b3-frames $B3_FRAMES \
  --output-dir $OUTPUT_DIR \
  $RTMP_ARG \
  $B2_PIPELINE_ARG \
  $B3_VIDEO_ARG \
  2>&1 | tee ${OUTPUT_DIR}/byom_run.log"

# ─── Launch tmux ──────────────────────────────────────────────────────────────
info "Starting tmux session: $SESSION"
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n "core-exps" -x 220 -y 50

# Window 1: E1 E2 E3 E4 — starts immediately
tmux send-keys -t "$SESSION:core-exps" "$CORE_CMD" Enter

# Window 2: B1 B2/B3 — pre-loaded but NOT sent Enter
# Run manually after window 1 finishes and you confirm no errors
tmux new-window -t "$SESSION" -n "byom-exps"
tmux send-keys -t "$SESSION:byom-exps" \
    "# Wait for core-exps (window 1) to finish, then press Enter here"
tmux send-keys -t "$SESSION:byom-exps" ""
# Load the command into the buffer without executing
tmux send-keys -t "$SESSION:byom-exps" "" Enter
tmux send-keys -t "$SESSION:byom-exps" "$BYOM_CMD"
# Command is typed and waiting — user presses Enter to start

# Window 3: GPU + disk monitor
tmux new-window -t "$SESSION" -n "monitor"
tmux send-keys -t "$SESSION:monitor" \
    "watch -n3 'nvidia-smi && echo && df -h $CORE_DIR'" Enter

echo ""
echo -e "${BOLD}Benchmark session started: $SESSION${NC}"
echo -e "${BOLD}Output dir :${NC} $CORE_DIR/$OUTPUT_DIR"
echo ""
echo -e "${BOLD}Windows:${NC}"
echo -e "  ${CYAN}1. core-exps${NC}  — E1 E2 E3 E4 (running now)"
echo -e "  ${CYAN}2. byom-exps${NC}  — $(echo "$BYOM_EXPS" | tr ' ' '/') (press Enter after core-exps done)"
echo -e "  ${CYAN}3. monitor${NC}    — nvidia-smi + disk usage"
echo ""
echo -e "Attach : ${CYAN}tmux attach -t $SESSION${NC}"
echo -e "Detach : ${CYAN}Ctrl+B then D${NC}"
echo ""
echo -e "${YELLOW}B2 included: $(echo "$BYOM_EXPS" | grep -q b2 && echo YES — needs RTSP + pipeline-id || echo NO — set RTMP_SERVER + B2_PIPELINE_ID to enable)${NC}"