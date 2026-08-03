---
name: create-plan
description: Create detailed implementation plans through interactive research and iteration
model: opus
argument-hint: ["path to research doc, or beads issue ID"]
---

# Implementation Plan

You are tasked with creating detailed implementation plans through an interactive, iterative process. You should be skeptical, thorough, and work collaboratively with the user to produce high-quality technical specifications.

Planning runs on the Opus tier per docs/workflow.md (implementation runs on Sonnet via /implement-plan).

---

## MANDATORY Output Requirements

**You MUST follow these requirements exactly. Re-read this section before writing the final plan.**

### File Location

**ALWAYS** write the plan to: `docs/plans/YYMMDD-issue-id-description.md`

- `YYMMDD` = today's date
- `issue-id` = beads issue ID (omit if none)
- `description` = brief kebab-case description

Examples:
- `docs/plans/260802-st2-a42-parallel-exit-sets.md`
- `docs/plans/260802-improve-error-events.md`

**NEVER** write the plan to `.claude/`, the project root, or any other directory.

### Template Structure

The plan document **MUST** include ALL of the following sections in this order:

1. `# [Feature/Task Name] Implementation Plan` (title)
2. `## Overview` (brief description, beads issue ID)
3. `## Current State Analysis` (what exists, constraints)
4. `## Desired End State` (specification of end state, how to verify)
5. `## What We're NOT Doing` (explicit out-of-scope items)
6. `## Implementation Approach` (high-level strategy)
7. `## Phase N: [Name]` (one or more phases, each with Overview, Changes Required, and Success Criteria split into Automated/Manual Verification)
8. `## Testing Strategy` (unit, conformance, manual)
9. `## References` (source docs, related research, ADR numbers, file:line refs)

Optional sections (include if applicable): `## Performance Considerations`, `## Corpus/Ratchet Notes`

---

## Initial Response

When this command is invoked:

1. **Check if parameters were provided**:
   - If a file path was provided (research doc or other), skip the default message
   - Immediately read any provided files FULLY
   - Begin the research process
   - **Supported inputs**:
     - Research docs: `docs/research/YYMMDD-topic.md`
     - Beads issue IDs: e.g. `st2-a42` (fetch with `bd show st2-a42`)

2. **If no parameters provided**, respond with:

```
I'll help you create a detailed implementation plan. Let me start by understanding what we're building.

Please provide:
1. The task description, beads issue ID, or research document
2. Any relevant context, constraints, or specific requirements
3. Links to related research or previous implementations

I'll analyze this information and work with you to create a comprehensive plan.

Examples:
- `/create-plan st2-a42` (beads issue ID)
- `/create-plan docs/research/260802-history-restoration-flow.md`
- `/create-plan think deeply about docs/research/260802-history-restoration-flow.md`
```

Then wait for the user's input.

## Process Steps

### Step 1: Context Gathering & Initial Analysis

1. **Read all mentioned files immediately and FULLY**:
   - Research documents (e.g., `docs/research/YYMMDD-topic.md`)
   - Related implementation plans in `docs/plans/`
   - Relevant ADRs in `docs/adr/` (accepted ADRs are settled; the plan must fit them)
   - Any XML test cases or JSON/data files mentioned
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: DO NOT spawn sub-tasks before reading these files yourself in the main context
   - **NEVER** read files partially - if a file is mentioned, read it completely

   **When starting from a beads issue**:
   - Fetch it with `bd show <id>`; note dependencies and linked issues
   - Check `bd show` output for notes pointing at existing research docs

   **When starting from a research doc**:
   - Research docs contain analysis, discoveries, and recommendations
   - Use them as the foundation for the plan - they've already done the investigation
   - Focus on structuring the implementation rather than re-researching
   - Validate that recommendations are still current if the doc is old

2. **Spawn initial research tasks to gather context**:
   If a research document was not provided with full file:line details, before asking the user any questions, use specialized agents to research in parallel:

   - Use the **codebase-locator** agent to find all files related to the task
   - Use the **codebase-analyzer** agent to understand how the current implementation works
   - If relevant, use the **thoughts-locator** agent to find existing research, plans, or ADRs about this area in docs/

   These agents will:
   - Find relevant source files, configs, and tests
   - Identify the specific directories to focus on
   - Trace data flow and key functions
   - Return detailed explanations with file:line references

