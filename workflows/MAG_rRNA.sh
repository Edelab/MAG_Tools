#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# MAG_rRNA.sh
#
# Reference-anchored MAG recovery using 16S rRNA as taxonomic seed.
#
# MODES:
#   auto   barrnap → BLAST 16S → NCBI download → minimap2 → bins → QC
#   -T     user reference genome (single FASTA)  → minimap2 → bins → QC
#   -M     user reference folder (many FASTAs)   → minimap2 → bins → QC
#
# STEPS (auto mode):
#   1  barrnap       predict 16S rRNA genes in each assembly
#   2  BLAST         match 16S against rRNADB → accessions
#   3  NCBI datasets download reference genome(s)
#   4  minimap2      align assembly contigs to reference (asm5)
#   5  bedtools      merge aligned intervals
#   6  seqkit        extract aligned contigs
#   7  GUNC          identify dominant genus of extracted contigs
#   8  seqkit        pull genus-matched contigs → bin FASTA
#   9  CheckM2       completeness / contamination of bins
#   10 Summary       TSV coverage + QC report
#
# Steps 3–10 are shared with -T / -M modes (skip steps 1–3).
###############################################################################

if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: bash >= 4 required." >&2; exit 1
fi

# ── Container images ──────────────────────────────────────────────────────────
BARRNAP_IMG="quay.io/biocontainers/barrnap:0.9--hdfd78af_4"
BLAST_IMG="quay.io/biocontainers/blast:2.16.0--h6f7f691_0"
MINIMAP2_IMG="quay.io/biocontainers/minimap2:2.30--h577a1d6_0"
BEDTOOLS_IMG="quay.io/biocontainers/bedtools:2.31.0--hf5e1c6e_3"
SEQKIT_IMG="quay.io/biocontainers/seqkit:2.6.1--h9ee0642_0"
GUNC_IMG="quay.io/biocontainers/gunc:1.0.6--pyhdfd78af_0"
CHECKM2_IMG="quay.io/biocontainers/checkm2:1.1.0--pyh7e72e81_1"
NGD_IMG="quay.io/biocontainers/ncbi-genome-download:0.3.3--pyh7cba7a3_0"

# ── Signal handling ───────────────────────────────────────────────────────────
SCRIPT_PID=$$
DOCKER_LABEL="mag_rrna_run=$(date +%Y%m%d%H%M%S)"
CURRENT_DOCKER_PID=""

drun() {
  (( ${STOP_REQUESTED:-0} )) && return 1
  docker run "$@" &
  CURRENT_DOCKER_PID=$!
  wait "$CURRENT_DOCKER_PID"
  local rc=$?; CURRENT_DOCKER_PID=""; return $rc
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
    echo "" >&2; echo "[SIGNAL] Interrupt — stopping. Press again to force-kill." >&2
    STOP_REQUESTED=1; nuke_everything
  else
    echo "" >&2; echo "[SIGNAL] Force-kill." >&2
    nuke_everything; kill -KILL -- "-${SCRIPT_PID}" 2>/dev/null || true; exit 130
  fi
}
on_tstp() {
  echo "" >&2; echo "[SIGNAL] Ctrl+Z — aborting." >&2
  STOP_REQUESTED=1; nuke_everything; kill -KILL -- "-${SCRIPT_PID}" 2>/dev/null || true; exit 130
}
trap on_interrupt INT TERM
trap on_tstp    TSTP

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[$(date +'%H:%M:%S')] $*" >&2; }

# ── Defaults ─────────────────────────────────────────────────────────────────
ASSEMBLY_DIR=""
ASSEMBLY_FILE=""
THREADS=1
OUTDIR=""
TARGET_GENOME=""        # -T single reference FASTA
TARGET_GENOME_DIR=""    # -M directory of reference FASTAs
GUNC_DB=""
RRNA_DB=""              # rRNADB FASTA (auto-discovered)
CHECKM2_DB_DIR=""
CHECKM2_DB_REDUCED=0
BLAST_PIDENT=90         # minimum % identity for BLAST hit
BLAST_EVALUE="1e-5"
MIN_CONTIG_LEN=500      # discard contigs shorter than this after extraction
MAX_REFS=10             # max reference genomes to download per assembly
SKIP_CHECKM2=0

# ── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  local R='\033[0m' B='\033[1m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
  printf "\n${B}╔══════════════════════════════════════════════════════════════╗${R}\n"
  printf "${B}║          MAG_rRNA — rRNA-anchored reference MAG recovery      ║${R}\n"
  printf "${B}╚══════════════════════════════════════════════════════════════╝${R}\n\n"

  printf "${B}USAGE${R}\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_rRNA${R} ${Y}-d${R} <assembly_dir> ${Y}-t${R} <threads> ${Y}-o${R} <out_dir>  [options]\n\n"

  printf "${B}INPUT (one required)${R}\n"
  printf "  ${Y}-d${R}  Directory with assembly FASTAs  (.fa .fna .fasta)\n"
  printf "  ${Y}-f${R}  Single assembly FASTA file\n\n"

  printf "${B}REQUIRED${R}\n"
  printf "  ${Y}-t${R}  Number of threads\n"
  printf "  ${Y}-o${R}  Output directory\n\n"

  printf "${B}REFERENCE MODES  (choose one or combine)${R}\n"
  printf "  ${G}[auto]${R}  No flag needed. Uses barrnap → BLAST → NCBI download.\n"
  printf "          Requires rRNADB at database/rRNAs/rRNAs.fasta (auto-discovered).\n"
  printf "  ${Y}-T${R}   Single reference genome FASTA provided by user.\n"
  printf "          Skips barrnap/BLAST/download; goes straight to alignment.\n"
  printf "  ${Y}-M${R}   Directory of reference FASTAs (one file = one reference organism).\n"
  printf "          Runs one independent alignment+binning per reference.\n\n"
  printf "  Note: -T/-M can be combined with auto mode (all references processed).\n\n"

  printf "${B}DATABASES  (auto-discovered from script dir if omitted)${R}\n"
  printf "  ${Y}-g${R}   GUNC database file  (.dmnd)\n"
  printf "  ${Y}-r${R}   rRNA FASTA database for BLAST  (auto mode only)\n"
  printf "  ${Y}-c${R}   CheckM2 database directory\n"
  printf "  ${Y}-R${R}   Use reduced CheckM2 database\n\n"

  printf "${B}FILTERS${R}\n"
  printf "  ${Y}-p${R}   BLAST minimum %% identity  [${C}$BLAST_PIDENT${R}]  (lower for environmental seqs)\n"
  printf "  ${Y}-l${R}   Minimum contig length to keep after extraction  [${C}$MIN_CONTIG_LEN${R}]\n"
  printf "  ${Y}-n${R}   Max reference genomes to download per assembly  [${C}$MAX_REFS${R}]\n"
  printf "  ${Y}-Q${R}   Skip CheckM2 (faster, no completeness estimate)\n\n"

  printf "${B}RUNTIME${R}\n"
  printf "  ${Y}-v${R}   Verbose\n"
  printf "  ${Y}-h${R}   Show this help\n\n"

  printf "${B}PIPELINE STEPS${R}\n"
  printf "  ${G}[1]${R}  ${B}barrnap${R}    Predict 16S rRNA genes  (auto mode)\n"
  printf "  ${G}[2]${R}  ${B}BLAST${R}      Match 16S vs rRNA DB → NCBI accessions  (auto mode)\n"
  printf "  ${G}[3]${R}  ${B}Download${R}   Fetch reference genome(s) from NCBI  (auto mode)\n"
  printf "  ${G}[4]${R}  ${B}minimap2${R}   Align assembly contigs to reference  (asm5)\n"
  printf "  ${G}[5]${R}  ${B}bedtools${R}   Merge aligned intervals\n"
  printf "  ${G}[6]${R}  ${B}seqkit${R}     Extract aligned contigs  (length filter: -l)\n"
  printf "  ${G}[7]${R}  ${B}GUNC${R}       Identify dominant genus of extracted contigs\n"
  printf "  ${G}[8]${R}  ${B}seqkit${R}     Pull genus-matched contigs → bin FASTA\n"
  printf "  ${G}[9]${R}  ${B}CheckM2${R}    Completeness / contamination of recovered bins\n"
  printf "  ${G}[10]${R} ${B}Summary${R}    Coverage + QC TSV\n\n"

  printf "${B}OUTPUT STRUCTURE${R}\n"
  printf "  <out_dir>/\n"
  printf "  ├── results/\n"
  printf "  │   ├── <genus>_<sample>_bin<id>.fasta   recovered bin FASTAs\n"
  printf "  │   ├── bin_coverage_summary.tsv\n"
  printf "  │   └── checkm2/                         CheckM2 quality report\n"
  printf "  └── <sample>/\n"
  printf "      ├── step1_barrnap/    rRNA.fasta + rRNA.gff\n"
  printf "      ├── step2_blast/      blast.out + blast_filtered.out\n"
  printf "      ├── step3_ids/        ncbi_ids.txt\n"
  printf "      ├── step4_refs/       reference FASTA(s)\n"
  printf "      ├── step5_alignments/<ref>/\n"
  printf "      │   ├── alignment.paf\n"
  printf "      │   ├── aligned_contigs.fasta\n"
  printf "      │   └── gunc_output/\n"
  printf "      └── step6_bins/<bin_name>/\n\n"

  printf "${B}EXAMPLES${R}\n"
  printf "  # Auto mode (barrnap + BLAST + NCBI download):\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_rRNA -d ./assemblies -t 16 -o ./out${R}\n\n"
  printf "  # User-provided single reference:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_rRNA -d ./assemblies -t 16 -o ./out -T ./E_coli.fna${R}\n\n"
  printf "  # Multiple reference genomes:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_rRNA -d ./assemblies -t 16 -o ./out -M ./ref_genomes/${R}\n\n"
  printf "  # Auto + user references combined:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_rRNA -d ./assemblies -t 16 -o ./out -M ./refs/ -p 95${R}\n\n"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while getopts "d:f:t:o:T:M:g:r:c:Rp:l:n:Qvh" opt; do
  case $opt in
    d) ASSEMBLY_DIR="$OPTARG" ;;
    f) ASSEMBLY_FILE="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    T) TARGET_GENOME="$OPTARG" ;;
    M) TARGET_GENOME_DIR="$OPTARG" ;;
    g) GUNC_DB="$OPTARG" ;;
    r) RRNA_DB="$OPTARG" ;;
    c) CHECKM2_DB_DIR="$OPTARG" ;;
    R) CHECKM2_DB_REDUCED=1 ;;
    p) BLAST_PIDENT="$OPTARG" ;;
    l) MIN_CONTIG_LEN="$OPTARG" ;;
    n) MAX_REFS="$OPTARG" ;;
    Q) SKIP_CHECKM2=1 ;;
    v) VERBOSE=1 ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Validate required args ────────────────────────────────────────────────────
