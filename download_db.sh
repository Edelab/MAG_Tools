#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# download_db.sh — MAG_Tools database installer
#
# Downloads and installs all databases required by MAG_Tools workflows:
#
#   database/
#   ├── CheckM2_database/          CheckM2 (DIAMOND annotation DB)
#   │   └── uniref100.KO.1.dmnd
#   ├── GUNC/                      GUNC (chimerism/contamination)
#   │   └── gunc_db_progenomes2.1.dmnd
#   ├── genome_metrics/            GTDB genome reference table
#   │   └── genome_gtdb.tsv
#   └── rRNAs/                     16S/23S/5S rRNA reference DB (MAG_rRNA)
#       ├── rRNAs.fasta
#       └── rRNADB.*               BLAST index (built on first MAG_rRNA run)
#
# Usage:
#   bash download_db.sh [options]
#
###############################################################################

# ── Container images ──────────────────────────────────────────────────────────
CHECKM2_IMG="quay.io/biocontainers/checkm2:1.1.0--pyh7e72e81_1"
GUNC_IMG="quay.io/biocontainers/gunc:1.0.6--pyhdfd78af_0"

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="$SCRIPT_DIR/database"

DO_CHECKM2=1
DO_GUNC=1
DO_GENOME_GTDB=1
DO_RRNA=1
CHECKM2_REDUCED=0
GUNC_DB_VERSION="progenomes_2.1"   # or progenomes_3
THREADS=4
FORCE=0

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0m'
B='\033[1m'
G='\033[0;32m'
Y='\033[0;33m'
C='\033[0;36m'
RED='\033[0;31m'

log()     { echo -e "[$(date +'%H:%M:%S')] $*"; }
log_ok()  { echo -e "[$(date +'%H:%M:%S')] ${G}✓${R} $*"; }
log_skip(){ echo -e "[$(date +'%H:%M:%S')] ${Y}→${R} $*  ${Y}(already present — skipping)${R}"; }
log_err() { echo -e "[$(date +'%H:%M:%S')] ${RED}✗${R} $*" >&2; }

show_help() {
    printf "\n${B}╔══════════════════════════════════════════════════════════════╗${R}\n"
    printf "${B}║         download_db.sh — MAG_Tools Database Installer        ║${R}\n"
    printf "${B}╚══════════════════════════════════════════════════════════════╝${R}\n\n"

    printf "${B}USAGE${R}\n"
    printf "  ${C}bash download_db.sh${R} [options]\n\n"

    printf "${B}OPTIONS${R}\n"
    printf "  ${Y}-d${R}  Database root directory  [${C}$DB_DIR${R}]\n"
    printf "  ${Y}-t${R}  Threads for downloads    [${C}$THREADS${R}]\n"
    printf "  ${Y}-r${R}  Use reduced CheckM2 DB   (faster download, less accurate)\n"
    printf "  ${Y}-g${R}  GUNC DB version          [${C}$GUNC_DB_VERSION${R}]\n"
    printf "       Options: progenomes_2.1 | progenomes_3\n"
    printf "  ${Y}-f${R}  Force re-download even if DB already present\n\n"

    printf "${B}SELECT DATABASES${R}  (default: all)\n"
    printf "  ${Y}--only-checkm2${R}    Download only CheckM2\n"
    printf "  ${Y}--only-gunc${R}       Download only GUNC\n"
    printf "  ${Y}--only-gtdb${R}       Download only genome_gtdb.tsv\n"
    printf "  ${Y}--only-rrna${R}       Download only rRNAs\n"
    printf "  ${Y}--skip-checkm2${R}    Skip CheckM2\n"
    printf "  ${Y}--skip-gunc${R}       Skip GUNC\n"
    printf "  ${Y}--skip-gtdb${R}       Skip genome_gtdb.tsv\n"
    printf "  ${Y}--skip-rrna${R}       Skip rRNAs\n\n"

    printf "${B}EXAMPLES${R}\n"
    printf "  ${C}bash download_db.sh${R}                        # download everything\n"
    printf "  ${C}bash download_db.sh -d /data/databases${R}     # custom path\n"
    printf "  ${C}bash download_db.sh --only-checkm2 -r${R}      # CheckM2 reduced DB only\n"
    printf "  ${C}bash download_db.sh --skip-checkm2${R}         # everything except CheckM2\n"
    printf "  ${C}bash download_db.sh -f${R}                     # force re-download all\n\n"
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)  DB_DIR="$2"; shift 2 ;;
        -t)  THREADS="$2"; shift 2 ;;
        -r)  CHECKM2_REDUCED=1; shift ;;
        -g)  GUNC_DB_VERSION="$2"; shift 2 ;;
        -f)  FORCE=1; shift ;;
        --only-checkm2) DO_GUNC=0; DO_GENOME_GTDB=0; DO_RRNA=0; shift ;;
        --only-gunc)    DO_CHECKM2=0; DO_GENOME_GTDB=0; DO_RRNA=0; shift ;;
        --only-gtdb)    DO_CHECKM2=0; DO_GUNC=0; DO_RRNA=0; shift ;;
        --only-rrna)    DO_CHECKM2=0; DO_GUNC=0; DO_GENOME_GTDB=0; shift ;;
        --skip-checkm2) DO_CHECKM2=0; shift ;;
        --skip-gunc)    DO_GUNC=0; shift ;;
        --skip-gtdb)    DO_GENOME_GTDB=0; shift ;;
        --skip-rrna)    DO_RRNA=0; shift ;;
        -h|--help)      show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

