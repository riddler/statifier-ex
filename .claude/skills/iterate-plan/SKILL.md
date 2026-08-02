---
name: iterate-plan
description: Iterate on existing implementation plans with thorough research and updates
model: opus
argument-hint: ["path to plan file", "description of changes needed"]
---

# Iterate Implementation Plan

You are tasked with updating existing implementation plans based on user feedback. You should be skeptical, thorough, and ensure changes are grounded in actual codebase reality.

Plan iteration runs on the Opus tier per docs/workflow.md (implementation runs on Sonnet via /implement-plan).

## Initial Response

When this command is invoked:

1. **Parse the input to identify**:
   - Plan file path (e.g., `docs/plans/2026-08-02-statecharts_2-a42-parallel-exit-sets.md`)
   - Requested changes/feedback

2. **Handle different input scenarios**:

   **If NO plan file provided**:

   ```
   I'll help you iterate on an existing implementation plan.

   Which plan would you like to update? Please provide the path to the plan file (e.g., `docs/plans/2026-08-02-statecharts_2-a42-parallel-exit-sets.md`).

   Tip: You can list recent plans with `ls -lt docs/plans/ | head`
   ```

   Wait for user input, then re-check for feedback.

   **If plan file provided but NO feedback**:

   ```
   I've found the plan at [path]. What changes would you like to make?

   For example:
   - "Add a phase for ratcheting the newly passing W3C tests"
   - "Update the success criteria to include a dialyzer-clean check"
   - "Adjust the scope to exclude <invoke> handling"
   - "Split Phase 2 into two separate phases"
   ```

   Wait for user input.

   **If BOTH plan file AND feedback provided**:
   - Proceed immediately to Step 1
   - No preliminary questions needed

## Process Steps

### Step 1: Read and Understand Current Plan

1. **Read the existing plan file COMPLETELY**:
   - Use the Read tool WITHOUT limit/offset parameters
   - Understand the current structure, phases, and scope
   - Note the success criteria and implementation approach

2. **Understand the requested changes**:
   - Parse what the user wants to add/modify/remove
   - Identify if changes require codebase research
   - Determine scope of the update

### Step 2: Research If Needed

**Only spawn research tasks if the changes require new technical understanding.**

If the user's feedback requires understanding new code patterns or validating assumptions:

1. **Create a research todo list** to track the tasks

2. **Spawn parallel sub-tasks for research**:
   Use the right agent for each type of research:

   **For code investigation:**
   - **codebase-locator** - To find relevant files
   - **codebase-analyzer** - To understand implementation details
   - **codebase-pattern-finder** - To find similar patterns

   **For historical context:**
   - **thoughts-locator** - To find related research, plans, or ADRs in docs/
   - **thoughts-analyzer** - To extract insights from documents

   **Be EXTREMELY specific about directories**:
   - Include full path context in prompts to help agents locate the right files
   - Say explicitly when a task should look at `../statifier` (v1 reference)

3. **Read any new files identified by research**:
   - Read them FULLY into the main context
   - Cross-reference with the plan requirements

4. **Wait for ALL sub-tasks to complete** before proceeding

### Step 3: Present Understanding and Approach

Before making changes, confirm your understanding:

```
Based on your feedback, I understand you want to:
- [Change 1 with specific detail]
- [Change 2 with specific detail]

My research found:
- [Relevant code pattern or constraint]
- [Important discovery that affects the change]

I plan to update the plan by:
1. [Specific modification to make]
2. [Another modification]

Does this align with your intent?
```

Get user confirmation before proceeding.

### Step 4: Update the Plan

1. **Make focused, precise edits** to the existing plan:
   - Use the Edit tool for surgical changes
   - Maintain the existing structure unless explicitly changing it
   - Keep all file:line references accurate
   - Update success criteria if needed

2. **Ensure consistency**:
   - If adding a new phase, ensure it follows the existing pattern
   - If modifying scope, update "What We're NOT Doing" section
   - If changing approach, update "Implementation Approach" section
   - Maintain the distinction between automated vs manual success criteria

3. **Preserve quality standards**:
   - Include specific file paths and line numbers for new content
   - Write measurable success criteria
   - Use the ex_quality commands for automated verification:
     `mix quality --profile loop` during iteration, full `mix quality` as the
     per-phase gate, `mix quality --format json --report -` for machine-readable
     results
   - Keep language clear and actionable

