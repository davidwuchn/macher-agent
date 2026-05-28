;;; macher-agent-skills.el --- Agent Skills parsing and resolution -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'org)
(require 'org-macro)

(defvar macher-agent-tools-registry (make-hash-table :test 'equal)
  "Global registry mapping tool names (strings) to gptel tool objects.")

(defvar macher-agent-skills-alist nil
  "Alist mapping skill name symbols to skill metadata.")

(defun macher-agent--parse-yaml-array (text key)
  "Extract a YAML list for KEY from TEXT. 
Handles both inline JSON arrays [...] and YAML block lists (- item)."
  (let ((items nil))
    (if (string-match (format "^%s:[ \t]*\\[\\(.*\\)\\]" key) text)
        ;; Parse inline array format: ["tool_1", "tool_2"]
        (let ((raw-items (split-string (match-string 1 text) "[, \t\n\r\"]+" t)))
          (setq items raw-items))
      ;; Parse block list format:
      (let* ((lines (split-string text "\n"))
             (in-list nil))
        (dolist (line lines)
          (cond
           ((string-match (format "^%s:" key) line)
            (setq in-list t))
           ((and in-list (string-match "^[[:space:]]*-[[:space:]]+\"?\\([^\"[:space:]]+\\)\"?" line))
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
                               (condition-case nil
                                   (while t
                                     (setq val (eval (read (current-buffer)) lexical-binding)))
                                 (end-of-file (if (and (symbolp val) (boundp val))
                                                  (symbol-value val)
                                                val)))))))
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

(defvar macher-agent-workspace-skills-directory ".macher/skills"
  "Relative path to workspace-specific skills directory from project root.")

(defvar macher-agent--package-dir
  (when-let ((file (or load-file-name buffer-file-name)))
    (file-name-directory file))
  "Directory where the macher-agent package is installed.")

(defun macher-agent--load-scripts-from-dir (skills-dir)
  "Load script tools from the scripts subdirectory of SKILLS-DIR."
  (let ((scripts-dir (expand-file-name "scripts" skills-dir)))
    (when (file-directory-p scripts-dir)
      (dolist (script (directory-files scripts-dir t "\\.el$"))
        (let* ((base (file-name-base script))
               (tool (macher-agent-resolve-tool base skills-dir)))
          (ignore tool))))))

(defun macher-agent--load-skill-from-subdir (skills-dir subdir)
  "Load a skill from SUBDIR of SKILLS-DIR if SKILL.md exists."
  (when (file-directory-p subdir)
    (let ((skill-file (expand-file-name "SKILL.md" subdir)))
      (when (file-exists-p skill-file)
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
              ;; If gptel natively supports presets one day
              (when (and has-tools (fboundp 'gptel-make-preset))
                (apply #'gptel-make-preset sym
                       :system body
                       (append 
                        (when desc (list :description desc))
                        (when model (list :model (intern model)))
                        (list :tools resolved-tools)))))))))))

(defun macher-agent-initialize-skills (&optional override-dir)
  "Load all skills from package, global, and workspace directories.
If OVERRIDE-DIR is provided, load skills only from that directory."
  (interactive)
  (let* ((package-dir (when macher-agent--package-dir (expand-file-name "skills" macher-agent--package-dir)))
         (global-dir (when (bound-and-true-p macher-agent-global-skills-directory)
                       (expand-file-name macher-agent-global-skills-directory)))
         (root (or (locate-dominating-file default-directory ".git") default-directory))
         (workspace-dir (when (and root macher-agent-workspace-skills-directory)
                          (expand-file-name macher-agent-workspace-skills-directory root)))
         (dirs (if override-dir 
                   (if (listp override-dir) override-dir (list override-dir))
                 (delq nil (list package-dir global-dir workspace-dir)))))
    ;; Clean up any legacy plist formats in gptel-directives
    (when (boundp 'gptel-directives)
      (setq gptel-directives 
            (cl-remove-if (lambda (entry) 
                            (and (consp entry) (listp (cdr entry))))
                          gptel-directives)))
    (dolist (skills-dir dirs)
      (when (and skills-dir (file-directory-p skills-dir))
        (macher-agent--load-scripts-from-dir skills-dir)
        (dolist (subdir (directory-files skills-dir t "^[^.]"))
          (macher-agent--load-skill-from-subdir skills-dir subdir)))))
  (when-let* ((default-val (alist-get 'default gptel-directives))
              (default-prompt (if (listp default-val)
                                  (plist-get default-val :system)
                                default-val)))
    (setq-default gptel--system-message default-prompt)))

(provide 'macher-agent-skills)
