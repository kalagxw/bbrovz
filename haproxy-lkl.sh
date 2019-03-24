#!/bin/sh

: <<-'EOF'
Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
	http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
EOF

INTERFACE='eth0'
HAPROXY_LKL_DIR='/usr/local/haproxy-lkl'
LKL_TAP_NAME='lkl'
LKL_IN_CHAIN_NAME='LKL_IN'

HAPROXY_CFG_FILE="${HAPROXY_LKL_DIR}/etc/haproxy.cfg"
LKL_CFG_FILE="${HAPROXY_LKL_DIR}/lib64/lkl-hijack.json"
PIDFILE=
LOGFILE='/dev/null'

RETVAL=0

usage() {
	cat >&2 <<-EOF
	Usage: $(basename $0) [options]
	Valid options are:
	    -p <pidfile>        Writes pid to this file
	    -l <logfile>        Writes log to this file
	    -c                  Clear haproxy-lkl iptables rules
	    -h                  Show this help message
	EOF
	exit $1
}

command_exists() {
	command -v "$@" >/dev/null 2>&1
}

make_file_dir() {
	local file="$1"
	local dir="$(dirname $file)"
	if [ ! -d "$dir" ]; then
		mkdir -p "$dir" 2>/dev/null
	fi

	touch "$file" 2>/dev/null
}

pre_check() {
	if [ -z "$INTERFACE" ]; then
		cat >&2 <<-EOF
		Error: Please set your network interface first.
		    * Edit $0 and set INTERFACE at the top.
		EOF
		exit 1
	fi

	if [ -z "$HAPROXY_LKL_DIR" ]; then
		cat >&2 <<-EOF
		Error: Please set your haproxy lkl install dir first.
		    * Edit $0 and set HAPROXY_LKL_DIR at the top.
		    * Default is /usr/local/haproxy-lkl
		EOF
		exit 1
	fi

	notice_wrong_interface() {
		cat >&2 <<-EOF
		Error: You have set a wrong network interface.
		    * Edit $0 and reset the INTERFACE at the top.
		EOF
		exit 1
	}

	if command_exists ip; then
		if ! ( ip -o link show | grep -q "$INTERFACE" ); then
			notice_wrong_interface
		fi
	elif command_exists ifconfig; then
		if ! ( ifconfig -s | grep -q "$INTERFACE" ); then
			notice_wrong_interface
		fi
	else
		cat >&2 <<-'EOF'
		Error: Can't find command ip or ifconfig.
		Please install first.
		EOF
		exit 1
	fi

	if ! command_exists iptables; then
		cat >&2 <<-'EOF'
		Error: Can't find iptables.
		Please install first.
		EOF
		exit 1
	fi
}

clear_iptables_rules() {
	iptables -t nat -D PREROUTING -i ${INTERFACE} -j ${LKL_IN_CHAIN_NAME} 2>/dev/null

	iptables -t nat -F ${LKL_IN_CHAIN_NAME} 2>/dev/null
	iptables -t nat -X ${LKL_IN_CHAIN_NAME} 2>/dev/null
}

set_network() {
	if ( command_exists ip && ip tuntap >/dev/null 2>&1 ); then
		ip tuntap del dev ${LKL_TAP_NAME} mode tap 2>/dev/null
		ip tuntap add dev ${LKL_TAP_NAME} mode tap 2>/dev/null
	elif command_exists tunctl; then
		tunctl -d ${LKL_TAP_NAME} >/dev/null 2>&1
		tunctl -t ${LKL_TAP_NAME} -u haproxy >/dev/null 2>&1
	else
		cat >&2 <<-'EOF'
		Error: Can't find command ip (with tuntap) or tunctl.
		Please install first.
		EOF
		exit 1
	fi

	if command_exists ip; then
		ip addr add dev ${LKL_TAP_NAME} 10.0.0.1/24 2>/dev/null
		ip link set dev ${LKL_TAP_NAME} up 2>/dev/null
	elif command_exists ifconfig; then
		ifconfig ${LKL_TAP_NAME} 10.0.0.1 netmask 255.255.255.0 up
	fi

	clear_iptables_rules

	iptables -P FORWARD ACCEPT 2>/dev/null

	iptables -t nat -N ${LKL_IN_CHAIN_NAME} 2>/dev/null
	iptables -t nat -A PREROUTING -i ${INTERFACE} -j ${LKL_IN_CHAIN_NAME} 2>/dev/null
}

