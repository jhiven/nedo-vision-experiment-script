#!/usr/bin/env bash
# =============================================================================
# run_benchmark_others.sh — E1, E2, E3, E4, B1, B2, B3
# Target instance : L40S
# Estimated time  : ~2 hours
#
# Required env vars:
#   B2_PIPELINE_ID   — pipeline ID for B2 config-swap (default: RF-DETR swap pair)
#
# Optional env vars:
#   RUN_TAG         — label appended to output dir (default: current datetime)
#   B3_VIDEO_PATH   — path to video file for B3 (default: ~/nedovision/sample2_100x.mp4)
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

usage() {
        cat <<'USAGE'
Usage: run_benchmark_others.sh [e1 e2 e3 e4 b1 b2 b3]

If no benchmark names are provided, all benchmarks run in sequence.

Options:
    -h, --help   Show this help message
USAGE
}

CORE_DIR="$HOME/nedovision/nedo-vision-worker-core-v2"
SESSION="nedovision-benchmark"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M)}"
OUTPUT_DIR="benchmark_output/others_${RUN_TAG}"
WORKDIR="$HOME/nedovision"
SEAWEEDFS_REMOTE="${SEAWEEDFS_REMOTE:-seaweedfs_s3}"
SEAWEEDFS_BUCKET="${SEAWEEDFS_BUCKET:-personal}"

DEVICE="cuda"
WARMUP=50
SOURCE="dummy"
DURATION=300   # seconds per experiment/level

# Selected benchmarks: e1, e2, e3, e4, b1, b2, b3. If empty, run all.
BENCH_SELECTION=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            BENCH_SELECTION+=("$arg")
            ;;
    esac
done

# ─── Fixed model IDs from registry ───────────────────────────────────────────
# B1 models: yolov8n, yolov8s, yolov8m (or equivalent UUIDs)
B1_MODEL_IDS=(
    019dff8c-6550-7a41-812e-1585d9067937
    019dff8d-3354-7472-be12-16400911eaae
    019dff8e-1853-73ce-bee1-773c44fc9361
    019661ad-c7f2-7e9a-9a0c-43bd9053b435
)

# B2 models: includes RF-DETR for cross-architecture swap pair
B2_MODEL_IDS=(
    019dff8c-6550-7a41-812e-1585d9067937
    019dff8d-3354-7472-be12-16400911eaae
    019dff8e-1853-73ce-bee1-773c44fc9361
    019661ad-c7f2-7e9a-9a0c-43bd9053b435
)

# B3 models: includes RF-DETR for schema validation
B3_MODEL_IDS=(
    019dff8d-3354-7472-be12-16400911eaae
    019dff8e-1853-73ce-bee1-773c44fc9361
    019661ad-c7f2-7e9a-9a0c-43bd9053b435
)

B2_PIPELINE_ID_DEFAULT="019dff93-a84b-7964-85d5-0a0126dca772"
B2_PIPELINE_ID="${B2_PIPELINE_ID:-$B2_PIPELINE_ID_DEFAULT}"
B2_MANUAL_CSV_URL="https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/b2_hardcoded_manual.csv"
B2_MANUAL_CSV_PATH="$OUTPUT_DIR/b2/b2_hardcoded_manual.csv"

# B3 video path — override via env if your video is elsewhere
DEFAULT_B3_VIDEO_PATH="$HOME/nedovision/sample2_100x.mp4"
B3_VIDEO_PATH="${B3_VIDEO_PATH:-$DEFAULT_B3_VIDEO_PATH}"

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
deactivate

# ─── Build commands ───────────────────────────────────────────────────────────

# Shared prefix untuk semua command
BASE="cd $CORE_DIR && source .venv/bin/activate && set -o pipefail"
BENCH_PREFIX="CORE_STORAGE_PATH=\"../data\" python -m benchmark"
COMMON_FLAGS="--device $DEVICE --warmup $WARMUP --no-speed --markdown --pdf-charts --storage-path \"../data\" --output-dir $OUTPUT_DIR"
BACKUP_CMD="echo '' \
  && echo '>>> Backup to ${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG} starting...' \
  && if command -v rclone >/dev/null 2>&1 && rclone lsd \"${SEAWEEDFS_REMOTE}:\" >/dev/null 2>&1; then \
       rclone mkdir \"${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}\" 2>/dev/null || true; \
       rclone sync \"$CORE_DIR/$OUTPUT_DIR\" \"${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}\" --log-file /tmp/rclone_sync.log; \
       echo '=== BACKUP DONE ==='; \
     else \
       echo '[WARN] rclone or SeaweedFS remote unavailable; backup skipped.'; \
     fi"

