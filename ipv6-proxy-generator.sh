#!/bin/bash
# Script must be running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Program help info for users
function usage() {
  echo "Usage: $0  [-s | --subnet <16|32|48|64|80|96|112> proxy subnet (default 64)] 
                                    [-c | --proxy-count <number> count of proxies] 
                                    [-u | --username <string> proxy auth username] 
                                    [-p | --password <string> proxy password]
                                    [--random <bool> generate random username/password for each IPv4 backconnect proxy instead of predefined (default false)] 
                                    [-t | --proxies-type <http|socks5> result proxies type (default http)]
                                    [-r | --rotating-interval <0-59> proxies extarnal address rotating time in minutes (default 0, disabled)]
                                    [--start-port <80-65536> start port for backconnect ipv4 (default 80)]
                                    [-l | --localhost <bool> allow connections only for localhost (backconnect on 127.0.0.1)]
                                    [-m | --ipv6-mask <string> constant ipv6 address mask, to which the rotated part is added (or gateaway)
                                          use only if the gateway is different from the subnet address]
                                    [-i | --interface <string> full name of ethernet interface, on which IPv6 subnet was allocated
                                          automatically parsed by default, use ONLY if you have non-standard/additional interfaces on your server]
                                    [-f | --backconnect-proxies-file <string> path to file, in which backconnect proxies list will be written
                                          when proxies start working (default \`~/proxyserver/backconnect_proxies.list\`)]
                                    [-d | --disable-inet6-ifaces-check <bool> disable /etc/network/interfaces configuration check & exit when error
                                          use only if configuration handled by cloud-init or something like this (for example, on Vultr servers)]
                                    " 1>&2
  exit 1
}

options=$(getopt -o ldhs:c:u:p:t:r:m:f:i: --long help,localhost,disable-inet6-ifaces-check,random,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file: -- "$@")

# Throw error and chow help message if user don`t provide any arguments
if [ $? != 0 ]; then
  echo "Error: no arguments provided. Terminating..." >&2
  usage
fi

#  Parse command line options
eval set -- "$options"

# Set default values for optional arguments
subnet=64
proxies_type="http"
start_port=80
rotating_interval=0
use_localhost=false
auth=true
use_random_auth=false
inet6_network_interfaces_configuration_check=false
backconnect_proxies_file="default"
# Global network inteface name
interface_name="$(ip -br l | awk '$1 !~ "lo|vir|wl|@NONE" { print $1 }' | awk 'NR==1')"
# Log file for script execution
script_log_file="/var/tmp/ipv6-proxy-generator-logs.log"

while true; do
  case "$1" in
    -h | --help ) usage; shift ;;
    -s | --subnet ) subnet="$2"; shift 2 ;;
    -c | --proxy-count ) proxy_count="$2"; shift 2 ;;
    -u | --username ) user="$2"; shift 2 ;;
    -p | --password ) password="$2"; shift 2 ;;
    -t | --proxies-type ) proxies_type="$2"; shift 2 ;;
    -r | --rotating-interval ) rotating_interval="$2"; shift 2;;
    -m | --ipv6-mask ) subnet_mask="$2"; shift 2;;
    -f | --backconnect_proxies_file ) backconnect_proxies_file="$2"; shift 2;;
    -i | --interface ) interface_name="$2"; shift 2;;
    -l | --localhost ) use_localhost=true; shift ;;
    -d | --disable-inet6-ifaces-check ) inet6_network_interfaces_configuration_check=false; shift ;;
    --start-port ) start_port="$2"; shift 2;;
    --random ) use_random_auth=true; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

function echo_log_err(){
  echo $1 1>&2
  echo -e "$1\n" &>> $script_log_file
}

function echo_log_err_and_exit(){
  echo_log_err "$1"
  exit 1
}

# Check validity of user provided arguments
re='^[0-9]+$'
if ! [[ $proxy_count =~ $re ]]; then
  echo_log_err "Error: Argument -c (proxy count) must be a positive integer number"
  usage
fi

if [ -z $user ] && [ -z $password] && [ $use_random_auth = false ]; then auth=false; fi

if ([ -z $user ] || [ -z $password ]) && [ $auth = true ] && [ $use_random_auth = false ]; then
  echo_log_err "Error: user and password for proxy with auth is required (specify both '--username' and '--password' startup parameters)"
  usage
fi

if ([[ -n $user ]] || [[ -n $password ]]) && [ $use_random_auth = true ]; then
  echo_log_err "Error: don't provide user or password as arguments, if '--random' flag is set."
  usage
fi

if [ $proxies_type != "http" ] && [ $proxies_type != "socks5" ]; then
  echo_log_err "Error: invalid value of '-t' (proxy type) parameter"
  usage
fi

if [ $(expr $subnet % 16) != 0 ]; then
  echo_log_err "Error: invalid value of '-s' (subnet) parameter"
  usage
fi

if [ $rotating_interval -lt 0 ] || [ $rotating_interval -gt 59 ]; then
  echo_log_err "Error: invalid value of '-r' (proxy external ip rotating interval) parameter"
  usage
fi

if [ $start_port -lt 80 ] || [ $start_port -gt 65536 ]; then
  echo_log_err "Error: invalid value of '--start-port' parameter (must be from 80 to 65536)"
  usage
fi

# Check if port 80 is open
function check_port_80() {
  if nc -zv 0.0.0.0 80 &>/dev/null; then
    echo_log_err "Port 80 is open. Proceeding with proxy server setup."
  else
    echo_log_err "Error: Port 80 is not open. Please ensure that port 80 is open before running the proxy server."
    exit 1
  fi
}

# Call the function to check if port 80 is open
check_port_80

# Other functions...

# Your existing functions...

# Main script execution...

# Your existing main script execution...