3. **Read all files identified by research tasks or research document**:
   - After research tasks complete, read ALL files they identified as relevant
   - Read them FULLY into the main context
   - This ensures you have complete understanding before proceeding

4. **Analyze and verify understanding**:
   - Cross-reference the issue requirements with actual code
   - For interpreter work, check the W3C Appendix D pseudocode: deviations from it
     are semantic bugs unless mechanically required (ADR-0002)
   - Identify any discrepancies or misunderstandings
   - Note assumptions that need verification
   - Determine true scope based on codebase reality

5. **Present informed understanding and focused questions**:

   ```
   Based on the issue and my research of the codebase, I understand we need to [accurate summary].

   I've found that:
   - [Current implementation detail with file:line reference]
   - [Relevant pattern or constraint discovered, e.g. an ADR that bounds the design]
   - [Potential complexity or edge case identified]

   Questions that my research couldn't answer:
   - [Specific technical question that requires human judgment]
   - [Spec interpretation question - may need direction-level review per docs/workflow.md]
   - [Design preference that affects implementation]
   ```

   Only ask questions that you genuinely cannot answer through code investigation.

### Step 2: Research & Discovery

After getting initial clarifications:

1. **If the user corrects any misunderstanding**:
   - DO NOT just accept the correction
   - Spawn new research tasks to verify the correct information
   - Read the specific files/directories they mention
   - Only proceed once you've verified the facts yourself

2. **Create a research todo list** to track exploration tasks

3. **Spawn parallel sub-tasks for comprehensive research**:
   - Create multiple Task agents to research different aspects concurrently
   - Use the right agent for each type of research:

   **For deeper investigation:**
   - **codebase-locator** - To find more specific files (e.g., "find all files that handle [specific component]")
   - **codebase-analyzer** - To understand implementation details (e.g., "analyze how [interpreter function] works")
   - **codebase-pattern-finder** - To find similar features we can model after (e.g., "how are other lowering builders structured")

   **For historical context:**
   - **thoughts-locator** - To find any research, plans, or ADRs about this area in docs/
   - **thoughts-analyzer** - To extract key insights from the most relevant documents

   **For external resources:**
   - **web-search-researcher** - To find documentation or best practices (the W3C SCXML spec, SCION semantics notes, hexdocs for saxy/predicator)

   Each agent knows how to:
   - Find the right files and code patterns
   - Identify conventions and patterns to follow
   - Look for integration points and dependencies
   - Return specific file:line references
   - Find tests and examples

4. **Wait for ALL sub-tasks to complete** before proceeding

5. **Present findings and design options**:

   ```
   Based on my research, here's what I found:

   **Current State:**
   - [Key discovery about existing code]
   - [Pattern or convention to follow]

   **Design Options:**
   1. [Option A] - [pros/cons]
   2. [Option B] - [pros/cons]

   **Open Questions:**
   - [Technical uncertainty]
   - [Design decision needed]

   Which approach aligns best with your vision?
   ```

### Step 3: Plan Structure Development

Once aligned on approach:

1. **Create initial plan outline**:

   ```
   Here's my proposed plan structure:

   ## Overview
   [1-2 sentence summary]

   ## Implementation Phases:
   1. [Phase name] - [what it accomplishes]
   2. [Phase name] - [what it accomplishes]
   3. [Phase name] - [what it accomplishes]

   Does this phasing make sense? Should I adjust the order or granularity?
   ```

   Phases should split along module boundaries where possible (parser vs
   interpreter vs corpus tooling) so they can be parallelized across worktrees
   per docs/workflow.md.

2. **Get feedback on structure** before writing details

### Step 4: Detailed Plan Writing

After structure approval:

1. **CRITICAL: You MUST write the plan to disk before presenting your summary.**
   - **Re-read the "MANDATORY Output Requirements" section at the top of this document NOW**
   - Compose the full document content following the MANDATORY template structure
   - Write the file to `docs/plans/` using the MANDATORY naming convention
   - Present the proposed file path and a brief description to the user
   - Ask the user for permission to write the file
   - Upon approval, write the file using the Write tool
   - Confirm the file was written successfully
2. **Use this template structure** (see also MANDATORY Output Requirements above):

````markdown
# [Feature/Task Name] Implementation Plan

