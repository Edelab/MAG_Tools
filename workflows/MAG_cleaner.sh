#!/usr/bin/env bash
#set -euo pipefail

# =========================
# Parameters and defaults
# =========================
MAG_DIR=""
MAG_FILE=""
READS_DIR=""
THREADS=8
OUTDIR=""
SAVE_SVG=0
PERCENT=5
METHODS="coverage"
GUNC_DB=""
KMER_SIZE=4
KMER_PERCENT=5
GC_MAD_MULT=3
COMBINE="union"
PER_METHOD_FASTAS=1
AAID_PERCENT=5

show_workflow_help() {
  local R='\033[0m' B='\033[1m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' D='\033[2m'
  printf "\n${B}╔══════════════════════════════════════════════════════════════╗${R}\n"
  printf "${B}║              MAG_cleaner — MAG Contamination Removal         ║${R}\n"
  printf "${B}╚══════════════════════════════════════════════════════════════╝${R}\n\n"

  printf "${B}USAGE${R}\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_cleaner${R} [${Y}-d${R} <mag_dir> | ${Y}-f${R} <mag_file>] ${Y}-o${R} <outdir> [options]\n\n"

  printf "${B}INPUT  (one required)${R}\n"
  printf "  ${Y}-d${R}  Directory with MAG FASTAs  (.fa .fna .fasta)\n"
  printf "  ${Y}-f${R}  Single MAG FASTA file\n\n"

  printf "${B}REQUIRED${R}\n"
  printf "  ${Y}-o${R}  Output directory\n\n"

  printf "${B}METHODS${R}  (${Y}-m${R}, comma-separated, default: ${C}coverage${R})\n"
  printf "  ${G}coverage${R}     Read-depth correlation — removes low-correlation contigs\n"
  printf "               ${D}requires -r <reads_dir>${R}\n"
  printf "  ${G}kmer${R}         k-mer composition — removes composition outlier contigs\n"
  printf "  ${G}gc${R}           GC content — removes contigs outside median ± MAD×mult\n"
  printf "  ${G}gunc${R}         GUNC taxonomy — removes contigs not matching dominant genus\n"
  printf "               ${D}requires -G <gunc_db_dir>${R}\n"
  printf "  ${G}aaid${R}         Amino acid composition — removes AA similarity outliers\n"
  printf "  ${G}all${R}          Enable all five methods\n\n"

  printf "${B}COMBINATION STRATEGY${R}  (${Y}-c${R}, default: ${C}union${R})\n"
  printf "  ${G}union${R}          Remove contigs flagged by ANY method\n"
  printf "  ${G}intersection${R}   Remove contigs flagged by ALL methods\n\n"

  printf "${B}METHOD PARAMETERS${R}\n"
  printf "  ${Y}-p${R}  %% below global mean correlation  (coverage)   [${C}$PERCENT${R}]\n"
  printf "  ${Y}-k${R}  k-mer size                                     [${C}$KMER_SIZE${R}]\n"
  printf "  ${Y}-q${R}  %% below global mean k-mer similarity          [${C}$KMER_PERCENT${R}]\n"
  printf "  ${Y}-M${R}  GC MAD (or STD fallback) multiplier            [${C}$GC_MAD_MULT${R}]\n"
  printf "  ${Y}-a${R}  %% below global mean AA similarity  (aaid)     [${C}$AAID_PERCENT${R}]\n\n"

  printf "${B}DATABASES${R}\n"
  printf "  ${Y}-G${R}  GUNC database directory  (required if gunc method selected)\n\n"

  printf "${B}RUNTIME${R}\n"
  printf "  ${Y}-r${R}  Reads directory  (required for coverage method)\n"
  printf "  ${Y}-t${R}  Threads                                        [${C}$THREADS${R}]\n"
  printf "  ${Y}-s${R}  Also save plots as SVG  (0/1)                  [${C}$SAVE_SVG${R}]\n"
  printf "  ${Y}-X${R}  Generate per-method cleaned FASTAs  (0/1)      [${C}$PER_METHOD_FASTAS${R}]\n"
  printf "  ${Y}-h${R}  Show this help\n\n"

  printf "${B}OUTPUT STRUCTURE${R}\n"
  printf "  <outdir>/\n"
  printf "  ├── cleaned/\n"
  printf "  │   ├── <mag>__clean.fasta                 final combined FASTA\n"
  printf "  │   └── by_method/<mag>__clean_<m>.fasta   per-method FASTAs  (if -X 1)\n"
  printf "  ├── matrices/\n"
  printf "  │   ├── *__coverage_report.tsv\n"
  printf "  │   ├── *__kmer_report.tsv\n"
  printf "  │   ├── *__gc_report.tsv\n"
  printf "  │   ├── *__aaid_report.tsv\n"
  printf "  │   └── *__contigs_to_remove.txt           per-method removal lists\n"
  printf "  ├── plots/\n"
  printf "  │   ├── *__corr_before_after.png\n"
  printf "  │   ├── *__kmer_mean_similarity.png\n"
  printf "  │   ├── *__gc_content.png\n"
  printf "  │   └── *__aaid_mean_similarity.png\n"
  printf "  └── summary/\n"
  printf "      ├── removal_summary.tsv\n"
  printf "      └── per_method_counts.tsv\n\n"

  printf "${B}EXAMPLES${R}\n"
  printf "  # Fast — k-mer + GC only (no reads or GUNC needed):\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_cleaner -d ./mags -o ./out -m kmer,gc${R}\n\n"
  printf "  # Coverage + k-mer + GC:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_cleaner -d ./mags -r ./reads -o ./out -m coverage,kmer,gc${R}\n\n"
  printf "  # All methods, intersection strategy:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_cleaner -d ./mags -r ./reads -o ./out -m all -G ./gunc_db -c intersection${R}\n\n"
  printf "  # Single MAG, coverage only, aggressive threshold:\n"
  printf "  ${C}bash MAG_Tools.sh -w MAG_cleaner -f ./my_mag.fna -r ./reads -o ./out -p 10${R}\n\n"
}

