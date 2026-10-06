#!/bin/bash
set -e

# cyberwise_user + MYSQL_USER are already created by the official mysql image
# via MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD (set in .env). This only adds
# the other two databases Gophish and LMS need, granted to that same user.
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS cyberwise_lms
        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS cyberwise_phish
        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    GRANT ALL PRIVILEGES ON cyberwise_lms.*     TO '${MYSQL_USER}'@'%';
    GRANT ALL PRIVILEGES ON cyberwise_phish.* TO '${MYSQL_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL
