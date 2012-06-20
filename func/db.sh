# Get database host
get_next_dbhost() {
    if [ -z "$host" ] || [ "$host" == 'default' ]; then
        IFS=$'\n'
        host='EMPTY_DB_HOST'
        config="$VESTA/conf/$type.conf"
        host_str=$(grep "SUSPENDED='no'" $config)
        check_row=$(echo "$host_str"|wc -l)

        if [ 0 -lt "$check_row" ]; then
            if [ 1 -eq "$check_row" ]; then
                for db in $host_str; do
                    eval $db
                    if [ "$MAX_DB" -gt "$U_DB_BASES" ]; then
                        host=$HOST
                    fi
                done
            else
                old_weight='100'
                for db in $host_str; do
                    eval $db
                    let weight="$U_DB_BASES * 100 / $MAX_DB" &>/dev/null
                    if [ "$old_weight" -gt "$weight" ]; then
                        host="$HOST"
                        old_weight="$weight"
                    fi
                done
            fi
        fi
    fi
}

# Database charset validation
is_charset_valid() {
    host_str=$(grep "HOST='$host'" $VESTA/conf/$type.conf)
    eval $host_str

    if [ -z "$(echo $CHARSETS | grep -wi $charset )" ]; then
        echo "Error: charset $charset not exist"
        log_event "$E_NOTEXIST $EVENT"
        exit $E_NOTEXIST
    fi
}

# Increase database host value
increase_dbhost_values() {
    host_str=$(grep "HOST='$host'" $VESTA/conf/$type.conf)
    eval $host_str

    old_dbbases="U_DB_BASES='$U_DB_BASES'"
    new_dbbases="U_DB_BASES='$((U_DB_BASES + 1))'"
    if [ -z "$U_SYS_USERS" ]; then
        old_users="U_SYS_USERS=''"
        new_users="U_SYS_USERS='$user'"
    else
        old_users="U_SYS_USERS='$U_SYS_USERS'"
        new_users="U_SYS_USERS='$U_SYS_USERS'"
        if [ -z "$(echo $U_SYS_USERS|sed -e "s/,/\n/g"|grep -w $user)" ]; then
            old_users="U_SYS_USERS='$U_SYS_USERS'"
            new_users="U_SYS_USERS='$U_SYS_USERS,$user'"
        fi
    fi

    sed -i "s/$old_dbbases/$new_dbbases/g" $VESTA/conf/$type.conf
    sed -i "s/$old_users/$new_users/g" $VESTA/conf/$type.conf
}

# Decrease database host value
decrease_dbhost_values() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/$TYPE.conf)
    eval $host_str

    old_dbbases="U_DB_BASES='$U_DB_BASES'"
    new_dbbases="U_DB_BASES='$((U_DB_BASES - 1))'"
    old_users="U_SYS_USERS='$U_SYS_USERS'"
    U_SYS_USERS=$(echo "$U_SYS_USERS" |\
        sed -e "s/,/\n/g"|\
        sed -e "s/^$users$//g"|\
        sed -e "/^$/d"|\
        sed -e ':a;N;$!ba;s/\n/,/g')
    new_users="U_SYS_USERS='$U_SYS_USERS'"

    sed -i "s/$old_dbbases/$new_dbbases/g" $VESTA/conf/$TYPE.conf
    sed -i "s/$old_users/$new_users/g" $VESTA/conf/$TYPE.conf
}

