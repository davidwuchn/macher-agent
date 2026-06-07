;;; macher-agent.el --- Sandboxed, Language-Agnostic AI Workflows -*- lexical-binding: t; -*-

;; Author: Elijah Charles
;; Version: 0.8.0.2
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0") (macher "0.5.0"))
;; Keywords: convenience, gptel, llm, macher
;; URL: https://github.com/elij/macher-agent
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Macher-Agent provides sandboxed, language-agnostic AI workflows
;; using sub-agent orchestration and virtual 3-way file merging.
;;

;;; Code:

(require 'cl-lib)
(require 'macher)
(require 'gptel)
(require 'project)

(require 'macher-agent-api)
(require 'macher-agent-vfs-client)
(require 'macher-agent-orchestration)
(require 'macher-agent-gptel-bridge)
(require 'macher-agent-gptel-tools)

(defgroup macher-agent nil
  "Agent tools within the macher edit context ."
  :group 'gptel
  :prefix "macher-agent-")

(defvar macher-agent-active-subagents nil
  "Alist of active sub-agents and their locked directories.")

(defun macher-agent-inject-thought (instruction)
  "Interactively inject a directive while the agent is processing a tool."
  (interactive "sSteer the agent: ")
  (macher-agent-add-pending-instruction (format "USER OVERRIDE: %s" instruction))
  (message "Instruction queued! The agent will see this when its current tool finishes."))

(provide 'macher-agent)
;;; macher-agent.el ends here
