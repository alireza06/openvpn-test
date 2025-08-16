# OpenVPN Configuration Tester

This repository provides powerful scripts to test multiple OpenVPN (`.ovpn`) configurations to identify which ones are working correctly. It's an essential tool for anyone who manages multiple VPN profiles and needs to quickly validate them.

The scripts automatically test each configuration in an isolated environment, check for successful connection and internet access, and then sort the configurations into `success` and `failure` folders.

## ✨ Features

- **Isolated Testing**: Each VPN configuration is tested in its own network namespace, preventing any interference between tests or with your main system's network configuration.
- **Sequential and Parallel Testing**:
  - `openvpn_test.sh`: A simple script to test configurations one by one. Ideal for debugging.
  - `openvpn_test_parallel.sh`: A high-performance script that tests multiple configurations concurrently for rapid validation.
- **Credential Handling**: Automatically prompts for and caches username/password if a configuration requires it.
- **Internet Connectivity Check**: Doesn't just check if the VPN connects, but also verifies that you can access the internet through it.
- **Automatic Sorting**: Working configurations are moved to a `success_configs` directory and non-working ones to `failed_configs`.
- **Robust Cleanup**: Automatically cleans up all temporary network interfaces, namespaces, and files, even if the script is interrupted.

## 📦 Dependencies

Before you begin, ensure you have the following command-line tools installed on your Linux system:

- `openvpn`: The core tool for running the VPN connections.
- `iproute2`: Provides the `ip` command, used for managing network namespaces and virtual interfaces.
- `iptables`: Used to set up the necessary network address translation (NAT) rules.
- `sysctl`: Used to enable IP forwarding.

You can typically install these on Debian/Ubuntu with:
```bash
sudo apt-get update
sudo apt-get install openvpn iproute2 iptables procps
```

## 🚀 How to Use

**Important**: These scripts must be run with `sudo` or as the `root` user because they need to create and manage network interfaces and namespaces.

1.  **Place your `.ovpn` files** in a directory. For this example, let's assume you put them in the same directory as the scripts.
2.  **Make the scripts executable**:
    ```bash
    chmod +x openvpn_test.sh
    chmod +x openvpn_test_parallel.sh
    ```

### Testing Sequentially (One-by-One)

Use this script for simple, sequential testing. It's slower but the output is easier to follow for debugging individual configurations.

**Usage:**
```bash
sudo ./openvpn_test.sh <timeout_seconds> <path_to_config_dir>
```

**Example:**
```bash
# Test all .ovpn files in the current directory with a 30-second timeout for each
sudo ./openvpn_test.sh 30 .
```

### Testing in Parallel

Use this for testing a large number of configurations quickly. It creates a network bridge and runs multiple tests at once.

**Usage:**
```bash
sudo ./openvpn_test_parallel.sh <timeout_seconds> <path_to_config_dir> <max_parallel_tests>
```

**Example:**
```bash
# Test all .ovpn files in the current directory with a 30-second timeout,
# running up to 5 tests in parallel.
sudo ./openvpn_test_parallel.sh 30 . 5
```

## ⚙️ How It Works

### Network Isolation

The scripts create a **network namespace** for each VPN test. A namespace is like a virtualized network stack with its own interfaces, routes, and firewall rules. This ensures that when a VPN connection becomes active, it doesn't redirect your entire system's traffic—only the traffic within that specific namespace.

### Parallel Testing (`openvpn_test_parallel.sh`)

To enable parallel testing, the script first creates a **network bridge** (`br0`) on the host. For each VPN test, it creates:
1.  A new network namespace.
2.  A virtual ethernet (veth) pair, which acts like a virtual patch cable.
3.  One end of the "cable" is placed inside the namespace, and the other is connected to the bridge.
4.  This setup allows each namespace to communicate with the host's network (and the internet) via the bridge, while still being isolated from each other.

This architecture allows the script to run many tests at once without them interfering with each other.

## 📋 Output

After running, you will see two new directories:

- `success_configs/`: Contains all the `.ovpn` files that successfully connected and provided internet access.
- `failed_configs/`: Contains all the `.ovpn` files that failed to connect, timed out, or could not provide internet access.

A detailed log file is also created at `/tmp/vpn_test_log.txt`, which can be inspected for troubleshooting.

## 🚨 Troubleshooting

- **"Please run as root"**: The scripts require root privileges. Make sure you are using `sudo`.
- **"Command not found"**: Ensure all dependencies listed above are installed.
- **All tests fail**:
    - Check your machine's primary internet connection.
    - Your firewall might be blocking the connections.
    - The `eth0` interface used in the `iptables` rule might not be your primary network interface. You may need to edit the script to change `eth0` to your correct interface (e.g., `wlan0`).
- **Authentication fails repeatedly**: If you enter the wrong credentials, they will be cached. Delete the `/tmp/vpn_creds.txt` file to be prompted again.

---
*This README was generated by an AI assistant.*
