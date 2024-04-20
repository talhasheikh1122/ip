#!/bin/bash
# Script must be running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Function to display program usage information for users
function usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -s, --subnet <16|32|48|64|80|96|112>   Proxy subnet (default 64)"
  echo "  -c, --proxy-count <number>             Count of proxies"
  echo "  -u, --username <string>                Proxy auth username"
  echo "  -p, --password <string>                Proxy password"
  echo "  --random <bool>                        Generate random username/password for each IPv4 backconnect proxy instead of predefined (default false)"
  echo "  -t, --proxies-type <http|socks5>      Result proxies type (default http)"
  echo "  -r, --rotating-interval <0-59>         Proxies external address rotating time in minutes (default 0, disabled)"
  echo "  --start-port <80-60000>                Start port for backconnect IPv4 proxies (default 80)"
  echo "  -l, --localhost <bool>                 Allow connections only for localhost (backconnect on 127.0.0.1)"
  echo "  -m, --ipv6-mask <string>               Constant IPv6 address mask, to which the rotated part is added (or gateway). Use only if the gateway is different from the subnet address"
  echo "  -i, --interface <string>               Full name of ethernet interface, on which IPv6 subnet was allocated. Automatically parsed by default. Use ONLY if you have non-standard/additional interfaces on your server"
  echo "  -f, --backconnect-proxies-file <string> Path to file, in which backconnect proxies list will be written when proxies start working (default '~/proxyserver/backconnect_proxies.list')"
  echo "  -d, --disable-inet6-ifaces-check <bool> Disable /etc/network/interfaces configuration check & exit when error. Use only if configuration handled by cloud-init or something similar (e.g., on Vultr servers)"
  exit 1
}

# Parse command line options
options=$(getopt -o ldhs:c:u:p:t:r:m:f:i: --long help,localhost,disable-inet6-ifaces-check,random,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file: -- "$@")
if [ $? != 0 ]; then
  echo "Error: no arguments provided. Terminating..." >&2
  usage
fi

eval set -- "$options"

# Set default values for optional arguments
subnet=64
proxies_type="http"
start_port=80  # Set the default starting port to 80
rotating_interval=0
use_localhost=false
auth=true
use_random_auth=false
inet6_network_interfaces_configuration_check=false
backconnect_proxies_file="default"
# Global network interface name
interface_name="$(ip -br l | awk '$1 !~ "lo|vir|wl|@NONE" { print $1 }' | awk 'NR==1')"
# Log file for script execution
script_log_file="/var/tmp/ipv6-proxy-generator-logs.log"

# Process command line options
while true; do
  case "$1" in
    -h | --help ) usage ;;
    -s | --subnet ) subnet="$2"; shift 2 ;;
    -c | --proxy-count ) proxy_count="$2"; shift 2 ;;
    -u | --username ) user="$2"; shift 2 ;;
    -p | --password ) password="$2"; shift 2 ;;
    -t | --proxies-type ) proxies_type="$2"; shift 2 ;;
    -r | --rotating-interval ) rotating_interval="$2"; shift 2 ;;
    -m | --ipv6-mask ) subnet_mask="$2"; shift 2 ;;
    -f | --backconnect_proxies_file ) backconnect_proxies_file="$2"; shift 2 ;;
    -i | --interface ) interface_name="$2"; shift 2 ;;
    -l | --localhost ) use_localhost=true; shift ;;
    -d | --disable-inet6-ifaces-check ) inet6_network_interfaces_configuration_check=false; shift ;;
    --start-port ) 
      start_port="$2"
      # Check if start_port is within the range 80-60000
      if (( start_port < 80 || start_port > 60000 )); then
        echo "Error: Start port must be between 80 and 60000."
        exit 1
      fi
      shift 2
      ;;
    --random ) use_random_auth=true; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

# Rest of the script...
