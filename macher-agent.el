;;; macher-agent.el --- Sandboxed, Language-Agnostic AI Workflows -*- lexical-binding: t; -*-

;; Author: Elijah Charles
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0") (macher "0.5.0"))
;; Keywords: convenience, gptel, llm, macher
;; URL: https://github.com/elij/macher-agent

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'macher)
(require 'gptel)
(require 'project)

(defvar-local macher-agent--persistent-context nil
  "Stores the macher context across continuous agent tool turns.")

(defun macher-agent--setup-tools-advice (orig-fn fsm get-context)
  "Advise macher tool setup to use a persistent context across auto-continuations."
  (let* ((info (gptel-fsm-info fsm))
         (buffer (plist-get info :buffer)))
    (if (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((original-get-context get-context))
            (funcall orig-fn fsm
                     (lambda ()
                       ;; Force macher's internal tracker to register activity
                       (funcall original-get-context)
                       ;; Cache the context on the first turn
                       (unless macher-agent--persistent-context
                         (setq macher-agent--persistent-context (funcall original-get-context)))
                       
                       (let ((ctx macher-agent--persistent-context))
                         (when ctx
                           ;; Inject persistent context into current FSM so patch generation catches it
                           (let ((fsm-info (gptel-fsm-info fsm)))
                             (setf (gptel-fsm-info fsm) 
                                   (plist-put fsm-info :macher--context ctx)))
                           (setq macher--fsm-latest fsm))
                         ctx)))))
      (funcall orig-fn fsm get-context))))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)

(defun macher-agent-clear-context ()
  "Clear the persistent sub-agent context to start a fresh task."
  (interactive)
  (setq-local macher-agent--persistent-context nil)
  (message "Agent context cleared."))

