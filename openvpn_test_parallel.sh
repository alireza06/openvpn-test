#!/bin/bash

# set -euo pipefail

# Check if the correct number of arguments was provided.
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <timeout_in_seconds> <path_to_config_directory>"
    exit 1
fi

TIMEOUT=$1
CONFIG_DIR=$2

SUCCESS_DIR="./success_configs"
FAILED_DIR="./failed_configs"
LOG_FILE="/tmp/vpn_test_log.txt"
CRED_FILE="/tmp/vpn_creds.txt"
MAX_PARALLEL=10

rm -rf "$FAILED_DIR" "$SUCCESS_DIR"
mkdir -p "$CONFIG_DIR" "$SUCCESS_DIR" "$FAILED_DIR"
: > "$LOG_FILE"

# IP forwarding and NAT (do once)
sysctl -q -w net.ipv4.ip_forward=1
ip -all netns delete
ip link show | grep -E 'veth0_' | awk '{print $2}' | sed 's/[:@].*//g' | xargs -r -n1 ip link delete
iptables -t nat -F
iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -o eth0 -j MASQUERADE

# Get credentials
if [ ! -f "$CRED_FILE" ]; then
    echo "Some configs may require username and password."
    read -p "Username: " VPN_USER
    read -s -p "Password: " VPN_PASS
    echo
    echo -e "$VPN_USER\n$VPN_PASS" > "$CRED_FILE"
fi

# Shared worker function
run_config() {
    local config="$1"
    local id="$2"

    local name
    name=$(basename "$config" .ovpn)
    local ns="vpnns_${id}_${name}"

    echo "🧪 [$ns] Testing $config..."

    ip netns add "$ns"
    ip link add veth0_$id type veth peer name veth1_$id
    ip link set veth1_$id netns "$ns"
    ip addr add 192.168.$id.1/24 dev veth0_$id
    ip link set veth0_$id up
    ip netns exec "$ns" ip addr add 192.168.$id.2/24 dev veth1_$id
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip link set veth1_$id up
    ip netns exec "$ns" ip route add default via 192.168.$id.1

    # Check for auth
    if grep -q "auth-user-pass" "$config"; then
        AUTH_OPTION="--auth-user-pass $CRED_FILE"
    else
        AUTH_OPTION=""
    fi

    # Run VPN
    ip netns exec "$ns" bash -c "
        openvpn --config \"$config\" $AUTH_OPTION \
                --daemon --log /tmp/openvpn_test.log \
                --writepid /tmp/openvpn.pid
        CONNECTED=False
        # Poll for a 'tun0' interface to appear and be 'UP' inside the namespace.
        for ((i=1; i<=${TIMEOUT}*2; i++)); do
            if grep -q 'Initialization Sequence Completed' /tmp/openvpn_test.log; then
                if ping -c 3 -W 3 1.1.1.1 > /dev/null; then
                    cp \"$config\" \"$SUCCESS_DIR/\"
                    echo ✅
                    echo \"[$ns] ✅ $name: SUCCESS\" >> \"$LOG_FILE\"
                    CONNECTED=True
                    break
                else
                    cp \"$config\" \"$FAILED_DIR/\"
                    # echo ⚠️
                    echo \"[$ns] ⚠️ $name: VPN but no internet\" >> \"$LOG_FILE\"
                    break
                fi
            fi
            sleep 0.5
            # echo -n \".\"
        done

        if [ \"\$CONNECTED\" = False ]; then
            cp \"$config\" \"$FAILED_DIR/\"
            echo ❌
            echo \"[$ns] ❌ $name: VPN failed\" >> \"$LOG_FILE\"
            cat /tmp/openvpn_test.log >> \"$LOG_FILE\"
        fi

        kill \$(cat /tmp/openvpn.pid) 2>/dev/null || true
    "

    ip link delete veth0_$id
    ip netns delete "$ns"
    # echo 🧹
    echo "[$ns] 🧹 Done." >> "$LOG_FILE"
}

# Actual parallel job scheduler
mapfile -d $'\0' configs < <(find "$CONFIG_DIR" -name "*.ovpn" -print0 2>/dev/null)
total=${#configs[@]}
next=1

running_pids=()
namespace_ids=()

# echo $total
while (( next <= total )) || (( ${#running_pids[@]} > 0 )); do
    # Fill up to MAX_PARALLEL
    while (( ${#running_pids[@]} < MAX_PARALLEL && next <= total )); do
        config="${configs[(${next}-1)]}"
        ns_id=$next

        echo "Running ns $ns_id ==> "
        run_config "$config" "$ns_id" &
        sleep 0.1
        pid=$!

        running_pids+=($pid)
        namespace_ids+=($ns_id)
        ((next++))
    done

    # Wait for any job to finish
    for i in "${!running_pids[@]}"; do
        pid="${running_pids[$i]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            unset 'running_pids[i]'
            unset 'namespace_ids[i]'
            break
        fi
    done

    # Repack arrays (bash is dumb)
    running_pids=("${running_pids[@]}")
    namespace_ids=("${namespace_ids[@]}")
done

# run_config "${configs[$next]}" 12 

echo -e "\n🎉 All configs tested."
echo "✔️ Successes: $SUCCESS_DIR"
echo "❌ Failures: $FAILED_DIR"
echo "📄 Full log: $LOG_FILE"

# A function to ensure cleanup happens, even if the script is interrupted.
cleanup() {
    echo -e "\nCleaning up..."
    ip netns | awk '{print $1}' | xargs -r -n1 ip netns delete
    ip link show | grep -E 'veth0_' | awk '{print $2}' | sed 's/[:@].*//g' | xargs -r -n1 ip link delete
    iptables -t nat -F
    sysctl -q -w net.ipv4.ip_forward=0
    # Remove temporary files.
    rm -f "$CRED_FILE"
    echo "Cleanup complete."
}

# Set a trap to call the cleanup function on script exit or interrupt.
trap cleanup EXIT