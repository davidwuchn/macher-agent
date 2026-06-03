
``s`;;; macher-agent-api.el --- Public API for macher-agent -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-macro)
(require 'macher-agent-vfs-client)
(require 'macher-agent-macher-bridge)
(require 'macher-agent-orchestration)
(require 'macher-agent-gptel-tools)

;; --- Global Registries & Configuration ---

(defcustom macher-agent-global-skills-directory nil
  "Global directory for user-defined SKILL.md files."
  :type '(choice (const :tag "None" nil) string)
  :group 'macher-agent)

(defcustom macher-agent-extra-skill-directories nil
  "List of additional directories to scan for SKILL.md files."
  :type '(repeat string)
  :group 'macher-agent)

(defvar macher-agent-bundled-skills-directory
  (expand-file-name "skills" (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the default skills directory bundled with the macher-agent package.")

(defvar macher-agent-tools-registry (make-hash-table :test 'equal)
  "Global registry for all loaded macher-agent tools.")

(defvar macher-agent-global-skills-alist nil
  "Global registry for all loaded macher-agent skills metadata (presets/tools).")

(defvar-local macher-agent--active-skill-sym nil
  "The active skill symbol for this buffer. Acts as the anchor for FSM composition.")

;; --- Public Context API ---

(defun macher-agent-workspace-resolve-path (path)
  (macher-agent--resolve-buffer-name path))

(defun macher-agent-context-read (context file)
  (macher-agent--read-context-file context file))

(defun macher-agent-context-update (context file content)
  (macher-agent--update-context-file context file content))

(defun macher-agent-scope-add-file (buffer-name context)
  (macher-agent--add-buffer-to-scope-headless buffer-name context))

(defun macher-agent-prepare-instructions (buf instructions preset)
  (macher-agent--prepare-subagent-instructions buf instructions preset))

(defun macher-agent-submit-task-result (result)
  "Submit the final RESULT for the current agent task."
  (setq-local macher-agent--final-result result)
  (when (boundp 'macher-agent--parent-callback)
    (funcall macher-agent--parent-callback (list :status 'success :data result :buffer_name (buffer-name)))
    (makunbound 'macher-agent--parent-callback)
    (run-at-time 0.1 nil (lambda () (kill-buffer (current-buffer))))))

(defun macher-agent-ui-show (&optional buf)
  (macher-agent--show-ui buf))

(defun macher-agent-workspace-root (workspace)
  (if (and (fboundp 'macher-agent-workspace-p) (macher-agent-workspace-p workspace))
      (macher-agent-workspace-project-root workspace)
    (macher--workspace-root workspace)))

(defun macher-agent-force-review ()
  "Manually trigger the diff review screen for any pending virtual edits."
  (interactive)
  (let ((context (macher-agent-current-context))
        (fsm (bound-and-true-p macher--fsm-latest)))
    (if (not (and context (macher-agent--get-context-dirty-p context)))
        (message "No pending edits to review.")
      (macher-agent--process-request 'complete context fsm)
      (message "SUCCESS: Patch review screen(s) generated for pending edits."))))

;; --- Parsers & Loaders ---

(defun macher-agent--parse-yaml-array (text key)
  "Extract a YAML list for KEY from TEXT."
  (let ((items nil))
    (if (string-match (format "^%s:[ \t]*\\[\\(.*\\)\\]" key) text)
        (let* ((inner (match-string 1 text))
               (raw-items (split-string inner "[, \t\n\r\"]+" t)))
          (setq items raw-items))
      (let* ((lines (split-string text "\n"))
             (in-list nil))
        (dolist (line lines)
          (cond
           ((string-match (format "^%s:" key) line) (setq in-list t))
           ((and in-list (string-match "^[ \t]*-[ \t]+\"?\\([^\"]+\\)\"?" line))
            (push (match-string 1 line) items))
           ((and in-list (string-match "^[A-Za-z0-9_-]+:" line))
            (setq in-list nil))))
        (setq items (nreverse items))))
    items))

(defun macher-agent-parse-skill-file (filepath)
  "Parse a SKILL.md file at FILEPATH extracting frontmatter and body."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert-file-contents filepath)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (org-mode)
      (setq-local org-element-use-cache nil)
      (org-macro-initialize-templates)
      (org-macro-replace-all org-macro-templates)
      (goto-char (point-min))
      (let ((name nil) (desc nil) (tools nil) (body nil) (has-tools nil) (model nil))
        (when (re-search-forward "^---\n" nil t)
          (let ((start (point)))
            (when (re-search-forward "^---\n" nil t)
              (let ((frontmatter (buffer-substring-no-properties start (match-beginning 0))))
                (when (string-match "^name:[ \t]*\"?\\([^\n\"]+\\)\"?" frontmatter)
                  (setq name (match-string 1 frontmatter)))
                (when (string-match "^description:[ \t]*\"?\\([^\n\"]+\\)\"?" frontmatter)
                  (setq desc (match-string 1 frontmatter)))
                (when (string-match "^model:[ \t]*\"?\\([^\n\"]+\\)\"?" frontmatter)
                  (setq model (match-string 1 frontmatter)))
                (when (string-match "^allowed-tools:" frontmatter)
                  (setq has-tools t)
                  (setq tools (macher-agent--parse-yaml-array frontmatter "allowed-tools")))))))
        (setq body (string-trim (buffer-substring-no-properties (point) (point-max))))
        (list :name name
              :name-sym (when name (intern name))
              :description desc
              :model model
              :has-tools has-tools
              :allowed-tools tools
              :body body)))))

(defun macher-agent-resolve-tool (tool-name context dir-context)
  "Retrieve TOOL-NAME from workspace registry or load from VFS/disk, deferring native tools."
  (let* ((workspace (when context (macher-agent--get-context-workspace context)))
         (registry (if workspace (macher-agent-workspace-tools-registry workspace) macher-agent-tools-registry))
         (cached (gethash tool-name registry)))
    (or cached
        (let* ((script-paths (delq nil (list
                                        (when dir-context (expand-file-name (format "scripts/%s.el" tool-name) dir-context))
                                        (expand-file-name (format "scripts/%s.el" tool-name) macher-agent-bundled-skills-directory))))
               (content nil))
          (catch 'found
            (dolist (path script-paths)
              (let ((vfs-content (when context (ignore-errors (macher-agent--read-context-file context path)))))
                (when vfs-content
                  (setq content vfs-content)
                  (throw 'found t)))
              (when (file-exists-p path)
                (with-temp-buffer
                  (insert-file-contents path)
                  (setq content (buffer-string))
                  (throw 'found t)))))
          (if content
              (let ((tool (with-temp-buffer
                            (insert content)
                            (goto-char (point-min))
                            (when (or (re-search-forward "(defun " nil t)
                                      (re-search-forward "(defvar " nil t))
                              (error "SECURITY ERROR: JIT tool definitions must be pure forms. Core overrides forbidden."))
                            (goto-char (point-min))
                            (let ((val nil)
                                  (lexical-binding t))
                              (condition-case err
                                  (while t
                                    (let ((form (read (current-buffer))))
                                      (setq val (eval form t))))
                                (end-of-file (if (and (symbolp val) (boundp val))
                                                 (symbol-value val)
                                               val))
                                (error
                                 (message "Macher-Agent: Failed to load tool %s - %s" tool-name err)
                                 nil))))))
                (when tool
                  (puthash tool-name tool registry))
                tool)
            ;; FIX: Return the string directly to satisfy gptel's (gptel-tool string) constraint
            tool-name)))))

(defun macher-agent--load-scripts-from-dir (skills-dir context)
  "Load script tools from the scripts subdirectory of SKILLS-DIR."
  (let ((scripts-dir (expand-file-name "scripts" skills-dir)))
    (when (file-directory-p scripts-dir)
      (dolist (script (directory-files scripts-dir t "\\.el$"))
        (let* ((base (file-name-base script))
               (tool (macher-agent-resolve-tool base context skills-dir)))
          (ignore tool))))))

(defun macher-agent--load-skill-from-path (skills-dir path &optional context)
  "Load a skill from PATH within SKILLS-DIR and register it natively with gptel."
  (let ((skill-file (cond
                     ((and (file-directory-p path)
                           (file-exists-p (expand-file-name "SKILL.md" path)))
                      (expand-file-name "SKILL.md" path))
                     ((and (file-regular-p path)
                           (string-match-p "\\.md$" path))
                      path)
                     (t nil))))
    (when skill-file
      (let* ((parsed (macher-agent-parse-skill-file skill-file))
             (raw-sym (plist-get parsed :name-sym))
             (body (plist-get parsed :body))
             (desc (plist-get parsed :description))
             (model (plist-get parsed :model))
             (tool-names (plist-get parsed :allowed-tools))
             (workspace (when context (macher-agent--get-context-workspace context))))
        (when (and raw-sym body)
          (let* ((sym (if workspace
                          (intern (if (string-prefix-p "@" (symbol-name raw-sym))
                                      (symbol-name raw-sym)
                                    (concat "@" (symbol-name raw-sym))))
                        raw-sym))
                 (alist (if workspace (macher-agent-workspace-skills-alist workspace) macher-agent-global-skills-alist))
                 (resolved-tools (when tool-names
                                   (delq nil (mapcar (lambda (tname)
                                                       (macher-agent-resolve-tool tname context skills-dir))
                                                     tool-names)))))
            ;; Store metadata safely in the private alist
            (setf (alist-get sym alist)
                  (list :system body :description desc :model (when model (intern model)) :tools resolved-tools))
            (if workspace
                (setf (macher-agent-workspace-skills-alist workspace) alist)
              (setq macher-agent-global-skills-alist alist))
            
            ;; Register natively with gptel's UI
            (setf (alist-get sym gptel-directives) body)

            ;; Generate the full preset if tools are present
            (when (and tool-names (> (length tool-names) 0))
              (let ((preset-args (list :system body)))
                (when desc (setq preset-args (plist-put preset-args :description desc)))
                (when model (setq preset-args (plist-put preset-args :model (intern model))))
                (when resolved-tools (setq preset-args (plist-put preset-args :tools resolved-tools)))
                (apply #'gptel-make-preset sym preset-args)))))))))

(defun macher-agent-api-register-skills-in-directory (skills-dir &optional context)
  "Scan SKILLS-DIR for SKILL.md files and load them."
  (let* ((expanded-dir (file-name-as-directory (expand-file-name skills-dir)))
         (target-dir (if (file-directory-p (expand-file-name "skills" expanded-dir))
                         (file-name-as-directory (expand-file-name "skills" expanded-dir))
                       expanded-dir)))
    (when (and target-dir (file-directory-p target-dir))
      (macher-agent--load-scripts-from-dir target-dir context)
      (let ((files (directory-files target-dir t "^[^.]")))
        (dolist (path files)
          (condition-case err
              (macher-agent--load-skill-from-path target-dir path context)
            (error
             (message "Error loading path %s: %S" path err))))))))

(defun macher-agent--get-system-message-name (sys-msg)
  "Reverse lookup SYS-MSG to find its short name in local or global skills."
  (when (and sys-msg (stringp sys-msg) (not (string-empty-p sys-msg)))
    (let* ((ctx (ignore-errors (macher-agent-current-context)))
           (ws (when ctx (macher-agent--get-context-workspace ctx)))
           (ws-skills (when ws (macher-agent-workspace-skills-alist ws)))
           (global-skills macher-agent-global-skills-alist))
      (or
       (cl-loop for (sym . meta) in ws-skills
                if (equal (or (plist-get meta :system) "") sys-msg)
                return (symbol-name sym))
       (cl-loop for (sym . meta) in global-skills
                if (equal (or (plist-get meta :system) "") sys-msg)
                return (symbol-name sym))
       (cl-loop for (sym . msg) in (bound-and-true-p gptel-directives)
                for prompt = (if (stringp msg) msg (plist-get msg :system))
                if (equal prompt sys-msg)
                return (symbol-name sym))))))

(defun macher-agent-initialize-skills (&optional context dir)
  "Initialise agent skills from all registered directories."
  (interactive)
  (let ((directories (delq nil (append (list macher-agent-bundled-skills-directory
                                             macher-agent-global-skills-directory
                                             dir)
                                       macher-agent-extra-skill-directories))))
    
    (cl-loop for d in (delete-dups directories)
             do (when (file-directory-p d)
                  (macher-agent-api-register-skills-in-directory d context)))
    
    (when (fboundp 'gptel--setup-directive-menu)
      (gptel--setup-directive-menu 'gptel--system-message "Agent Profile"))))

(provide 'macher-agent-api)
