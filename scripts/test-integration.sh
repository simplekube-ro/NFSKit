#!/bin/bash
# Integration test runner for NFSKit (requires Docker)
# Usage: ./scripts/test-integration.sh [options]
#
# Options:
#   --filter PATTERN   Run tests matching pattern (class or class/method)
#   --skip-docker      Skip Docker container start/stop (containers already running)
#   -v                 Verbose output
#   --help             Show this help
#
# Examples:
#   ./scripts/test-integration.sh
#   ./scripts/test-integration.sh --filter ConnectionIntegrationTests
#   ./scripts/test-integration.sh --skip-docker --filter FileIntegrationTests
#   ./scripts/test-integration.sh --filter DirectoryIntegrationTests/testCreateAndListDirectory

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FIXTURES_DIR="$PROJECT_ROOT/test-fixtures"

cd "$PROJECT_ROOT"

# Defaults
SKIP_DOCKER=false
FILTER=""
VERBOSITY=0

# Show help
show_help() {
    head -15 "$0" | tail -13 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        --filter) FILTER="$2"; shift 2 ;;
        -v) VERBOSITY=1; shift ;;
        *) shift ;;
    esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NFSKit Integration Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Verify Docker
if ! command -v docker &>/dev/null; then
    echo "✗ Docker not found. Install Docker Desktop."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "✗ Docker daemon not running. Start Docker Desktop."
    exit 1
fi

# Guaranteed cleanup on exit
cleanup() {
    if [[ "$SKIP_DOCKER" == false ]]; then
        echo "Stopping Docker containers..."
        docker-compose -f "$FIXTURES_DIR/docker-compose.yml" down -v 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 2. Start containers
if [[ "$SKIP_DOCKER" == false ]]; then
    echo "Starting NFS container..."
    docker-compose -f "$FIXTURES_DIR/docker-compose.yml" up -d

    # 3. Wait for NFS ports
    echo "Waiting for NFS (ports 111+2049)..."
    for i in $(seq 1 30); do
        if nc -z localhost 2049 2>/dev/null && nc -z localhost 111 2>/dev/null; then
            echo "  NFS ready"
            break
        fi
        if [[ $i -eq 30 ]]; then
            echo "✗ NFS timeout after 30s"
            docker-compose -f "$FIXTURES_DIR/docker-compose.yml" logs
            exit 1
        fi
        sleep 1
    done
fi

# 4. Run integration tests
echo "Running integration tests..."
export NFSKIT_TEST_HOST=127.0.0.1
export NFSKIT_TEST_EXPORT=/share

TEST_FILTER="NFSKitIntegrationTests"
if [[ -n "$FILTER" ]]; then
    TEST_FILTER="NFSKitIntegrationTests.$FILTER"
fi

if [[ $VERBOSITY -eq 1 ]]; then
    swift test --filter "$TEST_FILTER" 2>&1
else
    swift test --filter "$TEST_FILTER" 2>&1
fi
TEST_EXIT=$?

# 5. Report
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $TEST_EXIT -eq 0 ]]; then
    echo "✓ Integration tests passed"
else
    echo "✗ Integration tests failed"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $TEST_EXIT