if [[ -z "${THREADS:-}" || -z "${OUTDIR:-}" ]]; then
  echo "ERROR: -t and -o are required." >&2; show_help; exit 1
fi
if [[ -z "${ASSEMBLY_DIR:-}" && -z "${ASSEMBLY_FILE:-}" ]]; then
  echo "ERROR: provide -d <dir> or -f <file>." >&2; show_help; exit 1
fi
if [[ -n "${ASSEMBLY_DIR:-}" && -n "${ASSEMBLY_FILE:-}" ]]; then
  echo "ERROR: use only one of -d or -f." >&2; exit 1
fi

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ASSEMBLY_DIR:-}" ]] && ASSEMBLY_DIR=$(realpath "$ASSEMBLY_DIR")
[[ -n "${ASSEMBLY_FILE:-}" ]] && ASSEMBLY_FILE=$(realpath "$ASSEMBLY_FILE")
[[ -n "${TARGET_GENOME:-}" ]] && TARGET_GENOME=$(realpath "$TARGET_GENOME")
[[ -n "${TARGET_GENOME_DIR:-}" ]] && TARGET_GENOME_DIR=$(realpath "$TARGET_GENOME_DIR")
OUTDIR=$(realpath "$OUTDIR")
mkdir -p "$OUTDIR/results"

# ── Determine mode ────────────────────────────────────────────────────────────
AUTO_MODE=1
[[ -n "${TARGET_GENOME:-}" || -n "${TARGET_GENOME_DIR:-}" ]] && AUTO_MODE=0
# If neither -T nor -M, auto mode is on
[[ -z "${TARGET_GENOME:-}" && -z "${TARGET_GENOME_DIR:-}" ]] && AUTO_MODE=1

# ── Auto-discover databases ───────────────────────────────────────────────────
_discover() {
  # _discover <var_name> <description> <candidate paths...>
  local varname="$1" desc="$2"; shift 2
  local val="${!varname:-}"
  if [[ -z "$val" ]]; then
    for cand in "$@"; do
      cand=$(realpath -m "$cand")
      if [[ -f "$cand" ]]; then
        printf -v "$varname" '%s' "$cand"
        log "${desc} auto-discovered: $cand"; return 0
      fi
    done
    return 1
  fi
  return 0
}

_discover_dir() {
  local varname="$1" desc="$2"; shift 2
  local val="${!varname:-}"
  if [[ -z "$val" ]]; then
    for cand in "$@"; do
      cand=$(realpath -m "$cand")
      if find "$cand" -maxdepth 2 -name "uniref100.KO.1.dmnd" 2>/dev/null | grep -q .; then
        printf -v "$varname" '%s' "$cand"
        log "${desc} auto-discovered: $cand"; return 0
      fi
    done
    return 1
  fi
  return 0
}

# GUNC DB
_discover GUNC_DB "GUNC DB" \
  "$SCRIPT_DIR/../database/GUNC/gunc_db_progenomes2.1.dmnd" \
  "$SCRIPT_DIR/../database/GUNC/gunc_db.dmnd" \
  "$SCRIPT_DIR/database/GUNC/gunc_db.dmnd" \
  || { echo "ERROR: GUNC database not found. Use -g." >&2; exit 1; }
GUNC_DB=$(realpath "$GUNC_DB")

# rRNA DB (only needed in auto mode)
if [[ $AUTO_MODE -eq 1 ]]; then
  _discover RRNA_DB "rRNA FASTA" \
    "$SCRIPT_DIR/../database/rRNAs/rRNAs.fasta" \
    "$SCRIPT_DIR/database/rRNAs/rRNAs.fasta" \
    || { echo "ERROR: rRNAs.fasta not found. Use -r or provide -T/-M to skip auto mode." >&2; exit 1; }
  RRNA_DB=$(realpath "$RRNA_DB")
  RRNA_DIR=$(dirname "$RRNA_DB")
fi

