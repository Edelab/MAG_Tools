#!/usr/bin/env bash
shopt -s nullglob

# ============================================================
# MAG_finder (Filtering PRE-DAS_Tool + DAS_Tool + dRep)
#
# Output structure:
#   00_ASSEMBLY/       MEGAHIT assemblies (if -A or auto-assembled)
#   01_ALIGNMENT/      BAM + depth per sample
#   02_BINNING/        MetaBAT2, MaxBin2, CONCOCT, VAMB, DAS_Tool, dRep
#   03_MAGS/           All raw bins (standardised names)
#   04_MAGs_filtered/  Size-filtered bins (PRE and POST DAS_Tool)
#   05_MAGs_derep/     Final: DAS_Tool/ + dRep/ copies
#
# Flow:
#   0. (Optional) MEGAHIT assembly   -> 00_ASSEMBLY/
#   1. Align reads -> BAM + depth    -> 01_ALIGNMENT/
#   2. Binning                       -> 02_BINNING/
#   3. Collect bins                  -> 03_MAGS/
#   4. Filter size (PRE_DASTOOL)     -> 04_MAGs_filtered/
#   5. (Optional) DAS_Tool (-D)      -> 02_BINNING/das_tool/
#   6. Add DAS_Tool bins + re-filter -> 04_MAGs_filtered/
#   7. (Optional) dRep (-R)          -> 02_BINNING/dRep/
#   8. Aggregate final MAGs          -> 05_MAGs_derep/
#
# ============================================================

MASTER_RUN_ID=$(date +%Y%m%d%H%M%S)
DOCKER_LABEL="mag_finder_run=$MASTER_RUN_ID"
STOP_REQUESTED=0
CURRENT_SAMPLE=""
CURRENT_SUBDIR=""

BINNING_TOOLS_DEFAULT="metabat2,maxbin2,concoct"
BINNING_TOOLS="$BINNING_TOOLS_DEFAULT"
DO_DREP=0
DREP_EXTRA_OPTS=""
DO_DASTOOL=0
DASTOOL_EXTRA_OPTS=""
MIN_MAG_SIZE=50000
ASSEMBLY_FILE=""
RUN_MEGAHIT=0
MEGAHIT_EXTRA_OPTS=""
MEGAHIT_MIN_CONTIG=1000
log_file=""

log() {
    local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${ts}] $*" | tee -a "$log_file"
}

# ── Signal handling ────────────────────────────────────────────────────────
SCRIPT_PID=$$
CURRENT_DOCKER_PID=""

drun() {
    (( STOP_REQUESTED )) && return 1
    docker run "$@" &
    CURRENT_DOCKER_PID=$!
    wait "$CURRENT_DOCKER_PID"
    local rc=$?
    CURRENT_DOCKER_PID=""
    return $rc
}