generate_config() {
	local port_rules_file="${HAPROXY_LKL_DIR}/etc/port-rules"

	if [ ! -r "$port_rules_file" ]; then
		cat >&2 <<-EOF
		Error: Can't read port rules file:
		    ${port_rules_file}
		Please check.
		EOF
		exit 1
	fi

	local port_rule_lines="$(grep -v '^#' ${port_rules_file} | \
		sed 's/[[:space:]]//g' | sed '/^$/d' 2>/dev/null)"

	if [ -z "$port_rule_lines" ]; then
		cat >&2 <<-EOF
		Error: Can't find rules in your port rules file:
		    ${port_rules_file}
		Please check.
		EOF
		exit 1
	fi

	touch "$HAPROXY_CFG_FILE" 2>/dev/null

	if [ ! -w "$HAPROXY_CFG_FILE" ]; then
		cat >&2 <<-EOF
		Error: Can't create HAproxy config file
		or we don't have write permission to file:
		    ${HAPROXY_CFG_FILE}
		Please check.
		EOF
		exit 1
	fi

	cat >"$HAPROXY_CFG_FILE" <<-EOF
	# Autogenerate by port rules file
	# Config will lost after restart haproxy-lkl
	# Do not edit this file.
	global
	    user haproxy
	    group haproxy
	defaults
	    mode tcp
	    timeout connect 5s
	    timeout client 10s
	    timeout server 10s
	backend local
	    server srv 10.0.0.1 maxconn 20480
	EOF
     
	local legal_rules=
	local i=0
	

	add_rule() {
		local ports="$1"

		legal_rules="$(printf "%s\n%s" "${legal_rules}" "${ports}")"
		i=`expr $i + 1`

		cat >>"$HAPROXY_CFG_FILE" <<-EOF
		frontend proxy-${i}
		    bind 10.0.0.2:${ports}
		    default_backend local
		EOF

		iptables -t nat -A ${LKL_IN_CHAIN_NAME} -p tcp \
			--dport "$(echo "$ports" | tr '-' ':')" -j DNAT \
			--to-destination 10.0.0.2 2>/dev/null
	}

	is_port() {
		local port=$1

		`expr $port + 1 >/dev/null 2>&1` && \
		[ "$port" -ge "1" -a "$port" -le "65535" ]
		return $?
	}

	local start_port=
	local end_port=
	for line in $port_rule_lines; do
		start_port="$(echo $line | cut -d '-' -f1)"
		end_port="$(echo $line | cut -d '-' -f2)"

		if [ -n "$start_port" -a -n "$end_port" ]; then
			if ( is_port "$start_port" && is_port "$end_port" ); then
				add_rule "$line"
			fi
		elif [ -n "$start_port" ]; then
			if is_port "$start_port"; then
				add_rule "$start_port"
			fi
		fi
	done

	if [ "$i" = "0" ]; then
		cat >&2 <<-EOF
		Error: Port rules file format error
		Please check ${port_rules_file}
		EOF

		exit 1
	fi

	if [ -w "$port_rules_file" ]; then
		cat >"$port_rules_file" <<-EOF
		# You can config HAproxy-lkl ports in this file.
		# Eg. 8800 or 8800-8810
		# It is the port(s) you want accelerate.
		# One port(port range) per line.
		${legal_rules}
		EOF
	fi
}

touch "$LKL_CFG_FILE" 2>/dev/null

	if [ ! -w "$HAPROXY_CFG_FILE" ]; then
		cat >&2 <<-EOF
		Error: Can't create LKL config file
		or we don't have write permission to file:
		    ${LKL_CFG_FILE}
		Please check.
		EOF
		exit 1
	fi
	cat >"$LKL_CFG_FILE" <<-EOF
	{
       "gateway":"10.0.0.1",
       "debug":"1",
       "singlecpu":"1",
       "sysctl":"net.ipv4.tcp_wmem=4096 65536 67108864",
       "sysctl":"net.ipv4.tcp_congestion_control=bbr",
       "sysctl":"net.ipv4.tcp_fastopen=3",
       "interfaces":[
               {
                       "type":"tap",
                       "param":"$LKL_TAP_NAME",
                       "ip":"10.0.0.2",
                       "masklen":"24",
                       "ifgateway":"10.0.0.1",
                       "offload":"0x8883",
                       "qdisc":"root|fq"
               }
       ]
}
     EOF

start_haproxy_lkl() {
	local haproxy_bin="${HAPROXY_LKL_DIR}/sbin/haproxy"
	local lkl_lib="${HAPROXY_LKL_DIR}/lib64/liblkl-hijack.so"

	if [ ! -f "$haproxy_bin" ]; then
		cat >&2 <<-EOF
		Error: Can't find haproxy bin.
		Please put haproxy in $(dirname ${haproxy_bin})
		EOF
		exit 1
	fi

	if [ ! -f "$lkl_lib" ]; then
		cat >&2 <<-EOF
		Error: Can't find Linux kernel library.
		Please put liblkl-hijack.so in $(dirname ${lkl_lib})
		EOF
		exit 1
	fi

	if [ ! -s "$HAPROXY_CFG_FILE" ]; then
		cat >&2 <<-EOF
		Error: HAproxy config file is empty.
		May be insufficient disk space.
		    ${HAPROXY_CFG_FILE}
		EOF
		exit 1
	fi

	[ ! -x "$haproxy_bin" ] && chmod +x "$haproxy_bin"
	LD_PRELOAD="$lkl_lib" \
	$haproxy_bin -f "$HAPROXY_CFG_FILE" >"$LOGFILE" 2>&1 &
}

do_start() {
	pre_check
	set_network
	generate_config

	local pid=
	start_haproxy_lkl && pid=$! || RETVAL=$?

	if [ -n "$pid" -a -n "$PIDFILE" ]; then
		echo "$pid" >"$PIDFILE" 2>/dev/null
	fi
}

while getopts "p:l:hc" opt; do
	case "$opt" in
		c)
			clear_iptables_rules
			exit 0
			;;
		p)
			if [ -n "$OPTARG" ]; then
				PIDFILE="$OPTARG"
				make_file_dir "$PIDFILE"
			fi
			;;
		l)
			if [ -n "$OPTARG" ]; then
				LOGFILE="$OPTARG"
				make_file_dir "$LOGFILE"
			fi
			;;
		h)
			usage 0
			;;
		[?])
			usage 1
			;;
	esac
done

do_start

exit $RETVAL
