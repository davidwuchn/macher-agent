;;; macher-agent.el --- Sandboxed, Language-Agnostic AI Workflows -*- lexical-binding: t; -*-

;; Author: Elijah Charles
;; Version: 0.0.3
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0") (macher "0.5.0"))
;; Keywords: convenience, gptel, llm, macher
;; URL: https://github.com/elij/macher-agent
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'macher)
(require 'gptel)
(require 'project)

(require 'macher-agent-context)
(require 'macher-agent-async)
(require 'macher-agent-orchestration)
(require 'macher-agent-context-tools)
(require 'macher-agent-gptel-tools)

(defvar macher-agent-active-subagents nil
  "Alist of active sub-agents and their locked directories.")

(defvar macher-context-resolved-functions nil
  "Abnormal hook run when a macher context is lazily resolved for a request.

Functions are called with two arguments: (CONTEXT FSM).
Functions can be used to modify the CONTEXT object, trigger side-effects,
or update the FSM state.")

(defun macher-agent--simulate-resolved-hook-advice (orig-fn fsm get-context)
  "Simulate an upstream hook that fires when the context is resolved."
  (let ((wrapped-get-context
         (lambda ()
           (let ((ctx (funcall get-context)))
             ;; 1. Fire our simulated upstream hook
             (run-hook-with-args 'macher-context-resolved-functions ctx fsm)
             
             ;; 2. Return the context from the FSM (in case a hook function swapped it)
             (plist-get (gptel-fsm-info fsm) :macher--context)))))
    (funcall orig-fn fsm wrapped-get-context)))

(advice-add 'macher--setup-tools :around #'macher-agent--simulate-resolved-hook-advice)

(defun macher-agent-persist-context-hook (ctx fsm)
  "Maintain a persistent context and sync it with the disk."
  (when ctx
    ;; Capture the initial context if we don't have one yet
    (unless macher-agent--persistent-context
      (setq macher-agent--persistent-context ctx))
    
    (let ((persistent-ctx macher-agent--persistent-context))
      ;; Perform custom auto-sync
      (macher-agent--auto-sync-context persistent-ctx)
      
      ;; Override the newly generated context with persistent one
      (let ((fsm-info (gptel-fsm-info fsm)))
        (setf (gptel-fsm-info fsm) 
              (plist-put fsm-info :macher--context persistent-ctx)))
      
      ;; Keep the global tracker updated
      (setq macher--fsm-latest fsm))))

;; Attach logic to the new hook
(add-hook 'macher-context-resolved-functions #'macher-agent-persist-context-hook)

(provide 'macher-agent)
;;; macher-agent.el ends here