nuke_everything() {
    if [[ -n "$CURRENT_DOCKER_PID" ]]; then
        kill -KILL "$CURRENT_DOCKER_PID" 2>/dev/null || true
        CURRENT_DOCKER_PID=""
    fi
    local ids
    ids=$(docker ps -a --filter "label=${DOCKER_LABEL}" -q 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
        echo "[SIGNAL] Killing containers: $(echo "$ids" | tr '\n' ' ')"
        docker kill --signal SIGKILL $ids >/dev/null 2>&1 || true
        docker rm -f $ids >/dev/null 2>&1 || true
    fi
    local child
    for child in $(pgrep -P "$SCRIPT_PID" 2>/dev/null || true); do
        kill -KILL "$child" 2>/dev/null || true
    done
}

request_stop() {
    if [[ $STOP_REQUESTED -eq 0 ]]; then
        echo ""
        echo "[SIGNAL] Ctrl+C — stopping after current step. Press again to force-quit."
        echo "[SIGNAL]   subdir='${CURRENT_SUBDIR}'  sample='${CURRENT_SAMPLE}'"
        STOP_REQUESTED=1
        nuke_everything
    else
        echo ""
        echo "[SIGNAL] Force-quit. Killing everything now."
        nuke_everything
        kill -KILL -- "-${SCRIPT_PID}" 2>/dev/null || true
        exit 130
    fi
}

handle_tstp() {
    echo ""
    echo "[SIGNAL] Ctrl+Z blocked. Use Ctrl+C to stop (once = graceful, twice = force)."
}

trap request_stop  INT TERM
trap handle_tstp   TSTP

show_workflow_help() {
    local BOLD='\033[1m'
    local CYAN='\033[0;36m'
    local YELLOW='\033[0;33m'
    local GREEN='\033[0;32m'
    local DIM='\033[2m'
    local RESET='\033[0m'

    printf "\n"
    printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}${CYAN}║               MAG_finder  —  Metagenome-Assembled Genomes        ║${RESET}\n"
    printf "${BOLD}${CYAN}║  Assembly (opt)  ▸  Binning  ▸  DAS_Tool (opt)  ▸  dRep (opt)   ║${RESET}\n"
    printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}\n"
    printf "\n"

    printf "${BOLD}USAGE${RESET}\n"
    printf "  bash MAG_Tools.sh -w MAG_finder ${YELLOW}-o${RESET} <out_dir> ${YELLOW}-t${RESET} <threads>  <INPUT_MODE>  [OPTIONS]\n"
    printf "  ${DIM}Note: -a <assembly> is optional — omit it to use MEGAHIT (-A) or be prompted.${RESET}\n"
    printf "\n"

    printf "${BOLD}INPUT MODES${RESET}  ${DIM}(exactly one required)${RESET}\n"
    printf "  ${YELLOW}-r${RESET} <reads_root>        Multi-sample mode. Scans subdirectories of <reads_root>;\n"
    printf "                        each subdir is processed as an independent sample set.\n"
    printf "                        If no subdirectories are found, the directory itself is used.\n"
    printf "\n"
    printf "  ${YELLOW}-1${RESET} <R1> ${YELLOW}-2${RESET} <R2>         Single paired-end sample. Provide the two FASTQ files\n"
    printf "                        explicitly (gzip-compressed accepted).\n"
    printf "\n"
    printf "  ${YELLOW}-s${RESET} <single.fastq.gz>   Single-end (unpaired) sample mode.\n"
    printf "\n"

    printf "${BOLD}ASSEMBLY${RESET}\n"
    printf "  ${YELLOW}-a${RESET} <path>              ${BOLD}Optional.${RESET} Assembly FASTA — two forms:\n"
    printf "                        ${BOLD}Directory:${RESET} each sample needs <sample>.fa|fna|fasta\n"
    printf "                        ${BOLD}Single file:${RESET} one FASTA used for all samples\n"
    printf "                        If omitted, MEGAHIT will be used (see -A below).\n"
    printf "\n"
    printf "  ${YELLOW}-A${RESET}                     ${GREEN}Run MEGAHIT assembly${RESET} on the input reads before binning.\n"
    printf "                        Required if -a is not provided.\n"
    printf "                        Output: <out_dir>/00_ASSEMBLY/<sample>/final.contigs.fa\n"
    printf "                        The assembled FASTA is then used automatically for all\n"
    printf "                        downstream steps (alignment, binning, DAS_Tool, dRep).\n"
    printf "\n"
    printf "  ${YELLOW}-E${RESET} \"<opts>\"            Extra options forwarded verbatim to MEGAHIT.\n"
    printf "                        Example: ${DIM}-E \"--min-count 2 --k-list 21,41,61,81,99\"${RESET}\n"
    printf "                        Default min contig length: ${MEGAHIT_MIN_CONTIG} bp\n"
    printf "\n"
    printf "  ${YELLOW}-L${RESET} <bp>                Minimum contig length for MEGAHIT output.  [${MEGAHIT_MIN_CONTIG}]\n"
    printf "\n"

    printf "${BOLD}REQUIRED${RESET}\n"
    printf "  ${YELLOW}-o${RESET} <out_dir>           Root output directory. Created if it does not exist.\n"
    printf "  ${YELLOW}-t${RESET} <threads>           Number of CPU threads passed to all tools.\n"
    printf "\n"

    printf "${BOLD}BINNING OPTIONS${RESET}\n"
    printf "  ${YELLOW}-B${RESET} <tool1,tool2,...>   Binning tools to run (comma-separated).\n"
    printf "                        Available: metabat2, maxbin2, concoct, vamb\n"
    printf "                        Default:   ${BINNING_TOOLS_DEFAULT}\n"
    printf "\n"
    printf "  ${YELLOW}-G${RESET} <bytes>             Minimum MAG size filter (bytes).  [${MIN_MAG_SIZE}]\n"
    printf "\n"

    printf "${BOLD}DAS_Tool / dRep${RESET}\n"
    printf "  ${YELLOW}-D${RESET}                     Enable DAS_Tool bin refinement (requires ≥ 2 binning tools).\n"
    printf "  ${YELLOW}-X${RESET} \"<opts>\"            Extra options for DAS_Tool.\n"
    printf "  ${YELLOW}-R${RESET}                     Enable dRep genome dereplication.\n"
    printf "  ${YELLOW}-P${RESET} \"<opts>\"            Extra options for dRep.\n"
    printf "\n"
    printf "  ${YELLOW}-h${RESET}                     Show this help message and exit.\n"
    printf "\n"

    printf "${BOLD}PIPELINE STEPS${RESET}\n"
    printf "  ${GREEN}[0]${RESET} ${BOLD}MEGAHIT Assembly${RESET}  ${DIM}(-A)${RESET}  Read assembly per sample    →  00_ASSEMBLY/\n"
    printf "  ${GREEN}[1]${RESET} ${BOLD}Read Alignment${RESET}          BWA-MEM → sorted BAM + depth  →  01_ALIGNMENT/\n"
    printf "  ${GREEN}[2]${RESET} ${BOLD}Binning${RESET}                 Selected tools per sample      →  02_BINNING/\n"
    printf "  ${GREEN}[3]${RESET} ${BOLD}Bin Collection${RESET}          All raw bins, standardised     →  03_MAGS/\n"
    printf "  ${GREEN}[4]${RESET} ${BOLD}PRE_DASTOOL Filter${RESET}      Size-based filter              →  04_MAGs_filtered/\n"
    printf "  ${GREEN}[5]${RESET} ${BOLD}DAS_Tool${RESET} ${DIM}(-D)${RESET}          Bin refinement                 →  02_BINNING/das_tool/\n"
    printf "  ${GREEN}[6]${RESET} ${BOLD}Post-DAS Merge${RESET}          Refined bins + re-filter       →  04_MAGs_filtered/\n"
    printf "  ${GREEN}[7]${RESET} ${BOLD}dRep${RESET} ${DIM}(-R)${RESET}              Genome dereplication           →  02_BINNING/dRep/\n"
    printf "  ${GREEN}[8]${RESET} ${BOLD}Aggregation${RESET}             DAS_Tool + dRep copies         →  05_MAGs_derep/\n"
    printf "\n"

    printf "${BOLD}OUTPUT STRUCTURE${RESET}\n"
    printf "  <out_dir>/\n"
    printf "  ├── 00_ASSEMBLY/         MEGAHIT assemblies per sample (if -A).\n"
    printf "  ├── 01_ALIGNMENT/        BAM, BAI and depth files per sample.\n"
    printf "  ├── 02_BINNING/\n"
    printf "  │   ├── metabat2/ maxbin2/ concoct/ vamb/\n"
    printf "  │   ├── das_tool/         DAS_Tool output (if -D).\n"
    printf "  │   └── dRep/             dRep output (if -R).\n"
    printf "  ├── 03_MAGS/             All raw bins (standardised names).\n"
    printf "  ├── 04_MAGs_filtered/    Size-filtered bins.\n"
    printf "  ├── 05_MAGs_derep/\n"
    printf "  │   ├── DAS_Tool/        DAS_Tool-refined bins.\n"
    printf "  │   └── dRep/            dRep dereplicated genomes.\n"
    printf "  └── log.txt\n"
    printf "\n"

    printf "${BOLD}EXAMPLES${RESET}\n"
    printf "  ${DIM}# Provide your own assembly:${RESET}\n"
    printf "  bash MAG_Tools.sh -w MAG_finder \\\\\n"
    printf "      -1 R1.fastq.gz -2 R2.fastq.gz -a assembly.fasta \\\\\n"
    printf "      -o out/ -t 20 -B metabat2,maxbin2,concoct\n"
    printf "\n"
    printf "  ${DIM}# Let MEGAHIT assemble for you (no -a needed):${RESET}\n"
    printf "  bash MAG_Tools.sh -w MAG_finder \\\\\n"
    printf "      -1 R1.fastq.gz -2 R2.fastq.gz \\\\\n"
    printf "      -o out/ -t 20 -A -B metabat2,maxbin2\n"
    printf "\n"
    printf "  ${DIM}# Multi-sample, MEGAHIT + DAS_Tool + dRep:${RESET}\n"
    printf "  bash MAG_Tools.sh -w MAG_finder \\\\\n"
    printf "      -r reads/ -o out/ -t 16 -A \\\\\n"
    printf "      -B metabat2,maxbin2,concoct -D -R\n"
    printf "\n"
    printf "  ${DIM}# Multi-sample with existing assemblies dir + DAS_Tool + dRep:${RESET}\n"
    printf "  bash MAG_Tools.sh -w MAG_finder \\\\\n"
    printf "      -r reads/ -a assemblies/ -o out/ -t 16 \\\\\n"
    printf "      -B metabat2,maxbin2,concoct \\\\\n"
    printf "      -D -X \"--search_engine diamond\" \\\\\n"
    printf "      -R -P \"-comp 50 -con 10\"\n"
    printf "\n"
    printf "${DIM}All tools run inside Docker containers. Ensure the Docker daemon is running.${RESET}\n"
    printf "${DIM}Ctrl+C once = graceful stop; twice = force-kill containers.${RESET}\n"
    printf "\n"
}

reads_root=""
assemblies_dir=""
threads=""
out_root=""
exp_R1=""
exp_R2=""
exp_SE=""

