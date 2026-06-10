#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Beetinq Sense — admin panel için mock veri seed script'i
#
# Backend ÇALIŞIYOR olmalı (npm run start:dev). Bu script /api endpoint'lerine
# gerçekçi mock veri inject eder: panel demo/sunum sırasında "veri yok" değil,
# dolu ve anlaşılır görünür.
#
# İçerik:
#   • 4 beacon  (oda köşelerine yerleştirilmiş, UUID = mobil default)
#   • 6 stand   (4 yerleştirilmiş + 2 "yerleştirilmemiş" sentinel — drag-drop
#                test için panelin "Yerleştirilmemiş" bölümünü dolu gösterir)
#   • 4 fingerprint (radio map, her stand için)
#   • 5 sahte cihaz (random SHA-256 hash)
#   • 30 visit  (son ~3 saatte, farklı standlar/cihazlar, dwell 30s–15dk)
#   • 12 contact event (cihaz çiftleri, %70 stand bilgili — "hangi standda
#                       temas" panelini doldurur)
#
# Kullanım:
#   ./scripts/seed-mock.sh                       # default localhost:3000/api
#   API=http://192.168.1.42:3000/api ./scripts/seed-mock.sh
#
# Önce isterseniz wipe edin: curl -X POST $API/admin/wipe
#
# Bu script idempotent DEĞİL — her çalışmada yeni random veri ekler. Temiz
# başlangıç istiyorsanız önce wipe edin.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

API="${API:-http://localhost:3000/api}"

# Renkler (terminal destekliyorsa)
if [[ -t 1 ]]; then
  C_OK="$(printf '\033[32m')"; C_WARN="$(printf '\033[33m')"
  C_ERR="$(printf '\033[31m')"; C_DIM="$(printf '\033[2m')"; C_OFF="$(printf '\033[0m')"
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

log()  { printf "  %s\n" "$1"; }
ok()   { printf "${C_OK}✓${C_OFF} %s\n" "$1"; }
warn() { printf "${C_WARN}⚠${C_OFF} %s\n" "$1"; }
err()  { printf "${C_ERR}✗${C_OFF} %s\n" "$1" >&2; }

# ── 0. Backend erişim kontrolü ────────────────────────────────────────────────
echo "── Beetinq mock seed → $API"
if ! curl -sf -m 3 "$API/stats/summary" >/dev/null 2>&1 \
   && ! curl -sf -m 3 "$API/discover" >/dev/null 2>&1; then
  err "Backend $API'ye erişilemiyor."
  err "Önce: cd beetinq-backend && npm run start:dev"
  exit 1
fi
ok "Backend ayakta."

# Helper: POST + sessiz başarısızlık durumunda gövde göster
post() {
  local path="$1" body="$2"
  local resp http
  resp=$(curl -s -o /tmp/seed-mock-resp -w '%{http_code}' \
           -X POST "$API$path" \
           -H 'Content-Type: application/json' \
           -d "$body")
  http="$resp"
  if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
    err "POST $path → HTTP $http"
    err "Body: $body"
    err "Resp: $(cat /tmp/seed-mock-resp)"
    return 1
  fi
}

# ── 1. Beacon (4 adet, oda köşelerinde) ──────────────────────────────────────
log "1) Beacon'lar..."
UUID="E2C56DB5-DFFB-48D2-B060-D0F5A71096E0"
post /beacons "{\"uuid\":\"$UUID\",\"major\":1,\"minor\":1,\"x\":0,\"y\":0,\"name\":\"Köşe-KB\"}"
post /beacons "{\"uuid\":\"$UUID\",\"major\":1,\"minor\":2,\"x\":5,\"y\":0,\"name\":\"Köşe-KD\"}"
post /beacons "{\"uuid\":\"$UUID\",\"major\":1,\"minor\":3,\"x\":5,\"y\":5,\"name\":\"Köşe-GD\"}"
post /beacons "{\"uuid\":\"$UUID\",\"major\":1,\"minor\":4,\"x\":0,\"y\":5,\"name\":\"Köşe-GB\"}"
ok "4 beacon eklendi."

# ── 2. Stand (4 yerleştirilmiş + 2 yerleştirilmemiş) ─────────────────────────
log "2) Standlar..."
post /stands '{"name":"Giriş","x":1,"y":0.5}'
post /stands '{"name":"Sergi-A","x":2.5,"y":2}'
post /stands '{"name":"Sergi-B","x":4,"y":4}'
post /stands '{"name":"Cafe","x":1,"y":4}'
# Yerleştirilmemiş — x,y verilmedi → backend sentinel (-1,-1) atar
post /stands '{"name":"Sponsor-Stand"}'
post /stands '{"name":"Workshop-Alanı"}'
ok "6 stand eklendi (4 yerleştirilmiş + 2 yerleştirilmemiş)."

