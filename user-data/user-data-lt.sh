#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

echo "=== [1/5] Update sistem & install Docker + cronie ==="
dnf update -y

. /etc/os-release
OS_ID="${ID}"

if [[ "${OS_ID}" == "amzn" ]]; then
  echo "Terdeteksi Amazon Linux (${OS_ID}) -> install docker dari repo default"
  dnf install -y docker cronie
elif [[ "${OS_ID}" == "rhel" ]]; then
  echo "Terdeteksi RHEL (${OS_ID}) -> install docker"
  dnf install -y docker cronie
else
  echo "OS_ID='${OS_ID}' tidak dikenali, mencoba install docker seperti biasa"
  dnf install -y docker cronie
fi

systemctl start docker
systemctl enable docker
systemctl enable --now crond
usermod -aG docker ec2-user

echo "=== [2/5] Siapkan folder log & folder script ==="
mkdir -p /home/ec2-user/app-logs
chown ec2-user:ec2-user /home/ec2-user/app-logs
mkdir -p /opt/scripts

echo "=== [3/5] Tulis script upload_log.sh ==="
cat > /opt/scripts/upload_log.sh << 'EOF'
#!/bin/bash
set -euo pipefail

BUCKET="
yasin-logs-1234"
PREFIX="logs"
LOG_FILE="/home/ec2-user/app-logs/access.log"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname)
S3_KEY="${PREFIX}/access-${HOSTNAME}-${TIMESTAMP}.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

if [ ! -f "${LOG_FILE}" ]; then
  log "Log file ${LOG_FILE} belum ada. Skip upload."
  exit 0
fi

if [ ! -s "${LOG_FILE}" ]; then
  log "Log file kosong. Skip upload."
  exit 0
fi

if aws s3 cp "${LOG_FILE}" "s3://${BUCKET}/${S3_KEY}"; then
  log "Berhasil upload ke s3://${BUCKET}/${S3_KEY}"
else
  log "Gagal upload ke S3"
  exit 1
fi
EOF

chmod +x /opt/scripts/upload_log.sh

echo "=== [4/5] Daftarkan cron job (tiap 5 menit) ==="
CRON_ENTRY="*/5 * * * * /opt/scripts/upload_log.sh >> /var/log/upload_log_cron.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "/opt/scripts/upload_log.sh" || true; echo "${CRON_ENTRY}" ) | crontab -

echo "=== [5/5] Cek status container & jalankan ==="
CONTAINER_NAME="training-app"

if docker ps -a --format '{{.Names}}' | grep -wq "${CONTAINER_NAME}"; then
  if docker ps --format '{{.Names}}' | grep -wq "${CONTAINER_NAME}"; then
    echo "Container '${CONTAINER_NAME}' sudah jalan, tidak perlu diapa-apain."
  else
    echo "Container '${CONTAINER_NAME}' ada tapi statusnya berhenti, menghidupkan ulang..."
    docker start "${CONTAINER_NAME}"
  fi
else
  echo "Container '${CONTAINER_NAME}' belum ada, membuat baru..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -e DB_HOST=yasin-db.cxysnxbk8snd.us-east-1.rds.amazonaws.com \
    -e DB_USER=admin \
    -e DB_PASS='admin123' \
    -e DB_NAME=yasin-db \
    -p 5000:5000 \
    -v /home/ec2-user/app-logs:/var/log/app \
    ghcr.io/CHANGE_ME_OWNER/CHANGE_ME_REPOSITORY:CHANGE_ME_TAG
fi

echo "=== Jalankan upload_log.sh sekali di awal (jaga-jaga) ==="
/opt/scripts/upload_log.sh || true

echo "=== User Data selesai ==="
