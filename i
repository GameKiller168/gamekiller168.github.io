#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2178,SC2128,SC2155,SC2209,SC2174,SC1010
# =====================================================================================================================
# Kirakat – EGYPARANCSOS TELEPÍTŐ (ODROID-M2, Hardkernel Ubuntu 26.04)
#
#   curl -sL https://gamekiller168.github.io/i | bash            # a friss ODROID-on, az odroid felhasználóval
#   curl -sL https://gamekiller168.github.io/i | bash -s -- --check    # csak ellenőrzés + terv, semmit nem változtat
#
# Mit csinál: letölti a legfrissebb kiadást, majd fölteszi a teljes rendszert (csomagok, lejátszó-kiosk, szerver, OTA-frissítő,
# rendszerjelszó), és a végén a kijelzőn megjelenik a QR-kód + a beállítási kód. Egyetlen JELSZÓT kér: a sudo-jelszót.
# (A tároló privát: a telepítőkódot – a GitHub-tokent – is meg kell adni, ha nem a --code-file / KIRAKAT_CODE adja; ez nem jelszó,
# hanem egy beillesztendő sor. Nyilvános tárolónál ez a kérdés elmarad.)
# Szöveges felület: lépéslista, ASCII folyamatjelző (letöltési sebesség, hátralévő idő), apt-állapot, összegző keret.
# Újrafuttatható: egy már telepített eszközön javít / frissít, az adatokhoz (/var/lib/signage) nem nyúl; megszakítás után
# ugyanazt a parancsot kell újra kiadni, a letöltés (ha ellenőrzött) újrahasznosul.
#
# Kapcsolók (mind elhagyható):
#   --version vX.Y.Z      egy adott kiadás (alap: a legfrissebb)
#   --code-file FÁJL      a telepítőkód fájlból (alternatíva: KIRAKAT_CODE környezeti változó, vagy begépelés/beillesztés)
#   --from CSOMAG|URL     a csomag helyi tar.gz-ből vagy (a PC-n futó tools/serve-installer.sh-ból) URL-ről; nincs GitHub-hozzáférés
#   --sha256 HEX          a --from csomag elvárt SHA-256 ellenőrző-összege
#   --check               csak előellenőrzés és a terv kiírása, SEMMIT nem változtat (sudo-t sem kér)
#   --yes                 nem kérdez semmit (a telepítőkód csak fájlból / környezetből jöhet)
#   --no-player           a kijelző-kiosk nem indul el (és nem is kapcsol be újraindításkor)
#   --keep-os-password    a rendszerjelszó marad, ami volt
#   --no-color            színek nélkül
#
# Biztonság: a telepítő NEM rootként fut (a sudo-t maga hívja), a letöltés privát (0700) mappába megy, a csomag minden bejegyzését
# kicsomagolás előtt ellenőrzi, a GitHub-token csak az api.github.com felé megy, fájlból (-H @fájl), sosem parancssorban,
# naplóban vagy a környezetben; átirányítást csak github.com / *.githubusercontent.com felé követ, token nélkül.
# Fontos: a teljes szkript egyetlen `main "$@"` hívással indul az utolsó sorban – egy megszakadt letöltésből semmi sem fut le.
#
# ELTÉRÉS A TERVTŐL (szándékos): a telepítő NEM olvassa ki és NEM írja ki a beállítási kódot. A szerver (server/kiosk.py) azt csak a fizikai kijelzőnek
# (a kioszk böngészőjének) adja ki, hogy hálózati kliens ne tudja megszerezni; a kód így csak a HDMI-kijelzőn látszik. A telepítő a lejátszó (systemd) stabil
# futását ellenőrzi és mondja ki; kijelző nélkül (vagy fekete képnél) a kód nem derül ki – ilyenkor kijelzőt kell csatlakoztatni (docs/INSTALL.md).
#
# A KIRAKAT_* és SIGNAGE_* környezeti változók csak teszteléshez valók (útvonalak felülírása); éles használatnál ne állítsd őket.
# =====================================================================================================================
set -Eeuo pipefail
shopt -s extglob
umask 022
ORIG_LOCALE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
export LC_ALL=C.UTF-8                      # megbízható karakterszámolás (kerethez) és angol eszköz-üzenetek (a hibafelismeréshez)

INSTALLER_REV="2026.10.2"
REPO="${KIRAKAT_REPO:-GameKiller168/odroid-signage}"
API_HOST="api.github.com"
APP_DIR="${KIRAKAT_APP_DIR:-/opt/signage}"
DATA_DIR="${KIRAKAT_DATA_DIR:-/var/lib/signage}"
LOG_FILE="${KIRAKAT_LOG:-/var/log/kirakat-install.log}"
HELPER_DIR="${SIGNAGE_HELPER_DIR:-/usr/local/lib/kirakat}"
INSTALL_STATE_DIR="${KIRAKAT_STATE_DIR:-/var/lib/kirakat-install}"
LOCAL_URL="${KIRAKAT_LOCAL_URL:-http://127.0.0.1}"
LOCAL_HTTPS_URL="${KIRAKAT_LOCAL_HTTPS_URL:-https://127.0.0.1}"
ROOT_OWNER="${KIRAKAT_ROOT_OWNER:-root}"                 # a rootnak átadott (előkészített) fájlok tulajdonosa; csak teszteléshez más
ROOT_GROUP="${KIRAKAT_ROOT_GROUP:-root}"
SYS_NET="${KIRAKAT_SYS_NET:-/sys/class/net}"
SSHD_DROPIN="${KIRAKAT_SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-signage-keyonly.conf}"
OS_RELEASE_FILE="${KIRAKAT_OS_RELEASE:-/etc/os-release}"
MEMINFO_FILE="${KIRAKAT_MEMINFO:-/proc/meminfo}"
MIN_FREE_KB="${KIRAKAT_MIN_FREE_KB:-4194304}"          # 4 GiB
MIN_RAM_KB=3000000
MIN_YEAR=2026                                            # ennél korábbi évszám = rossz óra (a telepítő ebben az évben készült)
MIN_EPOCH=1790812800                                     # 2026-10-01 00:00 UTC: a telepítő készülte; ennél korábbi „GitHub-idő” nem hihető
MAX_CLOCK_AHEAD=$((12 * 365 * 86400))                    # a (tényleg rossz) órát legfeljebb ennyivel a telepítő készülte után állítjuk be (hitelesítetlen forrásnál)
MAX_CLOCK_STEP=$((2 * 86400))                            # hitelesítetlen forrásnál, ha a helyi óra hihető: legfeljebb ekkora eltérést fogadunk el
MAX_DOWNLOAD=$((300 * 1024 * 1024))
MAX_UNPACKED=$((1024 * 1024 * 1024))
MAX_ENTRIES=50000
STEP_TOTAL=9
APT_LOCK_WAIT="${KIRAKAT_APT_LOCK_WAIT:-600}"            # mp: ennyit vár egy másik apt/dpkg folyamatra
START_WAIT="${KIRAKAT_START_WAIT:-180}"                  # mp: ennyit vár a szerver indulására
POLL="${KIRAKAT_POLL:-1}"                                # mp: a várakozó ciklusok lekérdezési üteme
PLAYER_STABLE_SECS="${KIRAKAT_PLAYER_STABLE:-6}"
HOOK_TIMEOUT="${KIRAKAT_HOOK_TIMEOUT:-300}"              # mp: egy kiegészítő horog (apt-https.sh, apply-network.sh) legfeljebb ennyi ideig futhat

# --- kapcsolók ---
WANT_VERSION="${KIRAKAT_VERSION:-}"
CODE_FILE=""
FROM="${KIRAKAT_FROM:-}"
PIN_SHA="${KIRAKAT_SHA256:-}"; PIN_OOB=0
CHECK=0; YES=0; NO_PLAYER=0; KEEP_OS_PW=0; NO_COLOR_FLAG=0

# --- futás közbeni állapot ---
APP_USER=""; APP_GROUP=""; APP_UID=""
WORK=""; WORK_LOG=""; LOG_FLUSHED=0; CACHE=""; TREE=""
SECRETS=""; RT_DIR=""; STAGE=""; RTREE=""; VERIFIED_SHA=""; SUDO_FRESH=0; RUNNING_VERSION=""; HAVE_NET_HOOK=0
HAVE_TTY=0; IS_TTY=0; COLOR=0; UNI=0; COLS=80; COMPACT=0
STEP_N=0; STEP_NAME=""; STEP_T0=0; RUN_T0=$SECONDS
INTERRUPTED=0; SIGNAME=""; FAIL_CAUSE=""; FAIL_TODO=""; IN_EXIT=0; SUDO_OK=0
KEEPALIVE_PID=""; MAIN_PID=$$; LOCK_PID=""
AUTH_HDR=""; TOKEN_FILE_OUT=""; KEY_FILE=""; HAVE_TOKEN=0; HAVE_KEY=0; PENDING_CODE=""
CONSOLE_TTY=""; ON_TTY1=0; PLAYER_DEFERRED=0
PKG_URL=""; PKG_SIZE=0
TAG=""; TARGET_VERSION=""; TARBALL_URL=""; SUMS_URL=""; SHA_ASSET_URL=""; NOTE_SHA=""; EXPECT_SHA=""; TGZ=""
INSTALLED_VERSION=""; LAYOUT="flat"; RANDOM_PW=""; OS_PW_MODE=""; CLOCK_FIX_EPOCH=""; HTTP_DATE_EPOCH=""
MAC=""; STATUS_JSON_NAME=""; STATUS_STATE=""; STATUS_CONFIGURED=""; STATUS_ID=""; SSH_NOTE=""; APT_NOTE=""; PLAYER_NOTE=""
CURL_SEC=(--proto '=https' --proto-redir '=https' --tlsv1.2)
FETCH_CODE=0; FETCH_RC=0; FETCH_HDR=""; FETCH_LOC=""
TICK=0

# =====================================================================================================================
# Python-segédek (a Python 3 szabványos könyvtárával; `python3 -I`: nem tölt be semmit a környezetből)
# =====================================================================================================================

# A telepítőkód (base64url(JSON{"t": token, "k": támogatási kulcs})) kibontása 0600-as fájlokba. Argumentumok: fejléc-fájl, token-fájl, kulcs-fájl; bemenet: a kód.
IFS= read -r -d '' PY_CODE <<'PY' || true
import base64, json, os, re, sys


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


auth_out, token_out, key_out = sys.argv[1:4]
raw = re.sub(r"\s+", "", sys.stdin.read())
if not re.fullmatch(r"[A-Za-z0-9_-]{20,2048}={0,2}", raw):
    die("a telepítőkód alakja hibás (hiányos vagy elcsúszott beillesztés?)")
body = raw.rstrip("=")
try:
    data = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode("utf-8"))
except Exception:
    die("a telepítőkód nem olvasható (hiányos beillesztés?)")
if not isinstance(data, dict):
    die("a telepítőkód nem olvasható")
t, k = data.get("t"), data.get("k")
if t is not None and not (isinstance(t, str) and 20 <= len(t) <= 255 and re.fullmatch(r"ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|[0-9a-f]{40}", t)):
    die("a telepítőkódban lévő GitHub-token alakja hibás")
if k is not None and not (isinstance(k, str) and re.fullmatch(r"[0-9a-f]{64,512}", k)):
    die("a telepítőkódban lévő támogatási kulcs alakja hibás")
if t is None and k is None:
    die("a telepítőkód üres")


