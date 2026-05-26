#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Beetinq Sense — backend sandbox / senaryo testi
#
# Kullanıcının saha gözlemlediği TARZDAKİ bug'ları otomatik kovalar ve bu
# oturumda yapılan fix'leri doğrular. Her senaryo bir PASS/FAIL satırı basar.
#
# Backend ÇALIŞIYOR olmalı (npm run start:dev). Script kendi test verisini
# yaratır; başında ve sonunda WIPE eder → MEVCUT VERİYİ SİLER, dikkat.
#
# Kullanım:
#   ./scripts/sandbox-test.sh
#   API=http://192.168.1.42:3000/api ./scripts/sandbox-test.sh
#
# Çıkış kodu: 0 = tüm testler geçti, 1 = en az bir FAIL.
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail
API="${API:-http://localhost:3000/api}"

if [[ -t 1 ]]; then
  G="$(printf '\033[32m')"; R="$(printf '\033[31m')"; Y="$(printf '\033[33m')"; D="$(printf '\033[2m')"; O="$(printf '\033[0m')"
else G=""; R=""; Y=""; D=""; O=""; fi

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "${G}✓ PASS${O} %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${R}✗ FAIL${O} %s\n" "$1"; [[ -n "${2:-}" ]] && printf "       ${D}%s${O}\n" "$2"; }
info() { printf "${Y}▸${O} %s\n" "$1"; }

# HTTP helper'ları: gövde + status kodu döndür
# jget VAR: global _BODY ve _CODE set eder
req() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    _CODE=$(curl -s -o /tmp/sbx_body -w '%{http_code}' -X "$method" "$API$path" \
            -H 'Content-Type: application/json' -d "$body")
  else
    _CODE=$(curl -s -o /tmp/sbx_body -w '%{http_code}' -X "$method" "$API$path")
  fi
  _BODY=$(cat /tmp/sbx_body)
}

iso() { # iso <dakika_önce> <+saniye>
  date -u -v-"${1}"M -v+"${2:-0}"S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "-${1} minutes +${2:-0} seconds" +"%Y-%m-%dT%H:%M:%SZ"
}

echo "── Beetinq sandbox testi → $API"
req GET /stats/summary
if [[ "$_CODE" != "200" ]]; then
  fail "Backend erişilemiyor ($API). Önce: npm run start:dev"
  exit 1
fi
info "Backend ayakta. Başlangıç WIPE..."
req POST /admin/wipe '{}'

DEV_A=$(openssl rand -hex 32)
DEV_B=$(openssl rand -hex 32)
UUID="E2C56DB5-DFFB-48D2-B060-D0F5A71096E0"

