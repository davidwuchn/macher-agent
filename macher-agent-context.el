;;; macher-agent-context.el --- Context and file system handling -*- lexical-binding: t; -*-

(require 'macher)

;; --- 1. Global Flags & State ---

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
  "Safely return files for the agent workspace, strictly ignoring unreadable directories."
  (condition-case nil
      (directory-files-recursively
       dir "^[^.]" nil
       (lambda (d)
         (let ((base (file-name-nondirectory (directory-file-name d))))
           (and (not (member base '(".git" "target" "node_modules" ".Trash" "Library")))
                (condition-case nil
                    (progn (directory-files d) t)
                  (error nil))))))
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

(defun macher-agent--auto-sync-context (ctx)
  "Check live buffers and physical disk to fast-forward the agent's memory if needed."
  (when ctx
    (let ((contents (macher-context-contents ctx))
          (synced nil))
      (dolist (entry contents)
        (let* ((path (car entry))
               (content-pair (cdr entry))
               (orig (car content-pair))
               (new (cdr content-pair))
               (buf (get-file-buffer path))
               (disk-exists (file-exists-p path))
               ;; 1. Determine the true current state (Buffer > Disk > Deleted)
               (current-state 
                (cond
                 ((and buf (buffer-modified-p buf))
                  (with-current-buffer buf
                    (buffer-substring-no-properties (point-min) (point-max))))
                 (disk-exists
                  (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string)))
                 (t nil))))
          
          (cond
           ;; Case A: File was deleted externally
           ((null current-state)
            (when (or orig new)
              (setcar content-pair nil)
              (setcdr content-pair nil)
              (setq synced t)))
           
           ;; Case B: External state caught up to 'new' (e.g. Patch was applied)
           ((and new (equal current-state new) (not (equal orig new)))
            (setcar content-pair current-state)
            (setq synced t))
           
           ;; Case C: External state diverged completely (External edit)
           ((and (not (equal current-state orig)) (not (equal current-state new)))
            (setcar content-pair current-state)
            (setcdr content-pair current-state)
            (setq synced t)))))
      
      (when synced
        (setf (macher-context-dirty-p ctx) nil)))))

(defvar macher-agent-context-resolved-functions nil
  "Abnormal hook run when a macher context is lazily resolved for a request.

Functions are called with two arguments: (CONTEXT FSM).
Functions can be used to modify the CONTEXT object, trigger side-effects,
or update the FSM state.")

(defun macher-agent--simulate-resolved-hook-advice (orig-fn fsm get-context)
  "Simulate an upstream hook that fires when the context is resolved."
  (let ((wrapped-get-context
         (lambda ()
           (let ((ctx (funcall get-context)))
             (run-hook-with-args 'macher-agent-context-resolved-functions ctx fsm)
             (plist-get (gptel-fsm-info fsm) :macher--context)))))
    (funcall orig-fn fsm wrapped-get-context)))

(add-hook 'macher-agent-context-resolved-functions #'macher-agent-persist-context-hook)

(defun macher-agent-persist-context-hook (ctx fsm)
  "Maintain a persistent context and synchronise it with the disk."
  (when ctx
    (unless macher-agent--persistent-context
      (setq macher-agent--persistent-context ctx))
    
    (let ((persistent-ctx macher-agent--persistent-context))
      (macher-agent--auto-sync-context persistent-ctx)
      
      (let ((fsm-info (gptel-fsm-info fsm)))
        (setf (gptel-fsm-info fsm) 
              (plist-put fsm-info :macher--context persistent-ctx)))
      
      (setq macher--fsm-latest fsm))))

(add-hook 'macher-context-resolved-functions #'macher-agent-persist-context-hook)

;; --- 4. Interactive Commands ---

(defun macher-agent-apply-patch ()
  "Apply the current patch buffer using external diff utilities to avoid collisions."
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

(provide 'macher-agent-context)
;;; macher-agent-context.el ends here