def write(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as f:
        f.write(text)


if t:
    write(auth_out, "Authorization: Bearer %s\n" % t)
    write(token_out, t + "\n")
if k:
    write(key_out, k + "\n")
print("token=%d key=%d" % (1 if t else 0, 1 if k else 0))
PY

# A kiadás JSON-jának értelmezése. Argumentumok: JSON-fájl, tároló (owner/repo). Kimenet: kulcs<TAB>érték sorok. Kilépés: 3 nem JSON, 4 rossz címke, 5 rossz tarball-cím.
IFS= read -r -d '' PY_RELEASE <<'PY' || true
import json, re, sys

repo = sys.argv[2]
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
tag = d.get("tag_name")
if not (isinstance(tag, str) and re.fullmatch(r"v?\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?", tag)):
    sys.exit(4)
pre = "https://api.github.com/repos/%s/" % repo
tb = d.get("tarball_url")
if not (isinstance(tb, str) and tb.startswith(pre + "tarball/") and re.fullmatch(r"[A-Za-z0-9._~:/@%+=-]+", tb)):
    sys.exit(5)
sums = sha = ""
pkg_url, pkg_size = "", 0
for a in d.get("assets") or []:
    if not isinstance(a, dict):
        continue
    n, u = a.get("name"), a.get("url")
    if not (isinstance(n, str) and isinstance(u, str) and u.startswith(pre + "releases/assets/") and re.fullmatch(r"[A-Za-z0-9._~:/@%+=-]+", u)):
        continue
    if n == "SHA256SUMS":
        sums = u
    elif n.endswith(".sha256") and not sha:
        sha = u
    elif re.fullmatch(r"(?:kirakat|odroid-signage)-v?\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?\.tar\.gz", n) and not pkg_url:
        size = a.get("size")
        pkg_url, pkg_size = u, (size if isinstance(size, int) and 0 < size < 2**31 else 0)
notes = set(re.findall(r"(?mi)^\s*sha-?256\s*[:=]\s*([0-9a-f]{64})\s*$", d.get("body") or ""))
note = "!" if len(notes) > 1 else (next(iter(notes)).lower() if notes else "")
for key, val in (("tag", tag), ("tarball", tb), ("sums", sums), ("shaasset", sha), ("notesha", note), ("pkg", pkg_url), ("pkgsize", pkg_size),
                 ("draft", "1" if d.get("draft") else "0"), ("prerelease", "1" if d.get("prerelease") else "0")):
    print("%s\t%s" % (key, val))
PY

# Elvárt SHA-256 egy SHA256SUMS / *.sha256 fájlból. Argumentumok: fájl, címke. Kimenet: a hex (kisbetűs), vagy üres (nincs rá bejegyzés), vagy "!" (kétértelmű).
IFS= read -r -d '' PY_SUMS <<'PY' || true
import re, sys

tag = sys.argv[2].lstrip("v")
text = open(sys.argv[1], "rb").read(65536).decode("ascii", "ignore")
entries = []
for line in text.splitlines():
    m = re.match(r"\s*([0-9a-fA-F]{64})(?:\s+\*?(\S+))?\s*$", line)
    if m:
        entries.append((m.group(1).lower(), m.group(2)))
named = {"odroid-signage-v%s.tar.gz" % tag, "odroid-signage-%s.tar.gz" % tag, "kirakat-v%s.tar.gz" % tag, "kirakat-%s.tar.gz" % tag,
         "v%s.tar.gz" % tag, "%s.tar.gz" % tag, "source.tar.gz", "release.tar.gz"}
pick = [h for h, n in entries if n in named]
if not pick:
    pick = [h for h, n in entries if n is None]
if not pick:
    archives = [h for h, n in entries if n and n.endswith((".tar.gz", ".tgz"))]
    if len(archives) == 1:
        pick = archives
print("!" if len(set(pick)) > 1 else (pick[0] if pick else ""))
PY

# A letöltött csomag szerkezet-ellenőrzése kicsomagolás ELŐTT (egyetlen felső mappa; csak fájl és mappa – SEMMILYEN link: a kiadás (git archive) nem tartalmaz,
# és a láncolt linkek ellen a puszta útvonal-számolás nem véd; nincs abszolút / '..' útvonal, eszköz, hard link, setuid bit; korlátos méret és darabszám).
# Argumentumok: fájl, méretkorlát, darabkorlát. Hiba: egy magyar sor a stderr-re, kilépés 1.
IFS= read -r -d '' PY_TARCHECK <<'PY' || true
import sys, tarfile


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


limit_bytes, limit_entries = int(sys.argv[2]), int(sys.argv[3])
top, total, count = None, 0, 0
try:
    with tarfile.open(sys.argv[1], "r:gz") as tf:
        for m in tf:
            count += 1
            if count > limit_entries:
                die("túl sok bejegyzés az archívumban")
            name = m.name
            if not name or any(c in name for c in "\x00\n\r"):
                die("veszélyes útvonal az archívumban (szokatlan karakter)")
            if name.startswith("/"):
                die("veszélyes útvonal az archívumban (abszolút)")
            parts = [p for p in name.split("/") if p not in ("", ".")]
            if ".." in parts:
                die("veszélyes útvonal az archívumban (..)")
            if not parts:
                die("veszélyes útvonal az archívumban (üres név)")
            if top is None:
                top = parts[0]
            elif parts[0] != top:
                die("az archívum nem egyetlen felső mappát tartalmaz")
            if len(parts) == 1 and not m.isdir():
                die("az archívum felső szintjén fájl áll (egyetlen felső mappát várunk)")
            if m.mode & 0o7000:
                die("setuid / setgid / sticky bit az archívumban")
            if m.isreg():
                total += max(m.size, 0)
                if total > limit_bytes:
                    die("az archívum kicsomagolt mérete túl nagy")
            elif m.isdir():
                pass
            elif m.issym():
                die("szimbolikus link az archívumban (a kiadás nem tartalmazhat linket)")
            else:
                die("nem megengedett bejegyzéstípus az archívumban (hard link, eszköz vagy FIFO)")
except SystemExit:
    raise
except (tarfile.TarError, EOFError, OSError, ValueError, UnicodeError):
    die("korrupt tar.gz (az archívum nem olvasható)")
if top is None:
    die("üres archívum")
PY

# A szerver /api/public/status válaszából: ok<TAB>verzió<TAB>állapot<TAB>configured<TAB>név<TAB>azonosító (vagy "bad").
IFS= read -r -d '' PY_STATUS <<'PY' || true
import json, re, sys

try:
    d = json.loads(sys.stdin.read(65536))
    v = d["version"]
    if not (isinstance(v, str) and re.fullmatch(r"[0-9A-Za-z._+-]{1,40}", v)):
        raise ValueError
    clean = lambda x: re.sub(r"[^\w .@-]", "", str(x or ""), flags=re.UNICODE)[:60]
    print("ok\t%s\t%s\t%s\t%s\t%s" % (v, clean(d.get("state")), "1" if d.get("configured") else "0", clean(d.get("name")), clean(d.get("id"))))
except Exception:
    print("bad")
PY

# Egy HTTP `Date:` fejléc (RFC 7231) egész másodperc-időbélyeggé; üres kimenet, ha nem értelmezhető. Argumentum: a fejléc értéke.
IFS= read -r -d '' PY_DATE <<'PY' || true
import email.utils, sys

try:
    print(int(email.utils.parsedate_to_datetime(sys.argv[1]).timestamp()))
except Exception:
    print("")
PY

# Véletlen jelszó: 20 karakter az os-password.py ábécéjével, 4 × 5-ös csoportban (félreérthető 0 O 1 l I nélkül).
IFS= read -r -d '' PY_RANDPW <<'PY' || true
import secrets

A = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
print("-".join("".join(secrets.choice(A) for _ in range(5)) for _ in range(4)))
PY

# Az apt-források gazdagépei: alapból csak a http:// címeké, az "all" argumentummal a https:// címeké is. Kimenet: gazdagépenként egy sor.
IFS= read -r -d '' PY_APTHOSTS <<'PY' || true
import glob, os, re, sys

root = os.environ.get("KIRAKAT_APT_ROOT", "/etc/apt")
want_all = sys.argv[1:2] == ["all"]
hosts = []
for path in [root + "/sources.list"] + sorted(glob.glob(root + "/sources.list.d/*.list") + glob.glob(root + "/sources.list.d/*.sources")):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        for scheme, h in re.findall(r"(https?)://([A-Za-z0-9.-]+)", line):
            if (want_all or scheme == "http") and h not in hosts:
                hosts.append(h)
print("\n".join(hosts))
PY

# Az apt-források http-s címeit a megadott gazdagépekre titkosított (https) címre írja át (az eredetit <fájl>.kirakat-orig néven megőrzi). Argumentumok: gazdagépek. Root kell.
IFS= read -r -d '' PY_APTREWRITE <<'PY' || true
import glob, os, re, shutil, sys

root = os.environ.get("KIRAKAT_APT_ROOT", "/etc/apt")
hosts = [h for h in sys.argv[1:] if re.fullmatch(r"[A-Za-z0-9.-]+", h)]
for path in [root + "/sources.list"] + sorted(glob.glob(root + "/sources.list.d/*.list") + glob.glob(root + "/sources.list.d/*.sources")):
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    new = text
    for h in hosts:
        new = re.sub(r"(?m)^(?!\s*#)(.*?)http://%s(?=[/\s]|$)" % re.escape(h), r"\1https://%s" % h, new)
    if new != text:
        backup = path + ".kirakat-orig"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
        tmp = path + ".kirakat-new"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(new)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
        print("átírva: %s" % path)
PY

# =====================================================================================================================
# Megjelenítés (TUI): színek csak terminálon, NO_COLOR-t tiszteletben tartja, terminál-szélesség szerint
# =====================================================================================================================
C_RST=""; C_B=""; C_DIM=""; C_OK=""; C_WARN=""; C_BAD=""; C_HDR=""
G_OK="+"; G_BAD="x"; G_WARN="!"; G_DOT="-"; G_ELL="~"; G_ARR=">"
BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"; BOX_ML="+"; BOX_MR="+"
SPIN=('|' '/' '-' '\'); SPIN_N=4
LIVE_ON=0; BAR=""
mapfile -t LOGO <<'LOGO'
 _  __ ___  ____      _     _  __    _     _____
| |/ /|_ _||  _ \    / \   | |/ /   / \   |_   _|
| ' /  | | | |_) |  / _ \  | ' /   / _ \    | |
| . \  | | |  _ <  / ___ \ | . \  / ___ \   | |
|_|\_\|___||_| \_\/_/   \_\|_|\_\/_/   \_\  |_|
LOGO

ui_init() {
  [[ -t 1 ]] && IS_TTY=1 || IS_TTY=0
  if (( IS_TTY )) && [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb && $NO_COLOR_FLAG == 0 ]]; then COLOR=1; fi
  if (( COLOR )); then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_HDR=$'\033[1;36m'
  fi
  # Unicode csak UTF-8 területi beállításnál és nem a Linux-konzolon (annak betűkészletéből hiányozhat a jel)
  if [[ $ORIG_LOCALE =~ [Uu][Tt][Ff]-?8 && ${TERM:-} != linux ]]; then
    UNI=1
    G_OK="✔"; G_BAD="✘"; G_WARN="!"; G_DOT="·"; G_ELL="…"; G_ARR="→"
    BOX_TL="┌"; BOX_TR="┐"; BOX_BL="└"; BOX_BR="┘"; BOX_H="─"; BOX_V="│"; BOX_ML="├"; BOX_MR="┤"
    SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'); SPIN_N=10
  fi
  ui_cols
  trap 'ui_cols' WINCH
}

ui_cols() {
  local c=""
  if (( IS_TTY )); then
    if (( HAVE_TTY )); then c="$(stty size 2>/dev/null </dev/tty || true)"; c="${c##* }"; fi
    [[ $c =~ ^[0-9]+$ ]] || c="${COLUMNS:-80}"
  fi
  [[ $c =~ ^[0-9]+$ ]] || c=80
  (( c == 0 )) && c=80
  (( c < 24 )) && c=24                 # ennél keskenyebb terminálra nem tudunk értelmesen kiírni
  (( c > 110 )) && c=110
  COLS=$c
  # keskeny terminálon (pl. telefonos SSH-kliens) nincs újrarajzolás és nincs folyamatjelző-sáv: a sor tördelése esetén az újrarajzolás a görgetősávot szemetelné tele
  COMPACT=0; if (( IS_TTY && c < 50 )); then COMPACT=1; fi
}

ui_fit() {      # $1 szöveg, $2 legnagyobb szélesség → a szöveg, szükség esetén rövidítve
  local s=$1 w=$2
  (( w < 2 )) && w=2
  if (( ${#s} > w )); then printf '%s' "${s:0:w-1}$G_ELL"; else printf '%s' "$s"; fi
}

ui_live_clear() { if (( IS_TTY && LIVE_ON )); then printf '\r\033[K'; LIVE_ON=0; fi; return 0; }
ui_emit() { ui_live_clear; printf '%s\n' "$1"; }
ui_live() {     # $1 szöveg (egy sor, a végén nincs újsor; csak terminálon, és nem keskeny terminálon)
  (( IS_TTY && ! COMPACT )) || return 0
  printf '\r\033[K  %s' "$(ui_fit "$1" $((COLS - 3)))"
  LIVE_ON=1
}

ui_banner() {
  local line
  ui_emit ""
  if (( COLS >= 54 )); then
    for line in "${LOGO[@]}"; do ui_emit "  ${C_HDR}${line}${C_RST}"; done
  else
    ui_emit "  ${C_HDR}K I R A K A T${C_RST}"
  fi
  ui_text 2 "  " "  " "$C_B" "egyparancsos telepítő · ODROID-M2 · telepítő ${INSTALLER_REV}"
  if [[ -n $WANT_VERSION ]]; then ui_text 2 "  " "  " "$C_DIM" "kért kiadás: $WANT_VERSION"; fi
  log "kirakat-install $INSTALLER_REV indul (felhasználó: $APP_USER, kapcsolók: check=$CHECK yes=$YES no-player=$NO_PLAYER keep-os-password=$KEEP_OS_PW)"
}

ui_step() {     # $1 sorszám, $2 név
  STEP_N=$1; STEP_NAME=$2; STEP_T0=$SECONDS
  ui_emit ""
  ui_text 6 "${C_HDR}[$1/$STEP_TOTAL]${C_RST} " "      " "$C_B" "$2"
  log "== [$1/$STEP_TOTAL] $2"
  state_write running
}
# ui_text <látható előtag-szélesség> <első sor előtagja> <folytatósorok előtagja> <szín> <szöveg>: terminálon a szélességhez igazítva tördel (lógó behúzással)
ui_text() {
  local vis=$1 first=$2 next=$3 col=$4 text=$5 avail chunk cut rst=""
  [[ -z $col ]] || rst=$C_RST
  if (( ! IS_TTY )); then ui_emit "${first}${col}${text}${rst}"; return 0; fi
  avail=$(( COLS - 1 - vis )); if (( avail < 10 )); then avail=10; fi
  while (( ${#text} > avail )); do
    chunk=${text:0:avail}; cut=${chunk% *}
    if [[ $cut != "$chunk" && -n $cut ]]; then chunk=$cut; fi
    ui_emit "${first}${col}${chunk}${rst}"
    text=${text:${#chunk}}; text=${text##+( )}; first=$next
  done
  ui_emit "${first}${col}${text}${rst}"
}
ui_ok()   { ui_text 6 "    ${C_OK}${G_OK}${C_RST} " "      " "" "$*"; log "ok: $*"; }
ui_warn() { ui_text 6 "    ${C_WARN}${G_WARN}${C_RST} " "      " "$C_WARN" "$*"; log "figyelem: $*"; }
ui_info() { ui_text 4 "    " "    " "$C_DIM" "$*"; log "info: $*"; }
ui_item() { ui_emit "    ${C_DIM}${G_DOT}${C_RST} $(ui_fit "$*" $((COLS - 8)))"; log "-- $*"; }
ui_step_done() { ui_emit "    ${C_DIM}kész ($(fmt_dur $((SECONDS - STEP_T0))))${C_RST}"; }

fmt_dur() {     # másodperc → m:ss / h:mm:ss
  local s=$1
  if (( s >= 3600 )); then printf '%d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); else printf '%d:%02d' $((s / 60)) $((s % 60)); fi
}

fmt_bytes() {   # bájt → 1 tizedes, MB / GB / KB
  local b=$1
  if (( b >= 1073741824 )); then printf '%d.%d GB' $((b / 1073741824)) $((b % 1073741824 * 10 / 1073741824))
  elif (( b >= 1048576 )); then printf '%d.%d MB' $((b / 1048576)) $((b % 1048576 * 10 / 1048576))
  elif (( b >= 1024 )); then printf '%d.%d KB' $((b / 1024)) $((b % 1024 * 10 / 1024))
  else printf '%d B' "$b"; fi
}

ui_bar() {      # $1 százalék (0–100; -1 = ismeretlen), $2 teljes szélesség → BAR (színek nélkül)
  local pct=$1 w=$2 inner filled pad i
  inner=$((w - 2)); (( inner < 6 )) && inner=6
  if (( pct < 0 )); then
    local span=$((inner - 5)) pos
    (( span < 1 )) && span=1
    pos=$(( TICK % (2 * span) )); (( pos >= span )) && pos=$((2 * span - pos - 1))
    BAR="["; for ((i = 0; i < inner; i++)); do if (( i >= pos && i < pos + 5 )); then BAR+="="; else BAR+=" "; fi; done; BAR+="]"
    return 0
  fi
  (( pct > 100 )) && pct=100
  filled=$(( pct * inner / 100 ))
  BAR="["
  for ((i = 0; i < inner; i++)); do
    if (( i < filled - 1 || (pct == 100 && i < filled) )); then BAR+="="
    elif (( i == filled - 1 )); then BAR+=">"
    else BAR+=" "; fi
  done
  BAR+="]"
}

PROG_LAST_MS=-1; PROG_LAST_PRINT=0
ui_progress() { # $1 címke, $2 százalék (-1 = ismeretlen), $3 jobb oldali szöveg (méret, sebesség, hátralévő idő)
  local label=$1 pct=$2 right=$3 bw pcts spin lab pad
  TICK=$((TICK + 1))
  if (( ! IS_TTY || COMPACT )); then
    # nem terminál (vagy keskeny terminál): nincs újrarajzolás; csak ~10%-onként (vagy 5 mp-enként, ha a teljes méret ismeretlen) egy teljes sor
    local step=-1 now=$SECONDS
    if (( pct >= 0 )); then step=$(( pct / 10 )); if (( step > PROG_LAST_MS )); then PROG_LAST_MS=$step; else return 0; fi
    elif (( now - PROG_LAST_PRINT < 5 && PROG_LAST_PRINT != 0 )); then return 0; fi
    PROG_LAST_PRINT=$now
    if (( pct >= 0 )); then printf -v pcts '%3d%%' "$pct"; else pcts=' ...'; fi
    if (( COMPACT )); then ui_emit "$(ui_fit "    $label $pcts $right" $((COLS - 1)))"; return 0; fi
    ui_bar "$pct" 30
    printf '    %s %s  %s  %s\n' "$label" "$BAR" "$pcts" "$right"
    return 0
  fi
  spin=${SPIN[$((TICK % SPIN_N))]}
  if (( pct >= 0 )); then printf -v pcts '%3d%%' "$pct"; else pcts='  ~ '; fi
  # a sáv szélessége állandó (a jobb oldali szöveg hossza ingadozik): nincs ugrálás / villogás
  lab=$(ui_fit "$label" 10)
  printf -v pad '%*s' $(( 10 - ${#lab} )) ''
  bw=$(( COLS - 1 - (3 + 10 + 2 + 2 + 4 + 2) - 44 ))
  if (( bw < 12 )); then right=""; bw=$(( COLS - 1 - (3 + 10 + 2 + 2 + 4 + 2) )); fi
  if (( bw < 10 )); then bw=10; fi
  if (( bw > 40 )); then bw=40; fi
  ui_bar "$pct" "$bw"
  printf '\r\033[K  %s%s%s %s%s %s%s%s %s  %s' "$C_HDR" "$spin" "$C_RST" "$lab" "$pad" "$C_OK" "$BAR" "$C_RST" "$pcts" "$right"
  LIVE_ON=1
}
ui_progress_reset() { PROG_LAST_MS=-1; PROG_LAST_PRINT=0; }

ui_box() {      # soronként egy "címke|érték" argumentum (üres címke = folytatósor); "---" = elválasztó; az első argumentum a cím
  local title=$1; shift
  if (( COMPACT )); then      # keskeny terminál: keret nélkül, „címke: érték” sorok
    local crow clabel cvalue
    ui_text 2 "  " "  " "${C_OK}${C_B}" "$title"
    for crow in "$@"; do
      if [[ $crow == --- ]]; then ui_emit ""; continue; fi
      clabel=${crow%%|*}; cvalue=${crow#*|}
      if [[ -z $clabel ]]; then ui_text 4 "    " "    " "" "$cvalue"
      elif [[ $cvalue != *' '* ]] && (( ${#clabel} + 4 + ${#cvalue} > COLS - 1 )); then
        # egyetlen, nem tördelhető érték (jelszó, cím): külön sorba, hogy ne vágódjon ketté
        ui_emit "  ${C_DIM}${clabel}:${C_RST}"; ui_text 4 "    " "    " "" "$cvalue"
      else ui_text $(( ${#clabel} + 4 )) "  ${C_DIM}${clabel}:${C_RST} " "    " "" "$cvalue"; fi
    done
    return 0
  fi
  local w=$(( COLS - 4 )); (( w > 76 )) && w=76
  local inner=$(( w - 4 )) lw=15 row label value avail line chunk cut pad
  local hl="" i
  for ((i = 0; i < w - 2; i++)); do hl+="$BOX_H"; done
  ui_emit "  ${BOX_TL}${hl}${BOX_TR}"
  title="$(ui_fit "$title" "$inner")"
  printf -v pad '%*s' $(( inner - ${#title} )) ''
  ui_emit "  ${BOX_V} ${C_OK}${C_B}${title}${C_RST}${pad} ${BOX_V}"
  for row in "$@"; do
    if [[ $row == --- ]]; then ui_emit "  ${BOX_ML}${hl}${BOX_MR}"; continue; fi
    label=${row%%|*}; value=${row#*|}
    avail=$(( inner - lw - 1 ))
    while :; do
      chunk=$value
      if (( ${#chunk} > avail )); then
        chunk=${value:0:avail}; cut=${chunk% *}
        if [[ $cut != "$chunk" && -n $cut ]]; then chunk=$cut; fi
      fi
      printf -v pad '%*s' $(( avail - ${#chunk} )) ''
      printf -v line '%*s' $(( lw - ${#label} )) ''
      ui_emit "  ${BOX_V} ${C_DIM}${label}${line}${C_RST} ${chunk}${pad} ${BOX_V}"
      value=${value:${#chunk}}; value=${value##+( )}; label=""
      [[ -n $value ]] || break
    done
  done
  ui_emit "  ${BOX_BL}${hl}${BOX_BR}"
}

# =====================================================================================================================
# Napló, állapot, takarítás
# =====================================================================================================================
log() { [[ -n $WORK_LOG ]] || return 0; printf '[%(%F %T)T] %s\n' -1 "$*" >>"$WORK_LOG"; }
log_raw() { [[ -n $WORK_LOG ]] || return 0; printf '  | %s\n' "$1" >>"$WORK_LOG"; }

# A munkanapló átmásolása a /var/log alá (sudo tee -a); lépéshatárokon és kilépéskor. Ami nem megy, azt a $HOME-ba menti.
flush_log() {
  [[ -s $WORK_LOG ]] || return 0
  local total; total="$(wc -c <"$WORK_LOG")"; total=${total//[!0-9]/}
  (( total > LOG_FLUSHED )) || return 0
  if (( SUDO_OK )); then
    if [[ ! -e $LOG_FILE ]]; then
      sudo -n touch "$LOG_FILE" 2>/dev/null && sudo -n chmod 640 "$LOG_FILE" 2>/dev/null || true
      sudo -n chgrp adm "$LOG_FILE" 2>/dev/null || true
    fi
    if tail -c +$((LOG_FLUSHED + 1)) "$WORK_LOG" | sudo -n tee -a "$LOG_FILE" >/dev/null 2>&1; then LOG_FLUSHED=$total; return 0; fi
  fi
  return 1
}

STATE_FILE=""
state_write() { [[ -n $STATE_FILE ]] || return 0; printf 'status=%s\nstep=%s\nname=%s\ntag=%s\n' "$1" "$STEP_N" "$STEP_NAME" "$TAG" >"$STATE_FILE" 2>/dev/null || true; }

wipe_secrets() {   # a titkos munkafájlok biztonságos törlése és a memóriában tartott jelszó nullázása
  local f
  shred_file "$AUTH_HDR"; shred_file "$TOKEN_FILE_OUT"; shred_file "$KEY_FILE"
  if [[ -n $SECRETS && -d $SECRETS ]]; then for f in "$SECRETS"/*; do shred_file "$f"; done; fi
  RANDOM_PW=""; PENDING_CODE=""
}

# A rootnak előkészített (gyökér-tulajdonú) másolat törlése: a titkos / hitelesített állomány ne maradjon a lemezen.
unstage_root() {
  [[ -n $STAGE ]] || return 0
  if (( SUDO_OK )); then sudo -n rm -rf -- "${STAGE:?}" >/dev/null 2>&1 || true; fi
  STAGE=""; RTREE=""
}

shred_file() { [[ -f ${1:-} ]] || return 0; shred -u -- "$1" 2>/dev/null || rm -f -- "$1"; }

# A gyerekfolyamatok megkeresése a /proc-ból (részfolyamat nélkül: a kilépési csapdában futó `$(pgrep …)` egy jelzett `read -t` után a bash-t összeomlaszthatta)
CHILDREN=()
children_of() { # $1 pid → CHILDREN tömb
  CHILDREN=()
  local f pid line fields
  for f in /proc/[0-9]*/stat; do
    line=""
    { read -r line <"$f"; } 2>/dev/null || continue
    line=${line##*) }
    read -ra fields <<<"$line"
    if [[ ${fields[1]:-} == "$1" ]]; then pid=${f#/proc/}; CHILDREN+=("${pid%/stat}"); fi
  done
}

kill_tree() {   # $1 pid, $2 jel
  local pid=$1 sig=${2:-TERM} c
  local -a kids
  children_of "$pid"; kids=("${CHILDREN[@]}")
  for c in "${kids[@]}"; do kill_tree "$c" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

cleanup_children() {
  local c
  local -a kids
  children_of $$; kids=("${CHILDREN[@]}")
  for c in "${kids[@]}"; do kill_tree "$c" TERM; done
}

on_signal() {   # $1 jel neve
  INTERRUPTED=1; SIGNAME=$1
  case $1 in INT) exit 130;; TERM) exit 143;; *) exit 129;; esac
}

ERR_INFO=""
on_err() {      # ERR csapda: váratlan hiba (csak feljegyzi; a kiírást a kilépési csapda végzi)
  local rc=$1 line=$2 cmd=$3
  [[ -n $ERR_INFO ]] || ERR_INFO="váratlan hiba a telepítőben (kilépési kód $rc, a ${line}. sor: ${cmd:0:80})"
  return 0
}

on_exit() {
  local rc=$?
  # Fontos: ha a jel egy `IFS= read …` közben érkezett, a csapda az ideiglenes (üres) IFS-sel fut → a szószétvágás nem működne (árva gyerekfolyamatok maradnának)
  IFS=$' \t\n'
  trap '' INT TERM HUP
  if (( IN_EXIT )); then return 0; fi
  IN_EXIT=1
  set +e +u
  if [[ -n $KEEPALIVE_PID ]]; then kill_tree "$KEEPALIVE_PID" TERM; fi
  cleanup_children
  ui_live_clear
  if (( IS_TTY )); then printf '\033[?25h'; fi
  if (( HAVE_TTY )); then stty echo </dev/tty 2>/dev/null; fi
  if (( INTERRUPTED )); then
    FAIL_CAUSE="megszakítva (${SIGNAME:-jel})"
    ui_emit ""
    ui_text 2 "${C_WARN}${G_WARN} " "  " "" "Megszakítva. A rendszer konzisztens állapotban maradt: félig megírt fájl nem maradt."
    if [[ -n $RANDOM_PW && $OS_PW_MODE == random-applied ]]; then show_random_pw; fi
    ui_text 2 "  " "  " "" "Futtasd újra ugyanazt a parancsot: folytatja ott, ahol abbahagyta."
  elif (( rc != 0 )); then
    show_failure "$rc"
  fi
  log "kilépés: kód $rc${FAIL_CAUSE:+ – $FAIL_CAUSE}"
  if (( rc != 0 )); then state_write failed; fi
  if (( rc != 0 || SUDO_OK )); then flush_log || save_log_home; fi
  unstage_root
  # a sudo-jegyet, amit mi szereztünk meg (jelszóbekéréssel), nem hagyjuk melegen: a telepítő után a felhasználó shell-je ne kapjon 15 percig jelszó nélküli sudo-t
  if (( SUDO_FRESH )); then sudo -k >/dev/null 2>&1; fi
  wipe_secrets
  if [[ -n $SECRETS && $SECRETS != "$WORK" && -d $SECRETS && $SECRETS == */kirakat-install.* ]]; then rm -rf -- "${SECRETS:?}"; fi
  if [[ -n $WORK && -d $WORK && $WORK == */kirakat-install.* ]]; then rm -rf -- "${WORK:?}"; fi
  exit "$rc"
}

LOG_SAVED_AT=""
save_log_home() {
  [[ -s $WORK_LOG ]] || return 0
  local f="${HOME:-/tmp}/kirakat-install.log"      # az utolsó (hibás) futás teljes naplója; sudo nélkül ez az egyetlen hely
  if ( umask 077; cat "$WORK_LOG" >"$f" ) 2>/dev/null; then LOG_SAVED_AT=$f; fi
  return 0
}

# fail "ok" "teendő": a hibaüzenet mindig megmondja, mit kell tenni. A kiírást a kilépési csapda végzi (egyszer, egységesen).
fail() {
  FAIL_CAUSE=$1; FAIL_TODO=${2:-"Futtasd újra ugyanazt a parancsot: folytatja."}
  log "HIBA: $FAIL_CAUSE | teendő: $FAIL_TODO"
  exit 1
}

show_failure() {
  local rc=$1 where="" logpath="$LOG_FILE"
  if (( STEP_N > 0 )); then where=" a(z) ${STEP_N}. lépésnél (${STEP_NAME})"; fi
  if [[ -z $FAIL_CAUSE ]]; then explain_from_log; fi
  if [[ -z $FAIL_CAUSE ]]; then
    FAIL_CAUSE="${ERR_INFO:-ismeretlen hiba (kilépési kód $rc)}"
    FAIL_TODO="Nézd meg a naplót, majd futtasd újra ugyanazt a parancsot; ha marad a hiba, küldd el a naplót a fejlesztőnek."
  fi
  if ! flush_log; then save_log_home; logpath="${LOG_SAVED_AT:-$WORK_LOG}"; fi
  ui_emit ""
  ui_text 2 "${C_BAD}${C_B}${G_BAD}${C_RST} " "  " "${C_BAD}${C_B}" "A telepítés megállt${where}."
  ui_text 10 "  ${C_B}Ok:${C_RST}     " "          " "" "$FAIL_CAUSE"
  ui_text 10 "  ${C_B}Teendő:${C_RST} " "          " "" "$FAIL_TODO"
  ui_text 10 "  ${C_B}Napló:${C_RST}  " "          " "" "$logpath"
  if [[ -s $WORK_LOG ]]; then
    ui_emit "  ${C_DIM}A napló utolsó 25 sora:${C_RST}"
    local l
    # terminálon a sor szélességhez igazítva; nem terminálon (napló / tee) teljes hosszban
    while IFS= read -r l; do
      if (( IS_TTY )); then l="$(ui_fit "$l" $((COLS - 6)))"; fi
      ui_emit "  ${C_DIM}|${C_RST} $l"
    done < <(tail -n 25 "$WORK_LOG")
  fi
  if [[ -n $RANDOM_PW && $OS_PW_MODE == random-applied ]]; then show_random_pw; fi
  ui_emit ""
  ui_text 2 "  " "  " "$C_B" "Futtasd újra ugyanazt a parancsot: folytatja."
}

# A már beállított, de az összegzésben még meg nem mutatott véletlen jelszó (megszakításkor / hibakor ez az egyetlen esély, hogy lássa a gazda).
show_random_pw() {
  ui_emit ""
  ui_text 4 "  ${C_WARN}${G_WARN}${C_RST} " "    " "" "Az új rendszerjelszó már érvényes – jegyezd fel: ${C_B}${RANDOM_PW}${C_RST}"
  ui_text 4 "    " "    " "$C_DIM" "(Az újrafuttatás új jelszót állít be, és azt mutatja meg az összegzésben.)"
}

# A napló végéből felismert gyakori okok → egyszerű magyar magyarázat és teendő
explain_from_log() {
  [[ -s $WORK_LOG ]] || return 0
  local t; t="$(tail -n 80 "$WORK_LOG")"
  case $t in
    *"No space left on device"*|*"Disk quota exceeded"*) FAIL_CAUSE="megtelt a lemez"; FAIL_TODO="Szabadíts fel helyet (df -h mutatja), majd futtasd újra ugyanazt a parancsot." ;;
    *"Could not get lock"*|*"Unable to acquire the dpkg frontend lock"*|*"Could not open lock file"*) FAIL_CAUSE="egy másik csomagkezelő (apt/dpkg, pl. automatikus frissítés) még fut"; FAIL_TODO="Várj 5–10 percet, majd futtasd újra ugyanazt a parancsot." ;;
    *"Temporary failure resolving"*|*"Could not resolve"*|*"Name or service not known"*) FAIL_CAUSE="a névfeloldás (DNS) nem működik"; FAIL_TODO="Ellenőrizd a hálózati kábelt és a DHCP/DNS beállítást (kérd meg az IT-t), majd futtasd újra." ;;
    *"Failed to fetch"*|*"Unable to connect"*|*"Connection timed out"*|*"Connection failed"*|*"Could not connect"*) FAIL_CAUSE="a csomagtár (apt) nem érhető el a hálózaton"; FAIL_TODO="Kérd meg az IT-t: 443-as (HTTPS) kimenő forgalom a csomagtárakhoz (az /etc/apt forrásaiban szereplő gazdagépek: pl. ports.ubuntu.com, archive.ubuntu.com, security.ubuntu.com és a Hardkernel tára), majd futtasd újra." ;;
    *"Hash Sum mismatch"*|*"GPG error"*|*"NO_PUBKEY"*) FAIL_CAUSE="a csomagtár tartalma nem hiteles (hash/aláírás hiba)"; FAIL_TODO="Ellenőrizd az órát (date), várj pár percet, majd futtasd újra." ;;
    *"dpkg was interrupted"*|*"dpkg: error processing"*) FAIL_CAUSE="egy korábbi csomagtelepítés félbemaradt"; FAIL_TODO="Futtasd újra ugyanazt a parancsot: a telepítő rendbe teszi (dpkg --configure -a)." ;;
    *"Permission denied"*) FAIL_CAUSE="jogosultsági hiba"; FAIL_TODO="Futtasd újra a parancsot az odroid felhasználóval (nem rootként), és add meg a sudo-jelszót." ;;
  esac
}

# =====================================================================================================================
# Segédek
# =====================================================================================================================
need_cmd() { command -v "$1" >/dev/null 2>&1; }

now_ms() {      # NOW_MS változóba (nincs részfolyamat)
  local t=${EPOCHREALTIME:-}
  if [[ -n $t ]]; then t=${t/[.,]/}; NOW_MS=$(( t / 1000 )); else NOW_MS=$(( $(date +%s) * 1000 )); fi
}

file_size() {   # FSIZE változóba
  local s; s="$(wc -c <"$1" 2>/dev/null || true)"; s=${s//[!0-9]/}; FSIZE=${s:-0}
}

hdr_get() {     # $1 fejléc-fájl, $2 név (kisbetűvel) → az utolsó előfordulás értéke
  local f=$1 want=$2 l v=""
  [[ -r $f ]] || return 0
  while IFS= read -r l; do
    l=${l%$'\r'}
    [[ ${l,,} == "$want":* ]] && v=${l#*:} && v=${v# }
  done <"$f"
  printf '%s' "$v"
}

strip_url() { local u=$1; printf '%s' "${u%%\?*}"; }   # naplóba csak lekérdezési rész (aláírt token) nélküli cím kerülhet

nearest_dir() { local p=$1; while [[ ! -d $p && $p != / && -n $p ]]; do p=$(dirname -- "$p"); done; printf '%s' "$p"; }
free_kb_of() {  # a legközelebbi létező szülőmappát tartalmazó fájlrendszer szabad helye (KiB)
  local d a
  local -a f
  d="$(nearest_dir "$1")"
  a="$(df -Pk -- "$d" 2>/dev/null | tail -n 1 || true)"
  read -ra f <<<"$a"
  printf '%s' "${f[3]:-0}"
}

primary_mac() { # az alapértelmezett útvonal csatolójának MAC-je (mint a server/ospasswd.py primary_mac), kisbetűs, kettőspontos
  local ifc="" l m="" i
  local -a w
  l="$(ip route show default 2>/dev/null | head -n 1 || true)"
  read -ra w <<<"$l"
  for i in "${!w[@]}"; do if [[ ${w[$i]} == dev ]]; then ifc=${w[$((i + 1))]:-}; break; fi; done
  [[ $ifc =~ ^[A-Za-z0-9_.:-]+$ ]] || ifc=eth0
  [[ -r $SYS_NET/$ifc/address ]] || ifc=eth0
  if [[ -r $SYS_NET/$ifc/address ]]; then read -r m <"$SYS_NET/$ifc/address" || true; fi
  printf '%s' "${m,,}"
}

# --- terminál-bemenet (a parancs `curl | bash`-ből jön, ezért minden kérdés a /dev/tty-ról olvas) ---
detect_tty() { if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; else HAVE_TTY=0; fi; }

prompt_hidden() {   # $1 kérdés → PROMPT_REPLY (szóközök nélkül); 1, ha nincs terminál
  PROMPT_REPLY=""
  (( HAVE_TTY )) || return 1
  printf '%s' "$1" >/dev/tty
  IFS= read -r -s PROMPT_REPLY </dev/tty || true
  printf '\n' >/dev/tty
  PROMPT_REPLY=${PROMPT_REPLY//[[:space:]]/}
}

# Egyetlen példány: a zárat egy külön „tartó” folyamat fogja (flock), amely a telepítő kilépésével magától megszűnik. (Ha a zárfájl leírója a gyerekfolyamatokban is nyitva
# maradna, egy leváló démon – pl. egy csomag szkriptje – a telepítő után is tartaná a zárat, és minden újrafuttatás „másik telepítő fut”-ot mondana.)
acquire_lock() { # $1 zárfájl
  local ok="$WORK/lock.ok" i
  rm -f -- "$ok"
  # (a tartó külső `sleep` nélkül vár – a bash `read -t`-jével –, így nem hagyhat maga után árva gyerekfolyamatot)
  flock -n "$1" bash -c 'echo ok >"$2"; while kill -0 "$1" 2>/dev/null; do read -r -t 2 <> <(:) || true; done' _ "$$" "$ok" >/dev/null 2>&1 </dev/null &
  LOCK_PID=$!
  for ((i = 0; i < 40; i++)); do
    [[ -e $ok ]] && return 0
    kill -0 "$LOCK_PID" 2>/dev/null || { [[ -e $ok ]] && return 0; return 1; }
    sleep 0.05
  done
  [[ -e $ok ]]
}

# --- sudo ---
SUDO=(sudo -n)
need_sudo() {
  if sudo -n true 2>/dev/null; then SUDO_OK=1; ui_ok "sudo: használható (jelszó nélkül / már megadva)"; start_keepalive; return 0; fi
  if (( ! HAVE_TTY )); then
    fail "a sudo jelszót kér, de nincs terminál, ahol be lehetne írni" "Lépj be SSH-val terminállal (ssh -t odroid@<cím>) vagy a konzolon, és ott futtasd a parancsot."
  fi
  ui_info "A sudo jelszavát kérem (ez az egyetlen jelszó, amit a telepítés kér)."
  ui_live_clear
  if ! sudo -v -p "A(z) %p felhasználó jelszava (sudo): " </dev/tty; then
    fail "a sudo nem fogadta el a jelszót, vagy a(z) $APP_USER felhasználó nem használhat sudo-t" "Futtasd újra a parancsot, és gépeld be pontosan az odroid felhasználó jelszavát (a gépelés közben nem látszik semmi)."
  fi
  SUDO_OK=1; SUDO_FRESH=1
  ui_ok "sudo: rendben (a telepítés végéig érvényben tartom, utána érvénytelenítem)"
  start_keepalive
}

start_keepalive() {   # a sudo-jegy frissítése a háttérben, hogy a hosszú apt-futás közben ne járjon le
  ( trap 'exit 0' TERM
    while :; do sleep 40 & wait $!; sudo -n -v 2>/dev/null || exit 0; kill -0 "$MAIN_PID" 2>/dev/null || exit 0; done ) >/dev/null 2>&1 &
  KEEPALIVE_PID=$!
}

# --- parancs futtatása naplózva (kimenet a naplóba; hibánál a napló vége látszik) ---
# A parancs a háttérben fut, mi a `wait`-en várunk: csak a `wait` szakítható meg azonnal egy jellel (egy előtérben futó hosszú parancs mellett a csapda csak a végén futna le).
run_logged() {  # parancs… → kilépési kód
  local rc=0 pid
  log "futtatás: ${*:1:6}"
  "$@" >>"$WORK_LOG" 2>&1 </dev/null &
  pid=$!
  wait "$pid" || rc=$?
  return "$rc"
}

# kritikus szakasz: közben a Ctrl-C / TERM nem szakít (az átnevezések egészben végbemennek: a gyerekfolyamatok is örökölik a „figyelmen kívül hagyást”)
crit_begin() { trap '' INT TERM HUP; }
crit_end() { install_signal_traps; }
install_signal_traps() { trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP; }

# =====================================================================================================================
# Letöltés: kézi átirányítás-követés, token csak az api.github.com felé, folyamatjelző
# =====================================================================================================================
url_ok() {
  local u=$1 host re_lan='^https?://[][A-Za-z0-9.:-]+(/|$)'
  [[ $u != *[[:space:][:cntrl:]\"\\\\]* ]] || return 1       # szóköz, vezérlőjel, idézőjel és fordított perjel nem lehet a címben
  if [[ $FROM_MODE == url ]]; then [[ $u =~ $re_lan ]]; return; fi
  [[ $u =~ ^https://([A-Za-z0-9.-]+)(/|$) ]] || return 1
  host="${BASH_REMATCH[1],,}"
  case $host in api.github.com|github.com|codeload.github.com|*.githubusercontent.com) return 0;; esac
  return 1
}
FROM_MODE=""

# fetch_follow URL KIMENET [auth 0|1] [Accept] [max bájt] [max mp] [folyamatjelző-címke] [várt méret]
fetch_follow() {
  local url=$1 out=$2 auth=${3:-0} accept=${4:-} maxbytes=${5:-$((50 * 1024 * 1024))} maxtime=${6:-60} label=${7:-} total=${8:-0}
  local hops=0 wfile="$WORK/curl.w" errf="$WORK/curl.err" hdr="$WORK/curl.hdr" pid rc line
  local -a args
  FETCH_HDR=$hdr; FETCH_CODE=0; FETCH_RC=0; FETCH_LOC=""
  while (( hops <= 5 )); do
    url_ok "$url" || { FETCH_RC=-1; log "nem engedélyezett cím: $(strip_url "$url")"; return 1; }
    args=("${CURL_SEC[@]}" -sS --connect-timeout 15 --max-time "$maxtime" --speed-limit 1024 --speed-time 30 --max-filesize "$maxbytes"
          -H "User-Agent: kirakat-install/$INSTALLER_REV" -D "$hdr" -o "$out" -w '%{http_code} %{redirect_url}')
    [[ -z $accept ]] || args+=(-H "Accept: $accept")
    # a token KIZÁRÓLAG az api.github.com-ra megy (fejléc-fájlból), átirányítási célra soha
    if [[ $auth == 1 && -n $AUTH_HDR && $url == "https://$API_HOST/"* ]]; then args+=(-H "@$AUTH_HDR"); fi
    : >"$out"; : >"$wfile"; : >"$errf"
    # a cím (az átirányítás aláírt, rövid életű `?token=…` lekérdezést is tartalmazhat) konfig-fájlból megy, nem a parancssorból: `ps`-ben nem látszik
    ( umask 077; printf 'url = "%s"\n' "$url" >"$SECRETS/curl.cfg" )
    log "GET $(strip_url "$url")$([[ $auth == 1 && -n $AUTH_HDR && $url == "https://$API_HOST/"* ]] && echo ' (tokennel)')"
    curl "${args[@]}" -K "$SECRETS/curl.cfg" >"$wfile" 2>"$errf" </dev/null &
    pid=$!
    if [[ -n $label ]]; then dl_monitor "$pid" "$out" "$hdr" "$label" "$total" "$maxbytes"; fi
    rc=0; wait "$pid" || rc=$?
    FETCH_RC=$rc
    if (( rc != 0 )); then
      line="$(head -n 1 "$errf" 2>/dev/null || true)"; log "curl hiba ($rc): ${line:0:200}"
      return 1
    fi
    line="$(cat "$wfile")"
    FETCH_CODE=${line%% *}; FETCH_LOC=${line#* }
    [[ $FETCH_CODE =~ ^[0-9]+$ ]] || FETCH_CODE=0
    case $FETCH_CODE in
      200) return 0 ;;
      301|302|303|307|308) [[ -n $FETCH_LOC ]] || return 1; url=$FETCH_LOC; hops=$((hops + 1)); log "átirányítás → $(strip_url "$url")" ;;
      *) log "HTTP $FETCH_CODE"; return 1 ;;
    esac
  done
  log "túl sok átirányítás"
  return 1
}

# hálózati hibák (időszakos) újrapróbálása; 4xx nem
fetch_retry() {
  local i
  for i in 1 2 3; do
    if fetch_follow "$@"; then return 0; fi
    case $FETCH_RC in
      0) if (( FETCH_CODE >= 500 )); then :; else return 1; fi ;;
      6|7|18|28|35|52|55|56) : ;;
      *) return 1 ;;
    esac
    if (( i < 3 )); then ui_warn "Átmeneti hálózati hiba, újrapróbálom ($((i + 1))/3)…"; sleep $((i * 2)); fi
  done
  return 1
}

DL_TOO_BIG=0
dl_monitor() {  # $1 curl-pid, $2 fájl, $3 fejléc-fájl, $4 címke, $5 várt méret (0 = ismeretlen), $6 felső korlát
  local pid=$1 f=$2 hdr=$3 label=$4 total=${5:-0} max=$6 t0 size=0 pct right speed eta len avg i
  local -a ts=() ss=()
  now_ms; t0=$NOW_MS
  ui_progress_reset
  DL_TOO_BIG=0
  while kill -0 "$pid" 2>/dev/null; do
    now_ms; file_size "$f"; size=$FSIZE
    if (( size > max )); then kill "$pid" 2>/dev/null || true; DL_TOO_BIG=1; break; fi
    if [[ -s $hdr ]]; then
      len="$(hdr_get "$hdr" content-length)"
      if [[ $len =~ ^[0-9]+$ ]] && (( len > 0 )); then total=$len; fi
    fi
    # sebesség: az utolsó ~3 mp mozgóablaka
    ts+=("$NOW_MS"); ss+=("$size")
    while (( ${#ts[@]} > 2 && NOW_MS - ts[0] > 3000 )); do ts=("${ts[@]:1}"); ss=("${ss[@]:1}"); done
    speed=0
    if (( NOW_MS - ts[0] > 0 )); then speed=$(( (size - ss[0]) * 1000 / (NOW_MS - ts[0]) )); fi
    if (( total > 0 )); then
      pct=$(( size * 100 / total )); if (( pct > 99 )); then pct=99; fi
      eta=""; if (( speed > 0 )); then eta=" ETA $(fmt_dur $(( (total - size) / speed )))"; fi
      right="$(fmt_bytes "$size") / $(fmt_bytes "$total")  $(fmt_bytes "$speed")/s$eta"
    else
      pct=-1
      right="$(fmt_bytes "$size")  $(fmt_bytes "$speed")/s"
    fi
    # átirányítási (üres) lépésnél nincs mit mutatni: a sáv az első adat megérkezésekor jelenik meg
    if (( size > 0 )); then ui_progress "$label" "$pct" "$right"; fi
    sleep 0.2
  done
  # záró sor (a kész állapot): a teljes méret és az átlagsebesség
  file_size "$f"; size=$FSIZE
  now_ms; i=$(( NOW_MS - t0 )); (( i < 1 )) && i=1
  avg=$(( size * 1000 / i ))
  if (( IS_TTY )); then ui_live_clear; fi
  if (( size > 0 )); then
    local tail_txt="100%  $(fmt_bytes "$size")  átlag $(fmt_bytes "$avg")/s  ($(fmt_dur $(( i / 1000 ))))" bw
    if (( COMPACT )); then
      ui_text 4 "    " "      " "" "$label kész: $(fmt_bytes "$size"), átlag $(fmt_bytes "$avg")/s ($(fmt_dur $(( i / 1000 ))))"
    else
      bw=$(( COLS - 6 - ${#label} - ${#tail_txt} - 2 )); if (( bw > 30 )); then bw=30; fi; if (( bw < 10 )); then bw=10; fi
      ui_bar 100 "$bw"
      ui_emit "    $label $BAR $tail_txt"
    fi
    log "letöltve: $size bájt, átlag $avg B/s"
  fi
}

# =====================================================================================================================
# 1. lépés – előellenőrzés
# =====================================================================================================================
NET_FAILS=(); CLOCK_SUSPECT=0
probe_https() {   # $1 gazdagép → 0 elérhető; egyébként PROBE_RC; a Date fejléc a $WORK/probe.hdr-ben
  local rc=0 code pid
  : >"$WORK/probe.code"
  curl "${CURL_SEC[@]}" -sS -I -o /dev/null -D "$WORK/probe.hdr" -w '%{http_code}' --connect-timeout 8 --max-time 15 \
       -H "User-Agent: kirakat-install/$INSTALLER_REV" "https://$1/" >"$WORK/probe.code" 2>"$WORK/probe.err" </dev/null &
  pid=$!
  wait "$pid" || rc=$?                      # a háttérben fut, hogy egy jel azonnal megszakíthassa
  code="$(<"$WORK/probe.code")"
  PROBE_RC=$rc
  if (( rc == 0 )) && [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then return 0; fi
  log "probe $1: curl=$rc http=${code:-?} $(head -n 1 "$WORK/probe.err" 2>/dev/null)"
  return 1
}

explain_net() {   # $1 gazdagép $2 curl-kód → sor a hibalistába
  case $2 in
    6)  printf '%s' "$1: a név nem oldható fel (DNS) – ellenőrizd a hálózati kábelt és a DNS-t" ;;
    7|28) printf '%s' "$1:443 nem érhető el – kérd meg az IT-t: 443-as kimenő forgalom a github.com és api.github.com felé" ;;
    35|51|58|59|60|77|83) printf '%s' "$1: titkosítási (TLS) hiba – rossz óra, vagy a céges hálózat átvizsgálja a HTTPS-t" ;;
    *)  printf '%s' "$1: a kapcsolat sikertelen (curl: $2) – kérd meg az IT-t: 443-as kimenő forgalom a github.com és api.github.com felé" ;;
  esac
}

step_preflight() {
  ui_step 1 "Előellenőrzés"
  local arch osid ver name mem="" free free2 tool l
  local -a missing=() w

  ui_ok "felhasználó: $APP_USER (nem root; a root-lépésekhez a sudo-t használom)"

  arch="$(uname -m)"
  if [[ $arch == aarch64 || $arch == arm64 ]]; then ui_ok "architektúra: $arch"
  elif [[ ${KIRAKAT_ALLOW_ANY_ARCH:-0} == 1 ]]; then ui_warn "architektúra: $arch (nem ODROID-M2; csak teszteléshez engedélyezett)"
  else fail "ez a telepítő ODROID-M2-re (aarch64) készült, itt: $arch" "Az ODROID-M2-n, az odroid felhasználóval futtasd a parancsot."; fi

  osid=""; ver=""; name=""
  if [[ -r $OS_RELEASE_FILE ]]; then
    while IFS= read -r l; do
      case $l in ID=*) osid=${l#ID=}; osid=${osid//\"/};; VERSION_ID=*) ver=${l#VERSION_ID=}; ver=${ver//\"/};; PRETTY_NAME=*) name=${l#PRETTY_NAME=}; name=${name//\"/};; esac
    done <"$OS_RELEASE_FILE"
  fi
  if [[ $osid == ubuntu && $ver == 26.04 ]]; then ui_ok "rendszer: ${name:-Ubuntu 26.04}"
  else ui_warn "rendszer: ${name:-ismeretlen} – a telepítő Ubuntu 26.04-re (Hardkernel image) készült; folytatom, de nem garantált"; fi

  if [[ -r $MEMINFO_FILE ]]; then
    while IFS= read -r l; do if [[ $l == MemTotal:* ]]; then read -ra w <<<"$l"; mem=${w[1]:-}; break; fi; done <"$MEMINFO_FILE"
  fi
  if [[ $mem =~ ^[0-9]+$ ]]; then
    if (( mem >= MIN_RAM_KB )); then ui_ok "memória: $(fmt_bytes $((mem * 1024)))"
    else ui_warn "memória: csak $(fmt_bytes $((mem * 1024))) – a videóátalakítás lassú lehet"; fi
  fi

  free="$(free_kb_of "${APP_DIR%/*}")"; free2="$(free_kb_of "$CACHE")"
  if (( free2 < free )); then free=$free2; fi
  if (( free >= MIN_FREE_KB )); then ui_ok "szabad hely: $(fmt_bytes $((free * 1024))) (kell: $(fmt_bytes $((MIN_FREE_KB * 1024))))"
  else fail "kevés a szabad hely: $(fmt_bytes $((free * 1024))), legalább $(fmt_bytes $((MIN_FREE_KB * 1024))) kell" "Szabadíts fel helyet (df -h, apt clean), majd futtasd újra ugyanazt a parancsot."; fi

  for tool in tar gzip python3 sha256sum flock mktemp; do need_cmd "$tool" || missing+=("$tool"); done
  if [[ $FROM_MODE != file ]]; then need_cmd curl || missing+=(curl); fi
  if (( ${#missing[@]} )); then
    fail "hiányzó program: ${missing[*]}" "A Hardkernel Ubuntu image tartalmazza ezeket – ellenőrizd, hogy a megfelelő image fut-e; apt nélkül a telepítő nem tudja pótolni."
  fi
  ui_ok "szükséges programok megvannak (curl, tar, python3, …)"

  probe_network
}

probe_network() {
  local h rc=0 f hh cc hard=0
  NET_FAILS=(); CLOCK_SUSPECT=0
  if [[ $FROM_MODE == file ]]; then
    ui_ok "hálózat: a csomag helyi fájlból jön, a GitHubot nem érem el"
    clock_check; probe_apt_hosts; return 0
  fi
  if [[ $FROM_MODE == url ]]; then
    local fh=${FROM#*://} code
    fh=${fh%%/*}
    ui_live "hálózat: $fh…"
    code="$(curl "${CURL_SEC[@]}" -sS -I -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "${FROM%/*}/" 2>"$WORK/probe.err" </dev/null)" || rc=$?
    ui_live_clear
    if (( rc == 0 )); then ui_ok "hálózat: $fh elérhető"
    else fail "a csomag forrása ($fh) nem érhető el" "Ellenőrizd, hogy a PC-n fut a tools/serve-installer.sh, és a két gép egy hálózaton van (tűzfal: a megadott port)."; fi
    clock_check; probe_apt_hosts; return 0
  fi
  for h in "$API_HOST" github.com codeload.github.com; do
    ui_live "hálózat: $h…"
    if probe_https "$h"; then
      ui_ok "hálózat: $h:443 elérhető"
      if [[ -z $HTTP_DATE_EPOCH ]]; then set_http_date; fi
    else
      NET_FAILS+=("$h|$PROBE_RC")
      case $PROBE_RC in 35|51|58|59|60|77|83) CLOCK_SUSPECT=1;; esac
    fi
  done
  ui_live_clear
  # a kiadás-mellékletek (a saját csomag, a SHA256SUMS) a GitHub tárolóján át, átirányítással érkeznek: a régi és az új gazdagép is lehet
  for h in objects.githubusercontent.com release-assets.githubusercontent.com; do
    if ! probe_https "$h"; then ui_warn "$h:443 nem érhető el – a kiadás-mellékletek (csomag, SHA256SUMS) letöltése hibázhat; kérd meg az IT-t, hogy engedélyezze"; fi
  done
  clock_check
  probe_apt_hosts
  for f in "${NET_FAILS[@]}"; do
    hh=${f%%|*}; cc=${f##*|}
    case $cc in
      35|51|58|59|60|77|83) ui_warn "$(explain_net "$hh" "$cc")$([[ $CLOCK_SUSPECT == 1 ]] && echo ' (az óra javítása után újrapróbálom)')" ;;
      *) hard=1; ui_text 6 "    ${C_BAD}${G_BAD}${C_RST} " "      " "" "$(explain_net "$hh" "$cc")"; log "hálózati hiba: $hh curl=$cc" ;;
    esac
  done
  if (( hard )); then
    fail "a GitHub nem érhető el ebből a hálózatból" "Kérd meg az IT-t: 443-as kimenő forgalom a github.com és api.github.com felé (és codeload.github.com, objects.githubusercontent.com, release-assets.githubusercontent.com). Ha kész, futtasd újra ugyanazt a parancsot."
  fi
}

set_http_date() {   # a legutóbbi probe Date fejlécéből
  local d; d="$(hdr_get "$WORK/probe.hdr" date)"
  if [[ -z $d ]]; then return 0; fi
  HTTP_DATE_EPOCH="$(python3 -I -c "$PY_DATE" "$d" 2>/dev/null || true)"
  if [[ -n $HTTP_DATE_EPOCH ]]; then HTTP_DATE_LOCAL=$(printf '%(%s)T' -1); fi
  return 0
}
HTTP_DATE_LOCAL=0

# Az óra: ha az év kisebb a telepítő événél, vagy a HTTPS Date fejléc >60 mp-cel eltér és az NTP nem szinkronizált → a 2. lépésben beállítom.
clock_check() {
  local year drift ntp
  year=$(printf '%(%Y)T' -1)
  if (( year < MIN_YEAR )); then
    if [[ -n $FROM_MODE ]]; then ui_warn "az óra rossz ($(printf '%(%F)T' -1)) – az apt hibázhat; állítsd be: sudo date -s 'YYYY-MM-DD HH:MM:SS'"
    else CLOCK_SUSPECT=1; ui_warn "az óra rossz ($(printf '%(%F)T' -1)) – a telepítés elején beállítom a GitHub idejére"; fi
  fi
  if [[ -n $HTTP_DATE_EPOCH ]]; then
    drift=$(( HTTP_DATE_EPOCH - HTTP_DATE_LOCAL )); if (( drift < 0 )); then drift=$(( -drift )); fi
    if (( drift > 60 )); then
      ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
      if [[ $ntp != yes ]]; then CLOCK_SUSPECT=1; ui_warn "az óra ${drift} mp-cel eltér a GitHub idejétől, és nincs idő-szinkron – beállítom"
      else ui_warn "az óra ${drift} mp-cel eltér a GitHub idejétől (az idő-szinkron be van kapcsolva, nem nyúlok hozzá)"; fi
    elif (( year >= MIN_YEAR )); then
      ui_ok "óra: rendben (eltérés a GitHub idejétől: ${drift} mp)"
    fi
  fi
  return 0
}

# =====================================================================================================================
# 2. lépés – hozzáférés: sudo, óra, telepítőkód
# =====================================================================================================================
# Az óra javítása (csak ha az 1. lépés gyanút jelzett). Két forrás:
#  - ELLENŐRZÖTT: a TLS-en, érvényes tanúsítvánnyal kapott `Date:` fejléc (HTTP_DATE_EPOCH) – ezt az óra beállítására használjuk;
#  - HITELESÍTETLEN: ha a TLS a rossz óra miatt nem megy, egyetlen `curl -k` fejléc-lekérdezés. Ezt egy közbeékelődő támadó (vagy egy HTTPS-t átvizsgáló proxy)
#    tetszőlegesre hamisíthatja, ezért csak akkor használjuk, ha az óra tényleg rossz (év < MIN_YEAR) vagy az idő-szinkron nincs bekapcsolva, és csak ésszerű
#    határokon belül (a telepítő készülte utáni legfeljebb 12 év; hihető helyi óránál legfeljebb 2 nap eltérés). Egyébként az órához NEM nyúlunk, és a TLS-hibát jelentjük.
tls_interception_fail() {
  fail "titkosítási (TLS) hiba, pedig az óra rendben van – a céges hálózat valószínűleg átvizsgálja a HTTPS-t" "Kérd meg az IT-t: a github.com és az api.github.com legyen kivéve a HTTPS-átvizsgálás alól (vagy engedélyezett a közvetlen 443-as elérés). Az órához nem nyúltam; ha kész, futtasd újra ugyanazt a parancsot."
}

fix_clock() {
  if (( ! CLOCK_SUSPECT )); then return 0; fi
  local d epoch="" year now ntp drift how h
  year=$(printf '%(%Y)T' -1); now=$(printf '%(%s)T' -1)
  if [[ -n $HTTP_DATE_EPOCH ]]; then
    epoch=$(( HTTP_DATE_EPOCH + now - HTTP_DATE_LOCAL ))      # a mérés óta eltelt idővel kiegészítve
    drift=$(( epoch - now )); if (( drift < 0 )); then drift=$(( -drift )); fi
    if (( year >= MIN_YEAR && drift <= 60 )); then
      # az óra rendben van: egy-két gazdagép TLS-hibája nem az órán múlik
      if (( ${#NET_FAILS[@]} )); then tls_interception_fail; fi
      return 0
    fi
    how="a GitHub idejére"
  else
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
    if (( year >= MIN_YEAR )) && [[ $ntp == yes ]]; then tls_interception_fail; fi
    # a TLS a rossz óra miatt nem működik: egyetlen, csak fejlécet olvasó kérés tanúsítvány-ellenőrzés nélkül; csak az időt vesszük át, ésszerűségi határokkal
    curl --proto '=https' --tlsv1.2 -k -sS -I -o /dev/null -D "$WORK/probe.hdr" --connect-timeout 8 --max-time 15 "https://$API_HOST/" 2>/dev/null </dev/null || true
    d="$(hdr_get "$WORK/probe.hdr" date)"
    if [[ -n $d ]]; then epoch="$(python3 -I -c "$PY_DATE" "$d" 2>/dev/null || true)"; fi
    [[ $epoch =~ ^[0-9]+$ ]] || fail "az óra rossz, és a GitHub idejét sem sikerült lekérdezni" "Állítsd be az órát kézzel (sudo date -s 'YYYY-MM-DD HH:MM:SS'), majd futtasd újra."
    if (( year < MIN_YEAR )); then
      (( epoch >= MIN_EPOCH && epoch <= MIN_EPOCH + MAX_CLOCK_AHEAD )) \
        || fail "a GitHubtól (hitelesítetlenül) kapott idő ($(printf '%(%F)T' "$epoch")) nem hihető" "Állítsd be az órát kézzel (sudo date -s 'YYYY-MM-DD HH:MM:SS'), majd futtasd újra."
    else
      drift=$(( epoch - now )); if (( drift < 0 )); then drift=$(( -drift )); fi
      (( epoch >= MIN_EPOCH && drift <= MAX_CLOCK_STEP )) \
        || fail "a GitHubtól (hitelesítetlenül) kapott idő ($(printf '%(%F %T)T' "$epoch")) túl messze van a gép órájától – nem fogadom el" "Ellenőrizd az órát (date); ha rossz, állítsd be kézzel (sudo date -s 'YYYY-MM-DD HH:MM:SS'). Ha jó, a céges hálózat átvizsgálja a HTTPS-t: kérd meg az IT-t."
    fi
    how="a GitHub által HITELESÍTETLENÜL közölt időre (a TLS a rossz óra miatt nem ellenőrizhető; a kapott időt ésszerűségi határok közt fogadtam el)"
  fi
  if "${SUDO[@]}" date -u -s "@$epoch" >>"$WORK_LOG" 2>&1; then
    CLOCK_FIX_EPOCH=$epoch
    ui_ok "óra beállítva ${how}: $(printf '%(%F %T)T' "$epoch") UTC"
    for h in "${NET_FAILS[@]}"; do
      probe_https "${h%%|*}" || fail "$(explain_net "${h%%|*}" "$PROBE_RC")" "Kérd meg az IT-t (443-as kimenő forgalom a github.com és api.github.com felé), majd futtasd újra."
    done
    NET_FAILS=()
  else
    fail "nem sikerült beállítani az órát" "Állítsd be kézzel: sudo date -s 'YYYY-MM-DD HH:MM:SS', majd futtasd újra."
  fi
}

# A telepítőkód betöltése: --code-file > KIRAKAT_CODE > (kérdés a terminálon). Eredmény: $AUTH_HDR / $TOKEN_FILE_OUT / $KEY_FILE (0600, a $WORK-ben).
CODE_ERR=""
load_code_from() {   # stdin: a kód
  local out
  if out="$(python3 -I -c "$PY_CODE" "$SECRETS/auth.hdr" "$SECRETS/token.txt" "$SECRETS/support.key" 2>"$WORK/code.err")"; then
    if [[ $out == *token=1* ]]; then AUTH_HDR="$SECRETS/auth.hdr"; TOKEN_FILE_OUT="$SECRETS/token.txt"; HAVE_TOKEN=1; fi
    if [[ $out == *key=1* ]]; then KEY_FILE="$SECRETS/support.key"; HAVE_KEY=1; fi
    return 0
  fi
  CODE_ERR="$(head -n 1 "$WORK/code.err" 2>/dev/null || true)"
  return 1
}

code_summary() { printf '%s%s' "$([[ $HAVE_TOKEN == 1 ]] && echo 'GitHub-token' || echo 'nincs token')" "$([[ $HAVE_KEY == 1 ]] && echo ', támogatási kulcs')"; }

get_code_noninteractive() {
  if [[ -n $CODE_FILE ]]; then
    [[ -f $CODE_FILE && -r $CODE_FILE ]] || fail "a --code-file nem olvasható: $CODE_FILE" "Add meg a telepítőkódot tartalmazó fájl helyes útvonalát, vagy hagyd el a kapcsolót."
    load_code_from <"$CODE_FILE" || fail "$CODE_ERR" "Kérj új telepítőkódot a gazdától (tools/make-install-code.sh), és futtasd újra."
    ui_ok "telepítőkód betöltve a fájlból ($(code_summary))"
    return 0
  fi
  if [[ -n $PENDING_CODE ]]; then
    # here-string: a kód nem kerül parancssorba
    if ! load_code_from <<<"$PENDING_CODE"; then PENDING_CODE=""; fail "$CODE_ERR" "Kérj új telepítőkódot a gazdától (tools/make-install-code.sh), és futtasd újra."; fi
    PENDING_CODE=""
    ui_ok "telepítőkód betöltve (KIRAKAT_CODE; $(code_summary))"
    return 0
  fi
  return 1
}

ask_code() {    # $1 kérdés; 0, ha kaptunk érvényes kódot; 1, ha üres (kihagyva) vagy nincs terminál
  local q=$1 tries=0
  while (( tries < 3 )); do
    tries=$((tries + 1))
    ui_live_clear
    prompt_hidden "$q" || return 1
    if [[ -z $PROMPT_REPLY ]]; then return 1; fi
    if load_code_from <<<"$PROMPT_REPLY"; then PROMPT_REPLY=""; return 0; fi
    PROMPT_REPLY=""
    ui_warn "$CODE_ERR – próbáld újra (vagy Enter = kihagyás)."
  done
  return 1
}

step_credentials() {
  ui_step 2 "Hozzáférés (sudo, telepítőkód)"
  if (( CHECK )); then
    ui_info "(--check) a sudo-t nem kérem, nem változtatok semmit"
  else
    need_sudo
    fix_clock
  fi
  if get_code_noninteractive; then :
  elif (( YES )) || (( CHECK )); then ui_info "telepítőkód: nincs megadva (--yes / --check mellett nem kérdezek)"
  elif (( HAVE_TTY )); then
    if ask_code "Telepítőkód (Enter = kihagyás): "; then ui_ok "telepítőkód elfogadva ($(code_summary))"
    else ui_info "telepítőkód: kihagyva"; fi
  else
    ui_info "telepítőkód: nincs terminál, nem kérdezek (KIRAKAT_CODE vagy --code-file adható meg)"
  fi
  if (( ! HAVE_KEY )); then ui_info "rendszerjelszó: támogatási kulcs nélkül véletlen jelszó készül (a végén egyszer látod)"; fi
  return 0
}

# =====================================================================================================================
# 3. lépés – kiadás keresése
# =====================================================================================================================
api_error() {   # HTTP-kód alapján emberi hiba (kilép)
  local code=$1 remaining reset when=""
  case $code in
    401) fail "a GitHub nem fogadta el a tokent (lejárt, visszavont vagy hibás)" "Kérj új telepítőkódot a gazdától (tools/make-install-code.sh), és futtasd újra a parancsot." ;;
    403|429)
      remaining="$(hdr_get "$FETCH_HDR" x-ratelimit-remaining)"; reset="$(hdr_get "$FETCH_HDR" x-ratelimit-reset)"
      if [[ $remaining == 0 || $code == 429 ]]; then
        if [[ $reset =~ ^[0-9]+$ ]]; then when=" (újra próbálható: $(printf '%(%H:%M)T' "$reset"))"; fi
        fail "a GitHub átmenetileg korlátozza a lekérdezéseket erről a hálózatról${when}" "Add meg a telepítőkódot (token): azzal magasabb a korlát; vagy várj, és futtasd újra."
      fi
      fail "a GitHub megtagadta a hozzáférést (HTTP $code)" "Ellenőrizd a token jogát (Contents: read, a tárolóra), vagy kérj új telepítőkódot." ;;
    404)
      if (( HAVE_TOKEN )); then
        fail "a GitHub nem találja a kiadást vagy a tárolót ($REPO) – a tokennek nincs hozzáférése, vagy nincs ilyen kiadás" "Ellenőrizd, hogy a token a(z) $REPO tárolóra szól (Contents: read) és létezik kiadás; kérj új telepítőkódot, ha kell."
      fi
      if (( HAVE_TTY && ! YES && ! CHECK )); then
        fail "a tároló privát (vagy nincs ilyen kiadás) – telepítőkód nélkül nem érhető el" "Futtasd újra a parancsot, és a kérdésnél illeszd be a telepítőkódot (a gazda gépén a tools/make-install-code.sh készíti)."
      fi
      fail "a tároló privát (vagy nincs ilyen kiadás) – telepítőkód nélkül nem érhető el" "Add meg a telepítőkódot: KIRAKAT_CODE környezeti változóban vagy a --code-file kapcsolóval (a gazda gépén a tools/make-install-code.sh készíti)." ;;
    5??) fail "a GitHub most nem válaszol rendesen (HTTP $code)" "Várj néhány percet, majd futtasd újra ugyanazt a parancsot." ;;
    *) fail "váratlan válasz a GitHubtól (HTTP $code)" "Futtasd újra a parancsot; ha marad a hiba, küldd el a naplót." ;;
  esac
}

net_error() {   # curl-hiba alapján emberi hiba (kilép)
  local rc=$FETCH_RC
  case $rc in
    6) fail "a névfeloldás (DNS) nem működik" "Ellenőrizd a hálózati kábelt és a DNS-t (kérd meg az IT-t), majd futtasd újra." ;;
    7|28) fail "a GitHub nem érhető el (időtúllépés / kapcsolat megtagadva)" "Kérd meg az IT-t: 443-as kimenő forgalom a github.com és api.github.com felé; majd futtasd újra." ;;
    23) fail "a letöltött adat nem írható (megtelt a lemez?)" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot." ;;
    35|51|58|59|60|77|83) fail "titkosítási (TLS) hiba a GitHub felé" "Ellenőrizd az órát (date) és hogy a céges hálózat nem vizsgálja-e át a HTTPS-t; majd futtasd újra." ;;
    63) fail "a letöltés túl nagy (a megengedett határ fölött)" "Ez nem a szokásos csomag – ellenőrizd a kiadást, vagy kérdezd a fejlesztőt." ;;
    -1) fail "nem engedélyezett letöltési cím" "Ez hibát jelez a kiadásban – szólj a fejlesztőnek." ;;
    *) fail "a letöltés sikertelen (curl hibakód: $rc)" "Futtasd újra a parancsot; ha marad a hiba, kérd meg az IT-t a 443-as kimenő forgalomról a github.com felé." ;;
  esac
}

step_release() {
  ui_step 3 "Kiadás keresése"
  if [[ -n $FROM_MODE ]]; then
    ui_ok "a csomag forrása: $FROM"
    if [[ $FROM_MODE == url ]]; then
      if (( PIN_OOB )); then ui_warn "titkosítatlan (HTTP) letöltés a helyi hálózatról – csak megbízható hálózaton használd (az ellenőrző-összeg a parancssorból jött: ez a módosított csomag ellen véd)"
      else ui_warn "titkosítatlan (HTTP) letöltés a helyi hálózatról – csak megbízható hálózaton használd${PIN_SHA:+; a szkriptbe írt ellenőrző-összeg ugyanazon a csatornán jött, ezért csak a sérült letöltést fogja meg, a közbeékelődő támadót nem – hasonlítsd össze a PC-n kiírt SHA-256 elejével, vagy add meg a --sha256 értéket a parancssorban}"; fi
    fi
    return 0
  fi
  local url path tries=0 key val rc=0 draft=0 pre=0 scopes
  if [[ -n $WANT_VERSION ]]; then path="releases/tags/$WANT_VERSION"; else path="releases/latest"; fi
  url="https://$API_HOST/repos/$REPO/$path"
  while :; do
    ui_live "lekérdezés: $path…"
    if fetch_retry "$url" "$WORK/release.json" 1 'application/vnd.github+json' 1048576 60; then break; fi
    ui_live_clear
    if (( FETCH_RC != 0 )); then net_error; fi
    # privát tárolónál token nélkül 404 / 401: terminálon rákérdezünk a telepítőkódra (legfeljebb háromszor)
    if [[ $FETCH_CODE == 404 || $FETCH_CODE == 401 ]] && (( ! HAVE_TOKEN && tries < 3 && HAVE_TTY && ! YES && ! CHECK )); then
      tries=$((tries + 1))
      ui_warn "A tároló privát – a telepítőkód kötelező."
      if ask_code "Telepítőkód (kötelező – a tároló privát): "; then continue; fi
    fi
    api_error "$FETCH_CODE"
  done
  ui_live_clear
  python3 -I -c "$PY_RELEASE" "$WORK/release.json" "$REPO" >"$WORK/release.kv" 2>/dev/null || rc=$?
  case $rc in
    0) ;;
    4) fail "a kiadás címkéje szokatlan alakú" "Nem a megszokott vX.Y.Z kiadás – szólj a fejlesztőnek." ;;
    5) fail "a kiadás letöltési címe nem a várt tárolóra mutat" "Ez hibát vagy támadást jelez – ne folytasd; szólj a fejlesztőnek." ;;
    *) fail "a GitHub válasza nem értelmezhető" "Futtasd újra a parancsot; ha marad a hiba, küldd el a naplót." ;;
  esac
  while IFS=$'\t' read -r key val; do
    case $key in
      tag) TAG=$val;; tarball) TARBALL_URL=$val;; sums) SUMS_URL=$val;; shaasset) SHA_ASSET_URL=$val;; notesha) NOTE_SHA=$val;;
      pkg) PKG_URL=$val;; pkgsize) PKG_SIZE=$val;;
      draft) draft=$val;; prerelease) pre=$val;;
    esac
  done <"$WORK/release.kv"
  [[ -n $TAG && -n $TARBALL_URL ]] || fail "a kiadás adatai hiányosak" "Futtasd újra; ha marad, szólj a fejlesztőnek."
  [[ $TAG == v* ]] || TAG="v$TAG"
  TARGET_VERSION=${TAG#v}
  if (( draft )); then fail "a kiadás még vázlat ($TAG)" "Válassz kész kiadást (--version), vagy várd meg, míg a fejlesztő közzéteszi."; fi
  if (( pre )); then ui_warn "előzetes kiadás: $TAG"; fi
  ui_ok "kiadás: ${C_B}$TAG${C_RST}$([[ -n $WANT_VERSION ]] && echo ' (kért)' || echo ' (legfrissebb)')"
  if (( HAVE_TOKEN )); then ui_ok "a tároló eléréséhez a telepítőkód tokenjét használom"; fi
  # klasszikus tokennél a GitHub kiírja a jogkört: az írási jog nem kell
  scopes="$(hdr_get "$FETCH_HDR" x-oauth-scopes)"
  case ${scopes// /} in *repo*|*write:*|*admin:*|*delete*) ui_warn "a token szélesebb jogú a szükségesnél (írási jog is van rajta) – csak olvasási jogú (Contents: read) tokent érdemes használni";; esac
  if [[ -n $SUMS_URL ]]; then ui_info "ellenőrző-összeg melléklet: SHA256SUMS"; fi
  return 0
}

# =====================================================================================================================
# 4. lépés – letöltés és ellenőrzés
# =====================================================================================================================
sha_of() { local s; s="$(sha256sum -- "$1")"; printf '%s' "${s%% *}"; }

fetch_expected_sha() {   # EXPECT_SHA beállítása a kiadás mellékleteiből / leírásából / --sha256-ból
  EXPECT_SHA=""
  if [[ -n $PIN_SHA ]]; then
    [[ $PIN_SHA =~ ^[0-9a-fA-F]{64}$ ]] || fail "a --sha256 érték nem 64 hexa jegy" "Add meg a csomag SHA-256 értékét (sha256sum), vagy hagyd el a kapcsolót."
    EXPECT_SHA=${PIN_SHA,,}; return 0
  fi
  local got=""
  if [[ -n $SUMS_URL ]]; then
    fetch_retry "$SUMS_URL" "$WORK/SHA256SUMS" 1 'application/octet-stream' 65536 60 \
      || fail "a kiadás ellenőrző-összeg melléklete (SHA256SUMS) nem tölthető le, a csomag nem hitelesíthető" "Futtasd újra a parancsot; ha marad, szólj a fejlesztőnek (a melléklet hibás vagy elérhetetlen)."
    got="$(python3 -I -c "$PY_SUMS" "$WORK/SHA256SUMS" "$TAG" 2>/dev/null || true)"
    [[ $got != '!' ]] || fail "a SHA256SUMS több, eltérő bejegyzést tartalmaz a csomaghoz, nem hitelesíthető" "Szólj a fejlesztőnek (a kiadás mellékletét javítani kell)."
    if [[ -n $got ]]; then EXPECT_SHA=$got; return 0; fi
    ui_warn "a SHA256SUMS nem tartalmaz bejegyzést a csomaghoz – az ellenőrző-összeget kihagyom"
  fi
  if [[ -n $SHA_ASSET_URL ]]; then
    fetch_retry "$SHA_ASSET_URL" "$WORK/release.sha256" 1 'application/octet-stream' 4096 60 \
      || fail "a kiadás *.sha256 melléklete nem tölthető le, a csomag nem hitelesíthető" "Futtasd újra; ha marad, szólj a fejlesztőnek."
    got="$(python3 -I -c "$PY_SUMS" "$WORK/release.sha256" "$TAG" 2>/dev/null || true)"
    [[ $got != '!' && -n $got ]] || fail "a kiadás *.sha256 melléklete hibás alakú, a csomag nem hitelesíthető" "Szólj a fejlesztőnek."
    EXPECT_SHA=$got; return 0
  fi
  if [[ -n $NOTE_SHA ]]; then
    [[ $NOTE_SHA != '!' ]] || fail "a kiadás leírásában több, eltérő SHA-256 áll, a csomag nem hitelesíthető" "Szólj a fejlesztőnek."
    EXPECT_SHA=$NOTE_SHA
  fi
  return 0
}

verify_tarball() {   # $1 tar.gz → kilép hibánál
  local tgz=$1 have rc=0 msg
  [[ -s $tgz ]] || fail "üres letöltés" "Futtasd újra a parancsot; ha marad, kérd meg az IT-t a github.com / codeload.github.com elérhetőségéről."
  gzip -t -- "$tgz" 2>/dev/null || fail "a letöltött csomag sérült (a gzip-teszt sikertelen)" "Futtasd újra a parancsot: új letöltést indít."
  have="$(sha_of "$tgz")"; VERIFIED_SHA=$have
  if [[ -n $EXPECT_SHA ]]; then
    [[ $have == "$EXPECT_SHA" ]] || fail "a letöltött csomag SHA-256 ellenőrző-összege nem egyezik az elvárttal – a csomagot nem telepítem" "Futtasd újra (új letöltés); ha marad a hiba, ne telepíts, és szólj a fejlesztőnek."
    ui_ok "SHA-256 ellenőrző-összeg egyezik (${have:0:16}…)"
  else
    ui_info "SHA-256: ${have:0:16}… (a kiadáshoz nincs közzétett ellenőrző-összeg; a hitelességet a TLS és a GitHub adja)"
  fi
  python3 -I -c "$PY_TARCHECK" "$tgz" "$MAX_UNPACKED" "$MAX_ENTRIES" 2>"$WORK/tarcheck.err" || rc=$?
  if (( rc != 0 )); then
    msg="$(head -n 1 "$WORK/tarcheck.err" 2>/dev/null || true)"
    fail "a csomag szerkezete nem megfelelő: ${msg:-ismeretlen ok}" "Ne telepítsd ezt a csomagot; futtasd újra, és ha marad a hiba, szólj a fejlesztőnek."
  fi
  ui_ok "a csomag szerkezete rendben (egy felső mappa, biztonságos útvonalak)"
}

REQUIRED_FILES=(server/app.py VERSION web/ui/index.html system/install-system.sh system/install-update-path.sh system/auto-update.sh
                system/signage-player.service system/signage-vt.service system/signage-server.service system/player-session)

extract_tree() {   # $1 tar.gz → $TREE
  local tgz=$1 f v want
  TREE="$CACHE/tree"
  if [[ -d $TREE ]]; then rm -rf -- "${TREE:?}"; fi
  mkdir -p -- "$TREE"
  tar -xzf "$tgz" -C "$TREE" --strip-components=1 --no-same-owner --no-same-permissions >>"$WORK_LOG" 2>&1 \
    || fail "a csomag kicsomagolása sikertelen" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
  for f in "${REQUIRED_FILES[@]}"; do
    [[ -e $TREE/$f ]] || fail "a csomagból hiányzik egy kötelező fájl: $f" "Ez a kiadás nem telepíthető ezzel a telepítővel – használj újabb kiadást (--version), vagy szólj a fejlesztőnek."
  done
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$TREE/server/app.py" 2>/dev/null \
    || fail "a csomag server/app.py fájlja szintaktikailag hibás" "Ne telepítsd; szólj a fejlesztőnek."
  read -r v <"$TREE/VERSION" || true
  v=${v//[[:space:]]/}; v=${v#v}
  [[ $v =~ ^[0-9][0-9A-Za-z._+-]{0,30}$ ]] || fail "a csomag VERSION fájlja hibás alakú" "Szólj a fejlesztőnek."
  if [[ -n $TARGET_VERSION ]]; then want=${TARGET_VERSION#v}; else want=$v; fi
  [[ $v == "$want" ]] || fail "a csomag VERSION fájlja ($v) nem egyezik a kiadás címkéjével ($want)" "Hibás csomag – ne telepítsd; szólj a fejlesztőnek."
  TARGET_VERSION=$v; [[ -n $TAG ]] || TAG="v$v"
  ui_ok "kicsomagolva: Kirakat v$v ($(find "$TREE" -type f | wc -l | tr -d ' ') fájl)"
  stage_root_tree "$tgz"
}

# --- a rootnak előkészített, gyökér-tulajdonú másolat ---
# A rootként futtatott szkriptek (jelszóbeállító, kiegészítő horgok, rendszer-előkészítő, frissítő-telepítő) és az apt-konfig NEM a felhasználó által írható
# gyorsítótár-fából futnak (ahol a felhasználó azonosítójával futó másik folyamat – pl. a médiát feldolgozó szerver – percekkel az ellenőrzés után kicserélhetné őket),
# hanem egy gyökér-tulajdonú, 0700-as másolatból: a most ellenőrzött csomagot gyökér-tulajdonba másoljuk, újra ellenőrizzük (SHA-256 + szerkezet), és rootként csomagoljuk ki.
# (Marad: az install-system.sh a saját bemeneteit – a szolgáltatás-egységeket – a felhasználó tulajdonú /opt/signage/system-ből olvassa, ahogy a tools/provision.sh is így hívja.)
stage_root_tree() {   # $1 az ellenőrzött tar.gz
  local tgz=$1 have
  STAGE="$INSTALL_STATE_DIR/stage"
  "${SUDO[@]}" install -d -m 755 -o "$ROOT_OWNER" -g "$ROOT_GROUP" "$INSTALL_STATE_DIR" >>"$WORK_LOG" 2>&1 \
    || fail "a(z) $INSTALL_STATE_DIR mappa nem hozható létre" "Ellenőrizd a sudo-jogot és a szabad helyet (df -h), majd futtasd újra."
  "${SUDO[@]}" rm -rf -- "${STAGE:?}" >>"$WORK_LOG" 2>&1 || true
  "${SUDO[@]}" install -d -m 700 -o "$ROOT_OWNER" -g "$ROOT_GROUP" "$STAGE" "$STAGE/tree" >>"$WORK_LOG" 2>&1 \
    || fail "a gyökér-tulajdonú munkamappa ($STAGE) nem hozható létre" "Ellenőrizd a sudo-jogot és a szabad helyet (df -h), majd futtasd újra."
  "${SUDO[@]}" install -m 600 -o "$ROOT_OWNER" -g "$ROOT_GROUP" -- "$tgz" "$STAGE/pkg.tar.gz" >>"$WORK_LOG" 2>&1 \
    || fail "a csomag gyökér-tulajdonú másolata nem készíthető el" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
  have="$("${SUDO[@]}" sha256sum -- "$STAGE/pkg.tar.gz")"; have=${have%% *}
  [[ $have == "$VERIFIED_SHA" ]] || fail "a csomag megváltozott az ellenőrzés és a gyökér-tulajdonú másolat készítése között – nem telepítem" "Futtasd újra (új letöltés); ha marad a hiba, ne telepíts, és szólj a fejlesztőnek."
  "${SUDO[@]}" python3 -I -c "$PY_TARCHECK" "$STAGE/pkg.tar.gz" "$MAX_UNPACKED" "$MAX_ENTRIES" 2>>"$WORK_LOG" \
    || fail "a csomag szerkezete a gyökér-tulajdonú másolaton nem megfelelő" "Ne telepítsd ezt a csomagot; szólj a fejlesztőnek."
  "${SUDO[@]}" tar -xzf "$STAGE/pkg.tar.gz" -C "$STAGE/tree" --strip-components=1 --no-same-owner --no-same-permissions >>"$WORK_LOG" 2>&1 \
    || fail "a csomag kicsomagolása a gyökér-tulajdonú mappába sikertelen" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
  RTREE="$STAGE/tree"
  log "gyökér-tulajdonú ellenőrzött másolat: $RTREE"
}

step_download() {
  ui_step 4 "Letöltés és ellenőrzés"
  local ok_file part sum
  if [[ $FROM_MODE == file ]]; then
    TGZ=$FROM
    [[ -f $TGZ && -r $TGZ ]] || fail "a megadott csomag nem olvasható: $TGZ" "Add meg egy létező .tar.gz fájl útvonalát (--from)."
    if [[ -n $PIN_SHA ]]; then fetch_expected_sha; fi
    ui_ok "helyi csomag: $TGZ ($(fmt_bytes "$(wc -c <"$TGZ")"))"
    verify_tarball "$TGZ"
    extract_tree "$TGZ"
    ui_step_done
    return 0
  fi
  local name
  if [[ $FROM_MODE == url ]]; then name="from-$(printf '%s' "$FROM" | sha256sum | cut -c1-12).tar.gz"; else name="release-$TAG.tar.gz"; fi
  # Az „ellenőrzött” jelölés gyökér-tulajdonú helyen él (nem a gyorsítótár mellett): a felhasználó azonosítójával futó másik folyamat nem tud se csomagot, se jelölést odatenni.
  TGZ="$CACHE/$name"; ok_file="$INSTALL_STATE_DIR/dl-${name//[^A-Za-z0-9._-]/_}.sha"; part="$TGZ.part"
  fetch_expected_sha
  # korábbi, ellenőrzött letöltés újrahasznosítása (megszakítás utáni folytatás)
  if [[ -s $TGZ && -r $ok_file ]] && { [[ $FROM_MODE != url ]] || [[ -n $EXPECT_SHA ]]; }; then
    read -r sum <"$ok_file" || true
    if [[ $sum == "$(sha_of "$TGZ")" ]] && gzip -t -- "$TGZ" 2>/dev/null && { [[ -z $EXPECT_SHA || $EXPECT_SHA == "$sum" ]]; }; then
      ui_ok "korábbi, ellenőrzött letöltés újrahasznosítva ($(fmt_bytes "$(wc -c <"$TGZ")"))"
      verify_tarball "$TGZ"
      extract_tree "$TGZ"
      ui_step_done
      return 0
    fi
    ui_info "a korábbi letöltés nem használható, újra letöltöm"
  fi
  rm -f -- "$TGZ" "$part"
  "${SUDO[@]}" rm -f -- "$ok_file" >/dev/null 2>&1 || true
  local src hint=0 accept="application/vnd.github+json, application/octet-stream;q=0.9, */*;q=0.1"
  if [[ $FROM_MODE == url ]]; then src=$FROM
  elif [[ -n $PKG_URL ]]; then src=$PKG_URL; hint=$PKG_SIZE; accept="application/octet-stream"; ui_info "a kiadás saját csomagját töltöm le (a méret ismert: $(fmt_bytes "$hint"))"
  else src=$TARBALL_URL; fi
  ui_info "forrás: $(strip_url "$src" | cut -c1-70)"
  if ! fetch_retry "$src" "$part" 1 "$accept" "$MAX_DOWNLOAD" 1800 "Letöltés" "$hint"; then
    ui_live_clear
    if (( DL_TOO_BIG )); then rm -f -- "$part"; fail "a letöltés túl nagy (több mint $(fmt_bytes $MAX_DOWNLOAD))" "Ez nem a szokásos csomag – ellenőrizd a kiadást, vagy kérdezd a fejlesztőt."; fi
    if (( FETCH_RC == 0 )); then api_error "$FETCH_CODE"; fi
    net_error
  fi
  if (( DL_TOO_BIG )); then rm -f -- "$part"; fail "a letöltés túl nagy (több mint $(fmt_bytes $MAX_DOWNLOAD))" "Ez nem a szokásos csomag – ellenőrizd a kiadást, vagy kérdezd a fejlesztőt."; fi
  verify_tarball "$part"
  mv -- "$part" "$TGZ"
  printf '%s\n' "$VERIFIED_SHA" >"$WORK/dl.mark"
  if "${SUDO[@]}" install -d -m 755 -o "$ROOT_OWNER" -g "$ROOT_GROUP" "$INSTALL_STATE_DIR" >>"$WORK_LOG" 2>&1; then
    "${SUDO[@]}" install -m 644 -o "$ROOT_OWNER" -g "$ROOT_GROUP" -- "$WORK/dl.mark" "$ok_file" >>"$WORK_LOG" 2>&1 || true
  fi
  extract_tree "$TGZ"
  ui_step_done
}

# =====================================================================================================================
# 5. lépés – rendszer-előkészítés (a kiadás system/install-system.sh-ja, root-ként)
# =====================================================================================================================
# A folyamatos kimenet értelmezése: "==> " sorok = szakaszcímek; az apt-állapot (APT::Status-Fd) = letöltés / telepítés folyamatjelző
SYS_PHASE=""; APT_KIND=""; APT_PCT=-1; APT_PKG=""; SYS_LAST=""; SYS_REDRAW=0; PHASE_N=0; APT_PREV_PCT=-1
sys_phase_item() {
  PHASE_N=$((PHASE_N + 1))
  SYS_PHASE=$1; APT_KIND=""; APT_PCT=-1; APT_PKG=""; APT_PREV_PCT=-1
  ui_progress_reset
  ui_item "$1"
}

sys_line() {
  local l=$1 i
  local -a f
  l=${l//$'\r'/}
  l=${l//$'\033'\[+([0-9;?])[A-Za-z]/}            # a színező / kurzormozgató (CSI) sorozatok kiszedése
  l=${l//$'\t'/ }
  l=${l//[[:cntrl:]]/}                               # minden más vezérlőkarakter (pl. az ablakcímet átíró ESC ] … BEL) is: a terminálra és a naplóba csak nyomtatható szöveg kerül
  [[ -n $l ]] || return 0
  log_raw "$l"
  case $l in
    '==> '*) sys_phase_item "${l#==> }" ;;
    dlstatus:*) IFS=: read -ra f <<<"$l"; apt_status "letöltés" "" "${f[2]:-}" ;;
    pmstatus:*)
      # pmstatus:<csomag>:<százalék>:<üzenet> – a csomagnév tartalmazhat kettőspontot (pl. libc6:arm64), ezért az első számszerű mező a százalék
      IFS=: read -ra f <<<"$l"
      for ((i = 2; i < ${#f[@]}; i++)); do [[ ${f[$i]} =~ ^[0-9]+(\.[0-9]*)?$ ]] && break; done
      if (( i < ${#f[@]} )); then
        local IFS=:
        apt_status "telepítés" "${f[*]:1:$((i - 1))}" "${f[$i]}"
      else apt_status "telepítés" "${f[1]:-}" ""; fi ;;
    pmerror:*) ui_warn "apt: ${l#pmerror:}" ;;
    *) SYS_LAST=$l ;;
  esac
  return 0
}

apt_status() {  # $1 fajta, $2 csomag, $3 százalék (tizedesekkel)
  local pct=${3%%.*}
  # csak 0–100 közötti, legfeljebb háromjegyű egész fogadható el (egy szemetes sor ne állítsa le a telepítést a printf '%d' hibájával)
  if [[ $pct =~ ^[0-9]{1,3}$ ]]; then pct=$((10#$pct)); (( pct <= 100 )) || pct=-1; else pct=-1; fi
  if [[ $1 != "$APT_KIND" ]] || (( pct < APT_PREV_PCT )); then ui_progress_reset; fi
  APT_KIND=$1; APT_PKG=$2; APT_PCT=$pct; APT_PREV_PCT=$pct
}

sys_redraw() {
  now_ms
  if (( NOW_MS - SYS_REDRAW < 150 && IS_TTY )); then return 0; fi
  SYS_REDRAW=$NOW_MS
  if [[ -n $APT_KIND ]]; then
    ui_progress "$APT_KIND" "$APT_PCT" "$APT_PKG"
  else
    TICK=$((TICK + 1))
    ui_live "${SPIN[$((TICK % SPIN_N))]} ${SYS_PHASE:-dolgozom}${SYS_LAST:+  $(ui_fit "$SYS_LAST" 40)}"
  fi
  return 0
}

# stream_cmd parancs… : a parancs (stdout+stderr) kimenetét soronként a sys_line dolgozza fel; a kilépési kódot STREAM_RC adja
STREAM_RC=0
stream_cmd() {
  local fifo="$WORK/stream.fifo" line="" part="" fd cpid rc=0 idle=0
  rm -f -- "$fifo"; mkfifo -m 600 "$fifo"
  "$@" >"$fifo" 2>&1 </dev/null &
  cpid=$!
  exec {fd}<"$fifo"
  while :; do
    if IFS= read -r -t 0.25 -u "$fd" line; then
      idle=0
      line="$part$line"; part=""
      sys_line "$line"
      sys_redraw
    else
      rc=$?
      if (( rc > 128 )); then
        part+="$line"; line=""
        # a parancs már kilépett, de egy leválasztott gyerekfolyamat (pl. démon) még tartja a csövet: nem várunk rá a végtelenségig
        if ! kill -0 "$cpid" 2>/dev/null; then idle=$((idle + 1)); if (( idle >= 4 )); then break; fi; fi
        sys_redraw
        continue
      fi
      break
    fi
  done
  if [[ -n $part ]]; then sys_line "$part"; fi
  exec {fd}<&-
  rm -f -- "$fifo"
  STREAM_RC=0; wait "$cpid" || STREAM_RC=$?
  ui_live_clear
  return 0
}

apt_busy() {    # 0, ha egy másik apt / dpkg / automatikus frissítés fut
  if need_cmd fuser; then "${SUDO[@]}" fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; return; fi
  pgrep -x 'apt|apt-get|dpkg|aptitude' >/dev/null 2>&1 || pgrep -f '/unattended-upgrade( |$)' >/dev/null 2>&1
}

wait_apt_lock() {
  local waited=0
  while apt_busy; do
    if (( waited >= APT_LOCK_WAIT )); then fail "másik csomagkezelő (apt/dpkg) foglalja a zárat $(fmt_dur "$waited") óta" "Várd meg, míg befejezi (pl. automatikus frissítés), majd futtasd újra ugyanazt a parancsot."; fi
    ui_live "${SPIN[$((TICK % SPIN_N))]} várok egy másik csomagkezelőre (automatikus frissítés fut)… $(fmt_dur "$waited")"
    TICK=$((TICK + 1)); sleep 3; waited=$((waited + 3))
  done
  ui_live_clear
  (( waited == 0 )) || ui_info "a csomagkezelő felszabadult ($(fmt_dur "$waited") várakozás után)"
}

fix_dpkg_state() {
  local out
  out="$("${SUDO[@]}" dpkg --audit 2>/dev/null || true)"
  if [[ -n $out ]]; then
    ui_warn "egy korábbi csomagtelepítés félbemaradt – rendbe teszem (dpkg --configure -a)"
    run_logged "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold \
      || fail "a félbemaradt csomagtelepítés rendbetétele nem sikerült" "Futtasd kézzel: sudo dpkg --configure -a, majd a telepítő parancsát újra."
  fi
}

# Egy apt-forrás gazdagép elérhetősége: APT_REACH = http (a sima http megy) | https (csak a https megy) | none. A telepített rendszer /etc/apt forrásaiból jönnek a gazdagépek
# (Ubuntu 26.04: ports.ubuntu.com, archive.ubuntu.com, security.ubuntu.com, a Hardkernel tárolója…), nem egy rögzített lista.
APT_REACH=""
apt_host_reach() {   # $1 gazdagép
  local rc=0 pid
  APT_REACH=none
  curl --proto '=http' -sS -I -o /dev/null --connect-timeout 6 --max-time 10 "http://$1/" 2>/dev/null </dev/null &
  pid=$!; wait "$pid" || rc=$?
  if (( rc == 0 )); then APT_REACH=http; return 0; fi
  rc=0
  curl --proto '=https' --tlsv1.2 -sS -I -o /dev/null --connect-timeout 6 --max-time 10 "https://$1/" 2>/dev/null </dev/null &
  pid=$!; wait "$pid" || rc=$?
  if (( rc == 0 )); then APT_REACH=https; fi
  return 0
}

# Az 1. lépésben: a csomagtárak elérhetősége (csak figyelmeztet; az átírás az 5. lépésben történik)
probe_apt_hosts() {
  local hosts h bad=() good=()
  hosts="$(python3 -I -c "$PY_APTHOSTS" all 2>/dev/null || true)"
  [[ -n $hosts ]] || return 0
  for h in $hosts; do
    ui_live "csomagtár: $h…"
    apt_host_reach "$h"
    case $APT_REACH in
      http) log "apt-forrás $h: http elérhető"; good+=("$h") ;;
      https) log "apt-forrás $h: csak https"; good+=("$h"); ui_info "csomagtár: $h – a sima http tiltott, https-en elérhető (az apt-forrást https-re írom át)" ;;
      *) bad+=("$h") ;;
    esac
  done
  ui_live_clear
  if (( ${#bad[@]} )); then
    ui_warn "csomagtár nem érhető el (sem http-n, sem https-en): ${bad[*]} – kérd meg az IT-t: 443-as kimenő forgalom ezek felé (az apt letöltése e nélkül hibázik)"
  fi
  if (( ${#good[@]} )); then ui_ok "csomagtárak elérhetők: ${good[*]}"; fi
}

# apt a csak 443-as hálózatokon: ha egy http:// forrás-gazdagép nem érhető el, de https-en igen, a forrás https-re íródik (az eredeti <fájl>.kirakat-orig)
apt_https_fix() {
  local hosts h rewrite=()
  hosts="$(python3 -I -c "$PY_APTHOSTS" 2>/dev/null || true)"
  [[ -n $hosts ]] || return 0
  for h in $hosts; do
    ui_live "apt-forrás ellenőrzése: $h…"
    apt_host_reach "$h"
    case $APT_REACH in
      http) continue ;;
      https) rewrite+=("$h") ;;
      *) ui_warn "az apt-forrás ($h) sem http-n, sem https-en nem érhető el – a csomagtelepítés hibázhat" ;;
    esac
  done
  ui_live_clear
  if (( ${#rewrite[@]} )); then
    "${SUDO[@]}" env KIRAKAT_APT_ROOT="${KIRAKAT_APT_ROOT:-/etc/apt}" python3 -I -c "$PY_APTREWRITE" "${rewrite[@]}" >>"$WORK_LOG" 2>&1 \
      || fail "az apt-források átírása https-re nem sikerült" "Kérd meg az IT-t, hogy engedélyezze a 80-as (http) kimenő forgalmat a csomagtárak felé, majd futtasd újra."
    APT_NOTE="apt-források https-re állítva: ${rewrite[*]} (az eredeti: /etc/apt/sources.list*.kirakat-orig)"
    ui_ok "$APT_NOTE"
  fi
}

# Az app-könyvtár szerkezete: lapos (alap: server/ web/ system/ VERSION bin/) vagy az automatikus frissítő releases/current elrendezése
detect_layout() {
  LAYOUT=flat
  if [[ -L $APP_DIR/current || -d $APP_DIR/releases ]]; then LAYOUT=releases; fi
  INSTALLED_VERSION=""
  if [[ -r $APP_DIR/VERSION ]]; then read -r INSTALLED_VERSION <"$APP_DIR/VERSION" || true; INSTALLED_VERSION=${INSTALLED_VERSION//[[:space:]]/}; fi
}

# Egy mappa cseréje két szakaszban. 1) prep_dir: az új másolat a mellé készül (hosszú, megszakítható: félkész másolat legfeljebb mellette marad, a következő futás törli);
# 2) commit_dir: két átnevezés – ezt MINDIG kritikus szakaszon belül hívjuk (crit_begin / crit_end), hogy egy Ctrl-C ne hagyjon fél cserét.
# Kizárások: __pycache__, tests (server), spike (system).
prep_dir() {    # $1 név (server|web|system)
  local name=$1 src="$TREE/$1" new="$APP_DIR/.kirakat-new-$1"
  [[ -d $src ]] || fail "a csomagból hiányzik a(z) $name mappa" "Szólj a fejlesztőnek."
  rm -rf -- "${new:?}"
  cp -a -- "$src" "$new" || fail "a(z) $name másolása sikertelen" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
  find "$new" -type d -name __pycache__ -prune -exec rm -rf -- {} + 2>/dev/null || true
  case $name in
    server) find "$new" -type d -name tests -prune -exec rm -rf -- {} + 2>/dev/null || true ;;
    system) find "$new" -type d -name spike -prune -exec rm -rf -- {} + 2>/dev/null || true ;;
  esac
  find "$new" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$new" -type f -exec chmod u+rwX,go+rX,go-w {} + 2>/dev/null || true
  if [[ $name == system ]]; then find "$new" -maxdepth 1 -type f \( -name '*.sh' -o -name player-session -o -name kirakat-fan -o -name apply-fan.sh \) -exec chmod 755 {} + 2>/dev/null || true; fi
}

commit_dir() {  # $1 név – kritikus szakaszon belül
  local old="$APP_DIR/.kirakat-old-$1" new="$APP_DIR/.kirakat-new-$1" cur="$APP_DIR/$1"
  rm -rf -- "${old:?}"
  if [[ -e $cur || -L $cur ]]; then mv -- "$cur" "$old"; fi
  mv -- "$new" "$cur"
  rm -rf -- "${old:?}"
}

swap_dir() {    # $1 név: előkészítés + csere egyben (a server / web együtt cserélendő, ott a step_app két szakaszra bontja)
  prep_dir "$1"
  crit_begin
  commit_dir "$1"
  crit_end
}

# Egy korábbi, megszakadt csere maradékai: ha a mappa hiányzik, de a régi megvan, visszaállítjuk; a félkész új másolatokat töröljük.
recover_app_dir() {
  local n
  for n in server web system; do
    if [[ ! -e $APP_DIR/$n && -d $APP_DIR/.kirakat-old-$n ]]; then mv -- "$APP_DIR/.kirakat-old-$n" "$APP_DIR/$n"; log "visszaállítva egy megszakadt cseréből: $n"; fi
    rm -rf -- "${APP_DIR:?}/.kirakat-new-$n" "${APP_DIR:?}/.kirakat-old-$n"
  done
  rm -f -- "$APP_DIR/VERSION.kirakat-new" "$APP_DIR/bin/player-session.kirakat-new"
}

# Kiegészítő horog (más fejlesztési ág szkriptje) futtatása a gyökér-tulajdonú ellenőrzött másolatból, időkorláttal és élő állapotsorral; a hiba csak figyelmeztetés
run_hook() {    # $1 a szkript neve a system/ alatt, $2 felirat
  local name=$1 label=$2 rc=0
  [[ -n $RTREE ]] || { ui_warn "a(z) $name kihagyva (nincs ellenőrzött másolat)"; return 0; }
  run_spin "$label" timeout -k 5 "$HOOK_TIMEOUT" "${SUDO[@]}" env APP_USER="$APP_USER" bash "$RTREE/system/$name" || rc=$?
  case $rc in
    0) ;;
    124|137) ui_warn "a(z) $name ${HOOK_TIMEOUT} mp alatt sem fejeződött be – megszakítottam (folytatom; a napló részletezi)" ;;
    *) ui_warn "a(z) $name hibával tért vissza (kilépési kód $rc; folytatom, a napló részletezi)" ;;
  esac
  return 0
}

# parancs futtatása naplóba, élő állapotsorral (terminálon pörgettyű + eltelt idő); a kilépési kódot adja vissza
run_spin() {    # $1 felirat, parancs…
  local label=$1 rc=0 pid t0=$SECONDS
  shift
  log "futtatás: ${*:1:6}"
  "$@" >>"$WORK_LOG" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    ui_live "${SPIN[$((TICK % SPIN_N))]} $label… $(fmt_dur $((SECONDS - t0)))"
    TICK=$((TICK + 1)); sleep 0.2
  done
  ui_live_clear
  wait "$pid" || rc=$?
  return "$rc"
}

step_system() {
  ui_step 5 "Rendszer-előkészítés (csomagok, szolgáltatások)"
  detect_layout
  if [[ -n $INSTALLED_VERSION ]]; then
    if [[ $INSTALLED_VERSION == "$TARGET_VERSION" ]]; then ui_info "már telepített verzió: v$INSTALLED_VERSION – javítás/ellenőrzés módban futok, az adatokhoz nem nyúlok"
    else ui_info "telepített verzió: v$INSTALLED_VERSION → v$TARGET_VERSION (frissítés, az adatokhoz nem nyúlok)"; fi
  fi
  "${SUDO[@]}" install -d -m 755 -o "$APP_USER" -g "$APP_GROUP" "$APP_DIR" "$APP_DIR/bin" \
    || fail "a(z) $APP_DIR mappa nem hozható létre" "Ellenőrizd a sudo-jogot és a szabad helyet (df -h), majd futtasd újra."
  if [[ $LAYOUT == flat ]]; then
    recover_app_dir
    ui_item "a rendszerfájlok átmásolása ($APP_DIR/system)"
    swap_dir system
  else
    ui_warn "az eszköz az automatikus frissítő elrendezését használja (releases/current): az alkalmazásfájlokat nem cserélem – a frissítést a Karbantartás oldal / az éjszakai frissítő végzi"
  fi
  wait_apt_lock
  fix_dpkg_state

  # kiegészítő horog (más fejlesztési ág szkriptje): ha a kiadás tartalmazza, lefut; nélküle a telepítő önállóan is teljes. (Az apply-network.sh a telepítés VÉGÉN fut, lásd apply_network_last.)
  if [[ -f $TREE/system/apt-https.sh ]]; then
    ui_item "apt https-re (a kiadás system/apt-https.sh szkriptje)"
    run_hook apt-https.sh "apt https-re"
  else
    apt_https_fix
  fi
  if [[ -f $TREE/system/apply-network.sh ]]; then HAVE_NET_HOOK=1; fi      # a gyorsítótár-fa a végére már törlődik: a jelenlétet itt jegyezzük fel

  # ha a hostname még alapértelmezett és az eth0 nincs meg (pl. end0 néven fut), a kiadás szkriptje elbukna: előbb a gépnevet adjuk meg
  local cur_host new_host m4
  cur_host="$(hostname)"
  if [[ $cur_host == server || $cur_host == odroid ]] && [[ ! -r $SYS_NET/eth0/address ]]; then
    MAC="$(primary_mac)"; m4=${MAC//:/}; m4=${m4: -4}
    if [[ -n $m4 ]]; then
      new_host="kijelzo-$m4"
      if run_logged "${SUDO[@]}" hostnamectl set-hostname "$new_host"; then ui_item "gépnév: $new_host (az eth0 nem létezik, az elsődleges csatoló MAC-jéből)"; fi
      "${SUDO[@]}" sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
      printf '127.0.1.1 %s\n' "$new_host" | "${SUDO[@]}" tee -a /etc/hosts >/dev/null 2>&1 || true
    fi
  fi

  # apt: állapot a szabványos kimenetre (APT::Status-Fd 1), zárvárakozás, ismétlés hálózati hibára, konfig-fájl kérdések nélkül. A konfig a gyökér-tulajdonú mappába kerül
  # (az apt-konfig parancsot is futtathat – pl. Pre-Invoke –, ezért nem lehet a felhasználó által írható helyen).
  cat >"$WORK/apt.conf" <<'CONF'
APT::Status-Fd "1";
Dpkg::Progress-Fancy "0";
APT::Color "0";
DPkg::Lock::Timeout "600";
Acquire::Retries "3";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
CONF
  "${SUDO[@]}" install -m 644 -o "$ROOT_OWNER" -g "$ROOT_GROUP" -- "$WORK/apt.conf" "$STAGE/apt.conf" >>"$WORK_LOG" 2>&1 \
    || fail "az apt-konfig nem írható ($STAGE/apt.conf)" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
  flush_log || true
  # a flat elrendezésnél a gyökér-tulajdonú, ellenőrzött másolat szkriptje fut (a bemenetei – a szolgáltatás-egységek – a /opt/signage/system alól jönnek, lásd stage_root_tree);
  # az automatikus frissítő elrendezésnél a telepített kiadás szkriptje (azt az OTA birtokolja)
  local script="$RTREE/system/install-system.sh"
  if [[ $LAYOUT != flat ]]; then
    script="$APP_DIR/system/install-system.sh"
    [[ -f $script ]] || fail "hiányzik a rendszer-előkészítő szkript ($script)" "Szólj a fejlesztőnek."
  fi
  ui_info "ez tart a legtovább (5–15 perc): csomagok letöltése és telepítése"
  SYS_PHASE=""; APT_KIND=""; SYS_LAST=""; PHASE_N=0
  stream_cmd "${SUDO[@]}" env APP_USER="$APP_USER" APT_CONFIG="$STAGE/apt.conf" DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a bash "$script"
  if (( STREAM_RC != 0 )); then
    log "install-system.sh kilépési kódja: $STREAM_RC"
    explain_from_log
    [[ -n $FAIL_CAUSE ]] || { FAIL_CAUSE="a rendszer-előkészítés hibával állt le (kilépési kód $STREAM_RC)"; FAIL_TODO="Nézd meg a napló végét; ha átmeneti volt (hálózat), futtasd újra ugyanazt a parancsot."; }
    exit 1
  fi
  ui_ok "a rendszer-előkészítés lefutott ($PHASE_N szakasz)"
  flush_log || true
  ui_step_done
}

# A hálózati beállítás (DHCP-azonosító = MAC) az UTOLSÓ művelet: közben a címe megváltozhat, és egy SSH-munkamenet megszakadhat – addigra minden kész, az összegzés kiírva.
# Az új címet a végén kiírjuk.
apply_network_last() {
  (( HAVE_NET_HOOK )) && [[ -n $RTREE ]] || return 0
  local before after prev i
  before="$(ip_list | tr '\n' ' ')"; before=${before% }
  ui_item "hálózati beállítás (a kiadás system/apply-network.sh szkriptje: DHCP-azonosító = MAC)"
  run_hook apply-network.sh "hálózati beállítás"
  after="$(ip_list | tr '\n' ' ')"; after=${after% }
  for ((i = 0; i < 15; i++)); do      # a címkiosztás néhány másodpercig tarthat: két egymás utáni, egyező, nem üres olvasásig várunk
    sleep 1; prev=$after; after="$(ip_list | tr '\n' ' ')"; after=${after% }
    if [[ -n $after && $after == "$prev" ]]; then break; fi
  done
  if [[ $before != "$after" ]]; then
    ui_warn "A hálózati beállítás után megváltozott az IP-cím: ${before:-nincs} → ${after:-nincs}. Ha SSH-n vagy, a kapcsolat megszakadhat: lépj be újra az új címen (és ha a DHCP-szerveren foglalás van, igazítsd a kliensazonosítóhoz)."
  else
    ui_ok "hálózati beállítás kész (IP-cím: ${after:-nincs})"
  fi
}

# =====================================================================================================================
# 6. lépés – alkalmazás telepítése (mint a tools/deploy.sh): server web VERSION bin/player-session + felhasználói unit
# =====================================================================================================================
user_systemctl() {
  local rtd="${XDG_RUNTIME_DIR:-/run/user/$APP_UID}"
  XDG_RUNTIME_DIR="$rtd" DBUS_SESSION_BUS_ADDRESS="unix:path=$rtd/bus" systemctl --user "$@"
}

wait_user_bus() {   # a felhasználói systemd elérhetősége (linger után néhány másodperc)
  local i rtd="${XDG_RUNTIME_DIR:-/run/user/$APP_UID}"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if user_systemctl is-system-running >/dev/null 2>&1 || user_systemctl daemon-reload >/dev/null 2>&1; then return 0; fi
    ui_live "${SPIN[$((TICK % SPIN_N))]} a felhasználói systemd indulására várok…"
    TICK=$((TICK + 1)); sleep 1
  done
  ui_live_clear
  [[ -S $rtd/bus ]] || log "figyelmeztetés: nincs $rtd/bus"
  return 1
}

prep_file() {   # $1 mód, $2 forrás, $3 cél: az új tartalom a cél mellé készül (a csere a commit_file-lal, kritikus szakaszon belül)
  install -m "$1" -- "$2" "$3.kirakat-new" || fail "a(z) $3 nem írható" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
}
commit_file() { # $1 cél: atomikus átnevezés
  mv -- "$1.kirakat-new" "$1" || fail "a(z) $1 nem cserélhető" "Futtasd újra ugyanazt a parancsot."
}
put_file() {    # $1 mód, $2 forrás, $3 cél: előkészítés + csere egyben
  prep_file "$1" "$2" "$3"
  commit_file "$3"
}

step_app() {
  ui_step 6 "Alkalmazás telepítése"
  local unit_dir="${KIRAKAT_USER_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
  if [[ $LAYOUT == flat ]]; then
    # minden új másolat elkészül ELŐBB (megszakítható: a régi telepítés érintetlen marad), a cserék pedig EGY rövid kritikus szakaszban mennek végbe –
    # így egy Ctrl-C nem hagyhat új szervert régi webfelülettel / VERSION-nel (a VERSION az utolsó)
    ui_item "szerver ($APP_DIR/server)"; prep_dir server
    ui_item "webes felület és lejátszó ($APP_DIR/web)"; prep_dir web
    install -d -m 755 "$APP_DIR/bin"
    prep_file 755 "$TREE/system/player-session" "$APP_DIR/bin/player-session"
    prep_file 644 "$TREE/VERSION" "$APP_DIR/VERSION"
    crit_begin
    commit_dir server
    commit_dir web
    commit_file "$APP_DIR/bin/player-session"
    commit_file "$APP_DIR/VERSION"
    crit_end
    ui_ok "az alkalmazás fájljai a helyükön (v$TARGET_VERSION), a tulajdonos: $APP_USER"
  else
    ui_info "(releases/current elrendezés: az alkalmazásfájlok érintetlenek)"
  fi
  mkdir -p -- "$unit_dir" || fail "a(z) $unit_dir nem hozható létre" "Ellenőrizd a szabad helyet és a jogosultságot, majd futtasd újra."
  put_file 644 "$TREE/system/signage-server.service" "$unit_dir/signage-server.service"
  ui_ok "felhasználói szolgáltatás: $unit_dir/signage-server.service"
  run_logged "${SUDO[@]}" loginctl enable-linger "$APP_USER" || ui_warn "a linger bekapcsolása nem sikerült (a szerver csak bejelentkezéssel indulna újraindítás után)"
  wait_user_bus || ui_warn "a felhasználói systemd lassan indul – megpróbálom így is"
  run_logged user_systemctl daemon-reload || fail "a felhasználói systemd nem érhető el" "Lépj ki, lépj be újra az odroid felhasználóval (ssh -t), és futtasd újra a parancsot."
  run_logged user_systemctl enable signage-server.service || fail "a signage-server szolgáltatás nem engedélyezhető" "Nézd meg a naplót, majd futtasd újra a parancsot."
  run_logged user_systemctl restart signage-server.service || fail "a signage-server szolgáltatás nem indul" "Nézd meg: journalctl --user -u signage-server; majd futtasd újra a parancsot."
  ui_ok "a szerver (signage-server) bekapcsolva és elindítva"
  flush_log || true
  ui_step_done
}

# =====================================================================================================================
# 7. lépés – frissítő segéd és GitHub-token
# =====================================================================================================================
step_updater() {
  ui_step 7 "Frissítő segéd és GitHub-hozzáférés"
  local helper="$HELPER_DIR/auto-update.sh" want_sha ups base
  if [[ $LAYOUT == flat ]]; then
    # a gyökér-tulajdonú, ellenőrzött másolathoz hasonlítunk, és onnan is telepítünk (az install-system.sh a /opt/signage/system alól már telepíthetett egy segédet: ha az eltér, javítjuk)
    want_sha="$("${SUDO[@]}" sha256sum -- "$RTREE/system/auto-update.sh" 2>/dev/null)" || want_sha=""; want_sha=${want_sha%% *}
    base=$RTREE; ups="$RTREE/system/install-update-path.sh"
  else
    want_sha="$(sha_of "$TREE/system/auto-update.sh")"
    base=$APP_DIR; ups="$APP_DIR/system/install-update-path.sh"
    [[ -f $ups ]] || ups="$TREE/system/install-update-path.sh"
  fi
  if [[ -f $helper && -f $HELPER_DIR/app-user && -n $want_sha && "$(sha_of "$helper")" == "$want_sha" && "$(<"$HELPER_DIR/app-user")" == "$APP_USER" ]]; then
    ui_ok "a frissítő segéd már telepítve van, és megegyezik a kiadásbelivel ($HELPER_DIR)"
  else
    ui_item "a frissítő segéd telepítése (root-tulajdonú másolat + egységek)"
    run_logged "${SUDO[@]}" env SIGNAGE_BASE="$base" APP_USER="$APP_USER" bash "$ups" \
      || { explain_from_log; fail "${FAIL_CAUSE:-a frissítő segéd telepítése nem sikerült}" "${FAIL_TODO:-Nézd meg a naplót, majd futtasd újra a parancsot.}"; }
    ui_ok "a Karbantartás oldal frissítése és az éjszakai frissítő használatra kész"
  fi
  if (( HAVE_TOKEN )); then
    local dest="$DATA_DIR/github-token"
    if [[ -f $dest ]] && cmp -s "$TOKEN_FILE_OUT" "$dest"; then
      ui_ok "a GitHub-token már be van állítva az OTA-frissítőhöz"
    else
      run_logged "${SUDO[@]}" install -m 600 -o "$APP_USER" -g "$APP_GROUP" "$TOKEN_FILE_OUT" "$dest" \
        || fail "a GitHub-token mentése nem sikerült ($dest)" "Ellenőrizd a szabad helyet; a token később a Karbantartás oldalon is megadható."
      ui_ok "a GitHub-token elmentve az OTA-frissítőhöz ($dest, 0600) – a felületen nem kell megadni"
    fi
  else
    ui_info "nincs telepítőkód-token: a frissítéshez a GitHub-tokent később a Karbantartás oldalon kell megadni (ha a tároló privát)"
  fi
  flush_log || true
  ui_step_done
}

# =====================================================================================================================
# 8. lépés – rendszerjelszó, SSH, gépnév
# =====================================================================================================================
# A rendszerjelszó állapota (a telepítő állapotmappájában, gyökér-tulajdonban): derived = a MAC-ből számolt gyári jelszó áll; random-unconfirmed = véletlen jelszó van beállítva, de az
# összegzésben még NEM mutattuk meg (megszakadás / SSH-kiesés után a gazda nem ismeri → az újrafuttatás újat állít be); random = a véletlen jelszót az összegzés kiírta.
mark_os_password() {   # $1 mód: derived | random-unconfirmed | random
  run_logged "${SUDO[@]}" install -d -m 755 -o "$ROOT_OWNER" -g "$ROOT_GROUP" "$INSTALL_STATE_DIR" || return 0
  printf '%s\n' "$1" >"$WORK/os-mark"
  "${SUDO[@]}" install -m 644 -o "$ROOT_OWNER" -g "$ROOT_GROUP" "$WORK/os-mark" "$INSTALL_STATE_DIR/os-password" >/dev/null 2>&1 || true
}

# Az SSH StrictModes-feltételei: az authorized_keys, a ~/.ssh és a home a felhasználóé (vagy rooté), és nem csoport- / mindenki által írható; különben az sshd figyelmen kívül hagyja a kulcsot.
SSH_BAD=""
ssh_modes_ok() {   # $1 az authorized_keys útvonala → 0 rendben; SSH_BAD = az első kifogásolt útvonal
  local p st m u
  SSH_BAD=""
  for p in "$1" "$(dirname -- "$1")" "$HOME"; do
    st="$(stat -c '%a %u' -- "$p" 2>/dev/null)" || { SSH_BAD=$p; return 1; }
    m=${st% *}; u=${st#* }
    if [[ $u != "$APP_UID" && $u != 0 ]] || (( (8#$m & 8#022) != 0 )); then SSH_BAD=$p; return 1; fi
  done
  return 0
}

# 0: a telepítést futtató munkamenet nem SSH-s (konzol – onnan a kizárás nem fenyeget), vagy bizonyítottan kulccsal lépett be (SSH_AUTH_INFO_0, vagy az sshd naplója: „Accepted publickey”
# ugyanarról a kliens-címről és -portról); 1: SSH-s munkamenet, amelynél nem tudjuk, hogy kulcsos volt-e (jelszóval is beléphetett: akkor a kulcs egy másik gépé is lehet).
ssh_session_by_key() {
  [[ -n ${SSH_CONNECTION:-} ]] || return 0
  [[ ${SSH_AUTH_INFO_0:-} == *publickey* ]] && return 0
  local cip cport rest jlog
  read -r cip cport rest <<<"$SSH_CONNECTION"
  [[ $cip =~ ^[0-9a-fA-F:.]+$ && $cport =~ ^[0-9]+$ ]] || return 1
  jlog="$("${SUDO[@]}" journalctl --no-pager -o cat -t sshd -t sshd-session --since -2d 2>/dev/null || true)"
  [[ $jlog == *"Accepted publickey for $APP_USER from $cip port $cport "* ]]
}

confirm_ssh_keyonly() {   # 0 = a gazda igent mondott
  (( HAVE_TTY && ! YES )) || return 1
  local ans=""
  ui_live_clear
  printf '%s' "Ezt az SSH-munkamenetet nem kulccsal nyitottad (vagy nem ellenőrizhető). Kikapcsoljam az SSH jelszavas belépését? Utána CSAK a ~/.ssh/authorized_keys kulcsaival lehet belépni. [i/N] " >/dev/tty
  IFS= read -r ans </dev/tty || true
  [[ $ans == [iIyY]* ]]
}

SSH_RECOVER="visszaállítás a konzolról: sudo rm $SSHD_DROPIN && sudo systemctl reload ssh"

step_os() {
  ui_step 8 "Rendszerjelszó, SSH, gépnév"
  MAC="$(primary_mac)"
  local pwfile="$SECRETS/os-password" setpw="$TREE/system/set-os-password.sh" tool="$TREE/tools/os-password.py" prev=""
  [[ -r $INSTALL_STATE_DIR/os-password ]] && read -r prev <"$INSTALL_STATE_DIR/os-password" || true
  if (( KEEP_OS_PW )); then
    OS_PW_MODE=kept; ui_info "rendszerjelszó: marad, ami volt (--keep-os-password)"
  elif [[ ! -f $setpw ]]; then
    OS_PW_MODE=kept; ui_warn "ez a kiadás nem tartalmaz jelszóbeállítót (system/set-os-password.sh) – a rendszerjelszó nem változik"
  elif (( HAVE_KEY )) && [[ $prev == derived ]]; then
    # egy újrafuttatás ne vegye el a gazdától a felületen / kézzel megváltoztatott jelszót
    OS_PW_MODE=kept; ui_info "rendszerjelszó: a MAC-ből számolt gyári jelszót egy korábbi telepítés már beállította – nem írom felül (visszaállítás a gyárira: PC-n tools/set-os-password.sh)"
  elif (( HAVE_KEY )) && [[ -f $tool ]]; then
    if [[ ! $MAC =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then fail "az eszköz MAC-címe nem állapítható meg ($MAC)" "Ellenőrizd a hálózati csatolót (ip link); a rendszerjelszó beállítását kihagyhatod a --keep-os-password kapcsolóval."; fi
    ( umask 077; OS_PASSWORD_KEY_FILE="$KEY_FILE" python3 -I "$tool" derive --mac "$MAC" >"$pwfile" ) \
      || fail "a MAC-ból számolt jelszó nem állítható elő" "A telepítőkódban lévő támogatási kulcs hibás lehet – kérj újat (tools/make-install-code.sh); vagy használd a --keep-os-password kapcsolót."
    OS_PW_MODE=derived
  else
    if (( HAVE_KEY )); then ui_warn "a telepítőkódban lévő támogatási kulcsot nem tudom felhasználni: ez a kiadás nem tartalmazza a tools/os-password.py-t – a MAC-ből számolt jelszó helyett más jelszó marad / készül"; fi
    if [[ $prev == derived || $prev == random ]]; then
      OS_PW_MODE=kept; ui_info "rendszerjelszó: a korábbi telepítés állította be ($prev), nem változtatom"
    else
      ( umask 077; python3 -I -c "$PY_RANDPW" >"$pwfile" )
      OS_PW_MODE=random
    fi
  fi
  if [[ $OS_PW_MODE == derived || $OS_PW_MODE == random ]]; then
    if [[ $OS_PW_MODE == random ]]; then RANDOM_PW="$(<"$pwfile")"; fi
    # a jelszófájl gyökér-tulajdonú másolatát adjuk át a jelszóbeállítónak (a felhasználó által írható fájlt a root nem olvassa be); a saját példányt azonnal töröljük
    "${SUDO[@]}" install -m 600 -o "$ROOT_OWNER" -g "$ROOT_GROUP" -- "$pwfile" "$STAGE/os-password" >>"$WORK_LOG" 2>&1 \
      || fail "a jelszófájl gyökér-tulajdonú másolata nem készíthető el" "Szabadíts fel helyet (df -h), majd futtasd újra ugyanazt a parancsot."
    shred_file "$pwfile"
    crit_begin
    # a kritikus szakasz legfeljebb ennyi ideig tarthat (egy elakadt chpasswd miatt a telepítő ne legyen megszakíthatatlan)
    if run_logged timeout -k 3 "${KIRAKAT_CRIT_TIMEOUT:-60}" "${SUDO[@]}" env APP_USER="$APP_USER" bash "$RTREE/system/set-os-password.sh" "$STAGE/os-password"; then
      crit_end
      if [[ $OS_PW_MODE == derived ]]; then
        ui_ok "rendszerjelszó: a MAC-címből számolt gyári jelszó beállítva (PC-n: tools/os-password.py derive --mac $MAC)"; mark_os_password derived
      else
        OS_PW_MODE=random-applied
        # „megerősítetlen”, amíg az összegzés ki nem írta: bármilyen megszakadás (Ctrl-C, SSH-kiesés, áramszünet) után a következő futás újat állít be és mutat meg
        ui_ok "rendszerjelszó: véletlen jelszó beállítva (a végén egyszer megmutatom)"; mark_os_password random-unconfirmed
      fi
    else
      crit_end
      fail "a rendszerjelszó beállítása nem sikerült" "Nézd meg a naplót; a --keep-os-password kapcsolóval a jelszó érintetlen marad. Futtasd újra a parancsot."
    fi
  fi

  # SSH: kulcsos belépésre csak akkor váltunk, ha van engedélyezett kulcs, az sshd el is fogadná (StrictModes), és biztos, hogy nem zárjuk ki a gazdát
  local ak="${KIRAKAT_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}" haskey=0 l re_key='(^|[[:space:]])(ssh-[a-z0-9]+|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+)[[:space:]]+AAAA'
  if [[ -s $ak ]]; then
    while IFS= read -r l; do
      if [[ $l != '#'* && $l =~ $re_key ]]; then haskey=1; break; fi
    done <"$ak"
  fi
  if (( ! haskey )); then
    SSH_NOTE="az SSH jelszavas belépése be van kapcsolva (nincs ~/.ssh/authorized_keys kulcs); kulcs felvétele után futtasd újra a telepítőt, az kikapcsolja"
    ui_warn "SSH: nincs engedélyezett kulcs ($ak), ezért a jelszavas belépést bekapcsolva hagyom"
  elif ! ssh_modes_ok "$ak"; then
    SSH_NOTE="az SSH jelszavas belépése bekapcsolva maradt: a(z) $SSH_BAD jogosultsága miatt az sshd nem fogadná el a kulcsot; javítás: chmod go-w ~ ~/.ssh ~/.ssh/authorized_keys, majd futtasd újra a telepítőt"
    ui_warn "SSH: a kulcsos belépés nem működne – a(z) $SSH_BAD csoport- vagy mindenki által írható (vagy nem a tiéd), ezért az sshd elutasítaná a kulcsot. A jelszavas belépést bekapcsolva hagyom. Javítás: chmod go-w ~ ~/.ssh ~/.ssh/authorized_keys"
  elif ! ssh_session_by_key && ! confirm_ssh_keyonly; then
    SSH_NOTE="az SSH jelszavas belépése bekapcsolva maradt: ezt a munkamenetet nem kulccsal nyitottad (vagy nem ellenőrizhető), a kulcs más gépé is lehet – ha kipróbáltad a kulcsos belépést, futtasd újra a telepítőt (terminálon, --yes nélkül) és válaszolj igennel"
    ui_warn "SSH: nem ellenőrizhető, hogy a ~/.ssh/authorized_keys kulcsával be tudsz lépni – a kizárás elkerülésére a jelszavas belépést bekapcsolva hagyom"
  else
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >"$WORK/sshd-keyonly.conf"
    if [[ -f $SSHD_DROPIN ]] && cmp -s "$WORK/sshd-keyonly.conf" "$SSHD_DROPIN"; then
      SSH_NOTE="az SSH-belépés csak kulccsal lehetséges ($SSH_RECOVER)"; ui_ok "SSH: már csak kulcsos belépés engedélyezett"
    else
      "${SUDO[@]}" install -d -m 755 "$(dirname -- "$SSHD_DROPIN")" >>"$WORK_LOG" 2>&1 || true
      if run_logged "${SUDO[@]}" install -m 644 "$WORK/sshd-keyonly.conf" "$SSHD_DROPIN" && run_logged "${SUDO[@]}" sshd -t; then
        run_logged "${SUDO[@]}" systemctl reload ssh || run_logged "${SUDO[@]}" systemctl reload sshd || true
        SSH_NOTE="az SSH-belépés mostantól csak kulccsal lehetséges (a jelszavas belépés kikapcsolva; $SSH_RECOVER)"; ui_ok "SSH: jelszavas belépés kikapcsolva (van engedélyezett kulcs: $ak)"
        ui_info "SSH $SSH_RECOVER"
      else
        "${SUDO[@]}" rm -f -- "$SSHD_DROPIN" >>"$WORK_LOG" 2>&1 || true
        SSH_NOTE="az SSH jelszavas belépése be van kapcsolva (a kulcsos módra váltás nem sikerült)"; ui_warn "SSH: az sshd-beállítás ellenőrzése sikertelen, a jelszavas belépést nem kapcsoltam ki"
      fi
    fi
  fi

  local hn; hn="$(hostname)"
  if [[ $hn == server || $hn == odroid ]]; then ui_warn "gépnév: $hn (az alapértelmezett maradt; a Beállítások oldalon átnevezhető)"
  else ui_ok "gépnév: $hn"; fi
  flush_log || true
  ui_step_done
}

# =====================================================================================================================
# 9. lépés – indítás és ellenőrzés
# =====================================================================================================================
local_status() {   # a helyi szerver /api/public/status válasza → STATUS_* (0, ha érvényes)
  local out="" rc=0
  out="$(curl --proto '=http,https' -sS --max-time 3 -H 'Accept: application/json' "$LOCAL_URL/api/public/status" 2>/dev/null </dev/null | python3 -I -c "$PY_STATUS" 2>/dev/null)" || rc=$?
  [[ $out == ok$'\t'* ]] || return 1
  IFS=$'\t' read -r _ STATUS_VERSION STATUS_STATE STATUS_CONFIGURED STATUS_JSON_NAME STATUS_ID <<<"$out"
  return 0
}
STATUS_VERSION=""

# HTTPS-módban (Beállítások) a szerver a hálózaton CSAK https-en hallgat (a sima http csak a loopbacken): a rendszer-összegzésben a megfelelő sémát írjuk ki. A loopbacken mindkettőt
# megpróbáljuk (a nyilvános állapotnak nincs TLS-mezője); a saját, aláíratlan tanúsítvány miatt a tanúsítvány-ellenőrzés itt (csak a loopbacken) ki van kapcsolva.
SERVER_SCHEME=http
detect_scheme() {
  SERVER_SCHEME=http
  local out="" rc=0
  out="$(curl --proto '=https' -k -sS --max-time 3 -H 'Accept: application/json' "$LOCAL_HTTPS_URL/api/public/status" 2>/dev/null </dev/null | python3 -I -c "$PY_STATUS" 2>/dev/null)" || rc=$?
  if [[ $out == ok$'\t'* ]]; then SERVER_SCHEME=https; ui_info "a szerver HTTPS-módban van: a vezérlő felület https-en érhető el"; fi
  return 0
}

start_player() {
  local i stable=0 st=""
  run_logged "${SUDO[@]}" systemctl enable signage-player.service || true
  run_logged "${SUDO[@]}" systemctl restart signage-player.service \
    || { run_logged "${SUDO[@]}" journalctl --no-pager -n 30 -u signage-player.service || true; fail "a kijelző-lejátszó (signage-player) nem indul" "Nézd meg: journalctl -u signage-player -n 50; HDMI-kijelző nélkül is lehet ok. Majd futtasd újra, vagy használd a --no-player kapcsolót."; }
  for ((i = 0; i < PLAYER_STABLE_SECS; i++)); do
    st="$("${SUDO[@]}" systemctl is-active signage-player.service 2>/dev/null || true)"
    if [[ $st == active ]]; then stable=$((stable + 1)); else stable=0; fi
    ui_live "${SPIN[$((TICK % SPIN_N))]} a lejátszó stabilitását ellenőrzöm… $((i + 1))/$PLAYER_STABLE_SECS"
    TICK=$((TICK + 1)); sleep "$POLL"
  done
  ui_live_clear
  if (( stable >= PLAYER_STABLE_SECS )); then
    PLAYER_NOTE="a kijelzőn a QR-kód és a beállítási kód látható"
    ui_ok "a lejátszó (signage-player) fut és stabil – $PLAYER_NOTE"
  else
    run_logged "${SUDO[@]}" journalctl --no-pager -n 40 -u signage-player.service || true
    PLAYER_NOTE="FIGYELEM: a kijelző-lejátszó nem stabil (állapot: ${st:-ismeretlen}) – a kijelzőn lehet, hogy nem látszik semmi"
    ui_warn "$PLAYER_NOTE"
    ui_warn "Ellenőrizd a HDMI-kábelt és a kijelzőt; a napló: journalctl -u signage-player -n 50. A szerver ettől még működik."
  fi
}

# tty1-ről futtatott telepítésnél: az összegzés után, a felhasználó Entert nyom (vagy letelik az idő), és a lejátszó átveszi a konzolt
deferred_player_start() {
  local delay="${KIRAKAT_TTY1_DELAY:-30}"
  ui_text 2 "  " "  " "" "${C_B}A kijelző-lejátszó indítása:${C_RST} ez a konzol (tty1) most átvált a kijelző-képre (QR-kód + beállítási kód)."
  if (( HAVE_TTY && ! YES )); then
    ui_text 2 "  " "  " "" "Jegyezd fel a fenti adatokat! Enter = indítás most; ${delay} mp múlva magától indul."
    IFS= read -r -t "$delay" </dev/tty || true
  fi
  run_logged "${SUDO[@]}" systemctl enable signage-player.service || true
  run_logged "${SUDO[@]}" systemctl restart signage-player.service || ui_warn "a lejátszó nem indult el – nézd meg: journalctl -u signage-player -n 50"
}

step_start() {
  ui_step 9 "Indítás és ellenőrzés"
  local waited=0 i t0=$SECONDS
  # a szerver
  run_logged user_systemctl is-active signage-server.service || run_logged user_systemctl restart signage-server.service || true
  while :; do
    if local_status; then
      if [[ $STATUS_VERSION == "$TARGET_VERSION" ]]; then break; fi
      # automatikus frissítésű (releases/current) eszközön az alkalmazásfájlokat az OTA-frissítő birtokolja: a futó verzió a régi lehet, és ez rendben van
      if [[ $LAYOUT == releases ]]; then break; fi
    fi
    if (( waited >= START_WAIT )); then
      run_logged "${SUDO[@]}" journalctl --no-pager -n 30 "_SYSTEMD_USER_UNIT=signage-server.service" || true
      if [[ -n $STATUS_VERSION && $STATUS_VERSION != "$TARGET_VERSION" ]]; then
        fail "a szerver más verziót jelent (v$STATUS_VERSION), mint amit telepítettem (v$TARGET_VERSION)" "Egy másik szerver-példány foglalhatja a 80-as portot – nézd meg: ss -ltnp | grep ':80 '; majd futtasd újra a parancsot."
      fi
      fail "a szerver ${START_WAIT} mp alatt sem indult el" "Nézd meg: journalctl --user -u signage-server -n 50; a napló is tartalmazza az utolsó sorokat. Majd futtasd újra a parancsot."
    fi
    ui_live "${SPIN[$((TICK % SPIN_N))]} a szerver indulására várok… $(fmt_dur "$waited")"
    TICK=$((TICK + 1)); sleep "$POLL"; waited=$((SECONDS - t0))
  done
  ui_live_clear
  RUNNING_VERSION=$STATUS_VERSION
  ui_ok "a szerver válaszol: v$STATUS_VERSION ($STATUS_JSON_NAME)"
  if [[ $STATUS_VERSION != "$TARGET_VERSION" ]]; then
    ui_warn "az eszköz automatikus frissítésű (releases/current) elrendezést használ: a szerver a v$STATUS_VERSION verziót futtatja; a v$TARGET_VERSION kiadásra az éjszakai frissítő (vagy a Karbantartás oldal) frissít. A rendszerlépések (csomagok, frissítő segéd, jelszó, SSH) megtörténtek."
  fi
  detect_scheme
  if [[ $STATUS_CONFIGURED == 0 ]]; then ui_ok "az eszköz még nincs beállítva: első beállítás módban (a kijelzőn a beállítási kód látszik)"
  else ui_info "az eszköz már be van állítva (a beállítási kód nem jelenik meg)"; fi

  # a lejátszó (cage + Chromium) a HDMI-kijelzőn
  if (( NO_PLAYER )); then
    run_logged "${SUDO[@]}" systemctl disable signage-player.service || true
    PLAYER_NOTE="a kijelző-lejátszó nincs elindítva (--no-player); később: sudo systemctl enable --now signage-player"
    ui_info "$PLAYER_NOTE"
  elif (( ON_TTY1 )); then
    # a HDMI-konzolról (tty1) futtatott telepítést a lejátszó indulása kitúrná a képernyőről: előbb az összegzés, csak utána indul
    PLAYER_DEFERRED=1
    PLAYER_NOTE="a kijelző-lejátszó az összegzés után indul; ekkor a kijelzőn megjelenik a QR-kód és a beállítási kód"
    ui_info "A telepítés a kijelző konzolján (tty1) fut: a lejátszó átveszi ezt a képernyőt, ezért csak az összegzés kiírása után indítom el."
  else
    start_player
  fi
  flush_log || true
  ui_step_done
}

# =====================================================================================================================
# Összegzés és a terv (--check)
# =====================================================================================================================
ip_list() {     # az eszköz globális IPv4-címei, soronként
  local l i
  local -a w
  while IFS= read -r l; do
    read -ra w <<<"$l"
    for i in "${!w[@]}"; do if [[ ${w[$i]} == inet ]]; then printf '%s\n' "${w[$((i + 1))]%%/*}"; break; fi; done
  done < <(ip -4 -o addr show scope global 2>/dev/null || true)
}

summary() {
  local -a ips=() rows=()
  local ip hn first="" l
  while IFS= read -r l; do [[ -n $l ]] && ips+=("$l"); done < <(ip_list)
  hn="$(hostname)"; [[ -n $MAC ]] || MAC="$(primary_mac)"
  first=${ips[0]:-}
  rows+=("Eszköz|${STATUS_JSON_NAME:-$hn}  ·  gépnév: $hn")
  rows+=("MAC-cím|$MAC")
  if (( ${#ips[@]} )); then
    rows+=("IP-cím|${ips[*]}")
    if [[ $STATUS_CONFIGURED == 0 ]]; then
      rows+=("Első beállítás|$SERVER_SCHEME://$first/   (a kijelzőn látható kóddal)")
      if [[ $SERVER_SCHEME == http ]]; then rows+=("Utána|https://$first/   (ha a HTTPS-t bekapcsolod a Beállításokban)"); fi
    else
      rows+=("Vezérlő felület|$SERVER_SCHEME://$first/")
    fi
  else
    rows+=("IP-cím|nem állapítható meg (nincs hálózati cím?)")
  fi
  rows+=("---")
  if [[ $STATUS_CONFIGURED == 0 && $NO_PLAYER == 0 ]]; then rows+=("A kijelzőn|$PLAYER_NOTE")
  elif (( NO_PLAYER )); then rows+=("Lejátszó|$PLAYER_NOTE")
  else rows+=("A kijelzőn|a lejátszó fut ($PLAYER_NOTE)"); fi
  case $OS_PW_MODE in
    derived) rows+=("Rendszerjelszó|a MAC-címből számolt (a támogatási kulcsból); PC-n: tools/os-password.py derive --mac $MAC") ;;
    random-applied)
      rows+=("Rendszerjelszó|$RANDOM_PW")
      rows+=("|CSAK MOST látszik – jegyezd fel! (SSH, helyi konzol, sudo)")
      rows+=("Későbbi csere|PC-n: tools/set-os-password.sh $first  (a MAC-ből számolt jelszóra, a támogatási kulccsal)") ;;
    kept) rows+=("Rendszerjelszó|nem változott") ;;
  esac
  [[ -n $SSH_NOTE ]] && rows+=("SSH|$SSH_NOTE")
  [[ -n $APT_NOTE ]] && rows+=("Apt|$APT_NOTE")
  rows+=("Napló|${LOG_SAVED_AT:-$LOG_FILE}")
  rows+=("Frissítés|$([[ $HAVE_TOKEN == 1 ]] && echo 'automatikus (éjszaka 3:30) és a Karbantartás oldalon – a token be van állítva' || echo 'a Karbantartás oldalon / éjszaka; privát tárolónál add meg a tokent')")
  ui_emit ""
  if [[ -n $RUNNING_VERSION && $RUNNING_VERSION != "$TARGET_VERSION" ]]; then
    ui_box "KÉSZ – a rendszer előkészítve; a Kirakat v$RUNNING_VERSION fut; a v$TARGET_VERSION kiadásra az automatikus frissítő frissít ($(fmt_dur $((SECONDS - RUN_T0))) alatt)" "${rows[@]}"
  else
    ui_box "KÉSZ – a Kirakat v$TARGET_VERSION telepítve ($(fmt_dur $((SECONDS - RUN_T0))) alatt)" "${rows[@]}"
  fi
  ui_emit ""
}

print_plan() {
  ui_emit ""
  ui_text 0 "" "" "$C_B" "Terv ${C_DIM}(--check: eddig semmi nem változott a rendszeren)${C_RST}"
  local v=${TAG:-"(helyi csomag)"}
  ui_text 5 "  ${C_HDR}4.${C_RST} " "     " "" "Letöltés: ${v}$([[ -n $FROM ]] || echo ' (api.github.com → codeload.github.com)'), gzip + szerkezet + SHA-256 ellenőrzés, biztonságos kicsomagolás"
  ui_text 5 "  ${C_HDR}5.${C_RST} " "     " "" "Rendszer-előkészítés: $APP_DIR/system, apt (Chromium, cage, ffmpeg, …), Mali-meghajtó, udev, polkit, hostname, napi újraindítás"
  ui_text 5 "  ${C_HDR}6.${C_RST} " "     " "" "Alkalmazás: server, web, VERSION, bin/player-session → $APP_DIR; felhasználói unit signage-server.service; linger"
  ui_text 5 "  ${C_HDR}7.${C_RST} " "     " "" "Frissítő segéd ($HELPER_DIR) és a GitHub-token ($DATA_DIR/github-token, 0600)"
  ui_text 5 "  ${C_HDR}8.${C_RST} " "     " "" "Rendszerjelszó ($([[ $HAVE_KEY == 1 ]] && echo 'a MAC-ből számolt' || echo 'véletlen, egyszer mutatom')), SSH kulcsos belépés (ha van kulcs), gépnév"
  ui_text 5 "  ${C_HDR}9.${C_RST} " "     " "" "Indítás: signage-server$([[ $NO_PLAYER == 1 ]] || echo ' + signage-player (HDMI)'), ellenőrzés a $LOCAL_URL/api/public/status címen"
  ui_emit ""
  ui_text 2 "  " "  " "" "Ha minden rendben, futtasd ugyanazt a parancsot a --check nélkül."
  ui_emit ""
}

# =====================================================================================================================
# Indítás
# =====================================================================================================================
usage() {
  cat <<'USAGE'
Kirakat – egyparancsos telepítő (ODROID-M2)

Használat:  curl -sL https://gamekiller168.github.io/i | bash [-s -- KAPCSOLÓK]

  --version vX.Y.Z      egy adott kiadás (alap: a legfrissebb)
  --code-file FÁJL      a telepítőkód fájlból (vagy KIRAKAT_CODE környezeti változó)
  --from CSOMAG|URL     helyi tar.gz vagy URL (tools/serve-installer.sh a PC-n)
  --sha256 HEX          a --from csomag elvárt SHA-256 értéke
  --check               csak ellenőrzés és terv; semmit nem változtat
  --yes                 nem kérdez semmit
  --no-player           a kijelző-kiosk nem indul
  --keep-os-password    a rendszerjelszó marad
  --no-color            színek nélkül
  -h, --help            ez a súgó
USAGE
}

usage_error() { printf 'Hiba: %s\n\n' "$1" >&2; usage >&2; exit 2; }

parse_args() {
  while (( $# )); do
    case $1 in
      --version) [[ $# -ge 2 ]] || usage_error "a --version után kiadás kell"; WANT_VERSION=$2; shift 2 ;;
      --version=*) WANT_VERSION=${1#*=}; shift ;;
      --code-file) [[ $# -ge 2 ]] || usage_error "a --code-file után fájl kell"; CODE_FILE=$2; shift 2 ;;
      --code-file=*) CODE_FILE=${1#*=}; shift ;;
      --from) [[ $# -ge 2 ]] || usage_error "a --from után csomag vagy URL kell"; FROM=$2; shift 2 ;;
      --from=*) FROM=${1#*=}; shift ;;
      --sha256) [[ $# -ge 2 ]] || usage_error "a --sha256 után érték kell"; PIN_SHA=$2; PIN_OOB=1; shift 2 ;;
      --sha256=*) PIN_SHA=${1#*=}; PIN_OOB=1; shift ;;
      --check) CHECK=1; shift ;;
      --yes|-y) YES=1; shift ;;
      --no-player) NO_PLAYER=1; shift ;;
      --keep-os-password) KEEP_OS_PW=1; shift ;;
      --no-color) NO_COLOR_FLAG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "ismeretlen kapcsoló: $1" ;;
    esac
  done
  if [[ -n $WANT_VERSION ]]; then
    [[ $WANT_VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || usage_error "a kiadás alakja vX.Y.Z legyen"
    [[ $WANT_VERSION == v* ]] || WANT_VERSION="v$WANT_VERSION"
  fi
  if [[ -n $FROM ]]; then
    case $FROM in
      http://*|https://*) FROM_MODE=url; CURL_SEC=(--proto '=http,https') ;;
      *) FROM_MODE=file ;;
    esac
  fi
}

# Egy korábbi, megölt futás (SIGKILL, áramszünet) maradványai: a titkokat tartalmazó ideiglenes mappák törlése (a zár megszerzése után hívjuk: nem fut másik telepítő;
# a 2 percnél frissebb mappákhoz nem nyúlunk – az egy párhuzamos, csak olvasó --check futásé lehet).
sweep_stale() {
  local base d f n=0
  for base in "${TMPDIR:-/tmp}" "$RT_DIR"; do
    [[ -d $base ]] || continue
    while IFS= read -r -d '' d; do
      [[ $d != "$WORK" && $d != "$SECRETS" && ! -L $d && -O $d ]] || continue
      for f in "$d"/* "$d"/.[!.]*; do shred_file "$f"; done
      rm -rf -- "${d:?}" && n=$((n + 1))
    done < <(find "$base" -maxdepth 1 -type d -name 'kirakat-install.*' -user "$APP_USER" -mmin +2 -print0 2>/dev/null)
  done
  if (( n )); then ui_info "egy korábbi, megszakadt futás maradványait ($n ideiglenes mappa) törölte a telepítő"; fi
  return 0
}

main() {
  # a KIRAKAT_CODE környezeti változót azonnal átvesszük egy (nem exportált) shell-változóba, és kivesszük a környezetből: egyetlen gyerekfolyamat sem örökli
  PENDING_CODE="${KIRAKAT_CODE:-}"
  unset KIRAKAT_CODE
  parse_args "$@"
  detect_tty
  ui_init
  APP_USER="$(id -un)"; APP_GROUP="$(id -gn)"; APP_UID="$(id -u)"
  if [[ $APP_UID == 0 ]]; then
    ui_banner
    printf '%s\n' "${C_BAD}${G_BAD} Ne rootként futtasd a telepítőt.${C_RST}" "  Lépj be az odroid felhasználóval, és onnan add ki a parancsot: a sudo-jelszót a telepítő maga kéri." >&2
    exit 1
  fi
  : "${HOME:?}"
  CONSOLE_TTY="${KIRAKAT_CONSOLE_TTY:-}"
  if [[ -z $CONSOLE_TTY ]] && (( HAVE_TTY )); then CONSOLE_TTY="$(tty </dev/tty 2>/dev/null || true)"; fi
  if [[ $CONSOLE_TTY == /dev/tty1 ]]; then ON_TTY1=1; fi
  CACHE="${KIRAKAT_CACHE:-$HOME/.cache/kirakat-install}"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/kirakat-install.XXXXXX")" || { printf 'Nem hozható létre ideiglenes mappa.\n' >&2; exit 1; }
  chmod 700 "$WORK"
  WORK_LOG="$WORK/install.log"; : >"$WORK_LOG"; chmod 600 "$WORK_LOG"
  # a titkok (token, támogatási kulcs, jelszó) memóriában élő fájlrendszerre (tmpfs: /run/user/<uid>) kerülnek, ha van: egy megölt futás vagy áramszünet után sem maradnak a lemezen
  RT_DIR="${KIRAKAT_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$APP_UID}}"
  SECRETS=""
  if [[ -d $RT_DIR && -w $RT_DIR && -O $RT_DIR ]]; then SECRETS="$(mktemp -d "$RT_DIR/kirakat-install.XXXXXX" 2>/dev/null)" || SECRETS=""; fi
  [[ -n $SECRETS ]] || SECRETS=$WORK
  chmod 700 "$SECRETS"
  local lockdir=$WORK
  if (( ! CHECK )); then
    # a letöltés és az állapot a felhasználó saját (0700-as) mappájában él, hogy megszakadás után folytatható legyen; a --check ide sem ír
    mkdir -p -m 700 -- "$CACHE" || { printf 'Nem hozható létre a munkamappa: %s\n' "$CACHE" >&2; exit 1; }
    chmod 700 -- "$CACHE"            # meglévő mappánál is: a letöltés és az állapot csak a felhasználóé
    lockdir=$CACHE; STATE_FILE="$CACHE/state"
  fi
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap on_exit EXIT
  install_signal_traps

  ui_banner
  # egyszerre csak egy telepítő futhat
  acquire_lock "$lockdir/lock" || fail "másik telepítő fut már ezen az eszközön" "Várd meg, míg befejezi, vagy lépj be újra és ellenőrizd (ps aux | grep install)."
  if (( ! CHECK )); then sweep_stale; fi
  if [[ -n $STATE_FILE && -f $STATE_FILE ]]; then
    local k v st="" sn="" snm=""
    while IFS='=' read -r k v; do case $k in status) st=$v;; step) sn=$v;; name) snm=$v;; esac; done <"$STATE_FILE"
    if [[ $st == running || $st == failed ]]; then ui_info "Folytatás: az előző futás a(z) ${sn:-?}. lépésnél (${snm:-?}) megszakadt – folytatom (az ellenőrzött letöltés újrahasznosul)."; fi
  fi

  step_preflight
  step_credentials
  step_release
  if (( CHECK )); then
    print_plan
    return 0
  fi
  step_download
  step_system
  step_app
  step_updater
  step_os
  step_start

  summary
  # a véletlen jelszó mostantól „megmutatott”: ha ezután újrafuttatják, már nem cseréljük
  if [[ $OS_PW_MODE == random-applied ]]; then mark_os_password random; fi
  state_write done
  flush_log || true
  # siker: a letöltött csomag és a kicsomagolt fa már nem kell (csak a saját, ismert nevű elemeket töröljük); a titkok törlése
  rm -rf -- "${CACHE:?}/tree" "${CACHE:?}"/release-* "${CACHE:?}"/from-*
  if (( SUDO_OK )); then sudo -n rm -f -- "${INSTALL_STATE_DIR:?}"/dl-*.sha >/dev/null 2>&1 || true; fi
  rm -f -- "$STATE_FILE" "$CACHE/lock"
  rmdir -- "$CACHE" 2>/dev/null || true
  wipe_secrets
  apply_network_last
  unstage_root
  if (( PLAYER_DEFERRED )); then deferred_player_start; fi
  return 0
}

main "$@"
