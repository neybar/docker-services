#!/bin/bash

# ralph.sh - Automated task execution workflow for Claude Code
# Usage: ./ralph.sh <iterations|interactive>

PROMPT_FILE="prompt.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}$1${NC}"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Check if prompt.md exists
if [ ! -f "$PROMPT_FILE" ]; then
    error "$PROMPT_FILE not found in current directory"
    exit 1
fi

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <iterations|interactive>"
    echo ""
    echo "Arguments:"
    echo "  iterations  - Number of times to run (1-100)"
    echo "  interactive - Run once in interactive mode (no acceptEdits)"
    echo ""
    echo "Examples:"
    echo "  $0 5           # Run 5 iterations in automated mode"
    echo "  $0 interactive # Run once interactively"
    exit 1
fi

ARG=$1

if [ "$ARG" = "interactive" ]; then
    # Interactive mode - single run without acceptEdits
    info "Running in interactive mode..."
    echo ""
    claude < "$PROMPT_FILE"
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        success "✓ Session completed successfully"
    else
        error "Session ended with errors (exit code: $EXIT_CODE)"
        exit $EXIT_CODE
    fi
else
    # Validate it's a number
    if ! [[ "$ARG" =~ ^[0-9]+$ ]]; then
        error "Argument must be a positive number or 'interactive'"
        exit 1
    fi

    ITERATIONS=$ARG

    # Sanity check on iterations
    if [ "$ITERATIONS" -lt 1 ] || [ "$ITERATIONS" -gt 100 ]; then
        error "Iterations must be between 1 and 100"
        exit 1
    fi

    info "Running in automated mode for $ITERATIONS iterations..."
    info "Exit conditions: iteration limit, <promise>COMPLETE</promise>, or error"
    echo ""

    for i in $(seq 1 "$ITERATIONS"); do
        warn "╔════════════════════════════════════════════════════════════╗"
        warn "║  Iteration $i of $ITERATIONS"
        warn "╚════════════════════════════════════════════════════════════╝"
        echo ""

        # Run claude and capture output
        OUTPUT=$(claude --permission-mode acceptEdits < "$PROMPT_FILE" 2>&1)
        EXIT_CODE=$?

        # Display output
        echo "$OUTPUT"
        echo ""

        # Check for error
        if [ $EXIT_CODE -ne 0 ]; then
            error "Claude exited with error code: $EXIT_CODE"
            error "Stopping automated execution"
            exit $EXIT_CODE
        fi

        # Check for completion marker
        if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
            success "╔════════════════════════════════════════════════════════════╗"
            success "║  ✓ COMPLETE - All tasks finished!                         ║"
            success "╚════════════════════════════════════════════════════════════╝"
            success "Completed after $i iteration(s)"
            exit 0
        fi

        # Brief pause between iterations for readability
        if [ "$i" -lt "$ITERATIONS" ]; then
            sleep 1
        fi
    done

    warn "Reached iteration limit ($ITERATIONS iterations completed)"
    info "Run again if more work remains, or check TODO file"
fi
