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
           ;; FIX: Use [:space:] to ignore \r, \t, and trailing spaces cleanly
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
      
      ;; Ensure a trailing newline exists so org-element-context doesn't fail at EOF
      (goto-char (point-max))
      (unless (bolp)
        (insert "\n"))
      
      (org-mode)
      ;; Explicitly disable the cache locally after org-mode initialisation
      ;; and outside of a let-binding to prevent the Emacs warning.
      (setq-local org-element-use-cache nil)
      
      (org-macro-initialize-templates)
      (org-macro-replace-all org-macro-templates)
      (goto-char (point-min))
      (let ((name nil) (desc nil) (tools nil) (body nil))
        ;; Extract YAML Frontmatter
        (when (re-search-forward "^---\n" nil t)
          (let ((start (point)))
            (when (re-search-forward "^---\n" nil t)
              (let ((frontmatter (buffer-substring-no-properties start (match-beginning 0))))
                (when (string-match "^name:[ \t]*\"?\\([^\n\"]+\\)\"?" frontmatter)
                  (setq name (match-string 1 frontmatter)))
                (when (string-match "^description:[ \t]*\"?\\([^\n\"]+\\)\"?" frontmatter)
                  (setq desc (match-string 1 frontmatter)))
                (setq tools (macher-agent--parse-yaml-array frontmatter "allowed-tools"))))))
        ;; Extract Markdown Body
        (setq body (string-trim (buffer-substring-no-properties (point) (point-max))))
        (list :name name
              :name-sym (when name (intern name))
              :description desc
              :allowed-tools tools
              :body body)))))

(defun macher-agent-resolve-tool (tool-name dir-context)
  "Retrieve TOOL-NAME from registry, or load it from DIR-CONTEXT/scripts if missing.
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
                                 (end-of-file val))))))
                 (when tool
                   (puthash tool-name tool macher-agent-tools-registry)))
               (gethash tool-name macher-agent-tools-registry))))
      ;; Fallback: Return the raw string name so gptel can link built-in tools
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

(defun macher-agent-initialize-skills (&optional dir)
  "Load all skills from DIR (defaults to `macher-agent-global-skills-directory`).
This populates `gptel-directives` with the skill bodies and pre-loads scripts
so they appear in the `gptel-menu`."
  (interactive)
  (let ((skills-dir (or dir (bound-and-true-p macher-agent-global-skills-directory))))
    (when (and skills-dir (file-exists-p skills-dir))
      
      ;; 1. Pre-load all scripts so gptel knows about them
      (let ((scripts-dir (expand-file-name "scripts" skills-dir)))
        (when (file-directory-p scripts-dir)
          (dolist (script (directory-files scripts-dir t "\\.el$"))
            (let* ((base (file-name-base script))
                   (tool (macher-agent-resolve-tool base skills-dir)))
              (ignore tool)))))
      
      ;; 2. Load all SKILL.md files and bundle them appropriately
      (dolist (subdir (directory-files skills-dir t "^[^.]"))
        (when (file-directory-p subdir)
          (let ((skill-file (expand-file-name "SKILL.md" subdir)))
            (when (file-exists-p skill-file)
              (let* ((parsed (macher-agent-load-skill-from-file skill-file t))
                     (sym (plist-get parsed :name-sym))
                     (body (plist-get parsed :body))
                     (desc (plist-get parsed :description))
                     (tool-names (plist-get parsed :allowed-tools)))
                (when (and sym body)
                  (let ((resolved-tools (when tool-names
                                          (delq nil (mapcar (lambda (tname)
                                                              (macher-agent-resolve-tool tname skills-dir))
                                                            tool-names)))))         
                    
                    ;; Branch: Create a preset if tools exist, otherwise store as a raw prompt
                    (if (and resolved-tools (fboundp 'gptel-make-preset))
                        (apply #'gptel-make-preset sym
                               :system body
                               (append 
                                (when desc (list :description desc))
                                (list :tools resolved-tools)))
                      
                      ;; Fallback: Pure string prompt for tool-less skills
                      (setf (alist-get sym gptel-directives) body))))))))))))

(provide 'macher-agent-skills)