while getopts "r:a:o:t:1:2:s:B:RP:G:DX:AE:L:h" opt; do
    case "$opt" in
        r) reads_root="$OPTARG" ;;
        a) assemblies_dir="$OPTARG" ;;
        o) out_root="$OPTARG" ;;
        t) threads="$OPTARG" ;;
        1) exp_R1="$OPTARG" ;;
        2) exp_R2="$OPTARG" ;;
        s) exp_SE="$OPTARG" ;;
        B) BINNING_TOOLS="$OPTARG" ;;
        R) DO_DREP=1 ;;
        P) DREP_EXTRA_OPTS="$OPTARG" ;;
        D) DO_DASTOOL=1 ;;
        G) MIN_MAG_SIZE="$OPTARG" ;;
        X) DASTOOL_EXTRA_OPTS="$OPTARG" ;;
        A) RUN_MEGAHIT=1 ;;
        E) MEGAHIT_EXTRA_OPTS="$OPTARG" ;;
        L) MEGAHIT_MIN_CONTIG="$OPTARG" ;;
        h) show_workflow_help; exit 0 ;;
        *) show_workflow_help; exit 1 ;;
    esac
done

if ! [[ "$MIN_MAG_SIZE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -G must be an integer (bytes)"; exit 1
fi

modes_set=0
[[ -n "$reads_root" ]] && modes_set=$((modes_set+1))
[[ -n "$exp_R1" || -n "$exp_R2" ]] && modes_set=$((modes_set+1))
[[ -n "$exp_SE" ]] && modes_set=$((modes_set+1))
(( modes_set == 1 )) || { echo "ERROR: choose exactly ONE mode (-r | -1/-2 | -s)"; exit 1; }
if [[ -n "$exp_R1" && -z "$exp_R2" ]] || [[ -z "$exp_R1" && -n "$exp_R2" ]]; then
    echo "ERROR: paired mode requires both -1 and -2"; exit 1
fi
[[ -z "$threads" || -z "$out_root" ]] && { echo "ERROR: missing required -o -t"; exit 1; }

# ── Assembly source resolution ─────────────────────────────────────────────
# If -a not provided: either -A was passed (use megahit) or ask the user
if [[ -z "$assemblies_dir" ]]; then
    if [[ $RUN_MEGAHIT -eq 0 ]]; then
        # Interactive prompt (only if stdin is a terminal)
        if [[ -t 0 ]]; then
            echo ""
            echo "┌─────────────────────────────────────────────────────┐"
            echo "│  No assembly provided (-a not set).                 │"
            echo "│  Would you like to run MEGAHIT to assemble reads?   │"
            echo "│                                                     │"
            echo "│  [Y] Yes — run MEGAHIT (recommended)                │"
            echo "│  [N] No  — exit and provide -a manually             │"
            echo "└─────────────────────────────────────────────────────┘"
            read -r -p "  Choice [Y/n]: " _yn
            case "${_yn,,}" in
                ""|y|yes)
                    RUN_MEGAHIT=1
                    echo "[INFO] MEGAHIT assembly enabled."
                    ;;
                *)
                    echo "[INFO] Exiting. Provide -a <assembly> or use -A to enable MEGAHIT."
                    exit 0
                    ;;
            esac
        else
            echo "ERROR: -a not provided and -A not set. Provide -a <assembly> or use -A." >&2
            exit 1
        fi
    fi
    # MEGAHIT will produce assemblies under 00_ASSEMBLY/
    # assemblies_dir will be set per-sample after megahit runs
fi

# Resolve -a if provided
if [[ -n "$assemblies_dir" ]]; then
    if [[ -f "$assemblies_dir" ]]; then
        ASSEMBLY_FILE=$(realpath "$assemblies_dir")
        assemblies_dir=$(dirname "$ASSEMBLY_FILE")
        echo "[INFO] -a detected as a single FASTA file: $ASSEMBLY_FILE"
    elif [[ -d "$assemblies_dir" ]]; then
        assemblies_dir=$(realpath "$assemblies_dir")
    else
        echo "ERROR: -a '$assemblies_dir' is neither a file nor a directory"; exit 1
    fi
fi

out_root=$(realpath "$out_root"); mkdir -p "$out_root"
[[ -n "$reads_root" ]] && reads_root=$(realpath "$reads_root")
[[ -n "$exp_R1" ]] && exp_R1=$(realpath "$exp_R1")
[[ -n "$exp_R2" ]] && exp_R2=$(realpath "$exp_R2")
[[ -n "$exp_SE" ]] && exp_SE=$(realpath "$exp_SE")