# CheckM2 DB
if [[ $SKIP_CHECKM2 -eq 0 ]]; then
  _discover_dir CHECKM2_DB_DIR "CheckM2 DB" \
    "$SCRIPT_DIR/../database/CheckM2_database" \
    "$SCRIPT_DIR/../database/checkm2_db" \
    "$SCRIPT_DIR/../database" \
    || { CHECKM2_DB_DIR="$OUTDIR/checkm2_db"; log "CheckM2 DB not found — will download to $CHECKM2_DB_DIR"; }
  CHECKM2_DB_DIR=$(realpath -m "$CHECKM2_DB_DIR")
  mkdir -p "$CHECKM2_DB_DIR"
fi

log "Mode: $([ $AUTO_MODE -eq 1 ] && echo 'auto (barrnap+BLAST+NCBI)' || echo 'reference-provided')"
[[ -n "${TARGET_GENOME:-}"     ]] && log "Single reference: $TARGET_GENOME"
[[ -n "${TARGET_GENOME_DIR:-}" ]] && log "Reference dir:    $TARGET_GENOME_DIR"

# ── Build rRNA BLAST DB if needed ─────────────────────────────────────────────
if [[ $AUTO_MODE -eq 1 ]]; then
  if [[ ! -f "${RRNA_DIR}/rRNADB.nhr" ]]; then
    log "Building BLAST database from rRNAs.fasta..."
    drun --rm --label "$DOCKER_LABEL" \
      -v "$RRNA_DIR":/db "$BLAST_IMG" \
      makeblastdb -in /db/$(basename "$RRNA_DB") -dbtype nucl -out /db/rRNADB
    log "BLAST DB ready."
  else
    log "BLAST DB already present."
  fi
fi

# ── Collect assembly list ─────────────────────────────────────────────────────
declare -a ASSEMBLIES
if [[ -n "${ASSEMBLY_FILE:-}" ]]; then
  ASSEMBLIES=("$ASSEMBLY_FILE")
else
  mapfile -t ASSEMBLIES < <(find "$ASSEMBLY_DIR" -maxdepth 1 -type f \
    \( -iname "*.fa" -o -iname "*.fna" -o -iname "*.fasta" \) | sort)
