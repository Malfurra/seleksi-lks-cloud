import os
import gzip
import fcntl
import atexit
import socket
import logging
import threading
from datetime import datetime, timezone

import boto3
from flask import Flask, jsonify
import pymysql

app = Flask(__name__)

# ---------------------------------------------------------
# Konfigurasi dari Environment Variable (tidak ada credential di kode).
# Isi lewat EC2 user-data / systemd service file.
# Untuk S3, credential otomatis diambil dari IAM Role EC2.
# ---------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST")
DB_USER = os.environ.get("DB_USER")
DB_PASS = os.environ.get("DB_PASS")
DB_NAME = os.environ.get("DB_NAME", "training_db")

LOG_BUCKET = os.environ.get("LOG_BUCKET")  # nama bucket S3, wajib untuk fitur upload
LOG_PREFIX = os.environ.get("LOG_PREFIX", "app-logs")
UPLOAD_INTERVAL = int(os.environ.get("LOG_UPLOAD_INTERVAL", "300"))  # detik

LOG_DIR = "/var/log/app"
LOG_PATH = os.path.join(LOG_DIR, "access.log")
STATE_PATH = os.path.join(LOG_DIR, ".s3_upload_offset")  # posisi byte terakhir yang sudah diupload
LOCK_PATH = os.path.join(LOG_DIR, ".s3_upload.lock")

os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(message)s",
)

HOSTNAME = socket.gethostname()
s3 = boto3.client("s3") if LOG_BUCKET else None


# ---------------------------------------------------------
# Upload log ke S3
# ---------------------------------------------------------
def _read_offset():
    try:
        with open(STATE_PATH) as f:
            return int(f.read().strip() or 0)
    except (FileNotFoundError, ValueError):
        return 0


def _write_offset(offset):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(offset))
    os.replace(tmp, STATE_PATH)


def upload_new_logs():
    """
    Upload hanya bagian log BARU (sejak upload terakhir) ke S3.

    File lock (flock) memastikan hanya SATU proses/worker yang meng-upload
    pada satu waktu, jadi aman dipakai dengan gunicorn multi-worker
    dan tidak menghasilkan data dobel.
    """
    if not s3:
        return

    with open(LOCK_PATH, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # worker lain sedang meng-upload

        offset = _read_offset()
        size = os.path.getsize(LOG_PATH)
        if size < offset:  # file di-rotate/dipotong, mulai dari awal
            offset = 0
        if size == offset:
            return  # tidak ada log baru

        with open(LOG_PATH, "rb") as f:
            f.seek(offset)
            data = f.read(size - offset)

        # Potong sampai baris lengkap terakhir supaya tidak mengirim baris setengah jadi
        last_newline = data.rfind(b"\n")
        if last_newline == -1:
            return
        data = data[: last_newline + 1]

        now = datetime.now(timezone.utc)
        key = f"{LOG_PREFIX}/{HOSTNAME}/{now:%Y/%m/%d}/{now:%H%M%S}-access.log.gz"

        try:
            s3.put_object(
                Bucket=LOG_BUCKET,
                Key=key,
                Body=gzip.compress(data),
                ContentType="text/plain",
                ContentEncoding="gzip",
            )
            _write_offset(offset + len(data))
            app.logger.info(f"Log diunggah ke s3://{LOG_BUCKET}/{key} ({len(data)} bytes)")
        except Exception as e:
            # Offset tidak diubah, jadi akan dicoba lagi di siklus berikutnya
            app.logger.error(f"Gagal upload log ke S3: {e}")


def _upload_loop(stop_event):
    while not stop_event.wait(UPLOAD_INTERVAL):
        upload_new_logs()


_stop_event = threading.Event()


def start_log_uploader():
    if not LOG_BUCKET:
        app.logger.warning("LOG_BUCKET tidak di-set, upload log ke S3 dinonaktifkan")
        return
    threading.Thread(target=_upload_loop, args=(_stop_event,), daemon=True).start()
    # Upload terakhir saat proses berhenti (misal instance di-terminate Auto Scaling)
    atexit.register(upload_new_logs)
    app.logger.info(
        f"Uploader aktif: s3://{LOG_BUCKET}/{LOG_PREFIX}/ tiap {UPLOAD_INTERVAL} detik"
    )


# ---------------------------------------------------------
# Database
# ---------------------------------------------------------
def get_db_connection():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        connect_timeout=5,
    )


def init_db():
    """Buat tabel 'visits' kalau belum ada. Dipanggil sekali saat start."""
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS visits (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    instance_id VARCHAR(64),
                    visited_at DATETIME
                )
                """
            )
        conn.commit()
        conn.close()
        app.logger.info("Database berhasil diinisialisasi")
    except Exception as e:
        app.logger.error(f"Gagal inisialisasi database: {e}")


init_db()
start_log_uploader()


# ---------------------------------------------------------
# Routes
# ---------------------------------------------------------
@app.route("/health")
def health():
    """Endpoint ini dipakai oleh ALB Target Group Health Check."""
    return jsonify(status="ok"), 200


@app.route("/")
def index():
    visit_count = None

    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO visits (instance_id, visited_at) VALUES (%s, %s)",
                (HOSTNAME, datetime.now(timezone.utc)),
            )
            conn.commit()
            cur.execute("SELECT COUNT(*) FROM visits")
            visit_count = cur.fetchone()[0]
        conn.close()
    except Exception as e:
        app.logger.error(f"Query database gagal: {e}")

    logging.info(f"Request dilayani oleh instance {HOSTNAME}")

    return jsonify(
        message="Halo dari Flask Training App!",
        served_by=HOSTNAME,
        total_visits=visit_count,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
