;;; macher-agent-macher-bridge.el --- Bridge to Macher Core -*- lexical-binding: t; -*-

(require 'macher)
(require 'cl-lib)

(declare-function macher-agent-workspace-project-root "macher-agent-vfs-client")
(declare-function macher-agent-workspace-p "macher-agent-vfs-client")
(declare-function macher-agent--prepare-patch-buffer "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")
(declare-function macher--generate-patch-diff "macher")

(defcustom macher-agent-patch-display-function #'macher-agent-default-patch-display
  "Function used to display the generated patch buffer.
It is called with one argument: the target patch buffer."
  :type 'function
  :group 'macher-agent)

(defun macher-agent-default-patch-display (buffer)
  "Default function to display the agent's patch BUFFER using diff-mode."
  (with-current-buffer buffer
    (unless (derived-mode-p 'diff-mode)
      (diff-mode))
    (goto-char (point-min)))
  (display-buffer buffer))

(defun macher-agent--get-workspace-root (ws)
  "Safely extract the root directory from any workspace representation."
  (cond
   ((and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
    (macher-agent-workspace-project-root ws))
   ((and (consp ws) (eq (car ws) 'agent) (not (stringp (cdr ws))))
    (macher-agent-workspace-project-root (cdr ws)))
   ((fboundp 'macher--workspace-root)
    (macher--workspace-root ws))
   (t nil)))

(defun macher-agent--get-workspace-name (ws)
  "Safely extract the workspace name from any workspace representation."
  (cond
   ((and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root ws))))
   ((and (consp ws) (eq (car ws) 'agent) (not (stringp (cdr ws))))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root (cdr ws)))))
   ((fboundp 'macher--workspace-name)
    (macher--workspace-name ws))
   (t "unknown")))

(defalias 'macher-agent--get-buffer 'macher--get-buffer)
(defalias 'macher-agent--patch-buffer-setup 'macher--patch-buffer-setup)

(defun macher-agent--fix-workspace-hash (orig-fn workspace &rest args)
  "Prevent `macher--workspace-hash` from crashing on the agent workspace struct."
  (if (and (consp workspace)
           (eq (car workspace) 'agent)
           (recordp (cdr workspace))
           (eq (type-of (cdr workspace)) 'macher-agent-workspace))
      ;; Convert (agent . struct) to a safe cons cell for the core hashing function
      (apply orig-fn (cons 'project (macher-agent-workspace-project-root (cdr workspace))) args)
    (apply orig-fn workspace args)))

(advice-add 'macher--workspace-hash :around #'macher-agent--fix-workspace-hash)

(defun macher-agent--build-patch (context &optional _fsm)
  "Build the standard patch deterministically, combining physical files and VFS buffers."
  (let* ((raw-workspace (if (fboundp 'macher-agent--get-context-workspace)
                            (macher-agent--get-context-workspace context)
                          (macher-context-workspace context)))
         (valid-workspace (cond
                           ((and (consp raw-workspace) (symbolp (car raw-workspace)))
                            raw-workspace)
                           ((and (recordp raw-workspace) (eq (type-of raw-workspace) 'macher-agent-workspace))
                            (cons 'agent raw-workspace))
                           (t nil)))
         
         (target-buffer (car (macher-agent--get-buffer "patch" valid-workspace t))))

    (when target-buffer
      (with-current-buffer target-buffer
        (when (fboundp 'macher-agent--patch-buffer-setup)
          (macher-agent--patch-buffer-setup))
        (run-hooks 'macher-patch-buffer-setup-hook)

        (let ((inhibit-read-only t))
          (erase-buffer)
          
          (when (and (recordp context) (eq (type-of context) 'macher-context))
            (setf (macher-context-workspace context) valid-workspace))

          ;; 1. Generate core physical file diff
          (let* ((file-diff (when (fboundp 'macher--generate-patch-diff)
                              (macher--generate-patch-diff context)))
                 ;; 2. Generate live VFS buffer diff
                 (buffer-diff (when (fboundp 'macher-agent--build-virtual-patch)
                                (macher-agent--build-virtual-patch context)))
                 ;; 3. Combine the split patches safely
                 (diff-text (concat 
                             (if (and file-diff (not (string-empty-p file-diff))) file-diff "")
                             (if (and file-diff buffer-diff 
                                      (not (string-empty-p file-diff)) 
                                      (not (string-empty-p buffer-diff))) 
                                 "\n" "")
                             (if (and buffer-diff (not (string-empty-p buffer-diff))) buffer-diff ""))))
            
            (when (not (string-empty-p diff-text))
              (insert diff-text)))

          ;; 4. RESTORE METADATA: Generate Patch ID and Workspace details
          (let* ((patch-id (let ((res ""))
                             (dotimes (_ 8 res)
                               (let ((idx (random 36)))
                                 (setq res (concat res (substring "abcdefghijklmnopqrstuvwxyz0123456789" idx (1+ idx))))))))
                 (root-dir (if (fboundp 'macher--workspace-root)
                               (ignore-errors (macher--workspace-root valid-workspace))
                             default-directory))
                 (proj-name (if (fboundp 'macher--workspace-name)
                                (ignore-errors (macher--workspace-name valid-workspace))
                              (file-name-nondirectory (directory-file-name (or root-dir "")))))
                 (prompt (when (recordp context) (ignore-errors (macher-context-prompt context)))))
            
            ;; Insert Top Header
            (goto-char (point-min))
            (insert (format "# Patch ID: %s\n# Project: %s\n" patch-id (or proj-name "Unknown")))
            
            ;; Handle empty patch edge-case
            (when (= (point-max) (point)) 
              (insert "\n# No changes were made to any files.\n"))
            
            ;; Insert Bottom Footer Context
            (goto-char (point-max))
            (when (and prompt (not (string-empty-p prompt)))
              (insert "# -----------------------------\n")
              (insert (format "# PROMPT for patch ID %s:\n" patch-id))
              (insert "# -----------------------------\n")
              (insert (replace-regexp-in-string "^" "# " prompt))
              (insert "\n"))))
        
        ;; Delegate the UI rendering to the user's preferred function
        (funcall macher-agent-patch-display-function target-buffer)
        target-buffer))))

;; Ensure our deterministic override takes precedence
(defalias 'macher--build-patch 'macher-agent--build-patch)

(defun macher--patch-prepare-metadata (context _fsm callback)
  "Add metadata to the current patch buffer content for CONTEXT.
CALLBACK must be called when preparation is complete."
  (macher-agent--prepare-patch-buffer (current-buffer) context)
  (funcall callback))

(cl-defun macher-agent--make-vfs-context (&key workspace contents)
  (macher--make-context :workspace workspace :contents contents))

(defun macher-agent--get-context-workspace (ctx)
  "Extract workspace safely, unwrapping 'agent cons cells if necessary."
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
