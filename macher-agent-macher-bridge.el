;;; macher-agent-macher-bridge.el --- Bridge to Macher Core -*- lexical-binding: t; -*-

(require 'macher)
(require 'cl-lib)

(declare-function macher-agent-workspace-project-root "macher-agent-vfs-client")
(declare-function macher-agent-workspace-p "macher-agent-vfs-client")
(declare-function macher-agent-current-context "macher-agent-vfs-client")

;; --- Workspace Helpers ---

(defun macher-agent--get-workspace-root (ws)
  (cond
   ((and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
    (macher-agent-workspace-project-root ws))
   ((and (consp ws) (eq (car ws) 'agent) (not (stringp (cdr ws))))
    (macher-agent-workspace-project-root (cdr ws)))
   ((fboundp 'macher--workspace-root)
    (ignore-errors (macher--workspace-root ws)))
   (t nil)))

(defun macher-agent--get-workspace-name (ws)
  (cond
   ((and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root ws))))
   ((and (consp ws) (eq (car ws) 'agent) (not (stringp (cdr ws))))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root (cdr ws)))))
   ((fboundp 'macher--workspace-name)
    (ignore-errors (macher--workspace-name ws)))
   (t "unknown")))

;; --- VFS Splitter ---

(defun macher-agent--split-vfs-contents (contents)
  "Split raw VFS contents into pure virtual and physical lists."
  (let ((virtual-contents nil)
        (physical-contents nil))
    (dolist (entry contents)
      (let* ((name (car entry))
             (live-buf (get-buffer name))
             (is-pure-virtual (and live-buf (null (buffer-file-name live-buf)))))
        (if is-pure-virtual
            (push entry virtual-contents)
          (push entry physical-contents))))
    (cons (nreverse virtual-contents) (nreverse physical-contents))))

;; --- Core Crash Fixes ---

(defun macher-agent--safe-workspace-hash (workspace &rest _args)
  "Nuke the core recursive hashing function which causes depth crashes."
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

;; --- The Constructor Interceptor ---

(defvar macher-agent--bypass-context-override nil
  "Internal flag to prevent intercepting our own ephemeral diff contexts.")

(defun macher-agent--override-make-context (orig-fn &rest kwargs)
  "Intercept the upstream constructor to natively enforce the VFS singleton."
  (let ((persistent-ctx (bound-and-true-p macher-agent--persistent-context)))
    (if (and persistent-ctx (not macher-agent--bypass-context-override))
        (progn
          ;; Safely update dynamic request properties on the persistent singleton
          (when (plist-member kwargs :prompt)
            (setf (macher-context-prompt persistent-ctx) (plist-get kwargs :prompt)))
          (when (plist-member kwargs :process-request-function)
            (setf (macher-context-process-request-function persistent-ctx) (plist-get kwargs :process-request-function)))
          persistent-ctx)
      (apply orig-fn kwargs))))

(advice-add 'macher--make-context :around #'macher-agent--override-make-context)

(cl-defun macher-agent--make-vfs-context (&key workspace contents)
  "Create an ephemeral context, safely bypassing the singleton constructor interceptor."
  (let ((macher-agent--bypass-context-override t))
    (macher--make-context :workspace workspace :contents contents)))

;; --- The Elegant UI Splitter (Buffer Rename Paradigm) ---

(defun macher-agent--override-build-patch (orig-fn context &optional fsm)
  "Override the upstream patch builder to support split Virtual/Physical diffs.
  Uses the buffer-rename paradigm to let the upstream core do all the heavy lifting."
  (let* ((vfs-ctx (ignore-errors (macher-agent-current-context)))
         (raw-contents (or (when vfs-ctx (macher-agent--get-context-contents vfs-ctx))
                           (macher-context-contents context)))
         (categorised (macher-agent--split-vfs-contents raw-contents))
         (virtual-contents (car categorised))
         (physical-contents (cdr categorised))
         (ws (macher-context-workspace context)))

    ;; 1. VIRTUAL BUFFERS
    (when virtual-contents
      (let ((v-ctx (macher-agent--make-vfs-context :workspace ws :contents virtual-contents)))
        (setf (macher-context-prompt v-ctx) (macher-context-prompt context))
        (funcall orig-fn v-ctx fsm)
        
        ;; Intercept the newly minted patch buffer and rename it to protect it from the next run
        (when-let ((patch-buf (car (macher--get-buffer "patch" ws nil))))
          (with-current-buffer patch-buf
            (rename-buffer (format "*macher-virtual-patch:%s*" (macher-agent--get-workspace-name ws)) t)))))

    ;; 2. PHYSICAL FILES
    ;; Always run this pass even if empty, so the core package naturally generates 
    ;; its native "No changes were made" UI if needed.
    (let ((p-ctx (macher-agent--make-vfs-context :workspace ws :contents physical-contents))
          (shadow-descriptors nil))
      (setf (macher-context-prompt p-ctx) (macher-context-prompt context))
      
      ;; Identify physical files that have active open back buffers visiting them,
      ;; and construct the shadow descriptors to temporarily redirect buffer operations.
      (dolist (entry physical-contents)
        (let* ((file-path (car entry))
               (new-content (cdr (cdr entry)))
               (orig-buf (or (get-file-buffer file-path)
                             (find-buffer-visiting file-path))))
          (when (and orig-buf (buffer-live-p orig-buf))
            (push (list :original-buffer orig-buf
                        :original-file-name (buffer-file-name orig-buf)
                        :original-buffer-name (buffer-name orig-buf)
                        :file-path file-path
                        :new-content new-content
                        :shadow-buffer nil)
                  shadow-descriptors))))
      
      (unwind-protect
          (progn
            ;; Temporarily rename and detach the user's real buffers, and create shadow buffers
            (dolist (desc shadow-descriptors)
              (let* ((orig-buf (plist-get desc :original-buffer))
                     (orig-name (plist-get desc :original-buffer-name))
                     (file-path (plist-get desc :file-path))
                     (new-content (plist-get desc :new-content))
                     (temp-name (generate-new-buffer-name (format " *macher-hidden-%s*" orig-name))))
                (with-current-buffer orig-buf
                  (rename-buffer temp-name t)
                  (setq buffer-file-name nil))
                
                (let* ((shadow-buf (get-buffer-create orig-name))
                       (exact-dir (file-name-directory (expand-file-name file-path))))
                  (with-current-buffer shadow-buf
                    (setq default-directory exact-dir)
                    (setq buffer-file-name file-path)
                    (setq buffer-file-truename (file-truename file-path))
                    (insert new-content)
                    (set-buffer-modified-p nil))
                  (plist-put desc :shadow-buffer shadow-buf))))
            
            ;; Execute the core patch builder
            (funcall orig-fn p-ctx fsm))
        
        ;; Cleanup phase: destroy shadow buffers and perfectly restore original buffers
        (dolist (desc shadow-descriptors)
          (let ((shadow (plist-get desc :shadow-buffer))
                (orig-buf (plist-get desc :original-buffer))
                (orig-name (plist-get desc :original-buffer-name))
                (orig-file (plist-get desc :original-file-name)))
            (when (and shadow (buffer-live-p shadow))
              (with-current-buffer shadow
                (setq buffer-file-name nil))
              (kill-buffer shadow))
            (when (and orig-buf (buffer-live-p orig-buf))
              (with-current-buffer orig-buf
                (setq buffer-file-name orig-file)
                (rename-buffer orig-name t)))))))))

(advice-add 'macher--build-patch :around #'macher-agent--override-build-patch)

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
