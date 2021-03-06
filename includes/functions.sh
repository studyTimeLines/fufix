textb() { echo $(tput bold)${1}$(tput sgr0); }
greenb() { echo $(tput bold)$(tput setaf 2)${1}$(tput sgr0); }
redb() { echo $(tput bold)$(tput setaf 1)${1}$(tput sgr0); }
yellowb() { echo $(tput bold)$(tput setaf 3)${1}$(tput sgr0); }
pinkb() { echo $(tput bold)$(tput setaf 5)${1}$(tput sgr0); }

usage() {
	echo "fufix install script command-line parameters."
	echo $(textb "Do not append any parameters to run fufix in default mode.")
	echo "
	--help | -h
		Print this text

	--upgrade-from-file installer.log | -u installer.log
		Upgrade using a previous \"installer.log\" file
	"
}

genpasswd() {
    count=0
    while [ $count -lt 3 ]
    do
        pw_valid=$(tr -cd A-Za-z0-9 < /dev/urandom | fold -w24 | head -n1)
        count=$(grep -o "[0-9]" <<< $pw_valid | wc -l)
    done
    echo $pw_valid
}

returnwait() {
		echo "$(greenb [OK]) - Task $(textb "$1") completed"
		echo "----------------------------------------------"
		if [[ $inst_unattended != "yes" ]]; then
			read -p "$(yellowb !) Press ENTER to continue with task $(textb "$2") (CTRL-C to abort) "
		fi
		echo "$(pinkb [RUNNING]) - Task $(textb "$2") started, please wait..."
}

is_ipv6() {
    # Thanks to https://github.com/mutax
    INPUT="$@"
    O=""
    while [ "$O" != "$INPUT" ]; do
        O="$INPUT"
        INPUT="$( sed  's|:\([0-9a-f]\{3\}\):|:0\1:|g' <<< "$INPUT" )"
        INPUT="$( sed  's|:\([0-9a-f]\{3\}\)$|:0\1|g'  <<< "$INPUT")"
        INPUT="$( sed  's|^\([0-9a-f]\{3\}\):|0\1:|g'  <<< "$INPUT" )"
        INPUT="$( sed  's|:\([0-9a-f]\{2\}\):|:00\1:|g' <<< "$INPUT")"
        INPUT="$( sed  's|:\([0-9a-f]\{2\}\)$|:00\1|g'  <<< "$INPUT")"
        INPUT="$( sed  's|^\([0-9a-f]\{2\}\):|00\1:|g'  <<< "$INPUT")"
        INPUT="$( sed  's|:\([0-9a-f]\):|:000\1:|g'  <<< "$INPUT")"
        INPUT="$( sed  's|:\([0-9a-f]\)$|:000\1|g'   <<< "$INPUT")"
        INPUT="$( sed  's|^\([0-9a-f]\):|000\1:|g'   <<< "$INPUT")"
    done

    grep -qs "::" <<< "$INPUT"
    if [ "$?" -eq 0 ]; then
        GRPS="$(sed  's|[0-9a-f]||g' <<< "$INPUT" | wc -m)"
        ((GRPS--)) # carriage return
        ((MISSING=8-GRPS))
        for ((i=0;i<$MISSING;i++)); do
            ZEROES="$ZEROES:0000"
        done
        INPUT="$( sed  's|\(.\)::\(.\)|\1'$ZEROES':\2|g'   <<< "$INPUT")"
        INPUT="$( sed  's|\(.\)::$|\1'$ZEROES':0000|g'   <<< "$INPUT")"
        INPUT="$( sed  's|^::\(.\)|'$ZEROES':0000:\1|g;s|^:||g'   <<< "$INPUT")"
    fi

    if [ $(echo $INPUT | wc -m) != 40 ]; then
        return 1
    else
        return 0
    fi
}

checksystem() {
	if [[ $(grep MemTotal /proc/meminfo | awk '{print $2}') -lt 750000 ]]; then
		echo "$(yellowb [WARN]) - At least 768MB of memory is highly recommended"
		read -p "Press ENTER to skip this warning or CTRL-C to cancel the process"
	fi
}

