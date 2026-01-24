# Development Guide

This document describes the development workflow and tools for maintaining this Docker infrastructure.

## Task Automation with Ralph

This repository uses an automated task execution workflow powered by Claude Code for managing complex migration and maintenance tasks.

### Files

* **`TODO`** - Detailed task list with checkboxes for tracking progress
* **`progress.md`** - Migration progress log with completion history
* **`prompt.md`** - Workflow instructions for Claude Code
* **`ralph.sh`** - Automation script for executing tasks incrementally

### Prerequisites

* [Claude Code](https://claude.ai/code) CLI installed and configured
* Git repository with feature branch workflow (see CLAUDE.md)

### Usage

#### Interactive Mode (Recommended for Learning)

Run a single task with full control and review:

```bash
./ralph.sh interactive
```

This mode:
- Runs Claude Code once in interactive mode
- Allows you to review and approve each action
- Good for understanding the workflow
- No automatic permission grants

#### Automated Mode (For Batch Processing)

Run multiple tasks automatically with pre-approved permissions:

```bash
./ralph.sh 5
```

This runs up to 5 iterations in automated mode (`acceptEdits` permission). Each iteration:
1. Reads `TODO` and `progress.md` to understand context
2. Selects the most important pending task (not always the first)
3. Executes the task completely
4. Performs code review
5. Updates `TODO` and `progress.md`
6. Creates a git commit
7. Stops and waits for next invocation

**Exit conditions:**
- Iteration limit reached
- All tasks complete (outputs `<promise>COMPLETE</promise>`)
- Error encountered

### Task Priority Logic

Ralph automatically prioritizes tasks based on:

1. **Dependencies** - Tasks that unlock other tasks go first
2. **Risk** - Backups before destructive operations
3. **Logical Order** - Directory creation before file modifications
4. **Safety** - Preparation before production deployment
5. **Context** - No production changes during off-hours without permission

### Example Workflow

```bash
# Start migration with 10 task iterations
./ralph.sh 10

# Check progress
cat progress.md

# If tasks remain, run more iterations
./ralph.sh 5

# Switch to interactive mode for manual control
./ralph.sh interactive

# Review what was done
git log --oneline
cat TODO
```

### How It Works

1. **Ralph reads the context:**
   - `TODO` file contains pending tasks
   - `progress.md` shows what's been completed
   - `prompt.md` contains the workflow instructions

2. **Ralph selects the best task:**
   - Analyzes all pending tasks (unchecked items)
   - Considers dependencies and safety
   - Chooses the most appropriate next task

3. **Claude executes the task:**
   - Follows instructions in the selected task
   - Runs commands, edits files, tests changes
   - Performs code review for quality

4. **Ralph updates tracking:**
   - Marks task checkboxes complete in `TODO`
   - Writes completion summary to `progress.md`
   - Creates descriptive git commit

5. **Ralph stops and waits:**
   - Does not automatically proceed to next task
   - Allows you to review changes between iterations
   - Gives you control over the pace

### Task File Format (TODO)

Tasks in `TODO` use markdown checkboxes:

```markdown
### Task 1: Example Task Title
- [ ] First step to complete
- [ ] Second step to complete
- [ ] Third step to complete

**Commands:**
\`\`\`bash
# Example command
echo "Hello"
\`\`\`
```

When complete:
```markdown
### Task 1: Example Task Title
- [x] First step to complete
- [x] Second step to complete
- [x] Third step to complete
```

### Progress Tracking (progress.md)

After each task, Ralph appends an entry:

```markdown
---

### Task 1: Example Task Title
**Completed:** 2026-01-24 14:30 UTC
**Status:** ✓ Success

**What was done:**
- Created directory structure
- Updated configuration files
- Ran tests

**Issues encountered:** None

**Next recommended task:** Task 2 - Update middleware configuration
```

### Tips

**Start small:**
- Use interactive mode first to understand the workflow
- Run 1-2 iterations in automated mode initially
- Increase iteration count as you gain confidence

**Review frequently:**
- Check `git log` after each run
- Review `progress.md` to understand what happened
- Examine changed files before pushing to remote

**Use git branches:**
- Ralph follows CLAUDE.md git workflow
- All changes go to feature branches
- Never commits directly to master
- You must manually push and create pull requests

**For complex migrations:**
- Break into smaller tasks in `TODO`
- Run a few iterations, then review
- Continue once you're satisfied with progress

**Error handling:**
- Ralph stops on errors automatically
- Review the error output
- Fix the issue manually or update `TODO`
- Resume with `./ralph.sh <iterations>`

### Troubleshooting

**Ralph doesn't find prompt.md:**
```bash
# Make sure you're in the project directory
cd /home/jalance/Projects/docker-services
./ralph.sh interactive
```

**Tasks not being completed:**
- Check `progress.md` for error messages
- Review `git log` to see what was attempted
- Run `./ralph.sh interactive` to debug

**Script permission denied:**
```bash
chmod +x ralph.sh
```

**Want to reset task progress:**
```bash
# Manually edit TODO and uncheck boxes
vim TODO

# Or start fresh by copying from git
git checkout TODO progress.md
```

## Git Workflow

Ralph follows the git workflow defined in `CLAUDE.md`:

1. **Never commit to master directly**
2. **Always use feature branches**
3. **Include co-author attribution** in commits
4. **Push branches and create PRs** for review

See `CLAUDE.md` for complete git workflow details.

## Code Review Standards

Ralph performs automated code review checking for:

* Syntax errors
* Security issues (SQL injection, XSS, command injection, etc.)
* Best practices adherence
* Consistency with existing codebase
* Compliance with CLAUDE.md guidelines

## Additional Resources

* **CLAUDE.md** - Project guidelines and constraints for AI assistance
* **TODO** - Current task list
* **progress.md** - Completion history
* **prompt.md** - Ralph workflow instructions (for Claude Code)
