;;; macher-agent-gptel-bridge.el --- Clean gptel boundary -*- lexical-binding: t; -*-

(require 'gptel)
(require 'macher)
(require 'macher-agent-vfs-client)

(declare-function macher-agent-current-context "macher-agent-vfs-client")
(declare-function macher-agent--auto-sync-context "macher-agent-vfs-client")
(declare-function macher-agent--split-context "macher-agent-vfs-client")
(declare-function macher-agent--build-virtual-patch "macher-agent-vfs-client")

(defun macher-agent--track-directive-selection (orig-fun sym val scope)
  "Intercept gptel directive selection to sync our buffer-local skill anchor."
  (apply orig-fun sym val scope)
  (when (and (eq sym 'gptel--system-message)
             (eq scope 'gptel--set-buffer-locally))
    (let ((skill-sym (macher-agent--get-system-message-name val)))
      (if skill-sym
          (setq-local macher-agent--active-skill-sym (intern skill-sym))
        (setq-local macher-agent--active-skill-sym nil)))))

(advice-add 'gptel--set-with-scope :around #'macher-agent--track-directive-selection)

(defun macher-agent--compose-active-skills ()
  "JIT Composition: Rebuild buffer-local state right before the LLM request fires."
  (let* ((ctx (ignore-errors (macher-agent-current-context)))
         (ws (when ctx (macher-agent--get-context-workspace ctx)))
         (local-skills (cond
                        ((and (recordp ws) (eq (type-of ws) 'macher-agent-workspace))
                         (macher-agent-workspace-skills-alist ws))
                        ((and (consp ws) (recordp (cdr ws)) (eq (type-of (cdr ws)) 'macher-agent-workspace))
                         (macher-agent-workspace-skills-alist (cdr ws)))
                        (t nil)))
         (target-sym (or (bound-and-true-p gptel-directive) 
                         macher-agent--active-skill-sym))
         (active-skill-meta (if target-sym
                                (or (alist-get target-sym local-skills)
                                    (alist-get target-sym macher-agent-global-skills-alist))
                              nil)))

    (when active-skill-meta
      (when-let ((model (plist-get active-skill-meta :model)))
        (setq-local gptel-model (if (stringp model) (intern model) model)))
      
      (unless (bound-and-true-p gptel-mode)
        (when-let ((system-prompt (plist-get active-skill-meta :system)))
          (setq-local gptel--system-message system-prompt)))
      
      (let ((base-tools (cl-remove-if 
                         (lambda (t_) (gethash (gptel-tool-name t_) macher-agent-tools-registry))
                         (default-value 'gptel-tools)))
            (skill-tools (plist-get active-skill-meta :tools))
            (resolved-tools nil))
        
        (dolist (t_ skill-tools)
          (if (and (fboundp 'gptel-tool-p) (gptel-tool-p t_))
              (push t_ resolved-tools)
            (let* ((t-str (if (symbolp t_) (symbol-name t_) t_))
                   (normalized-target (replace-regexp-in-string "-" "_" t-str))
                   (found-tool (cl-find normalized-target (append (default-value 'gptel-tools) (bound-and-true-p gptel-tools))
                                        :key (lambda (x) (replace-regexp-in-string "-" "_" (format "%s" (gptel-tool-name x))))
                                        :test #'equal)))
              (unless found-tool
                (mapatoms
                 (lambda (sym)
                   (when (and (not found-tool) (default-boundp sym))
                     (ignore-errors
                       (let ((val (default-value sym)))
                         (cond
                          ((and val (fboundp 'gptel-tool-p) (gptel-tool-p val))
                           (let ((t-name (format "%s" (gptel-tool-name val))))
                             (when (equal (replace-regexp-in-string "-" "_" t-name) normalized-target)
                               (setq found-tool val))))
                          ((and val (proper-list-p val))
                           (dolist (item val)
                             (when (and (not found-tool) (fboundp 'gptel-tool-p) (gptel-tool-p item))
                               (let ((t-name (format "%s" (gptel-tool-name item))))
                                 (when (equal (replace-regexp-in-string "-" "_" t-name) normalized-target)
                                   (setq found-tool item)))))))))))))
              (if found-tool
                  (push found-tool resolved-tools)
                (message "Macher-Agent WARNING: Tool '%s' could not be resolved at dispatch." t-str)))))
        (setq-local gptel-tools (cl-remove-duplicates 
                                 (append base-tools resolved-tools)
                                 :key (lambda (t_) (format "%s" (gptel-tool-name t_)))
                                 :test #'equal))))))

(defun macher-agent--gptel-pre-send-advice (orig-fun &rest args)
  "Ensure the agent VFS is synchronised and skills are composed before sending."
  (let* ((macher-agent--allow-lazy-init t)
         (ctx (macher-agent-current-context)))
    (when ctx (macher-agent--auto-sync-context ctx))
    (macher-agent--compose-active-skills))
  (apply orig-fun args))

(advice-add 'gptel-send :around #'macher-agent--gptel-pre-send-advice)

(defun macher-agent--inject-media-fsm-advice (orig-fun fsm &rest args)
  "Inject pending tool media into the FSM payload right before it hits the network."
  (let* ((info (if (fboundp 'gptel-fsm-info)
                   (funcall 'gptel-fsm-info fsm)
                 (when (fboundp 'mock-gptel-fsm-info)
                   (funcall 'mock-gptel-fsm-info fsm))))
         (session (plist-get info :macher-agent-session))
         (pending (when session (macher-agent-session-pending-media session))))
    (when pending
      (let* ((msg-plist (list :role "user" :content "Tool execution complete. Here is the requested visual data:"))
             (prompts (list msg-plist))
             (gptel-context pending))
        (when (fboundp 'gptel--inject-media)
          (gptel--inject-media (plist-get info :backend) prompts))
        (when (fboundp 'gptel--inject-prompt)
          (gptel--inject-prompt (plist-get info :backend) (plist-get info :data) (car prompts)))
        (setf (macher-agent-session-pending-media session) nil)))
    (apply orig-fun fsm args)))

(advice-add 'gptel--handle-wait :around #'macher-agent--inject-media-fsm-advice)

(defun macher-agent--setup-tools-advice (orig-fn &rest args)
  "Make sure `macher--setup-tools` works gracefully without FSM injection."
  (let* ((fsm (car args))
         (info (when fsm
                 (if (fboundp 'gptel-fsm-info)
                     (funcall 'gptel-fsm-info fsm)
                   (when (fboundp 'mock-gptel-fsm-info)
                     (funcall 'mock-gptel-fsm-info fsm)))))
         (ctx (when info (plist-get info :macher--context)))
         (fallback-ctx (unless ctx (ignore-errors (macher-agent-current-context))))
         (final-ctx (or ctx fallback-ctx)))
    (when final-ctx
      (macher-agent--auto-sync-context final-ctx)
      (when fsm
        (let ((session (or (plist-get info :macher-agent-session)
                           (let* ((ws (macher-agent--get-context-workspace final-ctx))
                                  (proj-root (if ws (macher-agent--get-workspace-root ws) default-directory))
                                  (agent-ws (make-macher-agent-workspace :project-root proj-root)))
                             (make-macher-agent-session :id (buffer-name) :workspace agent-ws)))))
          (setf (gptel-fsm-info fsm) (plist-put info :macher-agent-session session))))))
  (apply orig-fn args))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)
(setq macher-process-request-function #'macher-agent--process-request)

(provide 'macher-agent-gptel-bridge)
