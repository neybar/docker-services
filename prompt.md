# Task Execution Workflow

## Instructions

1. **Read and Analyze TODO and Progress**
   - Read the entire `TODO` file
   - Read the `progress.md` file to understand what has been completed
   - Analyze all pending tasks (those without `[x]` checkmarks)
   - Identify the most important task to work on next
   - **Important:** The most important task is NOT always the first uncompleted task
   - Consider dependencies, risk, and logical order
   - If there are no more pending tasks, print: `<promise>COMPLETE</promise>` and stop

2. **Execute ONLY One Task**
   - Work on the single most important task you identified
   - Complete ALL checkboxes within that task
   - Do NOT proceed to any other tasks
   - Follow all instructions and commands specified in the task

3. **Code Review**
   - After completing the task, perform a thorough code review
   - Check for:
     - Syntax errors
     - Security issues
     - Best practices
     - Consistency with existing codebase
     - Adherence to CLAUDE.md guidelines

4. **Update Documentation**
   - Review the `README.md` file
   - Update it if the completed task requires documentation changes
   - If no updates needed, skip this step

5. **Update TODO**
   - Mark all checkboxes for the completed task as `[x]`
   - Add any new tasks discovered during execution
   - Update task descriptions if needed

6. **Write Progress Report**
   - Update `progress.md` with a summary of the completed task
   - Include:
     - Date and time of completion
     - Task number and title
     - What was accomplished
     - Any issues encountered and how they were resolved
     - Next recommended task (if applicable)
   - Keep the format consistent and chronological

7. **Create Git Commit**
   - Stage relevant changes
   - Create a descriptive commit message following the project's conventions
   - Include `Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>`
   - **Do NOT push** unless explicitly instructed

8. **Stop Processing**
   - After creating the commit, STOP
   - Do NOT proceed to the next task
   - Do NOT analyze remaining tasks
   - Wait for next invocation

## Task Priority Guidelines

When selecting the most important task, consider:

1. **Dependencies:** Tasks that unlock other tasks should be done first
2. **Risk:** Preparation and backup tasks before destructive operations
3. **Logical Order:** Directory setup before file modifications
4. **Safety:** Testing and validation before production deployment
5. **Context:** Don't start production tasks during off-hours without explicit permission

## Example Task Selection Logic

- If "Create backup" and "Modify production config" are both pending → Choose "Create backup" first
- If "Update config file" and "Create directory structure" are both pending → Choose "Create directory structure" first
- If "Execute migration" and "Test services" are both pending → Choose "Execute migration" first
- If only "Monitor for 24 hours" remains → This requires time, not immediate action. Ask user if they want to proceed or wait.

## Commit Message Format

```
<Task title>

<Detailed description of changes>
- Change 1
- Change 2
- Change 3

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

## Important Notes

- **ONE TASK ONLY:** Complete one task per invocation
- **STOP AFTER COMMIT:** Do not continue to next task automatically
- **ASK FOR PERMISSION:** For production-impacting tasks (deployments, migrations), confirm with user before executing
- **FOLLOW CLAUDE.md:** Always adhere to project guidelines in CLAUDE.md
- **GIT WORKFLOW:** Never commit directly to master; use feature branches
