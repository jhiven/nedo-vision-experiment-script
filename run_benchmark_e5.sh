#!/usr/bin/env bash
# =============================================================================
# run_benchmark_e5.sh — E5 Long-Run Stability Benchmark
# Target instance : RTX 3090 (on-demand, 24 GB VRAM)
# Duration        : 24 hours total — 12h hardcoded first, then 12h DAG
#
# Run AFTER setup.sh completes successfully.
#
# Usage:
#   bash run_benchmark_e5.sh
#
# Optional env overrides:
#   RTMP_SERVER   — set to rtsp://... to use live source instead of dummy
#   RUN_TAG       — label appended to output dir (default: current datetime)
#   SEAWEEDFS_REMOTE — rclone remote name configured by setup.sh (default: seaweedfs_s3)
#   SEAWEEDFS_BUCKET — default: personal
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
OUTPUT_DIR="benchmark_output/e5_${RUN_TAG}"
SEAWEEDFS_REMOTE="${SEAWEEDFS_REMOTE:-seaweedfs_s3}"
SEAWEEDFS_BUCKET="${SEAWEEDFS_BUCKET:-personal}"

# 12 jam per child run (hardcoded runs first, then DAG)
E5_DURATION_SECS=43200

DEVICE="cuda"
WARMUP=100   # cli.py enforces min 50 for cuda; using 100 for safety

SOURCE="dummy"
RTMP_ARG=""
if [[ -n "${RTMP_SERVER:-}" ]]; then
    SOURCE="rtsp"
    RTMP_ARG="--rtmp-server ${RTMP_SERVER}"
    info "Using RTSP source: $RTMP_SERVER"
else
    info "No RTMP_SERVER set — using dummy frame source."
fi

# ─── Pre-flight ───────────────────────────────────────────────────────────────
[[ -d "$CORE_DIR" ]] || die "worker-core not found at $CORE_DIR. Run setup.sh first."
cd "$CORE_DIR"
[[ -d ".venv" ]]     || die ".venv not found. Run setup.sh first."
source .venv/bin/activate

python - <<'PYCHECK'
import torch, sys
if not torch.cuda.is_available():
    print("ERROR: CUDA not available. Is this the right instance?")
    sys.exit(1)
print(f"CUDA OK — {torch.cuda.get_device_name(0)}")
PYCHECK

mkdir -p "$OUTPUT_DIR"
success "Pre-flight passed."

# ─── Build command ────────────────────────────────────────────────────────────
BACKUP_CMD="echo '' \
  && echo '>>> Backup to ${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG} starting...' \
  && if command -v rclone >/dev/null 2>&1 && rclone lsd \"${SEAWEEDFS_REMOTE}:\" >/dev/null 2>&1; then \
       rclone mkdir \"${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}\" 2>/dev/null || true; \
       rclone sync \"$CORE_DIR/$OUTPUT_DIR\" \"${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}\" --log-file /tmp/rclone_sync.log; \
       echo '=== BACKUP DONE ==='; \
     else \
       echo '[WARN] rclone or SeaweedFS remote unavailable; backup skipped.'; \
     fi"

BENCH_CMD="cd $CORE_DIR && source .venv/bin/activate && set -o pipefail && \
CORE_STORAGE_PATH=\"../data\" \
python -m benchmark \
  --experiment e5 \
  --device $DEVICE \
  --source $SOURCE \
  --duration $E5_DURATION_SECS \
  --warmup $WARMUP \
  --no-speed \
  --markdown \
  --pdf-charts \
  --storage-path \"../data\" \
  --output-dir $OUTPUT_DIR \
  $RTMP_ARG \
  2>&1 | tee ${OUTPUT_DIR}/e5_run.log \
  && echo '' \
  && echo '=== E5 EXPERIMENT DONE ===' \
  && ${BACKUP_CMD}"

# ─── Launch tmux ──────────────────────────────────────────────────────────────
info "Starting tmux session: $SESSION"
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n "e5-stability" -x 220 -y 50
tmux send-keys -t "$SESSION:e5-stability" "$BENCH_CMD" Enter

# Monitor window
tmux new-window -t "$SESSION" -n "monitor"
tmux send-keys -t "$SESSION:monitor" \
    "watch -n5 'nvidia-smi && echo && df -h $CORE_DIR && echo && tail -5 /tmp/rclone_sync.log 2>/dev/null'" Enter

echo ""
echo -e "${BOLD}E5 stability benchmark started.${NC}"
echo -e "${BOLD}Output dir :${NC} $CORE_DIR/$OUTPUT_DIR"
echo -e "${BOLD}Duration   :${NC} ~24h total (hardcoded first, then DAG — each 12h)"
echo -e "${BOLD}Backup     :${NC} ${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}"
echo ""
echo -e "Attach : ${CYAN}tmux attach -t $SESSION${NC}"
echo -e "Detach : ${CYAN}Ctrl+B then D${NC}"
echo ""
echo -e "${YELLOW}WARNING: Use on-demand instance only. Do NOT terminate early.${NC}"
echo -e "${YELLOW}E5 runs both child processes sequentially — interruption loses all data.${NC}"
