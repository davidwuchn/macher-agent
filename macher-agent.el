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

(defun macher-agent--setup-tools-advice (orig-fn fsm get-context)
  "Advise macher tool setup to use a persistent context and auto-sync with disk."
  (let* ((info (gptel-fsm-info fsm))
         (buffer (plist-get info :buffer)))
    (if (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((original-get-context get-context))
            (funcall orig-fn fsm
                     (lambda ()
                       (funcall original-get-context)
                       (unless macher-agent--persistent-context
                         (setq macher-agent--persistent-context (funcall original-get-context)))
                       (let ((ctx macher-agent--persistent-context))
                         (when ctx
                           (macher-agent--auto-sync-context ctx)
                           (let ((fsm-info (gptel-fsm-info fsm)))
                             (setf (gptel-fsm-info fsm) 
                                   (plist-put fsm-info :macher--context ctx)))
                           (setq macher--fsm-latest fsm))
                         ctx)))))
      (funcall orig-fn fsm get-context))))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)

(provide 'macher-agent)
;;; macher-agent.el ends here