# Create MySQL database
add_mysql_database() {
    host_str=$(grep "HOST='$host'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="CREATE DATABASE $database CHARACTER SET $charset"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* TO '$dbuser'@'%' IDENTIFIED BY '$dbpass'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* TO '$dbuser'@'localhost'
        IDENTIFIED BY '$dbpass'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="SHOW GRANTS FOR '$dbuser'"
    md5=$(mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query")
    md5=$(echo "$md5" |grep 'PASSWORD' |tr ' ' '\n' |tail -n1 |cut -f 2 -d \')
}

# Create PostgreSQL database
add_pgsql_database() {
    host_str=$(grep "HOST='$host'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="CREATE ROLE $dbuser WITH LOGIN PASSWORD '$dbpass'"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="CREATE DATABASE $database OWNER $dbuser"
    if [ "$TPL" = 'template0' ]; then
        query="$query ENCODING '$charset' TEMPLATE $TPL"
    else
        query="$query TEMPLATE $TPL"
    fi
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="GRANT ALL PRIVILEGES ON DATABASE $database TO $dbuser"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="GRANT CONNECT ON DATABASE template1 to $dbuser"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="SELECT rolpassword FROM pg_authid WHERE rolname='$dbuser';"
    md5=$(psql -h $HOST -U $USER -p $PORT -c "$query"|grep md5|cut -f 2 -d \ )
}

# Check if database host do not exist in config 
is_dbhost_new() {
    if [ -e "$VESTA/conf/$type.conf" ]; then
        check_host=$(grep "HOST='$host'" $VESTA/conf/$type.conf)
        if [ ! -z "$check_host" ]; then
            echo "Error: db host exist"
            log_event "$E_EXISTS" "$EVENT"
            exit $E_EXISTS
        fi
    fi
}

# Check MySQL database host
is_mysql_host_alive() {
    query='SELECT VERSION()'
    mysql -h $host -u $dbuser -p$dbpass -P $port -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection to $host failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi
}

# Check PostgreSQL database host
is_pgsql_host_alive() {
    export PGPASSWORD="$dbpass"
    psql -h $host -U $dbuser -p $port -c "SELECT VERSION()" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection to $host failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi
}

# Get database values
get_database_values() {
    db_str=$(grep "DB='$database'" $USER_DATA/db.conf)
    eval $db_str
}

# Change MySQL database password
change_mysql_password() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event "$E_DB $EVENT"
        exit $E_DB
    fi

    query="GRANT ALL ON $database.* TO '$DBUSER'@'%' IDENTIFIED BY '$dbpass'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* TO '$DBUSER'@'localhost'
        IDENTIFIED BY '$dbpass'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="SHOW GRANTS FOR '$DBUSER'"
    md5=$(mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query")
    md5=$(echo "$md5" |grep 'PASSWORD' |tr ' ' '\n' |tail -n1 |cut -f 2 -d \')
}

# Change PostgreSQL database password
change_pgsql_password() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="ALTER ROLE $DBUSER WITH LOGIN PASSWORD '$dbpass'"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="SELECT rolpassword FROM pg_authid WHERE rolname='$DBUSER';"
    md5=$(psql -h $HOST -U $USER -p $PORT -c "$query"|grep md5|cut -f 2 -d \ )
}

# Delete MySQL database
delete_mysql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="DROP DATABASE $database"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="REVOKE ALL ON $database.* FROM '$DBUSER'@'%'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="REVOKE ALL ON $database.* FROM '$DBUSER'@'localhost'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    if [ "$(grep "DBUSER='$DBUSER'" $USER_DATA/db.conf |wc -l)" -lt 2 ]; then
        query="DROP USER '$DBUSER'@'%'"
        mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

        query="DROP USER '$DBUSER'@'localhost'"
        mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    fi
}

# Delete PostgreSQL database
delete_pgsql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="REVOKE ALL PRIVILEGES ON DATABASE $database FROM $DBUSER"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="DROP DATABASE $database"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    if [ "$(grep "DBUSER='$DBUSER'" $USER_DATA/db.conf |wc -l)" -lt 2 ]; then
        query="REVOKE CONNECT ON DATABASE template1 FROM $db_user"
        psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
        query="DROP ROLE $db_user"
        psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    fi
}

# Dump MySQL database
dump_mysql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    mysqldump -h $HOST -u $USER -p$PASSWORD -P$PORT -r $dump $database

    query="SHOW GRANTS FOR '$DBUSER'@'localhost'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" |\
        grep -v "Grants for" > $grants

    query="SHOW GRANTS FOR '$DBUSER'@'%'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" |\
        grep -v "Grants for" > $grants
}

# Dump PostgreSQL database
dump_pgsql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    pg_dump -h $HOST -U $USER -p $PORT -c -d -O -x -i -f $dump $database \
        2> /dev/null

    query="SELECT rolpassword FROM pg_authid WHERE rolname='$DBUSER';"
    md5=$(psql -h $HOST -U $USER -p $PORT -c "$query"|head -n1|cut -f 2 -d \ )
    pw_str="UPDATE pg_authid SET rolpassword='$md5' WHERE rolname='$DBUSER';"
    gr_str="GRANT ALL PRIVILEGES ON DATABASE $database to '$DBUSER'"
    echo -e "$pw_str\n$gr_str" >> $grants
}

