#!/bin/bash

# Update and upgrade packages
apt update -y
apt upgrade -y

# Install MariaDB Server
sudo apt-get install -y mariadb-server-10.6 -y

# SQL commands to setup database and user
SQL_COMMANDS="
CREATE DATABASE IF NOT EXISTS raddb;
GRANT ALL ON raddb.* TO 'raduser'@'localhost' IDENTIFIED BY 'radpass';
FLUSH PRIVILEGES;
"

# Execute SQL commands
echo "$SQL_COMMANDS" | mysql -u root
echo "Database and user setup completed."

# Start and enable MariaDB service
systemctl start mariadb
systemctl enable mariadb

# Install FreeRADIUS, MariaDB client, and additional packages without recommendations
apt --no-install-recommends install freeradius freeradius-mysql mariadb-client -y

# Import FreeRADIUS SQL schema
cd /etc/freeradius/3.0/mods-config/sql/main/mysql
mariadb -u raduser -pradpass -D raddb < schema.sql

# Configure FreeRADIUS SQL module
sed -i 's/#\?\s*dialect = "sqlite"/        dialect = "mysql"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\?\s*driver = "rlm_sql_null"/        driver = "rlm_sql_${dialect}"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\?\s*server = "localhost"/        server = "localhost"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\s*port = 3306/        port = 3306/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\s*login = "radius"/        login = "raduser"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\s*password = "radpass"/        password = "radpass"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/\s*radius_db = "radius"/        radius_db = "raddb"/' /etc/freeradius/3.0/mods-available/sql
sed -i 's/#\s*read_clients = yes/        read_clients = yes/' /etc/freeradius/3.0/mods-available/sql
sed -Ei '/^[\t\s#]*tls\s+\{/, /[\t\s#]*\}/ s/^/#/' /etc/freeradius/3.0/mods-available/sql

# Enable FreeRADIUS SQL module
ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/

# Enable and restart FreeRADIUS service
systemctl enable freeradius
systemctl restart freeradius

# Install Apache2, PHP, and additional PHP modules
apt --no-install-recommends install apache2 php libapache2-mod-php \
                                    php-mysql php-zip php-mbstring php-common php-curl \
                                    php-gd php-db php-mail php-mail-mime \
                                    mariadb-client freeradius-utils -y

# Install Git
apt --no-install-recommends install git

# Clone daloRADIUS from GitHub
cd /var/www
git clone https://github.com/lirantal/daloradius.git

# Create log directories for Apache2/daloRADIUS
mkdir -p /var/log/apache2/daloradius/{operators,users}

# Set environment variables for Apache2/daloRADIUS
cat <<EOF >> /etc/apache2/envvars
# daloRADIUS users interface port
export DALORADIUS_USERS_PORT=80

# daloRADIUS operators interface port
export DALORADIUS_OPERATORS_PORT=8000

# daloRADIUS package root directory
export DALORADIUS_ROOT_DIRECTORY=/var/www/daloradius  

# daloRADIUS administrator's email
export DALORADIUS_SERVER_ADMIN=admin@daloradius.local
EOF

# Configure Apache2 ports for daloRADIUS
cat <<EOF > /etc/apache2/ports.conf

# daloRADIUS
Listen \${DALORADIUS_USERS_PORT}
Listen \${DALORADIUS_OPERATORS_PORT}
EOF

# Configure Apache2 virtual hosts for daloRADIUS operators and users
cat <<EOF > /etc/apache2/sites-available/operators.conf
<VirtualHost *:\${DALORADIUS_OPERATORS_PORT}>
  ServerAdmin \${DALORADIUS_SERVER_ADMIN}
  DocumentRoot \${DALORADIUS_ROOT_DIRECTORY}/app/operators
  
  <Directory \${DALORADIUS_ROOT_DIRECTORY}/app/operators>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  <Directory \${DALORADIUS_ROOT_DIRECTORY}>
    Require all denied
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/daloradius/operators/error.log
  CustomLog \${APACHE_LOG_DIR}/daloradius/operators/access.log combined
</VirtualHost>
EOF

cat <<EOF > /etc/apache2/sites-available/users.conf
<VirtualHost *:\${DALORADIUS_USERS_PORT}>
  ServerAdmin \${DALORADIUS_SERVER_ADMIN}
  DocumentRoot \${DALORADIUS_ROOT_DIRECTORY}/app/users

  <Directory \${DALORADIUS_ROOT_DIRECTORY}/app/users>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
  </Directory>

  <Directory \${DALORADIUS_ROOT_DIRECTORY}>
    Require all denied
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/daloradius/users/error.log
  CustomLog \${APACHE_LOG_DIR}/daloradius/users/access.log combined
</VirtualHost>
EOF

# Configure daloRADIUS settings
cd /var/www/daloradius/app/common/includes
cp daloradius.conf.php.sample daloradius.conf.php
chown www-data:www-data daloradius.conf.php  
chmod 664 daloradius.conf.php

# Set permissions for logging
chmod 777 /var/log/syslog
chmod 777 /var/log/dmesg
sed -i "s/\$configValues\['CONFIG_LOG_PAGES'\] = 'no';/\$configValues\['CONFIG_LOG_PAGES'\] = 'yes';/" daloradius.conf.php

# Prepare daloRADIUS directories
cd /var/www/daloradius/
mkdir -p var/{log,backup}
chown -R www-data:www-data var  
chmod -R 775 var

# Import daloRADIUS and FreeRADIUS database schemas
cd /var/www/daloradius/contrib/db
mariadb -u raduser -pradpass -D raddb < fr3-mariadb-freeradius.sql
mariadb -u raduser -pradpass -D raddb < mariadb-daloradius.sql

# Configure Apache2 sites
a2dissite 000-default.conf  
a2ensite operators.conf users.conf

# Enable and restart Apache2 service
systemctl enable apache2
systemctl restart apache2

# Get the local IP address
local_ip=$(hostname -I | awk '{print $1}')

# Change Listen IP to Current Host IP
sudo sed -i "s/ipaddr = .*/ipaddr = $local_ip/" /etc/freeradius/3.0/sites-enabled/default
sudo sed -i "s/ipaddr = .*/ipaddr = $local_ip/" /etc/freeradius/3.0/sites-enabled/inner-tunnel

echo
echo "daloRADIUS URL : http://$local_ip:8000/"
echo "daloRADIUS Username : administrator"
echo "daloRADIUS Password : radius"
echo