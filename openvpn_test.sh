#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

#
# An advanced script to test multiple OpenVPN configurations one by one.
# Each test runs in an isolated network namespace to prevent conflicts.
# The script handles interactive and cached credential input.
#
# Usage: sudo ./openvpn_test.sh <timeout_in_seconds> <path_to_config_directory>
# Example: sudo ./openvpn_test.sh 30 ./
#

# --- Configuration ---
# The IP address to ping to verify a successful connection.
TEST_IP="8.8.8.8"
# The name for our temporary network namespace.
NAMESPACE="vpn-test-ns"
# Temporary files for caching credentials and storing logs.
CRED_FILE="/tmp/vpn_credentials.txt"
LOG_FILE="/tmp/openvpn_test.log"

# --- Script Body ---

# Check if the script is run as root, which is required for network operations.
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if the correct number of arguments was provided.
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <timeout_in_seconds> <path_to_config_directory>"
    exit 1
fi

# Check for required commands before starting.
for cmd in openvpn ip iptables sysctl; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed. Please install it to continue."
        exit 1
    fi
done

TIMEOUT=$1
CONFIG_DIR=$2

# Check if the config directory exists.
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Directory '$CONFIG_DIR' not found."
    exit 1
fi

# A function to ensure cleanup happens, even if the script is interrupted.
cleanup() {
    echo -e "\nCleaning up..."
    # Kill any lingering OpenVPN process.
    # Using pkill is a reliable way to find and stop the process.
    pkill -f "openvpn --config" &>/dev/null || true

    # Delete the network namespace.
    ip netns del $NAMESPACE &>/dev/null || true

    # Delete the virtual ethernet interface.
    ip link del veth-wsl &>/dev/null || true

    # Clear IP tables rules.
    iptables -t nat -F

    # Disable IP forwarding.
    sysctl -q -w net.ipv4.ip_forward=0

    # Remove temporary files.
    rm -f "$CRED_FILE" "$LOG_FILE"

    echo "Cleanup complete."
}

# Set a trap to call the cleanup function on script exit (EXIT) or interrupt (INT TERM).
trap cleanup EXIT INT TERM

# Enable IP forwarding to allow the namespace to access the internet.
sysctl -q -w net.ipv4.ip_forward=1
# Clear any previous iptables rules.
iptables -t nat -F
# Apply masquerading to NAT the traffic from the namespace.
iptables -t nat -A POSTROUTING -s 192.168.200.0/24 -o eth0 -j MASQUERADE

# Loop through all files ending with .ovpn in the specified directory.
for config_file in "$CONFIG_DIR"/*.ovpn; do
    # Skip iteration if no .ovpn files are present to prevent errors.
    [ -e "$config_file" ] || continue

    echo "=================================================="
    echo "Testing configuration: $(basename "$config_file")"
    echo "=================================================="

    # This inner loop allows retrying the same config if auth fails.
    while true; do
        # --- Credential Handling ---
        # If a config requires authentication and the credential file doesn't exist, prompt the user.
        if grep -q "auth-user-pass" "$config_file" && [ ! -f "$CRED_FILE" ]; then
            echo "This configuration requires credentials."
            read -p "Enter Username: " username
            read -s -p "Enter Password: " password
            echo # Add a newline after the hidden password prompt.
            
            # Store credentials in the file.
            echo "$username" > "$CRED_FILE"
            echo "$password" >> "$CRED_FILE"
            chmod 600 "$CRED_FILE" # Set secure permissions.
            echo "Credentials cached for subsequent tests."
        fi

        # --- Setup ---
        # Ensure no old namespace exists from a failed previous run.
        ip netns del $NAMESPACE &>/dev/null || true

        # Create a pair of virtual ethernet devices.
        ip link add veth-ns type veth peer name veth-wsl
        ip link set veth-wsl up
        # Assign an IP to the host-side of the veth pair.
        ip addr add 192.168.200.1/24 dev veth-wsl

        # Create a new, isolated network namespace for the test.
        echo "Creating network namespace: $NAMESPACE"
        ip netns add $NAMESPACE

        # Configure the namespace-side of the veth pair.
        ip link set veth-ns netns $NAMESPACE
        ip netns exec $NAMESPACE ip link set lo up
        ip netns exec $NAMESPACE ip link set veth-ns up
        ip netns exec $NAMESPACE ip addr add 192.168.200.2/24 dev veth-ns
        ip netns exec $NAMESPACE ip route add default via 192.168.200.1

        # --- Connection Attempt ---
        # Start OpenVPN in the background within the namespace.
        echo "Starting OpenVPN..."
        ip netns exec $NAMESPACE openvpn --config "$config_file" --auth-user-pass "$CRED_FILE" --log "$LOG_FILE" --daemon
        
        echo "Waiting for VPN connection (timeout: $TIMEOUT seconds)..."
        connected=false
        # Poll for connection success by checking for the 'tun0' interface.
        for ((i=1; i<=$TIMEOUT; i++)); do
            if ip netns exec $NAMESPACE ip link show tun0 &>/dev/null; then
                # A more robust check for 'Initialization Sequence Completed' might be needed
                # if the interface comes up before the connection is fully ready.
                echo "VPN interface 'tun0' is UP."
                connected=true
                break
            fi
            sleep 1
            echo -n "."
        done
        echo # Newline after the dots.

        # --- Verification and Result ---
        if [ "$connected" = true ]; then
            echo "Connection established. Verifying internet access..."
            # Ping the test IP from within the namespace.
            if ip netns exec $NAMESPACE ping -c 3 -W 5 $TEST_IP &>/dev/null; then
                echo "SUCCESS: Ping to $TEST_IP was successful."
                break # Success, move to the next config.
            else
                echo "FAILURE: Connected, but could not reach the internet via ping."
                break # Failure, move to the next config.
            fi
        else
            echo "FAILURE: Connection timed out."
            # Check the log for common errors like authentication failure.
            if grep -qi "auth failed" "$LOG_FILE"; then
                echo "Authentication failed. Removing cached credentials."
                rm -f "$CRED_FILE"
                # The 'while' loop will now repeat, prompting for new credentials.
            else
                echo "See log for details: $LOG_FILE"
                cat "$LOG_FILE" # Display the log for debugging.
                break # Failure, move to the next config.
            fi
        fi
    done # End of the inner 'while' loop for retries.

    # --- Teardown for this specific config test ---
    echo "Stopping OpenVPN and cleaning up for this configuration..."
    # Kill the daemonized OpenVPN process.
    pkill -f "openvpn --config $config_file" &>/dev/null || true
    ip netns del $NAMESPACE &>/dev/null || true
    ip link del veth-wsl &>/dev/null || true
    echo "Done."
    echo
done

echo "All configurations tested."
# The 'trap' will handle the final cleanup.