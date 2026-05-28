;;; macher-agent-context.el --- Context and file system handling -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'macher)
(require 'gptel nil t)
(require 'xref)

(declare-function gptel-fsm-info "gptel" (fsm))

(defvar macher-agent-context-mutated-hook nil
  "Hook run whenever the agent's context is modified.")

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
  "Dynamically resolve the active agent context for tool execution."
  (let* ((fsm (bound-and-true-p macher--fsm-latest))
         (fsm-ctx (when fsm (macher-agent--fsm-get-context fsm)))
         (pers-ctx (bound-and-true-p macher-agent--persistent-context)))
    (cond
     (pers-ctx pers-ctx)
     (fsm-ctx
      (setq-local macher-agent--persistent-context fsm-ctx)
      fsm-ctx)
     (t
      (let ((primary-ctx nil)
            (current-root (or (and (fboundp 'vc-root-dir) (vc-root-dir))
                              default-directory)))
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (and (bound-and-true-p macher-agent--is-workspace)
                       (bound-and-true-p macher-agent--persistent-context))
              (let* ((ws (when (fboundp 'macher-context-workspace) 
                           (macher-context-workspace macher-agent--persistent-context)))
                     (agent-root (when ws (macher--workspace-root ws))))
                (when (and agent-root
                           current-root
                           (string-prefix-p (expand-file-name agent-root)
                                            (expand-file-name current-root)))
                  (if primary-ctx
                      (error "Multiple active agent sessions found; cannot resolve primary context")
                    (setq primary-ctx macher-agent--persistent-context)))))))
        (unless primary-ctx
          (error "No active agent session found"))
        (setq-local macher-agent--persistent-context primary-ctx)
        primary-ctx)))))

(defun macher-agent--read-content-from-disk-or-buffer (path)
  "Read the content of PATH from its live buffer or physical file."
  (let ((buf (or (get-file-buffer path) (get-buffer path))))
    (cond
     ((and buf (buffer-live-p buf))
      (with-current-buffer buf
        (buffer-substring-no-properties (point-min) (point-max))))
     ((file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))
     (t nil))))

(defun macher-agent--get-buffer-content (path)
  "Get the content of a buffer or file by path."
  (let* ((ctx (macher-agent-current-context))
         (workspace (when ctx (macher-context-workspace ctx)))
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
        (let ((orig (macher-agent--get-buffer-content path)))
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
      (macher-agent--get-buffer-content path))
     (t (error "ERROR: Buffer '%s' does not exist." path)))))

(defun macher-agent-context-classify-entry (path-or-buf &optional root-dir)
  "Classify PATH-OR-BUF as a workspace \\='file\\=', \\='external\\=', or \\='buffer\\='.
Optional ROOT-DIR is used to determine if a file resides within the workspace."
  (let* ((expanded (expand-file-name path-or-buf))
         (buf (get-buffer path-or-buf))
         (file-from-buf (and buf (buffer-file-name buf)))
         (is-absolute (file-name-absolute-p path-or-buf))
         (has-slash (string-match-p "/" path-or-buf)))
    (cond
     ;; 1. Check if it is a physical file or visits a file
     ((or (and file-from-buf (file-exists-p file-from-buf))
          (file-exists-p expanded)
          is-absolute
          has-slash)
      (let ((path (or (and file-from-buf (file-exists-p file-from-buf) file-from-buf) expanded)))
        (if (and root-dir (string-prefix-p (expand-file-name root-dir) path))
            'file
          'external)))
     ;; 2. Otherwise treat as a pure buffer
     (t 'buffer))))


(defvar-local macher-agent--is-workspace nil
  "Flag indicating this buffer operates under the safe macher-agent file scanner.")

(defvar-local macher-agent--persistent-context nil
  "Stores the macher context across continuous agent tool turns.")

;; --- 2. Native Macher Workspace Definition ---

(defun macher-agent--get-root (dir)
  "Return the root directory for the agent workspace."
  dir)

(defun macher-agent--get-name (dir)
  "Return a safe name for the isolated sub-agent workspace."
  (concat "Agent: " (file-name-nondirectory (directory-file-name dir))))

(defun macher-agent--get-files (dir)
  "Safely return files for the agent workspace, respecting VC ignores.
Enforces strict boundary validation to prevent unbounded scans of home or root."
  (let ((expanded-dir (expand-file-name dir)))
    (condition-case err
        (if-let ((proj (project-current nil expanded-dir)))
            (let ((proj-root (expand-file-name (project-root proj))))
              (if (or (string= proj-root (expand-file-name "~/"))
                      (string= proj-root (expand-file-name "~"))
                      (string= proj-root "/")
                      (string= proj-root (expand-file-name "/")))
                  (error "SECURITY HALT: Project root detected as '%s', which is too broad. Unbounded scans are prohibited." proj-root)
                (project-files proj)))
          (error "SECURITY HALT: Workspace '%s' is not under version control. Unbounded scans are prohibited." expanded-dir))
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

;; --- 3. Context Synchronisation & Persistence ---

(defun macher-agent--clone-context (ctx)
  "Return a deep copy of the context object."
  (copy-tree ctx))

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
  "Synchronize a single virtual memory ENTRY against disk/buffer state."
  (let* ((path (car entry))
         (content-pair (cdr entry))
         (orig (car content-pair))
         (new (cdr content-pair))
         (current-state (macher-agent--read-content-from-disk-or-buffer path)))
    (when (or (not (equal orig new))
              (not (equal orig current-state)))
      (setcar content-pair current-state)
      (setcdr content-pair current-state)
      t)))

(defun macher-agent--auto-sync-context (ctx &optional fsm &rest _args)
  "Check live buffers and physical disk to fast-forward the agent's memory."
  (let ((actual-ctx (if fsm (macher-agent--fsm-get-context fsm) ctx)))
    (when actual-ctx
      (let ((contents (macher-context-contents actual-ctx))
            (synced nil))
        (dolist (entry contents)
          (when (macher-agent--sync-context-entry entry)
            (setq synced t)))
        (when synced
          (setf (macher-context-dirty-p actual-ctx) nil)
          (macher-agent--persist-vfs-to-hidden-buffer actual-ctx)
          (run-hooks 'macher-agent-context-mutated-hook))))))

(defun macher-agent--persist-vfs-to-hidden-buffer (ctx)
  "Persist the VFS state to a dedicated hidden buffer.
This moves the heavy string payload out of raw Lisp variables into a
C-optimised gap buffer, preventing memory loops. Uses a unique buffer
per workspace to prevent cross-contamination."
  (let* ((workspace (when (fboundp 'macher-context-workspace) (macher-context-workspace ctx)))
         (root-dir (if workspace (macher--workspace-root workspace) "default"))
         (buf-name (format " *macher-agent-vfs-state-%s*" (md5 (expand-file-name root-dir))))
         (vfs-buf (get-buffer-create buf-name)))
    (with-current-buffer vfs-buf
      (erase-buffer)
      ;; Insert a lightweight, parsable dump of the VFS
      (insert ";;; Macher Agent Virtual File System State\n")
      (insert ";;; This buffer is C-optimised and handles gigabytes of text effortlessly.\n\n")
      (dolist (entry (macher-context-contents ctx))
        (let ((path (car entry))
              (new-content (cddr entry)))
          (when new-content
            (insert (format "=== VFS ENTRY: %s ===\n" path))
            (insert new-content)
            (insert "\n=======================\n\n")))))))

;; --- Adapters ---

(defun macher-agent--fsm-put-context (fsm ctx)
  "Adapter to securely embed the macher context within the gptel FSM."
  (let ((fsm-info (gptel-fsm-info fsm)))
    (setf (gptel-fsm-info fsm) 
          (plist-put fsm-info :macher--context ctx))))

(defun macher-agent--fsm-get-context (fsm)
  "Adapter to securely retrieve the macher context from the gptel FSM."
  (plist-get (gptel-fsm-info fsm) :macher--context))



(defun macher-agent--handle-termination (terminated-fsm)
  "Handle completion of an agent's reasoning cycle."
  (let ((ctx (macher-agent--fsm-get-context terminated-fsm)))
    (when (and ctx (macher-context-dirty-p ctx))
      (setf (gptel-fsm-info terminated-fsm)
            (plist-put (gptel-fsm-info terminated-fsm) :macher--context ctx))
      (macher-process-request 'complete terminated-fsm))))

(defun macher-agent--bridge-context-advice (orig-fun fsm get-context)
  "Bridge macher setup with the agent's memory by proxying the context generator.
Enforces explicit context hunting to prevent orphaned ghost sessions."
  (let* ((info (gptel-fsm-info fsm))
         (buf (plist-get info :buffer))
         (pers-ctx (when (buffer-live-p buf)
                     (buffer-local-value 'macher-agent--persistent-context buf)))
         (resolved-ctx nil))
    
    (when pers-ctx
      (macher-agent--auto-sync-context pers-ctx))
    
    (let ((proxy-get-context
           (lambda ()
             (or resolved-ctx
                 (setq resolved-ctx
                       (or pers-ctx
                           (condition-case err
                               (macher-agent-current-context)
                             (error
                              (if (string= (error-message-string err) "Multiple active agent sessions found; cannot resolve primary context")
                                  (error (error-message-string err))
                                (let ((new-ctx (funcall get-context)))
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf
                                      (setq-local macher-agent--is-workspace t)
                                      (setq-local macher-agent--persistent-context new-ctx)))
                                  new-ctx))))))))))
      
      (funcall orig-fun fsm proxy-get-context)
      
      (let ((final-ctx (funcall proxy-get-context)))
        (when final-ctx
          (macher-agent--fsm-put-context fsm final-ctx)
          (macher--add-termination-handler fsm #'macher-agent--handle-termination))))))

;; Apply the new secure internal bridge
(advice-add 'macher--setup-tools :around #'macher-agent--bridge-context-advice)

;; --- Virtual Buffer Splitter ---

(defun macher-agent--split-context (context)
  "Splits the context into (file-context . buffer-context)."
  (let ((files nil)
        (buffers nil))
    (dolist (entry (macher-context-contents context))
      (let* ((path-or-name (car entry))
             (buf (get-buffer path-or-name)))
        (if (and buf (not (buffer-file-name buf)))
            (push entry buffers)
          (push entry files))))
    (cons
     (when files
       (let ((c (copy-macher-context context)))
         (setf (macher-context-contents c) (nreverse files))
         c))
     (when buffers
       (let ((c (copy-macher-context context)))
         (setf (macher-context-contents c) (nreverse buffers))
         c)))))

(defun macher-agent--build-virtual-patch (buf-ctx fsm)
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
    (macher--build-patch buf-ctx fsm)))

(defun macher-agent-process-request-split (_reason context fsm)
  "Processes the request by splitting file edits and pure buffer edits.
Diff screen presentation is suppressed for sub-agents."
  (unless (bound-and-true-p macher-agent--is-subagent)
    (when (and context (macher-context-dirty-p context))
      (let* ((split (macher-agent--split-context context))
             (file-ctx (car split))
             (buf-ctx (cdr split)))
        (when file-ctx
          (macher--build-patch file-ctx fsm))
        (when buf-ctx
          (macher-agent--build-virtual-patch buf-ctx fsm))))))

;; Override the native default processor with our splitting processor
(setq macher-process-request-function #'macher-agent-process-request-split)

;; --- 4. Interactive Commands ---

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

(defun macher-agent-apply-virtual-buffers ()
  "Apply proposed virtual edits directly to live Emacs buffers."
  (interactive)
  (let* ((workspace (when (fboundp 'macher-workspace) (macher-workspace)))
         (context (or (bound-and-true-p macher-agent--persistent-context)
                      (when (bound-and-true-p macher--fsm-latest)
                        (macher-agent--fsm-get-context macher--fsm-latest))
                      (cl-some (lambda (buf)
                                 (when (and workspace (equal workspace (buffer-local-value 'macher--workspace buf)))
                                   (buffer-local-value 'macher-agent--persistent-context buf)))
                               (buffer-list))))
         (applied-count 0))
    
    (unless context
      (user-error "No active context found in this session."))
    
    (dolist (entry (macher-context-contents context))
      (let* ((path-or-name (car entry))
             (new-content (cddr entry)))
        (let ((buf (get-buffer path-or-name)))
          (when (and buf new-content (not (buffer-file-name buf)))
            (with-current-buffer buf
              (erase-buffer)
              (insert new-content))
            (cl-incf applied-count)))))
    
    (macher-agent--auto-sync-context context)
    (message "SUCCESS: Applied virtual changes to %d Emacs buffer(s)." applied-count)))

(provide 'macher-agent-context)
;;; macher-agent-context.el ends here