(defun macher-agent--fix-directory-workspace-name (orig-fn workspace &rest args)
  "Provide a fallback name for raw directory workspaces to prevent macher crashes."
  (if (eq (car-safe workspace) 'directory)
      (file-name-nondirectory (directory-file-name (cdr workspace)))
    (apply orig-fn workspace args)))

(with-eval-after-load 'macher
  (advice-add 'macher--workspace-name :around #'macher-agent--fix-directory-workspace-name))

(cl-defmethod project-root ((project (head macher-agent)))
  "Return the root directory for an isolated sub-agent workspace."
  (cdr project))

(defvar-local macher-agent--gptel-finished nil
  "Flag to indicate standard gptel finished its current stream.")

(defun macher-agent--gptel-finished-hook (&rest _)
  "Hook to mark gptel request as finished."
  (setq macher-agent--gptel-finished t))

(defun macher-agent--wait-for-completion (buf callback actual-name fsm)
  "Wait for the FSM to complete using event-driven handlers, catching auto-continuations."
  (macher--add-termination-handler
   fsm
   (lambda (_)
     (run-at-time 0.5 nil
                  (lambda ()
                    (if (not (buffer-live-p buf))
                        (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
                      (let ((current-fsm (buffer-local-value 'macher--fsm-latest buf)))
                        (if (and current-fsm (not (eq current-fsm fsm)))
                            (macher-agent--wait-for-completion buf callback actual-name current-fsm)
                          (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))))))

(defun macher-agent--catch-fsm-and-wait (buf callback actual-name)
  "Poll until macher initializes the FSM OR standard gptel finishes generating."
  (if (not (buffer-live-p buf))
      (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
    (let ((fsm (buffer-local-value 'macher--fsm-latest buf))
          (finished (buffer-local-value 'macher-agent--gptel-finished buf)))
      (cond
       ;; Case 1: The LLM used a tool! Hand off to the robust FSM event listener.
       (fsm
        (macher-agent--wait-for-completion buf callback actual-name fsm))
       
       ;; Case 2: The LLM replied with plain text and gptel says it finished writing.
       (finished
        (run-at-time 0.5 nil
                     (lambda ()
                       (if (not (buffer-live-p buf))
                           (funcall callback (format "ERROR: Buffer '%s' killed." actual-name))
                         (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
                           (if new-fsm
                               (macher-agent--wait-for-completion buf callback actual-name new-fsm)
                             (funcall callback (format "SUCCESS: Sub-agent '%s' finished responding (No tools used)." actual-name))))))))
       
       ;; Case 3: Still actively generating text. Check again in 0.1s.
       (t
        (run-at-time 0.1 nil (lambda () (macher-agent--catch-fsm-and-wait buf callback actual-name))))))))(defvar-local macher-agent--gptel-finished nil
  "Flag to indicate standard gptel finished its current stream.")

(defun macher-agent--gptel-finished-hook (&rest _)
  "Hook to mark gptel request as finished."
  (setq macher-agent--gptel-finished t))

(defun macher-agent--wait-for-completion (buf callback actual-name fsm)
  "Wait for the FSM to complete using event-driven handlers, catching auto-continuations."
  (macher--add-termination-handler
   fsm
   (lambda (_)
     (run-at-time 0.5 nil
                  (lambda ()
                    (if (not (buffer-live-p buf))
                        (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
                      (let ((current-fsm (buffer-local-value 'macher--fsm-latest buf)))
                        (if (and current-fsm (not (eq current-fsm fsm)))
                            (macher-agent--wait-for-completion buf callback actual-name current-fsm)
                          (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))))))

(defun macher-agent--catch-fsm-and-wait (buf callback actual-name)
  "Poll until macher initializes the FSM OR standard gptel finishes generating."
  (if (not (buffer-live-p buf))
      (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
    (let ((fsm (buffer-local-value 'macher--fsm-latest buf))
          (finished (buffer-local-value 'macher-agent--gptel-finished buf)))
      (cond
       (fsm
        (macher-agent--wait-for-completion buf callback actual-name fsm))
       
       (finished
        (run-at-time 0.5 nil
                     (lambda ()
                       (if (not (buffer-live-p buf))
                           (funcall callback (format "ERROR: Buffer '%s' killed." actual-name))
                         (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
                           (if new-fsm
                               (macher-agent--wait-for-completion buf callback actual-name new-fsm)
                             (funcall callback (format "SUCCESS: Sub-agent '%s' finished responding (No tools used)." actual-name))))))))
       
       (t
        (run-at-time 0.1 nil (lambda () (macher-agent--catch-fsm-and-wait buf callback actual-name))))))))

(defun macher-agent--catch-fsm-and-wait (buf callback actual-name attempts)
  "Poll briefly until macher initializes the FSM, then hand off to the event listener."
  (if (not (buffer-live-p buf))
      (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
    (let ((fsm (buffer-local-value 'macher--fsm-latest buf)))
      (if fsm
          ;; We caught the new FSM! Attach the event handler immediately.
          (macher-agent--wait-for-completion buf callback actual-name fsm)
        (if (> attempts 20) ;; Give up after 2 seconds
            (funcall callback "ERROR: Sub-agent FSM failed to initialize.")
          ;; Check again in 0.1s
          (run-at-time 0.1 nil (lambda () (macher-agent--catch-fsm-and-wait buf callback actual-name (1+ attempts)))))))))

;; context wrappers

(defun macher-agent--get-context-edits (context)
  "Extract in-memory changes from the given macher CONTEXT."
  (let ((edits nil))
    (when (and context (macher-context-p context))
      (let* ((contents-alist (macher-context-contents context))
             (workspace (macher-context-workspace context))
             (root (macher--workspace-root workspace)))
        (dolist (entry contents-alist)
          (let* ((abs-path (car entry))
                 (content-pair (cdr entry))
                 (new-content (cdr content-pair))
                 (rel-path (file-relative-name abs-path root)))
            ;; Extract only files that differ from the disk state
            (when (and new-content (not (equal (car content-pair) new-content)))
              (push (cons rel-path new-content) edits))))))
    edits))

;; async

(defun macher-agent--pure-async-execute (context cmd success-override callback)
  "Execute CMD inside a temporary sandbox cleanly and asynchronously.
Does NOT block the Emacs event loop."
  (let* ((root (locate-dominating-file default-directory ".git"))
         (project-root (if root
                           (file-name-as-directory (expand-file-name root))
                         (file-name-as-directory default-directory)))
         (temp-dir (file-name-as-directory (expand-file-name (make-temp-file "sandbox-" t))))
         (rsync-cmd (format "rsync -a --exclude='target/' --exclude='.git/' %s %s"
                            (shell-quote-argument project-root)
                            (shell-quote-argument temp-dir)))
         (process-connection-type nil)
         (rsync-proc (start-process-shell-command "rsync-sandbox" nil rsync-cmd)))
    
    (set-process-sentinel
     rsync-proc
     (lambda (_proc event)
       (when (memq (process-status _proc) '(exit signal))
         (dolist (edit context)
           (let* ((path (car edit))
                  (content (cdr edit))
                  (full-path (expand-file-name path temp-dir)))
             (make-directory (file-name-directory full-path) t)
             (with-temp-file full-path
               (insert content))))
         
         (let* ((output-buffer (generate-new-buffer " *macher-async-out*"))
                (target-cmd (format "cd %s && %s" (shell-quote-argument temp-dir) cmd))
                (cmd-proc (start-process-shell-command "macher-cmd" output-buffer target-cmd)))
           (set-process-sentinel
            cmd-proc
            (lambda (cmd-p cmd-event)
              (when (memq (process-status cmd-p) '(exit signal))
                (let ((output (with-current-buffer output-buffer (buffer-string))))
                  (kill-buffer output-buffer)
                  (if (and success-override 
                           (= (process-exit-status cmd-p) 0) 
                           (string-empty-p output))
                      (funcall callback success-override)
                    (funcall callback output))))))))))))

;;;###autoload
(defun macher-agent-add-subagent (name dir &optional no-inject)
  "Interactively instantiate an isolated sub-agent buffer for task delegation.
If NO-INJECT is t, skip injecting the system directive into the parent buffer."
  (interactive "sSub-agent name: \nDTarget directory: ")
  (let* ((buf-name (format "*macher-agent: %s*" name))
         (full-dir (file-name-as-directory (expand-file-name dir)))
         (buf (get-buffer-create buf-name))
         (parent-buf (current-buffer)))
    
    (with-current-buffer buf
      (markdown-mode)
      (gptel-mode 1)
      (setq default-directory full-dir)
      (setq-local macher--workspace (cons 'directory full-dir))
      (insert (format "# Sub-Agent: %s\nWorkspace locked to: %s\n\n" name full-dir)))

    (push (cons name full-dir) macher-agent-active-subagents)
    
    ;; Inject directive invisibly so the LLM reads it but the UI stays clean
    (unless no-inject
      (with-current-buffer parent-buf
        (when (derived-mode-p 'gptel-mode 'markdown-mode 'org-mode 'text-mode)
          (save-excursion
            (goto-char (point-max))
            (let ((start (point)))
              (insert (format "\n\n[SYSTEM DIRECTIVE: A sub-agent named '%s' has been instantiated and locked to '%s'. You can dispatch tasks to it using the 'write_to_buffer' tool followed by 'execute_subagent_buffer_blocking'. The exact buffer_name to use is '%s'.]\n\n" name full-dir buf-name))
              (put-text-property start (point) 'invisible t)
              (put-text-property start (point) 'intangible t)
              (put-text-property start (point) 'rear-nonsticky t))))))
    
    (message "Instantiated sub-agent: %s (Macher workspace bound)" buf-name)))

(defvar macher-agent-active-subagents nil
  "An alist tracking active sub-agents globally for the current Emacs session.
Format: ((NAME . DIRECTORY) ...)")

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
             ;; fast-forward baseline
             ((and new (string= disk new) (not (string= orig new)))
              (setcar content-pair disk)
              (setq synced t))
             ;; intermediate edit
             ((and (not (string= disk orig)) (not (string= disk new)))
              (setcar content-pair disk)
              (setcdr content-pair disk)
              (setq synced t))))))
      ;; Reset
      (when synced
        (setf (macher-context-dirty-p ctx) nil)))))

(defun macher-agent--setup-tools-advice (orig-fn fsm get-context)
  "Advise macher tool setup to use a persistent context and auto-sync with disk."
  (let* ((info (gptel-fsm-info fsm))
         (buffer (plist-get info :buffer)))
    (if (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((original-get-context get-context))
            (funcall orig-fn fsm
                     (lambda ()
                       (funcall original-get-context)
                       (unless macher-agent--persistent-context
                         (setq macher-agent--persistent-context (funcall original-get-context)))
                       
                       (let ((ctx macher-agent--persistent-context))
                         (when ctx
                           ;; Automatically validate memory against the file system
                           (macher-agent--auto-sync-context ctx)
                           
                           (let ((fsm-info (gptel-fsm-info fsm)))
                             (setf (gptel-fsm-info fsm) 
                                   (plist-put fsm-info :macher--context ctx)))
                           (setq macher--fsm-latest fsm))
                         ctx)))))
      (funcall orig-fn fsm get-context))))

(advice-add 'macher--setup-tools :around #'macher-agent--setup-tools-advice)

;; macher-agent-tools

(defun macher-agent--resolve-buffer-name (name)
  "Ensure the buffer name has the correct macher-agent prefix."
  (let ((name-str (substring-no-properties name)))
    (if (string-prefix-p "*macher-agent:" name-str)
        name-str
      (format "*macher-agent: %s*" name-str))))

(defvar macher-agent-spawn-subagent-tool
  (gptel-make-tool
   :name "spawn_subagent"
   :description "Create a new, isolated sub-agent in the current project directory. You provide the name. Use this to spin up a worker for a specific task."
   :args (list '(:name "name" :type string :description "The name of the new sub-agent."))
   :function (lambda (name)
               (let ((buf-name (format "*macher-agent: %s*" name)))
                 ;; Pass 't' to no-inject so it doesn't clutter the LLM's chat log
                 (macher-agent-add-subagent name default-directory t)
                 (format "SUCCESS: Sub-agent created. The EXACT buffer name to use for tools is '%s'." buf-name)))))

(add-to-list 'gptel-tools macher-agent-spawn-subagent-tool)

(defvar macher-agent-execute-blocking-tool
  (gptel-make-tool
   :name "execute_subagent_buffer_blocking"
   :description "Trigger a sub-agent and WAIT for it to finish its task before continuing. Call this after dispatching instructions via write_to_buffer."
   :async t
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer."))
   :function (lambda (callback buffer_name)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (buf (get-buffer actual-name)))
                 (if (not (buffer-live-p buf))
                     (funcall callback (format "ERROR: Buffer '%s' does not exist." actual-name))
                   (with-current-buffer buf
                     ;; Wipe old trackers
                     (setq-local macher--fsm-latest nil)
                     (setq-local macher-agent--gptel-finished nil)
                     ;; Guarantee the fallback hook is attached to this buffer
                     (add-hook 'gptel-post-response-functions #'macher-agent--gptel-finished-hook nil t)
                     
                     (goto-char (point-max))
                     (gptel-send)
                     
                     ;; Start the hybrid polling hand-off
                     (macher-agent--catch-fsm-and-wait buf callback actual-name)))))))

(add-to-list 'gptel-tools macher-agent-execute-blocking-tool)

;; vanilla gptel-tools but related to above
;;;###autoload
(defvar macher-agent-write-to-buffer-tool
  (gptel-make-tool
   :name "write_to_buffer"
   :description "Write complete content to a specific Emacs buffer.."
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer.")
               '(:name "content" :type string :description "The text content to write."))
   :function (lambda (buffer_name content)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (target-buffer (get-buffer-create actual-name)))
                 (with-current-buffer target-buffer
                   (goto-char (point-max))
                   (insert "\n\n" (substring-no-properties content) "\n"))
                 (format "SUCCESS: Content successfully dispatched to buffer '%s'." actual-name)))))

(add-to-list 'gptel-tools macher-agent-write-to-buffer-tool)

(defvar macher-agent-execute-subagent-tool
  (gptel-make-tool
   :name "execute_subagent_buffer"
   :description "Trigger a sub-agent to begin processing the instructions in its buffer."
   :args (list '(:name "buffer_name" :type string :description "The exact name of the destination buffer."))
   :function (lambda (buffer_name)
               (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name))
                      (buf (get-buffer actual-name)))
                 (if (buffer-live-p buf)
                     (with-current-buffer buf
                       (goto-char (point-max))
                       (gptel-send)
                       (format "SUCCESS: Sub-agent in '%s' has been triggered and is executing asynchronously." actual-name))
                   (format "ERROR: Buffer '%s' does not exist." actual-name))))))

(add-to-list 'gptel-tools macher-agent-execute-subagent-tool)


(defun macher-agent--collision-warning (context fsm callback)
  "Inspect the proposed edits for path collisions and inject a warning if necessary."
  (let ((collision-detected nil)
        (root-files (directory-files (or (locate-dominating-file default-directory ".git") default-directory) nil "^[^.]")))
    
    (when context
      (dolist (entry (macher-context-contents context))
        (let* ((path (car entry))
               (filename (file-name-nondirectory path)))
          (when (and (string-match-p "/" path) (member filename root-files))
            (setq collision-detected t)))))
    
    (when collision-detected
      (goto-char (point-min))
      (insert "WARNING: Potential filename collision detected between sub-directories and the project root.\nIt is highly recommended to apply this patch using an external shell utility (ie, `git apply`) rather than the native Emacs interface to ensure filesystem integrity.\n\n"))
    
    ;; CRITICAL: You must execute the callback to continue the patch generation chain
    (funcall callback)))

(add-hook 'macher-patch-prepare-functions #'macher-agent--collision-warning)

(defun macher-agent-restore-session-hook ()
  "Silently recreate background buffers and restore the active agents tracker."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+PROPERTY:[ \t]+macher-sub-agents[ \t]+\\(.+\\)$" nil t)
      (let ((agents (read (match-string 1))))
        (setq macher-agent-active-subagents nil)
        
        (dolist (agent agents)
          (let* ((name (car agent))
                 (dir (cadr agent))
                 (buf-name (format "*macher-agent: %s*" name))
                 (buf (get-buffer-create buf-name)))
            
            (push (cons name dir) macher-agent-active-subagents)
            
            (with-current-buffer buf
              (unless (derived-mode-p 'markdown-mode)
                (markdown-mode)
                (gptel-mode 1)
                (setq-local macher--workspace (cons 'directory (expand-file-name dir)))
                (insert (format "# Sub-Agent: %s\nWorkspace locked to: %s\n\n" name dir))))))))))

;;;###autoload
(cl-defun macher-agent-make-tool (&key name description command-fn success-fn output-filter args)
  "Construct a public tool for gptel that automatically executes in a temporary sandbox."
  (macher--make-tool nil
                     :name name
                     :description description
                     :async t
                     :args args
                     :category macher-tool-category
                     :function (lambda (context callback &rest tool-args)
                                 (let* ((call-args
                                         (if (and tool-args (keywordp (car tool-args)))
                                             tool-args
                                           (let ((result nil))
                                             (cl-loop for arg-def in args
                                                      for i from 0
                                                      for arg-name = (intern (concat ":" (plist-get arg-def :name)))
                                                      do (setq result (plist-put result arg-name (nth i tool-args))))
                                             result)))
                                        (cmd-string (funcall command-fn call-args))
                                        (success-override (when success-fn (funcall success-fn call-args)))
                                        ;; Pull the virtual edits using the injected context
                                        (pending-edits (macher-agent--get-context-edits context)))
                                   
                                   (macher-agent--pure-async-execute
                                    pending-edits
                                    cmd-string
                                    success-override
                                    (lambda (result)
                                      (funcall callback (if output-filter (funcall output-filter result) result))))))))

(add-hook 'gptel-mode-hook #'macher-agent-restore-session-hook)

(provide 'macher-agent)
