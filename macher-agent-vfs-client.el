;;; macher-agent-vfs-client.el --- Layer 2 VFS Client for Macher -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'macher)
(require 'gptel nil t)
(require 'xref)

(cl-defstruct macher-agent-workspace
  "A shared singleton per project root managing the VFS state."
  project-root
  (vfs-buffers (make-hash-table :test 'equal))
  (mtime-tracker (make-hash-table :test 'equal))
  (tools-registry (make-hash-table :test 'equal))
  (skills-alist nil)
  (active-subagents nil))

(require 'macher-agent-macher-bridge)

(cl-defstruct macher-agent-session
  id
  workspace
  sandbox-path
  (pending-media nil))

(defvar macher-agent-context-mutated-hook nil)
(defvar macher-agent--allow-lazy-init nil)

(defun macher-agent-vfs-get-node (workspace path)
  "Retrieve a node's content from the virtual file system."
  (gethash path (macher-agent-workspace-vfs-buffers workspace)))

(defun macher-agent-vfs-set-node (workspace path content)
  "Set a node's content in the virtual file system."
  (puthash path content (macher-agent-workspace-vfs-buffers workspace)))

(defun macher-agent-vfs-write (workspace file-path content)
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
  (let ((content (gethash file-path (macher-agent-workspace-vfs-buffers workspace))))
    (if content
        content
      (macher-agent--read-content-from-disk-or-buffer file-path))))

(defun macher-agent--resolve-safe-path (unsafe-path base-dir)
  "Resolves UNSAFE-PATH strictly within BASE-DIR, preventing jailbreaks."
  ;; SECURITY HARDENING: Explicitly reject absolute paths. No "Ghost" routing.
  (when (file-name-absolute-p unsafe-path)
    (error "SECURITY ERROR: Absolute paths are forbidden. You must use relative paths (e.g., ./file). Path attempted: %s" unsafe-path))
  
  (let* ((relative (if (string-prefix-p "~" unsafe-path) (concat "./" unsafe-path) unsafe-path))
         (resolved (expand-file-name relative base-dir)))
    (if (or (file-in-directory-p resolved base-dir)
            (string= (expand-file-name resolved) (expand-file-name base-dir)))
        resolved
      (error "SECURITY ERROR: Path traversal jailbreak detected: %s" unsafe-path))))

(defun macher-agent-sandbox-inflate (session)
  (let* ((workspace (macher-agent-session-workspace session))
         (sandbox-path (macher-agent-session-sandbox-path session))
         (vfs-buffers (macher-agent-workspace-vfs-buffers workspace)))
    (when sandbox-path
      (let ((sandbox-root (file-name-as-directory (expand-file-name sandbox-path))))
        (maphash (lambda (path content)
                   (let* ((relative-path (if (file-name-absolute-p path)
                                             (file-relative-name path (macher-agent-workspace-project-root workspace))
                                           path))
                          (sandbox-target-path (macher-agent--resolve-safe-path relative-path sandbox-root)))
                     (make-directory (file-name-directory sandbox-target-path) t)
                     (write-region content nil sandbox-target-path nil 'silent)))
                 vfs-buffers)))))

(defun macher-agent-context-root (context)
  (if-let* ((workspace (when context (macher-agent--get-context-workspace context)))
            (root (macher-agent--get-workspace-root workspace)))
      root
    default-directory))

(defun macher-agent--vfs-verify-clean-merge (workspace-root context) t)

(defun macher-agent--build-rsync-cmd (src dest)
  "Construct an rsync command driven by Git. Throws an error if Git is unavailable."
  (let* ((src-dir (file-name-as-directory (expand-file-name src)))
         (dest-dir (file-name-as-directory (expand-file-name dest))))
    
    (unless (executable-find "git")
      (error "Macher-Agent: Git executable not found in PATH"))
    
    (unless (eq 0 (let ((default-directory src-dir))
                    (call-process "git" nil nil nil "rev-parse" "--is-inside-work-tree")))
      (error "Macher-Agent: Source directory is not inside a Git repository: %s" src-dir))
    
    (format "(cd %s && git ls-files -c -o --exclude-standard) | rsync -aLC --delete --files-from=- %s %s"
            (shell-quote-argument src-dir)
            (shell-quote-argument src-dir)
            (shell-quote-argument dest-dir))))

(defun macher-agent--vfs-sync-baseline (workspace-root sandbox-dir)
  (let ((sync-cmd (macher-agent--build-rsync-cmd workspace-root sandbox-dir)))
    (call-process shell-file-name nil nil nil shell-command-switch sync-cmd)))

(defun macher-agent--edit-string-fast (content old-text new-text replace-all)
  "Replace OLD-TEXT with NEW-TEXT in CONTENT.
If REPLACE-ALL is nil, errors if OLD-TEXT occurs more than once."
  (let ((count 0)
        (start 0))
    (while (string-match (regexp-quote old-text) content start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    (cond
     ((= count 0)
      (error "Text not found: %s" old-text))
     ((and (> count 1) (not replace-all))
      (error "Multiple matches found for text. Set replace_all to true or provide more context: %s" old-text))
     (t
      (replace-regexp-in-string (regexp-quote old-text) new-text content t t)))))

(defun macher-agent--vfs-apply-overlay (context sandbox-dir)
  (when (and context (macher-agent--get-context-dirty-p context))
    (let ((sandbox-root (file-name-as-directory (expand-file-name sandbox-dir)))
          (ws-root (file-name-as-directory (expand-file-name (macher-agent-context-root context)))))
      (dolist (entry (macher-agent--get-context-contents context))
        (let* ((original-path (car entry))
               (new-content (cdr (cdr entry))))
          (when (stringp new-content)
            (let* ((expanded-orig (expand-file-name original-path ws-root))
                   (relative-path (file-relative-name expanded-orig ws-root))
                   (sandbox-target-path (macher-agent--resolve-safe-path relative-path sandbox-root)))
              (make-directory (file-name-directory sandbox-target-path) t)
              (write-region new-content nil sandbox-target-path nil 'silent))))))))

(defun macher-agent-call-with-strict-vfs-pipeline (context body-fn)
  (let* ((workspace-root (macher-agent-context-root context))
         (sandbox-dir (make-temp-file "macher-sandbox-" t)))
    (unwind-protect
        (progn
          (macher-agent--vfs-verify-clean-merge workspace-root context)
          (macher-agent--vfs-sync-baseline workspace-root sandbox-dir)
          (macher-agent--vfs-apply-overlay context sandbox-dir)
          (let ((default-directory sandbox-dir))
            (funcall body-fn)))
      (delete-directory sandbox-dir t))))

(defmacro macher-agent-with-strict-vfs-pipeline (context &rest body)
  `(macher-agent-call-with-strict-vfs-pipeline ,context (lambda () ,@body)))

(defun macher-agent--ensure-access (context path)
  (let* ((actual-name (substring-no-properties path))
         (contents (and context (macher-agent--get-context-contents context))))
    (unless (assoc actual-name contents)
      (error "SECURITY ERROR: You do not have permission to access '%s'. Use list_buffers_in_workspace to see your allowed scope." actual-name))))

(defun macher-agent-current-context ()
  (let* ((fsm (macher-agent--get-fsm-latest))
         (fsm-info (when fsm
                     (if (fboundp 'gptel-fsm-info) (funcall 'gptel-fsm-info fsm)
                       (when (fboundp 'mock-gptel-fsm-info) (funcall 'mock-gptel-fsm-info fsm)))))
         (fsm-ctx (when fsm-info (plist-get fsm-info :macher--context)))
         (local-ctx (bound-and-true-p macher-agent--persistent-context)))
    
    (cond
     (fsm-ctx fsm-ctx)
     (local-ctx local-ctx)
     (t
      (let ((primary-ctx nil)
            (primary-directives nil)) ;; <-- Capture the workspace skills
        ;; Search for the active workspace buffer
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (and (bound-and-true-p macher-agent--is-workspace)
                       (bound-and-true-p macher-agent--persistent-context))
              (unless primary-ctx 
                (setq primary-ctx macher-agent--persistent-context)
                (setq primary-directives gptel-directives))))) ;; <-- Save them
        
        ;; Fallback lazy initialization
        (unless primary-ctx
          (if macher-agent--allow-lazy-init
              (let* ((proj (and (fboundp 'project-current) (project-current nil)))
                     (current-root (or (and proj (fboundp 'project-root) (project-root proj))
                                       (and (fboundp 'vc-root-dir) (vc-root-dir))
                                       default-directory)))
                (macher-agent--init-workspace-state current-root)
                (setq primary-ctx macher-agent--persistent-context)
                (setq primary-directives gptel-directives)) ;; <-- Capture them after init
            (error "No active agent session found")))
        
        ;; Inject both the context and the skills into the current buffer (e.g., navigate.md)
        (when primary-ctx 
          (setq-local macher-agent--persistent-context primary-ctx)
          (when primary-directives
            (setq-local gptel-directives primary-directives))) 
        primary-ctx)))))

(defun macher-agent--read-content-from-disk-or-buffer (path)
  (let ((buf (or (get-file-buffer path) (get-buffer path)))
        (is-media (and (file-exists-p path) 
                       (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|pdf\\)$" path))))
    (cond
     ((and buf (buffer-live-p buf))
      (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max))))
     ((file-exists-p path)
      (with-temp-buffer
        (if is-media (insert-file-contents-literally path) (insert-file-contents path))
        (buffer-string)))
     (t nil))))

(defun macher-agent--init-workspace-state (workspace-root)
  (setq-local macher-agent--is-workspace t)
  (let* ((workspace (make-macher-agent-workspace :project-root workspace-root))
         (macher-ws (cons 'agent workspace))
         (context (macher-agent--make-vfs-context :workspace macher-ws :contents nil)))
    (setq-local macher--workspace macher-ws)
    (setq-local macher-agent--persistent-context context)
    
    (let ((skills-dir (expand-file-name "skills" workspace-root)))
      (when (fboundp 'macher-agent-initialize-skills)
        (when (and (boundp 'macher-agent-bundled-skills-directory) macher-agent-bundled-skills-directory)
          (macher-agent-initialize-skills context macher-agent-bundled-skills-directory))
        (when (file-directory-p skills-dir)
          (macher-agent-initialize-skills context skills-dir))))))

(defun macher-agent--reload-skills-on-mutation (&rest _args)
  (when macher-agent--persistent-context
    (let* ((workspace (macher-agent--get-context-workspace macher-agent--persistent-context))
           (skills-dir (when workspace (expand-file-name "skills" (macher-agent--get-workspace-root workspace)))))
      (when (and skills-dir (file-directory-p skills-dir) (fboundp 'macher-agent-initialize-skills))
        (macher-agent-initialize-skills macher-agent--persistent-context skills-dir)))))

(add-hook 'macher-agent-context-mutated-hook #'macher-agent--reload-skills-on-mutation)

(defun macher-agent--split-context (ctx)
  (let ((file-ctx (macher-agent--clone-context ctx))
        (buf-ctx (macher-agent--clone-context ctx))
        (file-contents nil)
        (buf-contents nil)
        (workspace (when ctx (macher-agent--get-context-workspace ctx))))
    (let ((root (and workspace (macher-agent--get-workspace-root workspace))))
      (when ctx
        (dolist (entry (macher-agent--get-context-contents ctx))
          (let* ((path (car entry))
                 (content-pair (cdr entry))
                 (orig (car content-pair))
                 (new (cdr content-pair))
                 (class (macher-agent-context-classify-entry path root)))
            (unless (equal orig new)
              (if (eq class 'buffer) (push entry buf-contents) (push entry file-contents)))))))
    (when file-ctx (macher-agent--set-context-contents file-ctx (nreverse file-contents)))
    (when buf-ctx (macher-agent--set-context-contents buf-ctx (nreverse buf-contents)))
    (cons file-ctx buf-ctx)))

(defun macher-agent--get-buffer-content (context path)
  (let* ((workspace (when context (macher-agent--get-context-workspace context)))
         (workspace-root (when workspace (macher-agent--get-workspace-root workspace)))
         (abs-path (expand-file-name path)))
    (when (and workspace-root
               (not (or (file-in-directory-p abs-path workspace-root)
                        (string= (expand-file-name abs-path) (expand-file-name workspace-root)))))
      (error "SECURITY ERROR: Path traversal attempt detected. Path '%s' is outside workspace root '%s'." path workspace-root))
    (macher-agent--read-content-from-disk-or-buffer path)))

(defun macher-agent--update-context-file (context path new-content)
  (let* ((contents (macher-agent--get-context-contents context))
         (entry (assoc path contents)))
    (if entry
        (setcdr (cdr entry) new-content)
      (let ((orig (macher-agent--get-buffer-content context path)))
        (macher-agent--set-context-contents context
                                            (cons (cons path (cons orig new-content)) contents))))
    (macher-agent--set-context-dirty-p context t)
    (macher-agent--persist-vfs-to-hidden-buffer context)
    (run-hook-with-args 'macher-agent-context-mutated-hook path)))

(defun macher-agent--read-context-file (context path)
  (macher-agent--ensure-access context path)
  (let* ((virtual-entry (when context (assoc path (macher-agent--get-context-contents context))))
         (virtual-content (when virtual-entry (cddr virtual-entry))))
    (cond
     (virtual-content virtual-content)
     ((get-buffer path) (macher-agent--get-buffer-content context path))
     (t (error "ERROR: Buffer '%s' does not exist." path)))))

(defun macher-agent-context-classify-entry (path-or-buf &optional root-dir)
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

(defvar-local macher-agent--is-workspace nil)
(defvar-local macher--workspace nil)
(defvar-local macher-agent--persistent-context nil)

(defun macher-agent--get-root (workspace)
  (macher-agent-workspace-project-root workspace))

(defun macher-agent--get-name (workspace)
  (concat "Agent: " (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root workspace)))))

(defun macher-agent--get-files (workspace)
  (let* ((expanded-dir (expand-file-name (macher-agent-workspace-project-root workspace)))
         (home-dir (expand-file-name "~/")))
    (condition-case err
        (let* ((raw-files 
                (if-let ((proj (project-current nil expanded-dir)))
                    (project-files proj)
                  (when (or (string= expanded-dir home-dir) (string= expanded-dir "/"))
                    (error "SECURITY HALT: Workspace resolved to root or home directory."))
                  (directory-files-recursively
                   expanded-dir "^[^.]" nil
                   (lambda (d)
                     (let ((base (file-name-nondirectory (directory-file-name d))))
                       (and (not (member base '(".git" "target" "node_modules" ".Trash" "Library" ".cache" ".config")))
                            (condition-case nil (progn (directory-files d) t) (error nil))))))))
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

(add-to-list 'macher-workspace-types-alist
             '(agent . (:get-root macher-agent--get-root
                                  :get-name macher-agent--get-name
                                  :get-files macher-agent--get-files)))

(defun macher-workspace-agent ()
  (when macher-agent--is-workspace macher--workspace))

(add-hook 'macher-workspace-functions #'macher-workspace-agent)

(defun macher-agent--clone-context (ctx)
  (if (not ctx) nil
    (let ((new-ctx (macher-agent--make-vfs-context :workspace (when (fboundp 'macher-context-workspace) (macher-agent--get-context-workspace ctx))
                                                   :contents (copy-tree (macher-agent--get-context-contents ctx)))))
      (when (and (fboundp 'macher-context-prompt) (macher-agent--get-context-prompt ctx))
        (setf (macher-context-prompt new-ctx) (macher-agent--get-context-prompt ctx)))
      new-ctx)))

(defun macher-agent--merge-contexts (parent-ctx child-ctx)
  (let ((child-contents (macher-agent--get-context-contents child-ctx))
        (parent-contents (macher-agent--get-context-contents parent-ctx)))
    (dolist (child-entry child-contents)
      (let* ((path (car child-entry))
             (orig-new (cdr child-entry))
             (orig (car orig-new))
             (new (cdr orig-new)))
        (when (or (not (equal orig new))
                  (not (assoc path parent-contents)))
          (macher-agent--update-context-file parent-ctx path new))))))

(defun macher-agent--sync-context-entry (entry)
  (let* ((path (car entry))
         (content-pair (cdr entry))
         (orig (car content-pair))
         (new (cdr content-pair))
         (current-state (macher-agent--read-content-from-disk-or-buffer path)))
    (if (not (equal orig current-state))
        (if (equal new current-state)
            (progn (setcar content-pair current-state) t)
          (progn
            (setcar content-pair current-state)
            (setcdr content-pair current-state)
            t))
      nil)))

(defun macher-agent--auto-sync-context (ctx &rest _args)
  (when ctx
    (let ((contents (macher-agent--get-context-contents ctx))
          (synced nil))
      (dolist (entry contents)
        (when (macher-agent--sync-context-entry entry)
          (setq synced t)))
      (when synced
        (macher-agent--set-context-dirty-p ctx nil)
        (macher-agent--persist-vfs-to-hidden-buffer ctx)
        (run-hooks 'macher-agent-context-mutated-hook)))))

(defun macher-agent--persist-vfs-to-hidden-buffer (ctx)
  (let* ((workspace (when ctx (macher-agent--get-context-workspace ctx)))
         (root-dir (if workspace (macher-agent--get-workspace-root workspace) "default"))
         (buf-name (format " *macher-agent-vfs-state-%s*" (md5 (expand-file-name root-dir))))
         (vfs-buf (get-buffer-create buf-name)))
    (with-current-buffer vfs-buf
      (erase-buffer)
      (insert ";;; Macher Agent Virtual File System State\n")
      (insert ";;; This buffer is C-optimised and handles gigabytes of text effortlessly.\n\n")
      (when ctx
        (dolist (entry (macher-agent--get-context-contents ctx))
          (let ((path (car entry))
                (new-content (cddr entry)))
            (when new-content
              (insert (format "=== VFS ENTRY: %s ===\n" path))
              (insert new-content)
              (insert "\n=======================\n\n"))))))))

(defun macher-agent-apply-patch ()
  (interactive)
  (unless (derived-mode-p 'diff-mode) (user-error "Not in a patch/diff buffer"))
  (let* ((patch-content (buffer-substring-no-properties (point-min) (point-max)))
         (ctx (ignore-errors (macher-agent-current-context)))
         (ws (or (when ctx (macher-agent--get-context-workspace ctx))
                 (bound-and-true-p macher--workspace)))
         (root (if ws
                   (macher-agent--get-workspace-root ws)
                 (or (locate-dominating-file default-directory ".git") default-directory)))
         (default-directory (file-name-as-directory (expand-file-name root)))
         (use-git (locate-dominating-file default-directory ".git"))
         (cmd (if use-git "git" "patch"))
         (args (if use-git '("apply" "-p1" "-") '("-p1"))))
    (with-temp-buffer
      (insert patch-content)
      (let ((exit-code (apply #'call-process-region (point-min) (point-max) cmd nil "*macher-patch-out*" nil args)))
        (if (= exit-code 0)
            (progn (message "SUCCESS: Patch applied safely via %s from %s" cmd default-directory)
                   (when (get-buffer "*macher-patch-out*")
                     (kill-buffer "*macher-patch-out*")))
          (pop-to-buffer "*macher-patch-out*")
          (message "ERROR: Failed to apply patch safely."))))))

(defun macher-agent-insert-patch ()
  (interactive)
  (let* ((patch-buf (macher-patch-buffer))
         (content (when (buffer-live-p patch-buf)
                    (with-current-buffer patch-buf (buffer-substring-no-properties (point-min) (point-max))))))
    (if (or (null content) (string-empty-p content))
        (message "No patch available for current workspace.")
      (insert "\nHere is your proposed patch:\n```diff\n" content "\n```\n"))))

(defun macher-agent-clear-context ()
  (interactive)
  (if (not macher-agent--persistent-context)
      (message "No active context to clear in this buffer.")
    (setq-local macher-agent--persistent-context nil)
    (setq-local macher--fsm-latest nil)
    (run-hooks 'macher-agent-context-mutated-hook)
    (message "Agent memory cleared. It will take a fresh snapshot of the disk on its next task.")))

(provide 'macher-agent-vfs-client)
