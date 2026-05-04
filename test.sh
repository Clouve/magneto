#!/bin/bash

# ============================================================================
# Docker Application URL Update Test Script
# ============================================================================
# This script tests the dynamic URL update functionality for Docker applications.
# It verifies that changing a URL environment variable and restarting the container
# properly updates the application's internal configuration.
#
# This script uses environment variable substitution in docker-compose.yml files
# instead of modifying the files directly, making it cleaner and safer.
#
# Usage: ./test.sh <app-path> [domain1] [domain2] [port]
#
# Arguments:
#   app-path    Required. Relative path to app/bundle directory (e.g., apps/limesurvey)
#   domain1     Optional. First test domain (default: t1.test.clv)
#   domain2     Optional. Second test domain (default: t2.test.clv)
#   port        Optional. Port number to use (default: 8080)
#
# Examples:
#   ./test.sh apps/limesurvey
#   ./test.sh apps/wordpress
#   ./test.sh apps/limesurvey test1.example.com test2.example.com
#   ./test.sh apps/limesurvey test1.example.com test2.example.com 9090
# ============================================================================

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default test configuration
DEFAULT_DOMAIN_1="t1.test.clv"
DEFAULT_DOMAIN_2="t2.test.clv"
DEFAULT_PORT="8080"

# Global variables (will be set from arguments or defaults)
TEST_DOMAIN_1=""
TEST_DOMAIN_2=""
TEST_PORT=""

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# ============================================================================
# Validation Functions
# ============================================================================

show_usage() {
    echo "Usage: $0 <app-path> [domain1] [domain2] [port]"
    echo ""
    echo "Arguments:"
    echo "  app-path    Required. Relative path to app/bundle directory"
    echo "  domain1     Optional. First test domain (default: $DEFAULT_DOMAIN_1)"
    echo "  domain2     Optional. Second test domain (default: $DEFAULT_DOMAIN_2)"
    echo "  port        Optional. Port number to use (default: $DEFAULT_PORT)"
    echo ""
    echo "Examples:"
    echo "  $0 apps/limesurvey"
    echo "  $0 apps/wordpress"
    echo "  $0 apps/limesurvey test1.example.com test2.example.com"
    echo "  $0 apps/limesurvey test1.example.com test2.example.com 9090"
    echo ""
}