# Check if database server is in use
is_dbhost_free() {
    host_str=$(grep "HOST='$host'" $VESTA/conf/$type.conf)
    eval $host_str
    if [ 0 -ne "$U_DB_BASES" ]; then
        echo "Error: host $HOST is used"
        log_event "$E_INUSE" "$EVENT"
        exit $E_INUSE
    fi
}

# Suspend MySQL database
suspend_mysql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="REVOKE ALL ON $database.* FROM '$DBUSER'@'%'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="REVOKE ALL ON $database.* FROM '$DBUSER'@'localhost'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

}

# Suspend PostgreSQL database
suspend_pgsql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="REVOKE ALL PRIVILEGES ON $database FROM $DBUSER"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
}

# Unsuspend MySQL database
unsuspend_mysql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="GRANT ALL ON $database.* FROM '$DBUSER'@'%'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* FROM '$DBUSER'@'localhost'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
}

# Unsuspend PostgreSQL database
unsuspend_pgsql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="GRANT ALL PRIVILEGES ON DATABASE $database TO $DBUSER"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
}

# Get MySQL disk usage
get_mysql_disk_usage() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="SELECT SUM( data_length + index_length ) / 1024 / 1024 \"Size\"
        FROM information_schema.TABLES WHERE table_schema='$database'"
    usage=$(mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" |tail -n1)
    if [ "$usage" == 'NULL' ] || [ "${usage:0:1}" -eq '0' ]; then
        usage=1
    fi
    usage=$(printf "%0.f\n"  $usage)
}

# Get PostgreSQL disk usage
get_pgsql_disk_usage() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="SELECT pg_database_size('$database');"
    usage=$(psql -h $HOST -U $USER -p $PORT -c "$query")
    usage=$(echo "$usage" | grep -v "-" | grep -v 'row' | sed -e "/^$/d")
    usage=$(echo "$usage" | grep -v "pg_database_size" | awk '{print $1}')
    if [ -z "$usage" ]; then
        usage=0
    fi
    usage=$(($usage / 1048576))
    if [ "$usage" -eq '0' ]; then
        usage=1
    fi
}

# Rebuild MySQL database
rebuild_mysql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/mysql.conf)
    eval $host_str
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $PORT ]; then
        echo "Error: mysql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
    if [ '0' -ne "$?" ]; then
        echo "Error: Connection failed"
        log_event  "$E_DB $EVENT"
        exit $E_DB
    fi

    query="CREATE DATABASE $database CHARACTER SET $CHARSET"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* TO '$DBUSER'@'%'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="GRANT ALL ON $database.* TO '$DBUSER'@'localhost'"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null

    query="UPDATE mysql.user SET Password='$MD5' WHERE User='$DBUSER';"
    mysql -h $HOST -u $USER -p$PASSWORD -P $PORT -e "$query" &> /dev/null
}

# Rebuild PostgreSQL database
rebuild_pgsql_database() {
    host_str=$(grep "HOST='$HOST'" $VESTA/conf/pgsql.conf)
    eval $host_str
    export PGPASSWORD="$PASSWORD"
    if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ] || [ -z $TPL ]; then
        echo "Error: postgresql config parsing failed"
        log_event "$E_PARSING" "$EVENT"
        exit $E_PARSING
    fi

    query='SELECT VERSION()'
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
    if [ '0' -ne "$?" ];  then
        echo "Error: Connection failed"
        log_event "$E_DB" "$EVENT"
        exit $E_DB
    fi

    query="CREATE ROLE $DBUSER"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="UPDATE pg_authid SET rolpassword='$MD5' WHERE rolname='$DBUSER'"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="CREATE DATABASE $database OWNER $DBUSER"
    if [ "$TPL" = 'template0' ]; then
        query="$query ENCODING '$CHARSET' TEMPLATE $TPL"
    else
        query="$query TEMPLATE $TPL"
    fi
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="GRANT ALL PRIVILEGES ON DATABASE $database TO $DBUSER"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null

    query="GRANT CONNECT ON DATABASE template1 to $dbuser"
    psql -h $HOST -U $USER -p $PORT -c "$query" &> /dev/null
}
