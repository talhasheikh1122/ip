#!/bin/bash
# Script must be running from root
if [ "$EUID" -ne 0 ];
  then echo "Please run as root";
  exit 1;
fi;

# Program help info for users
function usage() { echo "Usage: $0  [-s | --subnet <16|32|48|64|80|96|112> proxy subnet (default 64)] 
                                    [-c | --proxy-count <number> count of proxies] 
                                    [-u | --username <string> proxy auth username] 
                                    [-p | --password <string> proxy password]
                                    [--random <bool> generate random username/password for each IPv4 backconnect proxy instead of predefined (default false)] 
                                    [-t | --proxies-type <http|socks5> result proxies type (default http)]
                                    [-r | --rotating-interval <0-59> proxies extarnal address rotating time in minutes (default 0, disabled)]
                                    [--start-port <3128-65536> start port for backconnect ipv4 (default 3128)]
                                    [-l | --localhost <bool> allow connections only for localhost (backconnect on 127.0.0.1)]
                                    [-m | --ipv6-mask <string> constant ipv6 address mask, to which the rotated part is added (or gateaway)
                                          use only if the gateway is different from the subnet address]
                                    [-i | --interface <string> full name of ethernet interface, on which IPv6 subnet was allocated
                                          automatically parsed by default, use ONLY if you have non-standard/additional interfaces on your server]
                                    [-f | --backconnect-proxies-file <string> path to file, in which backconnect proxies list will be written
                                          when proxies start working (default \`~/proxyserver/backconnect_proxies.list\`)]
                                    [-d | --disable-inet6-ifaces-check <bool> disable /etc/network/interfaces configuration check & exit when error
                                          use only if configuration handled by cloud-init or something like this (for example, on Vultr servers)]
                                    " 1>&2; exit 1; }

options=$(getopt -o ldhs:c:u:p:t:r:m:f:i: --long help,localhost,disable-inet6-ifaces-check,random,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file: -- "$@")

# Throw error and chow help message if user don't provide any arguments
if [ $? != 0 ] ; then echo "Error: no arguments provided. Terminating..." >&2 ; usage ; fi;

#  Parse command line options
eval set -- "$options"

# Set default values for optional arguments
subnet=64
proxies_type="http"
start_port=3128
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
  echo $1 1>&2;
  echo -e "$1\n" &>> $script_log_file;
}

function echo_log_err_and_exit(){
  echo_log_err "$1";
  exit 1;
}

# Check validity of user provided arguments
re='^[0-9]+$'
if ! [[ "$subnet" =~ $re ]]; then echo_log_err_and_exit "Error: subnet must be a number"; fi;
if [ "$subnet" -gt 128 ] || [ "$subnet" -lt 16 ]; then echo_log_err_and_exit "Error: subnet value out of range (16-128)"; fi;
if ! [[ "$proxy_count" =~ $re ]]; then echo_log_err_and_exit "Error: proxy count must be a number"; fi;
if ! [[ "$start_port" =~ $re ]]; then echo_log_err_and_exit "Error: start port must be a number"; fi;
if [ "$start_port" -gt 65536 ] || [ "$start_port" -lt 3128 ]; then echo_log_err_and_exit "Error: start port value out of range (3128-65536)"; fi;
if [ "$rotating_interval" -gt 59 ] || [ "$rotating_interval" -lt 0 ]; then echo_log_err_and_exit "Error: rotating interval value out of range (0-59)"; fi;
if ! [[ "$subnet_mask" =~ ^[a-f0-9\:]+$ ]]; then echo_log_err_and_exit "Error: ipv6 mask must be a hexadecimal number with delimiters"; fi;
if [ "$interface_name" == "" ]; then echo_log_err_and_exit "Error: can't parse global network interface name"; fi;
if [ ! -d "$(dirname "$backconnect_proxies_file")" ]; then echo_log_err_and_exit "Error: can't find directory $(dirname "$backconnect_proxies_file")"; fi;
if [ "$proxies_type" != "http" ] && [ "$proxies_type" != "socks5" ]; then echo_log_err_and_exit "Error: unknown proxy type"; fi;

function is_valid_ip(){
  if [[ "$1" =~ ^(([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then return 0; else return 1; fi;
}

function create_random_string(){
  tr -dc A-Za-z0-9 </dev/urandom | head -c "$1" ; echo ''
}

function delete_file_if_exists(){
  if test -f "$1"; then rm "$1"; fi;
}

# DONT use before curl package is installed
function get_backconnect_ipv4(){
  if [ "$use_localhost" = true ]; then echo "127.0.0.1"; return; fi;

  local maybe_ipv4=$(ip addr show "$interface_name" | awk '$1 == "inet" {gsub(/\/.*$/, "", $2); print $2}')
  if is_valid_ip "$maybe_ipv4"; then echo "$maybe_ipv4"; return; fi;

  if is_package_installed "curl"; then
    maybe_ipv4=$(curl https://ipinfo.io/ip)
    if is_valid_ip "$maybe_ipv4"; then echo "$maybe_ipv4"; return; fi;
  fi;

  echo_log_err_and_exit "Error: curl package not installed and cannot parse valid IP from interface info";
}


function check_ipv6(){
  # Check is ipv6 enabled or not
  if test -f /proc/net/if_inet6; then
	  echo "IPv6 interface is enabled";
  else
	  echo_log_err_and_exit "Error: inet6 (ipv6) interface is not enabled. Enable IP v6 on your system.";
  fi;

  if [[ $(ip -6 addr show scope global) ]]; then
    echo "IPv6 global address is allocated on server successfully";
  else
    echo_log_err_and_exit "Error: IPv6 global address is not allocated on server, allocate it or contact your VPS/VDS support.";
  fi;

  local ifaces_config="/etc/network/interfaces";
  if [ "$inet6_network_interfaces_configuration_check" = true ]; then
    if [ ! -f "$ifaces_config" ]; then echo_log_err_and_exit "Error: interfaces config ($ifaces_config) doesn't exist"; fi;
    
    if grep 'inet6' "$ifaces_config" > /dev/null; then
      echo "Network interfaces for IPv6 configured correctly";
    else
      echo_log_err_and_exit "Error: $ifaces_config has no inet6 (IPv6) configuration.";
    fi;
  fi;

  if [[ $(ping6 -c 1 google.com) != *"Network is unreachable"* ]]; then 
    echo "Test ping google.com using IPv6 successfully";
  else
    echo_log_err_and_exit "Error: test ping google.com through IPv6 failed, network is unreachable.";
  fi; 

}

# Install required libraries
function install_requred_packages(){
  apt update &>> "$script_log_file"

  requred_packages=("make" "g++" "wget" "curl" "cron")
  local package
  for package in "${requred_packages[@]}"; do
    if ! is_package_installed "$package"; then
      apt install "$package" -y &>> "$script_log_file"
      if ! is_package_installed "$package"; then
        echo_log_err_and_exit "Error: cannot install \"$package\" package";
      fi;
    fi;
  done;

  echo -e "\nAll required packages installed successfully";
}

function install_3proxy(){

  mkdir -p "$proxy_dir" && cd "$proxy_dir"

  echo -e "\Installing proxy server ...";
  ( # Install proxy server
  wget https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz &> /dev/null
  tar -xf 0.9.4.tar.gz
  rm 0.9.4.tar.gz
  cd 3proxy-0.9.4
  make -f Makefile.Linux &>> "$script_log_file"
  if [[ $? != 0 ]]; then
    echo_log_err_and_exit "Error: make -f Makefile.Linux exited with non-zero status code"
  fi;
  make -f Makefile.Linux install &>> "$script_log_file"
  if [[ $? != 0 ]]; then
    echo_log_err_and_exit "Error: make -f Makefile.Linux install exited with non-zero status code"
  fi;
  );

  echo "Proxy server installed successfully"
}

function prepare_backconnect_proxy_script(){
  local backconnect_proxy_script="backconnect.sh"

  echo -e "#!/bin/bash" > "$backconnect_proxy_script"
  echo -e "\n# Save full path to script dir" >> "$backconnect_proxy_script"
  echo -e "script_dir=\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)" >> "$backconnect_proxy_script"
  echo -e "\n# Kill previous instances of 3proxy" >> "$backconnect_proxy_script"
  echo -e "killall 3proxy 2> /dev/null" >> "$backconnect_proxy_script"

  echo -e "\n# Set path to 3proxy config" >> "$backconnect_proxy_script"
  echo -e "proxy_cfg=\"\$script_dir/3proxy.cfg\"" >> "$backconnect_proxy_script"

  echo -e "\n# Launch 3proxy" >> "$backconnect_proxy_script"
  echo -e "3proxy \"\$proxy_cfg\"" >> "$backconnect_proxy_script"

  chmod +x "$backconnect_proxy_script"
}

function get_ipv6_subnet_part_from_addr(){
  echo "$1" | awk -F':' '{ print $1":"$2":"$3":"$4":"$5 }';
}

function get_random_ipv6_subnet_part(){
  cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 16 | head -n 1;
}

function increment_ipv6(){
  local ipv6="$1"
  local parts=($(echo $ipv6 | sed -e 's/::/:!:/g' -e 's/:/ /g' -e 's/!/ /g'))
  local mask="$2"

  # Initialize IPv6 address parts
  local -a ip_parts
  for part in ${parts[@]}; do
    ip_parts+=("$part")
  done

  local i
  for ((i=(${#ip_parts[@]} - 1); i >= 0; i--)); do
    local val="${ip_parts[$i]}"
    if [[ "$val" == "!" ]]; then
      ip_parts[$i]=""
      continue
    fi

    local sum=$((0x$val + 1))
    if [[ $sum -gt 65535 ]]; then
      ip_parts[$i]="0"
    else
      ip_parts[$i]=$(printf '%04x' $sum)
      break
    fi
  done

  local ipv6_new="${ip_parts[@]}"
  ipv6_new=$(echo "$ipv6_new" | sed -e 's/ /:/g')
  echo "$ipv6_new"
}

function generate_ipv6_subnets(){
  local ipv6_mask="$1"
  local ipv6_gateway="$2"
  local proxy_count="$3"
  local subnet_part=$(get_ipv6_subnet_part_from_addr "$ipv6_mask")

  echo -e "# Generated by ipv6-proxy-generator script" > "$proxy_cfg_file"
  echo -e "# IPv6 proxy config" >> "$proxy_cfg_file"
  echo -e "# Written for $interface_name network interface" >> "$proxy_cfg_file"
  echo -e "# Using IPv6 subnet: $ipv6_mask" >> "$proxy_cfg_file"
  echo -e "# Gateway IPv6 address: $ipv6_gateway" >> "$proxy_cfg_file"
  echo -e "# Subnet part: $subnet_part" >> "$proxy_cfg_file"
  echo -e "# Generating $proxy_count proxies" >> "$proxy_cfg_file"

  local i
  for ((i=1; i<=proxy_count; i++)); do
    local ipv6_proxy=$(increment_ipv6 "$subnet_part" "$i")
    echo "proxy -6 -n -a -p$start_port -e$ipv6_proxy" >> "$proxy_cfg_file"
  done

  echo -e "\n# Allow all connections" >> "$proxy_cfg_file"
  echo "allow *" >> "$proxy_cfg_file"
}

function add_auth_to_ipv6_proxies(){
  local username="$1"
  local password="$2"

  echo -e "\n# Adding auth to IPv6 proxies" >> "$proxy_cfg_file"
  echo -e "auth iponly" >> "$proxy_cfg_file"
  echo -e "users $(echo $username):$(echo $password)" >> "$proxy_cfg_file"
}

# Main script logic
echo_log_err "Started at: $(date)"

# Install required packages
install_requred_packages

# Check IPv6 configuration
check_ipv6

# Get external IPv4 address
external_ipv4=$(get_backconnect_ipv4)

# Create proxy dir
proxy_dir="$HOME/proxyserver"
mkdir -p "$proxy_dir" &>> "$script_log_file"

# Install proxy server
install_3proxy

# Prepare backconnect proxy script
prepare_backconnect_proxy_script

# Create 3proxy config file
proxy_cfg_file="$proxy_dir/3proxy.cfg"
delete_file_if_exists "$proxy_cfg_file"
generate_ipv6_subnets "$subnet_mask" "$external_ipv4" "$proxy_count"

# Add authentication to proxies if necessary
if [ "$auth" = true ]; then
  if [ "$use_random_auth" = true ]; then
    username="$(create_random_string 8)"
    password="$(create_random_string 16)"
  fi;
  add_auth_to_ipv6_proxies "$username" "$password"
fi;

# Log script execution info
echo -e "\n\nDone at: $(date)\n" &>> $script_log_file

# Start proxy server
./backconnect.sh
