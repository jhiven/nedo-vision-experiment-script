# Nedo Vision Experiment Script

Scripts for setting up a fresh Vast.ai GPU instance and running Nedo Vision benchmark experiments.

Run `setup.sh` first on a new instance. After setup finishes, run either the L40S benchmark script or the RTX 3090 E5 long-run script.

## Environment Variables

| Variable               | Required For              | Default                         | Description                                                                                  |
| ---------------------- | ------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------- |
| `GITLAB_USER`          | `setup.sh`                | none                            | GitLab username.                                                                             |
| `GITLAB_TOKEN`         | `setup.sh`                | none                            | GitLab token with repository read access.                                                    |
| `WORKER_SERVICE_TOKEN` | `setup.sh`                | none                            | Worker service token used by `test_jhiven.py`.                                               |
| `RTMP_SERVER`          | `run_benchmark_others.sh` | none                            | RTSP stream URL for B2. Optional for `run_benchmark_e5.sh`; when unset, E5 uses dummy input. |
| `RUN_TAG`              | optional                  | current datetime                | Label appended to benchmark output directory.                                                |
| `B3_VIDEO_PATH`        | optional                  | `~/nedovision/sample2_100x.mp4` | Video file used by B3 in `run_benchmark_others.sh`.                                          |
| `SEAWEEDFS_REMOTE`     | optional                  | `seaweedfs_s3`                  | rclone remote name.                                                                          |
| `SEAWEEDFS_ENDPOINT`   | optional                  | `localhost:8333`                | SeaweedFS S3 endpoint configured by `setup.sh`.                                              |
| `SEAWEEDFS_ACCESS_KEY` | optional                  | `any`                           | SeaweedFS S3 access key configured by `setup.sh`.                                            |
| `SEAWEEDFS_SECRET_KEY` | optional                  | `any`                           | SeaweedFS S3 secret key configured by `setup.sh`.                                            |
| `SEAWEEDFS_BUCKET`     | optional                  | `personal`                      | Bucket used by benchmark backup scripts.                                                     |

## Setup

One-line setup command:

```bash
GITLAB_USER="your_gitlab_username" GITLAB_TOKEN="your_gitlab_token" WORKER_SERVICE_TOKEN="your_worker_service_token" bash -c "$(curl -fsSL https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/setup.sh)"
```

## Run L40S Benchmarks

Use this for non-RTX 3090 instances, such as L40S.

One-line command:

```bash
RTMP_SERVER="rtsp://your_stream_url" bash -c "$(curl -fsSL https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/run_benchmark_others.sh)"
```

## Run RTX 3090 E5 Benchmark

Use this for RTX 3090 instances. This is a long-running benchmark, around 24 hours.

One-line command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jhiven/nedo-vision-experiment-script/refs/heads/main/run_benchmark_e5.sh)"
```

## Tmux

All scripts run inside tmux sessions.

Attach:

```bash
tmux attach -t nedovision-benchmark
```

Detach:

```bash
Ctrl+B then D
```
