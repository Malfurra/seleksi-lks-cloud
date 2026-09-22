#!/bin/bash
PREFIX="yasin"                          # prefix identitas siswa
GHCR_OWNER="malfurra"                   # username GitHub siswa
GHCR_IMAGE="ghcr.io/${GHCR_OWNER}/flask-training-app"
ALB_NAME="${PREFIX}-alb"               # nama ALB dari materi 3


echo "==================================================="
echo " 9. GITHUB ACTIONS (CI/CD) -> GHCR"
echo "==================================================="
echo "Cara paling akurat: buka repo GitHub siswa -> tab 'Actions' ->"
echo "pastikan workflow 'Build and Push to GHCR' berstatus sukses"
echo "(centang hijau) pada commit terakhir."
echo ""
echo "Alternatif pakai GitHub CLI (jika sudah 'gh auth login' di CloudShell):"
echo "  gh run list --workflow=deploy.yml --limit 5"
echo ""
echo "-- Bukti image benar-benar ter-push ke GHCR: --"
echo "AWS CloudShell sudah menyediakan Docker, jadi bisa langsung ditarik:"
echo ""
echo "docker pull ${GHCR_IMAGE}:latest"
docker pull "${GHCR_IMAGE}:latest"
echo ""
echo "Jika berhasil pull, artinya workflow GitHub Actions sudah pernah"
echo "berjalan sukses dan image tersedia di GHCR."
echo "(Catatan: package GHCR siswa harus di-set 'Public' di GitHub agar"
echo "bisa di-pull tanpa login/token.)"


echo ""
echo "==================================================="
echo " 10. PYTHON / FLASK (APLIKASI BERJALAN)"
echo "==================================================="

ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[0].DNSName" --output text)

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" == "None" ]; then
  echo "ALB '$ALB_NAME' tidak ditemukan, tidak bisa test endpoint."
else
  echo "-- Test endpoint /health (harus return status 200 dan JSON status:ok) --"
  curl -i "http://$ALB_DNS/health"

  echo ""
  echo ""
  echo "-- Test endpoint / (harus return JSON dengan served_by & total_visits) --"
  curl -i "http://$ALB_DNS/"

  echo ""
  echo ""
  echo "-- Panggil beberapa kali untuk membuktikan koneksi ke RDS jalan --"
  echo "   (angka total_visits harus terus bertambah tiap request)"
  for i in 1 2 3; do
    curl -s "http://$ALB_DNS/" | python3 -c "import sys,json; d=json.load(sys.stdin); print('total_visits saat ini:', d.get('total_visits'))"
    sleep 1
  done
fi