DB_DIR=$(realpath -m "$DB_DIR")

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_err "Docker not found. Please install Docker and ensure it is running."
    exit 1
fi
if ! docker info &>/dev/null; then
    log_err "Docker daemon is not running or not accessible."
    exit 1
fi
if ! command -v curl &>/dev/null; then
    log_err "curl not found. Please install curl."
    exit 1
fi

mkdir -p "$DB_DIR"

echo ""
echo -e "${B}MAG_Tools — Database Installer${R}"
echo -e "  Database root : ${C}${DB_DIR}${R}"
echo -e "  CheckM2       : $([ $DO_CHECKM2 -eq 1 ] && echo "${G}yes${R}" || echo "skip")$([ $CHECKM2_REDUCED -eq 1 ] && echo " (reduced)" || echo "")"
echo -e "  GUNC          : $([ $DO_GUNC -eq 1 ] && echo "${G}yes${R} (${GUNC_DB_VERSION})" || echo "skip")"
echo -e "  genome_gtdb   : $([ $DO_GENOME_GTDB -eq 1 ] && echo "${G}yes${R}" || echo "skip")"
echo -e "  rRNAs         : $([ $DO_RRNA -eq 1 ] && echo "${G}yes${R}" || echo "skip")"
echo -e "  Force         : $([ $FORCE -eq 1 ] && echo "${Y}yes${R}" || echo "no")"
echo ""

ERRORS=0

###############################################################################
# 1. CheckM2
###############################################################################
if [[ $DO_CHECKM2 -eq 1 ]]; then
    log "${B}[1/4] CheckM2 database${R}"
    CHECKM2_DIR="$DB_DIR/CheckM2_database"
    CHECKM2_DMND="$CHECKM2_DIR/uniref100.KO.1.dmnd"

    if [[ -f "$CHECKM2_DMND" && $FORCE -eq 0 ]]; then
        log_skip "CheckM2 DB  ($CHECKM2_DMND)"
    else
        mkdir -p "$CHECKM2_DIR"
        [[ $FORCE -eq 1 && -f "$CHECKM2_DMND" ]] && rm -f "${CHECKM2_DIR:?}/"*

        log "Pulling Docker image: $CHECKM2_IMG"
        docker pull "$CHECKM2_IMG" 2>&1 | tail -n1

        log "Downloading CheckM2 database$([ $CHECKM2_REDUCED -eq 1 ] && echo " (reduced)" || echo "") ..."
        log "  This may take a while (full DB ~3 GB, reduced ~200 MB)."

        if [[ $CHECKM2_REDUCED -eq 1 ]]; then
            docker run --rm \
                -u "$(id -u)":"$(id -g)" \
                -v "$CHECKM2_DIR":/db \
                "$CHECKM2_IMG" \
                checkm2 database --download --reduced --path /db --no_write_json_db
        else
            docker run --rm \
                -u "$(id -u)":"$(id -g)" \
                -v "$CHECKM2_DIR":/db \
                "$CHECKM2_IMG" \
                checkm2 database --download --path /db --no_write_json_db
        fi

        # checkm2 puts it in a subdirectory — flatten if needed
        if [[ ! -f "$CHECKM2_DMND" ]]; then
            _found=$(find "$CHECKM2_DIR" -name "uniref100.KO.1.dmnd" 2>/dev/null | head -n1 || true)
            if [[ -n "$_found" && "$_found" != "$CHECKM2_DMND" ]]; then
                mv "$_found" "$CHECKM2_DMND"
                # Remove empty parent dirs
                find "$CHECKM2_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
            fi
        fi

        if [[ -f "$CHECKM2_DMND" ]]; then
            log_ok "CheckM2 DB  → $CHECKM2_DMND"
        else
            log_err "CheckM2 DB not found after download. Check Docker output above."
            ERRORS=$((ERRORS+1))
        fi
    fi
    echo ""
