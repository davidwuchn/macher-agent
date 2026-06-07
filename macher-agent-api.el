;;; macher-agent-api.el --- Public API for macher-agent -*- lexical-binding: t; -*-

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

(defvar-local macher-agent-parent-buffer nil
  "Stores the name of the buffer this chat branched from.")

(defvar-local macher-agent--active-skill-sym nil
  "Symbol representing the currently active skill preset in this buffer.")

(defmacro macher-agent-with-project-root (&rest body)
  "Execute BODY with `default-directory` strictly bound to the absolute project root."
  `(let ((default-directory (file-name-as-directory (macher-agent--get-project-root))))
     ,@body))

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
    ;;(push (current-buffer) macher-agent--garbage-queue)
    ))

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
      ;; Route directly to the upstream builder (which we intercept to split the UI)
      (macher--build-patch context fsm)
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
    (let* ((org-inhibit-startup t)
           (abs-file (expand-file-name filepath))) 
      (setq default-directory (file-name-directory abs-file))
      (insert-file-contents abs-file)
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

(defun macher-agent--evaluate-and-cache-tool (content tool-name registry)
  "Evaluate string CONTENT and cache it in REGISTRY under TOOL-NAME."
  (let ((tool (with-temp-buffer
                (insert content)
                (goto-char (point-min))
                (let ((val nil)
                      (form nil)
                      (security-fail nil))
                  (condition-case err
                      (while (not security-fail)
                        (setq form (read (current-buffer)))
                        (if (and (consp form)
                                 (memq (car form) '(defun cl-defun defvar defcustom defmacro)))
                            (progn
                              (setq security-fail t)
                              (error "SECURITY WARNING: Tool attempts to evaluate top-level definition: %s" (car form)))
                          (setq val (eval form t))))
                    (end-of-file nil)
                    (error
                     (message "Macher-Agent: Failed to load tool %s - %s" tool-name err)
                     (setq val nil)))
                  (unless security-fail
                    (if (and (symbolp val) (boundp val))
                        (symbol-value val)
                      val))))))
    (when tool
      (puthash tool-name tool registry))
    tool))

(defun macher-agent--read-and-cache-from-disk (tool-name script-paths registry)
  "Load and cache a tool from physical disk using SCRIPT-PATHS."
  (let ((disk-content nil))
    (catch 'found-disk
      (dolist (path script-paths)
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (setq disk-content (buffer-string))
            (throw 'found-disk t)))))
    (if disk-content
        (macher-agent--evaluate-and-cache-tool disk-content tool-name registry)
      tool-name)))

(defun macher-agent--invalidate-tool-cache-on-mutation (&optional path &rest _)
  "Invalidate the tool cache if the mutated PATH is a tool script."
  (when (and path (stringp path) (string-match "scripts/\\([^/]+\\)\\.el$" path))
    (let* ((tool-name (match-string 1 path))
           (workspace (when (bound-and-true-p macher-agent--persistent-context)
                        (macher-agent--get-context-workspace macher-agent--persistent-context)))
           (registry (if workspace
                         (macher-agent-workspace-tools-registry workspace)
                       macher-agent-tools-registry)))
      (remhash tool-name registry)
      (remhash (intern tool-name) registry))))

(add-hook 'macher-agent-context-mutated-hook #'macher-agent--invalidate-tool-cache-on-mutation)

(defun macher-agent-resolve-tool (tool-name context dir-context)
  "Retrieve TOOL-NAME from workspace registry or load from VFS/disk, deferring native tools."
  (let* ((workspace (when context (macher-agent--get-context-workspace context)))
         (registry (if workspace (macher-agent-workspace-tools-registry workspace) macher-agent-tools-registry))
         (cached (gethash tool-name registry))
         (script-paths (delq nil (list
                                  (when dir-context (expand-file-name (format "scripts/%s.el" tool-name) dir-context))
                                  (expand-file-name (format "scripts/%s.el" tool-name) macher-agent-bundled-skills-directory))))
         
         ;; 1. Prioritise checking Virtual File System (VFS) first
         (vfs-content (when context
                        (let* ((vfs-path (when dir-context (expand-file-name (format "scripts/%s.el" tool-name) dir-context)))
                               (workspace-root (when workspace (macher-agent--get-workspace-root workspace)))
                               (rel-to-workspace (when (and workspace-root vfs-path)
                                                   (file-relative-name vfs-path workspace-root)))
                               (rel-to-dir (when (and dir-context vfs-path)
                                             (file-relative-name vfs-path dir-context)))
                               (visiting-buf (when vfs-path (find-buffer-visiting vfs-path)))
                               (visiting-buf-name (when visiting-buf (buffer-name visiting-buf)))
                               (std-name (format "scripts/%s.el" tool-name))
                               (base-name (format "%s.el" tool-name))
                               (candidates (delq nil (list vfs-path rel-to-workspace rel-to-dir visiting-buf-name std-name base-name)))
                               (found-content nil))
                          (cl-loop for cand in candidates
                                   until found-content
                                   do (setq found-content (ignore-errors (macher-agent--read-context-file context cand))))
                          found-content)))
         
         (content-to-eval vfs-content)
         (loaded-tool nil))

    ;; 2. Determine state: VFS (re-eval), Cache (use), or Disk (read & eval)
    (if vfs-content
        ;; VFS exists. We skip the cache and evaluate `content-to-eval` below.
        nil 
      (if cached
          ;; No VFS, but we have a cache. Use it.
          (setq loaded-tool cached)

        ;; No VFS and no cache. Try the physical disk.
        (catch 'found
          (dolist (path script-paths)
            (when (file-exists-p path)
              (with-temp-buffer
                (insert-file-contents path)
                (setq content-to-eval (buffer-string))
                (throw 'found t)))))))

    ;; 3. Evaluation pipeline (runs if we found text in VFS or Disk)
    (when (and content-to-eval (not loaded-tool))
      (setq loaded-tool
            (with-temp-buffer
              (insert content-to-eval)
              (goto-char (point-min))
              (let ((captured-tool nil)
                    (security-triggered nil)
                    (form nil))
                (condition-case err
                    (while (not security-triggered)
                      (setq form (read (current-buffer)))
                      (let* (;; AST-based security check
                             (has-security-violation
                              (and (consp form)
                                   (memq (car form) '(defun cl-defun defvar defcustom defmacro)))))
                        (if has-security-violation
                            (progn
                              (setq security-triggered t)
                              (message "Macher-Agent SECURITY WARNING: Skipped tool '%s' because it attempts to evaluate top-level definition: %s" tool-name (car form)))
                          ;; Lexical scoping is forced by the 't' parameter here
                          (let ((res (eval form t)))
                            ;; Robustly capture the tool struct, ignoring `provide`, `require`, etc.
                            (cond
                             ;; If evaluation returns the struct directly
                             ((and (fboundp 'gptel-tool-p) (gptel-tool-p res))
                              (setq captured-tool res))

                             ;; If evaluation returns a symbol bound to the struct
                             ((and (symbolp res) (boundp res) 
                                   (fboundp 'gptel-tool-p) (gptel-tool-p (symbol-value res)))
                              (setq captured-tool (symbol-value res))))))))
                  (end-of-file nil)
                  (error
                   (message "Macher-Agent: Failed to load tool %s - %s" tool-name err)
                   (setq captured-tool nil)))
                (unless security-triggered
                  captured-tool)))))
    
    ;; 3.5 Resolve statically defined / in-memory symbols and native gptel tools
    (unless loaded-tool
      (let* ((tool-sym (if (symbolp tool-name) tool-name (intern-soft tool-name)))
             (sym-val (when (and tool-sym (boundp tool-sym)) (symbol-value tool-sym))))
        (if (and sym-val (fboundp 'gptel-tool-p) (gptel-tool-p sym-val))
            (setq loaded-tool sym-val)
          (let ((tool-name-str (if (symbolp tool-name) (symbol-name tool-name) tool-name)))
            (setq loaded-tool 
                  (ignore-errors 
                    (gptel-get-tool tool-name-str)))))))
    
    ;; 4. Cache and return
    (when loaded-tool
      (puthash tool-name loaded-tool registry))

    ;; Return the loaded struct, or return the string to satisfy gptel constraints
    (or loaded-tool tool-name)))

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
             (sym (plist-get parsed :name-sym))
             (body (plist-get parsed :body))
             (desc (plist-get parsed :description))
             (model (plist-get parsed :model))
             (tool-names (plist-get parsed :allowed-tools))
             (workspace (when context (macher-agent--get-context-workspace context))))
        (when (and sym body)
          (let* ((alist (if workspace (macher-agent-workspace-skills-alist workspace) macher-agent-global-skills-alist))
                 (resolved-tools (when tool-names
                                   (delq nil (mapcar (lambda (tname)
                                                       (macher-agent-resolve-tool tname context skills-dir))
                                                     tool-names)))))
            ;; Store metadata safely in the private alist
            (setf (alist-get sym alist)
                  (list :system body :description desc :model (when model (intern model)) :tools resolved-tools))
            (if workspace
                (setf (macher-agent-workspace-skills-alist workspace) alist)
              (setq macher-agent-global-skills-alist alist))))))))

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
    
    ;; Sync workspace and global skills to gptel's buffer-local directives
    (let* ((workspace (when context (macher-agent--get-context-workspace context)))
           (ws-skills (when workspace (macher-agent-workspace-skills-alist workspace)))
           (global-skills macher-agent-global-skills-alist)
           (merged-skills (append ws-skills global-skills)))
      
      (unless (local-variable-p 'gptel-directives)
        (setq-local gptel-directives (copy-tree (default-value 'gptel-directives))))
      
      (unless (local-variable-p 'gptel--known-presets)
        (setq-local gptel--known-presets (copy-tree (default-value 'gptel--known-presets))))
      
      (cl-loop for (sym . meta) in merged-skills
               for system-prompt = (plist-get meta :system)
               for desc = (plist-get meta :description)
               for model = (plist-get meta :model)
               for tools = (plist-get meta :tools)
               for tool-names = (mapcar (lambda (t_) (if (and (fboundp 'gptel-tool-p) (gptel-tool-p t_)) (gptel-tool-name t_) (if (symbolp t_) (symbol-name t_) t_))) tools)
               do (when system-prompt
                    (setf (alist-get sym gptel-directives) system-prompt)
                    (let ((preset-spec (list :description (or desc (format "Agent Profile: %s" sym))
                                             :system system-prompt)))
                      (when model (setq preset-spec (plist-put preset-spec :model model)))
                      (when tool-names 
                        (setq preset-spec (plist-put preset-spec :tools `(:append ,tool-names))))
                      (setf (alist-get sym gptel--known-presets) preset-spec))))))
  
  (when (fboundp 'gptel--setup-directive-menu)
    (gptel--setup-directive-menu 'gptel--system-message "Agent Profile")))

(defun macher-agent--find-native-tool (tool-name)
  "Safely find a gptel-tool registered natively via `gptel-make-tool`."
  (let* ((t-str (if (symbolp tool-name) (symbol-name tool-name) tool-name))
         ;; Normalise dashes to underscores for robust matching
         (normalized-target (replace-regexp-in-string "-" "_" t-str))
         (found nil))
    
    ;; 1. Check the active/buffer-local tools list first
    (dolist (t_ (append (default-value 'gptel-tools) (bound-and-true-p gptel-tools)))
      (when (and (not found) (fboundp 'gptel-tool-p) (gptel-tool-p t_))
        (let ((t-name (format "%s" (gptel-tool-name t_))))
          (when (equal (replace-regexp-in-string "-" "_" t-name) normalized-target)
            (setq found t_)))))
    
    ;; 2. Look in the global gptel registry (where `gptel-make-tool` stores everything)
    ;; Structure: ((category . ((name . tool-struct) ...)) ...)
    (unless found
      (when (boundp 'gptel--known-tools)
        (cl-loop for category-alist in gptel--known-tools
                 until found
                 do (let ((tools-alist (cdr category-alist)))
                      (cl-loop for (name . tool) in tools-alist
                               until found
                               do (when (and (fboundp 'gptel-tool-p) (gptel-tool-p tool))
                                    (let ((t-name (format "%s" (gptel-tool-name tool))))
                                      (when (equal (replace-regexp-in-string "-" "_" t-name) normalized-target)
                                        (setq found tool)))))))))
    found))

(defun macher-agent-resolve-and-flatten-tools (tools)
  "Resolve a list of tool names, structs, functions, or nested lists into a flat list of structs."
  (cl-mapcan
   (lambda (t-item)
     (cond
      ;; If nil, ignore
      ((null t-item) nil)
      ;; If a list, recurse
      ((listp t-item)
       (macher-agent-resolve-and-flatten-tools t-item))
      ;; If already a gptel-tool struct, return a list containing it
      ((and (fboundp 'gptel-tool-p) (gptel-tool-p t-item))
       (list t-item))
      ;; If a function, execute it and resolve the result recursively
      ((functionp t-item)
       (let ((result (condition-case nil
                         (funcall t-item)
                       (error nil))))
         (when result
           (macher-agent-resolve-and-flatten-tools (ensure-list result)))))
      ;; If a symbol that is fboundp, execute it
      ((and (symbolp t-item) (fboundp t-item))
       (let ((result (condition-case nil
                         (funcall t-item)
                       (error nil))))
         (when result
           (macher-agent-resolve-and-flatten-tools (ensure-list result)))))
      ;; If a string or symbol, resolve it via macher-agent-resolve-tool
      ((or (stringp t-item) (symbolp t-item))
       (let* ((ctx (ignore-errors (macher-agent-current-context)))
              (ws (when ctx (macher-agent--get-context-workspace ctx)))
              (skills-dir (when ws (macher-agent-workspace-root ws)))
              (resolved (macher-agent-resolve-tool t-item ctx skills-dir)))
         (if (and resolved (fboundp 'gptel-tool-p) (gptel-tool-p resolved))
             (list resolved)
           nil)))
      (t nil)))
   (ensure-list tools)))

(defun macher-agent-resolve-to-struct (t-item)
  "Convert a tool item safely into a gptel-tool struct."
  (car (macher-agent-resolve-and-flatten-tools t-item)))

(defun macher-agent--wrap-tool-for-project-root (tool)
  "Clone and wrap the tool so it ALWAYS runs in the project root."
  (if (and tool (fboundp 'gptel-tool-p) (gptel-tool-p tool))
      (let* ((orig-fn (gptel-tool-function tool))
             (tool-sym (intern (gptel-tool-name tool)))
             (cached-wrapped-fn (get tool-sym 'macher-agent-wrapped-fn)))
        
        ;; If already wrapped, skip to prevent nesting
        (if (eq orig-fn cached-wrapped-fn)
            tool
          
          ;; Otherwise, safely clone and inject the project root macro
          (let ((new-tool (copy-sequence tool)))
            (setf (gptel-tool-function new-tool)
                  (lambda (&rest args)
                    (macher-agent-with-project-root 
                     (apply orig-fn args))))
            
            ;; Cache the new lambda so we recognise it next time
            (put tool-sym 'macher-agent-wrapped-fn (gptel-tool-function new-tool))
            new-tool)))
    tool))

(defun macher-agent-deduplicate-tools (tools)
  "Resolve raw strings to gptel structs and deduplicate."
  (cl-remove-duplicates 
   (macher-agent-resolve-and-flatten-tools tools)
   :key (lambda (t_) (format "%s" (gptel-tool-name t_)))
   :test #'equal))

(defun macher-agent-resolve-profile-tools (skill-tools)
  "Convert a list of tool names/strings into a verified list of gptel-tool structs."
  (let ((resolved-tools nil))
    (when skill-tools
      (dolist (t_ skill-tools)
        (if (and (fboundp 'gptel-tool-p) (gptel-tool-p t_))
            (push t_ resolved-tools)
          (let* ((t-str (if (symbolp t_) (symbol-name t_) t_))
                 (found-tool (when (fboundp 'macher-agent--find-native-tool)
                               (macher-agent--find-native-tool t-str))))
            (if found-tool
                (push found-tool resolved-tools)
              (message "Macher-Agent WARNING: Tool '%s' could not be resolved." t-str))))))
    (nreverse resolved-tools)))

(defvar macher-agent--allow-gptel-restore)

(defun macher-agent-gptel-mode-setup ()
  "Initialise macher-agent defaults for all gptel buffers."
  ;; Make variables buffer-local to prevent bleeding between sessions
  (make-local-variable 'gptel--preset)
  (make-local-variable 'gptel-tools)
  (make-local-variable 'gptel-model)
  (make-local-variable 'gptel-backend)
  (make-local-variable 'gptel--system-message)
  (make-local-variable 'gptel-temperature)
  (make-local-variable 'gptel-max-tokens)
  (make-local-variable 'gptel--tool-names)
  (make-local-variable 'gptel--backend-name)

  (setq-local gptel--set-buffer-locally t)
  
  ;; Initialise tools to core defaults and resolve them to structs
  (setq-local gptel-tools (macher-agent-deduplicate-tools (append (default-value 'gptel-tools) gptel-tools)))

  (when default-directory
    (macher-agent--init-workspace-state 
     (file-name-as-directory (macher-agent--get-project-root default-directory))))
  
  ;; Safely trigger the postponed gptel--restore-state now that workspace is loaded.
  (when (fboundp 'gptel--restore-state)
    (let ((macher-agent--allow-gptel-restore t))
      (gptel--restore-state))))

(add-hook 'gptel-mode-hook #'macher-agent-gptel-mode-setup)

(defun macher-agent--get-project-root (&optional dir)
  "Resolve the absolute root path of the project for DIR."
  (let* ((d (or dir default-directory))
         (proj (and (fboundp 'project-current) (project-current nil d))))
    (expand-file-name
     (or (and proj (if (fboundp 'project-root) (project-root proj) (cdr proj)))
         (and (fboundp 'vc-root-dir) (let ((default-directory d)) (vc-root-dir)))
         d))))

(defun macher-agent-branch-chat (new-name)
  "Clone the current chat, establishing lineage and inheriting all agent state."
  (interactive "sNew branch name: ")
  (let* ((parent-buf (current-buffer))
         (parent-name (buffer-name parent-buf))
         (parent-mode major-mode)
         (content (buffer-string))
         (active-backend gptel-backend)
         (active-model gptel-model)
         (active-sys gptel--system-message)
         (active-skill (bound-and-true-p macher-agent--active-skill-sym)))
    
    (with-current-buffer (generate-new-buffer new-name)
      (funcall parent-mode)
      (gptel-mode)
      (insert content)

      ;; Metadata to allow users to render buffer trees
      (setq-local macher-agent-parent-buffer parent-name)
      
      (when active-backend (setq-local gptel-backend active-backend))
      (when active-model (setq-local gptel-model active-model))
      (when active-sys (setq-local gptel--system-message active-sys))
      (when active-skill (setq-local macher-agent--active-skill-sym active-skill))
      
      (switch-to-buffer (current-buffer)))))


(provide 'macher-agent-api)
