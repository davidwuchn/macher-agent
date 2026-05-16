;;; macher-agent-context.el --- Context and file system handling -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'macher)
(require 'gptel nil t)

(declare-function gptel-fsm-info "gptel" (fsm))

(defvar macher-agent-context-mutated-hook nil
  "Hook run whenever the agent's context is modified.")

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
      ;; Lazy Initialization: Start from a blank slate with FULL macher integration.
      (let ((new-ctx (macher--make-context
                      :workspace (when (fboundp 'macher-workspace) (macher-workspace))
                      :process-request-function (when (boundp 'macher-process-request-function) 
                                                  macher-process-request-function))))
        (setq-local macher-agent--persistent-context new-ctx)
        new-ctx)))))

(defun macher-agent--get-buffer-content (path)
  "Get the content of a buffer or file by path."
  (cond
   ((or (get-file-buffer path) (get-buffer path))
    (with-current-buffer (or (get-file-buffer path) (get-buffer path))
      (buffer-substring-no-properties (point-min) (point-max))))
   ((file-exists-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string)))
   (t nil)))

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
  "Classify PATH-OR-BUF as a workspace 'file', 'external', or 'buffer'.
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
  "Safely return files for the agent workspace, respecting VC ignores."
  (condition-case nil
      (if-let ((proj (project-current nil dir)))
          (project-files proj)
        ;; Fallback if not in a recognized project
        (directory-files-recursively
         dir "^[^.]" nil
         (lambda (d)
           (let ((base (file-name-nondirectory (directory-file-name d))))
             (and (not (member base '(".git" "target" "node_modules" ".Trash" "Library")))
                  (condition-case nil
                      (progn (directory-files d) t)
                    (error nil)))))))
    (error nil)))

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
  (let ((parent-contents (macher-context-contents parent-ctx))
        (child-contents (macher-context-contents child-ctx)))
    (dolist (child-entry child-contents)
      (let* ((path (car child-entry))
             (orig-new (cdr child-entry))
             (orig (car orig-new))
             (new (cdr orig-new)))
        ;; Only merge if content is dirty (or was modified)
        (unless (equal orig new)
          (macher-agent--update-context-file parent-ctx path new))))))

