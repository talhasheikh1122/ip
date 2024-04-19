## IPv6 Proxy Server 

Create your own IPv6 proxy server with only one script on any Linux distribution.

### Tutorial

Assuming you already have an entire IPv6 subnet (/48 or /64) routed to your server.

Full command:

```bash
cd proxy-generator
chmod +x ipv6-proxy-generator.sh
./ipv6-proxy-generator.sh -s 64 -t http  -c 100 -u username -p password --start-port 40000 -r 10 -d
```

If script already installed, you can just run one command to reconfigure parameters, for example:

Just run:

```bash
cd proxy-generator
./ipv6-proxy-generator.sh -c 100 -u username -p password
```

**Command line arguments:**

- `-s` or `--subnet` - IPv6 [subnet](https://docs.netgate.com/pfsense/en/latest/network/ipv6/subnets.html), fully dedicated for your server. `16`, `32`, `48`, `64`, `80`, `96` or `112`, default `64`
- `-c` or `--proxy-count` - The total number of proxies you want to have (from 1 to 10000)
- `-t` or `--proxies-type` - Proxies type - `http` or `socks5`. Default `http`, if no value provided
- `-u` or `--username` - All proxies auth login
- `-p` or `--password` - All proxies auth password (if you specify neither username not password, proxy will run without authentification)
- `--random` - bool parameter without value, if used, each backconnect proxy will have random username and password, that will be written in backconnect proxies file (`-f` argument)
- `--start-port` - backconnect IPv4 start port. If you create 1500 proxies and `start-port` is `20000`, and server external IPv4 is, e.g,`180.113.14.28` you can connect to proxies using `180.113.14.28:20000`, `180.113.14.28:20001` and so on until `180.113.14.28:21500`
- `-r` or `--rotating-interval` - rotation interval of entire proxy pool in minutes. At the end of each interval, output (external IPv6) addresses of all proxies are changed and proxy server is restarted, which breaks existing connections for a few seconds. From 0 to 59, default value - `0` (rotating disabled)
- `-l` or `--localhost` - bool parameter without value, if used, all backconnect proxy will be available only on localhost (`127.0.0.1:30000` instead of `180.113.14.28:30000`)
- `-f` or `--backconnect-proxies-file` - path to file, in which backconnect proxies list will be written when proxies start working (default `~/proxyserver/backconnect_proxies.list`). You can just copy all proxies from this file and use them in your soft as list of IPv6 proxies.
- `-m` or `--ipv6-mask` - first blocks on server subnet, unchanged part, use ONLY if script cannot parse ipv6 mask automatically. For example, if the external ipv6 address on server is `2a03:6f01:5::1da6` and you want to use entire /64 subnet, script cannot parse ipv6 gateaway because of address zero-field replacement with `::`. Real mask for /64 subnet is first four blocks - `2a03:6f01:5:0`
- `-i` or `--interface` - ethernet interface name, to which IPv6 subnet is allocated and where all proxies will be raised. Automatically parsed from system info by default, use ONLY if you have non-standard/additional interfaces on your server.
- `-d` or `--disable-inet6-ifaces-check` - disable /etc/network/interfaces configuration check & exit when error.
  Use only if configuration handled by cloud-init or something like this (for example, on Vultr servers), rarely used parameter, check your VPS documentation
