#!/bin/bash

#
# An advanced script to test multiple OpenVPN configurations within isolated
# network namespaces, with interactive and cached credential handling.
#
# Usage:./test_vpn_configs.sh <timeout_in_seconds> <path_to_config_directory>
# Example: sudo./test_vpn_configs.sh 30./ovpn_configs
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

# Check if the correct number of arguments was provided.
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <timeout_in_seconds> <path_to_config_directory>"
    exit 1
fi

# Check for required commands before starting.
for cmd in openvpn ip; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed. Please install it to continue."
        exit 1
    fi
done

TIMEOUT=$1
CONFIG_DIR=$2

# Check if the config directory exists.
if [ ! -e "$CONFIG_DIR" ]; then
    echo "Error: Directory '$CONFIG_DIR' not found."
    exit 1
fi

# A function to ensure cleanup happens, even if the script is interrupted.
cleanup() {
    echo -e "\nCleaning up..."
    # Kill any lingering OpenVPN process for this test.
    # pkill is a reliable way to find and stop the process. [4, 5]
    pkill -f "openvpn --config" &>/dev/null
    # Delete the network namespace.
    ip netns del $NAMESPACE &>/dev/null
    # Remove temporary files.
    # rm -f "$CRED_FILE" "$LOG_FILE"
    echo "Cleanup complete."
}

# Set a trap to call the cleanup function on script exit or interrupt.
trap cleanup EXIT SIGINT SIGTERM

# Loop through all files ending with.ovpn in the specified directory.
for config_file in "$CONFIG_DIR"/*/*.ovpn; do
    echo "Testing configuration: $config_file"
    # Skip iteration if no .ovpn files are present to prevent errors.
    [ -e "$config_file" ] || continue

    echo "=================================================="
    echo "Testing configuration: $(basename "$config_file")"
    echo "=================================================="

    # This inner loop allows retrying the same config if auth fails.
    while true; do
        # --- Credential Handling ---
        # If the credential file doesn't exist or is empty, prompt the user.
        if [ ! -e  "$CRED_FILE" ]; then
            echo "Credentials not found or invalid. Please provide them."
            read -p "Enter Username: " username
            # Use -s for silent (password) input and -p for a prompt. [1, 2]
            read -sp "Enter Password: " password
            echo # Add a newline after the hidden password prompt.
            
            # Store credentials in the file, username on line 1, password on line 2. [6]
            echo "$username" > "$CRED_FILE"
            echo "$password" >> "$CRED_FILE"
            chmod 600 "$CRED_FILE" # Set secure permissions.
            echo "Credentials saved for next attempts."
        fi

        # --- Setup ---
        # Ensure no old namespace exists from a failed previous run.
        ip netns del $NAMESPACE &>/dev/null

        # Create a new, isolated network namespace for the test.
        echo "Creating network namespace: $NAMESPACE"
        ip netns add $NAMESPACE
        if [ $? -ne 0 ]; then
            echo "FAILURE: Could not create network namespace. Skipping."
            break # Exit inner loop, go to next config.
        fi

        # Bring up the loopback interface inside the namespace (good practice).
        ip netns exec $NAMESPACE ip link set lo up

        # --- Connection Attempt ---
        # Start OpenVPN in the background, using the credentials file and logging the output.
        ip netns exec $NAMESPACE openvpn --config "$config_file" --auth-user-pass "$CRED_FILE" --log "$LOG_FILE" --daemon

        echo "Waiting for VPN connection (timeout: $TIMEOUT seconds)..."
        
        connected=false
        # Poll for a 'tun0' interface to appear and be 'UP' inside the namespace.
        for ((i=1; i<=$TIMEOUT; i++)); do
            if ip netns exec $NAMESPACE ip link show tun0 &>/dev/null && \
                ip netns exec $NAMESPACE ip link show tun0 | grep -q "state UP"; then
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
            # Ping the test IP from within the namespace, with a 5-second timeout.
            if ip netns exec $NAMESPACE timeout 5s ping -c 3 $TEST_IP &>/dev/null; then
                echo "SUCCESS: Ping to $TEST_IP was successful."
                break # Success, exit inner loop and move to next config.
            else
                echo "FAILURE: Connected, but could not reach the internet via ping."
                break # Failure, exit inner loop and move to next config.
            fi
        else
            # If connection timed out, check the log for an authentication failure. [3]
            if grep -q "AUTH_FAILED" "$LOG_FILE"; then
                echo "FAILURE: Authentication failed with the provided credentials."
                rm -f "$CRED_FILE" # Remove bad credentials.
                # The 'while' loop will now repeat for the same config, prompting for new credentials.
            else
                echo "FAILURE: Connection timed out for a reason other than authentication."
                break # Exit inner loop and move to next config.
            fi
        fi

        # --- Teardown for this attempt ---
        pkill -f "openvpn --config $config_file" &>/dev/null
        ip netns del $NAMESPACE &>/dev/null
    done # End of the inner 'while' loop for retries.

    # --- Teardown for this config ---
    echo "Stopping OpenVPN and cleaning up for this configuration..."
    pkill -f "openvpn --config $config_file" &>/dev/null
    ip netns del $NAMESPACE &>/dev/null
    echo "Done."
    echo
done

echo "All configurations tested."
# The 'trap' will handle the final cleanup.