fi

###############################################################################
# 2. GUNC
###############################################################################
if [[ $DO_GUNC -eq 1 ]]; then
    log "${B}[2/4] GUNC database (${GUNC_DB_VERSION})${R}"
    GUNC_DIR="$DB_DIR/GUNC"
    mkdir -p "$GUNC_DIR"

    # Determine expected filename
    case "$GUNC_DB_VERSION" in
        progenomes_2.1) GUNC_DMND_NAME="gunc_db_progenomes2.1.dmnd" ;;
        progenomes_3)   GUNC_DMND_NAME="gunc_db_progenomes3.0.dmnd" ;;
        *)
            log_err "Unknown GUNC DB version: $GUNC_DB_VERSION  (use progenomes_2.1 or progenomes_3)"
            ERRORS=$((ERRORS+1))
            GUNC_DMND_NAME=""
            ;;
    esac

    if [[ -n "$GUNC_DMND_NAME" ]]; then
        GUNC_DMND="$GUNC_DIR/$GUNC_DMND_NAME"
        if [[ -f "$GUNC_DMND" && $FORCE -eq 0 ]]; then
            log_skip "GUNC DB  ($GUNC_DMND)"
        else
            [[ $FORCE -eq 1 && -f "$GUNC_DMND" ]] && rm -f "$GUNC_DMND"

            log "Pulling Docker image: $GUNC_IMG"
            docker pull "$GUNC_IMG" 2>&1 | tail -n1

            log "Downloading GUNC database (${GUNC_DB_VERSION}) ..."
            log "  This may take a while (~6 GB)."

            docker run --rm \
                -u "$(id -u)":"$(id -g)" \
                -v "$GUNC_DIR":/db \
                "$GUNC_IMG" \
                gunc download_db /db -db "$GUNC_DB_VERSION"

            # Find the downloaded file (name may vary slightly)
            _found=$(find "$GUNC_DIR" -name "*.dmnd" 2>/dev/null | head -n1 || true)
            if [[ -n "$_found" && "$_found" != "$GUNC_DMND" ]]; then
                mv "$_found" "$GUNC_DMND"
            fi

            if [[ -f "$GUNC_DMND" ]]; then
                log_ok "GUNC DB  → $GUNC_DMND"
            else
                log_err "GUNC DB not found after download."
                ERRORS=$((ERRORS+1))
            fi
        fi
    fi
    echo ""
fi

###############################################################################
# 3. genome_gtdb.tsv
###############################################################################
if [[ $DO_GENOME_GTDB -eq 1 ]]; then
    log "${B}[3/4] genome_gtdb.tsv (GTDB reference table)${R}"
    GTDB_DIR="$DB_DIR/genome_metrics"
    GTDB_TSV="$GTDB_DIR/genome_gtdb.tsv"
    GTDB_URL="https://zenodo.org/records/19922783/files/genome_gtdb.zip?download=1"

    if [[ -f "$GTDB_TSV" && $FORCE -eq 0 ]]; then
        log_skip "genome_gtdb.tsv  ($GTDB_TSV)"
    else
        mkdir -p "$GTDB_DIR"
        [[ $FORCE -eq 1 && -f "$GTDB_TSV" ]] && rm -f "$GTDB_TSV"

        log "Downloading genome_gtdb.zip from Zenodo..."
        GTDB_ZIP="$GTDB_DIR/genome_gtdb.zip"

        if curl -fsSL --progress-bar \
                --retry 3 --retry-delay 5 \
                -o "$GTDB_ZIP" "$GTDB_URL"; then
            log "Extracting..."
            unzip -o "$GTDB_ZIP" -d "$GTDB_DIR" > /dev/null
            rm -f "$GTDB_ZIP"

            # Accept genome_gtdb.tsv at root or inside a subdir
            if [[ ! -f "$GTDB_TSV" ]]; then
                _found=$(find "$GTDB_DIR" -name "genome_gtdb.tsv" | head -n1 || true)
                [[ -n "$_found" ]] && mv "$_found" "$GTDB_TSV"
            fi

            if [[ -f "$GTDB_TSV" ]]; then
                _rows=$(awk 'NR>1' "$GTDB_TSV" | wc -l | tr -d ' ')
                log_ok "genome_gtdb.tsv  → $GTDB_TSV  (${_rows} genomes)"
            else
                log_err "genome_gtdb.tsv not found after extraction."
                ERRORS=$((ERRORS+1))
            fi
        else
            log_err "Download failed: $GTDB_URL"
            rm -f "$GTDB_ZIP"
            ERRORS=$((ERRORS+1))
        fi
    fi
    echo ""
