;;; demo-macher-agent.el --- Self-contained demo of macher-agent orchestration -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'macher)
(require 'gptel)
(require 'macher-agent)

;; 1. The Ghost Typing Simulator
(defun demo-macher-agent--type (text &optional speed)
  "Simulate ghost-typing TEXT into the current buffer.
SPEED is the delay between keystrokes (default 0.04 seconds)."
  (let ((delay (or speed 0.04)))
    (dolist (char (string-to-list text))
      (insert char)
      (redisplay)
      (sit-for delay))))

;; 2. The Demo Execution
(defun demo-macher-agent-run ()
  "Run the full orchestration demo programmatically in the current buffer."
  (interactive)
  
  ;; Bulletproof cleanup: Purge any lingering advice from older test runs
  (advice-remove 'macher-agent-add-subagent #'demo-macher-agent--display-subagent-advice)

  ;; Setup the current buffer for the demo
  (markdown-mode)
  (gptel-mode 1)

  ;; Apply the preset directive and lock in the orchestration tools
  (when (assoc "macher-agent-plan" gptel-directives)
    (setq-local gptel--system-message (alist-get "macher-agent-plan" gptel-directives))
    (make-local-variable 'gptel-tools)
    ;; Expose the fan-out tool so it can handle multiple targets in one turn
    (setq gptel-tools '("spawn_subagent" "delegate_tasks_to_subagents")))

  ;; Ensure we are at the bottom of the buffer on a fresh line
  (goto-char (point-max))

  ;; Pause for a second so the viewer is ready
  (sit-for 1.0) 

  ;; Simulate the user typing the objective
  (demo-macher-agent--type "@macher-agent-plan first spawn two sub-agents and then delegate the task 'What is the capital of France?' to the first, and 'What is the capital of Spain?' to the second concurrently. Show both responses.")

  ;; Pause briefly, then fire the request to the LLM
  (sit-for 0.5)
  (gptel-send))

(provide 'demo-macher-agent)
;;; demo-macher-agent.el ends here