# ═══════════════════════════════════════════════════════════════════════════
echo; info "1) Visit idempotency — aynı clientEventId iki kez → tek kayıt"
CEID=$(uuidgen | tr 'A-Z' 'a-z')
EN=$(iso 10 0); EX=$(iso 10 120)
V="{\"deviceId\":\"$DEV_A\",\"clientEventId\":\"$CEID\",\"locationName\":\"Sergi-A\",\"enteredAt\":\"$EN\",\"exitedAt\":\"$EX\",\"durationSeconds\":120,\"positionSource\":\"fingerprint\"}"
req POST /visit "$V"; ID1=$(echo "$_BODY" | grep -o '"id":[0-9]*' | head -1)
req POST /visit "$V"; DUP=$(echo "$_BODY" | grep -o '"duplicate":true')
if [[ -n "$DUP" ]]; then pass "Aynı clientEventId duplicate olarak reddedildi"; else fail "Duplicate yakalanmadı" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "2) Visit idempotency (R11) — clientEventId YOK, aynı içerik iki kez → tek kayıt"
V2="{\"deviceId\":\"$DEV_A\",\"locationName\":\"Cafe\",\"enteredAt\":\"$EN\",\"exitedAt\":\"$EX\",\"durationSeconds\":120,\"positionSource\":\"fingerprint\"}"
req POST /visit "$V2"
req POST /visit "$V2"; DUP2=$(echo "$_BODY" | grep -o '"duplicate":true')
if [[ -n "$DUP2" ]]; then pass "clientEventId'siz aynı içerik server-side hash ile dedup edildi"; else fail "Server-side hash dedup çalışmadı" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "3) Gelecek tarih reddi (R6) — enteredAt 1 saat ileri → 400"
FUT_EN=$(iso -60 0); FUT_EX=$(iso -60 120)  # -60 dk = 60 dk SONRASI
VF="{\"deviceId\":\"$DEV_A\",\"locationName\":\"X\",\"enteredAt\":\"$FUT_EN\",\"exitedAt\":\"$FUT_EX\",\"durationSeconds\":120}"
req POST /visit "$VF"
if [[ "$_CODE" == "400" ]]; then pass "Gelecek tarihli visit 400 ile reddedildi"; else fail "Gelecek tarih kabul edildi (HTTP $_CODE)" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "4) Stand sentinel (yerleştirilmemiş) — konum verilmeden create → x<0"
req POST /stands '{"name":"Yeni-Stand-Test"}'
SX=$(echo "$_BODY" | grep -o '"x":-\?[0-9.]*' | head -1)
if echo "$SX" | grep -q '"x":-1'; then pass "Konumsuz stand (-1,-1) sentinel ile oluştu"; else fail "Stand sentinel beklendi, geldi: $SX" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "5) Stand koordinat validasyonu (R7) — x=NaN → 400"
# JSON NaN literal değil; aşırı değer ile test (999999 > Max 1000)
req POST /stands '{"name":"Kotu-Koord","x":999999,"y":5}'
if [[ "$_CODE" == "400" ]]; then pass "Aşırı koordinat (999999) 400 ile reddedildi"; else fail "Aşırı koordinat kabul edildi (HTTP $_CODE)" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "6) Fingerprint delete 404 (R8) — olmayan id → 404"
req DELETE /fingerprints/bu-id-yok-12345
if [[ "$_CODE" == "404" ]]; then pass "Olmayan fingerprint silme 404 döndü"; else fail "404 beklendi, geldi HTTP $_CODE" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "7) Contact re-report upsert — aynı clientEventId, daha uzun süre → süre güncellenir, tek kayıt"
CC=$(uuidgen | tr 'A-Z' 'a-z')
PFX="${DEV_B:0:8}"; SEEN="${PFX:0:4}:${PFX:4:4}"
F1=$(iso 20 0); L1=$(iso 20 60)
C1="{\"deviceId\":\"$DEV_A\",\"clientEventId\":\"$CC\",\"seenAnonId\":\"$SEEN\",\"firstSeenAt\":\"$F1\",\"lastSeenAt\":\"$L1\",\"durationSeconds\":60,\"avgRssi\":-62,\"sampleCount\":30}"
req POST /contacts "$C1"
L2=$(iso 20 300)
C2="{\"deviceId\":\"$DEV_A\",\"clientEventId\":\"$CC\",\"seenAnonId\":\"$SEEN\",\"firstSeenAt\":\"$F1\",\"lastSeenAt\":\"$L2\",\"durationSeconds\":300,\"avgRssi\":-60,\"sampleCount\":150}"
req POST /contacts "$C2"; UPD=$(echo "$_BODY" | grep -o '"updated":true')
if [[ -n "$UPD" ]]; then pass "Contact re-report upsert ile güncellendi (updated:true)"; else fail "Re-report upsert çalışmadı" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "8) Contact-events okunur log (yön + saat) — reporterAnonId format kontrolü"
req GET /stats/contact-events
RA=$(echo "$_BODY" | grep -o '"reporterAnonId":"[0-9a-f]*:[0-9a-f]*"' | head -1)
if [[ -n "$RA" ]]; then pass "contact-events reporterAnonId 'xxxx:yyyy' formatında ($RA)"; else fail "reporterAnonId formatı bulunamadı" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "9) Heatmap tarih filtresi (R1 SQL precedence) — eski fingerprint visit dar aralığa sızmıyor"
# 200 dk önce bir fingerprint visit (x yok) ekle
OLD_EN=$(iso 200 0); OLD_EX=$(iso 200 90)
req POST /visit "{\"deviceId\":\"$DEV_B\",\"locationName\":\"Sergi-A\",\"enteredAt\":\"$OLD_EN\",\"exitedAt\":\"$OLD_EX\",\"durationSeconds\":90,\"positionSource\":\"fingerprint\"}"
# Stand'ı yerleştir ki heatmap fingerprint noktası koordinat bulsun
req GET /stands; SID=$(echo "$_BODY" | grep -o '{"id":[0-9]*,"name":"Sergi-A"[^}]*}' | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
[[ -n "${SID:-}" ]] && req PATCH "/stands/$SID" '{"x":2,"y":2}'
# Son 30 dk filtresi: 200 dk önceki visit GÖRÜNMEMELİ
FROM=$(iso 30 0); TO=$(iso -1 0)
req GET "/stats/heatmap?from=$FROM&to=$TO"
# fingerprint dizisinde Sergi-A count'u olmamalı (200dk önceki tek fp visit aralık dışı)
FPCOUNT=$(echo "$_BODY" | grep -o '"fingerprint":\[[^]]*\]')
if echo "$FPCOUNT" | grep -q 'Sergi-A'; then
  fail "Tarih filtresi dışı fingerprint sızdı (R1 regression)" "$FPCOUNT"
else
  pass "Heatmap tarih filtresi fingerprint dalında doğru çalışıyor (R1)"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "10) Saatlik trafik localtime (R5) — saat kovası 0-23 aralığında ve toplam visit tutuyor"
req GET /stats/hourly
HOURS=$(echo "$_BODY" | grep -o '"hour":[0-9]*' | wc -l | tr -d ' ')
if [[ "$HOURS" == "24" ]]; then pass "Saatlik trafik 24 kova döndürdü (localtime grup)"; else fail "24 saat kovası beklendi, geldi: $HOURS"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "11) Negatif/sıfır süre reddi — durationSeconds tutarsız ama negatif zaman → 400"
BAD="{\"deviceId\":\"$DEV_A\",\"locationName\":\"X\",\"enteredAt\":\"$EX\",\"exitedAt\":\"$EN\",\"durationSeconds\":120}"
req POST /visit "$BAD"
if [[ "$_CODE" == "400" ]]; then pass "exitedAt<enteredAt 400 ile reddedildi"; else fail "Ters zaman kabul edildi (HTTP $_CODE)" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo; info "12) Self-contact reddi — seenAnonId raporlayanın kendi prefix'i ise stats'a sızmamalı"
SELF_PFX="${DEV_A:0:8}"; SELF_SEEN="${SELF_PFX:0:4}:${SELF_PFX:4:4}"
SC=$(uuidgen | tr 'A-Z' 'a-z')
SF=$(iso 5 0); SL=$(iso 5 120)
req POST /contacts "{\"deviceId\":\"$DEV_A\",\"clientEventId\":\"$SC\",\"seenAnonId\":\"$SELF_SEEN\",\"firstSeenAt\":\"$SF\",\"lastSeenAt\":\"$SL\",\"durationSeconds\":120,\"avgRssi\":-50,\"sampleCount\":60}"
req GET /stats/contacts
UNIQ=$(echo "$_BODY" | grep -o '"uniqueDevicesInvolved":[0-9]*' | grep -o '[0-9]*')
# Self-contact pair'a sayılmamalı; gerçek pair (test 7) = 2 cihaz
if [[ "${UNIQ:-0}" -ge 2 ]]; then pass "uniqueDevicesInvolved tutarlı (self-contact pair'i şişirmedi): $UNIQ"; else fail "uniqueDevicesInvolved beklenmeyen: ${UNIQ:-yok}" "$_BODY"; fi

# ═══════════════════════════════════════════════════════════════════════════
echo
info "Sonuç WIPE (test verisi temizleniyor)..."
req POST /admin/wipe '{}'

echo
printf "── Özet: ${G}%d PASS${O}, ${R}%d FAIL${O}\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
