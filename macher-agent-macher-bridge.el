;;; macher-agent-macher-bridge.el --- Bridge to Macher Core -*- lexical-binding: t; -*-

(require 'macher)
(require 'cl-lib)

(declare-function macher-agent-workspace-project-root "macher-agent-vfs-client")
(declare-function macher-agent-workspace-p "macher-agent-vfs-client")
(declare-function macher-agent-resolve-context "macher-agent-vfs-client")
(declare-function macher-agent-vfs-entry-path "macher-agent-vfs-client")
(declare-function macher-agent-vfs-entry-curr "macher-agent-vfs-client")

(defun macher-agent--get-workspace-root (ws)
  (macher-agent-root ws))

(defun macher-agent--get-workspace-name (ws)
  (cond
   ((and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ws))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root ws))))
   ((and (consp ws) (eq (car ws) 'agent) (not (stringp (cdr ws))))
    (file-name-nondirectory (directory-file-name (macher-agent-workspace-project-root (cdr ws)))))
   ((fboundp 'macher--workspace-name)
    (ignore-errors (macher--workspace-name ws)))
   (t "unknown")))

(defun macher-agent--split-vfs-contents (contents)
  "Split raw VFS contents into pure virtual and physical lists."
  (let ((virtual-contents nil)
        (physical-contents nil))
    (dolist (entry contents)
      (let* ((name (macher-agent-vfs-entry-path entry))
             (live-buf (get-buffer name))
             (is-pure-virtual (and live-buf (null (buffer-file-name live-buf)))))
        (if is-pure-virtual
            (push entry virtual-contents)
          (push entry physical-contents))))
    (cons (nreverse virtual-contents) (nreverse physical-contents))))

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

(defvar macher-agent--bypass-context-override nil
  "Internal flag to prevent intercepting our own ephemeral diff contexts.")

(defun macher-agent--override-make-context (orig-fn &rest kwargs)
  "Intercept the upstream constructor to natively enforce the VFS singleton."
  (let ((persistent-ctx (bound-and-true-p macher-agent--persistent-context)))
    (if (and persistent-ctx (not macher-agent--bypass-context-override))
        (progn
          (when (plist-member kwargs :prompt)
            (setf (macher-context-prompt persistent-ctx) (plist-get kwargs :prompt)))
          (when (plist-member kwargs :process-request-function)
            (setf (macher-context-process-request-function persistent-ctx) (plist-get kwargs :process-request-function)))
          
          (when-let ((contents (plist-get kwargs :contents)))
            (let* ((ws (macher-agent--get-context-workspace persistent-ctx))
                   (project-root (if ws (macher-agent-root ws) default-directory)))
              (dolist (e contents)
                (let ((struct-entry (macher-agent--hydrate-vfs-entry e project-root)))
                  (macher-agent--update-context-file persistent-ctx 
                                                     (macher-agent-vfs-entry-path struct-entry) 
                                                     (macher-agent-vfs-entry-curr struct-entry))))))
          persistent-ctx)
      (apply orig-fn kwargs))))

(advice-add 'macher--make-context :around #'macher-agent--override-make-context)

(cl-defun macher-agent--make-vfs-context (&key workspace contents)
  "Create an ephemeral context, safely bypassing the singleton constructor interceptor."
  (let ((macher-agent--bypass-context-override t))
    (macher--make-context :workspace workspace :contents contents)))

(defun macher-agent--hydrate-vfs-entry (e project-root)
  "Hydrate an upstream context list into a populated VFS struct."
  (let* ((path (car e))
         (full-path (expand-file-name path project-root))
         (orig-raw (if (consp (cdr e)) (car (cdr e)) nil))
         (new-raw (if (consp (cdr e)) (cdr (cdr e)) (cdr e)))
         (orig-str (cond ((stringp orig-raw) orig-raw)
                         ((file-exists-p full-path)
                          (macher-agent--read-content-from-disk-or-buffer full-path))
                         (t nil)))
         (new-str (if (stringp new-raw) new-raw nil)))
    (macher-agent-vfs-make-entry path orig-str new-str)))

(defun macher-agent--dehydrate-vfs-entry (entry)
  "Dehydrate a VFS struct back into the legacy list format expected by core macher."
  (cons (macher-agent-vfs-entry-path entry)
        (cons (macher-agent-vfs-entry-orig entry)
              (macher-agent-vfs-entry-curr entry))))

(defun macher-agent--prepare-patch-contexts (context fsm project-root)
  "Calculate and return isolated contexts for virtual buffers and physical files."
  (let* ((vfs-ctx (or (ignore-errors (macher-agent-resolve-context (or fsm context))) context))
         (struct-contents (or (when vfs-ctx (macher-agent--get-context-contents vfs-ctx))
                              (macher-agent--get-context-contents context)))
         (categorised (macher-agent--partition-vfs-entries struct-contents project-root))
         (virtual-contents (car categorised))
         (physical-contents (cdr categorised))
         (macher-compatible-ws (cons 'project project-root))
         (v-ctx (when virtual-contents
                  (let ((ctx (macher-agent--make-vfs-context :workspace macher-compatible-ws
                                                             :contents (mapcar #'macher-agent--dehydrate-vfs-entry virtual-contents))))
                    (setf (macher-context-prompt ctx) (macher-agent--get-context-prompt context))
                    ctx)))
         (p-ctx (when physical-contents
                  (let ((ctx (macher-agent--make-vfs-context :workspace macher-compatible-ws
                                                             :contents (mapcar #'macher-agent--dehydrate-vfs-entry physical-contents))))
                    (setf (macher-context-prompt ctx) (macher-agent--get-context-prompt context))
                    ctx))))
    (list v-ctx p-ctx physical-contents)))

(defun macher-agent--override-build-patch (orig-fn context &optional fsm)
  "Override the upstream patch builder to support split Virtual and Physical diffs."
  (let* ((ws (macher-agent--get-context-workspace context))
         (project-root (macher-agent-root ws))
         (default-directory (file-name-as-directory (expand-file-name project-root)))
         (prepared (macher-agent--prepare-patch-contexts context fsm project-root))
         (v-ctx (nth 0 prepared))
         (p-ctx (nth 1 prepared))
         (physical-contents (nth 2 prepared)))

    (when v-ctx
      (funcall orig-fn v-ctx fsm)
      (when-let ((patch-buf (car (macher--get-buffer "patch" ws nil))))
        (with-current-buffer patch-buf
          (rename-buffer (format "*macher-virtual-patch:%s*" (macher-agent--get-workspace-name ws)) t))))

    (when p-ctx
      (let ((shadow-descriptors nil))
        (dolist (entry physical-contents)
          (let* ((raw-path (macher-agent-vfs-entry-path entry))
                 (file-path (expand-file-name raw-path project-root))
                 (raw-val (macher-agent-vfs-entry-curr entry))
                 (new-content (if (consp raw-val) (cdr raw-val) raw-val))
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
        
        (setq shadow-descriptors
              (mapcar (lambda (desc)
                        (let* ((orig-buf (plist-get desc :original-buffer))
                               (orig-name (plist-get desc :original-buffer-name))
                               (file-path (plist-get desc :file-path))
                               (new-content (plist-get desc :new-content))
                               (temp-name (generate-new-buffer-name (format " *macher-hidden-%s*" orig-name))))
                          (with-current-buffer orig-buf
                            (rename-buffer temp-name t)
                            (setq buffer-file-name nil))
                          (let ((shadow-buf (get-buffer-create orig-name)))
                            (with-current-buffer shadow-buf
                              (setq-local default-directory (file-name-as-directory project-root))
                              (when (stringp new-content) (insert new-content))
                              (setq-local buffer-file-name nil)
                              (setq-local buffer-file-truename nil)
                              (auto-save-mode -1))
                            (plist-put desc :shadow-buffer shadow-buf))))
                      shadow-descriptors))
        
        (when (fboundp 'macher-agent--set-context-shadow-buffers)
          (macher-agent--set-context-shadow-buffers p-ctx shadow-descriptors))

        (setq macher-agent--pause-auto-sync t)
        
        (let ((cleanup-fn nil))
          (setq cleanup-fn
                (lambda ()
                  (unwind-protect
                      (dolist (desc shadow-descriptors)
                        (let ((shadow (plist-get desc :shadow-buffer))
                              (orig-buf (plist-get desc :original-buffer))
                              (orig-name (plist-get desc :original-buffer-name))
                              (orig-file (plist-get desc :original-file-name)))
                          (when (and shadow (buffer-live-p shadow))
                            (with-current-buffer shadow
                              (set-buffer-modified-p nil) 
                              (setq buffer-file-name nil))
                            (kill-buffer shadow))
                          (when (and orig-buf (buffer-live-p orig-buf))
                            (with-current-buffer orig-buf
                              (setq buffer-file-name orig-file)
                              (rename-buffer orig-name t)))))

                    (setq macher-agent--pause-auto-sync nil)
                    (remove-hook 'macher-patch-ready-hook cleanup-fn))))
          
          (add-hook 'macher-patch-ready-hook cleanup-fn))

        (funcall orig-fn p-ctx fsm)))))

(advice-add 'macher--build-patch :around #'macher-agent--override-build-patch)

(defun macher-agent--get-context-workspace (ctx)
  (cond
   ((and ctx (fboundp 'macher-context-p) (macher-context-p ctx))
    (let ((ws (and (fboundp 'macher-context-workspace) (macher-context-workspace ctx))))
      (if (and (consp ws) (eq (car ws) 'agent))
          (cdr ws)
        ws)))
   ((and (consp ctx) (eq (car ctx) 'agent))
    (cdr ctx))
   ((and ctx (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p ctx))
    ctx)
   (t nil)))

(defun macher-agent--set-context-workspace (ctx ws)
  (when (and ctx (fboundp 'macher-context-p) (macher-context-p ctx))
    (setf (macher-context-workspace ctx) ws)))

(defmacro macher-agent--def-context-accessor (name accessor &optional setter-name docstring)
  "Define a safe accessor and optional setter for a Macher context struct."
  (let ((getter `(defun ,name (ctx)
                   ,(or docstring (format "Safely access `%s` on CTX." accessor))
                   (and ctx
                        (fboundp 'macher-context-p)
                        (macher-context-p ctx)
                        (fboundp ',accessor)
                        (,accessor ctx)))))
    (if setter-name
        `(progn
           ,getter
           (defun ,setter-name (ctx val)
             ,(format "Safely set `%s` on CTX." accessor)
             (when (and ctx
                        (fboundp 'macher-context-p)
                        (macher-context-p ctx)
                        (fboundp ',accessor))
               (setf (,accessor ctx) val))))
      getter)))

(macher-agent--def-context-accessor macher-agent--get-context-contents macher-context-contents macher-agent--set-context-contents)
(macher-agent--def-context-accessor macher-agent--get-context-dirty-p macher-context-dirty-p macher-agent--set-context-dirty-p)
(macher-agent--def-context-accessor macher-agent--get-context-prompt macher-context-prompt)
(macher-agent--def-context-accessor macher-agent--get-context-shadow-buffers macher-context-shadow-buffers macher-agent--set-context-shadow-buffers "Safely assign shadow buffers to the struct if the accessor is defined upstream.")

(defun macher-agent--get-fsm-latest ()
  (bound-and-true-p macher--fsm-latest))

(provide 'macher-agent-macher-bridge)
;;; macher-agent-macher-bridge.el ends here
