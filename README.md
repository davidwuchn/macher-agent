# macher-agent

An Emacs-native LLM agent harness with isolated sandboxing, asynchronous sub-agent orchestration, and a strict 3-tier virtual file system.

https://github.com/user-attachments/assets/461e695a-1315-4975-bbfb-c3a411819e11

## Table of Contents
1. [Core Concepts and Architecture](#core-concepts--architecture)
2. [Quick Start and Installation](#quick-start-and-installation)
3. [Tool Creation and The Sandbox](#tool-creation--the-sandbox)
4. [Agent Skills and Registration](#agent-skills--registration)
5. [Advanced Context (Media and Instructions)](#advanced-context-media--instructions)
6. [Orchestrating Workflows](#orchestrating-workflows)
7. [Command Reference](#command-reference)

## Core Concepts and Architecture

```mermaid
graph TD
    gptel --> macher
    macher --> macher-agent

    subgraph world [World]
        direction LR
        block
        emacs-buffer[buffer]
    end

    subgraph macher-context [Macher Context]
        files
        buffer
        media
    end

    gptel --> |gated| world
    macher --> files
    macher-context --> |ediff| world
    macher-agent --> buffer
    macher-agent --> media
    macher-context -->|macher-agent<br /> continuations + tools| macher-context 

```

- `gptel` (LLM/UI) provides the chat interface, API communication, and tool-call parsing. `gptel` is treated as a complete black box.
- `macher-agent` (harness) sits in the middle. It parses agent tools, orchestrates sub-agents, and bridges the LLM UI with the file system.
- `macher` (ephemeral context) serves as the Virtual File System (VFS) engine. It tracks all edits in hidden memory buffers and strictly bounds all agent actions.

The agent interacts with a `macher` context rather than live files. This environment records file and buffer modifications. These changes are presented as a diff patch (through ediff) for your review before any disk modifications occur. If the agent needs to use an external CLI tool (like `rg` or `cargo`), `macher-agent` automatically overlays the context onto a temporary directory to allow safe execution.

<img width="708" height="727" alt="macher-agent-context-tree" src="https://github.com/user-attachments/assets/38f55b4c-4de9-4382-b87a-0586ccd0306f" />

## Quick Start and Installation

`macher-agent` requires `macher` and `gptel`. It also requires `rsync` on your system path.

```elisp
(use-package macher-agent
  :after (gptel macher)
  :custom
  ;; You can place custom SKILL.md and .el scripts in this directory:
  (macher-agent-global-skills-directory (expand-file-name "skills" user-emacs-directory))
  :config
  ;; Initialise skills to populate gptel-directives and macher-agent-tools-registry
  (macher-agent-initialize-skills))

;; If you want to use the default skill pack:
(use-package macher-agent-skills
  :after macher-agent)
```

## Tool Creation and The Sandbox

`macher-agent` provides a declarative DSL for defining tools: `macher-agent-make-tool`. This macro handles `condition-case` errors automatically, and bridges directly into the `macher` context middleware.

Here is an example demonstrating a tool that executes a shell command safely across the workspace. By simply returning a string from your `:command-fn`, the execution router implicitly treats it as a shell command and executes it inside a temporary virtual sandbox.

```elisp
(macher-agent-make-tool macher-agent-cargo-check-tool
  "Run 'cargo check' to compile the project."
  :category "rust"
  :args nil
  :command-fn (lambda (_payload)
                "rtk cargo check </dev/null 2>&1")
  :success-fn (lambda (output)
                (if (string-match-p "error\\[" output)
                    output
                  (concat "SUCCESS: The code compiled perfectly with no errors.\n\n=== COMPILER OUTPUT ===\n" output))))
```

## Agent Skills and Registration

Agent Skills are defined via folders containing a `SKILL.md` file. 

A skill includes YAML or JSON frontmatter specifying a name, description, an optional model override, and an array of required tools (`allowed-tools`). The Markdown body provides the system prompt. 

### Custom User Skills
You can build custom skills and Emacs Lisp tools inside your global skills directory (for example `~/.config/emacs/skills/`). 
- If a skill specifies `allowed-tools: ["my_tool"]`, `macher-agent` will automatically search for `~/.config/emacs/skills/scripts/my_tool.el`.
- Script files must contain exactly one `macher-agent-make-tool` call and are dynamically evaluated with strict lexical scoping.
- If a `model` property is provided (for example`model: "Qwen3.6-35B-A3B"`), it is extracted and bound locally to `gptel-model` for that specific agent, ensuring requests are automatically routed to the correct LLM backend.

### Example Skill

Below is an example of a `SKILL.md` file that overrides the default model and references a custom tool:

```markdown
---
name: "python-test-runner"
description: "Runs unit tests and analyses failures. Trigger this when asked to verify Python code or run tests."
model: "Qwen3.6-35B-A3B"
allowed-tools:
  - "run_pytest"
---
# Python Test Runner

You are an expert quality assurance engineer. When asked to verify code, use the `run_pytest` tool to execute the test suite in the virtual workspace. If tests fail, analyse the output and propose fixes.
```

## Advanced Context (Media and Instructions)

`macher-agent` can safely steer the LLM and pass multi-modal media without polluting the Emacs UI:

- `M-x macher-agent-inject-thought` allows the injecting of throughts during agent continuations
- `macher-agent` dynamically reads agent skills llowing agents to iteratively build and reload `.el` tools from the virtual file system before their payload hits the network.
- The `macher` context intercepts images generated or downloaded by tools. The agent injects the media directly into the LLM's pre-flight payload letting agents read images as needed.

## Orchestrating Workflows

You can run workflows autonomously or manually.

In an autonomous setup, a planner agent creates sub-agents, delegates tasks, and waits for a response via tool calls. The parent agent can run these sub-agents in the background using the event-bus orchestrator (`macher-agent-execute-parallel`), guaranteeing the sub-agents share the parent's uncommitted VFS memory.

Alternatively, you can create sub-agents manually using interactive commands. You type instructions into the sub-agent buffer and trigger it. The sub-agent runs asynchronously and generates a patch.

## Command Reference

### Interactive Commands

| Command                                  | Description                                                              |
|------------------------------------------|--------------------------------------------------------------------------|
| `M-x macher-agent-add-subagent`          | Prompts for a name and directory, creating an isolated sub-agent buffer. |
| `M-x macher-agent-add-buffer-to-scope`   | Adds an existing Emacs buffer to the agent's context.                    |
| `M-x macher-agent-clear-context`         | Clears the virtual memory and pending edits.                             |
| `M-x macher-agent-apply-patch`           | Evaluates and applies the patch buffer.                                  |
| `M-x macher-agent-insert-patch`          | Inserts the workspace patch into the chat buffer.                        |
| `M-x macher-agent-apply-virtual-buffers` | Applies the virtual edits directly.                                      |
| `M-x macher-agent-initialize-skills`     | Scans the skills directory, compiling presets and tools into memory.     |

### LLM Tools

| Tool                                   | Description                                                     |
|----------------------------------------|-----------------------------------------------------------------|
| `spawn_subagent`                       | Creates a sub-agent inheriting the parent's virtual state.      |
| `delegate_tasks_to_subagents`          | Dispatches instructions to sub-agents and waits for a response. |
| `execute_subagents`                    | Starts sub-agent processing.                                    |
| `submit_task_result`                   | Submits final output from a worker to the parent.               |
| `write_buffer_in_workspace`            | Modifies a buffer via the virtual context.                      |
| `multi_edit_buffer_in_workspace`       | Performs string replacements in a buffer.                       |
| `read_buffer_in_workspace`             | Retrieves buffer contents from the persistent context.          |
| `read_media_in_workspace`              | Reads an image into the agent's context.                        |
| `list_buffers_in_workspace`            | Lists active agent buffers in scope.                            |
| `search_in_workspace`                  | Searches across accessible agent workspace.                     |