# ── 3. Fingerprint (RSSI haritaları) ─────────────────────────────────────────
# Beacon key formatı: "UUID-major-minor" (mobil beacon_controller key ile aynı).
B1="$UUID-1-1"; B2="$UUID-1-2"; B3="$UUID-1-3"; B4="$UUID-1-4"
log "3) Fingerprint'ler..."
post /fingerprints "{\"id\":\"fp-giris\",\"name\":\"Giriş\",\"rssiMap\":{\"$B1\":-55,\"$B2\":-72,\"$B3\":-85,\"$B4\":-78}}"
post /fingerprints "{\"id\":\"fp-sergi-a\",\"name\":\"Sergi-A\",\"rssiMap\":{\"$B1\":-68,\"$B2\":-62,\"$B3\":-71,\"$B4\":-75}}"
post /fingerprints "{\"id\":\"fp-sergi-b\",\"name\":\"Sergi-B\",\"rssiMap\":{\"$B1\":-82,\"$B2\":-70,\"$B3\":-58,\"$B4\":-73}}"
post /fingerprints "{\"id\":\"fp-cafe\",\"name\":\"Cafe\",\"rssiMap\":{\"$B1\":-74,\"$B2\":-83,\"$B3\":-72,\"$B4\":-60}}"
ok "4 fingerprint eklendi."

# ── 4. Sahte cihaz havuzu (5 cihaz, random SHA-256 hash) ─────────────────────
DEVICE_COUNT=5
declare -a DEVICES=()
for ((i=0; i<DEVICE_COUNT; i++)); do
  DEVICES+=("$(openssl rand -hex 32)")
done
log "4) ${DEVICE_COUNT} sahte cihaz hash'i üretildi."

# Helper: ms timestamp → ISO 8601 UTC, "X dakika önce + Y saniye" ofseti
iso_ago() {
  local mins_ago="$1" plus_sec="${2:-0}"
  date -u -v-"${mins_ago}"M -v+"${plus_sec}"S +"%Y-%m-%dT%H:%M:%SZ"
}

STANDS=(Giriş Sergi-A Sergi-B Cafe)
SOURCES=(fingerprint trilateration fingerprint fingerprint)

# ── 5. Visit'ler (80 adet, son ~8 saatte — saatlik trafik grafiği dolu olsun) ──
VISIT_COUNT=80
log "5) ${VISIT_COUNT} visit ekleniyor..."
for ((i=0; i<VISIT_COUNT; i++)); do
  DEV="${DEVICES[$((RANDOM % DEVICE_COUNT))]}"
  STAND="${STANDS[$((RANDOM % 4))]}"
  SRC="${SOURCES[$((RANDOM % 4))]}"
  MIN_AGO=$((RANDOM % 475 + 5))            # 5–480 dk öncesi (~8 saat)
  DUR=$((RANDOM % 870 + 30))               # 30–900 sn
  ENTER=$(iso_ago "$MIN_AGO" 0)
  EXIT=$(iso_ago "$MIN_AGO" "$DUR")
  CEID=$(uuidgen | tr 'A-Z' 'a-z')
  # Trilaterasyon ise hafif koordinat varyasyonu
  EXTRA=""
  if [[ "$SRC" == "trilateration" ]]; then
    JX=$(awk -v r="$RANDOM" 'BEGIN{printf "%.2f", (r%500)/100}')
    JY=$(awk -v r="$RANDOM" 'BEGIN{printf "%.2f", (r%500)/100}')
    EXTRA=",\"x\":${JX},\"y\":${JY}"
  fi
  BODY="{\"deviceId\":\"$DEV\",\"clientEventId\":\"$CEID\",\"locationName\":\"$STAND\",\"enteredAt\":\"$ENTER\",\"exitedAt\":\"$EXIT\",\"durationSeconds\":${DUR},\"positionSource\":\"$SRC\"${EXTRA}}"
  post /visit "$BODY" || warn "Visit #$i atlandı"
done
ok "${VISIT_COUNT} visit eklendi."

