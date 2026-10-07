# CyberWise Platform — 2-VM Installer

The same flow as `installer-1vm-simple`, split across two VMs. Each VM has one `.env` file and one command.

| VM | Folder | Runs |
|----|--------|------|
| VM1 (infra) | `vm1-infra/` | MySQL, MinIO |
| VM2 (app)   | `vm2-app/`   | nginx, User, LMS, Web, Phish |

Copy the whole `installer-2vm/` folder to both VMs. On each one, you only use its own subfolder.

## Prerequisites

- Docker Engine and the Compose plugin on both VMs.
- `gettext-base` (for `envsubst`) on VM2.
- VM2 can reach VM1's private IP.
- Docker Hub access on VM2, if the app images are private.

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in
```

### Firewall

| VM | Port | Allow from |
|----|------|------------|
| VM1 | 3306 (MySQL), 9000 (MinIO API) | VM2's IP **only** |
| VM2 | 3000 (web app + landing page) | users / targets |
| VM2 | 10081 (User API), 10082 (LMS gRPC), 10091 (metrics) | as needed |

On VM1, MySQL and MinIO are published only on the private IP that `deploy.sh` detects. The MinIO console (9001) is bound to `127.0.0.1` only. The MySQL `root` account accepts connections only from inside its container, so VM2 always connects as the app user.

Example with `ufw` on VM1:

```bash
sudo ufw allow from <VM2-IP> to any port 3306 proto tcp
sudo ufw allow from <VM2-IP> to any port 9000 proto tcp
```

Rules added with `ufw` don't apply to ports that Docker publishes, because Docker writes its own iptables rules. The `<VM1-IP>:` binding keeps MySQL and MinIO off public interfaces, but on a shared private network you must also filter by source. Use the `DOCKER-USER` iptables chain or your cloud provider's security group for that.

## Deploy

Run the steps in this order, VM1 first.

### 1. VM1

```bash
cd installer-2vm/vm1-infra
./deploy.sh
```

On the first run, there's no `.env` yet, so the script:

1. Detects VM1's private IP from the default route (on every run, not stored in `.env`). On a VM with several interfaces, set it yourself: `VM1_PRIVATE_IP=10.0.0.5 ./deploy.sh`. It must be an address on one of the VM's interfaces, because Docker binds to it.
2. Copies `.env.example` to `.env` and generates `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD` and `MINIO_ROOT_PASSWORD` (10-character random passwords).
3. Starts MySQL and MinIO and creates a MinIO service account (see `minio-setup.sh`). If that fails, it falls back to the root credentials.
4. Waits until MySQL is healthy. The healthcheck uses TCP, so it only passes after `init-db/` has created `cyberwise_lms` and `cyberwise_phish`.
5. Writes `vm2-shared.env`, which holds VM1's IP, the DB user and password, and the MinIO keys. The file is created with mode `600`.

There's nothing to edit by hand on VM1.

### 2. Copy `vm2-shared.env` to VM2

```bash
scp vm1-infra/vm2-shared.env <user>@<VM2>:<path>/installer-2vm/vm2-app/
```

This file contains credentials. Copy it over SSH, not by chat or email.

### 3. VM2

Before the first run, set real image tags (`USER_IMAGE`, `LMS_IMAGE`, `WEB_IMAGE`, `PHISH_IMAGE`) in `vm2-app/.env.example`.

```bash
cd installer-2vm/vm2-app
./deploy.sh
```

On the first run, the script:

1. Refuses to continue if the image tags are still `x.x.x` or if `vm2-shared.env` is missing.
2. Asks for VM2's public IP or domain, which is what browsers use.
3. Copies `.env.example` to `.env`. It fills in VM1's host, DB credentials and MinIO keys from `vm2-shared.env`, and puts VM2's host into `MAIL_FORGET_PASSWORD_URL`, `MAIL_LOGIN_URL` and `NEXT_PUBLIC_LANDING_PAGE_URL`.
4. Generates `JWT_SECRET`, `LICENSE_SECRET` and `PHISH_WEBHOOK_SECRET` (64-character hex values) and `SUPER_ADMIN_PASSWORD`.
5. Prints the Super Admin login once. Write it down; the script doesn't show it again.

After that, every run (including the first):

1. Renders `phish/config.json` from `.env`.
2. Checks that `VM1:3306` and `VM1:9000` are reachable, and fails early with a clear message if they aren't.
3. Logs in to Docker Hub if credentials are set.
4. Runs `docker compose up -d`.

Once `.env` exists, delete `vm2-app/vm2-shared.env`, because it's no longer read.

On VM2, the only values left to edit by hand in `.env` are `SUPER_ADMIN_EMAIL` / `SUPER_ADMIN_NAME` and SMTP (`MAIL_*`).

`API_URL` must stay `http://cyberwise-user:8080/api/v1`, never the VM's public IP. The `web` container reads it server-side, and a container can't reliably reach its own host's published port.