validate_arguments() {
    if [ $# -lt 1 ] || [ $# -gt 4 ]; then
        print_error "Invalid number of arguments"
        echo ""
        show_usage
        exit 1
    fi
}

parse_arguments() {
    local app_path="$1"
    local domain1="${2:-$DEFAULT_DOMAIN_1}"
    local domain2="${3:-$DEFAULT_DOMAIN_2}"
    local port="${4:-$DEFAULT_PORT}"

    # Set global variables
    TEST_DOMAIN_1="$domain1"
    TEST_DOMAIN_2="$domain2"
    TEST_PORT="$port"

    print_info "Test configuration:"
    print_info "  App path: $app_path"
    print_info "  Domain 1: $TEST_DOMAIN_1"
    print_info "  Domain 2: $TEST_DOMAIN_2"
    print_info "  Port: $TEST_PORT"
    echo ""
}

validate_app_directory() {
    local app_path="$1"

    if [ ! -d "$app_path" ]; then
        print_error "Directory not found: $app_path"
        exit 1
    fi

    if [ ! -f "$app_path/docker-compose.yml" ]; then
        print_error "docker-compose.yml not found in $app_path"
        exit 1
    fi

    print_success "Found docker-compose.yml in $app_path" >&2
}

# ============================================================================
# URL Configuration Functions
# ============================================================================

build_test_url() {
    local domain="$1"
    local port="$2"

    echo "http://${domain}:${port}"
}

# ============================================================================
# Docker Operations
# ============================================================================

get_main_container_name() {
    local app_path="$1"
    local compose_file="$app_path/docker-compose.yml"

    # Find the main application container by checking which running containers have port mappings
    # This is a positive selection approach: query Docker directly for containers with exposed ports

    # Step 1: Get all container names from the docker-compose file
    local all_containers=$(grep "container_name:" "$compose_file" | sed 's/.*container_name:[[:space:]]*//; s/[[:space:]]*$//')

    # Step 2: For each container, check if it has port mappings and get the lowest host port
    local containers_with_ports=()

    while IFS= read -r container_name; do
        [ -z "$container_name" ] && continue

        # Check if container exists and get its port mappings
        # Format: "0.0.0.0:8080->80/tcp" or ":::8080->80/tcp"
        local ports=$(docker ps --filter "name=^${container_name}$" --format "{{.Ports}}" 2>/dev/null)

        if [ -n "$ports" ]; then
            # Extract the lowest host port number from the port mappings
            # Port format examples: "0.0.0.0:8080->80/tcp", "0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp"
            local host_port=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+|:::[0-9]+' | grep -oE '[0-9]+' | sort -n | head -1)

            if [ -n "$host_port" ]; then
                containers_with_ports+=("${host_port}:${container_name}")
            fi
        fi
    done <<< "$all_containers"

    # Step 3: If we found containers with ports, select the one with the lowest port number
    if [ ${#containers_with_ports[@]} -gt 0 ]; then
        # Sort by port number and get the container name with the lowest port
        local selected=$(printf '%s\n' "${containers_with_ports[@]}" | sort -n | head -1 | cut -d: -f2-)
        echo "$selected"
        return 0
    fi

    # Step 4: Fallback to old exclusion-based logic for backward compatibility
    # This handles cases where containers aren't running yet
    print_warning "No running containers with port mappings found, falling back to exclusion-based detection" >&2

    local container_name=$(grep "container_name:" "$compose_file" | grep -v -E "(mariadb|mysql|postgres|_db|redis)" | head -1 | sed 's/.*container_name:[[:space:]]*//; s/[[:space:]]*$//')

    if [ -z "$container_name" ]; then
        # Final fallback: just get the first container_name
        container_name=$(grep "container_name:" "$compose_file" | head -1 | sed 's/.*container_name:[[:space:]]*//; s/[[:space:]]*$//')
    fi

    echo "$container_name"
}

docker_compose_up() {
    local app_path="$1"
    local domain="$2"
    local port="$3"

    print_step "Starting application with docker-compose..."
    cd "$app_path"
    # Export environment variables for docker-compose substitution
    export TEST_DOMAIN="$domain"
    export TEST_PORT="$port"
    docker-compose up -d
    cd - > /dev/null
    print_success "Application started"
}

docker_compose_down() {
    local app_path="$1"

    print_step "Stopping application..."
    cd "$app_path"
    docker-compose down
    cd - > /dev/null
    print_success "Application stopped"
}

wait_for_container_ready() {
    local container_name="$1"
    local max_wait="${2:-60}"
    local wait_count=0

    print_step "Waiting for container to be ready..."

    while [ $wait_count -lt $max_wait ]; do
        if docker ps --filter "name=${container_name}" --filter "status=running" | grep -q "$container_name"; then
            # Container is running, wait a bit more for initialization
            sleep 5
            print_success "Container is ready"
            return 0
        fi

        wait_count=$((wait_count + 1))
        echo -n "."
        sleep 1
    done

    echo ""
    print_error "Container failed to become ready after ${max_wait} seconds"
    return 1
}

# Wait for application to be fully initialized by polling HTTP endpoint
wait_for_app_ready() {
    local container_name="$1"
    local max_wait="${2:-180}"  # Default 3 minutes for apps like Moodle
    local wait_count=0
    local check_interval=5

    print_step "Waiting for application to be fully initialized..."

    # Get the port mapping for the container
    # Use sed instead of grep -P for macOS compatibility
    local port=$(docker port "$container_name" 2>/dev/null | grep '0.0.0.0:' | head -1 | sed -E 's/.*0.0.0.0:([0-9]+).*/\1/')

    if [ -z "$port" ]; then
        # Fallback: try to get port from docker-compose
        port="8080"
    fi

    while [ $wait_count -lt $max_wait ]; do
        # Try to make an HTTP request to the application
        if curl -sf "http://localhost:${port}/" >/dev/null 2>&1; then
            echo ""
            print_success "Application is ready and responding to HTTP requests"
            return 0
        fi

        wait_count=$((wait_count + check_interval))
        echo -n "."
        sleep $check_interval
    done

    echo ""
    print_error "Application failed to become ready after ${max_wait} seconds"
    return 1
}

# ============================================================================
# Log Verification
# ============================================================================

check_logs_for_url_change() {
    local container_name="$1"
    local old_url="$2"
    local new_url="$3"

    print_step "Checking container logs for URL change detection..."

    # Get recent logs (last 100 lines)
    local logs=$(docker logs --tail 100 "$container_name" 2>&1)

    # Look for URL change indicators
    local found_change=false

    if echo "$logs" | grep -q "URL has changed\|SITE_URL has changed\|PUBLIC_URL has changed"; then
        found_change=true
        print_success "Found URL change detection in logs"
    fi

    # Escape special characters in URLs for grep (use -F for fixed string matching)
    if echo "$logs" | grep -qF "$old_url"; then
        print_info "Found old URL in logs: $old_url"
    fi

    if echo "$logs" | grep -qF "$new_url"; then
        print_info "Found new URL in logs: $new_url"
    fi

    # Display relevant log excerpts
    echo ""
    print_info "Relevant log excerpts:"
    echo "----------------------------------------"
    echo "$logs" | grep -E "(URL|url|Checking|Updating|changed)" | tail -20
    echo "----------------------------------------"
    echo ""

    if [ "$found_change" = true ]; then
        return 0
    else
        print_warning "Could not find explicit URL change detection message in logs"
        print_info "This might be normal if the URL didn't actually change"
        return 1
    fi
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    local app_path="$1"

    print_header "Cleanup"

    # Stop any running containers
    print_step "Stopping application..."
    cd "$app_path"
    docker-compose down 2>/dev/null || true
    cd - > /dev/null

    # Unset environment variables
    unset TEST_DOMAIN
    unset TEST_PORT

    print_success "Cleanup complete"
}

# ============================================================================
# Main Test Logic
# ============================================================================

run_url_update_test() {
    local app_path="$1"

    print_header "Docker Application URL Update Test"
    print_info "Testing application: $app_path"

    # Step 1: Validate
    print_header "Step 1: Validation"
    validate_app_directory "$app_path"

    # Step 2: Get container name
    print_header "Step 2: Get Container Information"
    local container_name=$(get_main_container_name "$app_path")
    print_info "Main container: $container_name"

    # Step 3: Build test URLs
    local url_1=$(build_test_url "$TEST_DOMAIN_1" "$TEST_PORT")
    local url_2=$(build_test_url "$TEST_DOMAIN_2" "$TEST_PORT")
    print_info "Test URL 1 (initial): $url_1"
    print_info "Test URL 2 (changed): $url_2"

    # Step 4: Start application with initial URL
    print_header "Step 3: Start Application (Initial URL)"
    print_info "Starting with URL: $url_1"
    docker_compose_up "$app_path" "$TEST_DOMAIN_1" "$TEST_PORT"
    wait_for_container_ready "$container_name" 90
    wait_for_app_ready "$container_name" 180

    # Step 5: Stop the application
    print_header "Step 4: Stop Application"
    docker_compose_down "$app_path"

    # Step 6: Restart with changed URL
    print_header "Step 5: Restart Application (Changed URL)"
    print_info "Starting with new URL: $url_2"
    docker_compose_up "$app_path" "$TEST_DOMAIN_2" "$TEST_PORT"
    wait_for_container_ready "$container_name" 90
    wait_for_app_ready "$container_name" 180

    # Step 7: Check logs for URL change detection
    print_header "Step 6: Verify URL Change Detection"
    local test_passed=false
    if check_logs_for_url_change "$container_name" "$url_1" "$url_2"; then
        test_passed=true
    fi

    # Step 8: Test reverse change (optional)
    print_header "Step 7: Test Reverse URL Change (Optional)"
    print_info "Changing URL back to original domain..."

    # Stop the application
    docker_compose_down "$app_path"

    # Restart with original URL
    docker_compose_up "$app_path" "$TEST_DOMAIN_1" "$TEST_PORT"
    wait_for_container_ready "$container_name" 90
    wait_for_app_ready "$container_name" 180

    # Check logs again
    if check_logs_for_url_change "$container_name" "$url_2" "$url_1"; then
        print_success "Reverse URL change also detected successfully"
    fi

    # Step 9: Cleanup
    docker_compose_down "$app_path"
    cleanup "$app_path"

    # Step 10: Print summary
    print_header "Test Summary"
    echo ""
    print_info "Application: $app_path"
    print_info "Test URL 1 (initial): $url_1"
    print_info "Test URL 2 (changed): $url_2"
    echo ""

    if [ "$test_passed" = true ]; then
        print_success "✓ TEST PASSED: URL change detection is working correctly"
        echo ""
        return 0
    else
        print_error "✗ TEST FAILED: URL change detection may not be working"
        print_info "Please check the application logs manually"
        echo ""
        return 1
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Validate arguments
    validate_arguments "$@"

    # Parse arguments and set global configuration
    parse_arguments "$@"

    # Get app path (relative to current directory)
    local app_path="$1"

    # Run the test
    if run_url_update_test "$app_path"; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"



