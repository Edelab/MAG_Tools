#!/usr/bin/env bash
set -euo pipefail

# Minimal MAG summary pipeline (English, concise)
# Steps: 1 QUAST 2 PROKKA 3 CheckM1 4 CheckM2 5 GUNC 6 Genus assignments 7 Combined metrics & tables 8 Summary

if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: bash >= 4 required." >&2
  exit 1
fi

SCRIPT_PID=$$
DOCKER_LABEL="mag_summary_run=$(date +%Y%m%d%H%M%S)"
CURRENT_DOCKER_PID=""

# Wrapper: all drun calls go through drun so they can be killed instantly
drun() {
  (( ${STOP_REQUESTED:-0} )) && return 1
  docker run "$@" &
  CURRENT_DOCKER_PID=$!
  wait "$CURRENT_DOCKER_PID"
  local rc=$?
  CURRENT_DOCKER_PID=""
  return $rc
}

nuke_everything() {
  [[ -n "$CURRENT_DOCKER_PID" ]] && kill -KILL "$CURRENT_DOCKER_PID" 2>/dev/null || true
  local ids
  ids=$(docker ps -a --filter "label=${DOCKER_LABEL}" -q 2>/dev/null || true)
  if [[ -n "$ids" ]]; then
    echo "[SIGNAL] Killing containers: $(echo "$ids" | tr '\n' ' ')" >&2
    docker kill --signal SIGKILL $ids >/dev/null 2>&1 || true
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  for child in $(pgrep -P "$SCRIPT_PID" 2>/dev/null || true); do
    kill -KILL "$child" 2>/dev/null || true
  done
}

STOP_REQUESTED=0
on_interrupt() {
  if [[ $STOP_REQUESTED -eq 0 ]]; then
    echo "" >&2
    echo "[SIGNAL] Interrupt — stopping. Press again to force-kill." >&2
    STOP_REQUESTED=1
    nuke_everything
  else
    echo "" >&2
    echo "[SIGNAL] Force-kill. Terminating now." >&2
    nuke_everything
    kill -KILL -- "-${SCRIPT_PID}" 2>/dev/null || true
    exit 130
  fi
}
on_tstp() {
  echo "" >&2
  echo "[SIGNAL] Ctrl+Z — stopping and killing containers..." >&2
  STOP_REQUESTED=1
  nuke_everything
  kill -KILL -- "-${SCRIPT_PID}" 2>/dev/null || true
  exit 130
}
trap on_interrupt INT TERM
trap on_tstp    TSTP

log()  { echo "[$(date +'%H:%M:%S')] $*" >&2; }
vlog() { [[ $VERBOSE -eq 1 ]] && log "DEBUG: $*"; }

CHECKM1_IMG="quay.io/biocontainers/checkm-genome:1.2.4--pyhdfd78af_2"
CHECKM2_IMG="quay.io/biocontainers/checkm2:1.1.0--pyh7e72e81_1"
GUNC_IMG="quay.io/biocontainers/gunc:1.0.6--pyhdfd78af_0"
QUAST_IMG="quay.io/biocontainers/quast:5.3.0--py313pl5321h5ca1c30_2"
PROKKA_IMG="quay.io/biocontainers/prokka:1.14.6--pl5321hdfd78af_4"

VERBOSE=0
CHECK_GZ=0
CLEANUP=1          # remove staging + temp files at the end (-K to skip)
CHECKM2_DB_DIR=""
CHECKM2_DB_REDUCED=0
FORCE_DB_REDOWNLOAD=0
GENOME_GTDB_FILE=""
THREADS=1

show_help() {
    local BOLD='\033[1m'
    local CYAN='\033[0;36m'
    local YELLOW='\033[0;33m'
    local GREEN='\033[0;32m'
    local DIM='\033[2m'
    local RESET='\033[0m'
    printf "\n"
    printf "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}${CYAN}║         MAG_summary  —  Quality Assessment & Annotation           ║${RESET}\n"
    printf "${BOLD}${CYAN}║       QUAST ▸ PROKKA ▸ CheckM1/2 ▸ GUNC ▸ Genus ▸ Tables          ║${RESET}\n"
    printf "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════╝${RESET}\n\n"
    printf "${BOLD}USAGE${RESET}\n"
    printf "  bash MAG_summary.sh ${YELLOW}-d${RESET} <MAGs_dir> ${YELLOW}-o${RESET} <out_dir> ${YELLOW}-t${RESET} <threads> ${YELLOW}-g${RESET} <gunc_db.dmnd>  [OPTIONS]\n\n"
    printf "${BOLD}REQUIRED${RESET}\n"
    printf "  ${YELLOW}-d${RESET} <MAGs_dir>         Directory with FASTA files (.fa .fna .fasta or .gz).\n"
    printf "  ${YELLOW}-o${RESET} <out_dir>          Root output directory (created if absent).\n"
    printf "  ${YELLOW}-t${RESET} <threads>          CPU threads passed to all tools.\n"
    printf "  ${YELLOW}-g${RESET} <gunc_db.dmnd>     Path to the GUNC diamond database file.\n\n"
    printf "${BOLD}CHECKM2 DATABASE${RESET}\n"
    printf "  ${YELLOW}-c${RESET} <db_dir>           Directory containing the CheckM2 database.\n"
    printf "                      Accepts flat layout (db_dir/uniref100.KO.1.dmnd) OR\n"
    printf "                      standard download layout (db_dir/CheckM2_database/*.dmnd).\n"
    printf "                      If omitted, defaults to <out_dir>/checkm2_db/.\n"
    printf "  ${YELLOW}-R${RESET}                   Download the reduced CheckM2 database (faster, smaller).\n"
    printf "  ${YELLOW}-F${RESET}                   Force re-download even if DB already exists.\n\n"
    printf "${BOLD}REFERENCE & TAXONOMY${RESET}\n"
    printf "  ${YELLOW}-G${RESET} <genome_gtdb.tsv>  GTDB genome metrics table (ncbi_genbank_assembly_accession\n"
    printf "                      column required). If omitted, looks for\n"
    printf "                      ${DIM}<out_dir>/../database/genome_metrics/genome_gtdb.tsv${RESET}\n\n"
    printf "${BOLD}RUNTIME${RESET}\n"
    printf "  ${YELLOW}-K${RESET}                   Keep intermediate files (staging FASTA copies,\n"
    printf "                      generated Python scripts, tmp dirs). Default: remove them.\n"
    printf "  ${YELLOW}-v${RESET}                   Verbose / debug logging.\n"
    printf "  ${YELLOW}-z${RESET}                   Test gzip integrity of input files before processing.\n"
    printf "  ${YELLOW}-h${RESET}                   Show this help and exit.\n\n"
    printf "${BOLD}PIPELINE STEPS${RESET}\n"
    printf "  ${GREEN}[1]${RESET} ${BOLD}QUAST${RESET}            Structural metrics (N50, GC, contigs...).\n"
    printf "  ${GREEN}[2]${RESET} ${BOLD}PROKKA${RESET}           Gene annotation (CDS, tRNA, rRNA, coding density).\n"
    printf "  ${GREEN}[3]${RESET} ${BOLD}CheckM1${RESET}          Lineage completeness / contamination.\n"
    printf "  ${GREEN}[4]${RESET} ${BOLD}CheckM2${RESET}          ML-based completeness / contamination.\n"
    printf "  ${GREEN}[5]${RESET} ${BOLD}GUNC${RESET}             Chimerism detection + dominant genus assignment.\n"
    printf "  ${GREEN}[6]${RESET} ${BOLD}Genus metrics${RESET}    Combined table, z-scores, percentiles vs GTDB.\n"
    printf "  ${GREEN}[7]${RESET} ${BOLD}Summary plot${RESET}     Multi-panel PNG: scatter, heatmap, ranks, stats.\n"
    printf "  ${GREEN}[8]${RESET} ${BOLD}Cleanup${RESET}         Remove staging + temp files (skip with -K).\n\n"
    printf "${BOLD}OUTPUT STRUCTURE${RESET}\n"
    printf "  <out_dir>/\n"
    printf "  ├── tables/\n"
    printf "  │   ├── structural_metrics.tsv\n"
    printf "  │   ├── annotation_metrics.tsv\n"
    printf "  │   ├── genus_assignments.tsv\n"
    printf "  │   ├── genome_metrics_final.tsv   all metrics, z-scores, percentiles\n"
    printf "  │   └── mag_metric_ranks.tsv\n"
    printf "  ├── plots/\n"

    printf "  ├── quast/   annotation/prokka/   checkm/   checkm2/   gunc/\n"
    printf "  └── log.txt  (written to stderr)\n\n"
    printf "${BOLD}EXAMPLES${RESET}\n"
    printf "  ${DIM}# Basic run using an existing CheckM2 DB:${RESET}\n"
    printf "  bash MAG_summary.sh \\\\\n"
    printf "      -d 05_MAGs_derep/dRep -o summary_out -t 16 \\\\\n"
    printf "      -g /data/gunc_db/db.dmnd -c /data/checkm2_db\n\n"

    printf "${DIM}Ctrl+C once = graceful stop; twice = force-kill all containers.${RESET}\n\n"
}

