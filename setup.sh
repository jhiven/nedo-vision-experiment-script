#!/usr/bin/env bash
# =============================================================================
# setup.sh — Nedo Vision Benchmark: Instance Setup
# Run this ONCE on a fresh Vast.ai instance.
#
# Required env vars:
#   GITLAB_USER            — GitLab username
#   GITLAB_TOKEN           — GitLab personal access token (read_repository scope)
#   WORKER_SERVICE_TOKEN   — token for test_jhiven.py --token argument
#
# Optional env vars:
#   SEAWEEDFS_REMOTE       — rclone remote name (default: seaweedfs_s3)
#   SEAWEEDFS_ENDPOINT     — SeaweedFS S3 endpoint (default: localhost:8333)
#   SEAWEEDFS_ACCESS_KEY   — SeaweedFS S3 access key (default: any)
#   SEAWEEDFS_SECRET_KEY   — SeaweedFS S3 secret key (default: any)
#
# Usage:
#   export GITLAB_USER="your_username"
#   export GITLAB_TOKEN="glpat-xxxxxxxxxxxx"
#   export WORKER_SERVICE_TOKEN="your_service_token"
#   bash setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ -z "${GITLAB_USER:-}" ]]           && die "GITLAB_USER is not set."
[[ -z "${GITLAB_TOKEN:-}" ]]          && die "GITLAB_TOKEN is not set."
[[ -z "${WORKER_SERVICE_TOKEN:-}" ]]  && die "WORKER_SERVICE_TOKEN is not set."

PYTHON_VERSION="3.12.12"
WORKER_CORE_REPO="https://${GITLAB_USER}:${GITLAB_TOKEN}@gitlab.com/sindika/research/nedo-vision/nedo-vision-worker-core-v2.git"
WORKER_SERVICE_REPO="https://${GITLAB_USER}:${GITLAB_TOKEN}@gitlab.com/sindika/research/nedo-vision/nedo-vision-worker-service.git"
WORKER_CORE_BRANCH="feat/pipeline-flow"
WORKER_SERVICE_BRANCH="feat/pipeline-workflow"
SETUP_SESSION="nedovision-setup"
WORKDIR="$HOME/nedovision"
DATA_DIR="$WORKDIR/data"
SEAWEEDFS_REMOTE="${SEAWEEDFS_REMOTE:-seaweedfs_s3}"
SEAWEEDFS_ENDPOINT="${SEAWEEDFS_ENDPOINT:-localhost:8333}"
SEAWEEDFS_ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:-any}"
SEAWEEDFS_SECRET_KEY="${SEAWEEDFS_SECRET_KEY:-any}"

echo -e "${BOLD}==============================${NC}"
echo -e "${BOLD} Nedo Vision — Instance Setup${NC}"
echo -e "${BOLD}==============================${NC}"

# ─── 1. System packages ───────────────────────────────────────────────────────
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
    tmux git curl wget ffmpeg rclone build-essential libssl-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
    liblzma-dev libncursesw5-dev xz-utils tk-dev \
    > /dev/null 2>&1
success "System packages installed."

# ─── 2. rclone SeaweedFS remote ───────────────────────────────────────────────
info "Configuring rclone remote: $SEAWEEDFS_REMOTE"
mkdir -p "$HOME/.config/rclone"
rclone config create "$SEAWEEDFS_REMOTE" s3 \
    provider SeaweedFS \
    access_key_id "$SEAWEEDFS_ACCESS_KEY" \
    secret_access_key "$SEAWEEDFS_SECRET_KEY" \
    endpoint "$SEAWEEDFS_ENDPOINT" \
    >/dev/null
success "rclone remote '$SEAWEEDFS_REMOTE' configured for $SEAWEEDFS_ENDPOINT."

# ─── 3. tmux config ───────────────────────────────────────────────────────────
TMUX_CONF_URL="https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/.tmux.conf"
info "Downloading tmux config..."
if curl -fsSL "$TMUX_CONF_URL" -o "$HOME/.tmux.conf" 2>/dev/null; then
    success "tmux config downloaded."
else
    warn "Could not download .tmux.conf — using tmux defaults."
fi

# ─── 4. pyenv ─────────────────────────────────────────────────────────────────
if ! command -v pyenv &>/dev/null; then
    info "Installing pyenv..."
    curl -fsSL https://pyenv.run | bash
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)" 2>/dev/null || true
    {
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init - bash)"'
    } >> "$HOME/.bashrc"
    {
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo 'eval "$(pyenv init - bash)"'
    } >> "$HOME/.profile"
    success "pyenv installed."