(defun macher-agent--auto-sync-context (ctx &optional fsm &rest _args)
  "Check live buffers and physical disk to fast-forward the agent's memory using strict three-way merge logic."
  (let ((actual-ctx (if fsm (macher-agent--fsm-get-context fsm) ctx)))
    (when actual-ctx
      (let ((contents (macher-context-contents actual-ctx))
            (synced nil))
        (dolist (entry contents)
          (let* ((path (car entry))
                 (content-pair (cdr entry))
                 (orig (car content-pair))
                 (new (cdr content-pair))
                 (buf (or (get-file-buffer path) (get-buffer path)))
                 (disk-exists (file-exists-p path))
                 (current-state 
                  (cond
                   ((and buf (buffer-live-p buf))
                    (with-current-buffer buf
                      (buffer-substring-no-properties (point-min) (point-max))))
                   (disk-exists
                    (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string)))
                   (t nil)))
                 
                 ;; Establish our truth table booleans
                 (local-changed (not (equal orig new)))
                 (remote-changed (not (equal orig current-state))))
            
            (cond
             ;; 1. Clean Convergence: The patch was applied externally
             ((and local-changed remote-changed (equal new current-state))
              (setcar content-pair current-state)
              (setq synced t))

             ;; 2. Fast-Forward: External edit only (or external deletion)
             ((and remote-changed (not local-changed))
              (setcar content-pair current-state)
              (setcdr content-pair current-state)
              (setq synced t))

             ;; 3. True Conflict: Both diverged to different states
             ((and local-changed remote-changed (not (equal new current-state)))
              ;; The safest autonomous action is cache invalidation (adopt remote)
              (setcar content-pair current-state)
              (setcdr content-pair current-state)
              (setq synced t))

             ;; 4. Stale Virtual Edit (Unapplied Patch)
             ;; The agent proposed an edit, but it was ignored by the user.
             ;; Invalidate the edit to prevent ghost diffs on the next turn.
             ((and local-changed (not remote-changed))
              (setcar content-pair current-state)
              (setcdr content-pair current-state)
              (setq synced t)))))
        
        (when synced
          (setf (macher-context-dirty-p actual-ctx) nil)
          (run-hooks 'macher-agent-context-mutated-hook))))))

;; --- Adapters ---

(defun macher-agent--fsm-put-context (fsm ctx)
  "Adapter to securely embed the macher context within the gptel FSM."
  (let ((fsm-info (gptel-fsm-info fsm)))
    (setf (gptel-fsm-info fsm) 
          (plist-put fsm-info :macher--context ctx))))

(defun macher-agent--fsm-get-context (fsm)
  "Adapter to securely retrieve the macher context from the gptel FSM."
  (plist-get (gptel-fsm-info fsm) :macher--context))

(defvar macher-agent-context-resolved-functions nil
  "Abnormal hook run when a macher context is lazily resolved for a request.

Functions are called with two arguments: (CONTEXT FSM).
Functions can be used to modify the CONTEXT object, trigger side-effects,
or update the FSM state.")



;; --- 4. Interactive Commands ---

(defun macher-agent-apply-patch ()
  "Apply the current patch buffer using Emacs's native diff-mode."
  (interactive)
  (unless (derived-mode-p 'diff-mode)
    (user-error "Not in a patch/diff buffer"))
  (condition-case err
      (progn
        (diff-apply-buffer)
        (message "SUCCESS: Patch applied safely via diff-mode."))
    (error
     (message "ERROR: Failed to apply patch safely: %s" (error-message-string err)))))

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
  "Apply proposed virtual edits directly to live Emacs buffers.
This bypasses external patch utilities, which expect physical files. As an alternative to ediff-patch-buffer"
  (interactive)
  (let* ((workspace (when (fboundp 'macher-workspace) (macher-workspace)))
         ;; 1. Look for memory in the current buffer
         ;; 2. Fallback: Search all live buffers for one sharing the same workspace that HAS memory
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
        ;; Check if it's a pure buffer that isn't visiting a file
        (let ((buf (get-buffer path-or-name)))
          (when (and buf new-content (not (buffer-file-name buf)))
            (with-current-buffer buf
              (erase-buffer)
              (insert new-content))
            (cl-incf applied-count)))))
    
    ;; Sync context so the agent knows it was applied
    (macher-agent--auto-sync-context context)
    (message "SUCCESS: Applied virtual changes to %d Emacs buffer(s)." applied-count)))

;; --- Bridge to Native Macher Patch Engine ---

(defun macher-agent--bridge-context-advice (orig-fun fsm get-context)
  "Bridge the native macher setup with the agent's persistent memory."
  ;; 1. Run native setup
  (funcall orig-fun fsm get-context)
  
  ;; 2. Force macher.el to initialize its internal state (awakens the native UI handler)
  (let* ((info (gptel-fsm-info fsm))
         (buf (plist-get info :buffer))
         (pers-ctx (when (buffer-live-p buf)
                     (buffer-local-value 'macher-agent--persistent-context buf)))
         (new-ctx (funcall get-context)))
    
    (when new-ctx
      (if pers-ctx
          ;; 3a. Multi-turn: Overwrite macher's blank slate with our persistent memory
          (macher-agent--fsm-put-context fsm pers-ctx)
        ;; 3b. Turn 1: Save the initial blank slate as our persistent memory
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq-local macher-agent--persistent-context new-ctx)))))))

;; Apply the new secure internal bridge
(advice-add 'macher--setup-tools :around #'macher-agent--bridge-context-advice)

(provide 'macher-agent-context)
;;; macher-agent-context.el ends here
