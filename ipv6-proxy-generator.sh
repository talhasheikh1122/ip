#!/bin/bash
# Script must be running from root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root"; 
  exit 1; 
fi;

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
                                    " 1>&2; exit 1; }

options=$(getopt -o ldhs:c:u:p:t:r:m:f:i: --long help,localhost,disable-inet6-ifaces-check,random,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file: -- "$@")

# Throw error and chow help message if user don`t provide any arguments
if [ $? != 0 ] ; then echo "Error: no arguments provided. Terminating..." >&2 ; usage ; fi;

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
  echo $1 1>&2;
  echo -e "$1\n" &>> $script_log_file;
}

function echo_log_err_and_exit(){
  echo_log_err "$1";
  exit 1;
}

# Check validity of user provided arguments
re='^[0-9]+$'
if ! [[ $proxy_count =~ $re ]] ; then
  echo_log_err "Error: Argument -c (proxy count) must be a positive integer number";
  usage;
fi;

if [ -z $user ] && [ -z $password] && [ $use_random_auth = false ]; then auth=false; fi;

if ([ -z $user ] || [ -z $password ]) && [ $auth = true ] && [ $use_random_auth = false ]; then
  echo_log_err "Error: user and password for proxy with auth is required (specify both '--username' and '--password' startup parameters)";
  usage;
fi;

if ([[ -n $user ]] || [[ -n $password ]]) && [ $use_random_auth = true ]; then
  echo_log_err "Error: don't provide user or password as arguments, if '--random' flag is set.";
  usage;
fi;

if [ $proxies_type != "http" ] && [ $proxies_type != "socks5" ] ; then
  echo_log_err "Error: invalid value of '-t' (proxy type) parameter";
  usage;
fi;

if [ $(expr $subnet % 16) != 0 ]; then
  echo_log_err "Error: invalid value of '-s' (subnet) parameter";
  usage;
fi;

if [ $rotating_interval -lt 0 ] || [ $rotating_interval -gt 59 ]; then
  echo_log_err "Error: invalid value of '-r' (proxy external ip rotating interval) parameter";
  usage;
fi;

if [ $start_port -lt 80 ] || (($start_port - $proxy_count > 65536 )); then
  echo_log_err "Wrong '--start-port' parameter value, it must be more than 5000 and '--start-port' + '--proxy-count' must be lower than 65536,
because Linux has only 65536 potentially ports";
  usage;
fi;

if [ -z $subnet_mask ]; then 
  blocks_count=$((($subnet / 16) - 1));
  subnet_mask="$(ip -6 addr|awk '{print $2}'|grep -m1 -oP '^(?!fe80)([0-9a-fA-F]{1,4}:){'$blocks_count'}[0-9a-fA-F]{1,4}'|cut -d '/' -f1)";
fi;

if cat /sys/class/net/$interface_name/operstate 2>&1 | grep -q "No such file or directory"; then
  echo_log_err "Incorrect ethernet interface name \"$interface_name\", provide correct name using parameter '--interface'";
  usage;
fi;

# Define all needed paths to scripts / configs / etc
bash_location="$(which bash)"
# Get user home dir absolute path
cd ~
user_home_dir="$(pwd)"
# Path to dir with all proxies info
proxy_dir="$user_home_dir/proxyserver"
# Path to file with config for backconnect proxy server
proxyserver_config_path="$proxy_dir/3proxy/3proxy.cfg"
# Path to file with all result (external) ipv6 addresses
random_ipv6_list_file="$proxy_dir/ipv6.list"
# Path to file with proxy random usernames/password
random_users_list_file="$proxy_dir/random_users.list"
# Define correct path to file with backconnect proxies list, if it isn't defined by user
if [[ $backconnect_proxies_file == "default" ]]; then backconnect_proxies_file="$proxy_dir/backconnect_proxies.list"; fi;
# Script on server startup (generate random ids and run proxy daemon)
startup_script_path="$proxy_dir/proxy-startup.sh"
# Cron config path (start proxy server after linux reboot and IPs rotations)
cron_script_path="$proxy_dir/proxy-server.cron"
# Last opened port for backconnect proxy
last_port=$(($start_port + $proxy_count - 1));
# Proxy credentials - username and password, delimited by ':', if exist, or empty string, if auth == false
credentials=$([[ $auth == true ]] && [[ $use_random_auth == false ]] && echo -n ":$user:$password" || echo -n "");

function is_proxyserver_installed(){
  if [ -d $proxy_dir ] && [ "$(ls -A $proxy_dir)" ]; then return 0; fi;
  return 1;
}

function is_proxyserver_running(){
  if ps aux | grep -q $proxyserver_config_path; then return 0; else return 1; fi;
}

