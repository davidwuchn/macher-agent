;;; macher-agent-context.el --- Context and file system handling -*- lexical-binding: t; -*-

(require 'project)

(defvar-local macher-agent--persistent-context nil
  "Stores the macher context across continuous agent tool turns.")

(cl-defmethod project-root ((project (head macher-agent)))
  "Return the root directory for an isolated sub-agent workspace."
  (cdr project))

(cl-defmethod project-files ((project (head macher-agent)) &optional dirs)
  "Safely return files for the agent workspace, strictly ignoring unreadable directories."
  (let ((root (cdr project)))
    (condition-case nil
        (directory-files-recursively
         root "^[^.]" nil
         (lambda (d)
           (let ((base (file-name-nondirectory (directory-file-name d))))
             (and (not (member base '(".git" "target" "node_modules" ".Trash" "Library")))
                  (condition-case nil
                      (progn (directory-files d) t)
                    (error nil))))))
      (error nil))))

(defun macher-agent--auto-sync-context (ctx)
  "Check the physical disk and fast-forward the agent's memory if needed."
  (when ctx
    (let ((contents (macher-context-contents ctx))
          (synced nil))
      (dolist (entry contents)
        (let* ((path (car entry))
               (content-pair (cdr entry))
               (orig (car content-pair))
               (new (cdr content-pair))
               (disk (when (file-exists-p path)
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string)))))
          (when disk
            (cond
             ((and new (string= disk new) (not (string= orig new)))
              (setcar content-pair disk)
              (setq synced t))
             ((and (not (string= disk orig)) (not (string= disk new)))
              (setcar content-pair disk)
              (setcdr content-pair disk)
              (setq synced t))))))
      (when synced
        (setf (macher-context-dirty-p ctx) nil)))))

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
