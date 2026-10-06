{
    "admin_server": {
        "listen_url": "0.0.0.0:3333",
        "use_tls": false,
        "cert_path": "gophish_admin.crt",
        "key_path": "gophish_admin.key"
    },
    "phish_server": {
        "listen_url": "0.0.0.0:8080",
        "use_tls": false,
        "cert_path": "example.crt",
        "key_path": "example.key"
    },
    "db_name": "mysql",
    "db_path": "${MYSQL_USER}:${MYSQL_PASSWORD}@(${VM1_HOST}:3306)/cyberwise_phish?charset=utf8mb4&parseTime=True&loc=UTC",
    "migrations_prefix": "db/db_",
    "contact_address": "${SUPER_ADMIN_EMAIL}",
    "logging": {
        "filename": "",
        "level": "info"
    },
    "user_service_url": "http://cyberwise-user:8080/api/v1/webhook/gophish/campaign-complete",
    "user_service_secret": "${PHISH_WEBHOOK_SECRET}"
}