# =========================
# Parse arguments
# =========================
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    show_workflow_help
    exit 0
  fi
done

while getopts "d:f:o:r:t:s:p:m:G:k:q:M:a:c:X:h" opt; do
  case $opt in
    d) MAG_DIR="$OPTARG" ;;
    f) MAG_FILE="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    r) READS_DIR="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    s) SAVE_SVG="$OPTARG" ;;
    p) PERCENT="$OPTARG" ;;
    m) METHODS="$OPTARG" ;;
    G) GUNC_DB="$OPTARG" ;;
    k) KMER_SIZE="$OPTARG" ;;
    q) KMER_PERCENT="$OPTARG" ;;
    M) GC_MAD_MULT="$OPTARG" ;;
    a) AAID_PERCENT="$OPTARG" ;;
    c) COMBINE="$OPTARG" ;;
    X) PER_METHOD_FASTAS="$OPTARG" ;;
    h) show_workflow_help; exit 0 ;;
    *) show_workflow_help; exit 1 ;;
  esac
done

if [[ -z "${OUTDIR:-}" ]]; then
  echo "Error: -o <outdir> is required."
  exit 1
fi

if [[ -z "${MAG_DIR:-}" && -z "${MAG_FILE:-}" ]]; then
  echo "Error: provide either -d <mag_dir> or -f <mag_file>."
  exit 1
fi
if [[ -n "${MAG_DIR:-}" && -n "${MAG_FILE:-}" ]]; then
  echo "Error: use only one of -d or -f."
  exit 1
fi

IFS=',' read -r -a METHOD_LIST <<< "$(echo "$METHODS" | tr '[:upper:]' '[:lower:]')"
if printf "%s\n" "${METHOD_LIST[@]}" | grep -qx "all"; then
  METHOD_LIST=(coverage kmer gc gunc aaid)
fi

USE_COVERAGE=0
if printf "%s\n" "${METHOD_LIST[@]}" | grep -qx "coverage"; then
  USE_COVERAGE=1
fi

if [[ $USE_COVERAGE -eq 1 && -z "${READS_DIR:-}" ]]; then
  echo "Error: -r <reads_dir> is required when using 'coverage' method."
  exit 1
fi

if [[ "$COMBINE" != "union" && "$COMBINE" != "intersection" ]]; then
  echo "Invalid -c value (use union or intersection)."
  exit 1
fi

if printf "%s\n" "${METHOD_LIST[@]}" | grep -qx "gunc"; then
  if [[ -z "${GUNC_DB:-}" ]]; then
    echo "Error: GUNC method selected but -G (GUNC DB path) not provided."
    exit 1
  fi
  if [[ ! -d "$GUNC_DB" ]]; then
    echo "Error: GUNC DB directory not found: $GUNC_DB"
    exit 1
  fi
fi

MAG_DIR="${MAG_DIR:+$(realpath "$MAG_DIR")}"
MAG_FILE="${MAG_FILE:+$(realpath "$MAG_FILE")}"
OUTDIR=$(realpath "$OUTDIR")
[[ -n "${READS_DIR:-}" ]] && READS_DIR=$(realpath "$READS_DIR")

mkdir -p "$OUTDIR"/{bams,coverage,matrices,cleaned,plots,tmp,summary,method_outputs}
[[ "$PER_METHOD_FASTAS" == "1" ]] && mkdir -p "$OUTDIR/cleaned/by_method"

echo ">>> Selected methods: ${METHOD_LIST[*]}"
echo ">>> Combination strategy: $COMBINE"
echo ">>> Per-method FASTAs: $([[ "$PER_METHOD_FASTAS" == "1" ]] && echo ON || echo OFF)"
[[ $USE_COVERAGE -eq 1 ]] && echo ">>> Coverage method active (reads required)" || echo ">>> Coverage method NOT active (skipping read mapping)"

