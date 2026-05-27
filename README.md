# macher-agent

https://github.com/user-attachments/assets/461e695a-1315-4975-bbfb-c3a411819e11

This is a collection of tools inspired by [gptel-agent](https://github.com/karthink/gptel-agent/) but using the ethos of [macher](https://github.com/kmontag/macher). 

This attempts to avoid working directly on live files and instead operates within the macher context. With the verification gate being the final patch that's output at the end of execution.

This also contains some helpers to make tools that work in the macher ephemeral context using `macher-agent-make-tool` and native sub-agent orchestration with `macher-agent-add-subagent`.

## Why macher-agent?

`macher-agent` enables an agent to execute shell commands (like `cargo check` or test suites) in an isolated sandbox against its own unsaved, in-memory edits. The macher context persists by default across auto-continuations effectively providing a continuous `macher-revise` loop by default until the objective is achieved. 

The auto sync is able to determine if patches were applied, if intermediate edits have been made or if the context is still valid. You only need to use clear to intentionally remove outstanding changes from the agent context.

You can also adopt a auto-agentic CLI style approach where a planner dynamically spins up, delegates to sub-agents entirely through tool calls. Or you could use a semi-agentic workflow, manually instantiating sub-agents and dispatching instructions yourself while still benefiting from the non-blocking, sandboxed execution.

### Emacs-native architecture mapping

* Sandboxing and isolation are handled by routing modifications strictly through a virtual memory `macher` context, culminating in a reviewable ediff patch rather than live file mutation.
* Pure decoupled execution and strict I/O adherence routing all interactions through the `macher-context` API, completely isolating the UI from underlying LLM and FSM asynchronous loops.
* Asynchronous background execution is achieved via non-blocking sub-agent commands and Finite State Machine (FSM) driven logic, keeping your editor GUI entirely responsive whilst the agent works.
* Multi-agent orchestration for complex tasks is replicated natively by allowing a planner to dynamically spin up isolated buffers, safely inherit persistent state, dispatch instructions, and await synthesised responses via tool calls.
* System integration and automated testing rely on dynamic tool creation (featuring built-in category registration and standardised error handling), running filesystem aware tools against in-memory edits to self-correct compilation errors before presenting a final patch.
* Contextual integrity in patches and state preservation mirror external versioning by embedding the continuous conversation directly into intermediate patches, ensuring the agent's logic remains tethered to the proposed code.
* Infinite task loops and token management are sustained using `gptel` episodic sliding memory to compress older transcripts into structured summaries, preventing context degradation whilst retaining the full human-readable history in your buffer.

## Installation

To integrate macher-agent into your workflow, ensure that macher and gptel are already installed and loaded (and your system has rsync installed). Then setup your use-package based on the examples below


## Example

### macher-agent-make-tool

To integrate `macher-agent` into your workflow, ensure that `macher` and `gptel` are already installed and loaded. Then, add the following `use-package` declaration to your Emacs configuration. 

This setup assumes you have [context-builder](https://github.com/igorls/context-builder) and [rtk](https://github.com/rtk-ai/rtk) available in your system path. 

```elisp
(use-package macher-agent
  :after (gptel macher)
  :config
  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "build_project_context"
                :description "Generate a read-only architectural map of the entire project. This returns structural context rather than compilable source code."
                :command-fn (lambda (_) "context-builder -y -f rs --signatures --ignore external --input . -o /dev/stdout </dev/null 2>&1")
                :output-filter (lambda (raw-output)
                                 (if (string-prefix-p "Execution failed" raw-output)
                                     raw-output
                                   (concat "CRITICAL DIRECTIVE: The following text is a read-only architectural map of the codebase. Do NOT write mock implementations for these signatures.\n\n" raw-output)))))

  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "cargo_check"
                :description "Run 'cargo check' to compile the project."
                :args nil
                :command-fn (lambda (_) "rtk cargo check </dev/null 2>&1")
                :success-fn (lambda (_) "SUCCESS: The code compiled perfectly with no errors."))
               )
  (add-to-list 'gptel-tools
               (macher-agent-make-tool
                :name "cargo_test"
                :description "Run 'cargo test' to test the project."
                :args nil
                :command-fn (lambda (_) "rtk cargo test </dev/null 2>&1")
                :success-fn (lambda (_) "SUCCESS: The tests ran perfectly with no errors."))
               ))
```

### Workspace leaking

The context an agent operates in is strictly tied to a single workspace. Using `macher-agent-add-buffer-to-scope` add buffers that could exist in other workspaces into the context.

Here we're using something like [ruskel](https://github.com/cortesi/ruskel) to generate needed insight from a discrete workspace. That it exposes through its buffer being read.
```elisp
;; to work with own rust packages
(macher-agent-make-tool
 :name "ruskel"
 :description "Ruskel generates skeletonised outlines of Rust crates."
 :category "rust-dev"
 :args (list '(:name "target" :type string :description "The target crate or module to skeletonise"))
 :command-fn (lambda (args)
               (let ((target-val (plist-get args :target)))
                 (format "ruskel %s </dev/null 2>&1" target-val))))
```
Or
```elisp
;; public crates only
(gptel-make-tool
 :name "ruskel"
 :description "Ruskel generates skeletonised outlines of Rust crates."
 :category "rust-dev"
 :args (list '(:name "target" :type string :description "The target crate or module to skeletonise"))
 :function (lambda (target)
             (shell-command-to-string (format "ruskel %s </dev/null 2>&1" target))))
```

### Agent Skills

`macher-agent` includes support for reading and parsing Agent Skills, loosely based on the [AgentSkills SKILL.md specification](https://agentskills.io/specification/SKILL.md). This system automatically converts folder-based skill structures into `gptel` directives.

A skill is defined by a `SKILL.md` file containing YAML or JSON-like frontmatter with a `name`, `description`, optional `model`, and an `allowed-tools` array. The Markdown body is treated as the system prompt instructions.

Example `SKILL.md`:
```elisp
---
name: mock-skillp
description: A testing skill
model: gpt-4o
allowed-tools: ["example-tool"]
---
You are a testing assistant. Please use the example tool when needed.
```

Or a skill using templated values:
```elisp
---
name: versioned-skill
description: A skill that uses macros
allowed-tools: []
---
#+MACRO: version (eval (with-temp-buffer (insert-file-contents "version.txt") (string-trim (buffer-string))))

The current version of this skill is {{{version}}}.
```

#### Configuration and Security
*   `macher-agent-global-skills-directory` this custom variable to a trusted directory containing global agent skills. If a tool mentioned in `allowed-tools` is not registered natively, `macher-agent` will attempt to dynamically evaluate and load its implementation script from `<global-directory>/scripts/<tool-name>.el`.
* `macher-agent` can also load skills from your active Emacs workspace (`M-x macher-agent-load-workspace-skills`). However, to maintain a secure sandbox, *scripts are ignored in workspace skills*. Workspace skills may only use tools that are already globally registered.

When an Agent Skill is selected via `gptel`'s menu ( by selecting its `name`), `macher-agent` intercepts the selection and automatically activates the required tools for that session into `gptel-tools`.

### Macher context availability

All tools built with `macher-agent-make-tool` (or `gptel-make-tool` after macher-agent has loaded) will have their category added to the evaluation list used by macher (which by default only loads the macher-tool-category). View the current macher-context real time using `macher-agent-context-tree`

<img width="708" height="727" alt="macher-agent-context-tree" src="https://github.com/user-attachments/assets/38f55b4c-4de9-4382-b87a-0586ccd0306f" />

### Agentic workflow

This workflow demonstrates how to use the planner preset to analyse a repository and seamlessly hand off the implementation details to an isolated sub-agent entirely through tool calls. Agents interact with files and buffers strictly via the `macher` virtual memory context, allowing changes to be reviewed as patches before being committed.

### Orchestration

* `spawn_subagent` - Instantiates a new, isolated sub-agent buffer locked to the current project directory, inheriting the parent's persistent virtual state.
* `delegate_tasks_to_subagents` - Writes instructions to one or more sub-agents with strict submission reminders and waits for their final synthesised responses.
* `execute_subagents` - Triggers an array of sub-agents to begin processing. Accepts an optional parameter to dictate whether the orchestrator should block and wait for completion or run them asynchronously in the background.

### Emacs Buffer Operations

* `write_buffer_in_workspace` - Proposes a change to a live Emacs buffer, creating a virtual patch for review via the `macher` context API rather than mutating the buffer immediately.
* `write_and_commit_buffer_in_workspace` - Directly overwrites an Emacs buffer and fast-forwards the context to synchronise the agent's awareness.
* `multi_edit_buffer_in_workspace` - Allows the agent to make multiple distinct exact string replacements in a single buffer in one tool call, generating a virtual patch for review.
* `read_buffer_in_workspace` - Reads the contents of a buffer directly from the persistent `macher` context, prioritising proposed virtual edits if modified during the current turn, or returning the live Emacs buffer state otherwise.
* `list_buffers_in_workspace` - Scans the current Emacs session and returns a filtered list of all active orchestrator and sub-agent buffers.
* `search_buffers_in_workspace` - Performs a regex search across all active agent buffers, returning matching lines and their locations.

### Semi-agentic workflow

Human-in-the-loop orchestration using interactive Emacs commands to manually manage your sub-agents.

* `M-x macher-agent-add-subagent` - Interactively prompts you for a name and a target directory, then spins up a dedicated, isolated sub-agent buffer locked to that specific workspace, safely inheriting the persistent context of the parent agent. Makes current agent aware of sub agents, for example allowing you to instruct it to `write_to_buffer` with plans, research etc.
* `M-x macher-agent-clear-context` - Clears the persistent memory and pending edits of the current sub-agent buffer, allowing you to start a completely fresh task without destroying the buffer itself.
* **Manual Execution** - You can manually type your instructions directly into any sub-agent buffer and trigger `gptel-send` (or `macher-implement`). The agent will still execute its tasks asynchronously in the background and generate a reviewable patch, but you remain in full control of the dispatching.

### 1. Interactive User Commands
These are the `M-x` commands designed for human-in-the-loop orchestration and workspace management.

| Command                              | Description                                                                                                                                                               |
|:-------------------------------------|:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `macher-agent-add-subagent`          | Interactively prompts for a name and directory, then spins up a dedicated, isolated sub-agent buffer locked to that workspace, inheriting the persistent context payload. |
| `macher-agent-add-buffer-to-scope`   | Manually injects an existing Emacs buffer into the current agent's persistent context payload, explicitly granting it permission to read/edit it.                         |
| `macher-agent-clear-context`         | Clears the persistent virtual memory and pending edits of the current agent or sub-agent buffer, allowing a fresh start.                                                  |
| `macher-agent-apply-patch`           | Safely applies the current patch buffer using Emacs's native `diff-mode` utilities (e.g. `diff-apply-buffer`).                                                            |
| `macher-agent-insert-patch`          | Inserts the proposed patch from the current workspace directly into the chat buffer for review.                                                                           |
| `macher-agent-apply-virtual-buffers` | Alternative buffer patching function to ediff-patch-buffer                                                                                                                |

---

### 2. Agent Tools
These are the `gptel` tools exposed to the LLM to facilitate orchestration, file operations, and buffer manipulation.

| Tool Name                              | Description                                                                                                                                                |
|:---------------------------------------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `spawn_subagent`                       | Creates a new, isolated sub-agent in the current project directory, safely inheriting the parent agent's virtual state and persistent context.             |
| `delegate_task_to_subagents`           | Writes instructions to sub-agents with strict submission reminders and waits for its final synthesised response.                                           |
| `execute_subagents`                    | Triggers an array of sub-agents to execute. Supports an optional flag to toggle between blocking the parent agent or running completely in the background. |
| `write_buffer_in_workspace`            | Proposes new content for a live Emacs buffer, routing through the `macher` context API to create a virtual patch for review.                               |
| `write_and_commit_buffer_in_workspace` | Directly overwrites an Emacs buffer and fast-forwards the context to synchronise the agent's awareness.                                                    |
| `multi_edit_buffer_in_workspace`       | Proposes multiple exact string replacements in a live Emacs buffer sequentially.                                                                           |
| `read_buffer_in_workspace`             | Reads a buffer's contents via the `macher` context, returning proposed virtual edits if modified, or the live state otherwise.                             |
| `list_buffers_in_workspace`            | Returns a filtered list of all active orchestrator and sub-agent buffers within the agent's explicitly allowed context scope.                              |
| `search_buffers_in_workspace`          | Performs a regex search across all allowed agent buffers, returning matching text and their line numbers.                                                  |
| `submit_task_result`                   | Used strictly by worker sub-agents to submit their final, synthesised answer back to the parent orchestrator.                                              |
