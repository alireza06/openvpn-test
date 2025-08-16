#!/bin/bash

# set -euo pipefail

# --- Configuration ---
# Directories for sorting the tested VPN configurations.
SUCCESS_DIR="./success_configs"
FAILED_DIR="./failed_configs"
# Main log file for the entire test run.
LOG_FILE="/tmp/vpn_test_log.txt"
# File to cache VPN credentials.
CRED_FILE="/tmp/vpn_creds.txt"
# IP to ping for verifying internet connectivity.
TEST_IP="1.1.1.1"

# --- Functions ---

# A function to ensure cleanup happens, even if the script is interrupted.
cleanup() {
    echo -e "\n🧹 Cleaning up..."
    # Kill all running OpenVPN processes started by this script.
    pkill -f "openvpn --config" || true
    # Delete all network namespaces that might have been created.
    ip -all netns delete
    # Delete the network bridge.
    ip link delete br0 &>/dev/null || true
    # Clear all iptables NAT rules.
    iptables -t nat -F
    # Disable IP forwarding.
    sysctl -q -w net.ipv4.ip_forward=0
    # Remove temporary files.
    rm -f "$CRED_FILE" "$LOG_FILE"
    echo "Cleanup complete."
}

# The main worker function to test a single OpenVPN configuration.
run_config() {
    local config_file="$1"
    local id="$2"
    local main_log_file="$3"
    local timeout_seconds="$4"
    local config_name
    config_name=$(basename "$config_file" .ovpn)
    local ns="vpnns_${id}_${config_name}"
    local log_file_ns="/tmp/openvpn_log_${ns}.log"
    local pid_file="/tmp/openvpn_${ns}.pid"

    echo "🧪 [$ns] Testing $config_file"

    # Check if the config requires authentication and set the appropriate option.
    local auth_option=""
    if grep -q "auth-user-pass" "$config_file"; then
        auth_option="--auth-user-pass $CRED_FILE"
        echo "   -> Using credentials."
    fi

    # Create a dedicated network namespace for this test.
    ip netns add "$ns"
    # Create a virtual ethernet pair to connect the namespace to the bridge.
    ip link add "veth$id" type veth peer name "veth-ns" netns "$ns"
    # Attach the host-side of the veth pair to the bridge.
    ip link set "veth$id" master br0
    ip link set "veth$id" up

    # Configure the network inside the namespace.
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip link set "veth-ns" up
    # Assign a unique IP address to the namespace's veth interface.
    ip netns exec "$ns" ip addr add 172.17.$(((id / 254) + 1)).$(((id % 254) + 2))/20 dev "veth-ns"
    ip netns exec "$ns" ip route add default via 172.17.1.1

    # Start OpenVPN in the background within the namespace.
    ip netns exec "$ns" openvpn --config "$config_file" $auth_option \
        --daemon \
        --log "$log_file_ns" \
        --writepid "$pid_file" \
        --verb 3 # Verb 3 provides a good balance of info.

    local connected=false
    # Poll for connection success.
    for ((i = 1; i <= timeout_seconds; i++)); do
        # Check if OpenVPN has completed its initialization sequence.
        if grep -q 'Initialization Sequence Completed' "$log_file_ns"; then
            # Verify internet connectivity by pinging the test IP.
            if ip netns exec "$ns" ping -c 1 -W 5 "$TEST_IP" &>/dev/null; then
                echo "✅ [$ns] SUCCESS: $config_name"
                echo "✅ [$ns] SUCCESS: $config_name" >>"$main_log_file"
                cp "$config_file" "$SUCCESS_DIR/"
                connected=true
                break
            else
                echo "⚠️ [$ns] VPN connected, but no internet: $config_name"
                echo "⚠️ [$ns] VPN connected, but no internet: $config_name" >>"$main_log_file"
                cp "$config_file" "$FAILED_DIR/"
                break
            fi
        fi
        sleep 1
    done

    if [ "$connected" = false ]; then
        echo "❌ [$ns] FAILED to connect: $config_name"
        echo "❌ [$ns] FAILED to connect: $config_name" >>"$main_log_file"
        # Append the specific log for this failure to the main log file.
        echo "--- Log for $ns ---" >>"$main_log_file"
        cat "$log_file_ns" >>"$main_log_file"
        echo "--- End Log for $ns ---" >>"$main_log_file"
        cp "$config_file" "$FAILED_DIR/"
    fi

    # Clean up resources for this specific test.
    kill "$(cat "$pid_file")" &>/dev/null || true
    rm -f "$pid_file" "$log_file_ns"
    ip link delete "veth$id" &>/dev/null || true
    ip netns delete "$ns" &>/dev/null || true
}

