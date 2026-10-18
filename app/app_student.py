import os
import socket
import logging
from datetime import datetime, timezone

from flask import Flask, jsonify
import pymysql

app = Flask(__name__)

# ---------------------------------------------------------
# Konfigurasi koneksi database diambil dari Environment Variable
# supaya credential TIDAK di-hardcode di kode.
# Isi variabel ini nanti lewat EC2 user-data / systemd service file.
# ---------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST")
DB_USER = os.environ.get("DB_USER")
DB_PASS = os.environ.get("DB_PASS")
DB_NAME = os.environ.get("DB_NAME", "training_db")

LOG_DIR = "/var/log/app"
LOG_PATH = os.path.join(LOG_DIR, "access.log")
os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(message)s",
)


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


@app.route("/health")
def health():
    """Endpoint ini dipakai oleh ALB Target Group Health Check."""
    return jsonify(status="ok"), 200


@app.route("/")
def index():
    hostname = socket.gethostname()
    visit_count = None

    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO visits (instance_id, visited_at) VALUES (%s, %s)",
                (hostname, datetime.now(timezone.utc)),
            )
            conn.commit()
            cur.execute("SELECT COUNT(*) FROM visits")
            visit_count = cur.fetchone()[0]
        conn.close()
    except Exception as e:
        app.logger.error(f"Query database gagal: {e}")

    logging.info(f"Request dilayani oleh instance {hostname}")

    return jsonify(
        message="Halo dari Flask Training App!",
        served_by=hostname,
        total_visits=visit_count,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
