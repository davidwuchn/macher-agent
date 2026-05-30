;;; macher-agent-api.el --- Public API for macher-agent -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-macro)
(defvar macher-agent-tools-registry (make-hash-table :test 'equal)
  "Global registry mapping tool names (strings) to gptel tool objects.")

(require 'macher-agent-context)
(require 'macher-agent-orchestration)
(require 'macher-agent-gptel-tools)

(defun macher-agent-workspace-resolve-path (path)
  "Resolve PATH within the current workspace."
  (macher-agent--resolve-buffer-name path))

(defun macher-agent-context-read (context file)
  "Read the context from FILE within CONTEXT."
  (macher-agent--read-context-file context file))

(defun macher-agent-context-update (context file content)
  "Update the context FILE with CONTENT within CONTEXT."
  (macher-agent--update-context-file context file content))

(defun macher-agent-scope-add-file (buffer-name context)
  "Add BUFFER-NAME to the current agent CONTEXT scope headlessly."
  (macher-agent--add-buffer-to-scope-headless buffer-name context))

(defun macher-agent-execute-parallel (tasks callback)
  "Execute TASKS in parallel subagents."
  (macher-agent--execute-parallel tasks callback))

(defun macher-agent-prepare-instructions (buf instructions preset)
  "Prepare instructions for a given BUF with INSTRUCTIONS and PRESET."
  (macher-agent--prepare-subagent-instructions buf instructions preset))

(defun macher-agent-submit-task-result (result)
  "Submit the final RESULT for the current agent task."
  (setq-local macher-agent--final-result result))

(defun macher-agent-ui-show (&optional buf)
  "Display the agent user interface."
  (macher-agent--show-ui buf))

(defun macher-agent-workspace-root (workspace)
  "Get the root directory of the WORKSPACE."
  (macher--workspace-root workspace))

(defvar macher-agent-skills-alist nil
  "Alist mapping skill name symbols to skill metadata.")

(defvar macher-agent-bundled-skills-directory
  (expand-file-name "skills" (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the default skills directory bundled with the macher-agent package.")

(defcustom macher-agent-workspace-skills-directory ".macher-agent/skills/"
  "The directory relative to the workspace root containing project-specific SKILL.md files."
  :type 'string
  :group 'macher-agent-skills)

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
           ((string-match (format "^%s:" key) line)
            (setq in-list t))
           ((and in-list (string-match "^[ \t]*-[ \t]+\"?\\([^\"]+\\)\"?" line))
            (push (match-string 1 line) items))
           ((and in-list (string-match "^[A-Za-z0-9_-]+:" line))
            (setq in-list nil))))
        (setq items (nreverse items))))
    items))

(defun macher-agent-parse-skill-file (filepath)
  "Parse a SKILL.md file at FILEPATH extracting frontmatter and body.
Returns a property list compatible with the tests."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert-file-contents filepath)
      (goto-char (point-max))
      (unless (bolp)
        (insert "\n"))
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

(defun macher-agent-resolve-tool (tool-name dir-context)
  "Retrieve TOOL-NAME from registry, or load from DIR-CONTEXT/scripts.
If no local script is found, fallback to returning the TOOL-NAME string,
assuming it is a globally registered native gptel/macher tool."
  (or (gethash tool-name macher-agent-tools-registry)
      (and dir-context
           (let ((script-path (expand-file-name (format "scripts/%s.el" tool-name) dir-context)))
             (when (file-exists-p script-path)
               (let ((tool (with-temp-buffer
                             (insert-file-contents script-path)
                             (let ((val nil))
                               (condition-case err
                                   (while t
                                     (let ((form (read (current-buffer))))
                                       (setq val (eval form lexical-binding))))
                                 (end-of-file (if (and (symbolp val) (boundp val))
                                                  (symbol-value val)
                                                val))
                                 (error
                                  (signal (car err) (cdr err))))))))
                 (when tool
                   (puthash tool-name tool macher-agent-tools-registry))
                 (gethash tool-name macher-agent-tools-registry)))))
      tool-name))

(defun macher-agent-load-skill-from-file (filepath &optional is-global)
  "Load skill from FILEPATH. 
If IS-GLOBAL is non-nil, sets :context-dir to allow script resolution."
  (let* ((parsed (macher-agent-parse-skill-file filepath))
         (name-sym (plist-get parsed :name-sym))
         (dir-context (if is-global (file-name-directory filepath) nil)))
    (when name-sym
      (setf (alist-get name-sym macher-agent-skills-alist)
            (list :description (plist-get parsed :description)
                  :tools (plist-get parsed :allowed-tools)
                  :model (plist-get parsed :model)
                  :has-tools (plist-get parsed :has-tools)
                  :context-dir dir-context
                  :body (plist-get parsed :body))))
    parsed))

(defun macher-agent--apply-skill-tools (preset-sym)
  "Apply the tools of PRESET-SYM into `gptel-tools`."
  (let* ((skill-meta (alist-get preset-sym macher-agent-skills-alist))
         (tool-names (plist-get skill-meta :tools))
         (dir-context (plist-get skill-meta :context-dir)))
    (when skill-meta
      (dolist (tname tool-names)
        (let ((tool (macher-agent-resolve-tool tname dir-context)))
          (when tool
            (add-to-list 'gptel-tools tool)))))))

(defun macher-agent--load-scripts-from-dir (skills-dir)
  "Load script tools from the scripts subdirectory of SKILLS-DIR."
  (let ((scripts-dir (expand-file-name "scripts" skills-dir)))
    (when (file-directory-p scripts-dir)
      (dolist (script (directory-files scripts-dir t "\\.el$"))
        (let* ((base (file-name-base script))
               (tool (macher-agent-resolve-tool base skills-dir)))
          (ignore tool))))))

(defun macher-agent--load-skill-from-path (skills-dir path)
  "Load a skill from PATH within SKILLS-DIR.
PATH can be a directory containing SKILL.md, or a direct .md file."
  (let ((skill-file (cond
                     ((and (file-directory-p path)
                           (file-exists-p (expand-file-name "SKILL.md" path)))
                      (expand-file-name "SKILL.md" path))
                     ((and (file-regular-p path)
                           (string-match-p "\\.md$" path))
                      path)
                     (t 
                      nil))))
    (when skill-file
      (let* ((parsed (macher-agent-load-skill-from-file skill-file t))
             (sym (plist-get parsed :name-sym))
             (body (plist-get parsed :body))
             (desc (plist-get parsed :description))
             (model (plist-get parsed :model))
             (has-tools (plist-get parsed :has-tools))
             (tool-names (plist-get parsed :allowed-tools)))
        (when (and sym body)
          (let ((resolved-tools (when tool-names
                                  (delq nil (mapcar (lambda (tname)
                                                      (macher-agent-resolve-tool tname skills-dir))
                                                    tool-names)))))
            ;; Always set in skills registry
            (setf (alist-get sym macher-agent-skills-alist)
                  (list :system body :description desc :model (when model (intern model)) :tools resolved-tools))
            ;; Always make available as a directive string in gptel
            (setf (alist-get sym gptel-directives) body)
            (when (fboundp 'gptel-make-preset)
              (apply #'gptel-make-preset sym
                     :system body
                     (append 
                      (when desc (list :description desc))
                      (when model (list :model (intern model)))
                      (when has-tools (list :tools resolved-tools)))))))))))

(defun macher-agent-api-register-skills-in-directory (skills-dir)
  "Scan SKILLS-DIR for SKILL.md files and load them into the core UI and registry.
Also loads any Elisp script tools found in the 'scripts' subdirectory."
  (let* ((expanded-dir (file-name-as-directory (expand-file-name skills-dir)))
         ;; Auto-detect if they passed a package root that contains a "skills/" subdirectory
         (skills-dir (if (file-directory-p (expand-file-name "skills" expanded-dir))
                         (file-name-as-directory (expand-file-name "skills" expanded-dir))
                       expanded-dir)))
    (when (and skills-dir (file-directory-p skills-dir))
      (macher-agent--load-scripts-from-dir skills-dir)
      (let ((files (directory-files skills-dir t "^[^.]")))
        (dolist (path files)
          (condition-case err
              (macher-agent--load-skill-from-path skills-dir path)
            (error
             (message "Error loading path %s: %S" path err)))))))
  (when-let* ((default-val (alist-get 'default gptel-directives))
              (default-prompt (if (listp default-val)
                                  (plist-get default-val :system)
                                default-val)))
    (setq-default gptel--system-message default-prompt)))

(defcustom macher-agent-global-skills-directory nil
  "Global directory for user-defined SKILL.md files."
  :type '(choice (const :tag "None" nil) string)
  :group 'macher-agent)

(defun macher-agent-initialize-skills (&optional dir)
  "Initialize agent skills from DIR or `macher-agent-global-skills-directory`."
  (let ((target-dir (or dir macher-agent-global-skills-directory)))
    (when (and target-dir (file-directory-p target-dir))
      (macher-agent-api-register-skills-in-directory target-dir))))

;; Initialise bundled skills on startup
(when (file-directory-p macher-agent-bundled-skills-directory)
  (macher-agent-initialize-skills macher-agent-bundled-skills-directory))

(provide 'macher-agent-api)
