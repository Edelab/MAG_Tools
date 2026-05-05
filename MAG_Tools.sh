#!/usr/bin/env bash

set -euo pipefail

WORKFLOW=""
ARGS=()

WORKFLOW_DIR="$(dirname "$0")/workflows"

show_help() {
    cat << EOF

================================================================================
 MAG_Tools - Centralized Workflows for Metagenome-Assembled Genomes (MAGs)
================================================================================

Description:
    MAG_Tools integrates different pipelines for recovery, cleaning, and analysis
    of MAGs from metagenomic data.

Usage:
    bash MAG_Tools.sh -w <workflow> [workflow_options]

Options:
    -w <workflow>      Name of the workflow to run (see below).
    -h                 Show this help menu.

Available workflows (use '-h' after a workflow for details):

    MAG_finder     : Recover MAGs using classical binning tools (MetaBAT2, MaxBin2, Concoct).
    MAG_rRNA       : Recover MAGs using a reference-based approach with an rRNA database.
    MAG_cleaner    : Remove MAG contamination using a depth/coverage approach.
    MAG_summary    : Summarize and describe MAGs, including metrics, CheckM, GUNC, NCBI.

For workflow-specific help, use:
    bash MAG_Tools.sh -w <workflow> -h

Example:
    bash MAG_Tools.sh -w MAG_finder -r reads_dir -a assemblies_dir -o output_dir -t 12

EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# Minimal new argument parser: let -w eat the next value, pass everything else as ARGS.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w)
            WORKFLOW="$2"
            shift 2
            ;;
        -h|--help)
            # Only show main help if no workflow is selected
            if [[ -z "${WORKFLOW:-}" ]]; then
                show_help
                exit 0
            else
                # Pass -h to workflow
                ARGS+=("$1")
                shift
            fi
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ -z "$WORKFLOW" ]]; then
    show_help
    exit 1
fi

WORKFLOW_SCRIPT="${WORKFLOW_DIR}/${WORKFLOW}.sh"
if [[ ! -f "$WORKFLOW_SCRIPT" ]]; then
    echo "[ERROR] Workflow script not found: $WORKFLOW_SCRIPT"
    exit 1
fi

# Pass all remaining ARGS (including -h) to workflow
bash "$WORKFLOW_SCRIPT" "${ARGS[@]}"