while getopts "d:o:t:g:c:RFvzG:Kh" opt; do
  case $opt in
    d) FASTA_DIR="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    g) GUNC_DB="$OPTARG" ;;
    c) CHECKM2_DB_DIR="$OPTARG" ;;
    R) CHECKM2_DB_REDUCED=1 ;;
    F) FORCE_DB_REDOWNLOAD=1 ;;
    v) VERBOSE=1 ;;
    z) CHECK_GZ=1 ;;
    G) GENOME_GTDB_FILE="$OPTARG" ;;
    K) CLEANUP=0 ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

if [[ -z "${FASTA_DIR:-}" || -z "${OUT_DIR:-}" || -z "${THREADS:-}" ]]; then
  echo "ERROR: -d -o -t are required" >&2
  exit 1
fi
GUNC_DB="${GUNC_DB:-}"  # may be auto-discovered below

FASTA_DIR=$(realpath "$FASTA_DIR")
OUT_DIR=$(realpath "$OUT_DIR")
mkdir -p "$OUT_DIR"

# ── Auto-discovery of databases ───────────────────────────────────────────────
# Searches relative to the script's own directory (supports both direct call
# and call via MAG_Tools.sh wrapper — both share the same directory tree).
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

_find_db_file() {
  # Usage: _find_db_file <filename> <max_depth> [search_root...]
  local fname="$1" depth="$2"; shift 2
  local roots=("$@")
  local f
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    f=$(find "$root" -maxdepth "$depth" -name "$fname" -type f 2>/dev/null | head -n1)
    [[ -n "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

find_databases_auto() {
  local BOLD='\033[1m'
  local YELLOW='\033[0;33m'
  local RED='\033[0;31m'
  local GREEN='\033[0;32m'
  local RESET='\033[0m'
  local missing=0

  # Common search roots: script dir, parent, grandparent (covers most setups)
  local SEARCH_ROOTS=(
    "$SCRIPT_DIR"
    "$SCRIPT_DIR/.."
    "$SCRIPT_DIR/../.."
    "$OUT_DIR"
    "$OUT_DIR/.."
  )

  echo "" >&2
  echo "[DB-DISCOVERY] Searching for databases from: $SCRIPT_DIR" >&2

  # ── CheckM2 ─────────────────────────────────────────────────────────────
  if [[ -z "$CHECKM2_DB_DIR" ]] || ! find_checkm2_dmnd "$CHECKM2_DB_DIR" > /dev/null 2>&1; then
    local cm2_dmnd
    cm2_dmnd=$(_find_db_file "uniref100.KO.1.dmnd" 5 "${SEARCH_ROOTS[@]}" || true)
    if [[ -n "$cm2_dmnd" ]]; then
      CHECKM2_DB_DIR=$(dirname "$cm2_dmnd")
      # If it's inside CheckM2_database/, use the parent as DB dir
      [[ "$(basename "$CHECKM2_DB_DIR")" == "CheckM2_database" ]] && CHECKM2_DB_DIR=$(dirname "$CHECKM2_DB_DIR")
      echo "[DB-DISCOVERY]  ${GREEN}CheckM2 DB found${RESET}: $cm2_dmnd" >&2
    else
      echo "[DB-DISCOVERY]  ${YELLOW}CheckM2 DB not found${RESET} — will download to: ${CHECKM2_DB_DIR:-$OUT_DIR/checkm2_db}" >&2
      echo "                ${YELLOW}(or specify with -c <db_dir>)${RESET}" >&2
      echo "                Download: https://data.ace.uq.edu.au/public/CheckM2_databases/" >&2
    fi
  else
    echo "[DB-DISCOVERY]  ${GREEN}CheckM2 DB (user-specified)${RESET}: $CHECKM2_DB_DIR" >&2
  fi

  # ── genome_gtdb.tsv ──────────────────────────────────────────────────────
  if [[ -z "$GENOME_GTDB_FILE" ]] || [[ ! -f "$GENOME_GTDB_FILE" ]]; then
    local gtdb_f
    gtdb_f=$(_find_db_file "genome_gtdb.tsv" 6 "${SEARCH_ROOTS[@]}" || true)
    if [[ -n "$gtdb_f" ]]; then
      GENOME_GTDB_FILE="$gtdb_f"
      echo "[DB-DISCOVERY]  ${GREEN}genome_gtdb.tsv found${RESET}: $gtdb_f" >&2
    else
      echo "[DB-DISCOVERY]  ${RED}genome_gtdb.tsv NOT FOUND${RESET}" >&2
      echo "                Please inform with -G <path/genome_gtdb.tsv>" >&2
      echo "                Download: https://data.gtdb.ecogenomic.org/releases/latest/bac120_metadata.tsv.gz" >&2
      missing=$((missing+1))
    fi
  else
    echo "[DB-DISCOVERY]  ${GREEN}genome_gtdb.tsv (user-specified)${RESET}: $GENOME_GTDB_FILE" >&2
  fi

  # ── GUNC ─────────────────────────────────────────────────────────────────
  if [[ -z "$GUNC_DB" ]] || [[ ! -f "$GUNC_DB" ]]; then
    local gunc_f
    gunc_f=$(_find_db_file "gunc_db.dmnd" 6 "${SEARCH_ROOTS[@]}" || true)
    # also accept any .dmnd in a gunc-named dir
    if [[ -z "$gunc_f" ]]; then
      gunc_f=$(find "${SEARCH_ROOTS[@]}" -maxdepth 6 -path "*/gunc*/*.dmnd" -type f 2>/dev/null | head -n1 || true)
    fi
    if [[ -n "$gunc_f" ]]; then
      GUNC_DB="$gunc_f"
      echo "[DB-DISCOVERY]  ${GREEN}GUNC DB found${RESET}: $gunc_f" >&2
    else
      echo "[DB-DISCOVERY]  ${RED}GUNC DB NOT FOUND${RESET}" >&2
      echo "                Please inform with -g <path/gunc_db.dmnd>" >&2
      echo "                Download: https://grp-bork.embl-community.io/gunc/installation.html" >&2
      echo "                  docker run --rm -v /your/db/dir:/db $GUNC_IMG gunc download_db /db" >&2
      missing=$((missing+1))
    fi
  else
    echo "[DB-DISCOVERY]  ${GREEN}GUNC DB (user-specified)${RESET}: $GUNC_DB" >&2
  fi

  echo "" >&2

  if [[ $missing -gt 0 ]]; then
    echo "[DB-DISCOVERY] ${RED}${BOLD}$missing required database(s) missing. Cannot proceed.${RESET}" >&2
    echo "[DB-DISCOVERY] Re-run with the appropriate flags once databases are available." >&2
    exit 1
  fi
}

find_databases_auto

# ── Validate genome_gtdb.tsv header ──────────────────────────────────────────
GENOME_GTDB_FILE=$(realpath "$GENOME_GTDB_FILE")
if ! head -n1 "$GENOME_GTDB_FILE" | grep -q $'\tncbi_genbank_assembly_accession\>' && \
   ! head -n1 "$GENOME_GTDB_FILE" | grep -q '^ncbi_genbank_assembly_accession\>'; then
  echo "ERROR: column ncbi_genbank_assembly_accession missing in genome_gtdb.tsv" >&2
  exit 1
fi

# Resolve GUNC_DB to absolute path
GUNC_DB=$(realpath "$GUNC_DB")

TABLE_DIR="$OUT_DIR/06_TABLES"
mkdir -p "$TABLE_DIR"
STAGING="$OUT_DIR/staging"
mkdir -p "$STAGING"; rm -f "$STAGING"/*

STRUCT="$TABLE_DIR/structural_metrics.tsv"
ANNOT="$TABLE_DIR/annotation_metrics.tsv"

if [[ -z "$CHECKM2_DB_DIR" ]]; then
  # Auto-discover: look relative to OUT_DIR/../database (same convention as genome_gtdb.tsv)
  for _cand in       "$(realpath -m "$OUT_DIR/../database/CheckM2_database")"       "$(realpath -m "$OUT_DIR/../database/checkm2_db")"       "$(realpath -m "$OUT_DIR/../database")"; do
    if find "$_cand" -maxdepth 2 -name "uniref100.KO.1.dmnd" 2>/dev/null | grep -q .; then
      CHECKM2_DB_DIR="$_cand"
      log "CheckM2 DB auto-discovered: $CHECKM2_DB_DIR"
      break
    fi
  done
  [[ -z "$CHECKM2_DB_DIR" ]] && CHECKM2_DB_DIR="$OUT_DIR/checkm2_db"
fi
CHECKM2_DB_DIR=$(realpath -m "$CHECKM2_DB_DIR"); mkdir -p "$CHECKM2_DB_DIR"

log "Scanning FASTA dir"
mapfile -t FASTA_FILES < <(find "$FASTA_DIR" -maxdepth 1 -type f \
  \( -iname "*.fa" -o -iname "*.fna" -o -iname "*.fasta" -o -iname "*.fa.gz" -o -iname "*.fna.gz" -o -iname "*.fasta.gz" \) | sort)
[[ ${#FASTA_FILES[@]} -eq 0 ]] && { echo "ERROR: no FASTA files" >&2; exit 1; }

log "Copying FASTAs"
i=0
for src in "${FASTA_FILES[@]}"; do
  i=$((i+1))
  b=$(basename "$src")
  core="${b%.gz}"
  root="${core%.*}"
  dest="$STAGING/${root}.fna"
  if [[ "$src" == *.gz ]]; then
    [[ $CHECK_GZ -eq 1 ]] && gzip -t "$src"
    gzip -cd "$src" > "$dest"
  else
    cp -f "$src" "$dest"
  fi
  sed -i 's/\r$//' "$dest"
  printf "\r  %d/%d %s" "$i" "${#FASTA_FILES[@]}" "$b" >&2
done
echo >&2

# 1 QUAST
log "QUAST..."
QUAST_DIR="$OUT_DIR/01_QUAST"; rm -rf "$QUAST_DIR"; mkdir -p "$QUAST_DIR"
drun --rm --label "$DOCKER_LABEL" -u "$(id -u)":"$(id -g)" -v "$STAGING":/in -v "$OUT_DIR":/out "$QUAST_IMG" \
  bash -lc "quast.py /in/*.fna -o /out/01_QUAST -t $THREADS --no-icarus >/out/01_QUAST/_quast.log 2>&1"
REPORT_TSV="$QUAST_DIR/report.tsv"
[[ -f "$REPORT_TSV" ]] || { log "ERROR: missing report.tsv"; exit 1; }

fasta_gc_count() {
  awk 'BEGIN{gc=0} /^>/ {next} {gsub(/[ \t\r]/,""); t=toupper($0); gc+=gsub(/[GC]/,"&",t)} END{print gc}' "$1"
}

echo -e "Genome\tSize(bp)\tGC_count\tContigs\tGC(%)\tMean_Contig_Len\tN50\tN90\tL50\tL90" > "$STRUCT"
IFS=$'\t' read -r -a HEADER < <(head -n1 "$REPORT_TSV")
ASSEMBLIES=("${HEADER[@]:1}")
declare -A Q
while IFS=$'\t' read -r -a cols; do
  m="${cols[0]}"
  for idx in "${!ASSEMBLIES[@]}"; do
    asm="${ASSEMBLIES[$idx]}"
    Q["${asm}__${m}"]="${cols[$((idx+1))]}"
  done
done < <(tail -n +2 "$REPORT_TSV")

for asm in "${ASSEMBLIES[@]}"; do
  total="${Q["${asm}__Total length"]:-NA}"
  contigs="${Q["${asm}__# contigs"]:-${Q["${asm}__# contigs (>= 0 bp)"]:-NA}}"
  gcperc="${Q["${asm}__GC (%)"]:-NA}"
  N50="${Q["${asm}__N50"]:-NA}"
  N90="${Q["${asm}__N90"]:-NA}"
  L50="${Q["${asm}__L50"]:-NA}"
  L90="${Q["${asm}__L90"]:-NA}"
  if [[ "$total" =~ ^[0-9]+$ && "$contigs" =~ ^[0-9]+$ && $contigs -gt 0 ]]; then
    mean=$(awk -v t="$total" -v c="$contigs" 'BEGIN{printf "%.2f",t/c}')
  else
    mean="NA"
  fi
  f="$STAGING/${asm}.fna"
  [[ -f "$f" ]] && gc_count=$(fasta_gc_count "$f") || gc_count="NA"
  if [[ "$gcperc" != "NA" && "$gcperc" != "" ]]; then
    gc_fmt=$(awk -v x="$gcperc" 'BEGIN{if(x=="NA"||x=="")print "NA"; else printf "%.4f",x+0}')
  else
    gc_fmt="NA"
  fi
  echo -e "${asm}\t${total}\t${gc_count}\t${contigs}\t${gc_fmt}\t${mean}\t${N50}\t${N90}\t${L50}\t${L90}" >> "$STRUCT"
done
log "QUAST done."

# 2 PROKKA
log "PROKKA..."
ANNOT_DIR="$OUT_DIR/02_ANNOTATION"
PROKKA_DIR="$ANNOT_DIR/prokka"
mkdir -p "$PROKKA_DIR"
echo -e "Genome\tprotein_count\tcoding_density\tcds_total_len_bp\tncbi_trna_count\tncbi_rrna_count" > "$ANNOT"
PROKKA_TOTAL=0; PROKKA_OK=0; PROKKA_WARN=0
for f in "$STAGING"/*.fna; do
  g=$(basename "${f%.fna}")
  PROKKA_TOTAL=$((PROKKA_TOTAL+1))
  log "  PROKKA ($PROKKA_TOTAL/${#FASTA_FILES[@]}): $g"
  outdir="$PROKKA_DIR/$g"; rm -rf "$outdir"
  # NOTE: do NOT mkdir "$outdir" here — PROKKA refuses to run if outdir already exists.
  # Log goes to the parent dir so the file path exists before the container starts.
  PROKKA_LOG="$PROKKA_DIR/${g}.stderr.log"
  # Known cosmetic noise in PROKKA 1.14.6 (non-fatal, safe to suppress):
  #   "print() on closed filehandle $faa"    — Prodigal overflow in metagenome mode
  #   "Argument ... isn't numeric in numeric" — Prodigal version string parse failure
  PROKKA_NOISE='print() on closed filehandle\|isn.t numeric in numeric'

  if ! drun --rm --label "$DOCKER_LABEL" -u "$(id -u)":"$(id -g)" \
        -v "$STAGING":/in -v "$PROKKA_DIR":/out "$PROKKA_IMG" \
        bash -lc "prokka --outdir /out/$g --prefix $g --cpus $THREADS \
                  --kingdom Bacteria --metagenome --quiet --force \
                  /in/$(basename "$f") 2>/out/${g}.stderr.log"; then
    grep -v "$PROKKA_NOISE" "$PROKKA_LOG" 2>/dev/null | grep -i 'error\|fatal\|died' >&2 || true
    log "WARN: PROKKA failed $g"
    PROKKA_WARN=$((PROKKA_WARN+1))
    echo -e "$g\tNA\tNA\tNA\tNA\tNA" >> "$ANNOT"
    continue
  fi

  # Surface any real (non-cosmetic) warnings
  if [[ -s "$PROKKA_LOG" ]]; then
    real_warns=$(grep -vc "$PROKKA_NOISE" "$PROKKA_LOG" 2>/dev/null || true)
    [[ "$real_warns" -gt 0 ]] && grep -v "$PROKKA_NOISE" "$PROKKA_LOG" >&2
  fi

  faa="$outdir/${g}.faa"
  ffn="$outdir/${g}.ffn"
  gff="$outdir/${g}.gff"

  # Check for truncated .faa (closed-filehandle bug can leave it incomplete)
  if [[ -s "$faa" ]]; then
    prot=$(grep -c '^>' "$faa")
    # GFF CDS count as ground truth — warn if .faa is significantly shorter
    gff_cds=$(awk -F'\t' '$3=="CDS"' "$gff" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$gff_cds" -gt 0 && "$prot" -lt "$((gff_cds * 80 / 100))" ]]; then
      log "WARN: $g .faa may be truncated (faa proteins: $prot, GFF CDS: $gff_cds). Falling back to GFF counts."
      prot="$gff_cds"
      PROKKA_WARN=$((PROKKA_WARN+1))
    fi
  else
    prot=0
    log "WARN: $g .faa is empty"
    PROKKA_WARN=$((PROKKA_WARN+1))
  fi

  if [[ -s "$ffn" ]]; then
    cds_bp=$(awk 'NR%2==0{gsub(/[ \t\r]/,""); l+=length($0)} END{print l+0}' "$ffn")
  else
    cds_bp=$(awk -F'\t' '$3=="CDS"{l+=$5-$4+1} END{print l+0}' "$gff")
  fi
  trna=$(awk -F'\t' '$3=="tRNA"' "$gff" | wc -l | tr -d ' ')
  rrna=$(awk -F'\t' '$3=="rRNA"' "$gff" | wc -l | tr -d ' ')
  gsize=$(awk -v id="$g" 'NR>1 && $1==id{print $2}' "$STRUCT" | head -n1)
  if [[ "$gsize" =~ ^[0-9]+$ && "$gsize" -gt 0 && "$cds_bp" =~ ^[0-9]+$ ]]; then
    dens=$(awk -v c="$cds_bp" -v s="$gsize" 'BEGIN{printf "%.4f",(c*100)/s}')
  else
    dens="NA"
  fi
  echo -e "$g\t$prot\t$dens\t$cds_bp\t$trna\t$rrna" >> "$ANNOT"
  PROKKA_OK=$((PROKKA_OK+1))
done
log "PROKKA done. OK: $PROKKA_OK / $PROKKA_TOTAL$([ $PROKKA_WARN -gt 0 ] && echo " (warnings: $PROKKA_WARN)" || true)"

# 3 CheckM1
log "CheckM1..."
mkdir -p "$OUT_DIR/03_CheckM1"
CHECKM1_TSV="$OUT_DIR/03_CheckM1/checkm.tsv"
CHECKM1_OK=0
# CheckM1 can fail due to pplacer issues in some container builds — treat as non-fatal.
# The pipeline continues; CheckM1 columns will appear as NA in combined tables.
if drun --rm --label "$DOCKER_LABEL" -v "$STAGING":/genomes -v "$OUT_DIR":/out       -u "$(id -u)":"$(id -g)" "$CHECKM1_IMG"       bash -lc "checkm lineage_wf /genomes /out/03_CheckM1 -t $THREADS -x fna \
                --tab_table -f /out/03_CheckM1/checkm.tsv 2>&1 | \
                grep -v 'pplacer.json\|Uncaught exception\|Fatal error' || true; \
                test -f /out/03_CheckM1/checkm.tsv"; then
  [[ -s "$CHECKM1_TSV" ]] && CHECKM1_OK=1 && log "CheckM1 done." || log "WARN: CheckM1 output empty."
else
  log "WARN: CheckM1 failed (pplacer/container issue). CheckM1 columns will be NA."
  # Create a minimal empty TSV so downstream Python doesn't crash on missing file
  mkdir -p "$OUT_DIR/03_CheckM1"
  echo -e "Bin Id	Marker lineage	# genomes	# markers	# marker sets	0	1	2	3	4	5+	Completeness	Contamination	Strain heterogeneity" > "$CHECKM1_TSV"
fi

# 4 CheckM2
log "CheckM2 DB..."
# Resolve the .dmnd file — search in common layouts:
#   <db_dir>/uniref100.KO.1.dmnd              (flat layout)
#   <db_dir>/CheckM2_database/uniref100.KO.1.dmnd  (default download layout)
#   <db_dir>/**/uniref100.KO.1.dmnd           (any subdir)
find_checkm2_dmnd() {
  local d="$1"
  local f
  # flat
  f="$d/uniref100.KO.1.dmnd"; [[ -f "$f" ]] && { echo "$f"; return 0; }
  # standard download subdir
  f="$d/CheckM2_database/uniref100.KO.1.dmnd"; [[ -f "$f" ]] && { echo "$f"; return 0; }
  # any subdir (one level)
  f=$(find "$d" -maxdepth 2 -name "uniref100.KO.1.dmnd" 2>/dev/null | head -n1)
  [[ -n "$f" ]] && { echo "$f"; return 0; }
  return 1
}
if [[ $FORCE_DB_REDOWNLOAD -eq 1 ]]; then
  log "CheckM2: forcing DB re-download (removing $CHECKM2_DB_DIR)"
  rm -rf "${CHECKM2_DB_DIR:?}/"*
fi
CHECKM2_DMND=""
if CHECKM2_DMND=$(find_checkm2_dmnd "$CHECKM2_DB_DIR") && [[ -n "$CHECKM2_DMND" ]]; then
  log "CheckM2 DB found: $CHECKM2_DMND (skipping download)"
else
  log "CheckM2 DB not found in $CHECKM2_DB_DIR — downloading..."
  if [[ $CHECKM2_DB_REDUCED -eq 1 ]]; then
    drun --rm -u "$(id -u)":"$(id -g)" --label "$DOCKER_LABEL" -v "$CHECKM2_DB_DIR":/db "$CHECKM2_IMG" checkm2 database --download --reduced --path /db --no_write_json_db
  else
    drun --rm -u "$(id -u)":"$(id -g)" --label "$DOCKER_LABEL" -v "$CHECKM2_DB_DIR":/db "$CHECKM2_IMG" checkm2 database --download --path /db --no_write_json_db
  fi
  CHECKM2_DMND=$(find_checkm2_dmnd "$CHECKM2_DB_DIR") || { log "ERROR: CheckM2 DB download failed"; exit 1; }
  log "CheckM2 DB downloaded: $CHECKM2_DMND"
fi
# Build container-side path (relative to CHECKM2_DB_DIR mount point /db)
CHECKM2_DMND_REL="${CHECKM2_DMND#$CHECKM2_DB_DIR/}"
log "CheckM2 run..."
drun --rm -v "$STAGING":/genomes -v "$OUT_DIR":/out -v "$CHECKM2_DB_DIR":/db -u "$(id -u)":"$(id -g)" --label "$DOCKER_LABEL" "$CHECKM2_IMG" \
  checkm2 predict --threads "$THREADS" --input /genomes --output-directory /out/04_CheckM2 \
  --database_path "/db/${CHECKM2_DMND_REL}" --force

# 5 GUNC
log "GUNC..."
mkdir -p "$OUT_DIR/05_GUNC"
drun --rm --label "$DOCKER_LABEL" -v "$STAGING":/in -v "$GUNC_DB":/gunc_db.dmnd:ro -v "$OUT_DIR":/out "$GUNC_IMG" \
  gunc run --input_dir /in --db_file /gunc_db.dmnd --threads "$THREADS" \
    --detailed_output --contig_taxonomy_output --use_species_level --out_dir /out/05_GUNC -e .fna

# 6 Dominant Genus
log "Dominant genus..."
GENUS_CONTIG_DIR="$OUT_DIR/gunc/genus_contig_ids"; mkdir -p "$GENUS_CONTIG_DIR"
GENUS_ASSIGN="$TABLE_DIR/genus_assignments.tsv"
echo -e "Genome\tGenus\tGenus_CDS\tTotal_CDS\tGenus_CDS_Percent\tNonGenus_CDS_Percent" > "$GENUS_ASSIGN"

find "$OUT_DIR/05_GUNC" -type f \( -name "*contig_assignments.tsv" -o -name "*contig_report.tsv" -o -name "aligned_contigs.contig_assignments.tsv" \) \
  2>/dev/null | sort > "$OUT_DIR/_gunc_files.list" || true

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  id=$(basename "$f")
  id=${id%.tsv}; id=${id%.contig_assignments}; id=${id%.contig_report}; id=${id//__clean/}
  genus=$(awk -F'\t' '$2=="genus"{g=$3;sub(/^[0-9]+[ ]+/,"",g);c=g;gsub(/[^A-Za-z0-9_. -]/,"",c);cnt[c]++}
    END{mx=0;best="NA";for(k in cnt)if(cnt[k]>mx){mx=cnt[k];best=k}print best}' "$f")
  GENUS_FILE="$GENUS_CONTIG_DIR/${id}_genus_contigs.txt"
  if [[ "$genus" != "NA" ]]; then
    awk -F'\t' -v g="$genus" '$2=="genus"{n=$3;sub(/^[0-9]+[ ]+/,"",n);if(n==g)print $1}' "$f" > "$GENUS_FILE"
  else
    : > "$GENUS_FILE"
  fi
  PROKKA_GFF="$OUT_DIR/02_ANNOTATION/prokka/${id}/${id}.gff"
  if [[ -s "$PROKKA_GFF" && -s "$GENUS_FILE" ]]; then
    read -r GENUS_CDS TOTAL_CDS <<<"$(
      awk -F'\t' -v CF="$GENUS_FILE" 'BEGIN{while((getline l<CF)>0){if(l!="")g[l]=1}}
        $3=="CDS"{tot++; if($1 in g)x++}
        END{if(tot==0)print "0 0"; else print x+0,tot+0}' "$PROKKA_GFF"
    )"
  else
    GENUS_CDS="NA"; TOTAL_CDS="NA"
  fi
  if [[ "$GENUS_CDS" != "NA" && "$TOTAL_CDS" != "NA" && "$TOTAL_CDS" != 0 ]]; then
    pct=$(awk -v a="$GENUS_CDS" -v t="$TOTAL_CDS" 'BEGIN{printf "%.2f",(a*100)/t}')
    pct_non=$(awk -v a="$GENUS_CDS" -v t="$TOTAL_CDS" 'BEGIN{printf "%.2f",((t-a)*100)/t}')
  else
    pct="NA"; pct_non="NA"
  fi
  echo -e "${id}\t${genus}\t${GENUS_CDS}\t${TOTAL_CDS}\t${pct}\t${pct_non}" >> "$GENUS_ASSIGN"
done < "$OUT_DIR/_gunc_files.list"

# 7 Combined Metrics & Plots
GENUS_SCRIPT="$OUT_DIR/genus_compare.py"
cat > "$GENUS_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import sys, csv, math, statistics, argparse, pathlib, re, os, bisect
from collections import defaultdict
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAVE_PLT=True
except Exception as e:
    print(f"[WARN] matplotlib not available: {e}", file=sys.stderr)
    plt=None; HAVE_PLT=False
try:
    import numpy as np
    HAVE_NUMPY=True
except Exception as e:
    print(f"[WARN] numpy not available: {e}", file=sys.stderr)
    np=None; HAVE_NUMPY=False

NUMERIC_METRICS=[
 "checkm2_completeness","checkm2_contamination",
 "checkm_completeness","checkm_contamination","checkm_marker_count",
 "checkm_strain_heterogeneity","coding_density","contig_count",
 "gc_count","gc_percentage","genome_size","mean_contig_length",
 "n50_contigs","ncbi_rrna_count","ncbi_trna_count","protein_count"
]
HIST_METRICS=[
 "checkm2_completeness","checkm2_contamination",
 "checkm_completeness","checkm_contamination",
 "genome_size","gc_percentage","n50_contigs",
 "mean_contig_length","protein_count","contig_count"
]
SYNONYMS={
 "genome_size":["genome_size","sequence_length","total_length","length","assembly_length"],
 "gc_percentage":["gc_percentage","gc_content","gc","gc_pct","percent_gc"],
 "n50_contigs":["n50_contigs","n50","assembly_n50"],
 "mean_contig_length":["mean_contig_length","avg_contig_length","mean_contig_len","avg_contig_len"],
 "protein_count":["protein_count","proteins","coding_genes","cds_count","cds"],
 "contig_count":["contig_count","num_contigs","number_of_contigs","contigs"],
 "checkm_completeness":["checkm_completeness","checkm1_completeness","cm_completeness","completeness"],
 "checkm_contamination":["checkm_contamination","checkm1_contamination","cm_contamination","contamination"],
 "checkm2_completeness":["checkm2_completeness","checkm2_complete","cm2_completeness"],
 "checkm2_contamination":["checkm2_contamination","checkm2_contam","cm2_contamination"],
 "coding_density":["coding_density","gene_density","coding_percent"],
 "ncbi_trna_count":["ncbi_trna_count","trna_count","trna"],
 "ncbi_rrna_count":["ncbi_rrna_count","rrna_count","rrna"],
 "checkm_marker_count":["checkm_marker_count","marker_count","#_markers","markers"],
 "checkm_strain_heterogeneity":["checkm_strain_heterogeneity","strain_heterogeneity","checkm_strain_het"],
 "gc_count":["gc_count","gc_bases","count_gc"]
}
def detect_delim(path):
    with open(path,'r',errors='replace') as fh:
        sample=''.join(fh.readline() for _ in range(20))
    if '\t' in sample:return '\t'
    for d in [',',';','|']:
        if d in sample:return d
    return '\t'
def extract_genus_from_tax(t):
    for c in t.split(';'):
        c=c.strip()
        if c.startswith("g__"):return c[3:].strip()
    return ""
def load_table(path):
    rows=[]
    if not os.path.exists(path): return rows,[]
    with open(path,newline='') as fh:
        r=csv.reader(fh,delimiter='\t')
        try: header=next(r)
        except StopIteration: return [],[]
        for row in r:
            if not row: continue
            if len(row)<len(header): row+=[""]*(len(header)-len(row))
            rows.append({c:row[i] for i,c in enumerate(header)})
    return rows,header
def to_float(x):
    if x is None: return None
    s=str(x).strip()
    if s=="" or s.upper()=="NA":return None
    try:return float(s)
    except:return None
def percentile(sorted_list,value):
    if not sorted_list:return None
    import bisect
    pos=bisect.bisect_left(sorted_list,value)
    return (pos/len(sorted_list))*100.0
def summarize_genus(gmap):
    out={}
    for g,rl in gmap.items():
        st={"Genus":g,"Genomes":len(rl)}
        for m in NUMERIC_METRICS:
            vals=[to_float(r.get(m)) for r in rl]
            vals=[v for v in vals if v is not None]
            if not vals:
                for suf in ("mean","median","std","min","max"):
                    st[f"{m}_{suf}"]="NA"
                continue
            import statistics
            st[f"{m}_mean"]=f"{statistics.fmean(vals):.6g}"
            st[f"{m}_median"]=f"{statistics.median(vals):.6g}"
            st[f"{m}_std"]=f"{statistics.pstdev(vals):.6g}" if len(vals)>1 else "0"
            st[f"{m}_min"]=f"{min(vals):.6g}"
            st[f"{m}_max"]=f"{max(vals):.6g}"
        out[g]=st
    return out
def load_reference(path,genus_col=None):
    if not path or not os.path.exists(path):return {}
    d=detect_delim(path)
    with open(path,'r',errors='replace') as fh:
        lines=[l.rstrip('\n') for l in fh if l.strip()]
    if not lines:return {}
    header=lines[0].split(d)
    low=[h.lower() for h in header]
    idx={low[i]:i for i in range(len(low))}
    metric_col={}
    for m in NUMERIC_METRICS:
        if m in idx: metric_col[m]=idx[m]
    for m,syns in SYNONYMS.items():
        if m in metric_col: continue
        for syn in syns:
            if syn.lower() in idx:
                metric_col[m]=idx[syn.lower()]; break
    genus_idx=None
    if genus_col:
        genus_idx=idx.get(genus_col.lower())
    tax_idx=None
    for t in ("gtdb_taxonomy","taxonomy"):
        if t in idx: tax_idx=idx[t]; break
    ref=defaultdict(lambda: defaultdict(list))
    miss=0
    import re
    for ln in lines[1:]:
        p=ln.split(d)
        genus=""
        if genus_idx is not None and genus_idx < len(p):
            genus=p[genus_idx].strip()
        if not genus and tax_idx is not None and tax_idx < len(p):
            genus=extract_genus_from_tax(p[tax_idx])
        if not genus:
            for alt in ("gtdb_genus","genus"):
                if alt in idx:
                    gi=idx[alt]
                    if gi < len(p) and p[gi].strip():
                        genus=p[gi].strip(); break
        if not genus:
            miss+=1; continue
        for metric,ci in metric_col.items():
            if ci>=len(p): continue
            raw=p[ci].strip()
            if raw=="" or raw.upper()=="NA": continue
            raw=re.sub(r'[,%]','',raw)
            try: ref[genus][metric].append(float(raw))
            except: pass
    for g in ref:
        for m in ref[g]:
            ref[g][m].sort()
    print(f"[INFO] Reference loaded genera={len(ref)} metrics={len(metric_col)} rows_without_genus={miss}", file=sys.stderr)
    return ref
def ensure_axes(ax):
    if HAVE_NUMPY and np is not None:
        return np.atleast_1d(ax).ravel()
    if isinstance(ax,(list,tuple)):
        flat=[]
        for a in ax:
            if isinstance(a,(list,tuple)): flat.extend(a)
            else: flat.append(a)
        return flat
    return [ax]
def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--genus-assign",required=True)
    ap.add_argument("--struct",required=True)
    ap.add_argument("--checkm",required=True)
    ap.add_argument("--checkm2",required=True)
    ap.add_argument("--annot",required=True)
    ap.add_argument("--tables-dir",required=True)
    ap.add_argument("--gtdb-file")
    ap.add_argument("--gtdb-genus-col")
    ap.add_argument("--verbose",action="store_true")
    args=ap.parse_args()

    tdir=pathlib.Path(args.tables_dir); tdir.mkdir(parents=True,exist_ok=True)

    ga_rows,_=load_table(args.genus_assign)
    if not ga_rows:
        print("ERROR: empty genus_assignments", file=sys.stderr); return 1
    mag_to_genus={r["Genome"]:r["Genus"] for r in ga_rows if r.get("Genome")}

    ref_gtdb={}
    if args.gtdb_file:
        ref_gtdb=load_reference(args.gtdb_file, genus_col=args.gtdb_genus_col)

    struct_rows,_=load_table(args.struct); s_by={r["Genome"]:r for r in struct_rows}
    annot_rows,_=load_table(args.annot); a_by={r["Genome"]:r for r in annot_rows}

    c1_rows,_=load_table(args.checkm); c1_by={}
    for r in c1_rows:
        bid=(r.get("Bin Id") or r.get("Bin") or r.get("Name") or "").strip()
        bid=re.sub(r"\.fna$","",bid)
        if bid: c1_by[bid]=r

    c2_path=pathlib.Path(args.checkm2)
    c2_main=None
    if c2_path.is_dir():
        for cand in ("quality_report.tsv","predict_results.tsv","quality.tsv"):
            p=c2_path/cand
            if p.exists(): c2_main=p; break
        if c2_main is None:
            tsvs=list(c2_path.glob("*.tsv"))
            if tsvs: c2_main=tsvs[0]
    else:
        c2_main=c2_path
    c2_by={}
    if c2_main and c2_main.exists():
        c2_rows,_=load_table(str(c2_main))
        for r in c2_rows:
            nm=(r.get("Name") or r.get("Genome") or r.get("Bin") or "").strip()
            nm=re.sub(r"\.fna$","",nm)
            if nm: c2_by[nm]=r
    else:
        print("[WARN] CheckM2 table not found", file=sys.stderr)

    genus_map=defaultdict(list)
    for mag,genus in mag_to_genus.items():
        s=s_by.get(mag,{})
        an=a_by.get(mag,{})
        c1=c1_by.get(mag,{})
        c2=c2_by.get(mag,{})
        rec={
          "genome_size":s.get("Size(bp)","NA"),
          "gc_percentage":s.get("GC(%)","NA"),
          "gc_count":s.get("GC_count","NA"),
          "contig_count":s.get("Contigs","NA"),
          "mean_contig_length":s.get("Mean_Contig_Len","NA"),
          "n50_contigs":s.get("N50","NA"),
          "protein_count":an.get("protein_count","NA"),
          "ncbi_trna_count":an.get("ncbi_trna_count","NA"),
          "ncbi_rrna_count":an.get("ncbi_rrna_count","NA"),
          "coding_density":an.get("coding_density","NA"),
          "checkm_completeness":c1.get("Completeness","NA"),
          "checkm_contamination":c1.get("Contamination","NA"),
          "checkm_marker_count":c1.get("# markers",c1.get("Markers","NA")),
          "checkm_strain_heterogeneity":c1.get("Strain heterogeneity","NA"),
          "checkm2_completeness":c2.get("Completeness","NA"),
          "checkm2_contamination":c2.get("Contamination","NA")
        }
        genus_map[genus].append(rec)

    genus_stats=summarize_genus(genus_map)

    per_genus_vals={g:{m:[] for m in NUMERIC_METRICS} for g in genus_map}
    for g,recs in genus_map.items():
        for r in recs:
            for m in NUMERIC_METRICS:
                v=to_float(r.get(m))
                if v is not None: per_genus_vals[g][m].append(v)
        for m in NUMERIC_METRICS:
            per_genus_vals[g][m].sort()


    basic_cols=["Genome","Genus","Size(bp)","GC_count","Contigs","GC(%)","Mean_Contig_Len",
                "N50","N90","L50","L90","CDS","tRNA","rRNA",
                "checkm_completeness","checkm_contamination","checkm_marker_count",
                "checkm_strain_heterogeneity","checkm2_completeness","checkm2_contamination"]
    full_cols=basic_cols[:]+[f"{m}_{k}" for m in NUMERIC_METRICS for k in ("value","genus_mean","genus_median","zscore","percentile")]
    combined_all=tdir/"genome_metrics_final.tsv"

    with open(combined_all,"w") as fa:
        fa.write("\t".join(full_cols)+"\n")
        for mag in sorted(mag_to_genus):
            genus=mag_to_genus[mag]
            s=s_by.get(mag,{})
            an=a_by.get(mag,{})
            c1=c1_by.get(mag,{})
            c2=c2_by.get(mag,{})
            size=s.get("Size(bp)","NA"); gc_count=s.get("GC_count","NA"); contigs=s.get("Contigs","NA")
            gc_perc=s.get("GC(%)","NA"); mean_len=s.get("Mean_Contig_Len","NA")
            N50=s.get("N50","NA"); N90=s.get("N90","NA"); L50=s.get("L50","NA"); L90=s.get("L90","NA")
            cds=an.get("protein_count","NA"); tRNA=an.get("ncbi_trna_count","NA"); rRNA=an.get("ncbi_rrna_count","NA")
            c1_comp=c1.get("Completeness","NA"); c1_cont=c1.get("Contamination","NA")
            c1_mark=c1.get("# markers",c1.get("Markers","NA"))
            c1_strain=c1.get("Strain heterogeneity","NA")
            c2_comp=c2.get("Completeness","NA"); c2_cont=c2.get("Contamination","NA")
            basic=[mag,genus,size,gc_count,contigs,gc_perc,mean_len,N50,N90,L50,L90,
                   cds,tRNA,rRNA,c1_comp,c1_cont,c1_mark,c1_strain,c2_comp,c2_cont]
            mapping={
              "genome_size":size,"gc_percentage":gc_perc,"gc_count":gc_count,"contig_count":contigs,
              "mean_contig_length":mean_len,"n50_contigs":N50,"protein_count":cds,"ncbi_trna_count":tRNA,
              "ncbi_rrna_count":rRNA,"coding_density":an.get("coding_density","NA"),
              "checkm_completeness":c1_comp,"checkm_contamination":c1_cont,"checkm_marker_count":c1_mark,
              "checkm_strain_heterogeneity":c1_strain,"checkm2_completeness":c2_comp,"checkm2_contamination":c2_cont
            }
            full=basic[:]
            for m in NUMERIC_METRICS:
                val=mapping.get(m,"NA")
                gs=genus_stats.get(genus,{})
                g_mean=gs.get(f"{m}_mean","NA")
                g_med=gs.get(f"{m}_median","NA")
                g_std=gs.get(f"{m}_std","NA")
                mv=to_float(val); stv=to_float(g_std)
                z="NA"; pct="NA"
                if mv is not None and stv is not None and stv>0 and g_mean not in ("NA",None):
                    try: z=f"{(mv-float(g_mean))/stv:.4f}"
                    except: z="NA"
                if mv is not None:
                    pval=percentile(per_genus_vals.get(genus,{}).get(m,[]),mv)
                    if pval is not None: pct=f"{pval:.2f}"
                full += [val,g_mean,g_med,z,pct]
            fa.write("\t".join(full)+"\n")


            print("[INFO] genus_compare finished.")
    return 0
if __name__=="__main__":
    sys.exit(main())
PYEOF
chmod +x "$GENUS_SCRIPT"

log "Running genus_compare..."
python3 "$GENUS_SCRIPT" \
  --genus-assign "$GENUS_ASSIGN" \
  --struct "$STRUCT" \
  --checkm "$OUT_DIR/03_CheckM1/checkm.tsv" \
  --checkm2 "$OUT_DIR/04_CheckM2" \
  --annot "$ANNOT" \
  --tables-dir "$TABLE_DIR" \
  --gtdb-file "$GENOME_GTDB_FILE" \
  --verbose || log "ERROR: genus_compare.py failed"


# 7 MAG summary plot
PLOT_SCRIPT="$OUT_DIR/mag_summary_plot.py"
cat > "$PLOT_SCRIPT" << 'PLOTEOF'
#!/usr/bin/env python3
"""
MAG summary — multi-panel quality & metrics figure.
Panels:
  A  Completeness vs Contamination scatter  (CheckM2 primary, CheckM1 fallback)
  B  Key-metrics heatmap  (MAGs × metrics, z-score normalised per column)
  C  Overall rank horizontal lollipop  (coloured by genus)
  D  Genome stats bar strip  (size / N50 / coding_density / GC%)
"""
import sys, csv, math, pathlib, argparse
from collections import defaultdict

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.gridspec as gridspec
    from matplotlib.lines import Line2D
    from matplotlib.patches import FancyBboxPatch
except ImportError as e:
    print(f"[WARN] missing dependency: {e}. Skipping plot.", file=sys.stderr)
    sys.exit(0)

# ── palette ──────────────────────────────────────────────────────────────────
PALETTE = [
    "#4C72B0","#DD8452","#55A868","#C44E52","#8172B3",
    "#937860","#DA8BC3","#8C8C8C","#CCB974","#64B5CD",
    "#1F77B4","#FF7F0E","#2CA02C","#D62728","#9467BD",
    "#8C564B","#E377C2","#7F7F7F","#BCBD22","#17BECF",
]

def genus_color_map(genera):
    uniq = sorted(set(genera))
    return {g: PALETTE[i % len(PALETTE)] for i, g in enumerate(uniq)}

def load_tsv(path):
    path = pathlib.Path(path)
    if not path.exists():
        return [], []
    with open(path, newline='', errors='replace') as fh:
        reader = csv.DictReader(fh, delimiter='\t')
        rows = list(reader)
    return rows, list(rows[0].keys()) if rows else []

def to_float(v):
    try:
        f = float(v)
        return None if math.isnan(f) else f
    except (TypeError, ValueError):
        return None

def human_bp(v):
    if v is None: return "NA"
    if v >= 1e6: return f"{v/1e6:.1f} Mb"
    if v >= 1e3: return f"{v/1e3:.0f} kb"
    return f"{v:.0f} bp"

# ── main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics",  required=True, help="genome_metrics_final.tsv")
    ap.add_argument("--out",      required=True, help="output PNG path")
    ap.add_argument("--dpi",      type=int, default=180)
    args = ap.parse_args()

    rows, _ = load_tsv(args.metrics)
    if not rows:
        print("[WARN] genome_metrics_final.tsv is empty. Skipping plot.", file=sys.stderr)
        return 0

    # ── index data ──────────────────────────────────────────────────────────
    mags       = [r["Genome"] for r in rows if r.get("Genome")]
    genera     = {r["Genome"]: r.get("Genus", "NA") for r in rows}
    gcmap      = genus_color_map(list(genera.values()))

    def col(name):
        return {r["Genome"]: to_float(r.get(name)) for r in rows if r.get("Genome")}

    # prefer CheckM2, fall back to CheckM1
    comp_col = "checkm2_completeness_value"
    cont_col = "checkm2_contamination_value"
    if all(col(comp_col).get(m) is None for m in mags):
        comp_col = "checkm_completeness_value"
        cont_col = "checkm_contamination_value"

    completeness = col(comp_col)
    contamination = col(cont_col)
    genome_size   = col("genome_size_value")
    n50           = col("n50_contigs_value")
    coding_dens   = col("coding_density_value")
    gc_perc       = col("gc_percentage_value")

    # sort score: completeness - 5*contamination (higher = better)
    rank_score = {}
    for m in mags:
        comp = completeness.get(m) or 0
        cont = contamination.get(m) or 0
        rank_score[m] = comp - 5 * cont

    # ── layout ──────────────────────────────────────────────────────────────
    n = len(mags)
    fig_h = max(10, 4 + n * 0.22)
    fig   = plt.figure(figsize=(18, fig_h), facecolor="#FAFAFA")
    gs    = gridspec.GridSpec(
        2, 2,
        figure=fig,
        left=0.07, right=0.97,
        top=0.93,  bottom=0.06,
        wspace=0.32, hspace=0.42
    )
    ax_scatter = fig.add_subplot(gs[0, 0])   # A  scatter
    ax_heat    = fig.add_subplot(gs[0, 1])   # B  heatmap
    ax_rank    = fig.add_subplot(gs[1, 0])   # C  rank lollipop
    ax_bars    = fig.add_subplot(gs[1, 1])   # D  bar strip

    # ── shared style ────────────────────────────────────────────────────────
    for ax in (ax_scatter, ax_heat, ax_rank, ax_bars):
        ax.set_facecolor("#F7F7F7")
        for spine in ax.spines.values():
            spine.set_edgecolor("#CCCCCC")
            spine.set_linewidth(0.7)

    LABEL_FS  = max(5.5, min(8.0, 72 / max(n, 12)))
    TICK_FS   = LABEL_FS - 0.5
    TITLE_FS  = 9.5
    PANEL_FS  = 11

    # ── A: Scatter completeness vs contamination ─────────────────────────────
    valid_sc = [(m, completeness[m], contamination[m]) for m in mags
                if completeness.get(m) is not None and contamination.get(m) is not None]
    if valid_sc:
        sizes = []
        for m, _, _ in valid_sc:
            gs_val = genome_size.get(m)
            sizes.append(max(20, min(350, (gs_val or 2e6) / 1e4)))
        for (m, comp, cont), sz in zip(valid_sc, sizes):
            ax_scatter.scatter(cont, comp,
                               s=sz,
                               color=gcmap[genera[m]],
                               edgecolors="#333333", linewidths=0.4,
                               alpha=0.85, zorder=3)
        # quality thresholds
        ax_scatter.axvline(5,  color="#E05555", lw=0.8, ls="--", alpha=0.6)
        ax_scatter.axhline(50, color="#4CAF50", lw=0.8, ls="--", alpha=0.6)
        ax_scatter.axhline(90, color="#2196F3", lw=0.8, ls="--", alpha=0.6)
        ax_scatter.set_xlabel("Contamination (%)", fontsize=TICK_FS)
        ax_scatter.set_ylabel("Completeness (%)", fontsize=TICK_FS)
        src_tag = "CheckM2" if "checkm2" in comp_col else "CheckM1"
        ax_scatter.set_title(f"A  Completeness vs Contamination ({src_tag})",
                             fontsize=PANEL_FS, fontweight="bold", loc="left", pad=6)
        ax_scatter.tick_params(labelsize=TICK_FS)
        ax_scatter.grid(True, linestyle=":", alpha=0.4, color="#AAAAAA")
        # genus legend (max 12)
        uniq_genera = sorted(set(genera[m] for m, *_ in valid_sc))
        handles = [Line2D([0],[0], marker='o', color='w',
                          markerfacecolor=gcmap[g], markeredgecolor="#333",
                          markersize=6, label=g)
                   for g in uniq_genera[:12]]
        ax_scatter.legend(handles=handles, fontsize=max(5, TICK_FS-1),
                          frameon=True, framealpha=0.85, edgecolor="#CCC",
                          loc="lower right", title="Genus", title_fontsize=TICK_FS)
    else:
        ax_scatter.text(0.5, 0.5, "No completeness data", ha="center", va="center",
                        transform=ax_scatter.transAxes, fontsize=10, color="#888")
        ax_scatter.set_title("A  Completeness vs Contamination", fontsize=PANEL_FS,
                             fontweight="bold", loc="left")

    # ── B: Key-metrics heatmap ────────────────────────────────────────────────
    HEAT_METRICS = [
        ("checkm2_completeness_value",    "Compl. (C2)"),
        ("checkm2_contamination_value",   "Contam. (C2)"),
        ("checkm_completeness_value",     "Compl. (C1)"),
        ("checkm_contamination_value",    "Contam. (C1)"),
        ("genome_size_value",             "Size"),
        ("gc_percentage_value",           "GC%"),
        ("n50_contigs_value",             "N50"),
        ("coding_density_value",          "Cod.Dens."),
        ("contig_count_value",            "Contigs"),
        ("protein_count_value",           "Proteins"),
    ]
    # sort MAGs by overall rank score descending
    sorted_mags = sorted(mags, key=lambda m: -(rank_score.get(m) or 0))
    mat   = np.full((len(sorted_mags), len(HEAT_METRICS)), np.nan)
    for j, (c, _) in enumerate(HEAT_METRICS):
        vals = np.array([to_float(next((r.get(c) for r in rows if r["Genome"] == m), None))
                         for m in sorted_mags], dtype=float)
        finite = vals[np.isfinite(vals)]
        if finite.size < 2:
            mat[:, j] = vals
            continue
        mu, sd = np.nanmean(finite), np.nanstd(finite)
        if sd > 0:
            mat[:, j] = (vals - mu) / sd
        else:
            mat[:, j] = 0.0

    cmap_heat = plt.get_cmap("RdYlGn").copy()
    cmap_heat.set_bad("#E0E0E0")
    im = ax_heat.imshow(mat, aspect="auto", cmap=cmap_heat,
                        vmin=-2.5, vmax=2.5, interpolation="nearest")
    ax_heat.set_xticks(range(len(HEAT_METRICS)))
    ax_heat.set_xticklabels([l for _, l in HEAT_METRICS],
                             rotation=40, ha="right", fontsize=TICK_FS)
    ax_heat.set_yticks(range(len(sorted_mags)))
    short_names = [m if len(m) <= 22 else m[:20]+"…" for m in sorted_mags]
    ax_heat.set_yticklabels(short_names, fontsize=LABEL_FS)
    # colour ytick labels by genus
    for ytl, m in zip(ax_heat.get_yticklabels(), sorted_mags):
        ytl.set_color(gcmap[genera.get(m, "NA")])
    ax_heat.set_title("B  Quality Metrics Heatmap  (z-score per column)",
                      fontsize=PANEL_FS, fontweight="bold", loc="left", pad=6)
    fig.colorbar(im, ax=ax_heat, shrink=0.6, pad=0.02,
                 label="z-score").ax.tick_params(labelsize=TICK_FS-1)

    # ── C: Overall rank lollipop ──────────────────────────────────────────────
    rank_mags = [m for m in sorted_mags if rank_score.get(m) is not None]
    rank_vals = [rank_score[m] for m in rank_mags]
    y = np.arange(len(rank_mags))
    base = 0
    for yi, v in zip(y, rank_vals):
        ax_rank.plot([base, v], [yi, yi], color="#BBBBBB", lw=1.0, zorder=1)
    ax_rank.scatter(rank_vals, y,
                    c=[gcmap[genera[m]] for m in rank_mags],
                    edgecolors="#333", linewidths=0.4, s=40, zorder=3)
    ax_rank.set_yticks(y)
    ax_rank.set_yticklabels([m if len(m) <= 22 else m[:20]+"…" for m in rank_mags],
                             fontsize=LABEL_FS)
    for ytl, m in zip(ax_rank.get_yticklabels(), rank_mags):
        ytl.set_color(gcmap[genera.get(m, "NA")])
    ax_rank.invert_yaxis()
    ax_rank.set_xlabel("Quality Score  (higher = better)", fontsize=TICK_FS)
    ax_rank.set_title("C  Quality Score  (Completeness − 5×Contamination)", fontsize=PANEL_FS,
                      fontweight="bold", loc="left", pad=6)
    ax_rank.tick_params(labelsize=TICK_FS)
    ax_rank.grid(axis="x", linestyle=":", alpha=0.4, color="#AAAAAA")
    ax_rank.set_xlim(-0.05, 1.05)

    # ── D: Genome stats horizontal bars ──────────────────────────────────────
    # 4 sub-columns: size, N50, coding_density, GC%
    BAR_METRICS = [
        ("genome_size_value",    "Size",         "#4C72B0", lambda v: v/1e6),
        ("n50_contigs_value",    "N50 (kb)",     "#55A868", lambda v: v/1e3),
        ("coding_density_value", "Cod.Dens.(%)", "#DD8452", lambda v: v),
        ("gc_percentage_value",  "GC (%)",       "#C44E52", lambda v: v),
    ]
    n_sub = len(BAR_METRICS)
    bar_mags = sorted_mags
    y = np.arange(len(bar_mags))
    h = 0.18
    offsets = np.linspace(-(n_sub-1)*h/2, (n_sub-1)*h/2, n_sub)
    vmax_cache = {}
    for j, (col_name, label, color, scale) in enumerate(BAR_METRICS):
        vals = []
        for m in bar_mags:
            raw = to_float(next((r.get(col_name) for r in rows if r["Genome"] == m), None))
            vals.append(scale(raw) if raw is not None else 0.0)
        vmax = max(vals) if vals else 1
        vmax_cache[col_name] = vmax
        norm_vals = [v / vmax if vmax > 0 else 0 for v in vals]
        ax_bars.barh(y + offsets[j], norm_vals, height=h,
                     color=color, alpha=0.75, label=label, edgecolor="none")

    ax_bars.set_yticks(y)
    ax_bars.set_yticklabels([m if len(m) <= 22 else m[:20]+"…" for m in bar_mags],
                             fontsize=LABEL_FS)
    for ytl, m in zip(ax_bars.get_yticklabels(), bar_mags):
        ytl.set_color(gcmap[genera.get(m, "NA")])
    ax_bars.invert_yaxis()
    ax_bars.set_xlabel("Normalised value  (relative to max in dataset)", fontsize=TICK_FS)
    ax_bars.set_title("D  Genome Statistics", fontsize=PANEL_FS,
                      fontweight="bold", loc="left", pad=6)
    ax_bars.tick_params(labelsize=TICK_FS)
    ax_bars.set_xlim(0, 1.12)
    ax_bars.legend(fontsize=max(5, TICK_FS-1), frameon=True, framealpha=0.85,
                   edgecolor="#CCC", loc="lower right")
    ax_bars.grid(axis="x", linestyle=":", alpha=0.4, color="#AAAAAA")

    # ── title & save ─────────────────────────────────────────────────────────
    n_hq = sum(1 for m in mags
               if (completeness.get(m) or 0) >= 90 and (contamination.get(m) or 100) <= 5)
    n_mq = sum(1 for m in mags
               if (completeness.get(m) or 0) >= 50 and (contamination.get(m) or 100) <= 10
               and not ((completeness.get(m) or 0) >= 90 and (contamination.get(m) or 100) <= 5))
    fig.suptitle(
        f"MAG Quality Summary  ·  {n} genomes  ·  "
        f"HQ ≥90%/≤5%: {n_hq}  ·  MQ ≥50%/≤10%: {n_mq}",
        fontsize=13, fontweight="bold", color="#222222", y=0.975
    )

    out_path = pathlib.Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=args.dpi, bbox_inches="tight", facecolor=fig.get_facecolor())
    svg_path = out_path.with_suffix(".svg")
    fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"[INFO] Plot saved: {out_path}", file=sys.stderr)
    print(f"[INFO] Plot saved: {svg_path}", file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())
PLOTEOF
chmod +x "$PLOT_SCRIPT"
log "Generating MAG summary plot..."
PLOT_OUT="$OUT_DIR/06_TABLES/MAG_summary_plot.png"
python3 "$PLOT_SCRIPT" \
  --metrics "$TABLE_DIR/genome_metrics_final.tsv" \
  --out     "$PLOT_OUT" \
  --dpi     180 && log "Plot saved: $PLOT_OUT" || log "WARN: plot generation failed (matplotlib/numpy missing?)"


# 8 Summary
# ── Cleanup intermediate files ─────────────────────────────────────────────
cleanup_intermediates() {
  if [[ $CLEANUP -eq 0 ]]; then
    log "Cleanup skipped (-K flag)."
    return
  fi
  log "Cleaning up intermediate files..."
  [[ -d "$STAGING" ]] && rm -rf "$STAGING" && log "  removed: staging/"
  for f in "${GENUS_SCRIPT:-}" "${PLOT_SCRIPT:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
  rm -f "$OUT_DIR/_gunc_files.list" 2>/dev/null || true
  log "Cleanup done."
}
cleanup_intermediates
log "Done."
echo "Tables: $TABLE_DIR"
echo "  Structural:      $STRUCT"
echo "  Annotation:      $ANNOT"
echo "  Genus assign:    $GENUS_ASSIGN"
echo "  Genome metrics:  $TABLE_DIR/genome_metrics_final.tsv"
echo "  Summary plot:    $TABLE_DIR/MAG_summary_plot.png"
echo "Pipeline finished."
