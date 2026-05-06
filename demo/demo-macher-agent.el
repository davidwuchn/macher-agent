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

  ;; Dynamically resolve the directory this script lives in
  (let* ((script-file (or load-file-name buffer-file-name))
         (demo-dir (if script-file (file-name-directory script-file) default-directory))
         (buf (get-buffer-create "*Planner*")))
    
    (with-current-buffer buf
      ;; 1. Lock the buffer to the demo directory immediately
      (setq default-directory demo-dir)
      
      (markdown-mode)
      (gptel-mode 1)

      ;; Apply the preset directive and lock in the orchestration tools
      (when (assoc "macher-agent-plan" gptel-directives)
        (setq-local gptel--system-message (alist-get "macher-agent-plan" gptel-directives))
        (make-local-variable 'gptel-tools)
        (setq gptel-tools '("spawn_subagent"
                            "write_to_buffer"
                            "execute_subagent_buffer_blocking")))

      (insert "# Macher Agent Orchestrator\n\n"))

    ;; Switch to the buffer only after the environment is fully set up
    (switch-to-buffer buf)

    ;; Pause for a second so the viewer registers the clean buffer
    (sit-for 1.0) 

    ;; Simulate the user typing the objective
    (demo-macher-agent--type "@macher-agent-plan Spawn a sub-agent. Write instructions in its buffer asking 'What is the capital of France?' and execute it with the blocking tool. The sub agent won't provide output")

    ;; Pause briefly, then fire the request to the LLM
    (sit-for 0.5)
    (gptel-send)))

(provide 'demo-macher-agent)
;;; demo-macher-agent.el ends here
