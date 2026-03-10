#!/bin/bash
#Check Root
[ $(id -u) != "0" ] && { echo "Error: 必须使用root用户执行此脚本！"; exit 1; }

APT_IPV4="-o Acquire::ForceIPv4=true"

enable_legacy_provider(){
	if openssl version 2>/dev/null | grep -q "OpenSSL 3"; then
		cat > /etc/ssl/openssl-legacy.cnf <<'EOF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
legacy = legacy_sect

[default_sect]
activate = 1

[legacy_sect]
activate = 1
EOF
		echo 'export OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf' > /etc/profile.d/openssl_legacy.sh
		chmod +x /etc/profile.d/openssl_legacy.sh
	fi
}

patch_python310_compat(){
	local target_file="/root/shadowsocks/shadowsocks/lru_cache.py"
	if [ -f "$target_file" ]; then
		sed -i "s/from collections import MutableMapping/from collections.abc import MutableMapping/" "$target_file"
	fi
	local target_encrypt="/root/shadowsocks/shadowsocks/encrypt.py"
	if [ -f "$target_encrypt" ]; then
		sed -i "s/collections.MutableMapping/collections.abc.MutableMapping/g" "$target_encrypt"
	fi
}

enable_bbr(){
	modprobe tcp_bbr >/dev/null 2>&1
	grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
	grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
	sysctl -p >/dev/null 2>&1
}

configure_startup_and_firewall(){
	iptables -F
	iptables -X
	iptables -I INPUT -p tcp -m tcp --dport 22:65535 -j ACCEPT
	iptables -I INPUT -p udp -m udp --dport 22:65535 -j ACCEPT

	if [[ ${release} = "centos" ]]; then
		mkdir -p /etc/sysconfig
		iptables-save > /etc/sysconfig/iptables
		echo 'iptables-restore /etc/sysconfig/iptables' >> /etc/rc.local
		echo "/usr/bin/supervisord -c /etc/supervisord.conf" >> /etc/rc.local
		chmod +x /etc/rc.d/rc.local
	else
		mkdir -p /etc/iptables
		iptables-save > /etc/iptables/rules.v4
		if command -v netfilter-persistent >/dev/null 2>&1; then
			netfilter-persistent save
		fi
		cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
iptables-restore < /etc/iptables/rules.v4
/usr/bin/supervisord -c /etc/supervisord.conf
exit 0
EOF
		chmod +x /etc/rc.local
	fi
}

config_supervisor_runtime(){
	local py_bin="python"
	if command -v python3 >/dev/null 2>&1; then
		py_bin="python3"
	fi
	if [ -f /etc/supervisord.conf ]; then
		sed -i "s#command = python #command = /usr/bin/env OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf ${py_bin} #g" /etc/supervisord.conf
		sed -i "s#command=python #command=/usr/bin/env OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf ${py_bin} #g" /etc/supervisord.conf
	fi
}