checkports() {
    if [[ -z $(which nc) ]]; then
		echo "$(redb [ERR]) - Please install $(textb netcat) before running this script"
		exit 1
	fi
	for port in 25 80 143 443 465 587 993 995 3306
	do
	    if [[ $(nc -z localhost $port; echo $?) -eq 0 ]]; then
	        echo "$(redb [ERR]) - An application is blocking the installation on Port $(textb $port)"
			# Wait until finished to list all blocked ports.
			blocked_port=1
	    fi
	done
	[[ $blocked_port -eq 1 ]] && exit 1
}

checkconfig() {
    if [[ $conf_done = "no" ]]; then
        echo "$(redb [ERR]) - Error in configuration file"
        echo "Is \"conf_done\" set to \"yes\"?"
        echo
        exit 1
    elif [[ ${#cert_country} -ne 2 ]]; then
        echo "$(redb [ERR]) - Country code must consist of exactly two characters (DE/US/UK etc.)"
        exit 1
    else
    for var in sys_hostname sys_domain sys_timezone my_postfixdb my_postfixuser my_postfixpass my_rootpw my_rcuser my_rcpass my_rcdb pfadmin_adminuser pfadmin_adminpass cert_country cert_state cert_city cert_org
    do
        if [[ -z ${!var} ]]; then
            echo "$(redb [ERR]) - Parameter $var must not be empty."
            echo
            exit 1
        fi
    done
    fi
    pass_count=$(grep -o "[0-9]" <<< $pfadmin_adminpass | wc -l)
    pass_chars=$(echo $pfadmin_adminpass | egrep "^.{8,255}" | \
	egrep "[ABCDEFGHIJKLMNOPQRSTUVXYZ]" | \
	egrep "[abcdefghijklmnopqrstuvxyz"] | \
	egrep "[0-9]")
    if [[ $pass_count -lt 2 || -z $pass_chars ]]; then
		echo "$(redb [ERR]) - Postfixadmin password does not meet password policy requirements."
		echo
		exit 1
	fi
	if [[ $inst_debug == "yes" ]]; then
		set -x
	fi
}

installtask() {
	case $1 in
		environment)
			getpublicipv4=$(wget -q4O- ip4.telize.com)
			if [[ $getpublicipv4 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
				cat > /etc/hosts<<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
				echo $getpublicipv4 $sys_hostname.$sys_domain $sys_hostname >> /etc/hosts
				echo $sys_hostname.$sys_domain > /etc/mailname
				getpublicipv6=$(wget -t2 -T1 -q6O- ip6.telize.com)
					if is_ipv6 $getpublicipv6; then
						echo $getpublicipv6 $sys_hostname.$sys_domain $sys_hostname >> /etc/hosts
					fi
			else
				echo "$(redb [ERR]) - Cannot set your hostname!"
				exit 1
			fi
			if [[ -f /lib/systemd/systemd ]]; then
				echo "$(textb [INFO]) - Checking for dbus, this may take a few seconds..."
				apt-get -y update > /dev/null ; apt-get -y install dbus > /dev/null
				hostnamectl set-hostname $sys_hostname
			else
				echo $sys_hostname > /etc/hostname
				hostname $sys_hostname > /dev/null 2>&1
				service hostname.sh start > /dev/null 2>&1
			fi
			if [[ -f /usr/share/zoneinfo/$sys_timezone ]] ; then
				echo $sys_timezone > /etc/timezone
				dpkg-reconfigure -f noninteractive tzdata > /dev/null 2>&1
				if [ "$?" -ne "0" ]; then
					echo "$(redb [ERR]) - Timezone configuration failed: dpkg returned exit code != 0"
					exit 1
				fi
			else
				echo "$(redb [ERR]) - Cannot set your timezone: timezone is unknown"
				exit 1
			fi
			;;
		installpackages)
			if [[ ! -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]]; then
				echo "$(textb [INFO]) - Generating snakeoil certificate to satisfy package installation..."
				apt-get -y update >/dev/null ; apt-get -y install ssl-cert >/dev/null
				/usr/sbin/make-ssl-cert generate-default-snakeoil --force-overwrite
			fi
            if [[ ! -z $(grep wheezy-backports /etc/apt/sources.list) ]]; then
				echo "$(textb [INFO]) - Installing python-magic from backports..."
				apt-get -y update >/dev/null ; apt-get -y install python-magic -t wheezy-backports >/dev/null
			fi
			echo "$(textb [INFO]) - Installing packages unattended, please stand by, errors will be reported."
			apt-get -y update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get --force-yes -y install dnsutils python-sqlalchemy python-beautifulsoup python-setuptools \
python-magic libmail-spf-perl libmail-dkim-perl openssl php-auth-sasl php-http-request php-mail php-mail-mime php-mail-mimedecode php-net-dime php-net-smtp \
php-net-socket php-net-url php-pear php-soap php5 php5-cli php5-common php5-curl php5-fpm php5-gd php5-imap php-apc subversion \
php5-intl php5-mcrypt php5-mysql php5-sqlite libawl-php php5-xmlrpc mysql-client mysql-server nginx-extras mailutils \
postfix-mysql postfix-pcre clamav clamav-base clamav-daemon clamav-freshclam spamassassin >/dev/null
			if [ "$?" -ne "0" ]; then
				echo "$(redb [ERR]) - Package installation failed"
				exit 1
			fi
			mkdir -p /etc/dovecot/private/
			cp /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/dovecot/dovecot.pem
			cp /etc/ssl/private/ssl-cert-snakeoil.key /etc/dovecot/dovecot.key
			cp /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/dovecot/private/dovecot.pem
			cp /etc/ssl/private/ssl-cert-snakeoil.key /etc/dovecot/private/dovecot.key
DEBIAN_FRONTEND=noninteractive apt-get --force-yes -y install dovecot-common dovecot-core dovecot-imapd dovecot-lmtpd dovecot-managesieved dovecot-sieve dovecot-mysql dovecot-pop3d >/dev/null
			;;
		ssl)
			rm /etc/ssl/mail/* 2> /dev/null
			mkdir /etc/ssl/mail
			openssl req -new -newkey rsa:4096 -days 1095 -nodes -x509 -subj "/C=$cert_country/ST=$cert_state/L=$cert_city/O=$cert_org/CN=$sys_hostname.$sys_domain" -keyout /etc/ssl/mail/mail.key  -out /etc/ssl/mail/mail.crt
			chmod 600 /etc/ssl/mail/mail.key
			cp /etc/ssl/mail/mail.crt /usr/local/share/ca-certificates/
			update-ca-certificates
			;;
		mysql)
			mysql --defaults-file=/etc/mysql/debian.cnf -e "UPDATE mysql.user SET Password=PASSWORD('$my_rootpw') WHERE USER='root'; FLUSH PRIVILEGES;"
			mysql --defaults-file=/etc/mysql/debian.cnf -e "DROP DATABASE IF EXISTS $my_postfixdb; DROP DATABASE IF EXISTS $my_rcdb;"
			mysql --defaults-file=/etc/mysql/debian.cnf -e "CREATE DATABASE $my_postfixdb; GRANT ALL PRIVILEGES ON $my_postfixdb.* TO '$my_postfixuser'@'localhost' IDENTIFIED BY '$my_postfixpass';"
			mysql --defaults-file=/etc/mysql/debian.cnf -e "CREATE DATABASE $my_rcdb; GRANT ALL PRIVILEGES ON $my_rcdb.* TO '$my_rcuser'@'localhost' IDENTIFIED BY '$my_rcpass';"
			;;
		fuglu)
			mkdir /var/log/fuglu 2> /dev/null
			userdel fuglu 2> /dev/null
			groupadd fuglu
			useradd -g fuglu -s /bin/false fuglu
			usermod -a -G debian-spamd fuglu
			usermod -a -G clamav fuglu
			rm /tmp/fuglu_control.sock 2> /dev/null
			chown fuglu:fuglu /var/log/fuglu
			tar xf fuglu/inst/$fuglu_version.tar -C fuglu/inst/ 2> /dev/null
			(cd fuglu/inst/$fuglu_version ; python setup.py -q install)
			cp -R fuglu/conf/* /etc/fuglu/
			if [[ -f /lib/systemd/systemd ]]; then
				cp fuglu/inst/$fuglu_version/scripts/startscripts/centos_rhel/7/fuglu.service /lib/systemd/system/fuglu.service
				ln -s /usr/local/bin/fuglu /usr/bin/fuglu
				systemctl enable fuglu
			else
				cp fuglu/inst/$fuglu_version/scripts/startscripts/debian/7/fuglu /etc/init.d/fuglu
				chmod +x /etc/init.d/fuglu
				update-rc.d fuglu defaults
			fi
			rm -rf fuglu/inst/$fuglu_version
			;;
		postfix)
			cp -R postfix/conf/* /etc/postfix/
			chown root:postfix "/etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_alias_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_alias_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_mailbox_limit_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_mailbox_limit_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_mailbox_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_mailbox_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_alias_domain_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_alias_domain_maps.cf"
			chown root:postfix "/etc/postfix/sql/mysql_virtual_domains_maps.cf"; chmod 640 "/etc/postfix/sql/mysql_virtual_domains_maps.cf"
			chown root:root "/etc/postfix/master.cf"; chmod 644 "/etc/postfix/master.cf"
			chown root:root "/etc/postfix/main.cf"; chmod 644 "/etc/postfix/main.cf"
			sed -i "s/mail.domain.tld/$sys_hostname.$sys_domain/g" /etc/postfix/* 2> /dev/null
			sed -i "s/domain.tld/$sys_domain/g" /etc/postfix/* 2> /dev/null
			sed -i "s/my_postfixpass/$my_postfixpass/g" /etc/postfix/sql/*
			sed -i "s/my_postfixuser/$my_postfixuser/g" /etc/postfix/sql/*
			sed -i "s/my_postfixdb/$my_postfixdb/g" /etc/postfix/sql/*
			;;
		dovecot)
			[[ -z $(grep fs.inotify.max_user_instances /etc/sysctl.conf) ]] && echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf
			sysctl -p > /dev/null
			rm -rf /etc/dovecot/* 2> /dev/null
			cp -R dovecot/conf/*.conf /etc/dovecot/
			userdel vmail 2> /dev/null
			groupadd -g 5000 vmail
			useradd -g vmail -u 5000 vmail -d /var/vmail
			chown root:dovecot "/etc/dovecot/dovecot-dict-sql.conf"; chmod 640 "/etc/dovecot/dovecot-dict-sql.conf"
			chown root:vmail "/etc/dovecot/dovecot-mysql.conf"; chmod 640 "/etc/dovecot/dovecot-mysql.conf"
			chown root:root "/etc/dovecot/dovecot.conf"; chmod 644 "/etc/dovecot/dovecot.conf"
			sed -i "s/mail.domain.tld/$sys_hostname.$sys_domain/g" /etc/dovecot/*
			sed -i "s/domain.tld/$sys_domain/g" /etc/dovecot/*
			sed -i "s/my_postfixpass/$my_postfixpass/g" /etc/dovecot/*
			sed -i "s/my_postfixuser/$my_postfixuser/g" /etc/dovecot/*
			sed -i "s/my_postfixdb/$my_postfixdb/g" /etc/dovecot/*
			mkdir -p /var/vmail/sieve
			cp dovecot/conf/spam-global.sieve /var/vmail/sieve/spam-global.sieve
			cp dovecot/conf/default.sieve /var/vmail/sieve/default.sieve
			sievec /var/vmail/sieve/spam-global.sieve
			chown -R vmail:vmail /var/vmail
			cp dovecot/conf/doverecalcq /etc/cron.daily/; chmod 755 /etc/cron.daily/doverecalcq
			cp dovecot/conf/spamlearn /etc/cron.daily/; chmod 755 /etc/cron.daily/spamlearn
			cp dovecot/conf/spamassassin_heinlein /etc/cron.daily/; chmod 755 /etc/cron.daily/spamassassin_heinlein
			;;
		clamav)
			service clamav-freshclam stop
			sed -i '/MaxFileSize/c\MaxFileSize 25M' /etc/clamav/clamd.conf
			sed -i '/StreamMaxLength/c\StreamMaxLength 25M' /etc/clamav/clamd.conf
			freshclam
			service clamav-freshclam start
			;;
		spamassassin)
			cp spamassassin/conf/local.cf /etc/spamassassin/local.cf
			sed -i '/^OPTIONS=/s/=.*/="--create-prefs --max-children 5 --helper-home-dir --username debian-spamd --socketpath \/var\/run\/spamd.sock --socketowner debian-spamd --socketgroup debian-spamd"/' /etc/default/spamassassin
			sed -i '/^CRON=/s/=.*/="1"/' /etc/default/spamassassin
			sed -i '/^ENABLED=/s/=.*/="1"/' /etc/default/spamassassin
			;;
		webserver)
			rm -rf /etc/php5/fpm/pool.d/* 2> /dev/null
			rm -rf /etc/nginx/{sites-available,sites-enabled}/* 2> /dev/null
			cp nginx/conf/sites-available/mail /etc/nginx/sites-available/mail
			ln -s /etc/nginx/sites-available/mail /etc/nginx/sites-enabled/mail
			cp php5-fpm/conf/pool/mail.conf /etc/php5/fpm/pool.d/mail.conf
			cp php5-fpm/conf/php-fpm.conf /etc/php5/fpm/php-fpm.conf
			cp nginx/conf/nginx.conf /etc/nginx/nginx.conf
			mkdir /var/lib/php5/sessions 2> /dev/null
			chown -R www-data:www-data /var/lib/php5/sessions
			sed -i "/date.timezone/c\php_admin_value[date.timezone] = $sys_timezone" /etc/php5/fpm/pool.d/mail.conf
			sed -i "/worker_processes/c\worker_processes $(($(grep ^processor /proc/cpuinfo | wc -l) *2));" /etc/nginx/nginx.conf
			;;
		postfixadmin)
			rm -rf /var/www/mail 2> /dev/null
			mkdir -p /var/www/mail/pfadmin
			cp nginx/conf/htdocs/index.php /var/www/mail/
			cp nginx/conf/htdocs/robots.txt /var/www/mail/
			cp nginx/conf/htdocs/autoconfig.xml /var/www/mail/
			sed -i "s/fufix_sub/$sys_hostname/g" /var/www/mail/autoconfig.xml
			tar xf pfadmin/inst/$postfixadmin_revision.tar -C pfadmin/inst/
			mv pfadmin/inst/$postfixadmin_revision/* /var/www/mail/pfadmin/
			cp pfadmin/conf/config.local.php /var/www/mail/pfadmin/config.local.php
			sed -i "s/my_postfixpass/$my_postfixpass/g" /var/www/mail/pfadmin/config.local.php
			sed -i "s/my_postfixuser/$my_postfixuser/g" /var/www/mail/pfadmin/config.local.php
			sed -i "s/my_postfixdb/$my_postfixdb/g" /var/www/mail/pfadmin/config.local.php
			sed -i "s/domain.tld/$sys_domain/g" /var/www/mail/pfadmin/config.local.php
			sed -i "s/change-this-to-your.domain.tld/$sys_domain/g" /var/www/mail/pfadmin/config.inc.php
			chown -R www-data: /var/www/
			rm -rf pfadmin/inst/$postfixadmin_revision
			;;
		roundcube)
			mkdir -p /var/www/mail/rc
			tar xf roundcube/inst/$roundcube_version.tar -C roundcube/inst/
			mv roundcube/inst/$roundcube_version/* /var/www/mail/rc/
			cp -R roundcube/conf/* /var/www/mail/rc/
			sed -i "s/my_postfixuser/$my_postfixuser/g" /var/www/mail/rc/plugins/password/config.inc.php
			sed -i "s/my_postfixpass/$my_postfixpass/g" /var/www/mail/rc/plugins/password/config.inc.php
			sed -i "s/my_postfixdb/$my_postfixdb/g" /var/www/mail/rc/plugins/password/config.inc.php
			sed -i "s/my_rcuser/$my_rcuser/g" /var/www/mail/rc/config/config.inc.php
			sed -i "s/my_rcpass/$my_rcpass/g" /var/www/mail/rc/config/config.inc.php
			sed -i "s/my_rcdb/$my_rcdb/g" /var/www/mail/rc/config/config.inc.php
			conf_rcdeskey=$(genpasswd)
			sed -i "s/conf_rcdeskey/$conf_rcdeskey/g" /var/www/mail/rc/config/config.inc.php
            sed -i "s/fufix_dfhost/$sys_hostname.$sys_domain/g" /var/www/mail/rc/config/config.inc.php
            sed -i "s/fufix_smtpsrv/$sys_hostname.$sys_domain/g" /var/www/mail/rc/config/config.inc.php
			chown -R www-data: /var/www/
			mysql -u $my_rcuser -p$my_rcpass $my_rcdb < /var/www/mail/rc/SQL/mysql.initial.sql
			rm -rf roundcube/inst/$roundcube_version
			rm -rf /var/www/mail/rc/installer/
			;;
		fail2ban)
			tar xf fail2ban/inst/$fail2ban_version.tar -C fail2ban/inst/
			rm -rf /etc/fail2ban/ 2> /dev/null
			(cd fail2ban/inst/$fail2ban_version ; python setup.py -q install 2> /dev/null)
			if [[ -f /lib/systemd/systemd ]]; then
				mkdir -p /var/run/fail2ban
				cp fail2ban/conf/fail2ban.service /lib/systemd/system/fail2ban.service
				systemctl enable fail2ban
			else
				cp fail2ban/conf/fail2ban.init /etc/init.d/fail2ban
				chmod +x /etc/init.d/fail2ban
				update-rc.d fail2ban defaults
			fi
			cp fail2ban/conf/jail.local /etc/fail2ban/jail.local
			rm -rf fail2ban/inst/$fail2ban_version
			;;
		rsyslogd)
			sed "s/*.*;auth,authpriv.none/*.*;auth,mail.none,authpriv.none/" -i /etc/rsyslog.conf
			;;
		restartservices)
			[[ -f /lib/systemd/systemd ]] && echo "$(textb [INFO]) - Restarting services, this may take a few seconds..."
			cat /dev/null > /var/log/mail.err
			cat /dev/null > /var/log/mail.warn
			cat /dev/null > /var/log/mail.log
			cat /dev/null > /var/log/mail.info
			for var in fail2ban rsyslog nginx php5-fpm clamav-daemon clamav-freshclam spamassassin fuglu mysql dovecot postfix
			do
				service $var stop
				sleep 1.5
				service $var start
			done
			;;
		checkdns)
			if [[ -z $(dig -x $getpublicipv4 @8.8.8.8 | grep -i $sys_domain) ]]; then
				echo "$(yellowb [WARN]) - Remember to setup a PTR record: $getpublicipv4 does not point to $sys_domain (checked by Google DNS)" | tee -a installer.log
			fi
			if [[ -z $(dig $sys_hostname.$sys_domain @8.8.8.8 | grep -i $getpublicipv4) ]]; then
				echo "$(yellowb [WARN]) - Remember to setup an A + MX record for $sys_hostname.$sys_domain pointing to $getpublicipv4 (checked by Google DNS)" | tee -a installer.log
			else
				if [[ -z $(dig mx $sys_domain @8.8.8.8 | grep -i $sys_hostname.$sys_domain) ]]; then
					echo "$(yellowb [WARN]) - Remember to setup a MX record pointing to this server (checked by Google DNS)" | tee -a installer.log
				fi
			fi
			if [[ -z $(dig $sys_domain txt @8.8.8.8 | grep -i spf) ]]; then
				echo "$(textb [HINT]) - You may want to setup a TXT record for SPF, see spfwizard.com for further information (checked by Google DNS)" | tee -a installer.log
			fi
			;;
                setupsuperadmin)
			wget --quiet --no-check-certificate -O /dev/null https://localhost/pfadmin/setup.php
			php /var/www/mail/pfadmin/scripts/postfixadmin-cli.php admin add $pfadmin_adminuser --password $pfadmin_adminpass --password2 $pfadmin_adminpass
			mysql --defaults-file=/etc/mysql/debian.cnf -e "UPDATE $my_postfixdb.admin SET superadmin='1' WHERE username='$pfadmin_adminuser';"
			;;
	esac
}
upgradetask() {
	if [[ -z $1 || ! -f $1 ]]; then
		echo "$(redb [ERR]) - \"$1\" is not a valid file"
		return 1
	fi
	if [[ ! -f /etc/fufix_version ]]; then
		echo "$(redb [ERR]) - Upgrade not yet supported"
		return 1
	fi
	sys_hostname=$(hostname)
	sys_domain=$(hostname -d)
	sys_timezone=$(cat /etc/timezone)
	timestamp=$(date +%Y%m%d_%H%M%S)
	old_des_key_rc=$(grep des_key "/var/www/mail/rc/config/config.inc.php" 2>/dev/null | awk '{ print $NF }' | cut -d "'" -f2)
	while read line
	do
		[[ ${line,,} =~ "postfix database" ]] && my_postfixdb=$(echo $line | awk '{ print $NF }')
		[[ ${line,,} =~ "postfix username" ]] && my_postfixuser=$(echo $line | awk '{ print $NF }')
		[[ ${line,,} =~ "postfix password" ]] && my_postfixpass=$(echo $line | awk '{ print $NF }')
		[[ ${line,,} =~ "roundcube database" ]] && my_rcdb=$(echo $line | awk '{ print $NF }')
		[[ ${line,,} =~ "roundcube username" ]] && my_rcuser=$(echo $line | awk '{ print $NF }')
		[[ ${line,,} =~ "roundcube password" ]] && my_rcpass=$(echo $line | awk '{ print $NF }')
	done < $1
	for var in sys_hostname sys_domain sys_timezone my_postfixdb my_postfixuser my_postfixpass my_rcuser my_rcpass my_rcdb
	do
		if [[ -z ${!var} ]]; then
			echo "$(redb [ERR]) - Log file does not contain all information"
			echo
			exit 1
		fi
	done
	echo -e "The following values were detected.\nPlease review the configuration:"
	echo "
$(textb "Hostname")        $sys_hostname
$(textb "Domain")          $sys_domain
$(textb "FQDN")            $sys_hostname.$sys_domain
$(textb "Timezone")        $sys_timezone
$(textb "Postfix MySQL")   ${my_postfixuser}:${my_postfixpass}/${my_postfixdb}
$(textb "Roundcube MySQL") ${my_rcuser}:${my_rcpass}/${my_rcdb}

-----------------------------------------------------
THIS UPGRADE WILL WILL RESET YOUR CONFIGURATION FILES
YOUR WEBROOT AND CUSTOM SITES WILL BE DELETED
-----------------------------------------------------
A backup will be stored in ./before_upgrade_$timestamp
-----------------------------------------------------
"
	read -p "Press ENTER to continue or CTRL-C to cancel the upgrade process"
	echo -en "\nStopping services, this may take a few seconds... \t\t"
	for var in fail2ban rsyslog nginx php5-fpm clamav-daemon clamav-freshclam spamassassin fuglu dovecot postfix
	do
		service $var stop > /dev/null 2>&1
	done
	echo -e "$(greenb "[OK]")"
	echo -en "Creating backups in ./before_upgrade_$timestamp... \t"
		mkdir before_upgrade_$timestamp
		cp -R /var/www/mail/ before_upgrade_$timestamp/mail_wwwroot
		cp -R /etc/{fuglu,postfix,dovecot,spamassassin,fail2ban,nginx,mysql,clamav,php5} before_upgrade_$timestamp/
	echo -e "$(greenb "[OK]")"

    echo "Update CA certificate store (self-signed only)..."
	if [[ ! -z $(openssl x509 -issuer -in /etc/ssl/mail/mail.crt | grep $sys_hostname.$sys_domain ) ]]; then
		cp /etc/ssl/mail/mail.crt /usr/local/share/ca-certificates/
		update-ca-certificates
		returnwait "Update CA certificate store" "FuGlu setup"
	fi

    returnwait "Update CA certificate store (skipped)" "FuGlu setup"

	installtask fuglu
	returnwait "FuGlu setup" "Postfix configuration"

	installtask postfix
	returnwait "Postfix configuration" "Dovecot configuration"

	installtask dovecot
	returnwait "Dovecot configuration" "ClamAV configuration"

	installtask clamav
	returnwait "ClamAV configuration" "Spamassassin configuration"

	installtask spamassassin
	returnwait "Spamassassin configuration" "Nginx configuration"

	installtask webserver
	returnwait "Nginx configuration" "Postfixadmin configuration"

	installtask postfixadmin
	returnwait "Postfixadmin configuration" "Roundcube configuration"

	# this prevents installtask roundcube from doing any mysql stuff
	mysql() {
		return 0
	}
	(export -f mysql && installtask roundcube)
	unset -f mysql
	sed -i "s/conf_rcdeskey/$old_des_key_rc/g" /var/www/mail/rc/config/config.inc.php
	/var/www/mail/rc/bin/updatedb.sh --package=roundcube --dir=/var/www/mail/rc/SQL
	returnwait "Roundcube configuration" "Fail2ban configuration"

	installtask fail2ban
	returnwait "Fail2ban configuration" "Restarting services"

	installtask restartservices
	returnwait "Restarting services" "Finish upgrade"
	exit 0
}