# --- Main Script ---

# Exit on interrupt, call the cleanup function.
trap cleanup EXIT INT TERM

# Check for root privileges.
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Validate arguments.
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <timeout_in_seconds> <path_to_config_directory> <max_parallel_tests>"
    exit 1
fi

TIMEOUT=$1
CONFIG_DIR=$2
MAX_PARALLEL=$3

# Check for required commands.
for cmd in openvpn ip iptables sysctl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# Initial cleanup and setup.
echo "Performing initial setup..."
cleanup
rm -rf "$FAILED_DIR" "$SUCCESS_DIR"
mkdir -p "$SUCCESS_DIR" "$FAILED_DIR"
# Create an empty log file.
: >"$LOG_FILE"

# Enable IP forwarding and set up the network bridge for parallel tests.
sysctl -q -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 172.17.0.0/20 -o eth0 -j MASQUERADE
ip link add name br0 type bridge
ip link set br0 up
ip addr add 172.17.1.1/20 dev br0
echo "Network bridge created."

# Get credentials if any config file requires them.
NEEDS_AUTH=false
for config in "$CONFIG_DIR"/*.ovpn; do
    if [ -f "$config" ] && grep -q "auth-user-pass" "$config"; then
        NEEDS_AUTH=true
        break
    fi
done

if [ "$NEEDS_AUTH" = true ] && [ ! -f "$CRED_FILE" ]; then
    echo "Some configs require a username and password."
    read -p "Enter Username: " VPN_USER
    read -s -p "Enter Password: " VPN_PASS
    echo
    echo -e "$VPN_USER\n$VPN_PASS" >"$CRED_FILE"
    chmod 600 "$CRED_FILE"
fi

# Find all .ovpn files and store them in an array.
mapfile -d $'\0' configs < <(find "$CONFIG_DIR" -type f -name "*.ovpn" -print0)
total_configs=${#configs[@]}

if [ "$total_configs" -eq 0 ]; then
    echo "No .ovpn files found in $CONFIG_DIR"
    exit 0
fi

echo "Found $total_configs configurations to test."

# --- Parallel Job Scheduler ---
current_jobs=0
config_index=0
pids=()

while [ $config_index -lt $total_configs ]; do
    if [ $current_jobs -lt $MAX_PARALLEL ]; then
        # Export the function so it's available to subshells.
        export -f run_config
        # Run the worker function in the background.
        run_config "${configs[$config_index]}" "$config_index" "$LOG_FILE" "$TIMEOUT" &
        pids+=($!)
        ((config_index++))
        ((current_jobs++))
    else
        # Wait for any of the background jobs to finish.
        wait -n -p finished_pid
        # Remove the finished PID from the list.
        pids=("${pids[@]/$finished_pid}")
        ((current_jobs--))
    fi
done

# Wait for all remaining jobs to complete.
wait "${pids[@]}"

echo -e "\n🎉 All configs tested."
echo "✔️ Successes stored in: $SUCCESS_DIR"
echo "❌ Failures stored in: $FAILED_DIR"
echo "📄 Full log available at: $LOG_FILE"