BINNING_TOOLS=$(echo "$BINNING_TOOLS" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
IFS=',' read -r -a BIN_ARRAY <<< "$BINNING_TOOLS"
declare -A BIN_SET=()
VALID_BINS=("metabat2" "maxbin2" "concoct" "vamb")
for b in "${BIN_ARRAY[@]}"; do
    ok=0; for v in "${VALID_BINS[@]}"; do [[ "$b" == "$v" ]] && ok=1 && break; done
    (( ok )) || { echo "ERROR: invalid binning tool: $b"; exit 1; }
    BIN_SET["$b"]=1
done

derive_sample() {
    local fname="${1:-}"
    [[ -z "$fname" ]] && { echo "UNDEFINED_SAMPLE"; return; }
    local s="$fname" suf
    for suf in _1.fastq.gz _1.fq.gz _1.fastq _1.fq _R1.fastq.gz _R1.fq.gz _R1.fastq _R1.fq \
               _2.fastq.gz _2.fq.gz _2.fastq _2.fq _R2.fastq.gz _R2.fq.gz _R2.fastq _R2.fq; do
        if [[ $s == *"$suf" ]]; then echo "${s%$suf}"; return; fi
    done
    s=${s%.fastq.gz}; s=${s%.fq.gz}; s=${s%.fastq}; s=${s%.fq}
    echo "$s"
}
is_r2() { [[ $1 =~ (_2\.f(ast)?q(\.gz)?$|_R2\.f(ast)?q(\.gz)?$) ]]; }
is_r1() { [[ $1 =~ (_1\.f(ast)?q(\.gz)?$|_R1\.f(ast)?q(\.gz)?$) ]]; }
get_r2() {
    local r1="${1:-}"; [[ -z "$r1" ]] && return 1
    local dir base candidate; dir=$(dirname "$r1"); base=$(basename "$r1")
    local patterns=(
        "_1.fastq.gz:_2.fastq.gz" "_1.fq.gz:_2.fq.gz" "_1.fastq:_2.fastq" "_1.fq:_2.fq"
        "_R1.fastq.gz:_R2.fastq.gz" "_R1.fq.gz:_R2.fq.gz" "_R1.fastq:_R2.fastq" "_R1.fq:_R2.fq"
    )
    local p left right
    for p in "${patterns[@]}"; do
        left=${p%%:*}; right=${p##*:}
        if [[ $base == *"$left" ]]; then
            candidate="${base/%$left/$right}"
            [[ -f "$dir/$candidate" ]] && { echo "$dir/$candidate"; return 0; }
        fi
    done
    candidate="${base/_1./_2.}"
    [[ -f "$dir/$candidate" ]] && { echo "$dir/$candidate"; return 0; }
    return 1
}

find_assembly_for_sample() {
    local sample="${1:-}"
    # Single-file mode
    if [[ -n "$ASSEMBLY_FILE" ]]; then
        [[ -f "$ASSEMBLY_FILE" ]] && { echo "$ASSEMBLY_FILE"; return 0; }
        return 1
    fi
    # MEGAHIT mode: look in 00_ASSEMBLY/<sample>/
    if [[ $RUN_MEGAHIT -eq 1 ]]; then
        local megahit_fa="${out_root}/00_ASSEMBLY/${sample}/final.contigs.fa"
        [[ -f "$megahit_fa" ]] && { echo "$megahit_fa"; return 0; }
        return 1
    fi
    # Directory mode
    if [[ -n "$assemblies_dir" ]]; then
        for f in "${assemblies_dir}/${sample}.fa" "${assemblies_dir}/${sample}.fna" "${assemblies_dir}/${sample}.fasta"; do
            [[ -f "$f" ]] && { echo "$f"; return 0; }
        done
    fi
    return 1
}

# ══════════════════════════════════════════════════════════════════════════
# MEGAHIT assembly
# ══════════════════════════════════════════════════════════════════════════
run_megahit_for_sample() {
    local sample="$1" r1="$2" r2="$3"   # r2 empty = single-end
    local asm_dir="${out_root}/00_ASSEMBLY/${sample}"
    local out_fa="${asm_dir}/final.contigs.fa"

    if [[ -f "$out_fa" ]]; then
        log "[MEGAHIT][$sample] Assembly already exists — skipping."
        return 0
    fi

    mkdir -p "$asm_dir"
    local reads_mount_host reads_mount_cont cmd

    if [[ -n "$r2" ]]; then
        # Paired-end: mount the reads directory
        local reads_dir; reads_dir=$(dirname "$r1")
        reads_mount_host="$reads_dir"
        reads_mount_cont="/reads"
        cmd="megahit -1 /reads/$(basename "$r1") -2 /reads/$(basename "$r2") \
             -o /out/megahit_tmp --min-contig-len $MEGAHIT_MIN_CONTIG \
             -t $threads $MEGAHIT_EXTRA_OPTS"
        log "[MEGAHIT][$sample] Paired-end assembly (min-contig=${MEGAHIT_MIN_CONTIG})..."
    else
        local reads_dir; reads_dir=$(dirname "$r1")
        reads_mount_host="$reads_dir"
        reads_mount_cont="/reads"
        cmd="megahit -r /reads/$(basename "$r1") \
             -o /out/megahit_tmp --min-contig-len $MEGAHIT_MIN_CONTIG \
             -t $threads $MEGAHIT_EXTRA_OPTS"
        log "[MEGAHIT][$sample] Single-end assembly (min-contig=${MEGAHIT_MIN_CONTIG})..."
    fi

    drun --rm --label "$DOCKER_LABEL" \
        -v "$reads_mount_host":"$reads_mount_cont":ro \
        -v "$asm_dir":/out \
        quay.io/biocontainers/megahit:1.2.9--haf24da9_8 \
        bash -c "$cmd && cp /out/megahit_tmp/final.contigs.fa /out/final.contigs.fa" \
        || { log "[MEGAHIT][$sample] ERROR — assembly failed"; return 1; }

    if [[ -f "$out_fa" ]]; then
        local n_contigs; n_contigs=$(grep -c '^>' "$out_fa" || true)
        log "[MEGAHIT][$sample] Done. Contigs: $n_contigs -> $out_fa"
    else
        log "[MEGAHIT][$sample] ERROR — final.contigs.fa not found after run"
        return 1
    fi
}

gather_initial_bins() {
    local sub_out_dir="$1"
    local bin_root="${sub_out_dir}/02_BINNING"
    local mags_dir="${sub_out_dir}/03_MAGS"
    mkdir -p "$mags_dir"
    log "[CHECKPOINT] Collecting initial bins -> $mags_dir"
    _cp_unique(){ [[ -f "$2" ]] || cp -f "$1" "$2"; }

    if [[ -d "${bin_root}/concoct" ]]; then
        while IFS= read -r -d '' f; do
            local parent sample base id new_name
            parent=$(basename "$(dirname "$(dirname "$f")")")
            sample=${parent#concoct_output_}
            base=$(basename "$f")
            id=${base%.fa}; id=${id%.fasta}
            new_name="${sample}_${id}_concoct.fasta"
            _cp_unique "$f" "$mags_dir/$new_name"
        done < <(find "${bin_root}/concoct" -type f \( -name "*.fa" -o -name "*.fasta" \) -path "*fasta_bins/*" -print0 || true)
    fi
    if [[ -d "${bin_root}/metabat2" ]]; then
        while IFS= read -r -d '' f; do
            local base sample num np new_name
            base=$(basename "$f")
            if [[ $base =~ ^(.+)\.([0-9]+)\.(fa|fasta)$ ]]; then
                sample="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
                printf -v np "%02d" "$num"
                new_name="${sample}_bin${np}_metabat2.fasta"
                _cp_unique "$f" "$mags_dir/$new_name"
            fi
        done < <(find "${bin_root}/metabat2" -maxdepth 1 -type f \( -name "*.fa" -o -name "*.fasta" \) -print0 || true)
    fi
    if [[ -d "${bin_root}/maxbin2" ]]; then
        while IFS= read -r -d '' f; do
            local base sample num new_name
            base=$(basename "$f")
            if [[ $base =~ ^(.+)_bin\.0*([0-9]+)\.(fa|fasta)$ ]]; then
                sample="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
                new_name="${sample}_bin${num}_maxbin2.fasta"
                _cp_unique "$f" "$mags_dir/$new_name"
            fi
        done < <(find "${bin_root}/maxbin2" -maxdepth 1 -type f \( -name "*.fa" -o -name "*.fasta" \) -print0 || true)
    fi
    if [[ -d "${bin_root}/vamb" ]]; then
        while IFS= read -r -d '' f; do
            local base bins_dir parent_dir sample id new_name
            base=$(basename "$f")
            bins_dir=$(dirname "$f")
            parent_dir=$(basename "$(dirname "$bins_dir")")
            if [[ "$parent_dir" == "vamb" ]]; then
                sample=$(basename "$(dirname "$(dirname "$bins_dir")")")
            else
                sample="$parent_dir"
            fi
            id=${base%.fna}; id=${id%.fa}; id=${id%.fasta}
            new_name="${sample}_${id}_vamb.fasta"
            _cp_unique "$f" "$mags_dir/$new_name"
        done < <(find "${bin_root}/vamb" -type f \( -name "*.fna" -o -name "*.fa" -o -name "*.fasta" \) -path "*/bins/*" -print0 || true)
    fi

    local total
    total=$(find "$mags_dir" -type f -name "*.fasta" | wc -l | tr -d ' ')
    log "[CHECKPOINT] Initial bins: $total"
}

add_dastool_bins_to_mags() {
    local sub_out_dir="$1"
    local bin_root="${sub_out_dir}/02_BINNING"
    local mags_dir="${sub_out_dir}/03_MAGS"
    [[ -d "${bin_root}/das_tool" ]] || return 0
    mkdir -p "$mags_dir"
    local added=0
    while IFS= read -r -d '' f; do
        local sample base id new_name
        sample=$(basename "$(dirname "$(dirname "$f")")")
        base=$(basename "$f")
        id=${base%.fa}; id=${id%.fasta}; id=${id%.fna}
        new_name="${sample}_${id}_dastool.fasta"
        if [[ ! -f "$mags_dir/$new_name" ]]; then
            cp -f "$f" "$mags_dir/$new_name"
            ((added++))
        fi
    done < <(find "${bin_root}/das_tool" -type f \( -name "*.fa" -o -name "*.fasta" -o -name "*.fna" \) -path "*/DASTool_bins/*" -print0 || true)
    log "[DAS_Tool] Added bins to MAGS/: $added"
}

filter_mags() {
    local sub_out_dir="$1" stage_label="${2:-}"
    local mags_dir="${sub_out_dir}/03_MAGS"
    local filt_dir="${sub_out_dir}/04_MAGs_filtered"
    mkdir -p "$filt_dir"
    [[ -d "$mags_dir" ]] || { log "[FILTER${stage_label}] No MAGS/ directory"; return; }
    local count_in=0 count_out=0
    while IFS= read -r -d '' f; do
        ((count_in++))
        local size
        if size=$(stat -c%s "$f" 2>/dev/null); then :; else size=$(wc -c < "$f" | tr -d ' '); fi
        if (( size > MIN_MAG_SIZE )); then
            cp -f "$f" "$filt_dir/$(basename "$f")"
            ((count_out++))
        fi
    done < <(find "$mags_dir" -maxdepth 1 -type f -name "*.fasta" -print0 || true)
    log "[FILTER${stage_label}] Total=$count_in Retained(>${MIN_MAG_SIZE})=$count_out"
}

perform_alignment_pipeline() {
    local r1="$1" r2="$2" sample="$3" reads_dir="$4" COV_DIR="$5"
    local sample_cov_dir="${COV_DIR}/${sample}"
    local work_dir="${sample_cov_dir}/work_files"
    mkdir -p "$work_dir"
    local asm
    if ! asm=$(find_assembly_for_sample "$sample"); then
        log "[ALIGN][$sample] Assembly not found"
        return
    fi
    cp -f "$asm" "${work_dir}/assembly.fa"
    if [[ ! -f "${work_dir}/assembly.fa.bwt" ]]; then
        log "[$sample] bwa index"
        drun --rm --label "$DOCKER_LABEL" -v "$work_dir":/data quay.io/biocontainers/bwa:0.7.19--h577a1d6_1 \
            bwa index /data/assembly.fa || { log "[$sample] Index failed"; return; }
    fi
    local bam="${work_dir}/${sample}.bam"
    if [[ ! -f "$bam" ]]; then
        log "[$sample] Aligning ($([[ -n "$r2" ]] && echo paired || echo single))"
        if [[ -n "$r2" ]]; then
            drun --rm --label "$DOCKER_LABEL" -v "$work_dir":/data -v "$reads_dir":/reads quay.io/biocontainers/bwa:0.7.19--h577a1d6_1 \
                bash -c "bwa mem -t $threads /data/assembly.fa /reads/${r1#$reads_dir/} /reads/${r2#$reads_dir/}" \
            | drun --rm -i --label "$DOCKER_LABEL" -v "$work_dir":/data quay.io/biocontainers/samtools:1.22.1--h96c455f_0 \
                samtools sort -@ "$threads" -O BAM -o /data/${sample}.bam -
        else
            drun --rm --label "$DOCKER_LABEL" -v "$work_dir":/data -v "$reads_dir":/reads quay.io/biocontainers/bwa:0.7.19--h577a1d6_1 \
                bash -c "bwa mem -t $threads /data/assembly.fa /reads/${r1#$reads_dir/}" \
            | drun --rm -i --label "$DOCKER_LABEL" -v "$work_dir":/data quay.io/biocontainers/samtools:1.22.1--h96c455f_0 \
                samtools sort -@ "$threads" -O BAM -o /data/${sample}.bam -
        fi
        [[ -f "$bam" ]] || { log "[$sample] Alignment failed"; return; }
        drun --rm --label "$DOCKER_LABEL" -v "$work_dir":/data quay.io/biocontainers/samtools:1.22.1--h96c455f_0 \
            samtools index /data/${sample}.bam
    else
        log "[$sample] BAM already exists"
    fi
    local depth="${work_dir}/${sample}_depth.txt"
    if [[ ! -f "$depth" ]]; then
        log "[$sample] Depth..."
        drun --rm --label "$DOCKER_LABEL" -v "$work_dir":/data quay.io/biocontainers/metabat2:2.18--h6f16272_0 \
            jgi_summarize_bam_contig_depths --outputDepth /data/$(basename "$depth") /data/${sample}.bam || log "[$sample] Depth calc failed"
    else
        log "[$sample] Depth file exists"
    fi
}

run_metabat2_for_all() {
    local COV_DIR="$1" BIN_DIR="$2"
    log "MetaBAT2..."
    for sample_dir in "$COV_DIR"/*; do
        (( STOP_REQUESTED )) && break
        [[ -d "$sample_dir" ]] || continue
        local sample depth asm
        sample=$(basename "$sample_dir")
        depth="${sample_dir}/work_files/${sample}_depth.txt"
        [[ -f "$depth" ]] || { log "[MetaBAT2][$sample] missing depth"; continue; }
        if ! asm=$(find_assembly_for_sample "$sample"); then log "[MetaBAT2][$sample] missing assembly"; continue; fi
        if compgen -G "${BIN_DIR}/metabat2/${sample}.*.fa" > /dev/null; then log "[MetaBAT2][$sample] skip (already exists)"; continue; fi
        drun --rm --label "$DOCKER_LABEL" \
          -v "$(dirname "$asm")":/in -v "$sample_dir/work_files":/depth -v "$BIN_DIR/metabat2":/out \
          quay.io/biocontainers/metabat2:2.18--h6f16272_0 \
          metabat2 -i /in/$(basename "$asm") -a /depth/$(basename "$depth") -o /out/${sample} -t "$threads" -s 100000 || log "[MetaBAT2][$sample] ERROR"
    done
}

run_maxbin2_for_all() {
    local COV_DIR="$1" BIN_DIR="$2"
    log "MaxBin2..."
    for sample_dir in "$COV_DIR"/*; do
        (( STOP_REQUESTED )) && break
        [[ -d "$sample_dir" ]] || continue
        local sample depth asm
        sample=$(basename "$sample_dir")
        depth="${sample_dir}/work_files/${sample}_depth.txt"
        [[ -f "$depth" ]] || { log "[MaxBin2][$sample] missing depth"; continue; }
        if ! asm=$(find_assembly_for_sample "$sample"); then
            log "[MaxBin2][$sample] missing assembly"; continue
        fi
        if compgen -G "$BIN_DIR/maxbin2/${sample}_bin.[0-9]*.fa" > /dev/null || \
           compgen -G "$BIN_DIR/maxbin2/${sample}_bin.[0-9]*.fasta" > /dev/null; then
            log "[MaxBin2][$sample] skip (exists)"; continue
        fi
        drun --rm --label "$DOCKER_LABEL" \
          -v "$(dirname "$asm")":/in \
          -v "$sample_dir/work_files":/depth \
          -v "$BIN_DIR/maxbin2":/out \
          quay.io/biocontainers/maxbin2:2.2.7--h503566f_7 \
          run_MaxBin.pl \
            -contig /in/$(basename "$asm") \
            -out /out/${sample}_bin \
            -abund /depth/$(basename "$depth") \
            -thread "$threads" \
          || log "[MaxBin2][$sample] ERROR"
    done
}

run_concoct_for_all() {
    local COV_DIR="$1" BIN_DIR="$2"
    log "CONCOCT..."
    for sample_dir in "$COV_DIR"/*; do
        (( STOP_REQUESTED )) && break
        [[ -d "$sample_dir" ]] || continue
        local sample work bam asm out_sub
        sample=$(basename "$sample_dir")
        work="${sample_dir}/work_files"
        bam="${work}/${sample}.bam"
        [[ -f "$bam" ]] || { log "[CONCOCT][$sample] missing BAM"; continue; }
        if ! asm=$(find_assembly_for_sample "$sample"); then log "[CONCOCT][$sample] missing assembly"; continue; fi
        out_sub="${BIN_DIR}/concoct/concoct_output_${sample}"
        [[ -d "$out_sub" ]] && { log "[CONCOCT][$sample] skip (exists)"; continue; }
        drun --rm --label "$DOCKER_LABEL" \
          -v "$BIN_DIR/concoct":/out -v "$(dirname "$bam")":/bam -v "$(dirname "$asm")":/asm \
          quay.io/biocontainers/concoct:1.1.0--py312h71dcd68_7 \
          bash -c "
            set -euo pipefail
            cut_up_fasta.py -c 10000 -o 0 -m /asm/$(basename "$asm") --merge_last -b /out/${sample}_10K.bed > /out/${sample}_10K.fa
            concoct_coverage_table.py /out/${sample}_10K.bed /bam/$(basename "$bam") > /out/${sample}_coverage_table.tsv
            concoct --composition_file /out/${sample}_10K.fa --coverage_file /out/${sample}_coverage_table.tsv -b /out/concoct_output_${sample}/ --threads $threads
            merge_cutup_clustering.py /out/concoct_output_${sample}/clustering_gt1000.csv > /out/concoct_output_${sample}/clustering_merged.csv
            mkdir -p /out/concoct_output_${sample}/fasta_bins
            extract_fasta_bins.py /asm/$(basename "$asm") /out/concoct_output_${sample}/clustering_merged.csv --output_path /out/concoct_output_${sample}/fasta_bins
          " || log "[CONCOCT][$sample] ERROR"
    done
}

run_vamb_for_sample() {
    local sample="$1" COV_DIR="$2" BIN_DIR="$3"
    local sample_dir="${COV_DIR}/${sample}"
    local work="${sample_dir}/work_files"
    local bam="${work}/${sample}.bam"
    [[ -f "$bam" ]] || { log "[VAMB][$sample] missing BAM"; return; }
    local asm
    if ! asm=$(find_assembly_for_sample "$sample"); then log "[VAMB][$sample] missing assembly"; return; fi
    local out_sample_dir="${BIN_DIR}/vamb/${sample}"
    [[ -d "${out_sample_dir}/vamb/bins" ]] && { log "[VAMB][$sample] skip (exists)"; return; }
    mkdir -p "$out_sample_dir"
    log "[VAMB][$sample] running..."
    if ! drun --rm --label "$DOCKER_LABEL" \
        -v "$(dirname "$asm")":/asm -v "$(dirname "$bam")":/bam -v "$out_sample_dir":/out \
        quay.io/biocontainers/vamb:5.0.4--pyhdfd78af_0 \
        vamb bin default --outdir /out/vamb --fasta /asm/$(basename "$asm") --bamfiles /bam/$(basename "$bam") --minfasta 2000 -p "$threads"; then
        log "[VAMB][$sample] ERROR"
    fi
}

run_vamb_for_all() {
    local COV_DIR="$1" BIN_DIR="$2"
    log "VAMB..."
    for sample_dir in "$COV_DIR"/*; do
        (( STOP_REQUESTED )) && break
        [[ -d "$sample_dir" ]] || continue
        run_vamb_for_sample "$(basename "$sample_dir")" "$COV_DIR" "$BIN_DIR"
    done
}

run_binning_pipeline() {
    local COV_DIR="$1" BIN_DIR="$2"
    log "[CHECKPOINT] Binning ($BINNING_TOOLS)"
    [[ -n "${BIN_SET[metabat2]:-}" ]] && run_metabat2_for_all "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return 0
    [[ -n "${BIN_SET[maxbin2]:-}" ]] && run_maxbin2_for_all "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return 0
    [[ -n "${BIN_SET[concoct]:-}" ]] && run_concoct_for_all "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return 0
    [[ -n "${BIN_SET[vamb]:-}" ]] && run_vamb_for_all "$COV_DIR" "$BIN_DIR"
    log "[CHECKPOINT] Binning finished"
}

generate_contigs2bin_from_filtered() {
    local sample="$1" mf_dir="$2" tool="$3" out_tsv="$4"
    : > "$out_tsv"
    local f matched=0
    shopt -s nullglob
    for f in "${mf_dir}/${sample}"_*_"${tool}".fasta "${mf_dir}/${sample}"_*_"${tool}".fa; do
        [[ -f "$f" ]] || continue
        matched=1
        local base bin_id bin_core
        base=$(basename "$f")
        case "$tool" in
            metabat2)
                if [[ $base =~ _bin([0-9]+)_metabat2\.f(ast)?a$ ]]; then
                    bin_id="metabat2.${BASH_REMATCH[1]}"
                else bin_id="metabat2.${base%_metabat2.*}"; fi ;;
            maxbin2)
                if [[ $base =~ _bin([0-9]+)_maxbin2\.f(ast)?a$ ]]; then
                    bin_id="maxbin2.${BASH_REMATCH[1]}"
                else bin_id="maxbin2.${base%_maxbin2.*}"; fi ;;
            concoct)
                if [[ $base =~ _([0-9]+)_concoct\.f(ast)?a$ ]]; then
                    bin_id="concoct.${BASH_REMATCH[1]}"
                else bin_id="concoct.${base%_concoct.*}"; fi ;;
            vamb)
                bin_core=${base%_vamb.*}; bin_core="${bin_core#${sample}_}"
                bin_id="vamb.${bin_core}" ;;
        esac
        awk -v BID="$bin_id" '/^>/{gsub(/^>/,"",$0); split($0,a," "); print a[1]"\t"BID}' "$f" >> "$out_tsv"
    done
    shopt -u nullglob
    [[ -s "$out_tsv" && $matched -eq 1 ]]
}

run_das_tool_per_sample_filtered() {
    local sample="$1" sub_out_dir="$2"
    local mags_filt_dir="${sub_out_dir}/04_MAGs_filtered"
    [[ -d "$mags_filt_dir" ]] || { log "[DAS_Tool][$sample] no MAGs_filtered dir"; return; }
    local asm
    if ! asm=$(find_assembly_for_sample "$sample"); then log "[DAS_Tool][$sample] missing assembly"; return; fi
    local work_dir="${sub_out_dir}/02_BINNING/das_tool/${sample}"
    local out_bins_dir="${work_dir}/DASTool_bins"
    [[ -d "$out_bins_dir" ]] && { log "[DAS_Tool][$sample] already exists"; return; }
    mkdir -p "$work_dir"
    local tsv_list=() labels=()
    if generate_contigs2bin_from_filtered "$sample" "$mags_filt_dir" "metabat2" "${work_dir}/metabat2.tsv"; then tsv_list+=("/work/metabat2.tsv"); labels+=("metabat2"); fi
    if generate_contigs2bin_from_filtered "$sample" "$mags_filt_dir" "maxbin2" "${work_dir}/maxbin2.tsv"; then tsv_list+=("/work/maxbin2.tsv"); labels+=("maxbin2"); fi
    if generate_contigs2bin_from_filtered "$sample" "$mags_filt_dir" "concoct" "${work_dir}/concoct.tsv"; then tsv_list+=("/work/concoct.tsv"); labels+=("concoct"); fi
    if generate_contigs2bin_from_filtered "$sample" "$mags_filt_dir" "vamb" "${work_dir}/vamb.tsv"; then tsv_list+=("/work/vamb.tsv"); labels+=("vamb"); fi
    (( ${#tsv_list[@]} >= 2 )) || { log "[DAS_Tool][$sample] <2 bin sets -> skip"; return; }
    local tsv_join label_join
    tsv_join=$(IFS=','; echo "${tsv_list[*]}")
    label_join=$(IFS=','; echo "${labels[*]}")
    log "[DAS_Tool][$sample] Running (filtered bins: $label_join) extra='${DASTOOL_EXTRA_OPTS}'"
    drun --rm --label "$DOCKER_LABEL" \
        -v "$(dirname "$asm")":/asm -v "$work_dir":/work \
        quay.io/biocontainers/das_tool:1.1.7--r44hdfd78af_1 \
        DAS_Tool -i "$tsv_join" -l "$label_join" -c /asm/$(basename "$asm") -o /work/DASTool_${sample} --write_bins --threads "$threads" ${DASTOOL_EXTRA_OPTS} \
        || { log "[DAS_Tool][$sample] ERROR"; return; }
    local prod_dir="${work_dir}/DASTool_${sample}_DASTool_bins"
    if [[ -d "$prod_dir" ]]; then
        mkdir -p "$out_bins_dir"
        mv "$prod_dir"/* "$out_bins_dir"/ 2>/dev/null || true
        rmdir "$prod_dir" 2>/dev/null || true
        log "[DAS_Tool][$sample] Bins: $(ls -1 "$out_bins_dir" | wc -l | tr -d ' ')"
    else
        log "[DAS_Tool][$sample] No output directory found"
    fi
}

run_das_tool_filtered_all() {
    local sub_out_dir="$1" COV_DIR="$2"
    (( DO_DASTOOL )) || return 0
    log "[CHECKPOINT] DAS_Tool (using MAGs_filtered)"
    local sd
    for sd in "$COV_DIR"/*; do
        (( STOP_REQUESTED )) && break
        [[ -d "$sd" ]] || continue
        run_das_tool_per_sample_filtered "$(basename "$sd")" "$sub_out_dir"
    done
}

run_drep() {
    local sub_out_dir="$1"
    local mags_dir_filt="${sub_out_dir}/04_MAGs_filtered"
    local target_dir=""
    if [[ -d "$mags_dir_filt" ]] && compgen -G "${mags_dir_filt}/*.fasta" > /dev/null; then
        target_dir="$mags_dir_filt"
    else
        local mags_dir="${sub_out_dir}/03_MAGS"
        [[ -d "$mags_dir" ]] || { log "[dRep] no MAGS directory"; return; }
        target_dir="$mags_dir"
        log "[dRep] Using MAGS/ (filtered empty)"
    fi
    local n; n=$(find "$target_dir" -maxdepth 1 -type f -name "*.fasta" | wc -l | tr -d ' ')
    (( n > 0 )) || { log "[dRep] no FASTA files"; return; }
    local drep_dir="${sub_out_dir}/02_BINNING/dRep"
    mkdir -p "$drep_dir"
    log "[dRep] Genomes=$n dir=$(basename "$target_dir") opts='${DREP_EXTRA_OPTS}'"
    drun --rm --label "$DOCKER_LABEL" \
        -v "$target_dir":/genomes \
        -v "$drep_dir":/out \
        quay.io/biocontainers/drep:3.5.0--pyhdfd78af_0 \
        bash -c "dRep dereplicate /out/drep_out -g /genomes/*.fasta -p $threads ${DREP_EXTRA_OPTS}" \
        || { log "[dRep] ERROR"; return; }
    log "[dRep] Completed."
}

collect_derep_outputs() {
    local out_dir="$1"
    local derep_root="${out_dir}/05_MAGs_derep"
    mkdir -p "${derep_root}"
    local das_target="${derep_root}/DAS_Tool"
    mkdir -p "$das_target"
    local dastool_bins_found=0
    while IFS= read -r -d '' f; do
        cp -f "$f" "$das_target/"
        ((dastool_bins_found++))
    done < <(find "${out_dir}/02_BINNING/das_tool" -type f -path "*/*DASTool_bins/*" \( -name "*.fa" -o -name "*.fasta" -o -name "*.fna" \) -print0 2>/dev/null || true)
    log "[MAGs_derep] Copied DAS_Tool bins: $dastool_bins_found -> $das_target"
    local drep_gen_dir="${out_dir}/02_BINNING/dRep/drep_out/dereplicated_genomes"
    local derep_target="${derep_root}/dRep"
    mkdir -p "$derep_target"
    local drep_copied=0
    if [[ -d "$drep_gen_dir" ]]; then
        while IFS= read -r -d '' f; do
            cp -f "$f" "$derep_target/"
            ((drep_copied++))
        done < <(find "$drep_gen_dir" -maxdepth 1 -type f \( -name "*.fa" -o -name "*.fasta" -o -name "*.fna" \) -print0 2>/dev/null || true)
    fi
    log "[MAGs_derep] Copied dRep dereplicated genomes: $drep_copied -> $derep_target"
}

post_binning_stages() {
    local out_dir="$1" COV_DIR="$2"
    gather_initial_bins "$out_dir"
    filter_mags "$out_dir" ":PRE_DASTOOL"
    run_das_tool_filtered_all "$out_dir" "$COV_DIR"
    add_dastool_bins_to_mags "$out_dir"
    filter_mags "$out_dir" ":POST_DASTOOL"
    (( DO_DREP )) && run_drep "$out_dir"
    collect_derep_outputs "$out_dir"
}

# ── run modes ──────────────────────────────────────────────────────────────
run_explicit_paired() {
    local R1="$exp_R1" R2="$exp_R2"
    local sample; sample=$(derive_sample "$(basename "$R1")")
    CURRENT_SAMPLE="$sample"
    local out_dir="${out_root}"
    log_file="${out_dir}/log.txt"; : > "$log_file"
    log "=== PAIRED sample=$sample === Tools=$BINNING_TOOLS DAS_Tool=$DO_DASTOOL dRep=$DO_DREP MEGAHIT=$RUN_MEGAHIT MIN=${MIN_MAG_SIZE}"
    local COV_DIR="${out_dir}/01_ALIGNMENT"; local BIN_DIR="${out_dir}/02_BINNING"
    mkdir -p "$COV_DIR" "$BIN_DIR"/{metabat2,maxbin2,concoct,vamb,das_tool,dRep}
    if [[ $RUN_MEGAHIT -eq 1 ]]; then
        mkdir -p "${out_dir}/00_ASSEMBLY"
        run_megahit_for_sample "$sample" "$R1" "$R2" || { log "Assembly failed — aborting."; return; }
        (( STOP_REQUESTED )) && return
    fi
    perform_alignment_pipeline "$R1" "$R2" "$sample" "$(dirname "$R1")" "$COV_DIR"
    (( STOP_REQUESTED )) && return
    run_binning_pipeline "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return
    post_binning_stages "$out_dir" "$COV_DIR"
    log "=== PAIRED COMPLETE ==="
}

run_explicit_single() {
    local SE="$exp_SE"
    local sample; sample=$(derive_sample "$(basename "$SE")")
    CURRENT_SAMPLE="$sample"
    local out_dir="${out_root}"
    log_file="${out_dir}/log.txt"; : > "$log_file"
    log "=== SINGLE sample=$sample === Tools=$BINNING_TOOLS DAS_Tool=$DO_DASTOOL dRep=$DO_DREP MEGAHIT=$RUN_MEGAHIT MIN=${MIN_MAG_SIZE}"
    local COV_DIR="${out_dir}/01_ALIGNMENT"; local BIN_DIR="${out_dir}/02_BINNING"
    mkdir -p "$COV_DIR" "$BIN_DIR"/{metabat2,maxbin2,concoct,vamb,das_tool,dRep}
    if [[ $RUN_MEGAHIT -eq 1 ]]; then
        mkdir -p "${out_dir}/00_ASSEMBLY"
        run_megahit_for_sample "$sample" "$SE" "" || { log "Assembly failed — aborting."; return; }
        (( STOP_REQUESTED )) && return
    fi
    perform_alignment_pipeline "$SE" "" "$sample" "$(dirname "$SE")" "$COV_DIR"
    (( STOP_REQUESTED )) && return
    run_binning_pipeline "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return
    post_binning_stages "$out_dir" "$COV_DIR"
    log "=== SINGLE COMPLETE ==="
}

process_reads_dir() {
    local reads_dir="$1" out_dir="$2"
    CURRENT_SUBDIR="$(basename "$reads_dir")"
    mkdir -p "$out_dir"; log_file="${out_dir}/log.txt"; : > "$log_file"
    log "==== SUBDIR START $(basename "$reads_dir") threads=$threads ===="
    log "Binning tools: $BINNING_TOOLS DAS_Tool=$DO_DASTOOL dRep=$DO_DREP MEGAHIT=$RUN_MEGAHIT MIN=${MIN_MAG_SIZE}"
    mapfile -t ALL_FASTQ < <(find "$reads_dir" -type f \( -iname "*.fastq" -o -iname "*.fastq.gz" -o -iname "*.fq" -o -iname "*.fq.gz" \) | sort)
    log "FASTQ detected: ${#ALL_FASTQ[@]}"
    [[ ${#ALL_FASTQ[@]} -eq 0 ]] && { log "No FASTQ -> skip"; return; }
    local COV_DIR="${out_dir}/01_ALIGNMENT"; local BIN_DIR="${out_dir}/02_BINNING"
    mkdir -p "$COV_DIR" "$BIN_DIR"/{metabat2,maxbin2,concoct,vamb,das_tool,dRep}
    [[ $RUN_MEGAHIT -eq 1 ]] && mkdir -p "${out_dir}/00_ASSEMBLY"
    declare -A PROCESSED=()
    local fq
    for fq in "${ALL_FASTQ[@]}"; do
        (( STOP_REQUESTED )) && break
        local bn sample r2 root_key; bn=$(basename "$fq")
        if is_r2 "$bn"; then continue; fi
        if is_r1 "$bn"; then
            r2=$(get_r2 "$fq" || true)
            sample=$(derive_sample "$bn")
            [[ "$sample" == "UNDEFINED_SAMPLE" ]] && { log "[WARN] Could not derive sample from $bn"; continue; }
            if [[ -n "$r2" ]]; then
                root_key="PAIR::$sample"; [[ -n "${PROCESSED[$root_key]:-}" ]] && continue
                PROCESSED[$root_key]=1
                if [[ $RUN_MEGAHIT -eq 1 ]]; then
                    run_megahit_for_sample "$sample" "$fq" "$r2" || { log "[MEGAHIT] skipping $sample"; continue; }
                    (( STOP_REQUESTED )) && break
                fi
                perform_alignment_pipeline "$fq" "$r2" "$sample" "$reads_dir" "$COV_DIR"
            else
                root_key="SINGLE::$sample"; [[ -n "${PROCESSED[$root_key]:-}" ]] && continue
                PROCESSED[$root_key]=1
                if [[ $RUN_MEGAHIT -eq 1 ]]; then
                    run_megahit_for_sample "$sample" "$fq" "" || { log "[MEGAHIT] skipping $sample"; continue; }
                    (( STOP_REQUESTED )) && break
                fi
                perform_alignment_pipeline "$fq" "" "$sample" "$reads_dir" "$COV_DIR"
            fi
        else
            sample=$(derive_sample "$bn")
            [[ "$sample" == "UNDEFINED_SAMPLE" ]] && { log "[WARN] Could not derive sample from $bn"; continue; }
            root_key="SINGLE::$sample"; [[ -n "${PROCESSED[$root_key]:-}" ]] && continue
            PROCESSED[$root_key]=1
            if [[ $RUN_MEGAHIT -eq 1 ]]; then
                run_megahit_for_sample "$sample" "$fq" "" || { log "[MEGAHIT] skipping $sample"; continue; }
                (( STOP_REQUESTED )) && break
            fi
            perform_alignment_pipeline "$fq" "" "$sample" "$reads_dir" "$COV_DIR"
        fi
    done
    (( STOP_REQUESTED )) && return
    run_binning_pipeline "$COV_DIR" "$BIN_DIR"
    (( STOP_REQUESTED )) && return
    post_binning_stages "$out_dir" "$COV_DIR"
    log "==== SUBDIR COMPLETE $(basename "$reads_dir") ===="
}

# ── Entry point ────────────────────────────────────────────────────────────
if [[ -n "$exp_R1" ]]; then
    run_explicit_paired
elif [[ -n "$exp_SE" ]]; then
    run_explicit_single
else
    # Exclude out_root from reads scan (handles -r . when -o is inside .)
    mapfile -t CHILD_DIRS < <(find "$reads_root" -mindepth 1 -maxdepth 1 -type d \
        | grep -vxF "$out_root" | sort)
    # Keep only dirs that actually contain FASTQ files
    _valid=()
    for _d in "${CHILD_DIRS[@]}"; do
        find "$_d" -maxdepth 1 -type f \( -iname "*.fastq*" -o -iname "*.fq*" \) -quit 2>/dev/null \
            | grep -q . && _valid+=("$_d") || true
    done
    CHILD_DIRS=("${_valid[@]}")
    if [[ ${#CHILD_DIRS[@]} -gt 0 ]]; then
        echo "[INFO] Multi-subdirectory mode: ${#CHILD_DIRS[@]}"
        for subd in "${CHILD_DIRS[@]}"; do
            process_reads_dir "$subd" "${out_root}/$(basename "$subd")"
            (( STOP_REQUESTED )) && { echo "[INFO] Interrupted."; break; }
        done
    else
        if [[ "$(realpath "$reads_root")" == "$(realpath "$out_root")" ]]; then
            echo "[ERROR] -r and -o resolve to the same directory. Use a separate output directory." >&2
            exit 1
        fi
        echo "[INFO] Flat directory mode (reads directly in $reads_root)"
        process_reads_dir "$reads_root" "$out_root"
    fi
fi

if (( STOP_REQUESTED )); then
    echo "[INFO] Interrupted (exit 130)."
    exit 130
fi
echo "[INFO] Workflow completed successfully."
