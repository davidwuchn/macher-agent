;;; macher-agent-vfs-client.el --- Layer 2 VFS Client for Macher -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'macher)
(require 'gptel nil t)
(require 'xref)

;; ---------------------------------------------------------------------
;; API Contract / Struct Definitions
;; ---------------------------------------------------------------------

(cl-defstruct macher-agent-workspace
  "A shared singleton per project root managing the VFS state."
  project-root
  (vfs-buffers (make-hash-table :test 'equal))
  (mtime-tracker (make-hash-table :test 'equal)))

(cl-defstruct macher-agent-session
  "An isolated session instance per agent/buffer."
  id
  workspace
  sandbox-path
  (pending-media nil))

(defvar macher-agent-context-mutated-hook nil
  "Hook run whenever the agent's context is modified.")

(defvar macher-agent--allow-lazy-init nil
  "Dynamically bound to t when lazy initialisation of the agent context is permitted.")

;; ---------------------------------------------------------------------
;; VFS State Machine
;; ---------------------------------------------------------------------

(defun macher-agent-vfs-write (workspace file-path content)
  "Write CONTENT to FILE-PATH in the WORKSPACE VFS, with optimistic concurrency."
  (let* ((tracker (macher-agent-workspace-mtime-tracker workspace))
         (original-mtime (gethash file-path tracker))
         (current-attrs (file-attributes file-path))
         (current-mtime (nth 5 current-attrs)))
    (when (and original-mtime current-mtime (not (equal original-mtime current-mtime)))
      (error "Your previous edits to %s were discarded due to external file modifications. Please re-read and re-apply."
             (file-name-nondirectory file-path)))
    (puthash file-path current-mtime tracker)
    (puthash file-path content (macher-agent-workspace-vfs-buffers workspace))))

(defun macher-agent-vfs-read (workspace file-path)
  "Read the content of FILE-PATH from the WORKSPACE VFS."
  (let ((content (gethash file-path (macher-agent-workspace-vfs-buffers workspace))))
    (if content
        content
      (macher-agent--read-content-from-disk-or-buffer file-path))))

(defun macher-agent-sandbox-inflate (session)
  "Inflate the sandbox for SESSION by overlaying VFS changes."
  (let* ((workspace (macher-agent-session-workspace session))
         (sandbox-path (macher-agent-session-sandbox-path session))
         (vfs-buffers (macher-agent-workspace-vfs-buffers workspace)))
    (when sandbox-path
      (let ((sandbox-root (file-name-as-directory (expand-file-name sandbox-path))))
        (maphash (lambda (path content)
                   (let* ((relative-path (if (file-name-absolute-p path)
                                             (file-relative-name path (macher-agent-workspace-project-root workspace))
                                           path))
                          (sandbox-target-path (expand-file-name relative-path sandbox-root)))
                     (make-directory (file-name-directory sandbox-target-path) t)
                     (write-region content nil sandbox-target-path nil 'silent)))
                 vfs-buffers)))))

(defun macher-agent--process-request (reason context fsm)
  "Categorise uncommitted changes to File VFS Diff or Live Buffer Diff."
  (when context
    (let* ((normalized-ctx (if (listp context)
                               (let ((ctx-struct (macher--make-context :workspace nil :contents nil)))
                                 (setf (macher-context-workspace ctx-struct) (plist-get context :workspace))
                                 (setf (macher-context-contents ctx-struct) (plist-get context :contents))
                                 ctx-struct)
                             context))
           (split (macher-agent--split-context normalized-ctx))
           (file-ctx (car split))
           (buf-ctx (cdr split)))
      
      (when (and file-ctx (macher-context-contents file-ctx))
        (macher--build-patch file-ctx fsm))
      
      (when (and buf-ctx (macher-context-contents buf-ctx))
        (macher-agent--build-virtual-patch buf-ctx)))))

(defun macher-agent--flush-vfs-to-sandbox (sandbox-dir)
  "Overlay pending virtual edits onto the ephemeral SANDBOX-DIR.
This ensures external tools test the agent's hybrid state without touching the real disk."
  (let ((ctx (ignore-errors (macher-agent-current-context)))
        (sandbox-root (file-name-as-directory (expand-file-name sandbox-dir))))
    (when (and ctx (macher-context-dirty-p ctx))
      (dolist (entry (macher-context-contents ctx))
        (let* ((original-path (car entry))
               (new-content (cdr (cdr entry)))
               ;; Re-root the absolute original path into the temporary sandbox directory
               (relative-path (file-relative-name original-path (macher--workspace-root (macher-context-workspace ctx))))
               (sandbox-target-path (expand-file-name relative-path sandbox-root)))
          (when (stringp new-content)
            (message "Flushing VFS content to: %s" original-path)
            
            (let* ((ws-root (file-name-as-directory (expand-file-name (macher--workspace-root (macher-context-workspace ctx)))))
                   (expanded-orig (expand-file-name original-path ws-root))
                   (relative-path (file-relative-name expanded-orig ws-root))
                   (sandbox-target-path (expand-file-name relative-path (file-name-as-directory (expand-file-name sandbox-dir)))))
              (make-directory (file-name-directory sandbox-target-path) t)
              (write-region new-content nil sandbox-target-path nil 'silent))))))))

;; work around fir large edits
(defun macher-agent--edit-string-fast (content old-string new-string &optional replace-all)
  "Replacement for `macher--edit-string`."
  (when (string-equal old-string new-string)
    (error "No changes to make: old_string and new_string are exactly the same"))
  
  (if (string-empty-p old-string)
      (if (string-empty-p content)
          new-string
        (error "Cannot replace empty string in non-empty content"))
    (let ((matches 0)
          (start 0))
      ;; Fast C-level count
      (while (setq start (string-search old-string content start))
        (setq matches (1+ matches))
        (setq start (+ start (length old-string))))
      
      (cond
       ((= matches 0)
        (error "String to replace not found in file"))
       ((and (> matches 1) (not replace-all))
        (error "Found %d matches of the string to replace, but replace_all is false. To replace all occurrences, set replace_all to true. To replace only one occurrence, please provide more context to uniquely identify the instance" matches))
       (t
        ;; Since we verified there is exactly 1 match (if not replace-all),
        ;; or we want to replace all, we can safely use the native string-replace.
        (string-replace old-string new-string content))))))

(advice-add 'macher--edit-string :override #'macher-agent--edit-string-fast)

(defun macher-agent--ensure-access (context path)
  "Halt execution if PATH is outside the agent's explicit scope."
  (let* ((actual-name (substring-no-properties path))
         (contents (and context (macher-context-contents context))))
    (unless (assoc actual-name contents)
      ;; Throwing a catchable error is idiomatic Emacs Lisp for access denial
      (error "SECURITY ERROR: You do not have permission to access '%s'. Use list_buffers_in_workspace to see your allowed scope." actual-name))))

(defun macher-agent-current-context ()
  "Dynamically resolve the active agent context for tool execution.
Prioritises the in-flight FSM context over the global persistent one."
  (let* (;; 1. Check if we are currently inside an active FSM turn
         (fsm (bound-and-true-p macher--fsm-latest))
         (fsm-info (when fsm
                     (if (fboundp 'gptel-fsm-info)
                         (funcall 'gptel-fsm-info fsm)
                       (when (fboundp 'mock-gptel-fsm-info)
                         (funcall 'mock-gptel-fsm-info fsm)))))
         ;; 2. Extract the uncommitted, mid-turn FSM context
         (fsm-ctx (when fsm-info (plist-get fsm-info :macher--context)))
         
         ;; 3. Check the current buffer's persistent context directly
         (local-ctx (bound-and-true-p macher-agent--persistent-context)))
    
    (cond
     ;; Priority A: Use the FSM's uncommitted context if a turn is active
     (fsm-ctx fsm-ctx)
     
     ;; Priority B: Fall back to the baseline persistent context in the current buffer
     (local-ctx local-ctx)
     
     ;; Priority C: Search all buffers (Critical for chained async tools running in sentinels)
     (t
      (let ((primary-ctx nil))
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (and (bound-and-true-p macher-agent--is-workspace)
                       (bound-and-true-p macher-agent--persistent-context))
              ;; Grab the first valid workspace context we find across all buffers
              (unless primary-ctx
                (setq primary-ctx macher-agent--persistent-context)))))
        
        (unless primary-ctx
          (if macher-agent--allow-lazy-init
              (let* ((proj (and (fboundp 'project-current) (project-current nil)))
                     (current-root (or (and proj (fboundp 'project-root) (project-root proj))
                                       (and (fboundp 'vc-root-dir) (vc-root-dir))
                                       default-directory))
                     (new-workspace (cons 'agent current-root)))
                (setq primary-ctx (macher--make-context :workspace new-workspace :contents nil))
                (setq-local macher-agent--is-workspace t)
                (setq-local macher--workspace new-workspace))
            (error "No active agent session found")))
        
        (when primary-ctx
          (setq-local macher-agent--persistent-context primary-ctx))
        primary-ctx)))))

(defun macher-agent--read-content-from-disk-or-buffer (path)
  "Read the content of PATH from its live buffer or physical file."
  (let ((buf (or (get-file-buffer path) (get-buffer path)))
        (is-media (and (file-exists-p path) 
                       (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|pdf\\)$" path))))
    (cond
     ((and buf (buffer-live-p buf))
      (with-current-buffer buf
        (buffer-substring-no-properties (point-min) (point-max))))
     ((file-exists-p path)
      (with-temp-buffer
        (if is-media
            (insert-file-contents-literally path)
          (insert-file-contents path))
        (buffer-string)))
     (t nil))))

(defun macher-agent--split-context (ctx)
  "Split CTX into a pair (FILE-CTX . BUF-CTX)."
  (let ((file-ctx (macher-agent--clone-context ctx))
        (buf-ctx (macher-agent--clone-context ctx))
        (file-contents nil)
        (buf-contents nil)
        ;; Add safe nil check to fboundp evaluation
        (workspace (when (and ctx (fboundp 'macher-context-workspace)) (macher-context-workspace ctx))))
    (let ((root (and workspace (macher--workspace-root workspace))))
      (when ctx
        (dolist (entry (macher-context-contents ctx))
          (let* ((path (car entry))
                 (content-pair (cdr entry))
                 (orig (car content-pair))
                 (new (cdr content-pair))
                 (class (macher-agent-context-classify-entry path root)))
            (unless (equal orig new)
              (if (eq class 'buffer)
                  (push entry buf-contents)
                (push entry file-contents)))))))
    (when file-ctx (setf (macher-context-contents file-ctx) (nreverse file-contents)))
    (when buf-ctx (setf (macher-context-contents buf-ctx) (nreverse buf-contents)))
    (cons file-ctx buf-ctx)))

(defun macher-agent--get-buffer-content (context path)
  "Get the content of a buffer or file by path."
  (let* ((workspace (when context (macher-context-workspace context)))
         (workspace-root (when workspace (macher--workspace-root workspace)))
         (abs-path (expand-file-name path)))
    (when (and workspace-root
               (not (string-prefix-p (expand-file-name workspace-root) abs-path)))
      (error "SECURITY ERROR: Path traversal attempt detected. Path '%s' is outside workspace root '%s'." path workspace-root))
    (macher-agent--read-content-from-disk-or-buffer path)))

(defun macher-agent--update-context-file (context path new-content)
  "Update the virtual NEW-CONTENT for PATH in the macher CONTEXT.
Can handle both physical file paths and pure Emacs buffer names."
  
  (let* ((contents (macher-context-contents context))
         (entry (assoc path contents)))
    (if entry
        (progn
          (setcdr (cdr entry) new-content))
      (progn
        (let ((orig (macher-agent--get-buffer-content context path)))
          (setf (macher-context-contents context)
                (cons (cons path (cons orig new-content)) contents)))))
    
    (setf (macher-context-dirty-p context) t)
    (macher-agent--persist-vfs-to-hidden-buffer context)
    (run-hooks 'macher-agent-context-mutated-hook)))

(defun macher-agent--read-context-file (context path)
  "Securely read PATH from the virtual CONTEXT or the live Emacs buffer."
  (macher-agent--ensure-access context path)
  
  (let* ((virtual-entry (when context (assoc path (macher-context-contents context))))
         (virtual-content (when virtual-entry (cddr virtual-entry))))
    (cond
     (virtual-content virtual-content)
     ((get-buffer path)
      (macher-agent--get-buffer-content context path))
     (t (error "ERROR: Buffer '%s' does not exist." path)))))

(defun macher-agent-context-classify-entry (path-or-buf &optional root-dir)
  "Classify PATH-OR-BUF as a workspace \\='file\\=', \\='external\\=', \\='buffer\\=', or \\='media\\='.
Optional ROOT-DIR is used to determine if a file resides within the workspace."
  (let* ((expanded (if root-dir (expand-file-name path-or-buf root-dir) (expand-file-name path-or-buf)))
         (buf (get-buffer path-or-buf))
         (file-from-buf (and buf (buffer-file-name buf)))
         (is-absolute (file-name-absolute-p path-or-buf))
         (has-slash (string-match-p "/" path-or-buf)))
    (cond
     ((or (and file-from-buf (file-exists-p file-from-buf))
          (file-exists-p expanded)
          is-absolute
          has-slash)
      (let* ((path (or (and file-from-buf (file-exists-p file-from-buf) file-from-buf) expanded))
             (is-in-workspace (if root-dir (string-prefix-p (expand-file-name root-dir) path) t)))
        (if is-in-workspace
            (let ((mime (or (mailcap-file-name-to-mime-type path)
                            (and (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|svg\\)$" path) "image/png"))))
              (if (and mime (or (string-prefix-p "image/" mime)
                                (string-prefix-p "video/" mime)
                                (string-prefix-p "audio/" mime)))
                  'media
                'file))
          'external)))
     (t 'buffer))))

(defvar-local macher-agent--is-workspace nil
  "Flag indicating this buffer operates under the safe macher-agent file scanner.")

(defvar-local macher-agent--persistent-context nil
  "Stores the macher context across continuous agent tool turns.")

;; --- Native Macher Workspace Definition ---

(defun macher-agent--get-root (dir)
  "Return the root directory for the agent workspace."
  dir)

(defun macher-agent--get-name (dir)
  "Return a safe name for the isolated sub-agent workspace."
  (concat "Agent: " (file-name-nondirectory (directory-file-name dir))))

(defun macher-agent--get-files (dir)
  "Return a list of safe files in the workspace at DIR.
This strictly enforces size and file type limits to prevent memory exhaustion,
and will abort if the workspace resolves to the root or home directory."
  (let ((expanded-dir (expand-file-name dir))
        (home-dir (expand-file-name "~/")))
    (condition-case err
        (let* ((raw-files 
                (if-let ((proj (project-current nil expanded-dir)))
                    (project-files proj)
                  (when (or (string= expanded-dir home-dir)
                            (string= expanded-dir "/"))
                    (error "SECURITY HALT: Workspace resolved to root or home directory."))
                  (directory-files-recursively
                   expanded-dir "^[^.]" nil
                   (lambda (d)
                     (let ((base (file-name-nondirectory (directory-file-name d))))
                       (and (not (member base '(".git" "target" "node_modules" ".Trash" "Library" ".cache" ".config")))
                            (condition-case nil
                                (progn (directory-files d) t)
                              (error nil))))))))
               (safe-files '()))
          
          (dolist (file raw-files)
            (when (file-exists-p file)
              (let ((attrs (file-attributes file)))
                (when (and attrs
                           (< (file-attribute-size attrs) 1000000)
                           (not (string-suffix-p ".json" file))
                           (not (string-suffix-p ".eln" file))
                           (not (string-suffix-p ".elc" file)))
                  (push file safe-files)))))
          (nreverse safe-files))
      (error (error "Agent Workspace Error: %s" (error-message-string err))))))

;; Register the new agent workspace type
(add-to-list 'macher-workspace-types-alist
             '(agent . (:get-root macher-agent--get-root
                                  :get-name macher-agent--get-name
                                  :get-files macher-agent--get-files)))

(defun macher-workspace-agent ()
  "Detect if the current buffer should use the safe agent workspace."
  (when macher-agent--is-workspace
    (cons 'agent default-directory)))

;; Inject custom scanner to the front of macher's detection list
(add-hook 'macher-workspace-functions #'macher-workspace-agent)

;; --- Context Synchronisation & Persistence ---

(defun macher-agent--clone-context (ctx)
  "Return a deep copy of the context object safely."
  (if (not ctx)
      nil
    (macher--make-context 
     :workspace (when (fboundp 'macher-context-workspace) (macher-context-workspace ctx))
     :contents (copy-tree (macher-context-contents ctx)))))

(defun macher-agent--merge-contexts (parent-ctx child-ctx)
  "Append all dirty file pairs from CHILD-CTX back into PARENT-CTX."
  (let ((child-contents (macher-context-contents child-ctx)))
    (dolist (child-entry child-contents)
      (let* ((path (car child-entry))
             (orig-new (cdr child-entry))
             (orig (car orig-new))
             (new (cdr orig-new)))
        ;; Only merge if content is dirty (or was modified)
        (unless (equal orig new)
          (macher-agent--update-context-file parent-ctx path new))))))

(defun macher-agent--sync-context-entry (entry)
  "Synchronise a single virtual memory ENTRY against disk state."
  (let* ((path (car entry))
         (content-pair (cdr entry))
         (orig (car content-pair))
         (new (cdr content-pair))
         (current-state (macher-agent--read-content-from-disk-or-buffer path)))
    
    (if (not (equal orig current-state))
        (if (equal new current-state)
            (progn
              (setcar content-pair current-state)
              t)
          (progn
            (setcar content-pair current-state)
            (setcdr content-pair current-state)
            t))
      nil)))

(defun macher-agent--auto-sync-context (ctx &rest _args)
  "Check live buffers and physical disk to fast-forward the agent's memory."
  (when ctx
    (let ((contents (macher-context-contents ctx))
          (synced nil))
      (dolist (entry contents)
        (when (macher-agent--sync-context-entry entry)
          (setq synced t)))
      (when synced
        (setf (macher-context-dirty-p ctx) nil)
        (macher-agent--persist-vfs-to-hidden-buffer ctx)
        (run-hooks 'macher-agent-context-mutated-hook)))))

(defun macher-agent--persist-vfs-to-hidden-buffer (ctx)
  "Persist the VFS state to a dedicated hidden buffer."
  ;; Add safe nil check to fboundp evaluation
  (let* ((workspace (when (and ctx (fboundp 'macher-context-workspace)) (macher-context-workspace ctx)))
         (root-dir (if workspace (macher--workspace-root workspace) "default"))
         (buf-name (format " *macher-agent-vfs-state-%s*" (md5 (expand-file-name root-dir))))
         (vfs-buf (get-buffer-create buf-name)))
    (with-current-buffer vfs-buf
      (erase-buffer)
      (insert ";;; Macher Agent Virtual File System State\n")
      (insert ";;; This buffer is C-optimised and handles gigabytes of text effortlessly.\n\n")
      (when ctx
        (dolist (entry (macher-context-contents ctx))
          (let ((path (car entry))
                (new-content (cddr entry)))
            (when new-content
              (insert (format "=== VFS ENTRY: %s ===\n" path))
              (insert new-content)
              (insert "\n=======================\n\n"))))))))

(defun macher-agent--build-virtual-patch (buf-ctx)
  "Build patch buffer specifically for virtual buffers."
  (cl-letf (((symbol-function 'macher-patch-buffer)
             (lambda (&optional workspace create)
               (let ((result (macher--get-buffer "virtual-buffers-patch" workspace create)))
                 (when result
                   (let ((target-buffer (car result))
                         (created-p (cdr result)))
                     (when created-p
                       (with-current-buffer target-buffer
                         (macher--patch-buffer-setup)
                         (run-hooks 'macher-patch-buffer-setup-hook)))
                     target-buffer))))))
    (macher--build-patch buf-ctx nil)))

(defun macher-agent-apply-patch ()
  "Apply current patch buffer using external diff utilities safely."
  (interactive)
  (unless (derived-mode-p 'diff-mode)
    (user-error "Not in a patch/diff buffer"))
  (let* ((patch-content (buffer-substring-no-properties (point-min) (point-max)))
         (root (or (locate-dominating-file default-directory ".git") 
                   default-directory))
         (default-directory root)
         (use-git (file-exists-p (expand-file-name ".git" root)))
         (cmd (if use-git "git" "patch"))
         (args (if use-git '("apply" "-") '("-p1"))))
    (with-temp-buffer
      (insert patch-content)
      (let ((exit-code (apply #'call-process-region 
                              (point-min) (point-max) 
                              cmd nil "*macher-patch-out*" nil args)))
        (if (= exit-code 0)
            (progn
              (message "SUCCESS: Patch applied safely via %s." cmd)
              (kill-buffer (get-buffer "*macher-patch-out*")))
          (pop-to-buffer "*macher-patch-out*")
          (message "ERROR: Failed to apply patch safely."))))))

(defun macher-agent-insert-patch ()
  "Insert the current workspace's patch into the chat buffer to continue working."
  (interactive)
  (let* ((patch-buf (macher-patch-buffer))
         (content (when (buffer-live-p patch-buf)
                    (with-current-buffer patch-buf
                      (buffer-substring-no-properties (point-min) (point-max))))))
    (if (or (null content) (string-empty-p content))
        (message "No patch available for current workspace.")
      (insert "\nHere is your proposed patch:\n```diff\n" content "\n```\n"))))

;; --- Sandbox and Execution Utilities (Merged from context-tools & vfs) ---

(defun macher-agent--get-context-edits (context)
  "Extract file paths and virtual contents from the macher CONTEXT."
  (when context
    (mapcar (lambda (entry)
              (let* ((path (car entry))
                     (content-pair (cdr entry))
                     (new-content (cdr content-pair)))
                (cons path new-content)))
            (macher-context-contents context))))

(defun macher-agent--run-async-cmd (name cmd dir callback)
  "Run CMD asynchronously in DIR, passing exit codes and output to CALLBACK."
  (let ((out-buf (generate-new-buffer (format " *macher-%s-out*" name)))
        (default-directory dir))
    (set-process-sentinel
     (if (listp cmd)
         (apply #'start-file-process name out-buf (car cmd) (cdr cmd))
       (start-file-process-shell-command name out-buf cmd))
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (set-process-sentinel proc nil)
         (let* ((exit-code (process-exit-status proc))
                (output (if (buffer-live-p out-buf)
                            (with-current-buffer out-buf (buffer-string))
                          "")))
           (when (buffer-live-p out-buf)
             (set-process-buffer proc nil)
             (kill-buffer out-buf))
           (funcall callback exit-code output)))))))

(defun macher-agent--build-rsync-cmd (src dest)
  "Construct a safe rsync command.
If in a Git repository, uses 'git ls-files' to perfectly respect standard ignores.
Falls back to a naive exclusion list for non-git workspaces."
  (let* ((src-dir (file-name-as-directory (expand-file-name src)))
         (dest-dir (file-name-as-directory (expand-file-name dest)))
         (in-git (eq 0 (call-process "git" nil nil nil "-C" src-dir "rev-parse" "--is-inside-work-tree"))))
    (if in-git
        ;; -z and -0 ensure paths with spaces are safely piped
        (format "git -C %s ls-files -c -o --exclude-standard -z | rsync -aLC0 --delete --files-from=- %s %s"
                (shell-quote-argument src-dir)
                (shell-quote-argument src-dir)
                (shell-quote-argument dest-dir))
      ;; Fallback: returns the standard list format if no git repo is found
      (let ((base-args (list "rsync" "-aLC" "--delete"))
            (excludes (list ".git/" "node_modules/" "target/" "__pycache__/" "venv/" ".venv/" "build/" "dist/")))
        (append base-args
                (mapcan (lambda (ex) (list "--exclude" ex)) excludes)
                (list src-dir dest-dir))))))

(defcustom macher-agent-sandbox-excludes 
  '(".git/" "target/" "node_modules/" ".Trash/" "Library/" ".venv/" "__pycache__/")
  "List of directories to exclude when syncing the workspace to a sandbox."
  :type '(repeat string)
  :group 'macher-agent)

(defun macher-agent-with-sandbox (project-root context callback)
  "Create a temporary sandbox from the CONTEXT VFS and pass its path to CALLBACK."
  (let* ((temp-dir (file-name-as-directory (make-temp-file "sandbox-" t)))
         (cleanup-fn (lambda () (delete-directory temp-dir t)))
         (rsync-cmd (macher-agent--build-rsync-cmd project-root temp-dir))
         (pending-edits (macher-agent--get-context-edits context)))
    
    ;; --- DEBUG LOGGING ---
    (message "DEBUG [sandbox]: Creating sandbox at %s" temp-dir)
    (message "DEBUG [sandbox]: Context provided? %s" (if context "YES" "NO"))
    (message "DEBUG [sandbox]: Total pending edits found: %d" (length pending-edits))
    ;; ---------------------

    (macher-agent--run-async-cmd 
     "rsync" rsync-cmd project-root
     (lambda (exit-code output)
       (if (not (= exit-code 0))
           (progn
             (funcall cleanup-fn)
             (funcall callback nil (format "ERROR: Rsync failed (code %s).\nOutput: %s" exit-code output)))
         
         ;; --- DEBUG LOGGING ---
         (message "DEBUG [sandbox]: Rsync complete. Beginning VFS overlay...")
         ;; ---------------------
         
         (dolist (edit pending-edits)
           (let* ((path (car edit))
                  (content (cdr edit))
                  (rel-path (if (file-name-absolute-p path)
                                (file-relative-name path project-root)
                              path))
                  (full-path (expand-file-name rel-path temp-dir)))
             
             ;; --- DEBUG LOGGING ---
             (message "DEBUG [sandbox]: Processing virtual edit for '%s'" rel-path)
             ;; ---------------------
             
             (if content
                 (progn
                   ;; --- DEBUG LOGGING ---
                   (message "DEBUG [sandbox]: -> Writing %d characters to %s" (length content) full-path)
                   ;; ---------------------
                   (make-directory (file-name-directory full-path) t)
                   (with-temp-file full-path (insert content)))
               (when (file-exists-p full-path)
                 (message "DEBUG [sandbox]: -> Deleting file %s" full-path)
                 (delete-file full-path)))))
         
         (message "DEBUG [sandbox]: Sandbox setup complete. Handing off to tool.")
         (funcall callback temp-dir nil))))))

(defun macher-agent--pure-async-execute (project-root context cmd success-override callback)
  "Execute CMD inside a temporary sandbox cleanly and asynchronously."
  (macher-agent-with-sandbox project-root context
                             (lambda (temp-dir err)
                               (if err
                                   (funcall callback err)
                                 (let ((cleanup-fn (lambda () (delete-directory temp-dir t))))
                                   (macher-agent--run-async-cmd 
                                    "cmd" cmd temp-dir
                                    (lambda (cmd-exit cmd-output)
                                      (funcall cleanup-fn)
                                      (if (and success-override 
                                               (= cmd-exit 0) 
                                               (string-empty-p (string-trim cmd-output)))
                                          (funcall callback success-override)
                                        (funcall callback cmd-output)))))))))

;;;###autoload
(defun macher-agent-clear-context ()
  "Wipe the agent's virtual memory so it reads fresh from the disk on its next turn."
  (interactive)
  (if (not macher-agent--persistent-context)
      (message "No active context to clear in this buffer.")
    (setq-local macher-agent--persistent-context nil)
    (setq-local macher--fsm-latest nil)
    (run-hooks 'macher-agent-context-mutated-hook)
    (message "Agent memory cleared. It will take a fresh snapshot of the disk on its next task.")))

(provide 'macher-agent-vfs-client)
;;; macher-agent-vfs-client.el ends here
