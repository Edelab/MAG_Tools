# MAG_Tools
**(Under development)**

**A modular, Docker-based toolkit for Metagenome-Assembled Genome (MAG) recovery, quality assessment, and contamination removal.**
<img width="1536" height="1024" alt="586094414-da7d09d2-e564-49b7-9cd4-b4cf9cc173b8" src="https://github.com/user-attachments/assets/48fea10b-d1e9-47ee-9071-0a31e76a1c0b" />

This pipeline was developed for the manuscritp: "Genome-resolved metagenomics of 171 leafhopper species reveals a modular microbiome architecture"

MAG_Tools wraps a curated set of bioinformatics workflows into a single entry-point script (`MAG_Tools.sh`), so you can go from raw reads or assemblies to high-quality, dereplicated MAGs with a single command — no manual environment setup required.

---

## Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Workflows](#workflows)
  - [MAG_finder](#mag_finder)
  - [MAG_summary](#mag_summary)
  - [MAG_cleaner](#mag_cleaner)
  - [MAG_rRNA](#mag_rrna)
- [Database Setup](#database-setup)
- [Output Structure](#output-structure)
- [Citation](#citation)

---

## Overview

MAG_Tools provides four independent but complementary workflows:

| Workflow | Purpose |
|----------|---------|
| `MAG_finder` | Assembly (optional) → read mapping → multi-tool binning → DAS_Tool refinement → dRep dereplication |
| `MAG_summary` | Quality assessment of MAG sets: QUAST + barrnap + CheckM v1/v2 + GUNC + combined metrics table + summary plot |
| `MAG_cleaner` | Contamination removal via coverage correlation, k-mer composition, GC content, GUNC taxonomy, and amino acid composition |
| `MAG_rRNA` | Reference-anchored MAG recovery using 16S rRNA as a taxonomic seed (barrnap → BLAST → NCBI download → minimap2 → binning → CheckM2) |

All tools run inside **Docker containers** — no Conda environments, no manual dependency installation.

---

## Requirements

- **bash** ≥ 4
- **Docker** (daemon running and accessible by the current user)
- **curl** (for NCBI FTP downloads in `MAG_rRNA`)
- Internet access for database downloads (first run only)

> **Note:** All bioinformatics tools (BWA, MetaBAT2, MaxBin2, CONCOCT, VAMB, DAS_Tool, dRep, barrnap, CheckM, CheckM2, GUNC, BLAST, minimap2, MEGAHIT, samtools, seqkit, bedtools, Prodigal) are pulled automatically as Docker images. No manual installation needed.

---

## Installation

```bash
git clone https://github.com/<your-username>/MAG_Tools.git
cd MAG_Tools
```

The entry point is `MAG_Tools.sh`. All workflows live under `workflows/`.

### Database setup

Databases are expected under `database/` relative to the `MAG_Tools.sh` script:

```
MAG_Tools/
├── MAG_Tools.sh
├── workflows/
│   ├── MAG_finder.sh
│   ├── MAG_summary.sh
│   ├── MAG_cleaner.sh
│   └── MAG_rRNA.sh
└── database/
    ├── GUNC/
    │   └── gunc_db_progenomes2.1.dmnd
    ├── CheckM2_database/
    │   └── uniref100.KO.1.dmnd
    ├── genome_metrics/
    │   └── genome_gtdb.tsv
    └── rRNAs/
        └── rRNAs.fasta          # required by MAG_rRNA auto mode
```

Databases that are not present are **auto-discovered** from the directory above. CheckM2 will download its database automatically on first use if not found.

---

## Usage

```bash
bash MAG_Tools.sh -w <workflow> [workflow options]
```

Use `-h` with any workflow to see its full help:

```bash
bash MAG_Tools.sh -w MAG_finder  -h
bash MAG_Tools.sh -w MAG_summary -h
bash MAG_Tools.sh -w MAG_cleaner -h
bash MAG_Tools.sh -w MAG_rRNA    -h
```

> **Signal handling:** Press **Ctrl+C** or **Ctrl+Z** at any time to immediately stop all running Docker containers and exit cleanly.

---

## Workflows

### MAG_finder

**Assembly → Binning → Refinement → Dereplication**

Supports three input modes and optional MEGAHIT assembly. If no assembly is provided, the tool will ask whether to run MEGAHIT automatically.

```
[0] MEGAHIT     (optional -A)  assemble reads              → 00_ASSEMBLY/
[1] BWA-MEM                    align reads → sorted BAM    → 01_ALIGNMENT/
[2] Binning                    MetaBAT2, MaxBin2, CONCOCT, VAMB → 02_BINNING/
[3] Collect                    standardise bin names        → 03_MAGS/
[4] Filter                     size filter (pre-DAS_Tool)  → 04_MAGs_filtered/
[5] DAS_Tool   (optional -D)   refine bins                 → 02_BINNING/das_tool/
[6] Re-filter                  post-DAS_Tool filter        → 04_MAGs_filtered/
[7] dRep       (optional -R)   dereplication               → 02_BINNING/dRep/
[8] Aggregate                  collect final MAGs           → 05_MAGs_derep/
```

**Examples:**

```bash
# Single paired-end sample, existing assembly
bash MAG_Tools.sh -w MAG_finder \
    -1 R1.fastq.gz -2 R2.fastq.gz \
    -a assembly.fasta -o out/ -t 20 \
    -B metabat2,maxbin2,concoct

# Let MEGAHIT assemble, then bin + dereplicate
bash MAG_Tools.sh -w MAG_finder \
    -1 R1.fastq.gz -2 R2.fastq.gz \
    -o out/ -t 20 -A \
    -B metabat2,maxbin2,concoct -D -R

# Multi-sample directory run
bash MAG_Tools.sh -w MAG_finder \
    -r reads/ -a assemblies/ -o out/ -t 16 \
    -B metabat2,maxbin2,concoct -D -R \
    -P "-comp 50 -con 10"
```

| Flag | Description |
|------|-------------|
| `-r` | Directory of reads (multi-sample, scans subdirs) |
| `-1`/`-2` | Explicit paired-end reads |
| `-s` | Single-end reads |
| `-a` | Assembly FASTA or directory (optional if `-A`) |
| `-A` | Run MEGAHIT assembly |
| `-E` | Extra MEGAHIT options |
| `-L` | Min contig length for MEGAHIT (default: 1000 bp) |
| `-B` | Binning tools: `metabat2,maxbin2,concoct,vamb` |
| `-D` | Enable DAS_Tool refinement |
| `-X` | Extra DAS_Tool options |
| `-R` | Enable dRep dereplication |
| `-P` | Extra dRep options |
| `-G` | Min MAG size in bytes (default: 50000) |

---

### MAG_summary

**Quality assessment of MAG collections**

Runs a full QC pipeline on a folder of MAG FASTAs and produces a single combined metrics table plus a multi-panel summary plot.

```
[1] QUAST          structural metrics (N50, GC%, contigs, size)
[2] barrnap        fast 16S/23S/5S rRNA prediction (seconds/genome)
[3] CheckM v1      lineage-based completeness/contamination (non-fatal)
[4] CheckM2        ML-based completeness/contamination
[5] GUNC           chimeric contamination + dominant genus
[6] Genus metrics  combined tables + z-scores + percentiles
[7] Summary plot   multi-panel PNG + SVG (completeness scatter,
                   metrics heatmap, rank lollipop, genome stats)
```

Auto-discovers CheckM2 DB, GUNC DB and `genome_gtdb.tsv` from the database folder.

```bash
bash MAG_Tools.sh -w MAG_summary \
    -d ./mags -o ./summary_out -t 16

# With species assignment
bash MAG_Tools.sh -w MAG_summary \
    -d ./mags -o ./summary_out -t 16 -S -G ./genome_gtdb.tsv
```

**Key outputs:**

| File | Content |
|------|---------|
| `06_TABLES/genome_metrics_final.tsv` | All metrics + z-scores + percentiles per MAG |
| `06_TABLES/genus_assignments.tsv` | Dominant genus per MAG (GUNC) |
| `06_TABLES/MAG_summary_plot.png` | Multi-panel quality overview |
| `06_TABLES/MAG_summary_plot.svg` | Vector version for publication |

---

### MAG_cleaner

**Contig-level contamination removal**

Identifies and removes contaminating contigs using up to five independent methods, then combines removal lists by union or intersection.

| Method | How it works |
|--------|-------------|
| `coverage` | Pearson correlation of read depth across samples; low-correlation contigs flagged |
| `kmer` | k-mer composition cosine similarity; outlier contigs flagged |
| `gc` | GC% median ± MAD×multiplier; outlier contigs flagged |
| `gunc` | GUNC contig-level taxonomy; contigs not matching dominant genus flagged |
| `aaid` | Amino acid composition similarity (Prodigal proteins); outliers flagged |

```bash
# Fast run — k-mer + GC (no reads or GUNC needed)
bash MAG_Tools.sh -w MAG_cleaner \
    -d ./mags -o ./cleaned -m kmer,gc

# Coverage + k-mer + GC
bash MAG_Tools.sh -w MAG_cleaner \
    -d ./mags -r ./reads -o ./cleaned -m coverage,kmer,gc

# All methods, intersection strategy
bash MAG_Tools.sh -w MAG_cleaner \
    -d ./mags -r ./reads -o ./cleaned \
    -m all -G ./gunc_db -c intersection
```

**Key flags:** `-m` (methods), `-c` (union/intersection), `-p/-q/-M/-a` (per-method thresholds), `-X 1` (per-method FASTAs)

---

### MAG_rRNA

**Reference-anchored MAG recovery via 16S rRNA**

Uses 16S rRNA genes as a taxonomic anchor to find and recover MAGs matching specific organisms. Three modes:

- **Auto mode:** barrnap → BLAST against rRNA DB → NCBI download → minimap2 → GUNC genus binning → CheckM2
- **`-T` mode:** user-provided single reference genome (skip barrnap/BLAST/download)
- **`-M` mode:** user-provided directory of reference genomes (one per target organism)

```bash
# Auto mode (requires rRNAs.fasta database)
bash MAG_Tools.sh -w MAG_rRNA \
    -d ./assemblies -o ./out -t 16

# User reference — find MAGs matching E. coli
bash MAG_Tools.sh -w MAG_rRNA \
    -d ./assemblies -o ./out -t 16 -T ./E_coli_ref.fna

# Multiple target organisms
bash MAG_Tools.sh -w MAG_rRNA \
    -d ./assemblies -o ./out -t 16 -M ./reference_genomes/

# With minimap2 alignment stats
bash MAG_Tools.sh -w MAG_rRNA \
    -d ./assemblies -o ./out -t 16 -T ./ref.fna -P
```

**Key flags:** `-T` (single ref), `-M` (ref dir), `-P` (minimap2 coverage), `-p` (BLAST min identity, default 90%), `-n` (max refs to download, default 10), `-Q` (skip CheckM2)

**Key outputs:**

| File | Content |
|------|---------|
| `results/*.fasta` | Recovered bin FASTAs |
| `results/bin_coverage_summary.tsv` | Size, coverage, recovery %, contigs, genus |
| `results/checkm2/` | Completeness/contamination of recovered bins |

---

## Output Structure

```
<out_dir>/
│
├── MAG_finder output
│   ├── 00_ASSEMBLY/          MEGAHIT assemblies (if -A)
│   ├── 01_ALIGNMENT/         BAM + depth files
│   ├── 02_BINNING/           Per-tool bins + DAS_Tool + dRep
│   ├── 03_MAGS/              All raw bins (standardised names)
│   ├── 04_MAGs_filtered/     Size-filtered bins
│   └── 05_MAGs_derep/        Final DAS_Tool + dRep MAGs
│
├── MAG_summary output
│   ├── 01_QUAST/
│   ├── 02_ANNOTATION/
│   ├── 03_CheckM1/
│   ├── 04_CheckM2/
│   ├── 05_GUNC/
│   └── 06_TABLES/
│       ├── genome_metrics_final.tsv
│       ├── genus_assignments.tsv
│       ├── MAG_summary_plot.png
│       └── MAG_summary_plot.svg
│
├── MAG_cleaner output
│   ├── cleaned/              Final cleaned FASTAs
│   ├── matrices/             Per-method reports + removal lists
│   ├── plots/                Correlation, k-mer, GC, AAID plots
│   └── summary/              removal_summary.tsv + per_method_counts.tsv
│
└── MAG_rRNA output
    ├── <sample>/
    │   ├── step1_barrnap/    16S rRNA sequences + GFF
    │   ├── step2_blast/      BLAST results
    │   ├── step3_ids/        NCBI accessions
    │   ├── step4_refs/       Downloaded reference FASTAs
    │   └── step5_alignments/ minimap2 PAF + GUNC output per reference
    └── results/
        ├── *.fasta           Recovered bin FASTAs
        ├── bin_coverage_summary.tsv
        └── checkm2/
```

---

## Citation

If you use MAG_Tools in your research, please cite the underlying tools used in your selected workflow:

- **BWA** — Li & Durbin, 2009
- **MetaBAT2** — Kang et al., 2019
- **MaxBin2** — Wu et al., 2016
- **CONCOCT** — Alneberg et al., 2014
- **VAMB** — Nissen et al., 2021
- **DAS_Tool** — Sieber et al., 2018
- **dRep** — Olm et al., 2017
- **QUAST** — Gurevich et al., 2013
- **barrnap** — Seemann, 2013
- **CheckM** — Parks et al., 2015
- **CheckM2** — Chklovski et al., 2023
- **GUNC** — Orakov et al., 2021
- **MEGAHIT** — Li et al., 2015
- **minimap2** — Li, 2018
- **Prodigal** — Hyatt et al., 2010
- **BLAST+** — Camacho et al., 2009

---

*MAG_Tools is developed for research use. All Docker images are sourced from [quay.io/biocontainers](https://quay.io/organization/biocontainers).*