function is_package_installed(){
  if [ $(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok installed") -eq 0 ]; then return 1; else return 0; fi;
}

function is_valid_ip(){
  if [[ "$1" =~ ^(([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then return 0; else return 1; fi;
}

function create_random_string(){
  tr -dc A-Za-z0-9 </dev/urandom | head -c $1 ; echo ''
}

function delete_file_if_exists(){
  if test -f $1; then rm $1; fi;
}

# DONT use before curl package is installed
function get_backconnect_ipv4(){
  if [ $use_localhost == true ]; then echo "127.0.0.1"; return; fi;

  local maybe_ipv4=$(ip addr show $interface_name | awk '$1 == "inet" {gsub(/\/.*$/, "", $2); print $2}')
  if is_valid_ip $maybe_ipv4; then echo $maybe_ipv4; return; fi;

  if is_package_installed "curl"; then
    (maybe_ipv4=$(curl https://ipinfo.io/ip)) &> /dev/null
    if is_valid_ip $maybe_ipv4; then echo $maybe_ipv4; return; fi;
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
  if [ $inet6_network_interfaces_configuration_check = true ]; then
    if [ ! -f $ifaces_config ]; then echo_log_err_and_exit "Error: interfaces config ($ifaces_config) doesn't exist"; fi;
    
    if grep 'inet6' $ifaces_config > /dev/null; then
      echo "Network interfaces for IPv6 configured correctly";
    else
      echo_log_err_and_exit "Error: $ifaces_config has no inet6 (IPv6) configuration.";
    fi;
  fi;

  if [[ $(ping6 -c 1 google.com) != *"Network is unreachable"* ]] &> /dev/null; then 
    echo "Test ping google.com using IPv6 successfully";
  else
    echo_log_err_and_exit "Error: test ping google.com through IPv6 failed, network is unreachable.";
  fi; 

}

# Install required libraries
function install_requred_packages(){
  apt update &>> $script_log_file

  requred_packages=("make" "g++" "wget" "curl" "cron")
  local package
  for package in ${requred_packages[@]}; do
    if ! is_package_installed $package; then
      apt install $package -y &>> $script_log_file
      if ! is_package_installed $package; then
        echo_log_err_and_exit "Error: cannot install \"$package\" package";
      fi;
    fi;
  done;

  echo -e "\nAll required packages installed successfully";
}

function install_3proxy(){

  mkdir $proxy_dir && cd $proxy_dir

  echo -e "\Installing proxy server ...";
  ( # Install proxy server
  wget https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz &> /dev/null
  tar -xf 0.9.4.tar.gz
  rm 0.9.4.tar.gz
  mv 3proxy-0.9.4 3proxy) &>> $script_log_file
  echo "Proxy server installed successfully";

  echo -e "\nStart building proxy server execution file ...";
  # Build proxy server
  cd 3proxy
  make -f Makefile.Linux &>> $script_log_file;
  if test -f "$proxy_dir/3proxy/bin/3proxy"; then
    echo "Proxy server builded successfully"
  else
    echo_log_err_and_exit "Error: proxy server build failed."
  fi;
  cd ..
}

function configure_ipv6(){
  # Enable sysctl options for rerouting and bind ips from subnet to default interface

  tee -a /etc/sysctl.conf > /dev/null << EOF
  net.ipv6.conf.$interface_name.proxy_ndp=1
  net.ipv6.conf.all.proxy_ndp=1
  net.ipv6.conf.default.forwarding=1
  net.ipv6.conf.all.forwarding=1
  net.ipv6.ip_nonlocal_bind=1
EOF
  sysctl -p &>> $script_log_file;
  if [[ $(cat /proc/sys/net/ipv6/conf/$interface_name/proxy_ndp) == 1 ]] && [[ $(cat /proc/sys/net/ipv6/ip_nonlocal_bind) == 1 ]]; then 
    echo "IPv6 network sysctl data configured successfully";
  else
    cat /etc/sysctl.conf &>> $script_log_file;
    echo_log_err_and_exit "Error: cannot configure IPv6 config";
  fi;
}

function add_to_cron(){
  delete_file_if_exists $cron_script_path;

  # Add startup script to cron (job sheduler) to restart proxy server after reboot and rotate proxy pool
  echo "@reboot $bash_location $startup_script_path" > $cron_script_path;
  if [ $rotating_interval -ne 0 ]; then echo "*/$rotating_interval * * * * $bash_location $startup_script_path" >> "$cron_script_path"; fi;

  # Add existing cron rules (not related to this proxy server) to cron script, so that they are not removed
  # https://unix.stackexchange.com/questions/21297/how-do-i-add-an-entry-to-my-crontab
  crontab -l | grep -v $startup_script_path >> $cron_script_path;

  crontab $cron_script_path;
  systemctl restart cron;

  if crontab -l | grep -q $startup_script_path; then 
    echo "Proxy startup script added to cron autorun successfully";
  else
    echo_log_err "Warning: adding script to cron autorun failed.";
  fi;
}

function generate_random_users_if_needed(){
  # No need to generate random usernames and passwords for proxies, if auth=none or one username/password for all proxies provided
  if [ $use_random_auth != true ]; then return; fi;
  delete_file_if_exists $random_users_list_file;
  
  for i in $(seq 1 $proxy_count); do 
    echo $(create_random_string 8):$(create_random_string 8) >> $random_users_list_file;
  done;
}

function create_startup_script(){
  delete_file_if_exists $startup_script_path;

  local backconnect_ipv4=$(get_backconnect_ipv4);
  # Add main script that runs proxy server and rotates external ip's, if server is already running
  cat > $startup_script_path <<-EOF
  #!$bash_location

  # Remove leading whitespaces in every string in text
  function dedent() {
    local -n reference="\$1"
    reference="\$(echo "\$reference" | sed 's/^[[:space:]]*//')"
  }

  # Close 3proxy daemon, if it's working
  ps -ef | awk '/[3]proxy/{print \$2}' | while read -r pid; do
    kill \$pid
  done

  # Remove old random ip list before create new one
  if test -f $random_ipv6_list_file; 
  then
    # Remove old ips from interface
    for ipv6_address in \$(cat $random_ipv6_list_file); do ip -6 addr del \$ipv6_address dev $interface_name;done;
    rm $random_ipv6_list_file; 
  fi;

  # Array with allowed symbols in hex (in ipv6 addresses)
  array=( 1 2 3 4 5 6 7 8 9 0 a b c d e f )

  # Generate random hex symbol
  function rh () { echo \${array[\$RANDOM%16]}; }

  rnd_subnet_ip () {
    echo -n $subnet_mask;
    symbol=$subnet
    while (( \$symbol < 128)); do
      if ((\$symbol % 16 == 0)); then echo -n :; fi;
      echo -n \$(rh);
      let "symbol += 4";
    done;
    echo ;
  }

  # Temporary variable to count generated ip's in cycle
  count=1

  # Generate random 'proxy_count' ipv6 of specified subnet and write it to file
  while (( \$count <= $proxy_count )); do
    rnd_ip=\$(rnd_subnet_ip)
    echo \$rnd_ip >> $random_ipv6_list_file;
    ip -6 addr add \$rnd_ip/$subnet dev $interface_name
    let "count += 1";
  done;

  # Configure proxy server config
  delete_file_if_exists $proxyserver_config_path;

  cat > $proxyserver_config_path <<-EOF
  nserver 8.8.8.8
  nserver 8.8.4.4

  logfile /var/log/3proxy/3proxy.log

  $([[ $auth == true ]] && [[ $use_random_auth == false ]] && echo "auth strong" || echo "auth none")
  $(cat $random_ipv6_list_file | awk '{print "proxy -6 -n -a -p" '$start_port' -i'$interface_name' "$1"'$credentials'}')
EOF

  dedent $(cat $proxyserver_config_path);

  if [[ $(cat $proxyserver_config_path) =~ ^[[:space:]]*$ ]]; then 
    echo_log_err_and_exit "Error: something went wrong with script config file";
  fi;

  # Make startup script executable
  chmod +x $proxyserver_config_path

  # Restart proxy server with new ip's
  3proxy_bin_path="$proxy_dir/3proxy/bin/3proxy"
  $3proxy_bin_path $proxyserver_config_path
EOF
}

# Main script body, invoke all needed functions

echo_log_err "IPv6 Proxy Server with Backconnect IPv4 started with arguments: 
  - Subnet: $subnet
  - Proxy count: $proxy_count
  - Username: $user
  - Password: $password
  - Proxies type: $proxies_type
  - Rotating interval: $rotating_interval
  - Subnet mask: $subnet_mask
  - Interface name: $interface_name
  - Start port: $start_port
  - Random auth: $use_random_auth
  - Localhost: $use_localhost
  - Disable inet6 interfaces check: $inet6_network_interfaces_configuration_check
  - Backconnect proxies file: $backconnect_proxies_file
  - Script log file: $script_log_file
  - Startup script path: $startup_script_path
  - Cron script path: $cron_script_path"

if ! is_proxyserver_installed; then 
  install_requred_packages;
  install_3proxy;
fi;

check_ipv6;
generate_random_users_if_needed;
configure_ipv6;
create_startup_script;
add_to_cron;

if ! is_proxyserver_running; then 
  $bash_location $startup_script_path;
  if is_proxyserver_running; then
    echo "Proxy server started successfully";
  else
    echo_log_err_and_exit "Error: cannot start proxy server";
  fi;
else
  echo "Proxy server is already running";
fi;

echo -e "\nProxy server with backconnect ip's script execution successfully completed";
