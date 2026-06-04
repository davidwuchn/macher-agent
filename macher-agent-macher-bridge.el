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

(defun macher-agent--sanitize-diff-headers (diff-text)
  "Strip standard a/ and b/ prefixes from unified diff headers to prevent nesting bugs.
Handles standard paths and git-quoted paths for filenames with spaces."
  (if (not (stringp diff-text))
      diff-text
    (let ((s diff-text))
      (setq s (replace-regexp-in-string "^--- \\(\"?\\)a/" "--- \\1" s))
      (setq s (replace-regexp-in-string "^\\+\\+\\+ \\(\"?\\)b/" "+++ \\1" s))
      s)))

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

;; --- CORE CRASH FIXES ---

(defun macher-agent--fix-workspace-hash (orig-fn workspace &rest args)
  "Prevent `macher--workspace-hash` from crashing on the agent workspace struct."
  (if (and (consp workspace)
           (eq (car workspace) 'agent)
           (recordp (cdr workspace))
           (eq (type-of (cdr workspace)) 'macher-agent-workspace))
      (apply orig-fn (cons 'project (macher-agent-workspace-project-root (cdr workspace))) args)
    (apply orig-fn workspace args)))

(advice-add 'macher--workspace-hash :around #'macher-agent--fix-workspace-hash)

(defun macher-agent--fix-generate-patch-diff (orig-fn context &rest args)
  "Intercept `macher--generate-patch-diff` to ensure it always receives a core-compatible list.
This prevents async process sentinels from crashing when parsing LLM outputs in the background."
  (if (and (recordp context) (eq (type-of context) 'macher-context))
      (let* ((orig-ws (macher-context-workspace context))
             (core-ws (cond
                       ;; If it's the raw struct
                       ((and (recordp orig-ws) (eq (type-of orig-ws) 'macher-agent-workspace))
                        (cons 'project (macher-agent-workspace-project-root orig-ws)))
                       ;; If it's an ('agent . struct) cons cell
                       ((and (consp orig-ws) (eq (car orig-ws) 'agent) (recordp (cdr orig-ws)))
                        (cons 'project (macher-agent-workspace-project-root (cdr orig-ws))))
                       ;; Otherwise leave it alone
                       (t orig-ws))))
        (unwind-protect
            (progn
              ;; Temporarily downgrade to a safe list for the core engine
              (setf (macher-context-workspace context) core-ws)
              (apply orig-fn context args))
          ;; Always restore the struct so downstream agent logic functions normally
          (setf (macher-context-workspace context) orig-ws)))
    (apply orig-fn context args)))

(advice-add 'macher--generate-patch-diff :around #'macher-agent--fix-generate-patch-diff)

;; --- PATCH BUILDER ---

(defun macher-agent--build-patch (context &optional _fsm)
  "Build the standard patch deterministically, splitting file and virtual diffs."
  (let* ((raw-workspace (if (fboundp 'macher-agent--get-context-workspace)
                            (macher-agent--get-context-workspace context)
                          (macher-context-workspace context)))
         (valid-workspace (cond
                           ((and (consp raw-workspace) (symbolp (car raw-workspace)))
                            raw-workspace)
                           ((and (recordp raw-workspace) (eq (type-of raw-workspace) 'macher-agent-workspace))
                            (cons 'agent raw-workspace))
                           (t nil)))
         
         (target-buffer (car (macher-agent--get-buffer "patch" valid-workspace t)))
         
         ;; Setup Metadata
         (patch-id (let ((res ""))
                     (dotimes (_ 8 res)
                       (let ((idx (random 36)))
                         (setq res (concat res (substring "abcdefghijklmnopqrstuvwxyz0123456789" idx (1+ idx))))))))
         (root-dir (if (fboundp 'macher--workspace-root)
                       (ignore-errors (macher--workspace-root valid-workspace))
                     default-directory))
         (proj-name (if (fboundp 'macher--workspace-name)
                        (ignore-errors (macher--workspace-name valid-workspace))
                      (file-name-nondirectory (directory-file-name (or root-dir "")))))
         (prompt (when (recordp context) (ignore-errors (macher-context-prompt context))))
         
         ;; Fetch and sanitise diffs (the new advice-add ensures the core call doesn't crash)
         (file-diff (macher-agent--sanitize-diff-headers 
                     (when (fboundp 'macher--generate-patch-diff)
                       (macher--generate-patch-diff context))))
         (virtual-diff (macher-agent--sanitize-diff-headers 
                        (when (fboundp 'macher-agent--build-virtual-patch)
                          (macher-agent--build-virtual-patch context)))))

    ;; 1. HANDLE VIRTUAL DIFF IN A DEDICATED BUFFER
    (when (and virtual-diff (not (string-empty-p virtual-diff)))
      (let ((vbuf-name (format "*macher-virtual-patch:%s*" (or proj-name "Unknown"))))
        (with-current-buffer (get-buffer-create vbuf-name)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "# Patch ID: %s (VIRTUAL BUFFERS)\n# Project: %s\n\n" patch-id (or proj-name "Unknown")))
            (insert virtual-diff)
            
            (when (and prompt (not (string-empty-p prompt)))
              (insert "\n\n# -----------------------------\n")
              (insert (format "# PROMPT for patch ID %s:\n" patch-id))
              (insert "# -----------------------------\n")
              (insert (replace-regexp-in-string "^" "# " prompt))
              (insert "\n")))
          (unless (derived-mode-p 'diff-mode)
            (diff-mode))
          (goto-char (point-min))
          (display-buffer (current-buffer)))))

    ;; 2. HANDLE PHYSICAL FILE DIFF IN THE STANDARD BUFFER
    (when target-buffer
      (with-current-buffer target-buffer
        (when (fboundp 'macher-agent--patch-buffer-setup)
          (macher-agent--patch-buffer-setup))
        (run-hooks 'macher-patch-buffer-setup-hook)

        (let ((inhibit-read-only t))
          (erase-buffer)
          
          (insert (format "# Patch ID: %s (PHYSICAL FILES)\n# Project: %s\n" patch-id (or proj-name "Unknown")))
          
          (if (and file-diff (not (string-empty-p file-diff)))
              (insert "\n" file-diff)
            (insert "\n# No changes were made to any physical files.\n"))
          
          (when (and (or (not virtual-diff) (string-empty-p virtual-diff)) prompt (not (string-empty-p prompt)))
            (insert "\n# -----------------------------\n")
            (insert (format "# PROMPT for patch ID %s:\n" patch-id))
            (insert "# -----------------------------\n")
            (insert (replace-regexp-in-string "^" "# " prompt))
            (insert "\n")))
        
        (funcall macher-agent-patch-display-function target-buffer)
        target-buffer))))

(defalias 'macher--build-patch 'macher-agent--build-patch)

(defun macher--patch-prepare-metadata (context _fsm callback)
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
