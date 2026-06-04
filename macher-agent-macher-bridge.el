;;; macher-agent-macher-bridge.el --- Bridge to Macher Core -*- lexical-binding: t; -*-

(require 'macher)
(require 'cl-lib)

(declare-function macher-agent-workspace-project-root "macher-agent-vfs-client")
(declare-function macher-agent-workspace-p "macher-agent-vfs-client")
(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--get-context-contents "macher-agent-vfs-client")
(declare-function macher-agent--prepare-patch-buffer "macher-agent-vfs-client")

;; --- UI Configuration ---

(defcustom macher-agent-patch-display-function #'macher-agent-default-patch-display
  "Function used to display the generated patch buffer."
  :type 'function
  :group 'macher-agent)

(defun macher-agent-default-patch-display (buffer)
  "Default function to display the agent's patch BUFFER using diff-mode."
  (with-current-buffer buffer
    (unless (derived-mode-p 'diff-mode)
      (diff-mode))
    (goto-char (point-min)))
  (display-buffer buffer))

;; --- Workspace Helpers ---

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

;; --- The "Nuclear" GNU Diff Generators ---

(defun macher-agent--diff-texts (rel-path old-text new-text)
  "Compare two strings and return a perfect GNU unified diff hunk using Unix diff."
  (let ((t1 (make-temp-file "macher-old-"))
        (t2 (make-temp-file "macher-new-"))
        (diff-str ""))
    (with-temp-file t1 (insert (or old-text "")))
    (with-temp-file t2 (insert (or new-text "")))
    (let* ((label-old (if old-text rel-path "/dev/null"))
           (label-new rel-path)
           ;; Manually labeling guarantees no b/ folder bugs!
           (cmd (format "diff -u --label %s --label %s %s %s"
                        (shell-quote-argument label-old)
                        (shell-quote-argument label-new)
                        (shell-quote-argument t1)
                        (shell-quote-argument t2))))
      (setq diff-str (shell-command-to-string cmd)))
    (delete-file t1)
    (delete-file t2)
    diff-str))

(defun macher-agent--generate-gnu-diff (context &rest _args)
  "Completely override the core macher generator to prevent recursive stack crashes."
  (let* ((contents (macher-agent--get-context-contents context))
         (raw-ws (if (fboundp 'macher-agent--get-context-workspace)
                     (macher-agent--get-context-workspace context)
                   (macher-context-workspace context)))
         (valid-ws (cond ((and (consp raw-ws) (symbolp (car raw-ws))) raw-ws)
                         ((and (recordp raw-ws) (eq (type-of raw-ws) 'macher-agent-workspace))
                          (cons 'project (macher-agent-workspace-project-root raw-ws)))
                         (t nil)))
         (root-dir (macher-agent--get-workspace-root valid-ws))
         (diff-output ""))
    (dolist (entry contents)
      (let* ((rel-path (car entry))
             ;; Safely unpack the cons cell if optimistic concurrency data is present
             (file-data (cdr entry))
             (new-text (if (consp file-data) (cdr file-data) file-data))
             (abs-path (expand-file-name rel-path (or root-dir default-directory)))
             ;; Treat missing files as empty strings for diffing additions
             (old-text (if (file-exists-p abs-path)
                           (with-temp-buffer
                             (insert-file-contents abs-path)
                             (buffer-substring-no-properties (point-min) (point-max)))
                         "")))
        (when (and (stringp new-text) (not (string= old-text new-text)))
          (let ((hunk (macher-agent--diff-texts rel-path old-text new-text)))
            (unless (string-empty-p hunk)
              (setq diff-output (concat diff-output hunk "\n")))))))
    diff-output))

(defun macher-agent--generate-virtual-gnu-diff ()
  "Generate a GNU diff for live buffers stored in the VFS."
  (let ((diff-output "")
        (vfs-ctx (ignore-errors (macher-agent-current-context))))
    (when vfs-ctx
      (dolist (entry (macher-agent--get-context-contents vfs-ctx))
        (let* ((buf-name (car entry))
               ;; Safely unpack the cons cell
               (file-data (cdr entry))
               (new-text (if (consp file-data) (cdr file-data) file-data))
               ;; Treat missing buffers as empty strings for diffing additions
               (old-text (if (get-buffer buf-name)
                             (with-current-buffer buf-name
                               (buffer-substring-no-properties (point-min) (point-max)))
                           "")))
          (when (and (stringp new-text) (not (string= old-text new-text)))
            (setq diff-output (concat diff-output
                                      (macher-agent--diff-texts buf-name old-text new-text)
                                      "\n"))))))
    diff-output))

;; --- Core Crash Fixes ---

(defun macher-agent--safe-workspace-hash (workspace &rest _args)
  "Nuke the core recursive hashing function which causes assq-delete-all depth crashes."
  (let ((path (cond
               ((and (recordp workspace) (eq (type-of workspace) 'macher-agent-workspace))
                (macher-agent-workspace-project-root workspace))
               ((and (consp workspace) (eq (car workspace) 'agent) (recordp (cdr workspace)))
                (macher-agent-workspace-project-root (cdr workspace)))
               ((and (consp workspace) (eq (car workspace) 'project))
                (cdr workspace))
               (t (format "%s" workspace)))))
    (md5 (or path "unknown-workspace"))))

(advice-add 'macher--workspace-hash :override #'macher-agent--safe-workspace-hash)

;; --- Safe UI Builder ---

(defalias 'macher-agent--get-buffer 'macher--get-buffer)
(defalias 'macher-agent--patch-buffer-setup 'macher--patch-buffer-setup)

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
         (proj-name (macher-agent--get-workspace-name valid-workspace))
         (prompt (when (recordp context) (ignore-errors (macher-context-prompt context))))
         
         ;; Fetch our flat Unix diffs
         (file-diff (macher-agent--generate-gnu-diff context))
         (virtual-diff (macher-agent--generate-virtual-gnu-diff)))

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
          
          (when (and (recordp context) (eq (type-of context) 'macher-context))
            (setf (macher-context-workspace context) valid-workspace))

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

;; --- Struct Accessors ---

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
