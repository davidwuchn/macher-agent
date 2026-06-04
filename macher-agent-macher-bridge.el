;;; macher-agent-macher-bridge.el --- Bridge to Macher Core -*- lexical-binding: t; -*-

(require 'macher)
(require 'cl-lib)

(declare-function macher-agent-workspace-project-root "macher-agent-vfs-client")
(declare-function macher-agent-workspace-p "macher-agent-vfs-client")
(declare-function macher-agent--prepare-patch-buffer "macher-agent-vfs-client")
(declare-function macher--generate-patch-diff "macher")

(defun macher-agent--get-workspace-root (ws)
  (if (and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
      (macher-agent-workspace-project-root ws)
    (if (fboundp 'macher--workspace-root)
        (macher--workspace-root ws)
      nil)))

(defun macher-agent--get-workspace-name (ws)
  (if (and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
      (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root ws)))
    (if (fboundp 'macher--workspace-name)
        (macher--workspace-name ws)
      nil)))

(defalias 'macher-agent--get-buffer 'macher--get-buffer)
(defalias 'macher-agent--patch-buffer-setup 'macher--patch-buffer-setup)
(defalias 'macher-agent--build-patch 'macher--build-patch)

(defun macher-agent--fix-workspace-hash (orig-fn workspace &rest args)
  "Prevent `macher--workspace-hash` from crashing on the agent workspace struct."
  (if (and (consp workspace)
           (eq (car workspace) 'agent)
           (not (stringp (cdr workspace)))) ; Ensure we don't double-process
      ;; Pass a string-based version to the original hashing function
      (apply orig-fn (cons 'agent (macher-agent-workspace-project-root (cdr workspace))) args)
    ;; Otherwise, run normally
    (apply orig-fn workspace args)))

(advice-add 'macher--workspace-hash :around #'macher-agent--fix-workspace-hash)

(defun macher-agent--populate-patch-buffer (buffer context)
  "Generate a deterministic diff via `macher--generate-patch-diff` and write to BUFFER."
  (with-current-buffer buffer
    (erase-buffer) ; CRITICAL: Clear any hallucinated LLM text
    (let* ((workspace (macher-agent--get-context-workspace context))
           (proj-name (if workspace 
                          (macher-agent--get-workspace-name workspace)
                        "unknown"))
           (patch-id
            (let ((chars "abcdefghijklmnopqrstuvwxyz0123456789")
                  (result ""))
              (dotimes (_ 8 result)
                (let ((idx (random (length chars))))
                  (setq result (concat result (substring chars idx (1+ idx))))))))
           (prompt (macher-agent--get-context-prompt context))
           (header (format "# Patch ID: %s\n# Project: %s\n" patch-id proj-name))
           ;; Call the deterministic core generation function
           (diff-text (if (fboundp 'macher--generate-patch-diff)
                          (macher--generate-patch-diff context)
                        (error "macher--generate-patch-diff is not loaded from core"))))

      (insert header)

      (if (string-empty-p diff-text)
          (insert "\n# No changes were made to any files.\n")
        (insert "\n" diff-text))

      (when prompt
        (insert
         "\n# -----------------------------\n"
         (format "# PROMPT for patch ID %s:\n" patch-id)
         "# -----------------------------\n"
         (replace-regexp-in-string "^" "# " prompt)
         "\n")))))

;; Override the core build-patch to skip LLM text injection and use our generator
(defun macher-agent--build-patch (context &optional _fsm)
  "Build the standard patch deterministically, bypassing LLM text."
  (let* ((workspace (macher-agent--get-context-workspace context))
         (root-dir (if (and (consp workspace) (eq (car workspace) 'agent))
                       (macher-agent-workspace-project-root (cdr workspace))
                     (or (and workspace (fboundp 'macher--workspace-root) (macher--workspace-root workspace)) 
                         default-directory)))
         (result (macher-agent--get-buffer "patch" root-dir t)))
    (when result
      (let ((target-buffer (car result)))
        (with-current-buffer target-buffer
          (macher-agent--patch-buffer-setup)
          (run-hooks 'macher-patch-buffer-setup-hook)
          (erase-buffer) ;; Wipe bad LLM text
          (insert (if (fboundp 'macher--generate-patch-diff)
                      (macher--generate-patch-diff context)
                    "")))
        target-buffer))))

(defun macher--patch-prepare-metadata (context _fsm callback)
  "Add metadata to the current patch buffer content for CONTEXT.
CALLBACK must be called when preparation is complete."
  (macher-agent--prepare-patch-buffer (current-buffer) context)
  (funcall callback))

(cl-defun macher-agent--make-vfs-context (&key workspace contents)
  (macher--make-context :workspace workspace :contents contents))

(defun macher-agent--get-context-workspace (ctx)
  (let ((ws (and ctx (fboundp 'macher-context-workspace) (macher-context-workspace ctx))))
    (if (and (consp ws) (eq (car ws) 'agent))
        (cdr ws)
      ws)))

(defun macher-agent--set-context-workspace (ctx ws)
  (setf (macher-context-workspace ctx) ws))

(defun macher-agent--get-context-contents (ctx)
  (and ctx (fboundp 'macher-context-contents) (macher-context-contents ctx)))

(defun macher-agent--set-context-contents (ctx val)
  (setf (macher-context-contents ctx) val))

(defun macher-agent--get-context-dirty-p (ctx)
  (and ctx (fboundp 'macher-context-dirty-p) (macher-context-dirty-p ctx)))

(defun macher-agent--set-context-dirty-p (ctx val)
  (setf (macher-context-dirty-p ctx) val))

(defun macher-agent--get-context-prompt (ctx)
  (and ctx (fboundp 'macher-context-prompt) (macher-context-prompt ctx)))

(defun macher-agent--get-fsm-latest ()
  (bound-and-true-p macher--fsm-latest))

(provide 'macher-agent-macher-bridge)
;;; macher-agent-macher-bridge.el ends here