The setup handles Phish the same way as the single-VM installer. Phish generates its own admin API key at first boot and stores it in `cyberwise_phish.users` on VM1. The `user` service reads the key from there, so `.env` holds no Phish key.

Plain HTTP, no TLS. This is the POC setup; see "Adding TLS later" below.

## Re-running

Re-running `deploy.sh` on either VM is safe. Once `.env` exists, the setup prompts don't run again. VM1 rewrites `vm2-shared.env` each time with the current values.

If VM1's IP or DB/MinIO credentials change later, edit `MYSQL_PASSWORD` / `DATABASE_PASSWORD`, `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` and the old VM1 IP inside the JDBC and MinIO URLs directly in `vm2-app/.env`, then rerun `deploy.sh`. **Don't delete `vm2-app/.env` to regenerate it.** Doing so issues new `JWT_SECRET` / `LICENSE_SECRET` values, which logs everyone out and invalidates existing licenses.

## Backups

All of this runs on **VM1**. One MySQL instance holds `cyberwise_user`, `cyberwise_lms` and `cyberwise_phish`. Back up and restore all three together, as a single snapshot:

```bash
docker exec cyberwise-mysql sh -c 'exec mysqldump --all-databases -uroot -p"$MYSQL_ROOT_PASSWORD"' > backup-$(date +%F).sql

# restore:
docker exec -i cyberwise-mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < backup-2026-01-01.sql
```

Don't restore only one of these databases. Restoring only `cyberwise_phish` (or only `cyberwise_user`) desyncs each company's per-tenant Phish key, stored in `cyberwise_user.company`, from Phish's own `users` table. Every Phish call then fails with "Invalid API key" until the two are back in sync.

To back up MinIO objects, use `mc mirror` against `cyberwise-minio`.

## Migrating an existing deployment

This is a data migration, not a fresh install. Carry the existing identity over instead of regenerating it:

1. Run `mysqldump --all-databases` on the old MySQL host.
2. On VM1, run `./deploy.sh`. It creates empty databases.
3. Restore the dump into VM1 (see Backups).
4. If the old `MYSQL_USER` password differs from the one now in `vm1-infra/.env`, either reset it in MySQL or update `.env` and `vm2-shared.env` to match.
5. Copy `vm2-shared.env` to VM2 and run `./deploy.sh`. If you're carrying over the old app `.env`, keep its `JWT_SECRET`, `LICENSE_SECRET` and `PHISH_WEBHOOK_SECRET`.
6. If the old deployment had MinIO objects, migrate them with `mc mirror`.

Phish needs nothing extra. The restored `cyberwise_phish.users` table already holds the admin key, and Phish's bootstrap skips creating a new admin.

## Service URLs

| Service | URL |
|---------|-----|
| Web App | `http://<VM2-HOST>:3000` |
| Phish landing page | `http://<VM2-HOST>:3000/landing` |
| User API | `http://<VM2-HOST>:10081` |
| User Metrics | `http://<VM2-HOST>:10091/actuator/prometheus` |
| LMS gRPC | `<VM2-HOST>:10082` |
| MinIO Console | `http://127.0.0.1:9001` on VM1 (`ssh -L 9001:127.0.0.1:9001 <VM1>`) |

The Phish admin UI is not published. Nobody signs in to it directly; everything goes through the `user` API.

The web app and the Phish landing page share port 3000 through nginx. Requests under `/landing/...` go to Phish, and everything else goes to the web app.

To give the landing page its own subdomain once you have a real domain:

1. Point `landing.<domain>` at VM2.
2. Edit the `server_name landing.CHANGE_ME` block in `vm2-app/nginx/default.conf`.
3. Set `NEXT_PUBLIC_LANDING_PAGE_URL=http://landing.<domain>:3000`.

## Common commands

Run these from the VM's own folder.

```bash
docker compose ps                    # status
docker compose logs -f <service>     # VM1: mysql | minio    VM2: nginx | user | lms | web | phish
docker compose restart <service>
docker compose down                  # stop (keeps data)
docker compose down -v               # VM1: stop AND delete all data — irreversible
```

## Adding TLS later

Same steps as `installer-1vm-simple`, all on VM2:

1. Get a certificate and put it in `vm2-app/nginx/certs/`.
2. Change `listen 3000;` to `listen 3000 ssl;` in `vm2-app/nginx/default.conf` and add the `ssl_*` directives.
3. Mount `./nginx/certs:/etc/nginx/certs:ro` in the `nginx` service.
4. Switch the `http://` URLs in `.env` to `https://`.
5. Run `docker compose up -d nginx`.

Traffic between VM2 and VM1 (MySQL, MinIO) stays unencrypted. Keep it on a private network.
