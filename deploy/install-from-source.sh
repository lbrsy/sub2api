#!/usr/bin/env bash
#
# Build and install Sub2API from source.
#
# This script is intended for deploying a patched fork/branch before the fix is
# available in an official release. It builds the Vue frontend, embeds it into
# the Go backend, installs the binary under /opt/sub2api, and manages systemd.
#
# Examples:
#   sudo bash deploy/install-from-source.sh
#   sudo bash deploy/install-from-source.sh --repo https://github.com/you/sub2api.git --branch fix/team-import
#   sudo bash deploy/install-from-source.sh --source-dir /opt/sub2api-src --port 8080
#

set -euo pipefail

INSTALL_DIR="/opt/sub2api"
SERVICE_NAME="sub2api"
SERVICE_USER="sub2api"
SERVER_HOST="0.0.0.0"
SERVER_PORT="8080"
SOURCE_DIR=""
SOURCE_REPO=""
SOURCE_REF=""
SKIP_START="false"
FORCE_YES="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

usage() {
    cat <<EOF
Usage: sudo bash install-from-source.sh [options]

Options:
  --source-dir <path>   Use an existing local source checkout.
  --repo <url>          Clone source from a Git repository.
  --branch <ref>        Branch/tag/commit to checkout when --repo is used.
  --install-dir <path>  Install directory. Default: /opt/sub2api
  --host <addr>         Listen address for systemd env. Default: 0.0.0.0
  --port <port>         Listen port for systemd env. Default: 8080
  --skip-start          Install service but do not start it.
  -y, --yes             Non-interactive yes for confirmations.
  -h, --help            Show this help.

If neither --source-dir nor --repo is provided, the script uses the repository
that contains this script. This works when you run it from a checked-out source
tree. When using curl | bash, pass --repo explicitly.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source-dir)
                SOURCE_DIR="${2:-}"
                shift 2
                ;;
            --source-dir=*)
                SOURCE_DIR="${1#*=}"
                shift
                ;;
            --repo)
                SOURCE_REPO="${2:-}"
                shift 2
                ;;
            --repo=*)
                SOURCE_REPO="${1#*=}"
                shift
                ;;
            --branch|--ref)
                SOURCE_REF="${2:-}"
                shift 2
                ;;
            --branch=*|--ref=*)
                SOURCE_REF="${1#*=}"
                shift
                ;;
            --install-dir)
                INSTALL_DIR="${2:-}"
                shift 2
                ;;
            --install-dir=*)
                INSTALL_DIR="${1#*=}"
                shift
                ;;
            --host)
                SERVER_HOST="${2:-}"
                shift 2
                ;;
            --host=*)
                SERVER_HOST="${1#*=}"
                shift
                ;;
            --port)
                SERVER_PORT="${2:-}"
                shift 2
                ;;
            --port=*)
                SERVER_PORT="${1#*=}"
                shift
                ;;
            --skip-start)
                SKIP_START="true"
                shift
                ;;
            -y|--yes)
                FORCE_YES="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

