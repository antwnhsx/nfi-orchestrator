# nfi-orchestrator

**nfi-orchestrator** is a safe, lightweight CLI tool designed to automate updates and backups for remote trading bots (such as [Freqtrade](https://github.com/freqtrade/freqtrade) + [NostalgiaForInfinity](https://github.com/iterativv/NostalgiaForInfinity) strategy) running via Docker Compose over SSH.

It streams compressed backups directly off-site to save remote disk writes (protecting SD cards and SSDs), verifies active positions before applying updates, and features emergency recovery handlers if network drops occur mid-process.

## Context & Scope

This project was built primarily for my own setup to manage instances reliably and save disk writes on single-board computers. 

It is intentionally opinionated, simple, and low-overhead and it is not designed to be a one-size-fits-all deployment framework for generic applications.


## Key Features

- **Zero-Write Offsite Backups:** Pipes `tar` directly over SSH stdout to write backups locally without taking up disk space or causing extra writes on the remote machine.
- **Safety Checks:** Queries local/remote API endpoints (e.g., active open trade counts) to abort updates automatically if positions are open.
- **Smart Git Checking:** Uses Git commit revision hashes to skip container restarts and backups if no upstream updates exist.
- **Crash & Interruption Recovery:** Built-in Bash `trap` handlers automatically attempt to restart remote Docker containers if the script fails midway.
- **Pre-flight Checks:** Verifies disk space locally and detects remote Docker Compose binary versions (`docker compose` vs `docker-compose`).
- **Single Config Architecture:** INI-style section configuration supports multiple remote targets in a single file.


## Directory Structure

```text
nfi-orchestrator/
├── bot-updater.sh        # Main orchestration bash script
├── example.conf.sample   # Multi-target configuration file
├── LICENSE
├── README.md
└── .gitignore
```

## Setup & Prerequisites

### Local Prerequisites:

#### Ensure the local machine executing the script has:

- `bash`
- `ssh`
- `curl`
- `awk`
- `tar`

### Configure Passwordless SSH Keys (Required for Cron)

The script relies on SSH keys for unattended execution. Run the following on the local machine:

#### Generate a dedicated SSH key pair:
    
```bash
ssh-keygen -t ed25519 -f ~/.ssh/nfi_orchestrator_key -N ""
```

#### Copy the public key to your remote host:

```bash
ssh-copy-id -i ~/.ssh/nfi_orchestrator_key.pub user@remote-ip
```

#### Verify the connection without a password prompt:

```bash
ssh -i ~/.ssh/nfi_orchestrator_key user@remote-ip "echo 'SSH Connection successful!'"
```

### Creating Your Configuration File

#### Copy or create your configuration file (updater.conf):

```bash
cp example.conf.sample updater.conf
```

#### Edit updater.conf with your parameters:

```bash
# Global Defaults
BACKUP_BASE_DIR="$HOME/bot-updater/backups"
RETENTION_DAYS=7

# Target Profile: bot-1
[bot-1]
ENABLED=true
SSH_USER="user"
SSH_HOST="100.101.102.103"
SSH_PORT="22"
SSH_KEY_FILE="$HOME/.ssh/nfi_orchestrator_key"
REMOTE_BOT_DIR="/home/user/freqtrade"
EXCLUDE_PATTERNS="user_data/data user_data/backtest_results"
LOG_FILE="$HOME/bot-updater/logs/orchestrator.log"

# API Safety Check (Leave blank to skip)
API_HOST="100.101.102.103"
API_PORT="8080"
API_ENDPOINT="/api/v1/count"

# Telegram Notifications (Optional)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
```

#### To make bot-updater.sh executable, run the following command in your terminal:

```bash
chmod +x bot-updater.sh
```

## Usage
### Run Manually

#### Execute update for target profile

```bash
./bot-updater.sh -t bot-1
```

#### Run in Verbose Mode

```bash
./bot-updater.sh -t bot-1 -v
```

#### Perform a Dry Run (Simulates operations without stopping containers or pulling git)

```bash
./bot-updater.sh -t bot-1 -d
```

### Automated Cron Job

#### To run automatically in quiet mode (only logging errors):

```bash
0 3 * * * /path/to/nfi-orchestrator/bot-updater.sh -t bot-1 -q >/dev/null 2>&1
```

## Troubleshooting & Tips

### SSH Permission Denied: Ensure your private key has restricted permissions on the local machine:

```bash
chmod 600 ~/.ssh/nfi_orchestrator_key
```

### Docker Permission Denied on Remote: Ensure the SSH_USER on the remote host belongs to the docker user group so docker compose commands don't require sudo:

```bash
sudo usermod -aG docker $USER
```