fi

###############################################################################
# 4. rRNAs database (MAG_rRNA auto mode)
###############################################################################
if [[ $DO_RRNA -eq 1 ]]; then
    log "${B}[4/4] rRNA reference database (MAG_rRNA)${R}"
    RRNA_DIR="$DB_DIR/rRNAs"
    RRNA_FA="$RRNA_DIR/rRNAs.fasta"
    RRNA_URL="https://zenodo.org/records/19922783/files/rRNAs.zip?download=1"

    if [[ -f "$RRNA_FA" && $FORCE -eq 0 ]]; then
        log_skip "rRNAs.fasta  ($RRNA_FA)"
    else
        mkdir -p "$RRNA_DIR"
        [[ $FORCE -eq 1 && -f "$RRNA_FA" ]] && rm -f "$RRNA_FA"

        log "Downloading rRNAs.zip from Zenodo..."
        RRNA_ZIP="$RRNA_DIR/rRNAs.zip"

        if curl -fsSL --progress-bar \
                --retry 3 --retry-delay 5 \
                -o "$RRNA_ZIP" "$RRNA_URL"; then
            log "Extracting..."
            unzip -o "$RRNA_ZIP" -d "$RRNA_DIR" > /dev/null
            rm -f "$RRNA_ZIP"

            if [[ ! -f "$RRNA_FA" ]]; then
                _found=$(find "$RRNA_DIR" -name "rRNAs.fasta" | head -n1 || true)
                [[ -n "$_found" ]] && mv "$_found" "$RRNA_FA"
            fi

            if [[ -f "$RRNA_FA" ]]; then
                _seqs=$(grep -c '^>' "$RRNA_FA" || true)
                log_ok "rRNAs.fasta  → $RRNA_FA  (${_seqs} sequences)"
                log "  Note: BLAST index will be built automatically on first MAG_rRNA run."
            else
                log_err "rRNAs.fasta not found after extraction."
                ERRORS=$((ERRORS+1))
            fi
        else
            log_err "Download failed: $RRNA_URL"
            rm -f "$RRNA_ZIP"
            ERRORS=$((ERRORS+1))
        fi
    fi
    echo ""
fi

###############################################################################
# Summary
###############################################################################
echo "══════════════════════════════════════════════════════"
echo -e "  ${B}Database installation summary${R}"
echo "══════════════════════════════════════════════════════"
echo -e "  Root: ${C}${DB_DIR}${R}"
echo ""

_check() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        echo -e "  ${G}✓${R}  ${label}"
        echo -e "       ${path}"
    else
        echo -e "  ${RED}✗${R}  ${label}  ${RED}NOT FOUND${R}"
    fi
}

[[ $DO_CHECKM2    -eq 1 ]] && _check "CheckM2 DB"       "$DB_DIR/CheckM2_database/uniref100.KO.1.dmnd"
[[ $DO_GUNC       -eq 1 ]] && _check "GUNC DB"          "$DB_DIR/GUNC/gunc_db_progenomes2.1.dmnd"
[[ $DO_GENOME_GTDB -eq 1 ]] && _check "genome_gtdb.tsv" "$DB_DIR/genome_metrics/genome_gtdb.tsv"
[[ $DO_RRNA       -eq 1 ]] && _check "rRNAs.fasta"      "$DB_DIR/rRNAs/rRNAs.fasta"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "  ${G}${B}All databases ready.${R}"
    echo ""
    echo -e "  You can now run MAG_Tools workflows:"
    echo -e "  ${C}bash MAG_Tools.sh -w MAG_finder  [options]${R}"
    echo -e "  ${C}bash MAG_Tools.sh -w MAG_summary [options]${R}"
    echo -e "  ${C}bash MAG_Tools.sh -w MAG_cleaner [options]${R}"
    echo -e "  ${C}bash MAG_Tools.sh -w MAG_rRNA    [options]${R}"
else
    echo -e "  ${RED}${B}${ERRORS} database(s) failed to download.${R}"
    echo -e "  Check the errors above and re-run with ${Y}-f${R} to retry."
    exit 1
fi
echo "══════════════════════════════════════════════════════"