is_interactive() {
    [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

confirm() {
    local prompt="$1"
    if [ "$FORCE_YES" = "true" ]; then
        return 0
    fi
    if ! is_interactive; then
        print_error "Non-interactive mode requires -y/--yes for confirmation."
        exit 1
    fi
    read -r -p "$prompt [y/N]: " reply < /dev/tty
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) print_info "Cancelled."; exit 0 ;;
    esac
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Please run as root, for example: sudo bash deploy/install-from-source.sh"
        exit 1
    fi
}

require_command() {
    local command_name="$1"
    local hint="$2"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        print_error "Missing dependency: $command_name"
        print_error "$hint"
        exit 1
    fi
}

version_ge() {
    local current="$1"
    local required="$2"
    [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" = "$required" ]
}

check_dependencies() {
    require_command systemctl "This script targets Linux servers with systemd."
    require_command git "Install git first."
    require_command curl "Install curl first."
    require_command node "Install Node.js 20+ or 24+ first."
    require_command npm "Install npm first."
    require_command go "Install Go 1.26.4+ first. The current backend/go.mod requires go 1.26.4."

    local node_version
    node_version="$(node -v | sed 's/^v//')"
    if ! version_ge "$node_version" "18.0.0"; then
        print_error "Node.js $node_version is too old; install Node.js 18+."
        exit 1
    fi

    local go_version
    go_version="$(go version | awk '{print $3}' | sed 's/^go//')"
    if ! version_ge "$go_version" "1.26.4"; then
        print_error "Go $go_version is too old; install Go 1.26.4+."
        exit 1
    fi

    if ! command -v pnpm >/dev/null 2>&1; then
        if command -v corepack >/dev/null 2>&1; then
            print_info "pnpm not found; enabling pnpm through corepack."
            corepack enable
            corepack prepare pnpm@9 --activate
        else
            print_info "pnpm not found; installing pnpm@9 with npm."
            npm install -g pnpm@9
        fi
    fi

    require_command pnpm "Install pnpm first: npm install -g pnpm@9"
}

infer_source_dir() {
    if [ -n "$SOURCE_DIR" ]; then
        SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
        return
    fi

    local script_file="${BASH_SOURCE[0]:-}"
    if [ -n "$script_file" ] && [ -f "$script_file" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "$script_file")" && pwd)"
        local candidate
        candidate="$(cd "$script_dir/.." && pwd)"
        if [ -d "$candidate/backend" ] && [ -d "$candidate/frontend" ] && [ -f "$candidate/backend/go.mod" ]; then
            SOURCE_DIR="$candidate"
            return
        fi
    fi

    if [ -n "$SOURCE_REPO" ]; then
        return
    fi

    print_error "No source found. Run this script from a source checkout, or pass --source-dir/--repo."
    exit 1
}

prepare_source() {
    local build_root="$1"
    WORKTREE=""

    if [ -n "$SOURCE_REPO" ]; then
        WORKTREE="$build_root/src"
        print_info "Cloning source: $SOURCE_REPO"
        if [ -n "$SOURCE_REF" ]; then
            if ! git clone --depth 1 --branch "$SOURCE_REF" "$SOURCE_REPO" "$WORKTREE"; then
                print_warning "Shallow branch clone failed; retrying full clone and checkout."
                rm -rf "$WORKTREE"
                git clone "$SOURCE_REPO" "$WORKTREE"
                git -C "$WORKTREE" checkout "$SOURCE_REF"
            fi
        else
            git clone --depth 1 "$SOURCE_REPO" "$WORKTREE"
        fi
    else
        WORKTREE="$SOURCE_DIR"
    fi

    if [ ! -f "$WORKTREE/backend/go.mod" ] || [ ! -f "$WORKTREE/frontend/package.json" ]; then
        print_error "Invalid source tree: $WORKTREE"
        exit 1
    fi

    print_success "Using source: $WORKTREE"
}

create_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        print_info "System user already exists: $SERVICE_USER"
        local current_shell
        current_shell="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f7 || true)"
        if [ "$current_shell" = "/bin/false" ] || [ "$current_shell" = "/sbin/nologin" ]; then
            usermod -s /bin/sh "$SERVICE_USER" || true
        fi
    else
        print_info "Creating system user: $SERVICE_USER"
        useradd -r -s /bin/sh -d "$INSTALL_DIR" "$SERVICE_USER"
    fi
}

build_frontend() {
    print_info "Building frontend."
    (
        cd "$WORKTREE/frontend"
        pnpm install --frozen-lockfile
        pnpm run build
    )
}

build_backend() {
    print_info "Building backend with embedded frontend."
    local output="$1"
    local version_value
    local commit_value
    local date_value

    version_value="${VERSION:-}"
    if [ -z "$version_value" ]; then
        version_value="$(cd "$WORKTREE/backend" && ./scripts/resolve-version.sh)"
    fi
    commit_value="$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo source)"
    date_value="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    (
        cd "$WORKTREE/backend"
        go build \
            -tags embed \
            -ldflags="-s -w -X main.Version=${version_value} -X main.Commit=${commit_value} -X main.Date=${date_value} -X main.BuildType=source" \
            -trimpath \
            -o "$output" \
            ./cmd/server
    )
}