Libtest(){
	#自动选择下载节点
	GIT='raw.githubusercontent.com'
	LIB='download.libsodium.org'
	GIT_PING=`ping -c 1 -w 1 $GIT|grep time=|awk '{print $7}'|sed "s/time=//"`
	LIB_PING=`ping -c 1 -w 1 $LIB|grep time=|awk '{print $7}'|sed "s/time=//"`
	echo "$GIT_PING $GIT" > ping.pl
	echo "$LIB_PING $LIB" >> ping.pl
	libAddr=`sort -V ping.pl|sed -n '1p'|awk '{print $2}'`
	if [ "$libAddr" == "$GIT" ];then
		libAddr='https://raw.githubusercontent.com/Tyrant-2017/ss-panel-v3-mod-node-connect/master/libsodium-1.0.13.tar.gz'
	else
		libAddr='https://download.libsodium.org/libsodium/releases/libsodium-1.0.13.tar.gz'
	fi
	rm -f ping.pl		
}
Get_Dist_Version()
{
	if [ -f /etc/os-release ]; then
		Version=$(awk -F'=' '/^VERSION_ID=/{gsub(/"/,"",$2);print $2}' /etc/os-release | cut -d. -f1)
	fi
}
python_test(){
	#测速决定使用哪个源
	tsinghua='pypi.tuna.tsinghua.edu.cn'
	pypi='mirror-ord.pypi.io'
	doubanio='pypi.doubanio.com'
	pubyun='pypi.pubyun.com'	
	tsinghua_PING=`ping -c 1 -w 1 $tsinghua|grep time=|awk '{print $8}'|sed "s/time=//"`
	pypi_PING=`ping -c 1 -w 1 $pypi|grep time=|awk '{print $8}'|sed "s/time=//"`
	doubanio_PING=`ping -c 1 -w 1 $doubanio|grep time=|awk '{print $8}'|sed "s/time=//"`
	pubyun_PING=`ping -c 1 -w 1 $pubyun|grep time=|awk '{print $8}'|sed "s/time=//"`
	echo "$tsinghua_PING $tsinghua" > ping.pl
	echo "$pypi_PING $pypi" >> ping.pl
	echo "$doubanio_PING $doubanio" >> ping.pl
	echo "$pubyun_PING $pubyun" >> ping.pl
	pyAddr=`sort -V ping.pl|sed -n '1p'|awk '{print $2}'`
	if [ "$pyAddr" == "$tsinghua" ]; then
		pyAddr='https://pypi.tuna.tsinghua.edu.cn/simple'
	elif [ "$pyAddr" == "$pypi" ]; then
		pyAddr='https://mirror-ord.pypi.io/simple'
	elif [ "$pyAddr" == "$doubanio" ]; then
		pyAddr='http://pypi.doubanio.com/simple --trusted-host pypi.doubanio.com'
	elif [ "$pyAddr" == "$pubyun_PING" ]; then
		pyAddr='http://pypi.pubyun.com/simple --trusted-host pypi.pubyun.com'
	fi
	rm -f ping.pl
}
install_centos_ssr(){
	cd /root
	Get_Dist_Version
	if [ $Version == "7" ]; then
		wget -4 --no-check-certificate https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm 
		rpm -ivh epel-release-latest-7.noarch.rpm	
	else
		wget -4 --no-check-certificate https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm
		rpm -ivh epel-release-latest-6.noarch.rpm
	fi
	rm -rf *.rpm
	yum -y update --exclude=kernel*	
	yum -y install git gcc python-setuptools lsof lrzsz python-devel libffi-devel openssl-devel iptables
	yum -y update nss curl libcurl 
	yum -y groupinstall "Development Tools" 
	#第一次yum安装 supervisor pip
	yum -y install supervisor python-pip
	supervisord
	#第二次pip supervisor是否安装成功
	if [ -z "`pip`" ]; then
    curl -O https://bootstrap.pypa.io/get-pip.py
		python get-pip.py 
		rm -rf *.py
	fi
	if [ -z "`ps aux|grep supervisord|grep python`" ]; then
    pip install supervisor
    supervisord
	fi
	#第三次检测pip supervisor是否安装成功
	if [ -z "`pip`" ]; then
		if [ -z "`easy_install`"]; then
    wget http://peak.telecommunity.com/dist/ez_setup.py
		python ez_setup.py
		fi		
		easy_install pip
	fi
	if [ -z "`ps aux|grep supervisord|grep python`" ]; then
    easy_install supervisor
    supervisord
	fi
	pip install --upgrade pip
	Libtest
	wget --no-check-certificate $libAddr
	tar xf libsodium-1.0.13.tar.gz && cd libsodium-1.0.13
	./configure && make -j2 && make install
	echo /usr/local/lib > /etc/ld.so.conf.d/usr_local_lib.conf
	ldconfig
	git clone -b manyuser https://github.com/Tyrant-2017/shadowsocks.git "/root/shadowsocks"
	cd /root/shadowsocks
	chkconfig supervisord on
	#第一次安装
	python_test
	pip install -r requirements.txt -i $pyAddr	
	#第二次检测是否安装成功
	if [ -z "`python -c 'import requests;print(requests)'`" ]; then
		pip install -r requirements.txt #用自带的源试试再装一遍
	fi
	#第三次检测是否成功
	if [ -z "`python -c 'import requests;print(requests)'`" ]; then
		mkdir python && cd python
		git clone https://github.com/Tyrant-2017/urllib3.git && cd urllib3
		python setup.py install && cd ..
		git clone https://github.com/nakagami/CyMySQL.git && cd CyMySQL
		python setup.py install && cd ..
		git clone https://github.com/requests/requests.git && cd requests
		python setup.py install && cd ..
		git clone https://github.com/pyca/pyopenssl.git && cd pyopenssl
		python setup.py install && cd ..
		git clone https://github.com/cedadev/ndg_httpsclient.git && cd ndg_httpsclient
		python setup.py install && cd ..
		git clone https://github.com/etingof/pyasn1.git && cd pyasn1
		python setup.py install && cd ..
		rm -rf python
	fi	
	systemctl stop firewalld.service
	systemctl disable firewalld.service
	cd /root/shadowsocks
	cp apiconfig.py userapiconfig.py
	cp config.json user-config.json
}
install_ubuntu_ssr(){
	apt-get ${APT_IPV4} update -y
	apt-get ${APT_IPV4} install supervisor lsof -y
	apt-get ${APT_IPV4} install build-essential wget -y
	apt-get ${APT_IPV4} install iptables git curl -y
	apt-get ${APT_IPV4} install python3 python3-pip python3-dev python3-setuptools python3-wheel -y
	Libtest
	wget -4 --no-check-certificate $libAddr
	tar xf libsodium-1.0.13.tar.gz && cd libsodium-1.0.13
	./configure && make -j2 && make install
	echo /usr/local/lib > /etc/ld.so.conf.d/usr_local_lib.conf
	ldconfig
	python3 -m pip install --upgrade pip setuptools wheel
	python3 -m pip install cymysql
	cd /root
	git clone -b master https://github.com/Tyrant-2017/shadowsocks.git "/root/shadowsocks"
	cd shadowsocks
	patch_python310_compat
	enable_legacy_provider
	OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf python3 -m pip install -r requirements.txt
	chmod +x *.sh
	# 配置程序
	cp apiconfig.py userapiconfig.py
	cp config.json user-config.json
}
install_node(){
	clear
	echo
	echo "#######################################################################"
	echo "# One click Install Shadowsocks-Python-Manyuser                       #"
	echo "# Github: https://github.com/Tyrant-2017/ss-panel-v3-mod-node-connect #"
	echo "# Author: Tyrant                                                    	#"
	echo "# blog: https://tyrant.cc                                      		#"	
	echo "#######################################################################"
	echo
	#Check Root
	[ $(id -u) != "0" ] && { echo "Error: 必须使用root用户执行此脚本！"; exit 1; }
	#check OS version
	check_sys(){
		if [[ -f /etc/redhat-release ]]; then
			release="centos"
		elif cat /etc/issue | grep -q -E -i "debian"; then
			release="debian"
		elif cat /etc/issue | grep -q -E -i "ubuntu"; then
			release="ubuntu"
		elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
			release="centos"
		elif cat /proc/version | grep -q -E -i "debian"; then
			release="debian"
		elif cat /proc/version | grep -q -E -i "ubuntu"; then
			release="ubuntu"
		elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
			release="centos"
	  fi
	}
	install_ssr_for_each(){
		check_sys
		if [[ ${release} = "centos" ]]; then
			install_centos_ssr
		else
			install_ubuntu_ssr
		fi
	}
	# 取消文件数量限制
	sed -i '$a * hard nofile 512000\n* soft nofile 512000' /etc/security/limits.conf
	read -p "请输入面板的域名或ip(例如:https://tyrant.cc or http://114.114.114.114): " Userdomain
	read -p "请输入面板的muKey(例如:mupass): " Usermukey
	read -p "请输入面板的节点id(例如:7): " UserNODE_ID
	install_ssr_for_each
	cd /root/shadowsocks
	echo -e "modify Config.py...\n"
	sed -i "s#'zhaoj.in'#'jd.hk'#" /root/shadowsocks/userapiconfig.py
	Userdomain=${Userdomain:-"http://127.0.0.1"}
	sed -i "s#https://zhaoj.in#${Userdomain}#" /root/shadowsocks/userapiconfig.py
	Usermukey=${Usermukey:-"mupass"}
	sed -i "s#glzjin#${Usermukey}#" /root/shadowsocks/userapiconfig.py
	UserNODE_ID=${UserNODE_ID:-"3"}
	sed -i '2d' /root/shadowsocks/userapiconfig.py
	sed -i "2a\NODE_ID = ${UserNODE_ID}" /root/shadowsocks/userapiconfig.py
	# 启用supervisord
	supervisorctl shutdown
	#某些机器没有echo_supervisord_conf 
	wget -4 -N -P  /etc/ --no-check-certificate  https://raw.githubusercontent.com/Tyrant-2017/ss-panel-v3-mod-node-connect/master/supervisord.conf
	config_supervisor_runtime
	supervisord
	#iptables
	configure_startup_and_firewall
	echo "#######################################################################"
	echo "# 安装完成，节点即将重启使配置生效                                    #"
	echo "# Github: https://github.com/Tyrant-2017/ss-panel-v3-mod-node-connect #"
	echo "# Author: Tyrant                                                    	#"
	echo "# blog: https://tyrant.cc                                      		#"	
	echo "#######################################################################"
	enable_bbr
	reboot now
}
install_node_db(){
	clear
	echo
	echo "#######################################################################"
	echo "# One click Install Shadowsocks-Python-Manyuser                       #"
	echo "# Github: https://github.com/Tyrant-2017/ss-panel-v3-mod-node-connect #"
	echo "# Author: Tyrant                                                    	#"
	echo "# blog: https://tyrant.cc                                      		#"	
	echo "#######################################################################"
	echo
	#Check Root
	[ $(id -u) != "0" ] && { echo "Error: 必须使用root用户执行此脚本！"; exit 1; }
	#check OS version
	check_sys(){
		if [[ -f /etc/redhat-release ]]; then
			release="centos"
		elif cat /etc/issue | grep -q -E -i "debian"; then
			release="debian"
		elif cat /etc/issue | grep -q -E -i "ubuntu"; then
			release="ubuntu"
		elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
			release="centos"
		elif cat /proc/version | grep -q -E -i "debian"; then
			release="debian"
		elif cat /proc/version | grep -q -E -i "ubuntu"; then
			release="ubuntu"
		elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
			release="centos"
	  fi
	}
	install_ssr_for_each(){
		check_sys
		if [[ ${release} = "centos" ]]; then
			install_centos_ssr
		else
			install_ubuntu_ssr
		fi
	}
	# 取消文件数量限制
	sed -i '$a * hard nofile 512000\n* soft nofile 512000' /etc/security/limits.conf
	read -p "请输入面板数据库地址: " MYSQL_HOST
	read -p "请输入面板数据库库名: " MYSQL_DB 
	read -p "请输入面板数据库用户名: " MYSQL_USER 
	read -p "请输入面板数据库密码: " MYSQL_PASS 
	read -p "请输入面板的节点ID(like:7): " UserNODE_ID
	install_ssr_for_each
	cd /root/shadowsocks
	echo -e "modify Config.py...\n"
	sed -i "s#'modwebapi'#'glzjinmod'#" /root/shadowsocks/userapiconfig.py #改成数据库对接
	sed -i "s#'zhaoj.in'#'jd.hk'#" /root/shadowsocks/userapiconfig.py #混淆设置
	MYSQL_HOST=${MYSQL_HOST:-"http://127.0.0.1"}
	sed -i "s#MYSQL_HOST = '127.0.0.1'#MYSQL_HOST = '${MYSQL_HOST}'#" /root/shadowsocks/userapiconfig.py
	MYSQL_DB=${MYSQL_DB:-"root"}
	sed -i "s#MYSQL_DB = 'shadowsocks'#MYSQL_DB = '${MYSQL_DB}'#" /root/shadowsocks/userapiconfig.py
	MYSQL_USER=${MYSQL_USER:-"root"}
	sed -i "s#MYSQL_USER = 'ss'#MYSQL_USER = '${MYSQL_USER}'#" /root/shadowsocks/userapiconfig.py
	MYSQL_PASS=${MYSQL_PASS:-"root"}
	sed -i "s#MYSQL_PASS = 'ss'#MYSQL_PASS = '${MYSQL_PASS}'#" /root/shadowsocks/userapiconfig.py
	UserNODE_ID=${UserNODE_ID:-"3"}
	sed -i '2d' /root/shadowsocks/userapiconfig.py
	sed -i "2a\NODE_ID = ${UserNODE_ID}" /root/shadowsocks/userapiconfig.py
	# 启用supervisord
	supervisorctl shutdown
	#某些机器没有echo_supervisord_conf 
	wget -4 -N -P  /etc/ --no-check-certificate  https://raw.githubusercontent.com/Tyrant-2017/ss-panel-v3-mod-node-connect/master/supervisord.conf
	config_supervisor_runtime
	supervisord
	#iptables
	configure_startup_and_firewall
	echo "#######################################################################"
	echo "# 安装完成，节点即将重启使配置生效                                    #"
	echo "# Github: https://github.com/Tyrant-2017/ss-panel-v3-mod-node-connect #"
	echo "# Author: Tyrant                                                    	#"
	echo "# blog: https://tyrant.cc                                      		#"
	echo "#######################################################################"
	enable_bbr
	reboot now
}
echo
echo "########################################################################"
echo "# ss-panel-v3-mod后端对接一键脚本                     				 #"
echo "# Github: https://github.com/Tyrant-2017/ss-panel-v3-mod-node-connect  #"
echo "# Author: Tyrant                                                   	 #"
echo "# blog: https://tyrant.cc                                     		 #"
echo "# 请输入1或2选择对接方式                                               #"
echo "# 1  webapi对接选这个!                                                 #"
echo "# 2  db数据库对接选这个!                                               #"
echo "########################################################################"
echo
num=$1
if [ "${num}" == "1" ]; then
    install_node 1
else
    stty erase '^H' && read -p " 请输入数字 [1-2]:" num
		case "$num" in
		1)
		install_node
		;;
		2)
		install_node_db
		;;
		*)
		echo "请输入正确数字 [1-2]"
		;;
	esac
fi