## Overview

[Brief description of what we're implementing and why. Beads issue: st2-xxx]

## Current State Analysis

[What exists now, what's missing, key constraints discovered]

## Desired End State

[A Specification of the desired end state after this plan is complete, and how to verify it]

### Key Discoveries:
- [Important finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within, e.g. ADR number]

## What We're NOT Doing

[Explicitly list out-of-scope items to prevent scope creep]

## Implementation Approach

[High-level strategy and reasoning]

## Phase 1: [Descriptive Name]

### Overview
[What this phase accomplishes]

### Changes Required:

#### 1. [Component/File Group]
**File**: `lib/statifier/interpreter.ex`
**Changes**: [Summary of changes]

```elixir
# Specific code to add/modify
```

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (format, compile, credo, dialyzer, deps audit, full suite with coverage): `mix quality`
- [ ] Newly passing conformance tests added to the ratchet: `mix test.baseline add`

#### Manual Verification:
- [ ] Behavior matches the Appendix D pseudocode for the touched functions
- [ ] Edge case handling verified manually (e.g. via iex session)
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits while iterating; run the full `mix quality` as the phase gate. After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: [Descriptive Name]

[Similar structure with both automated and manual success criteria...]

---

## Testing Strategy

### Unit Tests:
- [What to test in test/statifier/, pattern-matching style]
- [Key edge cases]

### Conformance Tests:
- [SCION/W3C tests expected to start passing; add them to the ratchet in the same PR]

### Manual Testing Steps:
1. [Specific step to verify feature]
2. [Another verification step]
3. [Edge case to test manually]

## Performance Considerations

[Any performance implications or optimizations needed]

## Corpus/Ratchet Notes

[If applicable, corpus regeneration or passing_tests.json changes]

## References

- Source document: `docs/research/[relevant].md`
- Related ADRs: `docs/adr/NNNN-...`
- Similar implementation: `[file:line]`
- Beads issue: `st2-xxx`
````

### Step 5: Review

1. **Present the draft plan location**:

   ```
   I've created the initial implementation plan at:
   `docs/plans/YYMMDD-issue-id-description.md`

   Please review it and let me know:
   - Are the phases properly scoped?
   - Are the success criteria specific enough?
   - Any technical details that need adjustment?
   - Missing edge cases or considerations?
   ```

2. **Iterate based on feedback** - be ready to:
   - Add missing phases
   - Adjust technical approach
   - Clarify success criteria (both automated and manual)
   - Add/remove scope items

3. **Continue refining** until the user is satisfied

## Important Guidelines

1. **Be Skeptical**:
   - Question vague requirements
   - Identify potential issues early
   - Ask "why" and "what about"
   - Don't assume - verify with code

2. **Be Interactive**:
   - Don't write the full plan in one shot
   - Get buy-in at each major step
   - Allow course corrections
   - Work collaboratively

3. **Be Thorough**:
   - Read all context files COMPLETELY before planning
   - Research actual code patterns using parallel sub-tasks
   - Include specific file paths and line numbers
   - Write measurable success criteria with clear automated vs manual distinction
   - Automated steps use the ex_quality flow: `mix quality --profile loop` while
     iterating, full `mix quality` as the per-phase gate, and
     `mix quality --format json --report -` when an agent needs to route on results

4. **Be Practical**:
   - Focus on incremental, testable changes
   - Consider ratchet additions and corpus impact
   - Think about edge cases
   - Include "what we're NOT doing"

5. **Track Progress**:
   - Track planning tasks as todos
   - Update todos as you complete research
   - Mark planning tasks complete when done

6. **No Open Questions in Final Plan**:
   - If you encounter open questions during planning, STOP
   - Research or ask for clarification immediately
   - Do NOT write the plan with unresolved questions
   - The implementation plan must be complete and actionable
   - Every decision must be made before finalizing the plan

## Success Criteria Guidelines

**Always separate success criteria into two categories:**

1. **Automated Verification** (can be run by execution agents):
   - `mix quality --profile loop` for the iteration loop (format, compile, credo, changed-scope tests)
   - `mix quality` as the full per-phase gate (adds dialyzer, deps audit, full suite with coverage)
   - `mix quality --format json --report -` when results must be machine-readable
   - `mix test.regression` / `mix test.baseline add` for ratchet changes
   - Specific files that should exist

2. **Manual Verification** (requires human testing):
   - Spec-conformance judgment calls (pseudocode diffing)
   - Behavior exercised interactively (iex, example documents)
   - Edge cases that are hard to automate
   - User acceptance criteria

**Format example:**

```markdown
### Success Criteria:

#### Automated Verification:
- [ ] Full gate passes: `mix quality`
- [ ] Newly passing SCION tests ratcheted: `mix test.baseline add`

#### Manual Verification:
- [ ] `compute_exit_set/3` matches the Appendix D pseudocode line-for-line
- [ ] History restoration behaves correctly on the example document
- [ ] error.execution events carry useful reasons
```

## Common Patterns

### For New SCXML Elements

- Add the lowering builder under `lib/statifier/lowering/`
- Extend the Document structs and validator checks
- Extend the compiler/Machine if the element affects runtime structure
- Wire interpreter behavior (keeping Appendix D structure)
- Add internal tests plus ratchet any newly passing conformance tests

### For Interpreter Features

- Start from the Appendix D pseudocode for the affected functions
- Port literally; note any mechanical deviation with an inline comment
- Effects out, never side effects in the core (ADR-0003)
- Verify against SCION/W3C tests before ratcheting

### For Refactoring

- Document current behavior
- Plan incremental changes
- Keep the conformance suites green throughout
- Include ratchet/regression strategy

## Project-Specific Code Patterns

Follow the conventions in `CLAUDE.md` and `docs/` (Appendix D naming, errors as
events, structs + MapSets, UXID identifiers, state-first argument order). Cite ADR
numbers rather than restating their reasoning.

## Sub-task Spawning Best Practices

When spawning research sub-tasks:

1. **Spawn multiple tasks in parallel** for efficiency
2. **Each task should be focused** on a specific area
3. **Provide detailed instructions** including:
   - Exactly what to search for
   - Which directories to focus on
   - What information to extract
   - Expected output format
4. **Be EXTREMELY specific about directories**:
   - Include the full path context in your prompts to help agents locate the right files
   - Say explicitly when a task should look at `../statifier` (v1 reference) versus this repo
5. **Specify read-only tools** to use
6. **Request specific file:line references** in responses
7. **Wait for all tasks to complete** before synthesizing
8. **Verify sub-task results**:
   - If a sub-task returns unexpected results, spawn follow-up tasks
   - Cross-check findings against the actual codebase
   - Don't accept results that seem incorrect

Example of spawning multiple tasks:

```python
# Spawn these tasks concurrently:
tasks = [
    Task("Research interpreter exit-set functions", interpreter_research_prompt),
    Task("Find lowering builder patterns", lowering_research_prompt),
    Task("Locate affected conformance tests", corpus_research_prompt),
    Task("Check internal test patterns", test_research_prompt)
]
```

## Example Interaction Flow

### From a beads issue:

```
User: /create-plan st2-a42
Assistant: Let me fetch the details for issue st2-a42...

[Runs bd show st2-a42]

Based on the issue, I understand we need to implement parallel-state exit set computation. Let me research the codebase...

[Interactive process continues...]
```

### From a research document:

```
User: /create-plan docs/research/260802-history-restoration-flow.md
Assistant: Let me read that research document completely first...

[Reads file fully]

Based on your research, I see you've already traced how history restoration flows through compute_entry_set.
The research includes file references and implementation notes. Let me structure this into an implementation plan...

[Proceeds with less initial research since the doc already contains findings]
```

---

## Pre-Write Checklist

**STOP. Before writing the plan file, verify ALL of the following:**

- [ ] File path is `docs/plans/YYMMDD-...md` (NOT `.claude/`, NOT project root)
- [ ] File name follows format: `YYMMDD-issue-id-kebab-description.md`
- [ ] Document starts with `# [Name] Implementation Plan`
- [ ] Contains ALL mandatory sections: Overview, Current State Analysis, Desired End State, What We're NOT Doing, Implementation Approach, Phase(s), Testing Strategy, References
- [ ] Each Phase has Success Criteria split into Automated Verification and Manual Verification
- [ ] Automated criteria use the ex_quality commands (`mix quality --profile loop`, `mix quality`)
- [ ] No unresolved open questions remain in the document