CMD_E1="${BASE} && ${BENCH_PREFIX} \
    --experiment e1 \
    --source $SOURCE \
    --duration $DURATION \
    ${COMMON_FLAGS} \
    2>&1 | tee ${OUTPUT_DIR}/e1_run.log"

CMD_E2="${BASE} && ${BENCH_PREFIX} \
    --experiment e2 \
    --source $SOURCE \
    --duration $DURATION \
    ${COMMON_FLAGS} \
    2>&1 | tee ${OUTPUT_DIR}/e2_run.log"

CMD_E3="${BASE} && ${BENCH_PREFIX} \
    --experiment e3 \
    --source $SOURCE \
    --duration $DURATION \
    ${COMMON_FLAGS} \
    2>&1 | tee ${OUTPUT_DIR}/e3_run.log"

CMD_E4="${BASE} && ${BENCH_PREFIX} \
    --experiment e4 \
    --source $SOURCE \
    --duration $DURATION \
    ${COMMON_FLAGS} \
    2>&1 | tee ${OUTPUT_DIR}/e4_run.log"

CMD_B1="${BASE} && ${BENCH_PREFIX} \
  --experiment b1 \
  --b1-model-ids ${B1_MODEL_IDS[*]} \
  --b1-trials 30 \
  ${COMMON_FLAGS} \
  2>&1 | tee ${OUTPUT_DIR}/b1_run.log"

CMD_B2="${BASE} && ${BENCH_PREFIX} \
  --experiment b2 \
  --source rtsp \
  --b2-pipeline-id ${B2_PIPELINE_ID} \
  --b2-model-ids ${B2_MODEL_IDS[*]} \
  --b2-trials 30 \
  --b2-poll-interval 1.0 \
  --b2-timeout 60 \
  ${COMMON_FLAGS} \
  2>&1 | tee ${OUTPUT_DIR}/b2_run.log"

CMD_B3="${BASE} && ${BENCH_PREFIX} \
  --experiment b3 \
  --b3-model-ids ${B3_MODEL_IDS[*]} \
  --b3-frames 100 \
  --b3-video-path \"${B3_VIDEO_PATH}\" \
  ${COMMON_FLAGS} \
  2>&1 | tee ${OUTPUT_DIR}/b3_run.log"

# Sequential runner — run only selected benchmarks, stop on error
declare -a RUN_STEPS=()
declare -a RUN_LABELS=()

add_step() {
    local label="$1"; shift
    local cmd="$1"
    RUN_LABELS+=("$label")
    RUN_STEPS+=("$cmd")
}