install_binary() {
    local binary_path="$1"

    print_info "Installing to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/data"

    if [ -f "$INSTALL_DIR/sub2api" ]; then
        local backup_path="$INSTALL_DIR/sub2api.backup.$(date +%Y%m%d%H%M%S)"
        cp "$INSTALL_DIR/sub2api" "$backup_path"
        print_info "Existing binary backed up to $backup_path"
    fi

    install -m 0755 "$binary_path" "$INSTALL_DIR/sub2api"
    rm -rf "$INSTALL_DIR/resources"
    cp -a "$WORKTREE/backend/resources" "$INSTALL_DIR/resources"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

    if git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        {
            echo "source_repo=${SOURCE_REPO:-local}"
            echo "source_ref=${SOURCE_REF:-$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
            echo "source_commit=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
            echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$INSTALL_DIR/source-build.txt"
        chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/source-build.txt"
    fi
}

install_service() {
    print_info "Installing systemd service: $SERVICE_NAME"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Sub2API - AI API Gateway Platform
Documentation=https://github.com/Wei-Shaw/sub2api
After=network.target postgresql.service redis.service
Wants=postgresql.service redis.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/sub2api
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${INSTALL_DIR}

# Environment - Server configuration
Environment=GIN_MODE=release
Environment=SERVER_HOST=${SERVER_HOST}
Environment=SERVER_PORT=${SERVER_PORT}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
}

restart_service() {
    if [ "$SKIP_START" = "true" ]; then
        print_warning "Service start skipped. Start later with: sudo systemctl start $SERVICE_NAME"
        return
    fi

    print_info "Starting service."
    systemctl restart "$SERVICE_NAME"
    print_success "Service started."
}

print_completion() {
    local display_host="$SERVER_HOST"
    if [ "$display_host" = "0.0.0.0" ]; then
        display_host="$(hostname -I 2>/dev/null | awk '{print $1}')"
        display_host="${display_host:-YOUR_SERVER_IP}"
    fi

    echo ""
    echo "=============================================="
    print_success "Sub2API source deployment completed"
    echo "=============================================="
    echo ""
    echo "Install directory: $INSTALL_DIR"
    echo "Listen address:    $SERVER_HOST:$SERVER_PORT"
    echo "Web setup:         http://${display_host}:${SERVER_PORT}"
    echo ""
    echo "Important:"
    echo "  - PostgreSQL 15+ and Redis 7+ must be running before completing setup."
    echo "  - On first deployment, do not pre-create config.yaml unless you already have an admin user."
    echo "  - The setup wizard creates config and the initial admin account."
    echo ""
    echo "Commands:"
    echo "  sudo systemctl status $SERVICE_NAME"
    echo "  sudo journalctl -u $SERVICE_NAME -f"
    echo "  sudo systemctl restart $SERVICE_NAME"
    echo ""
}

main() {
    parse_args "$@"
    check_root
    infer_source_dir

    if [ -f "$INSTALL_DIR/sub2api" ]; then
        confirm "Sub2API is already installed at $INSTALL_DIR. Build and replace the binary?"
    fi

    check_dependencies

    local build_root
    build_root="$(mktemp -d)"
    trap 'rm -rf "$build_root"' EXIT

    prepare_source "$build_root"
    create_user

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_info "Stopping running service before installing new binary."
        systemctl stop "$SERVICE_NAME"
    fi

    build_frontend
    build_backend "$build_root/sub2api"
    install_binary "$build_root/sub2api"
    install_service
    restart_service
    print_completion
}

main "$@"