else
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    success "pyenv already installed."
fi

# ─── 5. Python 3.12.12 ────────────────────────────────────────────────────────
if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
    info "Installing Python $PYTHON_VERSION (this takes a few minutes)..."
    pyenv install "$PYTHON_VERSION"
    success "Python $PYTHON_VERSION installed."
else
    success "Python $PYTHON_VERSION already installed."
fi

# ─── 6. Workdir + shared data dir ─────────────────────────────────────────────
mkdir -p "$WORKDIR" "$DATA_DIR"
info "Working directory : $WORKDIR"
info "Shared data dir   : $DATA_DIR  (used as --storage-path ../data by both repos)"

# ─── 7. Clone repos ───────────────────────────────────────────────────────────
CORE_DIR="$WORKDIR/nedo-vision-worker-core-v2"
SERVICE_DIR="$WORKDIR/nedo-vision-worker-service"

info "Cloning repositories..."
if [[ ! -d "$CORE_DIR/.git" ]]; then
    git clone "$WORKER_CORE_REPO" "$CORE_DIR" -q
    success "worker-core cloned."
else
    warn "worker-core already exists, skipping clone."
fi

if [[ ! -d "$SERVICE_DIR/.git" ]]; then
    git clone "$WORKER_SERVICE_REPO" "$SERVICE_DIR" -q
    success "worker-service cloned."
else
    warn "worker-service already exists, skipping clone."
fi

# ─── 8. Checkout branches ─────────────────────────────────────────────────────
git -C "$CORE_DIR"    checkout "$WORKER_CORE_BRANCH"    -q
git -C "$SERVICE_DIR" checkout "$WORKER_SERVICE_BRANCH" -q
success "Branches checked out."

# ─── 9. Setup venv + pip install for both repos ───────────────────────────────
setup_repo() {
    local dir="$1"
    local label="$2"
    info "[$label] Setting up Python environment..."
    cd "$dir"
    pyenv local "$PYTHON_VERSION"
    local python_bin
    python_bin="$(pyenv prefix $PYTHON_VERSION)/bin/python"
    if [[ ! -d ".venv" ]]; then
        "$python_bin" -m venv .venv
        success "[$label] venv created."
    else
        warn "[$label] .venv already exists."
    fi
    source .venv/bin/activate
    info "[$label] Using $(python --version)"
    pip install --upgrade pip -q
    if [[ "$label" == "worker-core" ]]; then
        pip install torch torchvision --index-url https://download.pytorch.org/whl/cu126 -q
    else
        pip install statsmodels -q
    fi
    pip install -r requirements.txt -q
    success "[$label] requirements installed."
    deactivate
    cd - > /dev/null
}

setup_repo "$CORE_DIR"    "worker-core"
setup_repo "$SERVICE_DIR" "worker-service"

# ─── 10. Launch tmux session ──────────────────────────────────────────────────
info "Launching tmux session: $SETUP_SESSION"
tmux kill-session -t "$SETUP_SESSION" 2>/dev/null || true
tmux new-session -d -s "$SETUP_SESSION" -n "worker-core" -x 220 -y 50

# Window 1: worker-core test (--storage-path optional, default is ../data)
tmux send-keys -t "$SETUP_SESSION:worker-core" \
    "cd $CORE_DIR && source .venv/bin/activate && python test_jhiven.py --storage-path \"../data\"" Enter

# Window 2: worker-service test
tmux new-window -t "$SETUP_SESSION" -n "worker-service"
tmux send-keys -t "$SETUP_SESSION:worker-service" \
    "cd $SERVICE_DIR && source .venv/bin/activate && \
python test_jhiven.py \
  --server-host grpc-nedovision.jhiven.my.id \
  --server-port 443 \
  --token \"${WORKER_SERVICE_TOKEN}\" \
  --storage-path \"../data\"" Enter

success "tmux session '$SETUP_SESSION' launched."
echo ""
echo -e "${BOLD}Attach with:${NC}  tmux attach -t $SETUP_SESSION"
echo -e "${BOLD}Window 1:${NC}     worker-core     (test_jhiven.py)"
echo -e "${BOLD}Window 2:${NC}     worker-service  (test_jhiven.py --server-host ...)"
echo ""
echo -e "${GREEN}Once both windows show success, run one of the benchmark scripts.${NC}"