fi
[[ ${#ASSEMBLIES[@]} -eq 0 ]] && { echo "ERROR: no FASTA assemblies found." >&2; exit 1; }
log "Assemblies to process: ${#ASSEMBLIES[@]}"

# ── Coverage summary header ───────────────────────────────────────────────────
SUMMARY_TSV="$OUTDIR/results/bin_coverage_summary.tsv"
echo -e "bin\tsample\treference\tbin_size_bp\tref_covered_bp\trecovery_pct\tcontigs\tdominant_genus" \
  > "$SUMMARY_TSV"

###############################################################################
# FUNCTION: align_and_bin
#   $1 = assembly FASTA (full path)
#   $2 = reference FASTA (full path)
#   $3 = sample name
#   $4 = reference label (used for directory naming)
#   $5 = sample output dir
###############################################################################
align_and_bin() {
  local assembly="$1" ref_fasta="$2" sample="$3" ref_label="$4" sample_out="$5"
  local aln_dir="$sample_out/step5_alignments/$ref_label"
  mkdir -p "$aln_dir"

  # ── Step 4: minimap2 alignment ──────────────────────────────────────────────
  log "  [4] minimap2: $sample vs $ref_label"
  drun --rm --label "$DOCKER_LABEL" \
    -v "$(dirname "$assembly")":/q \
    -v "$(dirname "$ref_fasta")":/ref \
    -v "$aln_dir":/aln \
    "$MINIMAP2_IMG" \
    minimap2 -x asm5 -k 28 -N 1 -t "$THREADS" \
      /ref/$(basename "$ref_fasta") \
      /q/$(basename "$assembly") \
    > "$aln_dir/alignment.paf" 2>/dev/null || true

  if [[ ! -s "$aln_dir/alignment.paf" ]]; then
    log "  WARN: no alignment for $ref_label — skipping."; return
  fi

  # ── Step 5: bedtools merge ──────────────────────────────────────────────────
  awk '{print $6"\t"$8"\t"$9}' "$aln_dir/alignment.paf" > "$aln_dir/tmp.bed"
  drun --rm --label "$DOCKER_LABEL" \
    -v "$aln_dir":/work "$BEDTOOLS_IMG" \
    bash -c "bedtools sort -i /work/tmp.bed | bedtools merge > /work/merged.bed" || true

  # ── Step 6: seqkit — extract aligned contigs ───────────────────────────────
  log "  [6] seqkit: extracting aligned contigs"
  awk '{print $1}' "$aln_dir/alignment.paf" | sort -u > "$aln_dir/aligned_ids.txt"
  drun --rm --label "$DOCKER_LABEL" \
    -v "$(dirname "$assembly")":/asm \
    -v "$aln_dir":/aln \
    "$SEQKIT_IMG" \
    seqkit grep -f /aln/aligned_ids.txt /asm/$(basename "$assembly") \
    > "$aln_dir/aligned_contigs.fasta" 2>/dev/null || true

  # Filter by min contig length
  if [[ -s "$aln_dir/aligned_contigs.fasta" && $MIN_CONTIG_LEN -gt 0 ]]; then
    drun --rm --label "$DOCKER_LABEL" \
      -v "$aln_dir":/aln "$SEQKIT_IMG" \
      seqkit seq -m "$MIN_CONTIG_LEN" /aln/aligned_contigs.fasta \
      > "$aln_dir/aligned_contigs_filtered.fasta" 2>/dev/null || true
    [[ -s "$aln_dir/aligned_contigs_filtered.fasta" ]] && \
      mv "$aln_dir/aligned_contigs_filtered.fasta" "$aln_dir/aligned_contigs.fasta"
  fi

  if [[ ! -s "$aln_dir/aligned_contigs.fasta" ]] || \
     [[ $(grep -c '^>' "$aln_dir/aligned_contigs.fasta") -eq 0 ]]; then
    log "  WARN: no contigs extracted for $ref_label — skipping."; return
  fi

  N_CONTIGS=$(grep -c '^>' "$aln_dir/aligned_contigs.fasta")
  log "  Extracted contigs: $N_CONTIGS"

  # ── Step 7: GUNC — dominant genus ──────────────────────────────────────────
  log "  [7] GUNC: identifying dominant genus"
  mkdir -p "$aln_dir/gunc_output"
  drun --rm --label "$DOCKER_LABEL" \
    -v "$aln_dir":/data \
    -v "$GUNC_DB":/gunc_db.dmnd:ro \
    "$GUNC_IMG" \
    gunc run -r /gunc_db.dmnd \
      -i /data/aligned_contigs.fasta \
      -t "$THREADS" \
      --detailed_output --contig_taxonomy_output --use_species_level \
      -o /data/gunc_output 2>/dev/null || true

  # GUNC plot
  local diamond_dir="$aln_dir/gunc_output/diamond_output"
  if compgen -G "$diamond_dir/*.out" > /dev/null 2>&1; then
    local dout; dout=$(ls "$diamond_dir"/*.out | head -n1)
    drun --rm --label "$DOCKER_LABEL" \
      -v "$aln_dir":/data "$GUNC_IMG" \
      gunc plot \
        -d /data/gunc_output/diamond_output/$(basename "$dout") \
        -o /data/gunc_output 2>/dev/null || true
  fi

  local assign_file="$aln_dir/gunc_output/gunc_output/aligned_contigs.contig_assignments.tsv"
  if [[ ! -f "$assign_file" ]]; then
    log "  WARN: GUNC contig_assignments not found — skipping genus binning."; return
  fi

  local genus
  genus=$(awk -F'\t' '
    $2=="genus" { g=$3; sub(/^[0-9]+ /,"",g); gsub(/[^A-Za-z0-9_. -]/,"",g); c[g]+=$4 }
    END { for(g in c) if(c[g]>mx){mx=c[g];top=g} print top }
  ' "$assign_file")

  if [[ -z "$genus" || "$genus" == "NA" ]]; then
    log "  WARN: GUNC could not determine dominant genus — skipping."; return
  fi
  log "  Dominant genus: $genus"

  # ── Step 8: seqkit — pull genus-matched contigs → bin ──────────────────────
  log "  [8] Building bin for genus: $genus"
  awk -F'\t' -v g="$genus" '
    $2=="genus" { n=$3; sub(/^[0-9]+ /,"",n); if(n==g) print $1 }
  ' "$assign_file" > "$aln_dir/gunc_output/genus_ids.txt"

  local genus_safe="${genus// /_}"
  local bin_id=$(( RANDOM % 1000000 ))
  local bin_name="${genus_safe}_${sample}_bin${bin_id}"
  local bin_fasta="$OUTDIR/results/${bin_name}.fasta"

  drun --rm --label "$DOCKER_LABEL" \
    -v "$aln_dir/gunc_output":/ids \
    -v "$aln_dir":/aln \
    -v "$OUTDIR/results":/out \
    "$SEQKIT_IMG" \
    seqkit grep -f /ids/genus_ids.txt /aln/aligned_contigs.fasta \
    > "$bin_fasta" 2>/dev/null || true

  if [[ ! -s "$bin_fasta" ]] || [[ $(grep -c '^>' "$bin_fasta") -eq 0 ]]; then
    log "  WARN: bin FASTA empty after genus filter — skipping."; return
  fi

  # Register bin for CheckM2 (copy to staging)
  cp "$bin_fasta" "$OUTDIR/results/checkm2_input/$(basename "$bin_fasta")"

  # ── Coverage stats ──────────────────────────────────────────────────────────
  local bin_dir="$sample_out/step6_bins/$bin_name"
  mkdir -p "$bin_dir"

  drun --rm --label "$DOCKER_LABEL" \
    -v "$bin_dir":/bdir \
    -v "$(dirname "$ref_fasta")":/ref \
    -v "$OUTDIR/results":/out \
    "$MINIMAP2_IMG" \
    minimap2 -x asm5 -t "$THREADS" \
      /ref/$(basename "$ref_fasta") \
      /out/$(basename "$bin_fasta") \
    > "$bin_dir/bin_vs_ref.paf" 2>/dev/null || true

  local bin_covered=0
  if [[ -s "$bin_dir/bin_vs_ref.paf" ]]; then
    awk '{print $6"\t"$8"\t"$9}' "$bin_dir/bin_vs_ref.paf" > "$bin_dir/tmp.bed"
    drun --rm --label "$DOCKER_LABEL" \
      -v "$bin_dir":/bdir "$BEDTOOLS_IMG" \
      bash -c "bedtools sort -i /bdir/tmp.bed | bedtools merge > /bdir/merged.bed" || true
    [[ -s "$bin_dir/merged.bed" ]] && \
      bin_covered=$(awk '{s+=$3-$2} END{print s+0}' "$bin_dir/merged.bed")
  fi

  local bin_size n_contigs recovery
  bin_size=$(grep -v '^>' "$bin_fasta" | tr -d '\n\r ' | wc -c)
  n_contigs=$(grep -c '^>' "$bin_fasta")
  recovery=$(awk -v a="$bin_covered" -v b="$bin_size" \
    'BEGIN{printf "%.2f",(b>0?(a/b)*100:0)}')

  echo -e "${bin_name}\t${sample}\t${ref_label}\t${bin_size}\t${bin_covered}\t${recovery}\t${n_contigs}\t${genus}" \
    >> "$SUMMARY_TSV"

  log "  Bin: $bin_name | size=${bin_size}bp | covered=${bin_covered}bp | recovery=${recovery}% | contigs=${n_contigs}"
}

###############################################################################
# MAIN LOOP — iterate over each assembly
###############################################################################
mkdir -p "$OUTDIR/results/checkm2_input"

TOTAL=${#ASSEMBLIES[@]}
IDX=0
for ASSEMBLY in "${ASSEMBLIES[@]}"; do
  [[ -f "$ASSEMBLY" ]] || continue
  IDX=$((IDX+1))
  sample=$(basename "$ASSEMBLY" | sed 's/\..*//')
  sample_out="$OUTDIR/$sample"
  mkdir -p "$sample_out"

  log "[$IDX/$TOTAL] Processing: $sample"

  # ── Collect reference FASTAs for this sample ─────────────────────────────
  declare -a REF_FASTAS=()

  # --- AUTO MODE: barrnap → BLAST → NCBI download -------------------------
  if [[ $AUTO_MODE -eq 1 ]]; then
    # Step 1: barrnap
    log "  [1] barrnap: predicting 16S rRNA"
    mkdir -p "$sample_out/step1_barrnap"
    drun --rm --label "$DOCKER_LABEL" \
      -v "$(dirname "$ASSEMBLY")":/in \
      -v "$sample_out/step1_barrnap":/out \
      "$BARRNAP_IMG" \
      bash -lc "barrnap --kingdom bac --threads $THREADS \
        --outseq /out/rRNA.fasta /in/$(basename "$ASSEMBLY") \
        > /out/rRNA.gff 2>/dev/null || true" || true

    if [[ ! -s "$sample_out/step1_barrnap/rRNA.fasta" ]]; then
      log "  WARN: barrnap found no rRNA in $sample — skipping auto mode."
    else
      # Keep only 16S sequences for species identification
      grep -A1 "16S" "$sample_out/step1_barrnap/rRNA.fasta" \
        | grep -v "^--$" > "$sample_out/step1_barrnap/16S_only.fasta" || true
      # Fallback: use all if no 16S found
      if [[ ! -s "$sample_out/step1_barrnap/16S_only.fasta" ]]; then
        cp "$sample_out/step1_barrnap/rRNA.fasta" "$sample_out/step1_barrnap/16S_only.fasta"
        log "  WARN: no 16S sequences found, using all rRNA for BLAST"
      fi
      N_16S=$(grep -c '^>' "$sample_out/step1_barrnap/16S_only.fasta" || true)
      N_RRNA=$(grep -c '^>' "$sample_out/step1_barrnap/rRNA.fasta" || true)
      log "  barrnap: $N_RRNA rRNA total, $N_16S 16S used for BLAST"

      # Step 2: BLAST
      log "  [2] BLAST: matching 16S against rRNA DB (pident >= $BLAST_PIDENT)"
      mkdir -p "$sample_out/step2_blast"
      drun --rm --label "$DOCKER_LABEL" \
        -v "$sample_out/step1_barrnap":/query \
        -v "$RRNA_DIR":/db \
        -v "$sample_out/step2_blast":/out \
        "$BLAST_IMG" \
        blastn -query /query/16S_only.fasta -db /db/rRNADB \
          -out /out/blast.out \
          -evalue "$BLAST_EVALUE" \
          -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qcovs" \
          -max_target_seqs 5 \
          -perc_identity "$BLAST_PIDENT" \
          -num_threads "$THREADS" 2>/dev/null || true

      # Show top hits for diagnostics
      if [[ -s "$sample_out/step2_blast/blast.out" ]]; then
        TOP_HIT=$(awk 'NR==1{printf "best hit: %s pident=%.1f%%", $2, $3}' "$sample_out/step2_blast/blast.out")
        N_HITS=$(wc -l < "$sample_out/step2_blast/blast.out")
        log "  BLAST: $N_HITS raw hits. $TOP_HIT"
      else
        log "  WARN: blast.out is empty — no matches in rRNA DB."
      fi
      awk -v pid="$BLAST_PIDENT" '$3 >= pid && ($13+0 >= 70 || NF < 13)' \
        "$sample_out/step2_blast/blast.out" \
        > "$sample_out/step2_blast/blast_filtered.out" || true

      # Step 3: get accessions + download
      mkdir -p "$sample_out/step3_ids"
      # Extract only clean GCF_/GCA_ accessions from BLAST subject IDs
      # (rRNA DB subject IDs can look like: GCA_000010305.1 or GCA000010305renamed_...)
      # Extract and normalise GCF/GCA accessions from BLAST sseqid
      # DB format:  GCF016403105_16S_rRNA::NZ_CP046155.1:...
      # Target fmt: GCF_016403105.1
      cut -f2 "$sample_out/step2_blast/blast_filtered.out" \
        | grep -Eo 'GC[FA][_]?[0-9]{9}' \
        | sed -E 's/^(GC[FA])_?([0-9]{9})$/\1_\2.1/' \
        | sort -u \
        | head -n "$MAX_REFS" > "$sample_out/step3_ids/ncbi_ids.txt" || true
      log "  Unique accessions to download: $(wc -l < "$sample_out/step3_ids/ncbi_ids.txt")"
      [[ -s "$sample_out/step3_ids/ncbi_ids.txt" ]] && \
        head -n5 "$sample_out/step3_ids/ncbi_ids.txt" | sed 's/^/    /' >&2 || true

      mkdir -p "$sample_out/step4_refs"
      if [[ -s "$sample_out/step3_ids/ncbi_ids.txt" ]]; then
        log "  [3] Downloading $(wc -l < "$sample_out/step3_ids/ncbi_ids.txt") reference(s) from NCBI"
        while IFS= read -r acc; do
          local_ref="$sample_out/step4_refs/${acc}.fna"
          # Check if already downloaded
          if [[ -s "$local_ref" ]]; then
            log "    cached: $acc"; REF_FASTAS+=("$local_ref"); continue
          fi
          log "    downloading: $acc"
          dl_dir="$sample_out/step4_refs/${acc}_dl"
          mkdir -p "$dl_dir"

          # Build NCBI FTP path from accession
          # GCA_000014005.1  →  GCA/000/014/005/
          _acc_nover="${acc%.*}"          # GCA_000014005
          _prefix="${_acc_nover:0:3}"     # GCA
          _digits="${_acc_nover##*_}"     # 000014005
          _p1="${_digits:0:3}"            # 000
          _p2="${_digits:3:3}"            # 014
          _p3="${_digits:6:3}"            # 005
          _ftp_base="https://ftp.ncbi.nlm.nih.gov/genomes/all/${_prefix}/${_p1}/${_p2}/${_p3}"

          # List directory to get full assembly name
          _asm_name=$(curl -fsSL --max-time 30 "${_ftp_base}/" 2>/dev/null \
            | grep -oP "(?<=>)${_acc_nover//./\.}[^<]+" \
            | grep -v ".gz" | head -n1 | tr -d "/" || true)

          _dl_ok=0
          if [[ -n "$_asm_name" ]]; then
            _fna_url="${_ftp_base}/${_asm_name}/${_asm_name}_genomic.fna.gz"
            if curl -fsSL --max-time 120 "$_fna_url" | gzip -cd > "$local_ref" 2>/dev/null; then
              [[ -s "$local_ref" ]] && _dl_ok=1
            fi
          fi

          # Fallback: ncbi-genome-download with --groups all
          if [[ $_dl_ok -eq 0 ]]; then
            drun --rm --label "$DOCKER_LABEL"               -u "$(id -u)":"$(id -g)"               -v "$dl_dir":/dl               "$NGD_IMG"               ncbi-genome-download all                 --assembly-accessions "$acc"                 --formats fasta                 --output-folder /dl                 --flat-output 2>/dev/null || true
            found=$(find "$dl_dir" -name "*.fna.gz" | head -n1 || true)
            if [[ -f "$found" ]]; then
              gzip -cd "$found" > "$local_ref" && _dl_ok=1
            fi
          fi

          if [[ $_dl_ok -eq 1 && -s "$local_ref" ]]; then
            REF_FASTAS+=("$local_ref")
            log "    downloaded: $acc"
          else
            rm -f "$local_ref"
            log "    WARN: download failed for $acc"
          fi
        done < "$sample_out/step3_ids/ncbi_ids.txt"
      else
        log "  WARN: no NCBI accessions found for $sample (BLAST returned no hits >= ${BLAST_PIDENT}%)."
      fi
    fi
  fi

  # --- USER-PROVIDED REFERENCES -------------------------------------------
  if [[ -n "${TARGET_GENOME:-}" ]]; then
    REF_FASTAS+=("$TARGET_GENOME")
  fi
  if [[ -n "${TARGET_GENOME_DIR:-}" ]]; then
    while IFS= read -r rf; do REF_FASTAS+=("$rf"); done < <(
      find "$TARGET_GENOME_DIR" -maxdepth 1 -type f \
        \( -iname "*.fa" -o -iname "*.fna" -o -iname "*.fasta" \) | sort
    )
  fi

  if [[ ${#REF_FASTAS[@]} -eq 0 ]]; then
    log "  No references available for $sample — skipping alignment steps."
    continue
  fi

  log "  References to align: ${#REF_FASTAS[@]}"

  # --- Steps 4-8 per reference -------------------------------------------
  for ref_fasta in "${REF_FASTAS[@]}"; do
    [[ -f "$ref_fasta" ]] || continue
    ref_label=$(basename "${ref_fasta%.*}")
    ref_label="${ref_label//./_}"
    align_and_bin "$ASSEMBLY" "$ref_fasta" "$sample" "$ref_label" "$sample_out"
  done

  log "[$IDX/$TOTAL] Done: $sample"
done

###############################################################################
# Step 9: CheckM2 on all recovered bins
###############################################################################
N_BINS=$(find "$OUTDIR/results/checkm2_input" -name "*.fasta" | wc -l | tr -d ' ')
if [[ $SKIP_CHECKM2 -eq 1 ]]; then
  log "[9] CheckM2 skipped (-Q)."
elif [[ $N_BINS -eq 0 ]]; then
  log "[9] No bins recovered — skipping CheckM2."
else
  log "[9] CheckM2: assessing $N_BINS bin(s)..."

  # CheckM2 DB discovery/download
  find_checkm2_dmnd() {
    local d="$1" f
    f="$d/uniref100.KO.1.dmnd";                  [[ -f "$f" ]] && { echo "$f"; return 0; }
    f="$d/CheckM2_database/uniref100.KO.1.dmnd"; [[ -f "$f" ]] && { echo "$f"; return 0; }
    f=$(find "$d" -maxdepth 2 -name "uniref100.KO.1.dmnd" 2>/dev/null | head -n1)
    [[ -n "$f" ]] && { echo "$f"; return 0; }; return 1
  }
  CHECKM2_DMND=""
  if ! CHECKM2_DMND=$(find_checkm2_dmnd "$CHECKM2_DB_DIR"); then
    log "CheckM2 DB not found — downloading..."
    if [[ $CHECKM2_DB_REDUCED -eq 1 ]]; then
      drun --rm --label "$DOCKER_LABEL" -u "$(id -u)":"$(id -g)" \
        -v "$CHECKM2_DB_DIR":/db "$CHECKM2_IMG" \
        checkm2 database --download --reduced --path /db --no_write_json_db
    else
      drun --rm --label "$DOCKER_LABEL" -u "$(id -u)":"$(id -g)" \
        -v "$CHECKM2_DB_DIR":/db "$CHECKM2_IMG" \
        checkm2 database --download --path /db --no_write_json_db
    fi
    CHECKM2_DMND=$(find_checkm2_dmnd "$CHECKM2_DB_DIR") \
      || { log "ERROR: CheckM2 DB download failed."; exit 1; }
  fi
  CHECKM2_DMND_REL="${CHECKM2_DMND#$CHECKM2_DB_DIR/}"

  mkdir -p "$OUTDIR/results/checkm2"
  drun --rm --label "$DOCKER_LABEL" \
    -u "$(id -u)":"$(id -g)" \
    -v "$OUTDIR/results/checkm2_input":/bins \
    -v "$OUTDIR/results/checkm2":/out \
    -v "$CHECKM2_DB_DIR":/db \
    "$CHECKM2_IMG" \
    checkm2 predict \
      --threads "$THREADS" \
      --input /bins \
      --output-directory /out \
      --database_path "/db/${CHECKM2_DMND_REL}" \
      --force 2>/dev/null \
    && log "CheckM2 done -> $OUTDIR/results/checkm2/" \
    || log "WARN: CheckM2 failed."
fi

###############################################################################
# Step 10: Summary
###############################################################################
log "[10] Summary"
N_RECOVERED=$(awk 'NR>1' "$SUMMARY_TSV" | wc -l | tr -d ' ')
echo ""
echo "══════════════════════════════════════════════"
echo "  MAG_rRNA pipeline complete"
echo "  Bins recovered : $N_RECOVERED"
echo "  Coverage table : $SUMMARY_TSV"
[[ $SKIP_CHECKM2 -eq 0 && $N_BINS -gt 0 ]] && \
  echo "  CheckM2 report : $OUTDIR/results/checkm2/"
echo "  Bin FASTAs     : $OUTDIR/results/*.fasta"
echo "══════════════════════════════════════════════"
