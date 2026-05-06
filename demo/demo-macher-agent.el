;;; demo-macher-agent.el --- Self-contained demo of macher-agent orchestration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'macher)
(require 'gptel)
(require 'macher-agent)

;; 1. The Ghost Typing Simulator
;; This replaces the missing macher--demo utilities with a reliable text insertion loop.
(defun demo-macher-agent--type (text &optional speed)
  "Simulate ghost-typing TEXT into the current buffer.
SPEED is the delay between keystrokes (default 0.04 seconds)."
  (let ((delay (or speed 0.04)))
    (dolist (char (string-to-list text))
      (insert char)
      (redisplay)
      (sit-for delay))))

;; 2. The Window Visibility Hook
(defun demo-macher-agent--display-subagent-advice (name &rest _)
  "Display the newly created sub-agent buffer in the other window."
  (let ((buf-name (format "*macher-agent: %s*" name)))
    (when-let ((buf (get-buffer buf-name)))
      (with-selected-window (next-window (selected-window) nil nil)
        (switch-to-buffer buf)))))

(advice-add 'macher-agent-add-subagent :after #'demo-macher-agent--display-subagent-advice)

;; 3. The Demo Execution
(defun demo-macher-agent-run ()
  "Run the full orchestration demo programmatically."
  (interactive)
  ;; Set up a clean 2-window layout
  (delete-other-windows)
  (split-window-right)

  ;; Programmatically prepare the Planner buffer (vastly safer than driving the minibuffer)
  (let ((buf (get-buffer-create "*Planner*")))
    (switch-to-buffer buf)
    (markdown-mode)
    (gptel-mode 1)

    ;; Apply the preset directive and lock in the orchestration tools
    (when (assoc "macher-agent-plan" gptel-directives)
      (setq-local gptel--system-message (alist-get "macher-agent-plan" gptel-directives))
      (make-local-variable 'gptel-tools)
      (setq gptel-tools '("read_file_in_workspace" 
                          "list_directory_in_workspace" 
                          "search_in_workspace"
                          "get_current_time"
                          "build_project_context" 
                          "spawn_subagent"
                          "write_to_buffer"
                          "execute_subagent_buffer_blocking")))

    (insert "# Macher Agent Orchestrator\n\n")
    ;; Pause for a second so the viewer registers the clean buffer
    (sit-for 1.0) 

    ;; Simulate the user typing the objective
    (demo-macher-agent--type "@macher-agent-plan Spawn a sub-agent named 'geo'. Write instructions in its buffer asking 'What is the capital of France?' and execute it with the blocking tool.")

    ;; Pause briefly, then fire the request to the LLM
    (sit-for 0.5)
    (gptel-send)))

(provide 'demo-macher-agent)
;;; demo-macher-agent.el ends here