# ── 6. Contact event'ler (30 çift) ───────────────────────────────────────────
CONTACT_COUNT=30
log "6) ${CONTACT_COUNT} contact event ekleniyor..."
for ((i=0; i<CONTACT_COUNT; i++)); do
  A_IDX=$((RANDOM % DEVICE_COUNT))
  B_IDX=$((RANDOM % DEVICE_COUNT))
  while [[ "$B_IDX" -eq "$A_IDX" ]]; do B_IDX=$((RANDOM % DEVICE_COUNT)); done
  DEV_A="${DEVICES[$A_IDX]}"; DEV_B="${DEVICES[$B_IDX]}"
  PFX="${DEV_B:0:8}"
  SEEN="${PFX:0:4}:${PFX:4:4}"
  MIN_AGO=$((RANDOM % 475 + 5))            # 5–480 dk öncesi (~8 saat)
  DUR=$((RANDOM % 840 + 60))               # 60–900 sn
  FIRST=$(iso_ago "$MIN_AGO" 0)
  LAST=$(iso_ago "$MIN_AGO" "$DUR")
  RSSI=$(( -(55 + RANDOM % 20) ))          # -55..-74 dBm
  SAMPLE=$((DUR / 2 + 1))
  if [[ $((RANDOM % 10)) -lt 7 ]]; then
    STAND="${STANDS[$((RANDOM % 4))]}"
    LOC=",\"locationName\":\"$STAND\""
  else
    LOC=""
  fi
  CEID=$(uuidgen | tr 'A-Z' 'a-z')
  BODY="{\"deviceId\":\"$DEV_A\",\"clientEventId\":\"$CEID\",\"seenAnonId\":\"$SEEN\",\"firstSeenAt\":\"$FIRST\",\"lastSeenAt\":\"$LAST\",\"durationSeconds\":${DUR},\"avgRssi\":${RSSI},\"sampleCount\":${SAMPLE}${LOC}}"
  post /contacts "$BODY" || warn "Contact #$i atlandı"
done
ok "${CONTACT_COUNT} contact event eklendi."

# ── 7. Doğruluk (accuracy) örnekleri (40 ölçüm) ──────────────────────────────
# Mobil "Doğruluk Testi" akışını taklit eder: gerçek stand + sistem tahmini.
# correct/errorMeters BACKEND'de hesaplanır (stand'ın gerçek x,y'si serverda).
ACC_COUNT=40
ASX=(1 2.5 4 1); ASY=(0.5 2 4 4)           # /stands ile birebir koordinatlar
log "7) ${ACC_COUNT} doğruluk örneği ekleniyor..."
for ((i=0; i<ACC_COUNT; i++)); do
  DEV="${DEVICES[$((RANDOM % DEVICE_COUNT))]}"
  IDX=$((RANDOM % 4))
  GT="${STANDS[$IDX]}"; GX="${ASX[$IDX]}"; GY="${ASY[$IDX]}"
  # positionSource: %65 trilaterasyon (x,y → errorMeters), %35 fingerprint
  if [[ $((RANDOM % 100)) -lt 65 ]]; then SRC="trilateration"; else SRC="fingerprint"; fi
  # predictedLocation: %82 doğru (== GT), %18 komşu stand (yanlış isabet)
  if [[ $((RANDOM % 100)) -lt 82 ]]; then
    PRED="$GT"
  else
    PIDX=$((RANDOM % 4)); while [[ "$PIDX" -eq "$IDX" ]]; do PIDX=$((RANDOM % 4)); done
    PRED="${STANDS[$PIDX]}"
  fi
  # tahmini (x,y): gerçek stand etrafında küçük jitter (≈ -1.1..+1.1 m)
  PX=$(awk -v g="$GX" -v r="$RANDOM" 'BEGIN{printf "%.2f", g + ((r%220)-110)/100}')
  PY=$(awk -v g="$GY" -v r="$RANDOM" 'BEGIN{printf "%.2f", g + ((r%220)-110)/100}')
  BODY="{\"deviceId\":\"$DEV\",\"groundTruth\":\"$GT\",\"predictedLocation\":\"$PRED\",\"positionSource\":\"$SRC\",\"predictedX\":${PX},\"predictedY\":${PY}}"
  post /accuracy "$BODY" || warn "Accuracy #$i atlandı"
done
ok "${ACC_COUNT} doğruluk örneği eklendi."

echo
ok "Mock veri hazır. Paneli aç: ${API%/api}/"
printf "${C_DIM}İpucu: Temizlemek için → curl -X POST -H 'Content-Type: application/json' -d '{}' $API/admin/wipe${C_OFF}\n"