want_bench() {
    local name="$1"
    if [[ ${#BENCH_SELECTION[@]} -eq 0 ]]; then
        return 0
    fi
    for sel in "${BENCH_SELECTION[@]}"; do
        if [[ "$sel" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

if want_bench "e1"; then
    add_step "E1" "$CMD_E1"
fi
if want_bench "e2"; then
    add_step "E2" "$CMD_E2"
fi
if want_bench "e3"; then
    add_step "E3" "$CMD_E3"
fi
if want_bench "e4"; then
    add_step "E4" "$CMD_E4"
fi
if want_bench "b1"; then
    add_step "B1 cold-start" "$CMD_B1"
fi
if want_bench "b2"; then
    add_step "B2 config-swap" "$CMD_B2"
fi
if want_bench "b3"; then
    add_step "B3 schema consistency" "$CMD_B3"
fi

if [[ ${#RUN_STEPS[@]} -eq 0 ]]; then
    die "No valid benchmarks selected. Use: e1 e2 e3 e4 b1 b2 b3"
fi

SEQUENTIAL_CMD=""
for i in "${!RUN_STEPS[@]}"; do
    step_no=$((i + 1))
    total=${#RUN_STEPS[@]}
    if [[ -z "$SEQUENTIAL_CMD" ]]; then
        SEQUENTIAL_CMD="echo '>>> [${step_no}/${total}] ${RUN_LABELS[$i]} starting...' && ${RUN_STEPS[$i]}"
    else
        SEQUENTIAL_CMD+=" && echo '' && echo '>>> [${step_no}/${total}] ${RUN_LABELS[$i]} starting...' && ${RUN_STEPS[$i]}"
    fi
done
SEQUENTIAL_CMD+=" && echo '' && echo '=== ALL SELECTED EXPERIMENTS DONE ===' && ${BACKUP_CMD}"

# ─── Prepare B2 manual CSV ────────────────────────────────────────────────────
info "Preparing B2 manual CSV..."
mkdir -p "$(dirname "$B2_MANUAL_CSV_PATH")"
if [[ ! -f "$B2_MANUAL_CSV_PATH" ]]; then
    wget -q --show-progress "$B2_MANUAL_CSV_URL" -O "$B2_MANUAL_CSV_PATH" \
        || die "Failed to download b2_hardcoded_manual.csv"
    success "B2 manual CSV ready: $B2_MANUAL_CSV_PATH"
else
    warn "b2_hardcoded_manual.csv already exists, skipping download."
fi

# ─── Prepare B3 video ─────────────────────────────────────────────────────────
VIDEO_DIR="$WORKDIR"
SAMPLE_RAW="$VIDEO_DIR/sample2.mp4"
SAMPLE_COPY="$VIDEO_DIR/sample2_copy.mkv"
SAMPLE_100X="$VIDEO_DIR/sample2_100x.mp4"
SAMPLE_URL="https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/sample2.mp4"

info "Preparing B3 video..."

if [[ "$B3_VIDEO_PATH" == "$DEFAULT_B3_VIDEO_PATH" && ! -f "$SAMPLE_100X" ]]; then
    if [[ ! -f "$SAMPLE_RAW" ]]; then
        info "Downloading sample2.mp4..."
        wget -q --show-progress "$SAMPLE_URL" -O "$SAMPLE_RAW" \
            || die "Failed to download sample2.mp4"
        success "sample2.mp4 downloaded."
    else
        warn "sample2.mp4 already exists, skipping download."
    fi

    info "Running ffmpeg: copy to mkv..."
    ffmpeg -i "$SAMPLE_RAW" -c copy "$SAMPLE_COPY" -y -loglevel error \
        || die "ffmpeg step 1 failed (copy to mkv)"

    info "Running ffmpeg: loop 100x..."
    ffmpeg -stream_loop 100 -i "$SAMPLE_COPY" -c copy "$SAMPLE_100X" -y -loglevel error \
        || die "ffmpeg step 2 failed (loop 100x)"

    success "B3 video ready: $SAMPLE_100X"
elif [[ "$B3_VIDEO_PATH" == "$DEFAULT_B3_VIDEO_PATH" ]]; then
    warn "sample2_100x.mp4 already exists, skipping video preparation."
else
    info "Using custom B3 video path: $B3_VIDEO_PATH"
fi

[[ -f "$B3_VIDEO_PATH" ]] || die "B3 video not found at: $B3_VIDEO_PATH. Set B3_VIDEO_PATH or place video there."

# ─── Launch tmux ──────────────────────────────────────────────────────────────
info "Starting tmux session: $SESSION"
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n "benchmark" -x 220 -y 50

# Window 1: semua experiments sequential dalam 1 window
tmux send-keys -t "$SESSION:benchmark" "$SEQUENTIAL_CMD" Enter

# Window 2: GPU + disk monitor
tmux new-window -t "$SESSION" -n "monitor"
tmux send-keys -t "$SESSION:monitor" \
    "watch -n3 'nvidia-smi && echo && df -h $CORE_DIR && echo && tail -5 /tmp/rclone_sync.log 2>/dev/null'" Enter

echo ""
echo -e "${BOLD}Benchmark session started: $SESSION${NC}"
echo -e "${BOLD}Output dir :${NC} $CORE_DIR/$OUTPUT_DIR"
echo ""
echo -e "${BOLD}Execution order (sequential, auto-stop on error):${NC}"
echo -e "  1. E1             (~$(( DURATION * 2 / 60 )) min)"
echo -e "  2. E2             (~$(( DURATION * 2 / 60 )) min)"
echo -e "  3. E3             (~$(( DURATION * 2 / 60 )) min)"
echo -e "  4. E4             (~$(( DURATION * 2 / 60 )) min)"
echo -e "  5. B1             (30 trials x 3 models)"
echo -e "  6. B2             (30 trials x 4 swap pairs, needs RTSP)"
echo -e "  7. B3             (100 frames x 3 models)"
echo ""
echo -e "Attach : ${CYAN}tmux attach -t $SESSION${NC}"
echo -e "Detach : ${CYAN}Ctrl+B then D${NC}"
echo ""
echo -e "${YELLOW}B3 video path: ${B3_VIDEO_PATH}${NC}"
echo -e "${YELLOW}Backup target: ${SEAWEEDFS_REMOTE}:${SEAWEEDFS_BUCKET}/${RUN_TAG}${NC}"
