#!/bin/bash

# set -e

php -v
install_drush(){
    composer self-update
    composer global require consolidation/cgr 
	composer_home=$(find / -name .composer)
    ln -s $composer_home/vendor/bin/cgr /usr/local/bin/cgr
	cgr drush/drush 
    ln -s $composer_home/vendor/bin/drush /usr/local/bin/drush
}

setup_mariadb_data_dir(){
    test ! -d "$MARIADB_DATA_DIR" && echo "INFO: $MARIADB_DATA_DIR not found. creating ..." && mkdir -p "$MARIADB_DATA_DIR"

    # check if 'mysql' database exists
    if [ ! -d "$MARIADB_DATA_DIR/mysql" ]; then
	    echo "INFO: 'mysql' database doesn't exist under $MARIADB_DATA_DIR. So we think $MARIADB_DATA_DIR is empty."
	    echo "Copying all data files from the original folder /var/lib/mysql to $MARIADB_DATA_DIR ..."
	    cp -R --no-clobber /var/lib/mysql/. $MARIADB_DATA_DIR
    else
	    echo "INFO: 'mysql' database already exists under $MARIADB_DATA_DIR."
    fi

    rm -rf /var/lib/mysql
    ln -s $MARIADB_DATA_DIR /var/lib/mysql
    chown -R mysql:mysql $MARIADB_DATA_DIR
    test ! -d /run/mysqld && echo "INFO: /run/mysqld not found. creating ..." && mkdir -p /run/mysqld
    chown -R mysql:mysql /run/mysqld
}

start_mariadb(){
    /etc/init.d/mariadb setup
    rc-service mariadb start

    rm -f /tmp/mysql.sock
    ln -s /var/run/mysqld/mysqld.sock /tmp/mysql.sock

    # create default database 'azurelocaldb'
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS azurelocaldb; FLUSH PRIVILEGES;"
}

#unzip phpmyadmin
setup_phpmyadmin(){
    test ! -d "$PHPMYADMIN_HOME" && echo "INFO: $PHPMYADMIN_HOME not found. creating..." && mkdir -p "$PHPMYADMIN_HOME"
    cd $PHPMYADMIN_SOURCE
    tar -xf phpMyAdmin.tar.gz -C $PHPMYADMIN_HOME/ --strip-components=1 
    cp -R phpmyadmin-default.conf /etc/nginx/conf.d/default.conf   
    cd /
    rm -rf $PHPMYADMIN_SOURCE
	if [ ! $WEBSITES_ENABLE_APP_SERVICE_STORAGE ]; then
        echo "INFO: NOT in Azure, chown for "$PHPMYADMIN_HOME  
        chown -R www-data:www-data $PHPMYADMIN_HOME
	fi
}

# Generate drupal by composer
setup_drupal(){	
	mkdir -p "$DRUPAL_HOME/config/sync"
    chmod a+w "$DRUPAL_HOME/config/sync"
    chmod a+w "$DRUPAL_HOME/web/sites/default" 
    mkdir -p "$DRUPAL_HOME/web/sites/default/files"
    chmod a+w "$DRUPAL_HOME/web/sites/default/files"
    # still like to chown in Azure.
    chown -R www-data:www-data $DRUPAL_HOME     	
}

install_drush

echo "Setup openrc ..." && openrc && touch /run/openrc/softlevel

echo "INFO: creating /run/php/php7.0-fpm.sock ..."
test -e /run/php/php7.0-fpm.sock && rm -f /run/php/php7.0-fpm.sock
mkdir -p /run/php
touch /run/php/php7.0-fpm.sock
chown www-data:www-data /run/php/php7.0-fpm.sock
chmod 777 /run/php/php7.0-fpm.sock

DATABASE_TYPE=$(echo ${DATABASE_TYPE}|tr '[A-Z]' '[a-z]')
if [ "${DATABASE_TYPE}" == "local" ]; then  
    echo "Starting MariaDB and PHPMYADMIN..."
    echo 'mysql.default_socket = /run/mysqld/mysqld.sock' >> $PHP_CONF_FILE     
    echo 'mysqli.default_socket = /run/mysqld/mysqld.sock' >> $PHP_CONF_FILE     
    #setup MariaDB
    echo "INFO: loading local MariaDB and phpMyAdmin ..."
    echo "Setting up MariaDB data dir ..."
    setup_mariadb_data_dir
    echo "Setting up MariaDB log dir ..."
    test ! -d "$MARIADB_LOG_DIR" && echo "INFO: $MARIADB_LOG_DIR not found. creating ..." && mkdir -p "$MARIADB_LOG_DIR"
    chown -R mysql:mysql $MARIADB_LOG_DIR
    echo "Starting local MariaDB ..."
    start_mariadb

    echo "Granting user for phpMyAdmin ..."
    # Set default value of username/password if they are't exist/null.
    DATABASE_USERNAME=${DATABASE_USERNAME:-phpmyadmin}
    DATABASE_PASSWORD=${DATABASE_PASSWORD:-MS173m_QN}
    echo "phpmyadmin username: "$DATABASE_USERNAME    
    echo "phpmyadmin password: "$DATABASE_PASSWORD    
    mysql -u root -e "GRANT ALL ON *.* TO \`$DATABASE_USERNAME\`@'localhost' IDENTIFIED BY '$DATABASE_PASSWORD' WITH GRANT OPTION; FLUSH PRIVILEGES;"
    echo "Installing phpMyAdmin ..."
    setup_phpmyadmin
fi

# setup Drupal
if test ! -e "$DRUPAL_HOME/web/sites/default/settings.php"; then 
#Test this time, if WEBSITES_ENABLE_APP_SERVICE_STORAGE = true and drupal has already installed.
    echo "Installing Drupal ..."    
    if test -e "$DRUPAL_HOME/composer.json"; then 
        cd $DRUPAL_HOME && composer install
    else
        while test -d "$DRUPAL_HOME"  
        do
            echo "INFO: $DRUPAL_HOME is exist, clean it to ready for git..."
            mv $DRUPAL_HOME /home/site/bak$(date +%s)
        done
        composer create-project drupal-composer/drupal-project:8.x-dev  $DRUPAL_HOME --stability dev --no-interaction
    fi
    setup_drupal    
fi
cd $DRUPAL_HOME

echo "Starting Redis ..."
redis-server &
       
echo "Starting SSH ..."
rc-service sshd start

echo "Starting php-fpm ..."
php-fpm -D
chmod 777 /run/php/php7.0-fpm.sock

echo "Starting Nginx ..."
mkdir -p /home/LogFiles/nginx
if test ! -e /home/LogFiles/nginx/error.log; then 
    touch /home/LogFiles/nginx/error.log
fi
/usr/sbin/nginx -g "daemon off;"


