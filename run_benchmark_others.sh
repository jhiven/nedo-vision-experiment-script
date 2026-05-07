#!/usr/bin/env bash
# =============================================================================
# run_benchmark_others.sh — E1, E2, E3, E4, B1, B2, B3
# Target instance : L40S
# Estimated time  : ~2 hours
#
# Required env vars:
#   RTMP_SERVER     — RTSP stream URL (required for B2)
#   B3_VIDEO_PATH   — path to video file for B3 (default: ~/nedovision/sample.mp4)
#
# Optional env vars:
#   RUN_TAG         — label appended to output dir (default: current datetime)
#   MINIO_ENDPOINT  — MinIO endpoint for auto-sync
#   MINIO_ACCESS_KEY
#   MINIO_SECRET_KEY
#   MINIO_BUCKET    — default: nedovision-benchmark
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
WORKDIR="$HOME/nedovision"

DEVICE="cuda"
WARMUP=50
SOURCE="dummy"
DURATION=300   # seconds per experiment/level

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

B2_PIPELINE_ID="3cf5199c-7833-4289-a107-bcb2acdf4b37"

# B3 video path — override via env if your video is elsewhere
B3_VIDEO_PATH="${B3_VIDEO_PATH:-$HOME/nedovision/sample2_100x.mp4}"

# ─── Guards ───────────────────────────────────────────────────────────────────
[[ -z "${RTMP_SERVER:-}" ]] && die "RTMP_SERVER is not set. B2 requires a live RTSP stream. Export it before running."
[[ -f "$B3_VIDEO_PATH" ]]   || die "B3 video not found at: $B3_VIDEO_PATH. Set B3_VIDEO_PATH or place video there."

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

# ─── Auto-sync setup ──────────────────────────────────────────────────────────
start_autosync() {
    local src_dir="$1"
    local tag="$2"
    local bucket="${MINIO_BUCKET:-nedovision-benchmark}"

    if ! command -v rclone &>/dev/null; then
        warn "rclone not found — skipping auto-sync."
        return
    fi
    if ! rclone lsd minio: &>/dev/null 2>&1; then
        warn "MinIO not reachable — skipping auto-sync."
        return
    fi

    rclone mkdir "minio:${bucket}/${tag}" 2>/dev/null || true

    local cron_line="*/5 * * * * rclone sync \"${src_dir}\" \"minio:${bucket}/${tag}\" --log-file /tmp/rclone_sync.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "nedovision-benchmark"; echo "$cron_line") | crontab -

    success "Auto-sync: every 5 min → minio:${bucket}/${tag}"
}

start_autosync "$CORE_DIR/$OUTPUT_DIR" "$RUN_TAG"

# ─── Build commands ───────────────────────────────────────────────────────────

# Shared prefix untuk semua command
BASE="cd $CORE_DIR && source .venv/bin/activate"
BENCH_PREFIX="CORE_STORAGE_PATH=\"../data\" python -m benchmark"
COMMON_FLAGS="--device $DEVICE --warmup $WARMUP --no-speed --markdown --pdf-charts --storage-path \"../data\" --output-dir $OUTPUT_DIR"

CMD_CORE="${BASE} && ${BENCH_PREFIX} \
  --experiment e1 e2 e3 e4 \
  --source $SOURCE \
  --duration $DURATION \
  ${COMMON_FLAGS} \
  2>&1 | tee ${OUTPUT_DIR}/core_run.log"

CMD_B1="${BASE} && ${BENCH_PREFIX} \
  --experiment b1 \
  --b1-model-ids ${B1_MODEL_IDS[*]} \
  --b1-trials 30 \
  ${COMMON_FLAGS} \
  2>&1 | tee ${OUTPUT_DIR}/b1_run.log"

CMD_B2="${BASE} && ${BENCH_PREFIX} \
  --experiment b2 \
  --source rtsp \
  --rtmp-server ${RTMP_SERVER} \
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

# Sequential runner — jalan satu per satu, berhenti kalau ada yang gagal
SEQUENTIAL_CMD="${CMD_CORE} \
  && echo '' \
  && echo '>>> [1/3] B1 cold-start starting...' \
  && ${CMD_B1} \
  && echo '' \
  && echo '>>> [2/3] B2 config-swap starting...' \
  && ${CMD_B2} \
  && echo '' \
  && echo '>>> [3/3] B3 schema consistency starting...' \
  && ${CMD_B3} \
  && echo '' \
  && echo '=== ALL EXPERIMENTS DONE ==='"

# ─── Prepare B3 video ─────────────────────────────────────────────────────────
VIDEO_DIR="$WORKDIR"
SAMPLE_RAW="$VIDEO_DIR/sample2.mp4"
SAMPLE_COPY="$VIDEO_DIR/sample2_copy.mkv"
SAMPLE_100X="$VIDEO_DIR/sample2_100x.mp4"
SAMPLE_URL="https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/sample2.mp4"

info "Preparing B3 video..."

if [[ ! -f "$SAMPLE_100X" ]]; then
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
else
    warn "sample2_100x.mp4 already exists, skipping video preparation."
fi

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
echo -e "  1. E1 E2 E3 E4   (~$(( DURATION * 4 * 2 / 60 )) min)"
echo -e "  2. B1             (30 trials x 3 models)"
echo -e "  3. B2             (30 trials x 4 swap pairs, needs RTSP)"
echo -e "  4. B3             (100 frames x 3 models)"
echo ""
echo -e "Attach : ${CYAN}tmux attach -t $SESSION${NC}"
echo -e "Detach : ${CYAN}Ctrl+B then D${NC}"
echo ""
echo -e "${YELLOW}B3 video path: ${B3_VIDEO_PATH}${NC}"
echo -e "${YELLOW}B2 RTSP: ${RTMP_SERVER}${NC}"