### Step 5: Review

1. **Present the changes made**:

   ```
   I've updated the plan at `docs/plans/[filename].md`

   Changes made:
   - [Specific change 1]
   - [Specific change 2]

   The updated plan now:
   - [Key improvement]
   - [Another improvement]

   Would you like any further adjustments?
   ```

2. **Be ready to iterate further** based on feedback

## Important Guidelines

1. **Be Skeptical**:
   - Don't blindly accept change requests that seem problematic
   - Question vague feedback - ask for clarification
   - Verify technical feasibility with code research
   - Point out potential conflicts with existing plan phases
   - Flag changes that would contradict an accepted ADR - those need a
     direction-level decision per docs/workflow.md, not a silent plan edit

2. **Be Surgical**:
   - Make precise edits, not wholesale rewrites
   - Preserve good content that doesn't need changing
   - Only research what's necessary for the specific changes
   - Don't over-engineer the updates

3. **Be Thorough**:
   - Read the entire existing plan before making changes
   - Research code patterns if changes require new technical understanding
   - Ensure updated sections maintain quality standards
   - Verify success criteria are still measurable

4. **Be Interactive**:
   - Confirm understanding before making changes
   - Show what you plan to change before doing it
   - Allow course corrections
   - Don't disappear into research without communicating

5. **Track Progress**:
   - Track update tasks as todos if complex
   - Update todos as you complete research
   - Mark tasks complete when done

6. **No Open Questions**:
   - If the requested change raises questions, ASK
   - Research or get clarification immediately
   - Do NOT update the plan with unresolved questions
   - Every change must be complete and actionable

## Success Criteria Guidelines

When updating success criteria, always maintain the two-category structure:

1. **Automated Verification** (can be run by execution agents):
   - `mix quality --profile loop` for the iteration loop (format, compile, credo, changed-scope tests)
   - `mix quality` as the full per-phase/pre-commit gate (adds dialyzer, deps audit, full suite with coverage)
   - `mix test.regression` / `mix test.baseline add` for ratchet changes
   - Specific files that should exist

2. **Manual Verification** (requires human testing):
   - Spec-conformance judgment calls (Appendix D pseudocode diffing)
   - Behavior exercised interactively (iex, example documents)
   - Edge cases that are hard to automate
   - User acceptance criteria

## Project-Specific Code Patterns

Follow the conventions in `CLAUDE.md` and `docs/` (Appendix D naming, errors as
events, structs + MapSets, UXID identifiers, state-first argument order). Cite ADR
numbers rather than restating their reasoning.

## Sub-task Spawning Best Practices

When spawning research sub-tasks:

1. **Only spawn if truly needed** - don't research for simple changes
2. **Spawn multiple tasks in parallel** for efficiency
3. **Each task should be focused** on a specific area
4. **Provide detailed instructions** including:
   - Exactly what to search for
   - Which directories to focus on
   - What information to extract
   - Expected output format
5. **Request specific file:line references** in responses
6. **Wait for all tasks to complete** before synthesizing
7. **Verify sub-task results** - if something seems off, spawn follow-up tasks

## Example Interaction Flows

**Scenario 1: User provides everything upfront**

```
User: /iterate-plan docs/plans/2026-08-02-statecharts_2-a42-parallel-exit-sets.md - add phase for ratcheting newly passing tests
Assistant: [Reads plan, researches ratchet mechanics, updates plan]
```

**Scenario 2: User provides just plan file**

```
User: /iterate-plan docs/plans/2026-08-02-statecharts_2-a42-parallel-exit-sets.md
Assistant: I've found the plan. What changes would you like to make?
User: Split Phase 2 into two phases - one for the compiler, one for the interpreter
Assistant: [Proceeds with update]
```

**Scenario 3: User provides no arguments**

```
User: /iterate-plan
Assistant: Which plan would you like to update? Please provide the path...
User: docs/plans/2026-08-02-statecharts_2-a42-parallel-exit-sets.md
Assistant: I've found the plan. What changes would you like to make?
User: Add more specific success criteria
Assistant: [Proceeds with update]
```
