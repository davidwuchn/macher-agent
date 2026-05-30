;;; macher-agent.el --- Sandboxed, Language-Agnostic AI Workflows -*- lexical-binding: t; -*-

;; Author: Elijah Charles
;; Version: 0.5.0
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

(provide 'macher-agent)
;;; macher-agent.el ends here