SAMPLES=()
MODE="none"
if [[ $USE_COVERAGE -eq 1 ]]; then
  if compgen -G "$READS_DIR/*_1.fastq*" > /dev/null || compgen -G "$READS_DIR/*_1.fq*" > /dev/null; then
    MODE="paired"
    mapfile -t SAMPLES < <(find "$READS_DIR" -maxdepth 1 -type f \( -name "*_1.fastq*" -o -name "*_1.fq*" \) \
      | sed -E 's#(.*/)?([^/]+)_1\.(fastq|fq)(.gz)?#\2#' | sort -u)
  else
    MODE="single"
    mapfile -t SAMPLES < <(find "$READS_DIR" -maxdepth 1 -type f \( -name "*.fastq*" -o -name "*.fq*" \) \
      | sed -E 's#(.*/)?([^/]+)\.(fastq|fq)(.gz)?#\2#' | sort -u)
  fi
  [[ ${#SAMPLES[@]} -eq 0 ]] && { echo "Error: no samples found in $READS_DIR"; exit 1; }
  echo ">>> Read mode: $MODE"
  echo ">>> Samples found: ${#SAMPLES[@]}"
fi

shopt -s nullglob
if [[ -n "$MAG_FILE" ]]; then
  MAG_FILES=("$MAG_FILE")
else
  MAG_FILES=("$MAG_DIR"/*.fa "$MAG_DIR"/*.fna "$MAG_DIR"/*.fasta)
fi
[[ ${#MAG_FILES[@]} -eq 0 ]] && { echo "No MAG files found."; exit 1; }
echo ">>> MAGs detected: ${#MAG_FILES[@]}"

find_read() {
  local base="$1"
  for ext in fastq fastq.gz fq fq.gz; do
    local f="$READS_DIR/${base}.${ext}"
    [[ -f "$f" ]] && echo "$f" && return 0
  done
  return 1
}

map_and_coverage() {
  local mag_fa="$1" sample="$2"
  local mag_base=$(basename "$mag_fa"); mag_base="${mag_base%.*}"
  local bam="$OUTDIR/bams/${mag_base}__${sample}.bam"
  local cov_tsv="$OUTDIR/coverage/${mag_base}__${sample}.tsv"
  local sam_tmp="$OUTDIR/tmp/${mag_base}__${sample}.sam"
  [[ -s "$cov_tsv" ]] && echo "  • Coverage exists: $(basename "$cov_tsv")" && return 0

  if [[ "$MODE" == "paired" ]]; then
    r1=$(find_read "${sample}_1") || { echo "[WARN] missing R1 for $sample"; return 0; }
    r2=$(find_read "${sample}_2") || { echo "[WARN] missing R2 for $sample"; return 0; }
    echo "  • Mapping PE $sample -> $mag_base"
    docker run --rm -v "$(dirname "$mag_fa")":/mags -v "$READS_DIR":/reads -v "$OUTDIR":/out \
      quay.io/biocontainers/minimap2:2.30--h577a1d6_0 \
      minimap2 -ax sr -t "$THREADS" "/mags/$(basename "$mag_fa")" \
        "/reads/$(basename "$r1")" "/reads/$(basename "$r2")" > "$sam_tmp"
  else
    r=$(find_read "${sample}") || { echo "[WARN] missing reads for $sample"; return 0; }
    echo "  • Mapping SE $sample -> $mag_base"
    docker run --rm -v "$(dirname "$mag_fa")":/mags -v "$READS_DIR":/reads -v "$OUTDIR":/out \
      quay.io/biocontainers/minimap2:2.30--h577a1d6_0 \
      minimap2 -ax sr -t "$THREADS" "/mags/$(basename "$mag_fa")" "/reads/$(basename "$r")" > "$sam_tmp"
  fi

  docker run --rm -v "$OUTDIR":/work quay.io/biocontainers/samtools:1.20--h50ea8bc_0 \
    bash -c "samtools sort -@ $THREADS -o /work/bams/$(basename "$bam") /work/tmp/$(basename "$sam_tmp") && \
             samtools index -@ $THREADS /work/bams/$(basename "$bam") && \
             samtools coverage /work/bams/$(basename "$bam") | \
             awk 'BEGIN{FS=\"\t\";OFS=\"\t\"} NR>1{print \$1,\$7}' > /work/coverage/$(basename "$cov_tsv")"
  rm -f "$sam_tmp"
}

generate_clean_per_method() {
  local method="$1" mag="$2" mag_base="$3" removal_file="$4"
  local outdir_method="$OUTDIR/cleaned/by_method"
  local outfile="${outdir_method}/${mag_base}__clean_${method}.fasta"
  if [[ ! -s "$removal_file" ]]; then
    cp -f "$mag" "$outfile"
    echo "    • (per-method) $method: 0 removed"
  else
    local nrem
    nrem=$(grep -c . "$removal_file" || true)
    docker run --rm -v "$OUTDIR":/out -v "$(dirname "$mag")":/mags quay.io/biocontainers/seqkit:2.7.0--h9ee0642_0 \
      seqkit grep -v -f /out/matrices/$(basename "$removal_file") /mags/$(basename "$mag") > "$outfile"
    echo "    • (per-method) $method: ${nrem} removed -> $(basename "$outfile")"
  fi
}

SUMMARY_FILE="$OUTDIR/summary/removal_summary.tsv"
echo -e "mag\ttotal_contigs\tremoved_coverage\tremoved_kmer\tremoved_gc\tremoved_gunc\tremoved_aaid\tfinal_removed\tmethods_used\tcombine_strategy" > "$SUMMARY_FILE"

PER_METHOD_COUNTS="$OUTDIR/summary/per_method_counts.tsv"
echo -e "mag\tmethod\tn_removed" > "$PER_METHOD_COUNTS"

# =========================
# Main loop
# =========================
for MAG in "${MAG_FILES[@]}"; do
  mag_base=$(basename "$MAG"); mag_base="${mag_base%.*}"
  echo ">>> MAG: $mag_base"

  MATRIX=""
  PY_COVERAGE_REM="$OUTDIR/matrices/${mag_base}__coverage_contigs_to_remove.txt"
  PY_COVERAGE_REPORT="$OUTDIR/matrices/${mag_base}__coverage_report.tsv"
  CORR_BEFORE_TSV="$OUTDIR/matrices/${mag_base}__corr_before.tsv"
  CORR_AFTER_TSV="$OUTDIR/matrices/${mag_base}__corr_after.tsv"
  CORR_PNG="$OUTDIR/plots/${mag_base}__corr_before_after.png"
  CORR_SVG="$OUTDIR/plots/${mag_base}__corr_before_after.svg"

  if [[ $USE_COVERAGE -eq 1 ]]; then
    for S in "${SAMPLES[@]}"; do
      map_and_coverage "$MAG" "$S"
    done

    MATRIX="$OUTDIR/matrices/${mag_base}__coverage_matrix.tsv"
    CONTIGS_LIST="$OUTDIR/matrices/${mag_base}__contigs.list"
    {
      printf "contig"
      for S in "${SAMPLES[@]}"; do printf "\t%s" "$S"; done
      printf "\n"
    } > "$MATRIX"
    awk '/^>/{gsub(/^>/,""); print $1}' "$MAG" > "$CONTIGS_LIST"

    while read -r CONTIG; do
      printf "%s" "$CONTIG"
      for S in "${SAMPLES[@]}"; do
        COV_TSV="$OUTDIR/coverage/${mag_base}__${S}.tsv"
        if [[ -s "$COV_TSV" ]]; then
          val=$(awk -v c="$CONTIG" 'BEGIN{FS=OFS="\t"} $1==c{print $2}' "$COV_TSV" | head -n1)
          [[ -z "${val:-}" ]] && val=0
        else
          val=0
        fi
        printf "\t%s" "$val"
      done
      printf "\n"
    done < "$CONTIGS_LIST" >> "$MATRIX"
  else
    : > "$PY_COVERAGE_REM"
    : > "$PY_COVERAGE_REPORT"
    : > "$CORR_BEFORE_TSV"
    : > "$CORR_AFTER_TSV"
    MATRIX="/dev/null"
  fi

  KMER_REPORT="$OUTDIR/matrices/${mag_base}__kmer_report.tsv"
  KMER_REMOVE="$OUTDIR/matrices/${mag_base}__kmer_contigs_to_remove.txt"
  KMER_PLOT="$OUTDIR/plots/${mag_base}__kmer_mean_similarity.png"
  GC_REPORT="$OUTDIR/matrices/${mag_base}__gc_report.tsv"
  GC_REMOVE="$OUTDIR/matrices/${mag_base}__gc_contigs_to_remove.txt"
  GC_PLOT="$OUTDIR/plots/${mag_base}__gc_content.png"
  AAID_REPORT="$OUTDIR/matrices/${mag_base}__aaid_report.tsv"
  AAID_REMOVE="$OUTDIR/matrices/${mag_base}__aaid_contigs_to_remove.txt"
  AAID_PLOT="$OUTDIR/plots/${mag_base}__aaid_mean_similarity.png"

  PROTEINS_FAA="$OUTDIR/tmp/${mag_base}.faa"
  if printf "%s\n" "${METHOD_LIST[@]}" | grep -qx "aaid"; then
    if [[ ! -s "$PROTEINS_FAA" ]]; then
      echo "  • Predicting proteins (Prodigal) for aaid..."
      docker run --rm -v "$(dirname "$MAG")":/mags -v "$OUTDIR":/out quay.io/biocontainers/prodigal:2.6.3--h031d066_9 \
        prodigal -i /mags/$(basename "$MAG") -a /out/tmp/${mag_base}.faa -p meta || {
          echo "[WARN] Prodigal failed for $mag_base"
          : > "$PROTEINS_FAA"
        }
    fi
  else
    : > "$PROTEINS_FAA"
  fi

  METHODS_ARG=$(IFS=','; echo "${METHOD_LIST[*]}")

  python3 - "$MATRIX" "$MAG" "$PROTEINS_FAA" \
    "$PY_COVERAGE_REM" "$PY_COVERAGE_REPORT" "$CORR_BEFORE_TSV" "$CORR_AFTER_TSV" "$CORR_PNG" "$CORR_SVG" \
    "$KMER_REPORT" "$KMER_REMOVE" "$KMER_PLOT" \
    "$GC_REPORT" "$GC_REMOVE" "$GC_PLOT" \
    "$AAID_REPORT" "$AAID_REMOVE" "$AAID_PLOT" \
    "$SAVE_SVG" "$PERCENT" "$METHODS_ARG" "$KMER_SIZE" "$KMER_PERCENT" "$GC_MAD_MULT" "$AAID_PERCENT" << 'PYCODE'
import sys, numpy as np, pandas as pd, matplotlib.pyplot as plt, re, os
from Bio import SeqIO
from itertools import product

(args := sys.argv[1:])
(matrix_path, fasta_path, proteins_faa,
 cov_remove, cov_report, corr_before_path, corr_after_path, corr_png, corr_svg,
 kmer_report, kmer_remove, kmer_plot,
 gc_report, gc_remove, gc_plot,
 aaid_report, aaid_remove, aaid_plot,
 save_svg, percent_cov, methods_csv, kmer_size, kmer_percent, gc_mad_mult, aaid_percent) = args

save_svg = str(save_svg) == "1"
percent_cov = float(percent_cov)
kmer_percent = float(kmer_percent)
gc_mad_mult = float(gc_mad_mult)
aaid_percent = float(aaid_percent)
kmer_size = int(kmer_size)
methods = set(m.strip() for m in methods_csv.split(','))

cov_removed = []
if "coverage" in methods and os.path.exists(matrix_path) and matrix_path != "/dev/null":
    df = pd.read_csv(matrix_path, sep="\t").fillna(0.0)
    contigs = df["contig"].astype(str).to_numpy()
    Xcov = df.drop(columns=["contig"]).to_numpy(dtype=float) if df.shape[1] > 1 else np.empty((len(contigs),0))
else:
    contigs = [rec.id for rec in SeqIO.parse(fasta_path, "fasta")]
    if "coverage" in methods:
        pd.DataFrame().to_csv(cov_report, sep="\t", index=False)
        pd.DataFrame().to_csv(corr_before_path, sep="\t", index=False)
        pd.DataFrame().to_csv(corr_after_path, sep="\t", index=False)
        open(cov_remove,'w').close()

if "coverage" in methods and os.path.exists(matrix_path) and matrix_path != "/dev/null":
    if len(contigs) >= 2 and Xcov.shape[1] >= 2:
        cor_before = np.corrcoef(Xcov)
        cor_before = np.nan_to_num(cor_before, nan=0.0)
        mean_per = (np.sum(cor_before, axis=1) - 1) / (cor_before.shape[1] - 1)
        global_mean = mean_per.mean()
        threshold = global_mean * (1 - percent_cov / 100.0)
        flag_remove = mean_per < threshold
        cov_removed = list(np.array(contigs)[flag_remove])
        pd.DataFrame({
            "contig": contigs,
            "mean_corr": mean_per,
            "global_mean": global_mean,
            "threshold": threshold,
            "flag_remove": flag_remove
        }).sort_values("mean_corr").to_csv(cov_report, sep="\t", index=False)
        pd.DataFrame(cor_before, index=contigs, columns=contigs).to_csv(corr_before_path, sep="\t")
        kept = ~flag_remove
        if kept.sum() >= 2:
            cor_after = np.corrcoef(Xcov[kept,:])
            cor_after = np.nan_to_num(cor_after, nan=0.0)
            pd.DataFrame(cor_after, index=np.array(contigs)[kept], columns=np.array(contigs)[kept]).to_csv(corr_after_path, sep="\t")
        else:
            pd.DataFrame().to_csv(corr_after_path, sep="\t", index=False)
        with open(cov_remove,'w') as f:
            for c in cov_removed: f.write(c+"\n")
        fig, axs = plt.subplots(1,2, figsize=(14,5))
        im1 = axs[0].imshow(cor_before, vmin=-1, vmax=1, aspect="auto")
        axs[0].set_title(f"Correlation before (n={len(contigs)})")
        axs[0].set_xlabel("contigs"); axs[0].set_ylabel("contigs")
        if kept.sum() >= 2:
            axs[1].imshow(cor_after, vmin=-1, vmax=1, aspect="auto")
            axs[1].set_title(f"Correlation after (n={kept.sum()})")
        else:
            axs[1].text(0.5,0.5,"< 2 contigs kept", ha="center", va="center")
            axs[1].set_title("Correlation after")
            axs[1].set_xticks([]); axs[1].set_yticks([])
        cb = fig.colorbar(im1, ax=axs.ravel().tolist(), shrink=0.6)
        cb.set_label("Pearson r")
        fig.tight_layout()
        fig.savefig(corr_png, dpi=300)
        if save_svg: fig.savefig(corr_svg)
    else:
        pd.DataFrame().to_csv(cov_report, sep="\t", index=False)
        pd.DataFrame().to_csv(corr_before_path, sep="\t", index=False)
        pd.DataFrame().to_csv(corr_after_path, sep="\t", index=False)
        open(cov_remove,'w').close()
else:
    if "coverage" not in methods:
        for p in [cov_report, corr_before_path, corr_after_path, cov_remove]:
            if not os.path.exists(p):
                pd.DataFrame().to_csv(p, sep="\t", index=False)

seqs_all = list(SeqIO.parse(fasta_path, "fasta"))
lengths_map = {r.id: len(r.seq) for r in seqs_all}

kmer_removed = []
if "kmer" in methods:
    alphabet = ['A','C','G','T']
    from itertools import product
    kmers_all = [''.join(p) for p in product(alphabet, repeat=int(kmer_size))]
    idx = {k:i for i,k in enumerate(kmers_all)}
    mat = np.zeros((len(seqs_all), len(kmers_all)), dtype=float)
    for i, rec in enumerate(seqs_all):
        s = str(rec.seq).upper()
        total = 0
        ks = int(kmer_size)
        for j in range(len(s)-ks+1):
            k = s[j:j+ks]
            if k in idx:
                mat[i, idx[k]] += 1
                total += 1
        if total > 0:
            mat[i,:] /= total
    norms = np.linalg.norm(mat, axis=1)
    norms[norms==0] = 1
    mat_norm = mat / norms[:,None]
    sim_matrix = np.dot(mat_norm, mat_norm.T)
    sim_matrix = np.nan_to_num(sim_matrix, nan=0.0)
    if sim_matrix.shape[0] > 1:
        mean_sim = (np.sum(sim_matrix, axis=1)-1)/(sim_matrix.shape[1]-1)
    else:
        mean_sim = np.zeros(sim_matrix.shape[0])
    global_mean_sim = mean_sim.mean() if len(mean_sim) else 0
    threshold_k = global_mean_sim * (1 - float(kmer_percent)/100.0)
    flag_remove_k = mean_sim < threshold_k
    kmer_removed = [seqs_all[i].id for i, fr in enumerate(flag_remove_k) if fr]
    pd.DataFrame({
        "contig":[r.id for r in seqs_all],
        "mean_kmer_similarity": mean_sim,
        "global_mean_similarity": global_mean_sim,
        "threshold": threshold_k,
        "flag_remove": flag_remove_k
    }).sort_values("mean_kmer_similarity").to_csv(kmer_report, sep="\t", index=False)
    with open(kmer_remove,'w') as f:
        for c in kmer_removed: f.write(c+"\n")
    fig, ax = plt.subplots(figsize=(10,5))
    lengths = [lengths_map[r.id] for r in seqs_all]
    ax.scatter(lengths, mean_sim, s=15, c=["red" if fr else "blue" for fr in flag_remove_k], alpha=0.7)
    ax.axhline(threshold_k, color="orange", linestyle="--", label=f"threshold {threshold_k:.3f}")
    ax.set_xscale("log")
    ax.set_xlabel("Contig length (bp)")
    ax.set_ylabel("Mean k-mer cosine similarity")
    ax.set_title(f"K-mer similarity (k={kmer_size})")
    ax.legend()
    fig.tight_layout()
    fig.savefig(kmer_plot, dpi=300)
else:
    for p in [kmer_report, kmer_remove]:
        if not os.path.exists(p):
            pd.DataFrame().to_csv(p, sep="\t", index=False)

gc_removed = []
if "gc" in methods:
    gc_vals = []
    ids = []
    for rec in seqs_all:
        s = str(rec.seq).upper()
        gc_vals.append((s.count('G')+s.count('C'))/len(s) if len(s)>0 else 0.0)
        ids.append(rec.id)
    gc_vals = np.array(gc_vals)
    median_gc = np.median(gc_vals) if len(gc_vals) else 0
    mad = np.median(np.abs(gc_vals - median_gc)) if len(gc_vals) else 0
    if mad == 0:
        std = gc_vals.std() if len(gc_vals) else 0
        if std == 0:
            flag_remove_gc = np.array([False]*len(gc_vals))
            threshold_low = threshold_high = median_gc
        else:
            threshold_low = median_gc - float(gc_mad_mult)*std
            threshold_high = median_gc + float(gc_mad_mult)*std
            flag_remove_gc = (gc_vals < threshold_low) | (gc_vals > threshold_high)
    else:
        threshold_low = median_gc - float(gc_mad_mult)*mad
        threshold_high = median_gc + float(gc_mad_mult)*mad
        flag_remove_gc = (gc_vals < threshold_low) | (gc_vals > threshold_high)
    gc_removed = [i for i, fr in zip(ids, flag_remove_gc) if fr]
    pd.DataFrame({
        "contig": ids,
        "gc": gc_vals,
        "median_gc": median_gc,
        "MAD_or_STD_used": "MAD" if mad!=0 else "STD",
        "threshold_low": threshold_low,
        "threshold_high": threshold_high,
        "flag_remove": flag_remove_gc
    }).sort_values("gc").to_csv(gc_report, sep="\t", index=False)
    with open(gc_remove,'w') as f:
        for c in gc_removed: f.write(c+"\n")
    fig, ax = plt.subplots(figsize=(10,5))
    ax.scatter([lengths_map[i] for i in ids], gc_vals, s=15,
               c=["red" if fr else "blue" for fr in flag_remove_gc], alpha=0.7)
    ax.axhline(threshold_low, color="orange", linestyle="--", label=f"low {threshold_low:.3f}")
    ax.axhline(threshold_high, color="orange", linestyle="--", label=f"high {threshold_high:.3f}")
    ax.set_xscale("log")
    ax.set_xlabel("Contig length (bp)")
    ax.set_ylabel("GC fraction")
    ax.set_title("GC content per contig")
    ax.legend()
    fig.tight_layout()
    fig.savefig(gc_plot, dpi=300)
else:
    for p in [gc_report, gc_remove]:
        if not os.path.exists(p):
            pd.DataFrame().to_csv(p, sep="\t", index=False)

aaid_removed = []
if "aaid" in methods:
    contig_index = {c:i for i,c in enumerate(lengths_map.keys())}
    aa_list = list("ACDEFGHIKLMNPQRSTVWY")
    aa_pos = {a:i for i,a in enumerate(aa_list)}
    aa_counts = np.zeros((len(contig_index), len(aa_list)), dtype=float)
    if os.path.isfile(proteins_faa) and os.path.getsize(proteins_faa) > 0:
        for rec in SeqIO.parse(proteins_faa, "fasta"):
            contig_id = re.sub(r'_\d+$', '', rec.id)
            if contig_id in contig_index:
                vec = aa_counts[contig_index[contig_id]]
                for aa in str(rec.seq).upper():
                    if aa in aa_pos:
                        vec[aa_pos[aa]] += 1
    row_sums = aa_counts.sum(axis=1)
    for i, rs in enumerate(row_sums):
        if rs > 0:
            aa_counts[i,:] /= rs
    norms = np.linalg.norm(aa_counts, axis=1)
    norms[norms==0] = 1
    aa_norm = aa_counts / norms[:,None]
    sim_mat = np.dot(aa_norm, aa_norm.T)
    sim_mat = np.nan_to_num(sim_mat, nan=0.0)
    n = sim_mat.shape[0]
    if n > 1:
        mean_sim = (np.sum(sim_mat, axis=1)-1)/(n-1)
    else:
        mean_sim = np.zeros(n)
    global_mean_aa = mean_sim.mean() if n>0 else 0
    threshold_aa = global_mean_aa * (1 - float(aaid_percent)/100.0)
    ids = list(contig_index.keys())
    flag_remove_aa = mean_sim < threshold_aa
    aaid_removed = [ids[i] for i, fr in enumerate(flag_remove_aa) if fr]
    pd.DataFrame({
        "contig": ids,
        "mean_aaid_similarity": mean_sim,
        "global_mean_similarity": global_mean_aa,
        "threshold": threshold_aa,
        "flag_remove": flag_remove_aa
    }).sort_values("mean_aaid_similarity").to_csv(aaid_report, sep="\t", index=False)
    with open(aaid_remove,'w') as f:
        for c in aaid_removed: f.write(c+"\n")
    fig, ax = plt.subplots(figsize=(10,5))
    lengths = [lengths_map[i] for i in ids]
    ax.scatter(lengths, mean_sim, s=15,
               c=["red" if fr else "blue" for fr in flag_remove_aa], alpha=0.7)
    ax.axhline(threshold_aa, color="orange", linestyle="--", label=f"threshold {threshold_aa:.3f}")
    ax.set_xscale("log")
    ax.set_xlabel("Contig length (bp)")
    ax.set_ylabel("Mean AA composition similarity")
    ax.set_title("AAID-like similarity")
    ax.legend()
    fig.tight_layout()
    fig.savefig(aaid_plot, dpi=300)
else:
    for p in [aaid_report, aaid_remove]:
        if not os.path.exists(p):
            pd.DataFrame().to_csv(p, sep="\t", index=False)
PYCODE

  GUNC_REMOVE="$OUTDIR/matrices/${mag_base}__gunc_contigs_to_remove.txt"
  : > "$GUNC_REMOVE"
  if printf "%s\n" "${METHOD_LIST[@]}" | grep -qx "gunc"; then
    echo "  • Running GUNC..."
    GUNC_WORK="$OUTDIR/tmp/gunc_${mag_base}"
    rm -rf "$GUNC_WORK"
    mkdir -p "$GUNC_WORK/gunc_output"
    docker run --rm -v "$(dirname "$MAG")":/mags -v "$GUNC_DB":/gunc_db -v "$GUNC_WORK":/out \
      quay.io/biocontainers/gunc:1.0.6--pyhdfd78af_0 \
        gunc run -r /gunc_db/gunc_db.dmnd -i /mags/$(basename "$MAG") -t "$THREADS" \
          --detailed_output --contig_taxonomy_output --use_species_level \
          -o /out/gunc_output || echo "[WARN] GUNC failed for $mag_base"

    ASSIGN_FILE=$(find "$GUNC_WORK/gunc_output/gunc_output/" -maxdepth 1 -type f -name "*.contig_assignments.tsv" | head -n1 || true)
    if [[ -n "$ASSIGN_FILE" && -s "$ASSIGN_FILE" ]]; then
      genus=$(awk -F'\t' '$2=="genus"{g=$3;sub(/^[0-9]+ /,"",g);c[g]+=$4}
                           END{mx=0;top="";for(g in c){if(c[g]>mx){mx=c[g];top=g}}print top}' "$ASSIGN_FILE")
      if [[ -n "$genus" ]]; then
        echo "    + Dominant genus = $genus"
        awk -F'\t' -v g="$genus" '$2=="genus"{n=$3;sub(/^[0-9]+ /,"",n); if(n==g)print $1}' "$ASSIGN_FILE" > "$GUNC_WORK/keep_ids.tsv"
        awk '/^>/{sub(/^>/,"");print $1}' "$MAG" > "$GUNC_WORK/all_ids.tsv"
        grep -Fvx -f "$GUNC_WORK/keep_ids.tsv" "$GUNC_WORK/all_ids.tsv" > "$GUNC_REMOVE" || true
      else
        echo "    + Could not determine dominant genus."
      fi
    else
      echo "    + GUNC assignments file not found."
    fi
  fi

  COVERAGE_REM_LIST="$PY_COVERAGE_REM"
  KMER_REM_LIST="$KMER_REMOVE"
  GC_REM_LIST="$GC_REMOVE"
  GUNC_REM_LIST="$GUNC_REMOVE"
  AAID_REM_LIST="$AAID_REMOVE"

  for f in "$COVERAGE_REM_LIST" "$KMER_REM_LIST" "$GC_REM_LIST" "$GUNC_REM_LIST" "$AAID_REM_LIST"; do
    [[ -f "$f" ]] || : > "$f"
  done

  n_cov=$(grep -c . "$COVERAGE_REM_LIST" || true)
  n_kmer=$(grep -c . "$KMER_REM_LIST" || true)
  n_gc=$(grep -c . "$GC_REM_LIST" || true)
  n_gunc=$(grep -c . "$GUNC_REM_LIST" || true)
  n_aaid=$(grep -c . "$AAID_REM_LIST" || true)

  if [[ "$PER_METHOD_FASTAS" == "1" ]]; then
    for m in "${METHOD_LIST[@]}"; do
      case "$m" in
        coverage) generate_clean_per_method "coverage" "$MAG" "$mag_base" "$COVERAGE_REM_LIST" ;;
        kmer)     generate_clean_per_method "kmer"     "$MAG" "$mag_base" "$KMER_REM_LIST" ;;
        gc)       generate_clean_per_method "gc"       "$MAG" "$mag_base" "$GC_REM_LIST" ;;
        gunc)     generate_clean_per_method "gunc"     "$MAG" "$mag_base" "$GUNC_REM_LIST" ;;
        aaid)     generate_clean_per_method "aaid"     "$MAG" "$mag_base" "$AAID_REM_LIST" ;;
      esac
    done
  fi

  [[ " ${METHOD_LIST[*]} " == *" coverage "* ]] && echo -e "${mag_base}\tcoverage\t${n_cov}" >> "$PER_METHOD_COUNTS"
  [[ " ${METHOD_LIST[*]} " == *" kmer "*     ]] && echo -e "${mag_base}\tkmer\t${n_kmer}"     >> "$PER_METHOD_COUNTS"
  [[ " ${METHOD_LIST[*]} " == *" gc "*       ]] && echo -e "${mag_base}\tgc\t${n_gc}"         >> "$PER_METHOD_COUNTS"
  [[ " ${METHOD_LIST[*]} " == *" gunc "*     ]] && echo -e "${mag_base}\tgunc\t${n_gunc}"     >> "$PER_METHOD_COUNTS"
  [[ " ${METHOD_LIST[*]} " == *" aaid "*     ]] && echo -e "${mag_base}\taaid\t${n_aaid}"     >> "$PER_METHOD_COUNTS"

  ALL_REM_UNION="$OUTDIR/matrices/${mag_base}__all_removed_union.txt"
  cat "$COVERAGE_REM_LIST" "$KMER_REM_LIST" "$GC_REM_LIST" "$GUNC_REM_LIST" "$AAID_REM_LIST" 2>/dev/null | grep -v '^$' | sort -u > "$ALL_REM_UNION"

  if [[ "$COMBINE" == "intersection" ]]; then
    USED_FILES=()
    for m in "${METHOD_LIST[@]}"; do
      case "$m" in
        coverage) USED_FILES+=("$COVERAGE_REM_LIST") ;;
        kmer)     USED_FILES+=("$KMER_REM_LIST") ;;
        gc)       USED_FILES+=("$GC_REM_LIST") ;;
        gunc)     USED_FILES+=("$GUNC_REM_LIST") ;;
        aaid)     USED_FILES+=("$AAID_REM_LIST") ;;
      esac
    done
    if [[ ${#USED_FILES[@]} -gt 0 ]]; then
      cp "${USED_FILES[0]}" "$OUTDIR/matrices/${mag_base}__intersection_work.txt" || true
      for ((i=1;i<${#USED_FILES[@]};i++)); do
        grep -Fxf "${USED_FILES[i]}" "$OUTDIR/matrices/${mag_base}__intersection_work.txt" > "$OUTDIR/matrices/${mag_base}__intersection_tmp.txt" || true
        mv "$OUTDIR/matrices/${mag_base}__intersection_tmp.txt" "$OUTDIR/matrices/${mag_base}__intersection_work.txt"
      done
      FINAL_REMOVE="$OUTDIR/matrices/${mag_base}__final_remove.txt"
      sort -u "$OUTDIR/matrices/${mag_base}__intersection_work.txt" > "$FINAL_REMOVE"
      rm -f "$OUTDIR/matrices/${mag_base}__intersection_work.txt"
    else
      FINAL_REMOVE="$ALL_REM_UNION"
    fi
  else
    FINAL_REMOVE="$ALL_REM_UNION"
  fi

  n_final=$(grep -c . "$FINAL_REMOVE" || true)
  echo "  • Removed coverage: $n_cov | kmer: $n_kmer | gc: $n_gc | gunc: $n_gunc | aaid: $n_aaid | final ($COMBINE): $n_final"

  CLEAN="$OUTDIR/cleaned/${mag_base}__clean.fasta"
  if [[ "$n_final" -gt 0 ]]; then
    docker run --rm -v "$OUTDIR":/out -v "$(dirname "$MAG")":/mags quay.io/biocontainers/seqkit:2.7.0--h9ee0642_0 \
      seqkit grep -v -f /out/matrices/$(basename "$FINAL_REMOVE") /mags/$(basename "$MAG") > "$CLEAN"
  else
    cp -f "$MAG" "$CLEAN"
  fi

  total_contigs=$(grep -c '^>' "$MAG" || true)
  echo -e "${mag_base}\t${total_contigs}\t${n_cov}\t${n_kmer}\t${n_gc}\t${n_gunc}\t${n_aaid}\t${n_final}\t${METHOD_LIST[*]}\t${COMBINE}" >> "$SUMMARY_FILE"
done

echo "-----------------------------------------"
echo "Done. Results in: $OUTDIR"
echo "Final combined summary: $SUMMARY_FILE"
[[ "$PER_METHOD_FASTAS" == "1" ]] && echo "Per-method counts: $PER_METHOD_COUNTS"
[[ "$PER_METHOD_FASTAS" == "1" ]] && echo "Per-method FASTAs: $OUTDIR/cleaned/by_method"
echo "-----------------------------------------"
